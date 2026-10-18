const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('companion', Object.freeze({
  call: (method, body = {}) => ipcRenderer.invoke('companion:call', method, body),
  choose: kind => ipcRenderer.invoke('companion:choose', kind),
  exportPairing: () => ipcRenderer.invoke('companion:export'),
  copyPairing: () => ipcRenderer.invoke('companion:copyPairing'),
  installTerminal: () => ipcRenderer.invoke('companion:installTerminal'),
  resetPairing: () => ipcRenderer.invoke('companion:resetPairing'),
  autoStart: enabled => ipcRenderer.invoke('companion:autoStart', enabled),
  shutdown: () => ipcRenderer.invoke('companion:shutdown')
}));
