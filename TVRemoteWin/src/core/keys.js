'use strict';

// Remote key codes accepted by Samsung Tizen TVs on the `samsung.remote.control` channel.
// Names were recovered with REA from Samsung's own PC Smart View 2 assembly
// (SmartView2.Devices.RemoteControls.TvKeyCode, 280 entries); any other KEY_* string works too.
const KEYS = {
  power: 'KEY_POWER', powerOff: 'KEY_POWEROFF', source: 'KEY_SOURCE', hdmi: 'KEY_HDMI',
  hdmi1: 'KEY_HDMI1', hdmi2: 'KEY_HDMI2', hdmi3: 'KEY_HDMI3', tv: 'KEY_TV',
  home: 'KEY_HOME', menu: 'KEY_MENU', up: 'KEY_UP', down: 'KEY_DOWN', left: 'KEY_LEFT', right: 'KEY_RIGHT',
  enter: 'KEY_ENTER', back: 'KEY_RETURN', exit: 'KEY_EXIT', info: 'KEY_INFO', tools: 'KEY_TOOLS',
  guide: 'KEY_GUIDE', search: 'KEY_SEARCH', eManual: 'KEY_EMANUAL',
  volumeUp: 'KEY_VOLUP', volumeDown: 'KEY_VOLDOWN', mute: 'KEY_MUTE',
  channelUp: 'KEY_CHUP', channelDown: 'KEY_CHDOWN', previousChannel: 'KEY_PRECH', channelList: 'KEY_CH_LIST',
  num0: 'KEY_0', num1: 'KEY_1', num2: 'KEY_2', num3: 'KEY_3', num4: 'KEY_4',
  num5: 'KEY_5', num6: 'KEY_6', num7: 'KEY_7', num8: 'KEY_8', num9: 'KEY_9', minus: 'KEY_PLUS100',
  red: 'KEY_RED', green: 'KEY_GREEN', yellow: 'KEY_YELLOW', blue: 'KEY_CYAN',
  play: 'KEY_PLAY', pause: 'KEY_PAUSE', stop: 'KEY_STOP', rewind: 'KEY_REWIND',
  fastForward: 'KEY_FF', record: 'KEY_REC',
  pictureMode: 'KEY_PMODE', soundMode: 'KEY_SOUND_MODE', aspect: 'KEY_ASPECT',
  subtitle: 'KEY_SUB_TITLE', caption: 'KEY_CAPTION', sleep: 'KEY_SLEEP',
};

const ALIASES = {
  ok: 'enter', select: 'enter', return: 'back',
  'vol+': 'volumeUp', volume_up: 'volumeUp', 'vol-': 'volumeDown', volume_down: 'volumeDown',
};

/** `KEY_*` code for a friendly name (`volumeUp`, `home`, `ok`, `5`) or a raw code (`KEY_VOLUP`). */
function keyCode(name) {
  const s = String(name).trim();
  if (s.toUpperCase().startsWith('KEY_')) return s.toUpperCase();
  const lower = s.toLowerCase();
  const known = Object.keys(KEYS).find((k) => k.toLowerCase() === lower);
  if (known) return KEYS[known];
  if (ALIASES[lower]) return KEYS[ALIASES[lower]];
  return 'KEY_' + s.toUpperCase();
}

module.exports = { KEYS, keyCode };
