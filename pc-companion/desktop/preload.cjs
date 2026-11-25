const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('companion', Object.freeze({
  call: (method, body = {}) => ipcRenderer.invoke('companion:call', method, body),
  choose: kind => ipcRenderer.invoke('companion:choose', kind),
  codexRuntime: action => ipcRenderer.invoke('companion:codexRuntime', action),
  desktopSharing: action => ipcRenderer.invoke('companion:desktopSharing', action),
  existingProjects: () => ipcRenderer.invoke('companion:projects'),
  exportPairing: () => ipcRenderer.invoke('companion:export'),
  copyPairing: () => ipcRenderer.invoke('companion:copyPairing'),
  installTerminal: () => ipcRenderer.invoke('companion:installTerminal'),
  resetPairing: () => ipcRenderer.invoke('companion:resetPairing'),
  autoStart: enabled => ipcRenderer.invoke('companion:autoStart', enabled),
  updates: (method, body = {}) => ipcRenderer.invoke('companion:updates', method, body),
  onUpdate: callback => {
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('companion:update-state', listener);
    return () => ipcRenderer.removeListener('companion:update-state', listener);
  },
  shutdown: () => ipcRenderer.invoke('companion:shutdown')
}));
