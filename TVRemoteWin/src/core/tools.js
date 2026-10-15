'use strict';

const rest = require('./rest');
const youtube = require('./youtube');
const shortcuts = require('./shortcuts');
const { RenderingControl } = require('./upnp');
const { keyCode } = require('./keys');
const { TVError } = require('./errors');

/*
 * The TV control tools shared by the in-app Claude chat and the MCP server.
 *
 * A "host" runs them and owns the TV connection:
 *   resolvedHost(): Promise<string>        the TV's IP, or throws when none is known
 *   readyChannel(): Promise<RemoteChannel> a connected channel (connecting first), or throws when the TV is off
 *   installedApps(): Promise<App[]>        apps in the user's Smart Hub order
 *   setPower(on): Promise<string>          Wake-on-LAN / power key; returns what happened
 */

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const object = (properties = {}, required = []) => ({ type: 'object', properties, required });

const TOOLS = [
  {
    name: 'press_keys',
    description: 'Press remote control buttons in order (about 0.4 s apart). Names: home, back, exit, up, down, left, '
      + 'right, enter (OK), menu, source, guide, info, tools, search, channelUp, channelDown, previousChannel, '
      + 'channelList, 0-9, red, green, yellow, blue, play, pause, stop, rewind, fastForward, record, mute, '
      + 'volumeUp, volumeDown, power — or any raw Samsung KEY_* code. The screen can\'t be seen, so menu '
      + 'navigation is blind: prefer launch_app, open_url and shortcuts when they fit.',
    schema: object({ keys: { type: 'array', items: { type: 'string' }, description: 'Button names in order' } }, ['keys']),
  },
  {
    name: 'type_text',
    description: 'Type text into the TV\'s on-screen keyboard (search boxes, browser address bar). Only works while '
      + 'that keyboard is open on the TV.',
    schema: object({ text: { type: 'string' } }, ['text']),
  },
  {
    name: 'list_apps',
    description: 'List the apps installed on the TV, in the user\'s Smart Hub order.',
    schema: object(),
  },
  {
    name: 'launch_app',
    description: 'Open an installed app by name or id. Names match loosely and ignore case and accents '
      + '("fpt" opens FPT Play, "youtube" opens YouTube). Pass `link` to open straight to content: for '
      + 'YouTube a video id or watch URL plays that video.',
    schema: object({
      app: { type: 'string', description: 'App name or id' },
      link: { type: 'string', description: 'Optional deep link / launch data, e.g. a YouTube video id' },
    }, ['app']),
  },
  {
    name: 'play_youtube',
    description: 'Play a YouTube video on the TV. Give `video` (an 11-character id or a youtube.com / youtu.be URL), '
      + 'or `channel` (an @handle such as @mkbhd, a channel id, or a name that is the channel\'s handle) to play '
      + 'that channel\'s most recent video (Shorts skipped). Use this instead of launch_app + key presses for '
      + 'YouTube content. This TV shows a "Who\'s watching?" picker on every YouTube launch, so the first '
      + 'profile is chosen automatically (set `choose_profile` to false to skip). Returns the title playing.',
    schema: object({
      video: { type: 'string' },
      channel: { type: 'string' },
      choose_profile: { type: 'boolean', description: 'Press OK on the first profile after launch (default true)' },
    }),
  },
  {
    name: 'open_url',
    description: 'Open a web page in the TV\'s Web Browser. The 2016 browser is slow and some modern sites don\'t render.',
    schema: object({ url: { type: 'string' } }, ['url']),
  },
  {
    name: 'set_volume',
    description: 'Set the TV volume (0-100) with `level`, or adjust it with `change` (e.g. 5 or -3).',
    schema: object({
      level: { type: 'integer', minimum: 0, maximum: 100 },
      change: { type: 'integer' },
    }),
  },
  {
    name: 'mute',
    description: 'Mute or unmute the TV.',
    schema: object({ muted: { type: 'boolean' } }, ['muted']),
  },
  {
    name: 'power',
    description: 'Turn the TV on (Wake-on-LAN, takes a few seconds) or off.',
    schema: object({ state: { type: 'string', enum: ['on', 'off'] } }, ['state']),
  },
  {
    name: 'get_status',
    description: 'Whether the TV is on, its volume and mute state, and which app is in front.',
    schema: object(),
  },
  {
    name: 'wait',
    description: 'Wait before the next action, e.g. 4-6 seconds for an app to finish opening.',
    schema: object({ seconds: { type: 'number', minimum: 0.5, maximum: 15 } }, ['seconds']),
  },
  {
    name: 'list_shortcuts',
    description: 'List the user\'s saved shortcuts: named action sequences that reach places the remote can\'t jump to '
      + 'directly (e.g. a channel inside FPT Play). Check these before navigating inside an app.',
    schema: object(),
  },
  {
    name: 'run_shortcut',
    description: 'Run a saved shortcut by name.',
    schema: object({ name: { type: 'string' } }, ['name']),
  },
  {
    name: 'save_shortcut',
    description: 'Save a sequence of actions as a named shortcut so it can be replayed later, e.g. after a sequence '
      + 'you ran worked and the user asks you to remember it. Each step\'s value is a key name, text to type, '
      + 'app name or id, URL, or seconds to wait.',
    schema: object({
      name: { type: 'string' },
      steps: {
        type: 'array',
        items: object({ action: { type: 'string', enum: shortcuts.ACTIONS }, value: { type: 'string' } }, ['action', 'value']),
      },
    }, ['name', 'steps']),
  },
];

const claudeTools = () => TOOLS.map((t) => ({ name: t.name, description: t.description, input_schema: t.schema }));
const mcpTools = () => TOOLS.map((t) => ({ name: t.name, description: t.description, inputSchema: t.schema }));

/** Exact id, then name equality, prefix, substring, or the name inside the query ("the fpt play app"). */
function findApp(query, apps) {
  const q = shortcuts.fold(query);
  if (!q) return null;
  const named = apps.map((app) => ({ app, name: shortcuts.fold(app.name) }));
  return apps.find((a) => a.id === query)
    || named.find((n) => n.name === q)?.app
    || named.find((n) => n.name.startsWith(q))?.app
    || named.find((n) => n.name.includes(q))?.app
    || named.find((n) => n.name && q.includes(n.name))?.app
    || null;
}

async function launch(query, link, host) {
  const apps = await host.installedApps();
  const app = findApp(query, apps);
  if (!app) throw new TVError(`No app matches “${query}”. Installed: ${apps.map((a) => a.name).join(', ')}`);
  (await host.readyChannel()).launchApp(app.id, app.appType, link || '');
  return link ? `Opened ${app.name} with link ${link}.` : `Opened ${app.name}.`;
}

async function runShortcut(shortcut, host) {
  for (const step of shortcut.steps) {
    switch (step.action) {
      case 'key':
        (await host.readyChannel()).sendKey(keyCode(step.value));
        await sleep(400);
        break;
      case 'text':
        (await host.readyChannel()).sendText(step.value);
        await sleep(500);
        break;
      case 'launch_app':
        await launch(step.value, '', host);
        break;
      case 'open_url':
        (await host.readyChannel()).openURL(step.value);
        break;
      case 'wait':
        await sleep(Math.min(20, Math.max(0, parseFloat(step.value) || 1)) * 1000);
        break;
      default:
        throw new TVError(`Unknown shortcut step “${step.action}”.`);
    }
  }
}

async function status(host) {
  const address = await host.resolvedHost();
  let info;
  try { info = await rest.info(address, { timeout: 2000 }); } catch { return `The TV at ${address} is off or unreachable.`; }
  const parts = [`${info.name} (${info.modelName}) is on at ${address}.`];
  const rc = new RenderingControl(address);
  try {
    const volume = await rc.volume();
    const muted = await rc.isMuted().catch(() => false);
    parts.push(`Volume ${volume}${muted ? ', muted' : ''}.`);
  } catch { /* volume is optional */ }
  try {
    const apps = await host.installedApps();
    const checks = await Promise.all(apps.map((a) => rest.appStatus(address, a.id).catch(() => null)));
    const front = apps.filter((_, i) => checks[i] && checks[i].visible).map((a) => a.name);
    parts.push(front.length
      ? `In front: ${front.join(', ')}.`
      : 'No Smart Hub web app is in front: it\'s TV/HDMI input, the home screen or a built-in app like the Web Browser.');
  } catch { /* apps are optional */ }
  return parts.join(' ');
}

async function perform(name, input, host) {
  switch (name) {
    case 'press_keys': {
      let keys = input.keys;
      if (typeof keys === 'string') keys = keys.split(/[\s,]+/).filter(Boolean);
      if (!Array.isArray(keys) || keys.length === 0) throw new TVError('`keys` must be a list of button names.');
      if (keys.length > 40) throw new TVError('At most 40 keys per call.');
      const channel = await host.readyChannel();
      for (const key of keys) {
        channel.sendKey(keyCode(key));
        await sleep(400);
      }
      return `Pressed ${keys.join(', ')}.`;
    }
    case 'type_text': {
      if (typeof input.text !== 'string' || !input.text) throw new TVError('`text` is empty.');
      (await host.readyChannel()).sendText(input.text);
      await sleep(500);
      return `Typed “${input.text}”.`;
    }
    case 'list_apps':
      return (await host.installedApps()).map((a) => `${a.name} (${a.id})`).join('\n');
    case 'launch_app':
      if (typeof input.app !== 'string') throw new TVError('Which app?');
      return launch(input.app, typeof input.link === 'string' ? input.link : '', host);
    case 'play_youtube': {
      const address = await host.resolvedHost();
      let id = input.video ? youtube.videoID(input.video) : null;
      let playing = '';
      if (!id && typeof input.channel === 'string' && input.channel) {
        const video = await youtube.latestVideo(input.channel);
        id = video.id;
        playing = `“${video.title}” by ${video.channel} (${video.published}) `;
      }
      if (!id) throw new TVError('Give `video` (an id or URL) or `channel` (an @handle).');
      try { await rest.info(address, { timeout: 2000 }); } catch { throw new TVError('The TV is off. Turn it on first.'); }
      await youtube.dialLaunch(address, 'YouTube', `v=${id}&t=0`);
      let note = '';
      if (input.choose_profile !== false) {
        await sleep(4500); // the picker appears within a couple of seconds
        (await host.readyChannel()).sendKey(keyCode('enter'));
        note = ' Picked the first profile.';
      }
      return `Playing ${playing}https://youtu.be/${id}.${note}`;
    }
    case 'open_url': {
      let url = String(input.url || '').trim();
      if (!url) throw new TVError('Which URL?');
      if (!url.includes('://')) url = `https://${url}`;
      (await host.readyChannel()).openURL(url);
      return `Opened ${url} in the TV's Web Browser.`;
    }
    case 'set_volume': {
      const rc = new RenderingControl(await host.resolvedHost());
      const before = await rc.volume();
      let target;
      if (Number.isFinite(input.level)) target = input.level;
      else if (Number.isFinite(input.change)) target = before + input.change;
      else throw new TVError('Give `level` or `change`.');
      await rc.setVolume(Math.max(0, Math.min(100, target)));
      // Report the old level too, so "put it back" can be undone.
      return `Volume ${before} → ${await rc.volume()}.`;
    }
    case 'mute': {
      if (typeof input.muted !== 'boolean') throw new TVError('`muted` must be true or false.');
      await new RenderingControl(await host.resolvedHost()).setMute(input.muted);
      return input.muted ? 'Muted.' : 'Unmuted.';
    }
    case 'power':
      if (!['on', 'off'].includes(input.state)) throw new TVError('`state` must be on or off.');
      return host.setPower(input.state === 'on');
    case 'get_status':
      return status(host);
    case 'wait': {
      const seconds = Math.min(15, Math.max(0.5, Number(input.seconds) || 3));
      await sleep(seconds * 1000);
      return `Waited ${seconds} s.`;
    }
    case 'list_shortcuts': {
      const all = shortcuts.load();
      return all.length ? all.map((s) => `${s.name}: ${shortcuts.summary(s)}`).join('\n') : 'No shortcuts saved yet.';
    }
    case 'run_shortcut': {
      const shortcut = typeof input.name === 'string' ? shortcuts.find(input.name) : null;
      if (!shortcut) {
        throw new TVError(`No shortcut named “${input.name || ''}”. Saved: ${shortcuts.load().map((s) => s.name).join(', ')}`);
      }
      await runShortcut(shortcut, host);
      return `Ran shortcut “${shortcut.name}”.`;
    }
    case 'save_shortcut': {
      const label = typeof input.name === 'string' ? input.name.trim() : '';
      if (!label || !Array.isArray(input.steps) || input.steps.length === 0) throw new TVError('Give a `name` and at least one step.');
      const steps = input.steps.map((step) => {
        if (!shortcuts.ACTIONS.includes(step.action)) throw new TVError(`Unknown step action ${step.action}.`);
        return { action: step.action, value: String(step.value ?? '') };
      });
      shortcuts.save({ name: label, steps });
      return `Saved shortcut “${label}” (${steps.length} steps).`;
    }
    default:
      throw new TVError(`Unknown tool ${name}.`);
  }
}

/** Runs one tool call; failures come back as text with `isError` so the model can react. */
async function runTool(name, input, host) {
  try {
    return { text: await perform(name, input || {}, host), isError: false };
  } catch (err) {
    return { text: err instanceof Error ? err.message : String(err), isError: true };
  }
}

module.exports = { TOOLS, claudeTools, mcpTools, runTool, runShortcut, findApp };
