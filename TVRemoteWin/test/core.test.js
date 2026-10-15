'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { keyCode } = require('../src/core/keys');
const youtube = require('../src/core/youtube');
const wol = require('../src/core/wol');
const { valueOf } = require('../src/core/upnp');
const { findApp, claudeTools, mcpTools, runTool, TOOLS } = require('../src/core/tools');
const { describe } = require('../src/main/chat');

test('keyCode: names, aliases and raw codes', () => {
  assert.equal(keyCode('volumeUp'), 'KEY_VOLUP');
  assert.equal(keyCode('VOLUMEDOWN'), 'KEY_VOLDOWN');
  assert.equal(keyCode('ok'), 'KEY_ENTER');
  assert.equal(keyCode('return'), 'KEY_RETURN');
  assert.equal(keyCode('back'), 'KEY_RETURN');
  assert.equal(keyCode('num5'), 'KEY_5');
  assert.equal(keyCode('5'), 'KEY_5');
  assert.equal(keyCode('key_hdmi1'), 'KEY_HDMI1');
  assert.equal(keyCode('blue'), 'KEY_CYAN');
  assert.equal(keyCode('teletext'), 'KEY_TELETEXT');
});

test('youtube.videoID: ids, watch/short/embed URLs, garbage', () => {
  const id = 'QVv3mQzlrN0';
  assert.equal(youtube.videoID(id), id);
  assert.equal(youtube.videoID(`https://www.youtube.com/watch?v=${id}&t=10s`), id);
  assert.equal(youtube.videoID(`youtube.com/watch?v=${id}`), id);
  assert.equal(youtube.videoID(`https://youtu.be/${id}?si=abc`), id);
  assert.equal(youtube.videoID(`https://www.youtube.com/shorts/${id}`), id);
  assert.equal(youtube.videoID(`https://www.youtube.com/embed/${id}`), id);
  assert.equal(youtube.videoID('@mkbhd'), null);
  assert.equal(youtube.videoID(''), null);
  assert.equal(youtube.videoID('https://example.com/'), null);
});

test('youtube.latestFromFeed: skips Shorts, unescapes titles', () => {
  const xml = `<feed><title>Marques &amp; Co</title>
    <entry><yt:videoId>SHORTSSSSS1</yt:videoId><title>a short</title><link rel="alternate" href="https://www.youtube.com/shorts/SHORTSSSSS1"/><published>2026-10-14T10:00:00+00:00</published></entry>
    <entry><yt:videoId>QVv3mQzlrN0</yt:videoId><title>Apple &quot;Homeview&quot;: Not Convinced!</title><link rel="alternate" href="https://www.youtube.com/watch?v=QVv3mQzlrN0"/><published>2026-10-13T22:42:00+00:00</published></entry>
    <entry><yt:videoId>_0G4OG39XjI</yt:videoId><title>older</title><link rel="alternate" href="https://www.youtube.com/watch?v=_0G4OG39XjI"/><published>2026-10-08T21:00:00+00:00</published></entry></feed>`;
  assert.deepEqual(youtube.latestFromFeed(xml), {
    id: 'QVv3mQzlrN0', title: 'Apple "Homeview": Not Convinced!', channel: 'Marques & Co', published: '2026-10-13',
  });
  assert.equal(youtube.latestFromFeed('<feed><title>x</title></feed>'), null);
});

test('wol.magicPacket: 6 x FF then the MAC 16 times; bad MACs rejected', () => {
  const packet = wol.magicPacket('F8:77:B8:BF:DF:BB');
  assert.equal(packet.length, 102);
  assert.deepEqual([...packet.subarray(0, 6)], [255, 255, 255, 255, 255, 255]);
  for (let i = 0; i < 16; i++) assert.equal(packet.subarray(6 + i * 6, 12 + i * 6).toString('hex'), 'f877b8bfdfbb');
  assert.equal(wol.magicPacket('f8-77-b8-bf-df-bb').length, 102);
  assert.throws(() => wol.magicPacket('not a mac'));
  assert.throws(() => wol.magicPacket('f8:77:b8:bf:df'));
});

test('wol.broadcastOf and parseArp (Windows and macOS formats)', () => {
  assert.equal(wol.broadcastOf('192.168.50.171', '255.255.255.0'), '192.168.50.255');
  assert.equal(wol.broadcastOf('10.1.2.3', '255.255.0.0'), '10.1.255.255');

  const windows = `
Interface: 192.168.50.20 --- 0x7
  Internet Address      Physical Address      Type
  192.168.50.1          04-42-1a-7a-02-e8     dynamic
  192.168.50.25         f8-77-b8-bf-df-bb     dynamic
  192.168.50.255        ff-ff-ff-ff-ff-ff     static`;
  assert.equal(wol.parseArp(windows, '192.168.50.25'), 'F8:77:B8:BF:DF:BB');
  assert.equal(wol.parseArp(windows, '192.168.50.2'), null); // not a prefix match of .25
  assert.equal(wol.parseArp(windows, '192.168.50.255'), null); // broadcast row is not a device

  const mac = '? (192.168.50.98) at c8:7f:54:8:a0:f3 on en0 ifscope [ethernet]';
  assert.equal(wol.parseArp(mac, '192.168.50.98'), 'C8:7F:54:08:A0:F3'); // macOS drops leading zeros
  assert.equal(wol.parseArp('? (192.168.50.9) at (incomplete) on en0', '192.168.50.9'), null);
});

test('upnp.valueOf', () => {
  assert.equal(valueOf('CurrentVolume', '<u:R><CurrentVolume>13</CurrentVolume>\n</u:R>'), '13');
  assert.equal(valueOf('CurrentMute', '<CurrentMute>\n 1 \n</CurrentMute>'), '1');
  assert.equal(valueOf('Missing', '<A>1</A>'), null);
});

test('tools: Claude and MCP schemas describe the same 14 tools', () => {
  assert.equal(TOOLS.length, 14);
  assert.deepEqual(claudeTools().map((t) => t.name), mcpTools().map((t) => t.name));
  for (const t of claudeTools()) {
    assert.ok(t.description.length > 20, t.name);
    assert.equal(t.input_schema.type, 'object');
    assert.ok(Array.isArray(t.input_schema.required));
  }
  assert.ok(mcpTools().every((t) => t.inputSchema && !t.input_schema));
});

test('findApp: id, accents, prefix, substring, name inside the sentence', () => {
  const apps = [
    { id: '111299001912', name: 'YouTube' }, { id: '3201707014491', name: 'FPT Play' },
    { id: '3201604008808', name: 'Galaxy Play' }, { id: '3201510005789', name: 'Bếp Nhà Ăn Ngon' },
    { id: 'org.tizen.browser', name: 'Web Browser' },
  ];
  assert.equal(findApp('youtube', apps).id, '111299001912');
  assert.equal(findApp('FPT', apps).id, '3201707014491');
  assert.equal(findApp('galaxy', apps).id, '3201604008808');
  assert.equal(findApp('bep nha an ngon', apps).id, '3201510005789');
  assert.equal(findApp('open the fpt play app', apps).id, '3201707014491');
  assert.equal(findApp('org.tizen.browser', apps).id, 'org.tizen.browser');
  assert.equal(findApp('netflix', apps), null);
  assert.equal(findApp('', apps), null);
});

test('runTool: argument validation and unknown tools come back as errors, not exceptions', async () => {
  const host = { resolvedHost: async () => '192.0.2.1', readyChannel: async () => { throw new Error('should not connect'); } };
  for (const [name, input] of [
    ['press_keys', {}], ['press_keys', { keys: [] }], ['type_text', { text: '' }], ['launch_app', {}],
    ['open_url', { url: '  ' }], ['set_volume', {}], ['mute', { muted: 'yes' }], ['power', { state: 'maybe' }],
    ['play_youtube', {}], ['run_shortcut', { name: 'nope-not-saved' }], ['save_shortcut', { name: 'x', steps: [] }],
    ['save_shortcut', { name: 'x', steps: [{ action: 'explode', value: '1' }] }], ['bogus', {}],
  ]) {
    const result = await runTool(name, input, host);
    assert.equal(result.isError, true, `${name} ${JSON.stringify(input)}`);
    assert.ok(result.text.length > 0);
  }
});

test('runTool: press_keys / type_text / open_url / launch_app drive the channel', async () => {
  const sent = [];
  const channel = {
    sendKey: (code) => sent.push(['key', code]),
    sendText: (text) => sent.push(['text', text]),
    openURL: (url) => sent.push(['url', url]),
    launchApp: (id, type, meta) => sent.push(['launch', id, type, meta]),
  };
  const host = {
    resolvedHost: async () => '192.0.2.1',
    readyChannel: async () => channel,
    installedApps: async () => [{ id: '111299001912', name: 'YouTube', appType: 2 }, { id: 'org.tizen.browser', name: 'Web Browser', appType: 4 }],
  };
  assert.equal((await runTool('press_keys', { keys: 'home, up' }, host)).isError, false); // lenient: string list
  assert.equal((await runTool('type_text', { text: 'vtv1' }, host)).text, 'Typed “vtv1”.');
  await runTool('open_url', { url: 'phimfly.com/tv' }, host);
  assert.match((await runTool('launch_app', { app: 'the youtube app', link: 'v=abc' }, host)).text, /Opened YouTube with link v=abc/);
  await runTool('launch_app', { app: 'browser' }, host);
  assert.deepEqual(sent, [
    ['key', 'KEY_HOME'], ['key', 'KEY_UP'], ['text', 'vtv1'], ['url', 'https://phimfly.com/tv'],
    ['launch', '111299001912', 2, 'v=abc'], ['launch', 'org.tizen.browser', 4, ''],
  ]);
});

test('chat.describe: action chip labels', () => {
  assert.equal(describe('press_keys', { keys: ['up', 'enter'] }), 'Keys: up enter');
  assert.equal(describe('set_volume', { change: 5 }), 'Volume +5');
  assert.equal(describe('set_volume', { change: -3 }), 'Volume -3');
  assert.equal(describe('set_volume', { level: 20 }), 'Volume 20');
  assert.equal(describe('play_youtube', { channel: '@mkbhd' }), 'YouTube → @mkbhd');
  assert.equal(describe('get_status', {}), 'Get status');
});
