'use strict';

const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');
const rest = require('../core/rest');
const wol = require('../core/wol');
const shortcuts = require('../core/shortcuts');
const { RenderingControl } = require('../core/upnp');
const { RemoteChannel, ChannelError } = require('../core/channel');
const { scan } = require('../core/discovery');
const { keyCode } = require('../core/keys');
const { TVError } = require('../core/errors');
const { dataDir, loadSettings, saveSettings } = require('../core/paths');
const { runShortcut } = require('../core/tools');

// A different name per platform so the TV (which routes replies such as app lists and icons per client
// name) never confuses this app with the macOS one when both run on the same network.
const CLIENT_NAME = process.platform === 'win32' ? 'Windows Remote' : 'Desktop Remote';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Owns the connection to one TV and everything the UI shows about it. Also the tool host for Claude:
 * resolvedHost / readyChannel / installedApps / setPower (see core/tools.js).
 *
 * status: 'noTV' | 'connecting' | 'connected' | 'waking' | 'off' | 'failed'
 * Events: 'state' (snapshot), 'icon' (path, Buffer).
 */
class TVController extends EventEmitter {
  constructor() {
    super();
    const saved = loadSettings();
    this.host = saved.host || '';
    this.mac = saved.mac || '';
    this.status = 'noTV';
    this.error = null;
    this.info = null;
    this.volume = 0;
    this.muted = false;
    this.apps = [];
    this.icons = new Map(); // icon path -> PNG Buffer
    this.pointerAvailable = false;
    this.recording = null; // steps while recording a shortcut
    this.shortcuts = shortcuts.load();
    this.discovered = [];
    this.scanning = false;

    this.channel = null;
    this.generation = 0; // bumped per connect(): a stale establish() must not touch the state
    this.offUntil = 0; // after we switch the TV off its network stays up ~25 s; that is not "on"
    this.retryTimer = null;
    this.volumeTimer = null;
    this.lastRecorded = 0;
    this.iconQueue = [];
    this.iconInFlight = null;
    this.iconTimer = null;
    this._notify = false;
  }

  start() {
    if (this.host) this.connect(); else this.scan({ autoSelect: true });
  }

  get isConnected() {
    return this.status === 'connected' && !!this.channel && this.channel.isConnected;
  }

  snapshot() {
    return {
      status: this.status,
      error: this.error,
      host: this.host,
      mac: this.mac,
      info: this.info,
      volume: this.volume,
      muted: this.muted,
      apps: this.apps,
      pointerAvailable: this.pointerAvailable,
      recording: this.recording ? this.recording.length : null,
      shortcuts: this.shortcuts,
      discovered: this.discovered,
      scanning: this.scanning,
      clientName: CLIENT_NAME,
    };
  }

  _changed() {
    if (this._notify) return;
    this._notify = true;
    queueMicrotask(() => { this._notify = false; this.emit('state', this.snapshot()); });
  }

  _set(status, error = null) {
    this.status = status;
    this.error = error;
    this._changed();
  }

  // --- connection -----------------------------------------------------------------------------

  connect() {
    clearTimeout(this.retryTimer);
    if (!this.host) { this._set('noTV'); return; }
    const gen = ++this.generation;
    this._establish(gen);
  }

  /** Called when the window is shown, so a TV switched on with its own remote shows up at once. */
  refresh() {
    if (this.isConnected) this.refreshVolume();
    else if (!['waking', 'connecting'].includes(this.status) && this.offUntil < Date.now()) this.connect();
  }

  async _establish(gen) {
    const live = () => gen === this.generation;
    // Background retries while the TV is off stay quiet instead of flashing "Connecting…".
    if (this.status === 'noTV' || this.status === 'connected') this._set('connecting');
    const host = this.host;
    try {
      const info = await rest.info(host, { timeout: 2500 });
      if (!live()) return;
      this.info = info;
      if (!this.mac) {
        this.mac = info.wifiMac || (await wol.macAddress(host)) || '';
        if (this.mac) saveSettings({ mac: this.mac });
      }
      const saved = loadSettings();
      const channel = new RemoteChannel({
        host,
        transport: info.tokenAuthSupport ? 'secure' : 'plain',
        appName: CLIENT_NAME,
        token: (saved.tokens || {})[host] || null,
      });
      channel.on('apps', (list) => {
        if (channel !== this.channel) return;
        this.apps = list; // already in the user's Smart Hub order
        this._changed();
        this._loadIcons(list);
      });
      channel.on('icon', (iconPath, png) => {
        if (channel !== this.channel) return;
        this._storeIcon(iconPath, png, true);
        if (this.iconInFlight === iconPath) this.iconInFlight = null;
        this._requestNextIcon();
      });
      channel.on('event', (name) => {
        if (channel !== this.channel) return;
        if (name === 'ms.remote.touchEnable') { this.pointerAvailable = true; this._changed(); }
        if (name === 'ms.remote.touchDisable') { this.pointerAvailable = false; this._changed(); }
      });
      channel.on('disconnected', () => {
        if (channel !== this.channel) return;
        this.channel = null;
        this.pointerAvailable = false;
        this.iconInFlight = null;
        if (this.status === 'connected') {
          this._set('connecting');
          this._scheduleRetry(2000);
        }
      });

      if (this.channel) this.channel.disconnect();
      this.channel = channel;
      const token = await channel.connect();
      if (!live() || channel !== this.channel) return;
      if (token && token !== (saved.tokens || {})[host]) {
        saveSettings({ tokens: { ...(saved.tokens || {}), [host]: token } });
      }
      this._set('connected');
      channel.requestInstalledApps();
      await this.refreshVolume();
    } catch (err) {
      if (!live()) return;
      this.channel = null;
      if (err instanceof ChannelError && err.kind !== 'closed') {
        this._set('failed', err.message);
        this._scheduleRetry(15_000);
      } else {
        // No answer on :8001 – the TV is off (or not on this network).
        this._set('off');
        this._scheduleRetry(8000);
      }
    }
  }

  _scheduleRetry(ms) {
    clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => {
      if (this.offUntil > Date.now()) return this._scheduleRetry(this.offUntil - Date.now() + 1000);
      this.connect();
    }, ms);
  }

  // --- power ----------------------------------------------------------------------------------

  togglePower() {
    if (this.isConnected) this._turnOff(); else this._turnOn();
  }

  _turnOff() {
    const channel = this.channel;
    channel.sendKey('KEY_POWER');
    this.offUntil = Date.now() + 35_000;
    this.channel = null;
    this.pointerAvailable = false;
    this.generation++;
    this._set('off');
    // Keep the socket open briefly: the TV drops a command if the client hangs up right away.
    setTimeout(() => channel.disconnect(), 1200);
    this._scheduleRetry(36_000);
  }

  _turnOn() {
    const shuttingDown = this.offUntil > Date.now();
    this.offUntil = 0;
    clearTimeout(this.retryTimer);
    const gen = ++this.generation;
    this._set('waking');
    const { host, mac } = this;
    (async () => {
      const reachable = () => rest.info(host, { timeout: 1500 }).then(() => true, () => false);
      // Still in its shutdown window the TV ignores Wake-on-LAN but accepts the power key.
      if (shuttingDown && await reachable()) {
        await this._establish(gen);
        if (gen === this.generation && this.isConnected) this.channel.sendKey('KEY_POWER');
        return;
      }
      for (let i = 0; i < 20 && gen === this.generation; i++) {
        if (mac) await wol.wake(mac, host).catch(() => {});
        if (await reachable()) break;
        await sleep(1000);
      }
      if (gen === this.generation) await this._establish(gen);
    })();
  }

  // --- remote ---------------------------------------------------------------------------------

  /** `name` is a key name (`home`, `volumeUp`, `5`) or a raw KEY_* code. */
  send(name) {
    if (!this.isConnected) return;
    this._record('key', name);
    if (name === 'volumeUp' || name === 'volumeDown') {
      // Step the absolute UPnP volume instead of sending the key: the TV drops repeat volume keys while its
      // volume bar animates in, so quick clicks got lost. It still shows the volume bar.
      this.setVolume(Math.min(100, Math.max(0, Math.round(this.volume) + (name === 'volumeUp' ? 1 : -1))));
    } else {
      this.channel.sendKey(keyCode(name));
      if (name === 'mute') this._refreshVolumeSoon();
    }
  }

  sendText(text) {
    if (!this.isConnected || !text) return;
    this._record('text', text);
    this.channel.sendText(text);
  }

  movePointer(dx, dy) { if (this.isConnected) this.channel.moveMouse(Math.round(dx), Math.round(dy)); }
  click() { if (this.isConnected) this.channel.click(); }

  launch(appId) {
    if (!this.isConnected) return;
    const app = this.apps.find((a) => a.id === appId);
    if (!app) return;
    this._record('launch_app', app.id);
    // REST launch answers "ok" for native apps without opening them, so always use the socket.
    this.channel.launchApp(app.id, app.appType);
  }

  // --- volume ---------------------------------------------------------------------------------

  setVolume(value) {
    this.volume = value;
    this._changed();
    clearTimeout(this.volumeTimer);
    this.volumeTimer = setTimeout(() => {
      new RenderingControl(this.host).setVolume(value).catch(() => {});
    }, 120);
  }

  async refreshVolume() {
    if (!this.host) return;
    const rc = new RenderingControl(this.host);
    try { this.volume = await rc.volume(); } catch { /* keep the last value */ }
    try { this.muted = await rc.isMuted(); } catch { /* keep the last value */ }
    this._changed();
  }

  /** The renderer's volume lags the key by up to ~1 s, so read it twice. */
  async _refreshVolumeSoon() {
    await sleep(500);
    await this.refreshVolume();
    await sleep(800);
    await this.refreshVolume();
  }

  // --- app icons --------------------------------------------------------------------------------

  _iconFile(iconPath) {
    return path.join(dataDir(), 'icons', iconPath.replace(/[^A-Za-z0-9._-]/g, '_'));
  }

  _storeIcon(iconPath, png, persist) {
    this.icons.set(iconPath, png);
    this.emit('icon', iconPath, png);
    if (persist) {
      try {
        fs.mkdirSync(path.dirname(this._iconFile(iconPath)), { recursive: true });
        fs.writeFileSync(this._iconFile(iconPath), png);
      } catch { /* the cache is optional */ }
    }
  }

  _loadIcons(list) {
    for (const iconPath of list.map((a) => a.icon).filter(Boolean)) {
      if (this.icons.has(iconPath)) continue;
      try {
        this._storeIcon(iconPath, fs.readFileSync(this._iconFile(iconPath)), false);
      } catch {
        if (!this.iconQueue.includes(iconPath)) this.iconQueue.push(iconPath);
      }
    }
    this._requestNextIcon();
  }

  /** One request in flight at a time: during a burst of icon requests the TV drops remote keys. */
  _requestNextIcon() {
    if (this.iconInFlight || !this.iconQueue.length || !this.channel || !this.channel.isConnected) return;
    const iconPath = this.iconQueue.shift();
    this.iconInFlight = iconPath;
    this.channel.requestIcon(iconPath);
    clearTimeout(this.iconTimer);
    this.iconTimer = setTimeout(() => {
      if (this.iconInFlight !== iconPath) return;
      this.iconInFlight = null;
      this._requestNextIcon();
    }, 3000);
  }

  // --- shortcut recording ---------------------------------------------------------------------

  startRecording() {
    this.recording = [];
    this.lastRecorded = 0;
    this._changed();
  }

  /** Stops recording; saves the steps under `name` unless it is empty. */
  stopRecording(name = '') {
    const steps = this.recording;
    this.recording = null;
    const label = String(name).trim();
    if (steps && steps.length && label) shortcuts.save({ name: label, steps });
    this.reloadShortcuts();
  }

  reloadShortcuts() {
    this.shortcuts = shortcuts.load();
    this._changed();
  }

  deleteShortcut(name) {
    shortcuts.remove(name);
    this.reloadShortcuts();
  }

  runShortcut(name) {
    const shortcut = shortcuts.find(name);
    if (shortcut) runShortcut(shortcut, this).catch(() => {});
  }

  /** Pauses longer than 1.5 s become wait steps, so an app gets the time it needed to open on replay. */
  _record(action, value) {
    if (!this.recording) return;
    const now = Date.now();
    if (this.lastRecorded) {
      const gap = (now - this.lastRecorded) / 1000;
      if (gap >= 1.5) this.recording.push({ action: 'wait', value: String(Math.round(Math.min(gap, 10) * 2) / 2) });
    }
    this.recording.push({ action, value });
    this.lastRecorded = now;
    this._changed();
  }

  // --- discovery / settings -------------------------------------------------------------------

  async scan({ autoSelect = false } = {}) {
    if (this.scanning) return;
    this.scanning = true;
    this._changed();
    try {
      this.discovered = await scan();
      if (autoSelect && !this.host && this.discovered.length === 1) this.select(this.discovered[0].host);
    } finally {
      this.scanning = false;
      this._changed();
    }
  }

  select(host) {
    const tv = this.discovered.find((t) => t.host === host);
    this.setHost(host, tv ? tv.wifiMac || '' : '');
  }

  setHost(host, mac = '') {
    const value = String(host).trim();
    if (!value || value === this.host) return;
    this.host = value;
    this.mac = mac;
    this.apps = [];
    this.info = null;
    saveSettings({ host: value, mac });
    this.connect();
  }

  setMac(mac) {
    this.mac = String(mac).trim();
    saveSettings({ mac: this.mac });
    this._changed();
  }

  shutdown() {
    this.generation++;
    clearTimeout(this.retryTimer);
    clearTimeout(this.volumeTimer);
    clearTimeout(this.iconTimer);
    if (this.channel) this.channel.disconnect();
  }

  // --- tool host (core/tools.js) --------------------------------------------------------------

  async resolvedHost() {
    if (!this.host) throw new TVError('No TV selected yet – pick one in TV Remote\'s settings.');
    return this.host;
  }

  async readyChannel() {
    if (this.isConnected) return this.channel;
    this.connect();
    for (let i = 0; i < 40; i++) {
      if (this.isConnected) return this.channel;
      await sleep(250);
    }
    throw new TVError(this.status === 'off' ? 'The TV is off. Turn it on first.' : `Can't reach the TV at ${this.host}.`);
  }

  async installedApps() {
    const channel = await this.readyChannel();
    if (!this.apps.length) {
      channel.requestInstalledApps();
      for (let i = 0; i < 16 && !this.apps.length; i++) await sleep(250);
    }
    if (!this.apps.length) throw new TVError('The TV did not send its app list.');
    return this.apps;
  }

  async setPower(on) {
    if (on) {
      if (this.isConnected) return 'The TV is already on.';
      this.togglePower();
      for (let i = 0; i < 180; i++) {
        if (this.isConnected) return 'The TV is on.';
        await sleep(250);
      }
      throw new TVError('The TV didn\'t wake up.');
    }
    if (!this.isConnected) return 'The TV is already off.';
    this.togglePower();
    return 'The TV is switching off.';
  }
}

module.exports = { TVController, CLIENT_NAME };
