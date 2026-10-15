'use strict';

// window.tv for the Go host: calls go to bridge() in gui_windows.go via WebView2's postMessage and come back
// through window.__tvReply; state pushes arrive through window.__tvEvent. Same API the Electron preload had.
(() => {
  const host = window.chrome.webview;
  const pending = new Map();
  const listeners = { state: [], icon: [], chat: [] };
  let seq = 0;

  window.__tvReply = ({ id, result, error }) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (error) p.reject(new Error(error)); else p.resolve(result);
  };
  window.__tvEvent = ({ event, args }) => (listeners[event] || []).forEach((fn) => fn(...args));

  const call = (method, ...args) => new Promise((resolve, reject) => {
    const id = ++seq;
    pending.set(id, { resolve, reject });
    host.postMessage(JSON.stringify({ id, method, args }));
  });

  const tv = {
    init: () => call('init'),
    onState: (fn) => listeners.state.push(fn),
    onIcon: (fn) => listeners.icon.push(fn),
    onChat: (fn) => listeners.chat.push(fn),
    reconnect: () => call('connect'),
  };
  for (const method of ['send', 'sendText', 'movePointer', 'click', 'launch', 'setVolume', 'togglePower', 'startRecording',
    'stopRecording', 'runShortcut', 'deleteShortcut', 'scan', 'select', 'setHost', 'setMac', 'chatSend', 'chatClear',
    'setOpenAtLogin', 'saveApiKey', 'quit', 'resize']) {
    tv[method] = (...args) => call(method, ...args);
  }
  window.tv = tv;
})();
