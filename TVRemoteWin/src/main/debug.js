'use strict';

/*
 * Development-only hooks (never loaded from a packaged build), driven by environment variables:
 *   TVREMOTE_SHOT=/tmp/shot            write shot-<view>.png of every tab + settings, then quit
 *   TVREMOTE_CHAT="msg || msg"         send chat messages through the real chat code path, print the transcript, quit
 *   TVREMOTE_SELFTEST=1|power          drive the controller against the real TV ("power" also switches it off and on)
 */

const fs = require('node:fs');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const err = (text) => process.stderr.write(`${text}\n`);

async function until(fn, timeout, step = 100) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (fn()) return true; await sleep(step); }
  return fn();
}

function install({ controller, chat, win, quit }) {
  const env = process.env;
  const run = async (task) => {
    try { await task(); } catch (e) { err(`debug: ${e.stack || e}`); process.exitCode = 1; }
    quit();
  };

  if (env.TVREMOTE_SHOT) {
    run(async () => {
      await until(() => controller.isConnected && controller.apps.length && controller.icons.size >= controller.apps.length, 20_000);
      await sleep(1500);
      const js = (code) => win.webContents.executeJavaScript(code);
      const shot = async (name) => {
        await sleep(400);
        fs.writeFileSync(`${env.TVREMOTE_SHOT}-${name}.png`, (await win.webContents.capturePage()).toPNG());
      };
      if (env.TVREMOTE_SHOT_CHAT) {
        chat.send(env.TVREMOTE_SHOT_CHAT);
        await sleep(300);
        await until(() => !chat.busy, 60_000);
      }
      if (env.TVREMOTE_SHOT_COMPACT) await js('document.body.classList.add("compact")');
      await sleep(300);
      err(`app height: ${await js('document.getElementById("app").offsetHeight')} px, screen avail: ${await js('screen.availHeight')} px`);
      err('layout: ' + await js(`JSON.stringify({
        innerHeight: innerHeight, docScroll: document.documentElement.scrollHeight, bodyScroll: document.body.scrollHeight,
        app: document.getElementById('app').getBoundingClientRect().height,
        chatbarBottom: document.getElementById('chatbar').getBoundingClientRect().bottom,
        formBottom: document.getElementById('chat-form').getBoundingClientRect().bottom,
        formHeight: document.getElementById('chat-form').getBoundingClientRect().height,
        controlsBottom: document.getElementById('controls').getBoundingClientRect().bottom,
        winContent: null })`));
      err('children: ' + await js(`JSON.stringify([...document.getElementById('app').children].map((c) => ({ id: c.id || c.className || c.tagName, top: Math.round(c.getBoundingClientRect().top), h: Math.round(c.getBoundingClientRect().height * 10) / 10, display: getComputedStyle(c).display })))`));
      err('app style: ' + await js(`JSON.stringify((({ height, display, paddingTop, paddingBottom, boxSizing, minHeight, maxHeight }) => ({ height, display, paddingTop, paddingBottom, boxSizing, minHeight, maxHeight }))(getComputedStyle(document.getElementById('app'))))`));
      err('window content size: ' + JSON.stringify(win.getContentSize()) + ' size: ' + JSON.stringify(win.getSize()));
      for (const tab of ['apps', 'numbers', 'type']) {
        await js(`document.querySelector('[data-tab="${tab}"]').click()`);
        await shot(tab);
      }
      await js('document.getElementById("open-settings").click()');
      await shot('settings');
      err(`shots written: status=${controller.status} apps=${controller.apps.length} icons=${controller.icons.size}`);
    });
  }

  if (env.TVREMOTE_CHAT) {
    run(async () => {
      await until(() => controller.isConnected, 15_000);
      let printed = 0;
      for (const prompt of env.TVREMOTE_CHAT.split(' || ')) {
        const started = Date.now();
        chat.send(prompt);
        await sleep(100);
        await until(() => !chat.busy, 120_000);
        for (const line of chat.lines.slice(printed)) err(`[${line.kind}] ${line.text}`);
        printed = chat.lines.length;
        err(`   (${((Date.now() - started) / 1000).toFixed(1)}s)`);
      }
    });
  }

  if (env.TVREMOTE_SELFTEST) {
    run(async () => {
      const t0 = Date.now();
      const log = (s) => err(`[${((Date.now() - t0) / 1000).toFixed(1).padStart(5)}s] ${s}`);
      const check = async (what, timeout, fn) => {
        const ok = await until(fn, timeout, 250);
        log(`${ok ? '✓' : '✗'} ${what}${ok ? '' : ` (status ${controller.status})`}`);
        return ok;
      };
      if (!await check('connected', 15_000, () => controller.isConnected)) throw new Error('not connected');
      await controller.refreshVolume();
      const v0 = Math.round(controller.volume);
      controller.send('mute');
      await sleep(1500);
      await check('KEY_MUTE → muted', 1000, () => controller.muted);
      controller.send('mute');
      await sleep(1500);
      await check('KEY_MUTE → unmuted', 1000, () => !controller.muted);
      for (let i = 0; i < 3; i++) { controller.send('volumeUp'); await sleep(60); }
      await sleep(1000);
      await controller.refreshVolume();
      await check(`3 rapid volume-up clicks → ${v0 + 3}`, 2000, () => Math.round(controller.volume) === v0 + 3);
      controller.setVolume(v0);
      await sleep(600);
      await controller.refreshVolume();
      await check(`slider back → ${v0}`, 2000, () => Math.round(controller.volume) === v0);
      await check('apps + icons loaded', 10_000, () => controller.apps.length > 0 && controller.icons.size >= controller.apps.length);

      if (env.TVREMOTE_SELFTEST === 'power') {
        log('power off'); controller.togglePower();
        await check('status off', 2000, () => controller.status === 'off');
        await sleep(8000);
        log('power on inside the shutdown window'); controller.togglePower();
        await check('reconnected (window path)', 25_000, () => controller.isConnected);
        await sleep(15_000);
        log('power off again'); controller.togglePower();
        await sleep(45_000); // past the window: the network is down
        log('power on via Wake-on-LAN'); controller.togglePower();
        await check('reconnected (WoL path)', 50_000, () => controller.isConnected);
      }
      log('done');
    });
  }
}

module.exports = { install };
