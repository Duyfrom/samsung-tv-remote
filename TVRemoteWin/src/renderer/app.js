'use strict';

/* Renderer: plain DOM, driven by the state snapshots the main process pushes (see main/controller.js). */

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

function make(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function icon(name, size = '') {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', `ic ${size}`.trim());
  const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  use.setAttribute('href', `#i-${name}`);
  svg.appendChild(use);
  return svg;
}

const SUBTITLE = {
  noTV: () => 'Pick your TV in settings',
  connecting: (s) => `Connecting to ${s.host}…`,
  connected: (s) => [s.info && s.info.modelName, s.host].filter(Boolean).join(' · '),
  waking: () => 'Waking the TV…',
  off: () => 'Off – press ⏻ to turn on',
  failed: (s) => s.error || 'Can\'t connect to the TV',
};

let state = null;
let extras = null;
let chat = { lines: [], busy: false };
const icons = new Map();
let settingsOpen = false;
let draggingVolume = false;
let appsKey = '';
let chatKey = '';
let chipsKey = '';
let foundKey = '';

// --- header & remote ----------------------------------------------------------------------------

function renderHeader() {
  const s = state;
  $('#status-dot').className = `dot ${s.status}`;
  $('#tv-name').textContent = (s.info && s.info.name) || 'Samsung TV';
  $('#tv-sub').textContent = SUBTITLE[s.status](s);
  const power = $('#power');
  power.classList.toggle('on', s.status === 'connected');
  power.disabled = !s.host || s.status === 'waking';
  power.title = s.status === 'connected' ? 'Turn the TV off' : 'Turn the TV on (Wake-on-LAN)';
}

function renderRemote() {
  $('#controls').classList.toggle('offline', state.status !== 'connected');
  const speaker = state.muted ? '#i-speaker-off' : '#i-speaker';
  $('#mute-icon use').setAttribute('href', speaker);
  $('#mute-icon-2 use').setAttribute('href', speaker);
  $('#mute-btn').classList.toggle('muted', state.muted);
  if (!draggingVolume) {
    $('#volume').value = state.volume;
    $('#volume-value').textContent = Math.round(state.volume);
  }
  $('#touchpad-hint').textContent = state.pointerAvailable
    ? 'Drag to move the pointer, tap to click'
    : 'Touchpad works in the TV\'s Web Browser';
}

function renderApps() {
  const apps = state.apps;
  const key = apps.map((a) => `${a.id}:${icons.has(a.icon) ? 1 : 0}`).join('|') + state.status;
  if (key === appsKey) return;
  appsKey = key;
  const grid = $('#apps-grid');
  grid.replaceChildren();
  if (!apps.length) {
    grid.appendChild(make('div', 'empty', state.status === 'connected' ? 'Loading apps…' : 'Apps appear once the TV is connected'));
    grid.className = '';
    return;
  }
  grid.className = 'apps-grid';
  for (const app of apps) {
    const button = make('button', 'app');
    button.title = app.name;
    const tile = make('div', 'app-icon');
    const src = app.icon && icons.get(app.icon);
    if (src) {
      const img = document.createElement('img');
      img.src = src;
      img.alt = '';
      tile.appendChild(img);
    } else {
      let hash = 0;
      for (const ch of app.id) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
      tile.style.background = `linear-gradient(135deg, hsl(${hash % 360} 55% 55%), hsl(${hash % 360} 55% 38%))`;
      tile.textContent = app.name.charAt(0).toUpperCase();
    }
    button.append(tile, make('span', '', app.name));
    button.addEventListener('click', () => window.tv.launch(app.id));
    grid.appendChild(button);
  }
}

// --- chat bar ---------------------------------------------------------------------------------

function renderChat() {
  const key = chat.lines.map((l) => l.id).join(',');
  const transcript = $('#transcript');
  transcript.classList.toggle('hidden', chat.lines.length === 0);
  if (key !== chatKey) {
    chatKey = key;
    const lines = $('#lines');
    lines.replaceChildren();
    for (const line of chat.lines) {
      const row = make('div', `line ${line.kind}`);
      if (line.kind === 'user') row.appendChild(make('span', '', line.text));
      else if (line.kind === 'action') row.append(icon('action', 'xs'), make('span', '', line.text));
      else if (line.kind === 'error') row.append(icon('warn', 'xs'), make('span', '', line.text));
      else row.textContent = line.text;
      lines.appendChild(row);
    }
    transcript.scrollTop = transcript.scrollHeight;
  }
  $('#chat-busy').classList.toggle('hidden', !chat.busy);
  $('#chat-send').classList.toggle('hidden', chat.busy);
}

function renderShortcuts() {
  const recording = state.recording !== null;
  $('#recorder').classList.toggle('hidden', !recording);
  $('#rec-count').textContent = `${state.recording || 0} step${state.recording === 1 ? '' : 's'}`;
  $('#rec-save').disabled = !state.recording;
  $('#rec-btn').disabled = recording || state.status !== 'connected';
  $('#rec-btn').classList.toggle('rec', recording);

  const list = state.shortcuts;
  const chips = $('#chips');
  chips.classList.toggle('hidden', recording || list.length === 0);
  const key = list.map((s) => s.name).join('|');
  if (key === chipsKey) return;
  chipsKey = key;
  chips.replaceChildren();
  for (const shortcut of list) {
    const chip = make('div', 'chip');
    const run = make('button', '');
    run.style.display = 'inline-flex';
    run.style.alignItems = 'center';
    run.style.gap = '5px';
    run.title = shortcut.steps.map((s) => (s.action === 'wait' ? `wait ${s.value}s` : `${s.action} ${s.value}`)).join(' → ');
    run.append(icon('bolt'), make('span', '', shortcut.name));
    run.addEventListener('click', () => window.tv.runShortcut(shortcut.name));
    const remove = make('button', 'x');
    remove.title = `Delete “${shortcut.name}”`;
    remove.setAttribute('aria-label', `Delete ${shortcut.name}`);
    remove.appendChild(icon('close', 'xs'));
    remove.addEventListener('click', () => window.tv.deleteShortcut(shortcut.name));
    chip.append(run, remove);
    chips.appendChild(chip);
  }
}

// --- settings ---------------------------------------------------------------------------------

function renderSettings() {
  $('#remote').classList.toggle('hidden', settingsOpen);
  $('#chatbar').classList.toggle('hidden', settingsOpen);
  $('#settings').classList.toggle('hidden', !settingsOpen);
  $('#open-settings use').setAttribute('href', settingsOpen ? '#i-close' : '#i-gear');
  if (!settingsOpen) return;

  const host = $('#host-input');
  if (document.activeElement !== host && host.dataset.touched !== '1') host.value = state.host;
  const mac = $('#mac-input');
  if (document.activeElement !== mac) mac.value = state.mac;
  const scan = $('#scan-btn');
  scan.disabled = state.scanning;
  scan.textContent = state.scanning ? 'Scanning…' : 'Scan';

  const key = state.discovered.map((t) => `${t.host}:${t.name}:${t.host === state.host}`).join('|') + state.scanning + state.status;
  if (key !== foundKey) {
    foundKey = key;
    const found = $('#found');
    found.replaceChildren();
    for (const tv of state.discovered) {
      const button = make('button');
      const text = make('div', 't');
      text.append(make('b', '', tv.name), make('small', '', `${tv.modelName} · ${tv.host}`));
      button.append(icon('guide'), text);
      if (tv.host === state.host) button.appendChild(icon('record', 'sm'));
      button.addEventListener('click', async () => {
        $('#host-input').dataset.touched = '';
        await window.tv.select(tv.host);
        settingsOpen = false;
        renderAll();
      });
      found.appendChild(button);
    }
    if (!state.scanning && !state.discovered.length && state.status === 'noTV') {
      found.appendChild(make('p', 'note', 'No TV found yet. Turn the TV on, make sure it\'s on the same network, then Scan.'));
    }
  }

  if (extras) {
    $('#model-name').textContent = extras.model;
    $('#key-source').textContent = extras.keySource ? `from ${extras.keySource}` : 'not found';
    $('#mcp-cmd').textContent = extras.mcpCommand;
    const login = $('#login-toggle');
    login.checked = extras.openAtLogin;
    login.disabled = !extras.packaged;
    $('#login-note').classList.toggle('hidden', extras.packaged);
    $('#key-input').disabled = !extras.keyEncryptable;
    $('#key-save').disabled = !extras.keyEncryptable;
  }

  const device = $('#device');
  device.replaceChildren();
  const info = state.info;
  const rows = info
    ? [['Model', info.modelName], ['Platform', info.model || '–'], ['Network', info.networkType || '–'],
       ['Resolution', info.resolution || '–'], ['Remote', info.tokenAuthSupport ? 'wss :8002 (token)' : 'ws :8001'],
       ['Connected as', state.clientName]]
    : [['Status', state.status]];
  for (const [label, value] of rows) {
    const row = make('div', 'kv');
    row.append(make('span', '', label), make('b', '', value));
    device.appendChild(row);
  }
}

function renderAll() {
  if (!state) return;
  if (state.status === 'noTV' && !settingsOpen && !state.host) settingsOpen = true;
  renderHeader();
  renderRemote();
  renderApps();
  renderShortcuts();
  renderChat();
  renderSettings();
}

// --- wiring -----------------------------------------------------------------------------------

function wire() {
  // Remote keys
  for (const button of $$('[data-key]')) button.addEventListener('click', () => window.tv.send(button.dataset.key));

  $('#power').addEventListener('click', () => window.tv.togglePower());
  $('#open-settings').addEventListener('click', () => { settingsOpen = !settingsOpen; renderAll(); });

  const slider = $('#volume');
  slider.addEventListener('pointerdown', () => { draggingVolume = true; });
  window.addEventListener('pointerup', () => { draggingVolume = false; });
  slider.addEventListener('input', () => {
    $('#volume-value').textContent = slider.value;
    window.tv.setVolume(Number(slider.value));
  });

  // Tabs
  for (const tab of $$('.tab')) {
    tab.addEventListener('click', () => {
      for (const t of $$('.tab')) t.classList.toggle('active', t === tab);
      for (const name of ['apps', 'numbers', 'type']) $(`#panel-${name}`).classList.toggle('hidden', name !== tab.dataset.tab);
    });
  }

  // Type + touchpad
  $('#type-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const input = $('#type-input');
    if (input.value) window.tv.sendText(input.value);
  });
  const pad = $('#touchpad');
  let last = null;
  let travelled = 0;
  pad.addEventListener('pointerdown', (e) => { pad.setPointerCapture(e.pointerId); last = { x: e.clientX, y: e.clientY }; travelled = 0; });
  pad.addEventListener('pointermove', (e) => {
    if (!last) return;
    const dx = e.clientX - last.x;
    const dy = e.clientY - last.y;
    travelled += Math.abs(dx) + Math.abs(dy);
    last = { x: e.clientX, y: e.clientY };
    window.tv.movePointer(dx * 2.5, dy * 2.5);
  });
  pad.addEventListener('pointerup', () => {
    if (last && travelled < 4) window.tv.click();
    last = null;
  });

  // Chat
  $('#chat-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const input = $('#chat-input');
    if (!input.value.trim() || chat.busy) return;
    window.tv.chatSend(input.value);
    input.value = '';
    $('#chat-send').classList.remove('ready');
  });
  $('#chat-input').addEventListener('input', (e) => $('#chat-send').classList.toggle('ready', e.target.value.trim().length > 0));
  $('#chat-clear').addEventListener('click', () => window.tv.chatClear());

  // Shortcut recording
  $('#rec-btn').addEventListener('click', () => { $('#rec-name').value = ''; window.tv.startRecording(); });
  const save = () => {
    const name = $('#rec-name').value.trim();
    if (name && state.recording) window.tv.stopRecording(name);
  };
  $('#rec-save').addEventListener('click', save);
  $('#rec-name').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); save(); } });
  $('#rec-cancel').addEventListener('click', () => window.tv.stopRecording(''));

  // Settings
  $('#host-input').addEventListener('input', (e) => { e.target.dataset.touched = '1'; });
  $('#host-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.target.dataset.touched = ''; window.tv.setHost(e.target.value); }
  });
  $('#host-input').addEventListener('blur', (e) => {
    if (e.target.dataset.touched === '1' && e.target.value.trim() && e.target.value.trim() !== state.host) {
      e.target.dataset.touched = '';
      window.tv.setHost(e.target.value);
    }
  });
  $('#mac-input').addEventListener('change', (e) => window.tv.setMac(e.target.value));
  $('#scan-btn').addEventListener('click', () => window.tv.scan());
  $('#login-toggle').addEventListener('change', async (e) => { extras = await window.tv.setOpenAtLogin(e.target.checked); renderAll(); });
  $('#key-save').addEventListener('click', async () => {
    extras = await window.tv.saveApiKey($('#key-input').value);
    $('#key-input').value = '';
    renderAll();
  });
  $('#mcp-copy').addEventListener('click', () => navigator.clipboard.writeText(extras.mcpCommand));
  $('#reconnect').addEventListener('click', () => window.tv.reconnect());
  $('#quit').addEventListener('click', () => window.tv.quit());

  // Keyboard, while the remote is in front and nothing is being typed
  document.addEventListener('keydown', (e) => {
    const t = e.target;
    if (t instanceof HTMLInputElement && t.type !== 'range' && t.type !== 'checkbox') return;
    if (!state || state.status !== 'connected' || settingsOpen || e.ctrlKey || e.metaKey || e.altKey) return;
    const named = {
      ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right',
      Enter: 'enter', Backspace: 'back', '+': 'volumeUp', '=': 'volumeUp', '-': 'volumeDown', _: 'volumeDown',
      m: 'mute', h: 'home',
    };
    const key = named[e.key] || (/^[0-9]$/.test(e.key) ? `num${e.key}` : null);
    if (!key) return;
    e.preventDefault();
    window.tv.send(key);
    const pressed = $(`[data-key="${key}"]`);
    if (pressed) { pressed.classList.add('pressed'); setTimeout(() => pressed.classList.remove('pressed'), 120); }
  });

  // The window is exactly as tall as its content.
  new ResizeObserver(() => window.tv.resize($('#app').offsetHeight)).observe($('#app'));
}

(async function start() {
  // Short screens (a 1080p laptop at 150% scaling is ~720 px tall): use the compact layout.
  if (window.screen.availHeight < 790) document.body.classList.add('compact');
  wire();
  const init = await window.tv.init();
  state = init.state;
  extras = init.extras;
  chat = init.chat;
  for (const [path, url] of Object.entries(init.icons)) icons.set(path, url);
  window.tv.onState((s) => { state = s; renderAll(); });
  window.tv.onIcon((path, url) => { icons.set(path, url); renderApps(); });
  window.tv.onChat(async (c) => {
    chat = c;
    renderChat();
    if (!c.busy && settingsOpen) extras = await window.tv.init().then((i) => i.extras);
  });
  renderAll();
})();
