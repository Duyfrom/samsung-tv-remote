'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const call = (method, ...args) => ipcRenderer.invoke('tv:call', method, ...args);
const on = (channel, fn) => ipcRenderer.on(channel, (_event, ...args) => fn(...args));

contextBridge.exposeInMainWorld('tv', {
  init: () => ipcRenderer.invoke('app:init'),
  onState: (fn) => on('tv:state', fn),
  onIcon: (fn) => on('tv:icon', fn),
  onChat: (fn) => on('chat:update', fn),

  send: (key) => call('send', key),
  sendText: (text) => call('sendText', text),
  movePointer: (dx, dy) => call('movePointer', dx, dy),
  click: () => call('click'),
  launch: (id) => call('launch', id),
  setVolume: (value) => call('setVolume', value),
  togglePower: () => call('togglePower'),

  startRecording: () => call('startRecording'),
  stopRecording: (name) => call('stopRecording', name),
  runShortcut: (name) => call('runShortcut', name),
  deleteShortcut: (name) => call('deleteShortcut', name),

  scan: () => call('scan'),
  select: (host) => call('select', host),
  setHost: (host) => call('setHost', host),
  setMac: (mac) => call('setMac', mac),
  reconnect: () => call('connect'),

  chatSend: (text) => ipcRenderer.invoke('chat:send', text),
  chatClear: () => ipcRenderer.invoke('chat:clear'),
  setOpenAtLogin: (on) => ipcRenderer.invoke('app:setOpenAtLogin', on),
  saveApiKey: (key) => ipcRenderer.invoke('app:saveApiKey', key),
  quit: () => ipcRenderer.invoke('app:quit'),
  resize: (height) => ipcRenderer.send('app:resize', height),
});
