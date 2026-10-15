'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { WebSocketServer } = require('ws');

const { RemoteChannel, ChannelError } = require('../src/core/channel');
const rest = require('../src/core/rest');
const { RenderingControl } = require('../src/core/upnp');

/** A stand-in for the TV's :8001 API: websocket remote channel + REST device description. */
function fakeTV({ onConnect = (ws) => ws.send(JSON.stringify({ event: 'ms.channel.connect', data: { clients: [] } })) } = {}) {
  const received = [];
  const server = http.createServer((req, res) => {
    res.setHeader('content-type', 'application/json');
    if (req.url === '/api/v2/') {
      res.end(JSON.stringify({ name: '[TV] Fake 5 Series', device: { type: 'Samsung SmartTV', modelName: 'UA49K5500', model: '16_HAWKM_FHD', wifiMac: 'F8:77:B8:BF:DF:BB', TokenAuthSupport: 'false' } }));
    } else if (req.url === '/api/v2/applications/missing') {
      res.statusCode = 404; res.end('{}');
    } else if (req.url === '/api/v2/applications/111299001912') {
      res.end(JSON.stringify({ id: '111299001912', name: 'YouTube', running: true, visible: true }));
    } else if (req.url === '/upnp/control/RenderingControl1' && req.method === 'POST') {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        res.setHeader('content-type', 'text/xml');
        const action = req.headers.soapaction;
        if (action.includes('GetVolume')) res.end('<s:Envelope><s:Body><u:GetVolumeResponse><CurrentVolume>13</CurrentVolume></u:GetVolumeResponse></s:Body></s:Envelope>');
        else if (action.includes('GetMute')) res.end('<CurrentMute>1</CurrentMute>');
        else { received.push({ soap: action, body }); res.end('<ok/>'); }
      });
    } else { res.statusCode = 404; res.end('{}'); }
  });
  const wss = new WebSocketServer({ server });
  wss.on('connection', (ws, req) => {
    received.push({ url: req.url });
    ws.on('message', (data) => received.push(JSON.parse(data.toString())));
    onConnect(ws);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    port: server.address().port,
    received,
    wss,
    close: () => new Promise((done) => { wss.clients.forEach((c) => c.terminate()); server.close(done); }),
  })));
}

const until = async (fn, ms = 2000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (fn()) return true; await new Promise((r) => setTimeout(r, 10)); }
  return fn();
};

test('channel: connects, encodes the client name, sends keys/text/pointer/launch exactly as the TV expects', async () => {
  const tv = await fakeTV();
  const channel = new RemoteChannel({ host: '127.0.0.1', port: tv.port, appName: 'Windows Remote' });
  await channel.connect();
  assert.equal(channel.isConnected, true);
  // base64("Windows Remote") = V2luZG93cyBSZW1vdGU=, percent-encoded in the query string
  assert.ok(tv.received[0].url.endsWith('/samsung.remote.control?name=V2luZG93cyBSZW1vdGU%3D'), tv.received[0].url);

  channel.sendKey('KEY_VOLUP');
  channel.sendText('hello');
  channel.moveMouse(3, -4);
  channel.click();
  channel.launchApp('111299001912', 2, 'v=abc');
  channel.openURL('https://phimfly.com/tv');
  await until(() => tv.received.length >= 7);
  const [, key, text, move, click, launch, url] = tv.received;
  assert.deepEqual(key, { method: 'ms.remote.control', params: { Cmd: 'Click', DataOfCmd: 'KEY_VOLUP', Option: 'false', TypeOfRemote: 'SendRemoteKey' } });
  assert.deepEqual(text.params, { Cmd: Buffer.from('hello').toString('base64'), DataOfCmd: 'base64', TypeOfRemote: 'SendInputString' });
  assert.equal(move.params.TypeOfRemote, 'ProcessMouseDevice');
  assert.deepEqual([move.params.Cmd, move.params.Position.x, move.params.Position.y], ['Move', 3, -4]);
  assert.equal(click.params.Cmd, 'LeftClick');
  assert.deepEqual(launch, { method: 'ms.channel.emit', params: { event: 'ed.apps.launch', to: 'host', data: { appId: '111299001912', action_type: 'DEEP_LINK', metaTag: 'v=abc' } } });
  assert.deepEqual(url.params.data, { appId: 'org.tizen.browser', action_type: 'NATIVE_LAUNCH', metaTag: 'https://phimfly.com/tv' });
  channel.disconnect();
  await tv.close();
});

test('channel: app list and icon replies become events; other events are forwarded', async () => {
  const tv = await fakeTV({
    onConnect(ws) {
      ws.send(JSON.stringify({ event: 'ms.channel.connect', data: {} }));
      ws.on('message', (data) => {
        const m = JSON.parse(data.toString());
        if (m.params.event === 'ed.installedApp.get') {
          ws.send(JSON.stringify({ event: 'ed.installedApp.get', data: { data: [
            { appId: '111299001912', app_type: 2, icon: '/i/yt.png', name: 'YouTube' },
            { appId: 'org.tizen.browser', app_type: 4, name: 'Web Browser' }, { name: 'no id' },
          ] } }));
        } else if (m.params.event === 'ed.apps.icon') {
          ws.send(JSON.stringify({ event: 'ed.apps.icon', data: { iconPath: m.params.data.iconPath, imageBase64: Buffer.from('PNGDATA').toString('base64') } }));
          ws.send(JSON.stringify({ event: 'ms.remote.touchEnable' }));
        }
      });
    },
  });
  const channel = new RemoteChannel({ host: '127.0.0.1', port: tv.port });
  const events = { apps: null, icon: null, other: [] };
  channel.on('apps', (a) => { events.apps = a; });
  channel.on('icon', (p, buf) => { events.icon = [p, buf.toString()]; });
  channel.on('event', (name) => events.other.push(name));
  await channel.connect();
  channel.requestInstalledApps();
  await until(() => events.apps);
  assert.deepEqual(events.apps, [
    { id: '111299001912', name: 'YouTube', appType: 2, icon: '/i/yt.png' },
    { id: 'org.tizen.browser', name: 'Web Browser', appType: 4, icon: null },
  ]);
  channel.requestIcon('/i/yt.png');
  await until(() => events.icon && events.other.length);
  assert.deepEqual(events.icon, ['/i/yt.png', 'PNGDATA']);
  assert.deepEqual(events.other, ['ms.remote.touchEnable']);
  channel.disconnect();
  await tv.close();
});

test('channel: unauthorized rejects connect; server drop emits disconnected', async () => {
  const denied = await fakeTV({ onConnect: (ws) => ws.send(JSON.stringify({ event: 'ms.channel.unauthorized' })) });
  const a = new RemoteChannel({ host: '127.0.0.1', port: denied.port });
  await assert.rejects(a.connect(), (e) => e instanceof ChannelError && e.kind === 'unauthorized');
  a.disconnect();
  await denied.close();

  const tv = await fakeTV();
  const b = new RemoteChannel({ host: '127.0.0.1', port: tv.port });
  let dropped = null;
  b.on('disconnected', (e) => { dropped = e; });
  await b.connect();
  tv.wss.clients.forEach((c) => c.terminate());
  await until(() => dropped);
  assert.ok(dropped);
  assert.equal(b.isConnected, false);
  await tv.close();
});

test('channel: token is only ever put in the URL for the TLS transport', () => {
  const plain = new RemoteChannel({ host: '192.0.2.1', transport: 'plain', token: 'SECRET' });
  assert.ok(!plain.url.includes('SECRET'));
  assert.ok(plain.url.startsWith('ws://192.0.2.1:8001/'));
  const secure = new RemoteChannel({ host: '192.0.2.1', transport: 'secure', token: 'SECRET' });
  assert.ok(secure.url.startsWith('wss://192.0.2.1:8002/'));
  assert.ok(secure.url.endsWith('&token=SECRET'));
});

test('rest + upnp against a fake TV', async () => {
  const tv = await fakeTV();
  const info = await rest.info('127.0.0.1', { port: tv.port });
  assert.deepEqual([info.name, info.type, info.modelName, info.wifiMac, info.tokenAuthSupport],
    ['Fake 5 Series', 'Samsung SmartTV', 'UA49K5500', 'F8:77:B8:BF:DF:BB', false]);
  assert.equal(await rest.appStatus('127.0.0.1', 'missing', { port: tv.port }), null);
  assert.deepEqual(await rest.appStatus('127.0.0.1', '111299001912', { port: tv.port }),
    { id: '111299001912', name: 'YouTube', running: true, visible: true });
  await assert.rejects(rest.info('127.0.0.1', { port: 1, timeout: 500 }));

  const rc = new RenderingControl('127.0.0.1', { port: tv.port });
  assert.equal(await rc.volume(), 13);
  assert.equal(await rc.isMuted(), true);
  await rc.setVolume(250); // clamped to 100
  await rc.setMute(false);
  const soaps = tv.received.filter((r) => r.soap);
  assert.match(soaps[0].soap, /SetVolume/);
  assert.match(soaps[0].body, /<DesiredVolume>100<\/DesiredVolume>/);
  assert.match(soaps[1].body, /<DesiredMute>0<\/DesiredMute>/);
  await tv.close();
});
