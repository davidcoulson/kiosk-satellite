/// `kioskSatellite.ha`: the page half of the managed Home Assistant
/// connection (see page_ha_socket.dart and docs/js-api.md).
///
/// `createSocket` hands `home-assistant-js-websocket` a WebSocket stand-in
/// that is already signed in, the way its own `createSocket` resolves. Its
/// reconnects run unchanged: a closed socket fires `close` and the library
/// asks for a new one. `call` and `subscribe` are a small client of their
/// own for pages without the library. It resubscribes after a drop.
///
/// Every socket belongs to this document: the id drawn here goes with
/// every message, so a socket of a page already gone never reaches this
/// one.
const pageHaSocketScript = r'''
  const haDoc = Math.random().toString(36).slice(2) + Date.now().toString(36);
  let haSerial = 0;
  const haSockets = {};

  function haBridge(op, sid, frame) {
    try {
      return window.flutter_inappwebview
        .callHandler('ksHaSocket', op, haDoc, sid, frame === undefined ? null : frame)
        .catch(function () { return null; });
    } catch (e) {
      return Promise.resolve(null);
    }
  }

  function haAtLeast(version, major, minor) {
    const parts = String(version || '').split('.');
    const a = Number(parts[0]) || 0;
    const b = Number(parts[1]) || 0;
    return a > major || (a === major && b >= minor);
  }

  // The app's deliveries: frames batched per socket, and closes.
  window.__ksHaSocket = {
    receive: function (doc, batch) {
      if (doc !== haDoc) return;
      for (const sid in batch) {
        const socket = haSockets[sid];
        if (!socket || socket.readyState !== 1) continue;
        for (const data of batch[sid]) socket._emit('message', { data: data });
      }
    },
    closed: function (doc, sid, reason) {
      if (doc !== haDoc) return;
      const socket = haSockets[sid];
      if (socket) socket._closed(reason);
    }
  };

  // A WebSocket stand-in: what home-assistant-js-websocket uses of one.
  class KioskHaSocket {
    constructor(sid) {
      this.sid = sid;
      this.haVersion = '';
      this.readyState = 0;
      this.onmessage = null;
      this.onclose = null;
      this._listeners = { message: [], close: [] };
    }
    addEventListener(type, fn) {
      if (this._listeners[type] && fn) this._listeners[type].push(fn);
    }
    removeEventListener(type, fn) {
      const list = this._listeners[type];
      const at = list ? list.indexOf(fn) : -1;
      if (at >= 0) list.splice(at, 1);
    }
    send(data) {
      if (this.readyState !== 1) throw new Error('The Home Assistant socket is not open');
      haBridge('send', this.sid, String(data));
    }
    close() {
      if (this.readyState >= 2) return;
      this.readyState = 2;
      haBridge('close', this.sid);
      const self = this;
      setTimeout(function () { self._closed('closed'); }, 0);
    }
    _emit(type, event) {
      const handlers = this._listeners[type].slice();
      const own = this['on' + type];
      if (typeof own === 'function') handlers.push(own);
      for (const fn of handlers) {
        try {
          fn.call(this, event);
        } catch (e) {
          setTimeout(function () { throw e; }, 0);
        }
      }
    }
    _closed(reason) {
      if (this.readyState === 3) return;
      this.readyState = 3;
      delete haSockets[this.sid];
      this._emit('close', { code: 1000, reason: reason, wasClean: reason === 'closed' });
    }
  }
  KioskHaSocket.prototype.CONNECTING = 0;
  KioskHaSocket.prototype.OPEN = 1;
  KioskHaSocket.prototype.CLOSING = 2;
  KioskHaSocket.prototype.CLOSED = 3;

  // A signed-in socket, or a rejection with {code, message}.
  function haOpen() {
    const sid = 's' + String(++haSerial);
    const socket = new KioskHaSocket(sid);
    haSockets[sid] = socket;
    return haBridge('open', sid).then(function (answer) {
      if (!answer || !answer.ok || socket.readyState !== 0) {
        delete haSockets[sid];
        const code = (answer && !answer.ok && answer.error) || 'unreachable';
        throw { code: code, message: 'Home Assistant connection: ' + code };
      }
      socket.haVersion = answer.haVersion;
      socket.readyState = 1;
      return socket;
    });
  }

  // Codes no retry can fix: the setting is off, the page is no custom
  // page, or the kiosk has no Home Assistant token.
  function haFinal(error) {
    const code = error && error.code;
    return code === 'not_allowed' || code === 'not_configured' || code === 'auth_invalid';
  }

  // ---- call / subscribe: a small client for pages without the library.
  let haConn = null;
  let haConnecting = null;
  let haRetry = null;
  const haSubs = [];

  function haConnect() {
    if (haConn) return Promise.resolve(haConn);
    if (haConnecting) return haConnecting;
    haConnecting = haOpen().then(function (socket) {
      const conn = { socket: socket, id: 0, pending: {} };
      socket.addEventListener('message', function (event) {
        let data;
        try { data = JSON.parse(event.data); } catch (e) { return; }
        for (const message of Array.isArray(data) ? data : [data]) haOnMessage(conn, message);
      });
      socket.addEventListener('close', function (event) { haOnClose(conn, event.reason); });
      haConn = conn;
      haConnecting = null;
      for (const sub of haSubs) haSubscribeOn(conn, sub).catch(function () {});
      return conn;
    }, function (error) {
      haConnecting = null;
      throw error;
    });
    return haConnecting;
  }

  function haOnMessage(conn, message) {
    if (message.type === 'event') {
      for (const sub of haSubs) {
        if (sub.conn === conn && sub.id === message.id) {
          try { sub.callback(message.event); } catch (e) { setTimeout(function () { throw e; }, 0); }
        }
      }
      return;
    }
    if (message.type !== 'result') return;
    const waiting = conn.pending[message.id];
    if (!waiting) return;
    delete conn.pending[message.id];
    if (message.success) waiting.resolve(message.result);
    else waiting.reject(message.error);
  }

  function haOnClose(conn, reason) {
    if (haConn === conn) haConn = null;
    const pending = conn.pending;
    conn.pending = {};
    for (const id in pending) {
      pending[id].reject({ code: 'connection_lost', message: 'Home Assistant connection lost' });
    }
    for (const sub of haSubs) {
      if (sub.conn === conn) { sub.conn = null; sub.id = null; }
    }
    window.dispatchEvent(new CustomEvent('kiosksatellite:ha-closed', { detail: { reason: reason } }));
    if (haSubs.length) haReconnect(0);
  }

  function haReconnect(tries) {
    if (haRetry) return;
    haRetry = setTimeout(function () {
      haRetry = null;
      if (!haSubs.length || haConn) return;
      haConnect().then(function () {
        window.dispatchEvent(new CustomEvent('kiosksatellite:ha-ready'));
      }, function (error) {
        if (!haFinal(error)) haReconnect(tries + 1);
      });
    }, Math.min(tries, 5) * 1000);
  }

  function haSend(conn, message) {
    const id = ++conn.id;
    return new Promise(function (resolve, reject) {
      conn.pending[id] = { resolve: resolve, reject: reject };
      conn.socket.send(JSON.stringify(Object.assign({}, message, { id: id })));
    });
  }

  function haSubscribeOn(conn, sub) {
    const id = ++conn.id;
    sub.conn = conn;
    sub.id = id;
    return sub.ready = new Promise(function (resolve, reject) {
      conn.pending[id] = {
        resolve: resolve,
        reject: function (error) {
          if (sub.id === id) { sub.conn = null; sub.id = null; }
          reject(error);
        }
      };
      conn.socket.send(JSON.stringify(Object.assign({}, sub.message, { id: id })));
    });
  }

  const ha = {
    // For home-assistant-js-websocket:
    // createConnection({createSocket: kioskSatellite.ha.createSocket}).
    createSocket: function () {
      return haOpen().then(function (socket) {
        // What the library's own createSocket does once signed in: its
        // command ids start at 2 to leave this one room.
        if (haAtLeast(socket.haVersion, 2022, 9)) {
          socket.send(JSON.stringify({
            type: 'supported_features', id: 1, features: { coalesce_messages: 1 }
          }));
        }
        return socket;
      }, function (error) {
        // The library's codes: ERR_INVALID_AUTH (2) stops its reconnects,
        // ERR_CANNOT_CONNECT (1) retries.
        throw haFinal(error) ? 2 : 1;
      });
    },
    // One command; resolves with its result.
    call: function (message) {
      return haConnect().then(function (conn) { return haSend(conn, message); });
    },
    // A subscription; resolves with a function that ends it. Kept across
    // reconnects.
    subscribe: function (message, callback) {
      const sub = { message: message, callback: callback, conn: null, id: null, ready: null };
      haSubs.push(sub);
      const drop = function () {
        const at = haSubs.indexOf(sub);
        if (at >= 0) haSubs.splice(at, 1);
      };
      return haConnect().then(function (conn) {
        // A connection opened just now subscribed it already.
        return sub.conn === conn ? sub.ready : haSubscribeOn(conn, sub);
      }).then(function () {
        return function unsubscribe() {
          drop();
          const conn = sub.conn;
          if (!conn || conn !== haConn || sub.id == null) return Promise.resolve();
          return haSend(conn, { type: 'unsubscribe_events', subscription: sub.id })
            .catch(function () {});
        };
      }, function (error) {
        drop();
        throw error;
      });
    }
  };
''';
