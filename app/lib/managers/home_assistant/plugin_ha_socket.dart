import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/logging.dart';
import 'ha_credential_commands.dart';

/// Home Assistant commands and subscriptions for plugins (the SDK's `ha`
/// capability).
///
/// Every plugin shares one connection, signed in with the kiosk's token,
/// which never reaches a plugin. A plugin sends Home Assistant's own
/// websocket messages without an id, and the app numbers them. That way
/// the app knows which subscriptions belong to which plugin session and
/// ends them when the session ends, without touching anyone else's.
///
/// The connection opens on the first call and closes after [idleClose]
/// with nothing in flight and no subscriptions. While subscriptions exist
/// it reconnects with backoff and subscribes them again.
class HaPluginSocket {
  HaPluginSocket({
    required this.baseUrl,
    required this.token,
    required this.log,
    WebSocketChannel Function(Uri uri)? channelFactory,
    this.idleClose = const Duration(seconds: 60),
    this.callTimeout = const Duration(seconds: 25),
  }) : _channelFactory =
           channelFactory ??
           ((uri) => IOWebSocketChannel.connect(
             uri,
             pingInterval: const Duration(seconds: 20),
             connectTimeout: const Duration(seconds: 10),
           ));

  /// Home Assistant's origin and the kiosk's long-lived token, read on
  /// every connect so a changed address or token is picked up.
  final String Function() baseUrl;
  final String Function() token;
  final Logger log;
  final Duration idleClose;
  final Duration callTimeout;
  final WebSocketChannel Function(Uri uri) _channelFactory;

  /// Delivers a subscription's events and status changes to its plugin
  /// session: `{type: event, event}`, `{type: disconnected}`,
  /// `{type: resubscribed}`, `{type: ended, error}` and `{type: too_large}`.
  void Function(String owner, String key, Map<String, Object?> payload)? emit;

  static const maxSubscriptions = 16;
  static const maxMessageBytes = 32768;
  static const maxResultBytes = 32768;
  static const maxEventBytes = 30000;

  static final _keyPattern = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');

  static bool validKey(Object? key) =>
      key is String && _keyPattern.hasMatch(key);

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _listener;
  Future<String?>? _connecting;
  bool _ready = false;
  bool _closed = false;
  int _generation = 0;
  int _nextId = 1;
  int _retrySeconds = 1;
  Timer? _retry;
  Timer? _idle;

  /// Result handlers by message id: calls, subscribes and resubscribes.
  final _pending = <int, void Function(Map frame)>{};

  /// The owner of each call in flight, so a session's end fails them at
  /// once.
  final _calls = <int, String>{};
  final _subs = <String, _Subscription>{};
  final _byId = <int, _Subscription>{};

  /// Ids whose stray events were already answered with an unsubscribe.
  final _released = <int>{};

  @visibleForTesting
  bool get connected => _ready;

  @visibleForTesting
  int get subscriptionCount => _subs.length;

  /// Run one command for [owner] and answer `{ok: true, result}` or
  /// `{ok: false, error: {code, message}}`.
  Future<Map<String, Object?>> call(
    String owner,
    Map<String, Object?> message,
  ) async {
    final invalid = _validate(message);
    if (invalid != null) return invalid;
    final error = await _ensureConnected();
    if (error != null) return _error(error);
    final done = Completer<Map<String, Object?>>();
    final id = _send(message, (frame) {
      if (done.isCompleted) return;
      if (frame['success'] != true) {
        done.complete(_failure(frame['error']));
        return;
      }
      final result = frame['result'];
      done.complete(
        _bytes({'result': result}) > maxResultBytes
            ? _error('too_large', 'The result is larger than 32 KB')
            : {'ok': true, 'result': result},
      );
    });
    if (id == null) return _error('connection_lost');
    _calls[id] = owner;
    try {
      return await done.future.timeout(
        callTimeout,
        onTimeout: () => _error('timeout'),
      );
    } finally {
      _pending.remove(id);
      _calls.remove(id);
      _scheduleIdle();
    }
  }

  /// Subscribe [owner] under [key] with [message], such as
  /// `subscribe_trigger`. Answers like [call] once Home Assistant accepted
  /// it. Events then arrive through [emit] until [unsubscribe].
  Future<Map<String, Object?>> subscribe(
    String owner,
    String key,
    Map<String, Object?> message,
  ) async {
    if (!validKey(key)) return _error('invalid_key');
    final invalid = _validate(message);
    if (invalid != null) return invalid;
    final name = _name(owner, key);
    if (_subs.containsKey(name)) return _error('in_use');
    if (_subs.values.where((s) => s.owner == owner).length >=
        maxSubscriptions) {
      return _error('too_many', 'At most 16 subscriptions per plugin');
    }
    final sub = _Subscription(owner, key, Map.of(message));
    _subs[name] = sub;
    final error = await _ensureConnected();
    if (!identical(_subs[name], sub)) return _error('unsubscribed');
    if (error != null) {
      _subs.remove(name);
      _scheduleIdle();
      return _error(error);
    }
    final done = Completer<Map<String, Object?>>();
    _start(sub, (frame) {
      if (done.isCompleted) return;
      done.complete(
        frame['success'] == true ? {'ok': true} : _failure(frame['error']),
      );
    });
    final result = await done.future.timeout(
      callTimeout,
      onTimeout: () => _error('timeout'),
    );
    if (result['ok'] == true && identical(_subs[name], sub)) {
      sub.confirmed = true;
    } else if (identical(_subs[name], sub)) {
      _end(sub);
    }
    _scheduleIdle();
    return result;
  }

  /// End [owner]'s subscription [key]. Unknown keys are ignored.
  void unsubscribe(String owner, String key) {
    final sub = _subs[_name(owner, key)];
    if (sub != null) _end(sub);
    _scheduleIdle();
  }

  /// End everything [owner] holds: its session ended.
  void release(String owner) {
    for (final sub in _subs.values.where((s) => s.owner == owner).toList()) {
      _end(sub);
    }
    for (final entry
        in _calls.entries.where((e) => e.value == owner).toList()) {
      _pending.remove(entry.key)?.call(_lostFrame('session_ended'));
    }
    _scheduleIdle();
  }

  /// The address or token changed: start over with the new one.
  void restart() {
    if (_closed) return;
    _drop('settings_changed');
    _retrySeconds = 1;
    if (_subs.isNotEmpty) _reconnectSoon(Duration.zero);
  }

  void dispose() {
    _closed = true;
    _retry?.cancel();
    _idle?.cancel();
    _drop('disposed');
    _subs.clear();
    emit = null;
  }

  Map<String, Object?>? _validate(Map<String, Object?> message) {
    final type = message['type'];
    if (type is! String || type.isEmpty) {
      return _error('invalid_message', 'The message needs a type');
    }
    if (message.containsKey('id')) {
      return _error('invalid_message', 'Leave out the id, KS numbers it');
    }
    if (isHaCredentialCommand(type)) {
      return _failure(haCredentialRefusal(null)['error']);
    }
    // The connection's own bookkeeping stays with KS.
    if (const {
      'ping',
      'pong',
      'supported_features',
      'unsubscribe_events',
    }.contains(type)) {
      return _error('not_allowed', '$type is handled by KS');
    }
    try {
      if (_bytes(message) > maxMessageBytes) {
        return _error('too_large', 'The message is larger than 32 KB');
      }
    } catch (_) {
      return _error('invalid_message', 'The message is not JSON');
    }
    return null;
  }

  void _start(_Subscription sub, void Function(Map frame) onResult) {
    final id = _send(sub.message, onResult);
    if (id == null) {
      onResult(_lostFrame('connection_lost'));
      return;
    }
    sub.id = id;
    _byId[id] = sub;
  }

  void _end(_Subscription sub) {
    _subs.remove(_name(sub.owner, sub.key));
    final id = sub.id;
    sub.id = null;
    if (id == null) return;
    _byId.remove(id);
    _pending.remove(id)?.call(_lostFrame('unsubscribed'));
    if (_ready) {
      _release(id);
      _send({'type': 'unsubscribe_events', 'subscription': id}, (_) {});
    }
  }

  /// Send [message] with a fresh id, its result going to [onResult]. Null
  /// when the connection is not up.
  int? _send(Map<String, Object?> message, void Function(Map frame) onResult) {
    final channel = _channel;
    if (!_ready || channel == null) return null;
    final id = _nextId++;
    _pending[id] = onResult;
    channel.sink.add(jsonEncode({...message, 'id': id}));
    return id;
  }

  Future<String?> _ensureConnected() {
    _idle?.cancel();
    if (_closed) return Future.value('not_configured');
    if (_ready) return Future.value(null);
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<String?> _connect() async {
    final base = baseUrl().trim().replaceFirst(RegExp(r'/+$'), '');
    final key = token().trim();
    if (base.isEmpty || key.isEmpty) return 'not_configured';
    final generation = ++_generation;
    final ws = base
        .replaceFirst(RegExp('^https://'), 'wss://')
        .replaceFirst(RegExp('^http://'), 'ws://');
    final authed = Completer<String?>();
    final WebSocketChannel channel;
    try {
      channel = _channelFactory(Uri.parse('$ws/api/websocket'));
    } catch (_) {
      return 'unreachable';
    }
    _channel = channel;
    void lost() {
      if (!authed.isCompleted) authed.complete('unreachable');
      if (generation == _generation) _lost();
    }

    _listener = channel.stream.listen(
      (raw) {
        if (generation != _generation || raw is! String) return;
        Object? decoded;
        try {
          decoded = jsonDecode(raw);
        } catch (_) {
          return;
        }
        for (final frame in decoded is List ? decoded : [decoded]) {
          if (frame is! Map) continue;
          if (_ready) {
            _onFrame(frame);
            continue;
          }
          switch (frame['type']) {
            case 'auth_required':
              channel.sink.add(
                jsonEncode({'type': 'auth', 'access_token': key}),
              );
            case 'auth_ok':
              _ready = true;
              _retrySeconds = 1;
              _released.clear();
              if (!authed.isCompleted) authed.complete(null);
            case 'auth_invalid':
              if (!authed.isCompleted) authed.complete('auth_invalid');
              _drop('auth_invalid');
          }
        }
      },
      onError: (Object _) => lost(),
      onDone: lost,
      cancelOnError: true,
    );
    unawaited(channel.ready.then<void>((_) {}, onError: (Object _) => lost()));
    final error = await authed.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        if (generation == _generation) _drop('timeout');
        return 'unreachable';
      },
    );
    if (error == null) {
      log.info('plugins', 'Home Assistant connection for plugins open');
      _resubscribe();
    } else {
      log.warn('plugins', 'Home Assistant connection for plugins: $error');
      if (_subs.values.any((s) => s.confirmed)) _reconnectSoon();
    }
    return error;
  }

  void _onFrame(Map frame) {
    final id = frame['id'];
    if (id is! int) return;
    switch (frame['type']) {
      case 'result':
        _pending.remove(id)?.call(frame);
        _scheduleIdle();
      case 'event':
        final sub = _byId[id];
        if (sub == null) {
          // A call answered with a subscription, or the tail of one just
          // ended: nobody listens, so Home Assistant can stop sending.
          if (_release(id)) {
            _send({'type': 'unsubscribe_events', 'subscription': id}, (_) {});
          }
          return;
        }
        final event = frame['event'];
        Map<String, Object?> payload = {'type': 'event', 'event': event};
        if (_bytes(payload) > maxEventBytes) payload = {'type': 'too_large'};
        emit?.call(sub.owner, sub.key, payload);
    }
  }

  /// Subscribe again everything that was confirmed before the connection
  /// dropped.
  void _resubscribe() {
    for (final sub in _subs.values.where((s) => s.confirmed).toList()) {
      if (sub.id != null) continue;
      _start(sub, (frame) {
        // Dropped again before Home Assistant answered: the next
        // connection tries once more.
        if (frame['lost'] == true) return;
        if (!identical(_subs[_name(sub.owner, sub.key)], sub)) return;
        if (frame['success'] == true) {
          emit?.call(sub.owner, sub.key, {'type': 'resubscribed'});
        } else {
          final error = _failure(frame['error'])['error'];
          _end(sub);
          emit?.call(sub.owner, sub.key, {'type': 'ended', 'error': error});
          _scheduleIdle();
        }
      });
    }
  }

  /// The connection went down on its own. One that never signed in is
  /// retried by [_connect].
  void _lost() {
    final retry = _ready && _subs.values.any((s) => s.confirmed);
    _drop('connection_lost');
    if (retry) _reconnectSoon();
  }

  /// Remember that [id] was unsubscribed. False when it already was.
  bool _release(int id) {
    if (_released.length > 512) _released.clear();
    return _released.add(id);
  }

  /// Close the connection. Calls in flight fail with [reason], and every
  /// confirmed subscription hears it went down.
  void _drop(String reason) {
    _generation++;
    final wasReady = _ready;
    _ready = false;
    final listener = _listener;
    final channel = _channel;
    _listener = null;
    _channel = null;
    if (listener != null) unawaited(listener.cancel());
    if (channel != null) {
      unawaited(channel.sink.close().catchError((_) {}));
    }
    final pending = _pending.values.toList();
    _pending.clear();
    _byId.clear();
    for (final handler in pending) {
      handler(_lostFrame(reason));
    }
    for (final sub in _subs.values.toList()) {
      final had = sub.id != null;
      sub.id = null;
      if (sub.confirmed && had && wasReady) {
        emit?.call(sub.owner, sub.key, {'type': 'disconnected'});
      }
    }
    if (wasReady) {
      log.info(
        'plugins',
        'Home Assistant connection for plugins closed: $reason',
      );
    }
  }

  void _reconnectSoon([Duration? delay]) {
    if (_closed) return;
    _retry?.cancel();
    final wait = delay ?? Duration(seconds: _retrySeconds);
    _retrySeconds = (_retrySeconds * 2).clamp(1, 30);
    _retry = Timer(wait, () {
      if (_closed || _ready || !_subs.values.any((s) => s.confirmed)) return;
      unawaited(_ensureConnected());
    });
  }

  void _scheduleIdle() {
    _idle?.cancel();
    if (_closed || _subs.isNotEmpty || _pending.isNotEmpty) return;
    _idle = Timer(idleClose, () {
      if (_subs.isEmpty && _pending.isEmpty) _drop('idle');
    });
  }

  static String _name(String owner, String key) => '$owner\n$key';

  static int _bytes(Object? value) => utf8.encode(jsonEncode(value)).length;

  static Map<String, Object?> _lostFrame(String code) => {
    'lost': true,
    'success': false,
    'error': {'code': code, 'message': ''},
  };

  static Map<String, Object?> _error(String code, [String message = '']) => {
    'ok': false,
    'error': {'code': code, 'message': message},
  };

  /// Home Assistant's error, reduced to its code and message.
  static Map<String, Object?> _failure(Object? error) => _error(
    error is Map && error['code'] != null
        ? '${error['code']}'
        : 'unknown_error',
    error is Map && error['message'] is String
        ? error['message'] as String
        : '',
  );
}

class _Subscription {
  _Subscription(this.owner, this.key, this.message);

  final String owner;
  final String key;
  final Map<String, Object?> message;

  /// The message id Home Assistant knows it by on this connection.
  int? id;

  /// Home Assistant accepted it once, so a reconnect subscribes it again.
  bool confirmed = false;
}
