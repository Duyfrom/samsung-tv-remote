'use strict';

const path = require('node:path');
const { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage, screen, safeStorage, shell } = require('electron');

const { dataDir, loadSettings, saveSettings } = require('../core/paths');

// Keep settings, shortcuts and the icon cache in the folder the MCP server and the macOS app also use.
app.setName('TV Remote');
app.setPath('userData', dataDir());

const { TVController } = require('./controller');
const { ClaudeChat, MODEL } = require('./chat');
const { resolveApiKey } = require('./apikey');

const ROOT = path.join(__dirname, '..', '..');
const asset = (name) => path.join(ROOT, 'build', name);
const startHidden = process.argv.includes('--hidden');

let win = null;
let tray = null;
let quitting = false;

const controller = new TVController();
const chat = new ClaudeChat({ controller, getApiKey: () => resolveApiKey(savedKey()) });

// --- API key saved in this app (OS keystore: DPAPI on Windows, Keychain on macOS) ---------------

function savedKey() {
  const enc = loadSettings().apiKeyEnc;
  if (!enc || !safeStorage.isEncryptionAvailable()) return null;
  try { return safeStorage.decryptString(Buffer.from(enc, 'base64')); } catch { return null; }
}

function mcpCommand() {
  const server = path.join(app.getAppPath(), 'src', 'mcp', 'server.js');
  if (app.isPackaged) {
    // The app's own executable runs the script as plain Node.
    return `claude mcp add tv-remote -s user -e ELECTRON_RUN_AS_NODE=1 -- "${process.execPath}" "${server}"`;
  }
  return `claude mcp add tv-remote -s user -- node "${server}"`;
}

function settingsExtras() {
  const { source } = resolveApiKey(savedKey());
  return {
    model: MODEL,
    keySource: source,
    keyEncryptable: safeStorage.isEncryptionAvailable(),
    mcpCommand: mcpCommand(),
    packaged: app.isPackaged,
    openAtLogin: app.isPackaged ? app.getLoginItemSettings().openAtLogin : false,
    platform: process.platform,
    version: app.getVersion(),
  };
}

// --- window & tray -------------------------------------------------------------------------------

function createWindow() {
  win = new BrowserWindow({
    width: 340,
    height: 760,
    useContentSize: true,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    show: false,
    title: 'TV Remote',
    icon: asset(process.platform === 'win32' ? 'icon.ico' : 'icon.png'),
    backgroundColor: '#1c1c1e',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
  });
  win.removeMenu();
  win.loadFile(path.join(ROOT, 'src', 'renderer', 'index.html'));
  // External links (none today) open in the browser, never in the app window.
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
  win.on('close', (event) => {
    if (quitting) return;
    event.preventDefault(); // closing hides to the tray; Quit is in the tray menu and Settings
    win.hide();
  });
}

function showWindow({ nearTray = false } = {}) {
  if (!win) return;
  if (nearTray && tray && !win.isVisible()) positionNearTray();
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
  controller.refresh();
}

function positionNearTray() {
  const bounds = tray.getBounds();
  if (!bounds.width) return;
  const [width, height] = win.getSize();
  const area = screen.getDisplayNearestPoint({ x: bounds.x, y: bounds.y }).workArea;
  const x = Math.round(Math.min(Math.max(bounds.x + bounds.width / 2 - width / 2, area.x), area.x + area.width - width));
  const below = bounds.y < area.y + area.height / 2; // tray at the top (macOS) or taskbar at the bottom (Windows)
  const y = below ? bounds.y + bounds.height + 4 : bounds.y - height - 4;
  win.setPosition(x, Math.round(Math.min(Math.max(y, area.y), area.y + area.height - height)));
}

function quit() {
  quitting = true;
  app.quit();
}

function trayIcon(connected) {
  return nativeImage.createFromPath(asset(connected ? 'tray.png' : 'tray-off.png'));
}

function createTray() {
  tray = new Tray(trayIcon(false));
  tray.setToolTip('TV Remote');
  tray.on('click', () => {
    if (win.isVisible() && win.isFocused()) win.hide(); else showWindow({ nearTray: true });
  });
  tray.on('right-click', () => {
    const connected = controller.isConnected;
    tray.popUpContextMenu(Menu.buildFromTemplate([
      { label: 'Show remote', click: () => showWindow({ nearTray: true }) },
      { label: connected ? 'Turn TV off' : 'Turn TV on', enabled: !!controller.host && controller.status !== 'waking', click: () => controller.togglePower() },
      { type: 'separator' },
      { label: 'Quit TV Remote', click: quit },
    ]));
  });
}

const STATUS_TEXT = {
  noTV: 'no TV selected',
  connecting: 'connecting…',
  connected: 'connected',
  waking: 'waking the TV…',
  off: 'TV is off',
  failed: 'can\'t connect',
};

// --- IPC --------------------------------------------------------------------------------------------

/** The renderer may call these controller methods, nothing else. */
const CALLABLE = new Set([
  'send', 'sendText', 'movePointer', 'click', 'launch', 'setVolume', 'togglePower', 'startRecording', 'stopRecording',
  'runShortcut', 'deleteShortcut', 'scan', 'select', 'setHost', 'setMac', 'connect',
]);

function iconURL(png) {
  return `data:image/png;base64,${png.toString('base64')}`;
}

function wireIpc() {
  ipcMain.handle('tv:call', (_event, method, ...args) => {
    if (!CALLABLE.has(method)) throw new Error(`Unknown method ${method}`);
    return controller[method](...args);
  });
  ipcMain.handle('app:init', () => ({
    state: controller.snapshot(),
    chat: chat.snapshot(),
    extras: settingsExtras(),
    icons: Object.fromEntries([...controller.icons].map(([p, png]) => [p, iconURL(png)])),
  }));
  ipcMain.handle('chat:send', (_e, text) => chat.send(text));
  ipcMain.handle('chat:clear', () => chat.clear());
  ipcMain.handle('app:setOpenAtLogin', (_e, on) => {
    if (app.isPackaged) app.setLoginItemSettings({ openAtLogin: !!on, args: ['--hidden'] });
    return settingsExtras();
  });
  ipcMain.handle('app:saveApiKey', (_e, key) => {
    const value = String(key || '').trim();
    if (!value) saveSettings({ apiKeyEnc: null });
    else if (safeStorage.isEncryptionAvailable()) saveSettings({ apiKeyEnc: safeStorage.encryptString(value).toString('base64') });
    return settingsExtras();
  });
  ipcMain.handle('app:quit', () => quit());
  ipcMain.handle('app:hide', () => win.hide());
  ipcMain.on('app:resize', (_e, height) => {
    if (!win || win.isDestroyed()) return;
    const area = screen.getDisplayMatching(win.getBounds()).workArea;
    const h = Math.max(300, Math.min(Math.round(height), area.height - 24));
    if (win.getContentSize()[1] !== h) win.setContentSize(340, h);
  });

  const send = (channel, ...args) => { if (win && !win.isDestroyed()) win.webContents.send(channel, ...args); };
  controller.on('state', (state) => {
    send('tv:state', state);
    if (tray) {
      tray.setImage(trayIcon(state.status === 'connected'));
      tray.setToolTip(`TV Remote — ${STATUS_TEXT[state.status] || state.status}`);
    }
  });
  controller.on('icon', (iconPath, png) => send('tv:icon', iconPath, iconURL(png)));
  chat.on('update', (snapshot) => send('chat:update', snapshot));
}

// --- lifecycle --------------------------------------------------------------------------------------

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => showWindow());
  app.on('before-quit', () => { quitting = true; controller.shutdown(); });
  app.on('window-all-closed', () => { /* stays in the tray */ });
  app.on('activate', () => showWindow()); // macOS dock click

  app.whenReady().then(() => {
    if (process.platform === 'darwin') {
      Menu.setApplicationMenu(Menu.buildFromTemplate([{ role: 'appMenu' }, { role: 'editMenu' }]));
    } else {
      Menu.setApplicationMenu(null);
    }
    wireIpc();
    createWindow();
    createTray();
    win.once('ready-to-show', () => { if (!startHidden) showWindow(); });
    controller.start();

    if (!app.isPackaged) require('./debug').install({ app, controller, chat, win, quit });
  });
}
