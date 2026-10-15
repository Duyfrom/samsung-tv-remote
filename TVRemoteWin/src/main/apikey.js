'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

/**
 * The Anthropic API key, read when needed – never copied – from, in order:
 *   1. opencode's auth store (`~/.local/share/opencode/auth.json`, plus the Windows AppData locations)
 *   2. a key saved in this app's settings (encrypted with the OS keystore; passed in as `savedKey`)
 *   3. $ANTHROPIC_API_KEY
 */
function opencodeAuthFiles() {
  const home = os.homedir();
  const files = [
    process.env.XDG_DATA_HOME && path.join(process.env.XDG_DATA_HOME, 'opencode', 'auth.json'),
    path.join(home, '.local', 'share', 'opencode', 'auth.json'),
  ];
  if (process.platform === 'win32') {
    files.push(
      process.env.APPDATA && path.join(process.env.APPDATA, 'opencode', 'auth.json'),
      process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'opencode', 'auth.json'),
    );
  }
  return files.filter(Boolean);
}

function fromOpencode() {
  for (const file of opencodeAuthFiles()) {
    try {
      const a = JSON.parse(fs.readFileSync(file, 'utf8')).anthropic;
      if (a && a.type === 'api' && typeof a.key === 'string' && a.key) return a.key;
    } catch { /* not there / not JSON */ }
  }
  return null;
}

/** `{ key, source }` or `{ key: null, source: null }`. */
function resolveApiKey(savedKey = null) {
  const opencode = fromOpencode();
  if (opencode) return { key: opencode, source: 'opencode' };
  if (savedKey) return { key: savedKey, source: 'saved in this app' };
  if (process.env.ANTHROPIC_API_KEY) return { key: process.env.ANTHROPIC_API_KEY, source: 'ANTHROPIC_API_KEY' };
  return { key: null, source: null };
}

module.exports = { resolveApiKey, opencodeAuthFiles };
