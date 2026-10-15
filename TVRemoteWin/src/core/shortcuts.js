'use strict';

const path = require('node:path');
const { dataDir, readJSON, writeJSON } = require('./paths');

/**
 * A named, replayable sequence of remote actions, e.g. "VTV1" = open FPT Play, wait, arrows, OK.
 * Same JSON format as the macOS app: `[{ name, steps: [{ action, value }] }]`.
 * Actions: key | text | launch_app | open_url | wait.
 */
const ACTIONS = ['key', 'text', 'launch_app', 'open_url', 'wait'];

const file = () => path.join(dataDir(), 'shortcuts.json');
const fold = (s) => String(s).normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/gi, 'd').toLowerCase().trim();

function load() {
  const all = readJSON(file(), []);
  return Array.isArray(all) ? all.filter((s) => s && typeof s.name === 'string' && Array.isArray(s.steps)) : [];
}

const find = (name) => load().find((s) => fold(s.name) === fold(name)) || null;

function save(shortcut) {
  writeJSON(file(), [...load().filter((s) => fold(s.name) !== fold(shortcut.name)), shortcut]);
}

function remove(name) {
  writeJSON(file(), load().filter((s) => fold(s.name) !== fold(name)));
}

const summary = (s) => s.steps.map((st) => (st.action === 'wait' ? `wait ${st.value}s` : `${st.action} ${st.value}`)).join(' → ');

module.exports = { ACTIONS, load, find, save, remove, summary, fold };
