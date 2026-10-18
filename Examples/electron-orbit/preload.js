const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("orbit", {
  listNotes: () => ipcRenderer.invoke("notes:list"),
  addNote: (text) => ipcRenderer.invoke("notes:add", text),
  exportNotes: () => ipcRenderer.invoke("notes:export"),
  openFile: () => ipcRenderer.invoke("file:open"),
  echoBytes: (bytes) => ipcRenderer.invoke("bytes:echo", bytes),
  apiStatus: () => ipcRenderer.invoke("api:status"),
  probeRead: (file) => ipcRenderer.invoke("probe:read", file),
  probeFetch: (url) => ipcRenderer.invoke("probe:fetch", url),
  openLink: (url) => ipcRenderer.invoke("link:open", url),
  notify: (body) => ipcRenderer.invoke("notify", body),
  copy: (text) => ipcRenderer.invoke("copy", text),
  ping: (n) => ipcRenderer.send("ping", n),
  versionSync: () => ipcRenderer.sendSync("version:sync"),
  on: (channel, listener) => {
    const wrapped = (_event, ...args) => listener(...args);
    ipcRenderer.on(channel, wrapped);
    return () => ipcRenderer.removeListener(channel, wrapped);
  },
  platform: process.platform,
});
