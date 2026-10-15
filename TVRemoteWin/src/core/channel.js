'use strict';

const { EventEmitter } = require('node:events');
const net = require('node:net');
const WebSocket = require('ws');

/**
 * RFC 1918, link-local and loopback IPv4 addresses: the only hosts we will talk unverified TLS to.
 * Canonical dotted-quad only. `net.isIPv4` rejects what the URL layer and the OS resolver would read
 * differently (leading zeros = octal, hex, short forms, plain integers, trailing junk), so the address we
 * approve is the address that gets connected to.
 */
function isLocalAddress(host) {
  if (typeof host !== 'string' || !net.isIPv4(host)) return false;
  const [a, b] = host.split('.').map(Number);
  return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
}

class ChannelError extends Error {
  constructor(kind, message) {
    super(message);
    this.name = 'ChannelError';
    this.kind = kind; // 'unauthorized' | 'timeout' | 'closed'
  }
}

/**
 * WebSocket client for the Samsung Multiscreen (MSF) remote-control channel.
 *
 *   ws://<tv>:8001/api/v2/channels/samsung.remote.control?name=<base64 app name>
 *   wss://<tv>:8002/api/v2/channels/samsung.remote.control?name=<base64>&token=<token>
 *
 * Events: 'connected' (token), 'apps' (list), 'icon' (path, Buffer), 'event' (name, raw),
 *         'unauthorized', 'timeout', 'disconnected' (error).
 *
 * Learned on a UA49K5500: the TV drops a command if the client hangs up within ~0.3 s of sending it,
 * and a burst of icon requests makes it drop remote keys – callers keep the socket open and fetch icons
 * one at a time.
 */
class RemoteChannel extends EventEmitter {
  constructor({ host, transport = 'plain', appName = 'Windows Remote', token = null, port = null }) {
    super();
    this.host = host;
    this.transport = transport; // 'plain' ws:8001 | 'secure' wss:8002 (token auth)
    this.appName = appName;
    this.token = token;
    this.port = port; // tests point this at a fake TV; real TVs use 8001 / 8002
    this.ws = null;
    this.isConnected = false;
    this._pending = null;
    this._ping = null;
  }

  get url() {
    const secure = this.transport === 'secure';
    const name = encodeURIComponent(Buffer.from(this.appName).toString('base64'));
    const port = this.port || (secure ? 8002 : 8001);
    let url = `${secure ? 'wss' : 'ws'}://${this.host}:${port}/api/v2/channels/samsung.remote.control?name=${name}`;
    // The token is a credential: only ever sent over the TLS transport.
    if (secure && this.token) url += `&token=${encodeURIComponent(this.token)}`;
    return url;
  }

  /** Opens the socket and waits for `ms.channel.connect`. Resolves with the (possibly new) token. */
  connect() {
    this.disconnect();
    return new Promise((resolve, reject) => {
      // Samsung TVs present a self-signed certificate on :8002, so there is no CA chain to validate and the
      // connection is not authenticated. That is only acceptable (and the token only safe to send) on the
      // local network, so refuse it for anything else.
      if (this.transport === 'secure') {
        // Judge the host the URL parser will really connect to, not just the string we were given.
        let target = null;
        try { target = new URL(this.url).hostname; } catch { /* refused below */ }
        if (target !== this.host || !isLocalAddress(target)) {
          reject(new ChannelError('insecure', 'Refusing an unverified TLS connection to a non-local address. Use the TV\'s LAN IP.'));
          return;
        }
      }
      const ws = new WebSocket(this.url, { rejectUnauthorized: false, handshakeTimeout: 10_000, perMessageDeflate: false });
      this.ws = ws;
      // The TV waits ~30 s for someone to press Allow on the first connection.
      const timer = setTimeout(() => this._settle(new ChannelError('timeout', 'No answer from the TV. Accept the Allow prompt on the TV screen.')), 35_000);
      this._pending = { resolve, reject, timer };
      ws.on('message', (data) => { if (ws === this.ws) this._handle(data.toString()); });
      ws.on('error', (err) => { if (ws === this.ws) this._fail(err); });
      ws.on('close', (code) => { if (ws === this.ws) this._fail(new ChannelError('closed', `Connection closed (code ${code})`)); });
    });
  }

  disconnect() {
    clearInterval(this._ping);
    this._ping = null;
    const ws = this.ws;
    this.ws = null;
    this.isConnected = false;
    this._settle(new ChannelError('closed', 'Disconnected'));
    if (ws) { ws.removeAllListeners(); ws.on('error', () => {}); try { ws.close(); } catch { /* already closed */ } }
  }

  // --- commands -----------------------------------------------------------------------------

  sendKey(code, action = 'Click') {
    this.send({ method: 'ms.remote.control', params: { Cmd: action, DataOfCmd: code, Option: 'false', TypeOfRemote: 'SendRemoteKey' } });
  }

  /** Types text into the focused on-screen keyboard (search boxes, browser, YouTube…). */
  sendText(text) {
    this.send({ method: 'ms.remote.control', params: { Cmd: Buffer.from(text).toString('base64'), DataOfCmd: 'base64', TypeOfRemote: 'SendInputString' } });
  }

  /** Relative pointer movement (Web Browser and apps that show a cursor). */
  moveMouse(dx, dy) {
    this.send({ method: 'ms.remote.control', params: { Cmd: 'Move', Position: { x: dx, y: dy, Time: String(Date.now()) }, TypeOfRemote: 'ProcessMouseDevice' } });
  }

  click(right = false) {
    this.send({ method: 'ms.remote.control', params: { Cmd: right ? 'RightClick' : 'LeftClick', TypeOfRemote: 'ProcessMouseDevice' } });
  }

  requestInstalledApps() {
    this.send({ method: 'ms.channel.emit', params: { event: 'ed.installedApp.get', to: 'host' } });
  }

  /** Answered with an 'icon' event. */
  requestIcon(path) {
    this.send({ method: 'ms.channel.emit', params: { event: 'ed.apps.icon', to: 'host', data: { iconPath: path } } });
  }

  /** appType 2 = web app (DEEP_LINK), 4 = native (NATIVE_LAUNCH). Always over the socket: REST says ok without launching natives. */
  launchApp(id, appType = 2, metaTag = '') {
    this.send({
      method: 'ms.channel.emit',
      params: { event: 'ed.apps.launch', to: 'host', data: { appId: id, action_type: appType === 2 ? 'DEEP_LINK' : 'NATIVE_LAUNCH', metaTag } },
    });
  }

  /** The Web Browser takes the page as launch data. */
  openURL(url) {
    this.launchApp('org.tizen.browser', 4, url);
  }

  send(object) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify(object), (err) => { if (err) this._fail(err); });
  }

  // --- internals ------------------------------------------------------------------------------

  _handle(text) {
    let msg;
    try { msg = JSON.parse(text); } catch { return; }
    const data = msg.data && typeof msg.data === 'object' ? msg.data : {};
    switch (msg.event) {
      case 'ms.channel.connect':
        if (data.token) this.token = data.token;
        this.isConnected = true;
        this._startPing();
        this._settle(null, this.token);
        this.emit('connected', this.token);
        break;
      case 'ms.channel.unauthorized':
        this._settle(new ChannelError('unauthorized', 'The TV refused the connection. Allow this device in TV Settings › General › External Device Manager › Device Connection Manager.'));
        this.emit('unauthorized');
        break;
      case 'ms.channel.timeOut':
        this._settle(new ChannelError('timeout', 'No answer from the TV. Accept the Allow prompt on the TV screen.'));
        this.emit('timeout');
        break;
      case 'ed.installedApp.get': {
        const list = Array.isArray(data.data) ? data.data : [];
        this.emit('apps', list.filter((a) => a.appId).map((a) => ({
          id: a.appId, name: a.name || a.appId, appType: a.app_type ?? 2, icon: a.icon || null,
        })));
        break;
      }
      case 'ed.apps.icon':
        if (data.iconPath && data.imageBase64) this.emit('icon', data.iconPath, Buffer.from(data.imageBase64, 'base64'));
        break;
      default:
        if (msg.event) this.emit('event', msg.event, msg);
    }
  }

  _settle(err, value) {
    const p = this._pending;
    if (!p) return;
    this._pending = null;
    clearTimeout(p.timer);
    if (err) p.reject(err); else p.resolve(value ?? null);
  }

  _fail(err) {
    const wasConnected = this.isConnected;
    const hadSocket = this.ws !== null;
    clearInterval(this._ping);
    this._ping = null;
    this.isConnected = false;
    this._settle(err);
    if (this.ws) { const ws = this.ws; this.ws = null; ws.removeAllListeners(); ws.on('error', () => {}); try { ws.close(); } catch { /* ignore */ } }
    if (wasConnected || hadSocket) this.emit('disconnected', err);
  }

  _startPing() {
    clearInterval(this._ping);
    this._ping = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.ping();
    }, 20_000);
  }
}

module.exports = { RemoteChannel, ChannelError, isLocalAddress };
