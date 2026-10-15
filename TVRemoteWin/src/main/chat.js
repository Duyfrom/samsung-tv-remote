'use strict';

const { EventEmitter } = require('node:events');
const { claudeTools, runTool } = require('../core/tools');

const MODEL = 'claude-haiku-5-5';

const SYSTEM = `You are the voice of a TV remote. You control the user's Samsung UA49K5500 (a 2016 Tizen Smart TV) through the tools. Act right away when a request maps to tools; ask only when it is genuinely ambiguous.

You cannot see the screen. Prefer direct tools — launch_app, open_url, set_volume, mute, power and saved shortcuts — over navigating menus with press_keys. Before navigating inside an app (a channel, a show, a page of a site), call list_shortcuts: the user may have recorded the exact path. If none fits, open the app, wait 4–6 seconds for it to load, try a short best-guess key sequence, and say plainly that you are navigating blind; suggest recording a shortcut with the ● button next to the chat so it works every time. type_text only works while the TV's on-screen keyboard is open. For YouTube content ("play the latest MKBHD video", a video link) use play_youtube – it finds the video itself.

After acting, reply with one short sentence, written in the same language as the user's latest message (English in, English out; Vietnamese in, Vietnamese out) – app names don't change that.`;

/** Short label for the action chips in the transcript. */
function describe(name, input) {
  const list = (v) => (Array.isArray(v) ? v.join(' ') : String(v ?? ''));
  switch (name) {
    case 'press_keys': return `Keys: ${list(input.keys)}`;
    case 'type_text': return `Type “${input.text ?? ''}”`;
    case 'launch_app': return input.link ? `Open ${input.app} → ${input.link}` : `Open ${input.app ?? 'app'}`;
    case 'play_youtube': return `YouTube → ${input.channel || input.video || 'video'}`;
    case 'open_url': return `Browse ${input.url ?? ''}`;
    case 'set_volume':
      if (Number.isFinite(input.level)) return `Volume ${input.level}`;
      return `Volume ${Number.isFinite(input.change) ? (input.change > 0 ? `+${input.change}` : input.change) : ''}`;
    case 'mute': return input.muted === false ? 'Unmute' : 'Mute';
    case 'power': return `Power ${input.state ?? ''}`;
    case 'wait': return `Wait ${input.seconds ?? ''}s`;
    case 'run_shortcut': return `Shortcut “${input.name ?? ''}”`;
    case 'save_shortcut': return `Save shortcut “${input.name ?? ''}”`;
    default: return name.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase());
  }
}

/**
 * The chat bar's brain: sends what the user types to Claude Haiku 5.5 with the TV tools and runs the tool
 * calls on the controller until Claude is done. Raw HTTP to the Messages API.
 *
 * `history` is append-only (thinking blocks are bound to the history they were made in); it is dropped,
 * never edited, when it grows long or a request fails.
 */
class ClaudeChat extends EventEmitter {
  constructor({ controller, getApiKey }) {
    super();
    this.controller = controller;
    this.getApiKey = getApiKey;
    this.lines = [];
    this.busy = false;
    this.history = [];
    this.abort = null;
    this.seq = 0;
  }

  snapshot() {
    return { lines: this.lines, busy: this.busy };
  }

  _line(kind, text) {
    this.lines.push({ id: ++this.seq, kind, text });
    this.emit('update', this.snapshot());
  }

  _setBusy(busy) {
    this.busy = busy;
    this.emit('update', this.snapshot());
  }

  send(text) {
    const message = String(text || '').trim();
    if (!message || this.busy) return;
    this._line('user', message);
    if (this.history.length > 40) this.history = []; // start fresh rather than editing the old conversation
    this.history.push({ role: 'user', content: message });
    this._loop().catch((err) => {
      if (err.name === 'AbortError') return; // cleared by the user
      this._fail(err.name === 'TimeoutError' ? 'Claude took too long to answer.' : err.message);
    });
  }

  clear() {
    if (this.abort) this.abort.abort();
    this.abort = null;
    this.busy = false;
    this.lines = [];
    this.history = [];
    this.emit('update', this.snapshot());
  }

  _fail(message) {
    this._line('error', message);
    this.history = []; // a failed turn leaves the history unbalanced; start over next time
  }

  async _loop() {
    const { key } = this.getApiKey();
    if (!key) {
      this._fail('No Anthropic API key: expected one in opencode\'s auth.json, saved in Settings, or in $ANTHROPIC_API_KEY.');
      return;
    }
    this._setBusy(true);
    const abort = new AbortController();
    this.abort = abort;
    try {
      for (let step = 0; step < 15; step++) {
        const response = await this._request(key, abort.signal);
        if (abort.signal.aborted) return;
        const content = Array.isArray(response.content) ? response.content : [];
        this.history.push({ role: 'assistant', content });
        for (const block of content) {
          if (block.type === 'text' && block.text && block.text.trim()) this._line('assistant', block.text.trim());
        }
        if (response.stop_reason === 'refusal') { this._line('error', 'Claude declined that request.'); this.history = []; return; }
        if (response.stop_reason === 'max_tokens') { this._line('error', 'Claude\'s reply was cut off.'); this.history = []; return; }
        if (response.stop_reason !== 'tool_use') return;

        // Run the calls in order (the TV needs them sequential) and answer them all in one message.
        const results = [];
        for (const block of content.filter((b) => b.type === 'tool_use')) {
          this._line('action', describe(block.name, block.input || {}));
          const { text: output, isError } = await runTool(block.name, block.input || {}, this.controller);
          if (abort.signal.aborted) return;
          if (isError) this._line('error', output);
          results.push({ type: 'tool_result', tool_use_id: block.id, content: output, ...(isError ? { is_error: true } : {}) });
        }
        this.history.push({ role: 'user', content: results });
        this.controller.reloadShortcuts();
        await this.controller.refreshVolume();
      }
      this._line('error', 'Stopped after too many steps.');
      this.history = [];
    } finally {
      if (this.abort === abort) this.abort = null;
      if (!abort.signal.aborted) this._setBusy(false);
    }
  }

  async _request(key, signal) {
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 16000,
        // A remote has to feel instant: low effort keeps thinking short.
        output_config: { effort: 'low' },
        system: SYSTEM,
        tools: claudeTools(),
        messages: this.history,
        cache_control: { type: 'ephemeral' },
      }),
      signal: AbortSignal.any([signal, AbortSignal.timeout(60_000)]),
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`Claude API: ${(json.error && json.error.message) || `HTTP ${res.status}`}`);
    return json;
  }
}

module.exports = { ClaudeChat, MODEL, describe };
