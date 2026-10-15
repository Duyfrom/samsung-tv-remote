'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

/**
 * Where the app and the MCP server keep their small shared files (settings, shortcuts, icon cache).
 * Same folder as the macOS app: shortcuts recorded there are the same file.
 *   Windows  %APPDATA%\TV Remote
 *   macOS    ~/Library/Application Support/TV Remote
 *   other    ~/.config/TV Remote
 */
function dataDir() {
  if (process.env.TV_REMOTE_DATA_DIR) return process.env.TV_REMOTE_DATA_DIR;
  const home = os.homedir();
  if (process.platform === 'win32') return path.join(process.env.APPDATA || path.join(home, 'AppData', 'Roaming'), 'TV Remote');
  if (process.platform === 'darwin') return path.join(home, 'Library', 'Application Support', 'TV Remote');
  return path.join(process.env.XDG_CONFIG_HOME || path.join(home, '.config'), 'TV Remote');
}

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file); // atomic: the app and the MCP server both read these
}

/** settings.json: `{ host, mac, tokens: { <host>: token }, apiKeyEnc }`. Read fresh each time. */
const settingsFile = () => path.join(dataDir(), 'settings.json');
const loadSettings = () => readJSON(settingsFile(), {});
function saveSettings(patch) {
  const next = { ...loadSettings(), ...patch };
  writeJSON(settingsFile(), next);
  return next;
}

module.exports = { dataDir, readJSON, writeJSON, loadSettings, saveSettings };
