import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../managers/settings/definitions.dart' as defs;
import 'theme.dart';

/// The six status tiles Remote Admin's Overview shows, on the panel itself.
///
/// The panel is where someone stands when something looks wrong, and it is
/// often the panel's own connection being debugged — reaching for a laptop
/// to answer "is Home Assistant connected?" is backwards when the answer
/// might be "no, and that is why the laptop route is failing too".
///
/// Read through the same commands Remote Admin's Overview calls
/// (`haStatus`, `getWakeWordState`, `esphomeStatus`, `sendspinStatus`,
/// `getServiceStatus`, `getUpdateStatus`), so the two surfaces cannot drift
/// into disagreeing about the same panel. The wording follows overview.js
/// deliberately, with one exception noted on [_ha].
///
/// Never shown in the restricted quick-actions drawer: a locked-down wall
/// panel should not advertise its internals to whoever walks past, and the
/// version notice above it already draws that line.
class KioskStatusTiles extends StatefulWidget {
  const KioskStatusTiles({super.key, required this.container});

  final AppContainer container;

  @override
  State<KioskStatusTiles> createState() => _KioskStatusTilesState();
}

class StatusTile {
  const StatusTile(this.title, this.text, this.level);
  final String title;
  final String text;

  /// '' neutral, 'on' good, 'warn' attention, 'off' bad — the same four
  /// levels paintTile() uses, so the dot colours match Remote Admin.
  final String level;
}

/// Remote Admin labels a true `connected` as "Connected". That flag is a
/// latch — HomeAssistantManager.connectionOk is "proven this run", and
/// nothing clears it when the server goes away — so this says "Validated"
/// instead, which is what it actually means (upstream #525 is making the
/// same change).
StatusTile haTile(Map<String, Object?>? ha) {
  if (ha == null) return const StatusTile('Home Assistant', 'Status unavailable', '');
  if (ha['configured'] != true) {
    return const StatusTile('Home Assistant', 'Not set up', 'warn');
  }
  if (ha['connected'] != true) {
    return const StatusTile('Home Assistant', 'Not validated', 'off');
  }
  return const StatusTile('Home Assistant', 'Validated', 'on');
}

StatusTile voiceTile(Map<String, Object?>? wake, bool wakeWordEnabled) {
  if (!wakeWordEnabled) {
    return const StatusTile('Voice Satellite', 'Wake word detection off', '');
  }
  if (wake == null) return const StatusTile('Voice Satellite', 'Status unavailable', '');
  if (wake['released'] == true) {
    final reason = wake['releaseReason'];
    return StatusTile('Voice Satellite',
        reason is String && reason.isNotEmpty ? reason : 'Stopped', 'warn');
  }
  if (wake['listening'] == true) {
    final models = wake['models'];
    final words = models is List
        ? models
            .whereType<Map>()
            .map((m) => m['wakeWord'])
            .whereType<String>()
            .where((w) => w.isNotEmpty)
            .join(', ')
        : '';
    return StatusTile('Voice Satellite',
        words.isEmpty ? 'Listening' : 'Listening for $words', 'on');
  }
  final label = wake['statusLabel'];
  return StatusTile('Voice Satellite',
      label is String && label.isNotEmpty ? label : 'Not listening', 'warn');
}

StatusTile esphomeTile(
    Map<String, Object?>? esp, bool entities, bool proxy) {
  if (esp == null) return const StatusTile('ESPHome', 'Status unavailable', '');
  if (esp['running'] != true) return const StatusTile('ESPHome', 'Off', '');
  final connections = esp['connections'];
  final live = (esp['clients'] as num?) != null && (esp['clients'] as num) > 0 ||
      (connections is List && connections.isNotEmpty) ||
      (esp['subscribers'] as num?) != null && (esp['subscribers'] as num) > 0;
  if (!live) return const StatusTile('ESPHome', 'Waiting for Home Assistant', 'warn');
  final what = entities && proxy
      ? 'Entities and BT proxy'
      : entities
          ? 'Entities only'
          : proxy
              ? 'BT Proxy only'
              : 'Connected';
  return StatusTile('ESPHome', what, 'on');
}

/// Green only while something plays: idle is a player's normal state, not
/// a fault, and a quiet speaker should not read as something to go and fix.
StatusTile mediaTile(Map<String, Object?>? media) {
  if (media == null) return const StatusTile('Media Player', 'Status unavailable', '');
  if (media['enabled'] != true) return const StatusTile('Media Player', 'Off', '');
  final remote = media['remotePlayer'];
  final server = media['serverName'];
  final where = remote is String && remote.isNotEmpty
      ? remote
      : server is String
          // "Music Assistant (d5369777-music-assistant)" reads as the name.
          ? server.replaceAll(RegExp(r'\s*\(.*\)\s*$'), '').trim()
          : '';
  String label(String word) => where.isEmpty ? word : '$word - $where';
  if (media['playing'] == true) return StatusTile('Media Player', label('Playing'), 'on');
  if (media['playbackState'] == 'paused') {
    return StatusTile('Media Player', label('Paused'), '');
  }
  return StatusTile('Media Player', label('Idle'), '');
}

StatusTile serviceTile(Map<String, Object?>? svc) {
  if (svc == null) return const StatusTile('Service', 'Status unavailable', '');
  final error = svc['error'];
  if (error is String && error.isNotEmpty) return StatusTile('Service', error, 'off');
  if (svc['running'] != true) return const StatusTile('Service', 'Not running', 'warn');
  final reasons = svc['reasons'];
  final n = reasons is List ? reasons.length : 0;
  return StatusTile('Service',
      n == 0 ? 'Running' : 'Running - $n feature${n == 1 ? '' : 's'}', 'on');
}

StatusTile updateTile(Map<String, Object?>? upd) {
  if (upd == null) return const StatusTile('App Version', 'Status unavailable', '');
  final available = upd['availableVersion'];
  if (upd['progress'] != null) {
    return StatusTile('App Version',
        'Downloading: ${available is String ? available : ''}'.trim(), 'warn');
  }
  if (available is String && available.isNotEmpty) {
    return StatusTile('App Version', 'New version: $available', 'warn');
  }
  final current = upd['currentVersion'];
  return StatusTile('App Version',
      current is String && current.isNotEmpty ? 'Up to date: $current' : 'Up to date',
      'on');
}

class _KioskStatusTilesState extends State<KioskStatusTiles> {
  List<StatusTile>? _tiles;
  Timer? _poll;

  AppContainer get c => widget.container;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    // The drawer is transient, so this only runs while it is open; a
    // stale-by-seconds tile would undercut the point of showing it at all.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_read()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<Map<String, Object?>?> _ask(String command) async {
    try {
      final result = await c.commands.execute(command, const {});
      if (!result.ok) return null;
      final data = result.data;
      return data is Map ? data.cast<String, Object?>() : null;
    } catch (_) {
      // A command that throws is "status unavailable", not a crashed menu.
      return null;
    }
  }

  Future<void> _read() async {
    final results = await Future.wait([
      _ask('haStatus'),
      _ask('getWakeWordState'),
      _ask('esphomeStatus'),
      _ask('sendspinStatus'),
      _ask('getServiceStatus'),
      _ask('getUpdateStatus'),
    ]);
    if (!mounted) return;
    setState(() {
      _tiles = [
        haTile(results[0]),
        voiceTile(results[1], c.settings.get(defs.wakeWordEnabled)),
        esphomeTile(results[2], c.settings.get(defs.esphomeEntities),
            c.settings.get(defs.btproxyEnabled)),
        mediaTile(results[3]),
        serviceTile(results[4]),
        updateTile(results[5]),
      ];
    });
  }







  Color _dot(ThemeData theme, String level) {
    switch (level) {
      case 'on':
        // The brand sage, as the remote admin's --ok uses; the darkened
        // step on light surfaces, matching the rest of the app.
        return theme.brightness == Brightness.dark ? ksSage : ksSageOnLight;
      case 'warn':
        return theme.colorScheme.tertiary;
      case 'off':
        return theme.colorScheme.error;
      default:
        return theme.colorScheme.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tiles = _tiles;
    // Nothing until the first read answers: an empty frame is better than
    // six "Status unavailable" rows that resolve a moment later.
    if (tiles == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final tile in tiles)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _dot(theme, tile.level),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    tile.title,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tile.text,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
