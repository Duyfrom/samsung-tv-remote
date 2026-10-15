'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Point the stores at a throwaway folder before loading them.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tvremote-test-'));
process.env.TV_REMOTE_DATA_DIR = dir;
const shortcuts = require('../src/core/shortcuts');
const { loadSettings, saveSettings, dataDir } = require('../src/core/paths');
const { runShortcut } = require('../src/core/tools');

test.after(() => fs.rmSync(dir, { recursive: true, force: true }));

test('dataDir honours TV_REMOTE_DATA_DIR', () => {
  assert.equal(dataDir(), dir);
});

test('settings: patches merge, file is atomic JSON', () => {
  assert.deepEqual(loadSettings(), {});
  saveSettings({ host: '192.168.50.25' });
  saveSettings({ mac: 'F8:77:B8:BF:DF:BB', tokens: { '192.168.50.25': 't' } });
  assert.deepEqual(loadSettings(), { host: '192.168.50.25', mac: 'F8:77:B8:BF:DF:BB', tokens: { '192.168.50.25': 't' } });
  assert.deepEqual(fs.readdirSync(dir).filter((f) => f.endsWith('.tmp')), []);
});

test('shortcuts: save / find (accent + case insensitive) / replace / remove', () => {
  assert.deepEqual(shortcuts.load(), []);
  shortcuts.save({ name: 'VTV1', steps: [{ action: 'launch_app', value: 'FPT Play' }, { action: 'wait', value: '5' }] });
  shortcuts.save({ name: 'Phim Việt', steps: [{ action: 'key', value: 'home' }] });
  assert.equal(shortcuts.find('vtv1').name, 'VTV1');
  assert.equal(shortcuts.find('phim viet').name, 'Phim Việt');
  shortcuts.save({ name: 'vtv1', steps: [{ action: 'key', value: 'enter' }] }); // replaces, not duplicates
  assert.equal(shortcuts.load().length, 2);
  assert.deepEqual(shortcuts.find('VTV1').steps, [{ action: 'key', value: 'enter' }]);
  assert.equal(shortcuts.summary(shortcuts.find('VTV1')), 'key enter');
  shortcuts.remove('VTV1');
  assert.equal(shortcuts.find('vtv1'), null);
  assert.equal(shortcuts.load().length, 1);
});

test('shortcuts: file written by the macOS app (same format) loads', () => {
  fs.writeFileSync(path.join(dir, 'shortcuts.json'), JSON.stringify([
    { name: 'Test YouTube', steps: [{ action: 'launch_app', value: 'youtube' }, { action: 'wait', value: '2' }] },
  ], null, 2));
  assert.equal(shortcuts.load()[0].steps[1].action, 'wait');
});

test('runShortcut replays every step kind in order', async () => {
  const sent = [];
  const channel = {
    sendKey: (c) => sent.push(`key:${c}`), sendText: (t) => sent.push(`text:${t}`),
    openURL: (u) => sent.push(`url:${u}`), launchApp: (id) => sent.push(`launch:${id}`),
  };
  const host = { readyChannel: async () => channel, installedApps: async () => [{ id: 'A1', name: 'FPT Play', appType: 2 }] };
  await runShortcut({ name: 'x', steps: [
    { action: 'launch_app', value: 'fpt' }, { action: 'wait', value: '0' }, { action: 'key', value: 'down' },
    { action: 'text', value: 'vtv1' }, { action: 'open_url', value: 'https://example.com' },
  ] }, host);
  assert.deepEqual(sent, ['launch:A1', 'key:KEY_DOWN', 'text:vtv1', 'url:https://example.com']);
});
