const { app, BrowserWindow, ipcMain, dialog, shell, Menu, Notification, clipboard } = require("electron");
const fs = require("node:fs");
const path = require("node:path");

const notesFile = () => path.join(app.getPath("userData"), "notes.json");
const readNotes = () => { try { return JSON.parse(fs.readFileSync(notesFile(), "utf8")); } catch { return []; } };
const writeNotes = (notes) => {
  fs.mkdirSync(path.dirname(notesFile()), { recursive: true });
  fs.writeFileSync(notesFile(), JSON.stringify(notes, null, 2));
};

ipcMain.handle("notes:list", () => readNotes());
ipcMain.handle("notes:add", (_event, text) => {
  const notes = [...readNotes(), { id: Date.now(), text, created: new Date() }];
  writeNotes(notes);
  BrowserWindow.getAllWindows().forEach((w) => w.webContents.send("notes:changed", notes.length));
  return notes;
});
ipcMain.handle("notes:export", async (event) => {
  const result = await dialog.showSaveDialog(BrowserWindow.fromWebContents(event.sender), { defaultPath: "notes.json" });
  if (result.canceled || !result.filePath) return null;
  fs.writeFileSync(result.filePath, JSON.stringify(readNotes(), null, 2));
  return path.basename(result.filePath);
});
ipcMain.handle("file:open", async () => {
  const result = await dialog.showOpenDialog({ properties: ["openFile"] });
  if (result.canceled || result.filePaths.length === 0) return null;
  const file = result.filePaths[0];
  return { name: path.basename(file), size: fs.statSync(file).size, head: fs.readFileSync(file, "utf8").slice(0, 80) };
});
ipcMain.handle("bytes:echo", (_event, bytes) => ({ length: bytes.length, first: bytes[0], back: bytes }));
ipcMain.handle("api:status", async () => {
  const response = await fetch(`http://127.0.0.1:${process.env.ORBIT_API_PORT || 5198}/status`);
  return response.json();
});
ipcMain.handle("probe:read", (_event, file) => fs.readFileSync(file.replace(/^~/, require("node:os").homedir()), "utf8").slice(0, 40));
ipcMain.handle("probe:fetch", async (_event, url) => (await fetch(url)).status);
ipcMain.handle("link:open", (_event, url) => shell.openExternal(url));
ipcMain.handle("notify", (_event, body) => new Notification({ title: "Orbit", body }).show());
ipcMain.handle("copy", (_event, text) => clipboard.writeText(text));
ipcMain.on("ping", (event, n) => event.reply("pong", n + 1));
ipcMain.on("version:sync", (event) => { event.returnValue = { app: app.getVersion(), name: app.getName() }; });

function createWindow() {
  const win = new BrowserWindow({
    width: 900,
    height: 640,
    title: "Orbit",
    show: false,
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, sandbox: true },
  });
  // ORBIT_HIDDEN: for unattended runs (script/electron-e2e.mjs), no window or Dock icon on this Mac.
  win.once("ready-to-show", () => { if (!process.env.ORBIT_HIDDEN) win.show(); });
  win.webContents.on("did-finish-load", () => win.webContents.send("hello", { greeting: "Welcome to Orbit" }));
  if (process.env.ELECTRON_RENDERER_URL) win.loadURL(process.env.ELECTRON_RENDERER_URL);
  else win.loadFile(path.join(__dirname, "renderer", "index.html"));
}

if (process.env.ORBIT_HIDDEN) app.dock?.hide();
app.whenReady().then(() => {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: "Orbit", submenu: [{ role: "about" }, { type: "separator" }, { role: "quit" }] },
    {
      label: "Notes",
      submenu: [
        { label: "New Note", accelerator: "CmdOrCtrl+N", click: (_item, win) => (win || BrowserWindow.getAllWindows()[0]).webContents.send("menu:new-note") },
        { label: "Export…", click: () => BrowserWindow.getAllWindows()[0].webContents.send("menu:export") },
      ],
    },
  ]));
  createWindow();
  setInterval(() => BrowserWindow.getAllWindows().forEach((w) => w.webContents.send("tick", Date.now())), 5000);
});

app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
