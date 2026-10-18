/*
 * OpenTraffic Electron host. Runs an Electron app's main process for a shared preview, on the app's
 * own Electron binary in Node mode (ELECTRON_RUN_AS_NODE=1), inside OpenTraffic's sandbox:
 *
 *   <Electron> electron-host.js '<config json>'
 *
 * `require('electron')` / `import 'electron'` get a stand-in: windows are recorded rather than shown
 * (their URL and preload tell OpenTraffic what to serve), ipcMain answers viewers over a WebSocket,
 * and desktop-only APIs (dialogs, shell, notifications, clipboard, menus) are handed to the viewer
 * who caused them. Everything else is a harmless no-op, so an API we don't know never crashes the app.
 *
 * Serves on 127.0.0.1:<random>, under /__opentraffic/electron/:
 *   preload.js     the browser stand-in for `electron` plus the app's preload, run first in <head>
 *   ipc            WebSocket: invoke/send/events, dialogs, menus
 *   ipc-sync       POST: ipcRenderer.sendSync (a synchronous XHR on the page)
 *   upload         POST: a file a viewer picked in an open dialog
 *   download/<id>  a file the app saved through a save dialog
 * and, when a window used loadFile, the renderer's files at /.
 *
 * Talks to OpenTraffic with lines on stdout that start with "\u0001OT " (ready, windows, want, ...)
 * and JSON lines on stdin (deny). Everything else on stdout/stderr is the app's own log.
 */
"use strict";

const Module = require("node:module");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");
const { EventEmitter } = require("node:events");
const { AsyncLocalStorage } = require("node:async_hooks");
const { pathToFileURL } = require("node:url");

const config = JSON.parse(process.argv[2] || "{}");
const APP_DIR = config.appDir;
const DATA = config.dataDir;
const SHIM_PATH = config.shimPath || path.join(__dirname, "electron-preload-shim.js");
const PREFIX = "/__opentraffic/electron/";
const pkg = readJSON(path.join(APP_DIR, "package.json")) || {};
// A finished app's main entry comes from the package.json inside its app.asar.
const MAIN = config.main || resolveMain(pkg.main);
const APP_NAME = config.name || pkg.productName || pkg.name || "App";
const APP_VERSION = pkg.version || "0.0.0";

// package.json's main, the way Node resolves it: a file, the file plus .js, or a folder's index.js.
function resolveMain(main) {
  const base = path.resolve(APP_DIR, main || "index.js");
  for (const candidate of [base, base + ".js", base + ".cjs", base + ".mjs", path.join(base, "index.js")]) {
    try { if (fs.statSync(candidate).isFile()) return candidate; } catch { /* next */ }
  }
  return base;
}

function readJSON(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}

// ---- Talking to OpenTraffic ---------------------------------------------------------------------

function tell(message) {
  try { process.stdout.write("\u0001OT " + JSON.stringify(message) + "\n"); } catch { /* closed */ }
}

const warned = new Set();
function note(what) {
  if (warned.has(what) || warned.size > 200) return;
  warned.add(what);
  console.warn(`[OpenTraffic] ${what} isn't available in a shared preview; it does nothing.`);
}

let started = false;
process.on("uncaughtException", (error) => {
  console.error("[OpenTraffic] Uncaught in the app's main process:", error);
  // Before the server is up nothing can recover: say so and stop.
  if (!started) { tell({ type: "failed", message: String(error && error.message || error) }); process.exit(1); }
});
process.on("unhandledRejection", (error) => console.error("[OpenTraffic] Unhandled rejection in the app's main process:", error));

// ---- Values over the wire -----------------------------------------------------------------------
// JSON plus the types Electron's structured clone carries that JSON doesn't. The same codec is in
// electron-preload-shim.js.

function encode(value, depth = 0) {
  if (depth > 64) return null;
  if (value === undefined) return { $ot: "undefined" };
  if (value === null || typeof value === "boolean" || typeof value === "string") return value;
  if (typeof value === "number") return Number.isFinite(value) ? value : { $ot: "number", v: String(value) };
  if (typeof value === "bigint") return { $ot: "bigint", v: value.toString() };
  if (typeof value === "function" || typeof value === "symbol") return { $ot: "undefined" };
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) return { $ot: "bytes", v: Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString("base64") };
  if (value instanceof ArrayBuffer) return { $ot: "arraybuffer", v: Buffer.from(value).toString("base64") };
  if (ArrayBuffer.isView(value)) return { $ot: "bytes", v: Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString("base64") };
  if (value instanceof Date) return { $ot: "date", v: value.getTime() };
  if (value instanceof Error) return { $ot: "error", name: value.name, message: value.message };
  if (value instanceof Map) return { $ot: "map", v: [...value].map(([k, v]) => [encode(k, depth + 1), encode(v, depth + 1)]) };
  if (value instanceof Set) return { $ot: "set", v: [...value].map((v) => encode(v, depth + 1)) };
  if (value instanceof RegExp) return { $ot: "regexp", source: value.source, flags: value.flags };
  if (Array.isArray(value)) return value.map((v) => encode(v, depth + 1));
  const out = {};
  for (const key of Object.keys(value)) out[key] = encode(value[key], depth + 1);
  return out;
}

function decode(value) {
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map(decode);
  switch (value.$ot) {
    case "undefined": return undefined;
    case "number": return Number(value.v);
    case "bigint": return BigInt(value.v);
    case "bytes": return new Uint8Array(Buffer.from(value.v, "base64"));
    case "arraybuffer": { const b = Buffer.from(value.v, "base64"); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); }
    case "date": return new Date(value.v);
    case "error": return Object.assign(new Error(value.message), { name: value.name });
    case "map": return new Map(value.v.map(([k, v]) => [decode(k), decode(v)]));
    case "set": return new Set(value.v.map(decode));
    case "regexp": return new RegExp(value.source, value.flags);
  }
  const out = {};
  for (const key of Object.keys(value)) out[key] = decode(value[key]);
  return out;
}

// ---- Harmless stand-ins for whatever we don't implement ----------------------------------------

function noop(name) {
  const fn = function () { note(name + "()"); return undefined; };
  return new Proxy(fn, {
    get(target, prop) {
      if (typeof prop === "symbol" || prop === "then") return undefined;
      if (prop in target) return target[prop];
      return noop(name + "." + prop);
    },
    construct() { note("new " + name + "()"); return withFallback(new EventEmitter(), name); },
  });
}

function withFallback(object, name) {
  return new Proxy(object, {
    get(target, prop, receiver) {
      if (typeof prop === "symbol" || prop === "then" || prop in target) return Reflect.get(target, prop, receiver);
      return noop(name + "." + prop);
    },
  });
}

// ---- Viewers ------------------------------------------------------------------------------------

const viewers = new Map(); // id -> Viewer
const viewerContext = new AsyncLocalStorage(); // the viewer whose action is running
let lastActive = null;
let loadTarget = null; // set while replaying load events for one viewer

class Viewer {
  constructor(id, window) {
    this.id = id;
    this.socket = null; // null until its WebSocket connects (sendSync can come first)
    this.queue = [];
    this.window = window;
    this.sender = withFallback(new ViewerContents(this), "webContents");
    this.requests = new Map();
    this.clipboard = "";
    this.dark = false;
  }
  get connected() { return !!this.socket && !this.socket.closed; }
  post(message) {
    if (this.connected) this.socket.send(JSON.stringify(message));
    else if (this.queue.length < 500) this.queue.push(message);
  }
  attach(socket) {
    if (this.socket && !this.socket.closed) this.socket.close();
    this.cancelRequests();
    this.socket = socket;
    const waiting = this.queue;
    this.queue = [];
    waiting.forEach((message) => this.post(message));
  }
  // Asks the viewer something (a file, a button) and waits for the answer.
  ask(kind, options) {
    const id = crypto.randomUUID();
    return new Promise((resolve) => {
      this.requests.set(id, resolve);
      this.post({ t: "request", id, kind, options: encode(options) });
    });
  }
  cancelRequests() {
    for (const resolve of this.requests.values()) resolve(null);
    this.requests.clear();
  }
}

function viewerFor(id, page) {
  let viewer = viewers.get(id);
  if (!viewer) {
    viewer = new Viewer(id, windowForPage(page));
    viewers.set(id, viewer);
  }
  return viewer;
}

function currentViewer() {
  const viewer = viewerContext.getStore() || loadTarget;
  if (viewer && viewers.has(viewer.id)) return viewer;
  if (lastActive && viewers.has(lastActive.id)) return lastActive;
  return viewers.values().next().value || null;
}

function broadcast(message, window) {
  const text = JSON.stringify(message);
  for (const viewer of viewers.values()) {
    if ((!window || viewer.window === window) && viewer.connected) viewer.socket.send(text);
  }
}

// ---- Windows ------------------------------------------------------------------------------------

let nextId = 1;
const windows = [];

class WebContents extends EventEmitter {
  constructor(window) {
    super();
    this.id = nextId++;
    this.window = window;
    this.session = session.defaultSession;
    this.mainFrame = withFallback({ url: "", processId: 1, routingId: this.id, send: (channel, ...args) => this.send(channel, ...args) }, "webFrameMain");
    this.windowOpenHandler = null;
  }
  send(channel, ...args) {
    const message = { t: "event", channel: String(channel), args: encode(args) };
    if (loadTarget && loadTarget.window === this.window) return loadTarget.post(message);
    broadcast(message, this.window);
  }
  postMessage(channel, message) { this.send(channel, message); }
  getURL() { return this.window.url || (this.window.file ? pathToFileURL(this.window.file).href : ""); }
  getTitle() { return this.window.title; }
  isLoading() { return false; }
  isDestroyed() { return this.window.destroyed; }
  isFocused() { return true; }
  isCrashed() { return false; }
  getOSProcessId() { return process.pid; }
  getProcessId() { return 1; }
  loadURL(url) { return this.window.loadURL(url); }
  loadFile(file, options) { return this.window.loadFile(file, options); }
  reload() { broadcast({ t: "reload" }, this.window); }
  setWindowOpenHandler(handler) { this.windowOpenHandler = handler; }
  executeJavaScript() { note("webContents.executeJavaScript"); return Promise.resolve(undefined); }
  openDevTools() {}
  closeDevTools() {}
  isDevToolsOpened() { return false; }
  getZoomFactor() { return 1; }
  getZoomLevel() { return 0; }
}

// What `event.sender` is for one viewer: sends go to that viewer only.
class ViewerContents extends EventEmitter {
  constructor(viewer) {
    super();
    this.viewer = viewer;
  }
  get id() { return this.viewer.window ? this.viewer.window.webContents.id : 0; }
  get session() { return session.defaultSession; }
  send(channel, ...args) { this.viewer.post({ t: "event", channel: String(channel), args: encode(args) }); }
  postMessage(channel, message) { this.send(channel, message); }
  getURL() { return this.viewer.window ? this.viewer.window.webContents.getURL() : ""; }
  getTitle() { return this.viewer.window ? this.viewer.window.title : APP_NAME; }
  isDestroyed() { return !viewers.has(this.viewer.id); }
  isLoading() { return false; }
  isFocused() { return true; }
  getOSProcessId() { return process.pid; }
  getProcessId() { return 1; }
  reload() { this.viewer.post({ t: "reload" }); }
  executeJavaScript() { return Promise.resolve(undefined); }
}

class BrowserWindow extends EventEmitter {
  constructor(options = {}) {
    super();
    this.id = nextId++;
    const web = options.webPreferences || {};
    this.preload = web.preload ? path.resolve(String(web.preload)) : null;
    this.title = options.title || APP_NAME;
    this.bounds = { x: 0, y: 0, width: options.width || 800, height: options.height || 600 };
    this.visible = options.show !== false;
    this.destroyed = false;
    this.url = null;
    this.file = null;
    this.parent = options.parent || null;
    this.raw = this;
    this.webContents = withFallback(new WebContents(this), "webContents");
    windows.push(this);
    const proxy = withFallback(this, "BrowserWindow");
    this.self = proxy;
    setImmediate(() => app.emit("browser-window-created", {}, proxy));
    return proxy;
  }
  static getAllWindows() { return windows.filter((w) => !w.destroyed).map((w) => w.self); }
  static getFocusedWindow() { const v = currentViewer(); return (v && v.window && v.window.self) || BrowserWindow.getAllWindows()[0] || null; }
  static fromWebContents(contents) {
    if (!contents) return null;
    if (contents.viewer) return contents.viewer.window ? contents.viewer.window.self : null;
    const w = windows.find((x) => x.webContents === contents || x.webContents.id === contents.id);
    return w ? w.self : null;
  }
  static fromId(id) { const w = windows.find((x) => x.id === id); return w ? w.self : null; }
  static fromBrowserView() { return null; }

  loadURL(url) {
    const text = String(url);
    if (/^file:/i.test(text)) {
      const parsed = new URL(text);
      return this.loadFile(decodeURIComponent(parsed.pathname), { hash: parsed.hash.slice(1) });
    }
    this.url = text; // http(s): a dev server; any other scheme: the app's own protocol, served here
    this.file = null;
    this.loaded();
    return Promise.resolve();
  }
  loadFile(file, options = {}) {
    this.file = path.resolve(APP_DIR, String(file));
    this.url = null;
    this.query = options.query ? new URLSearchParams(options.query).toString() : "";
    this.hash = options.hash || "";
    this.loaded();
    return Promise.resolve();
  }
  loaded() {
    reportWindows();
    setImmediate(() => {
      this.webContents.emit("did-start-loading");
      this.emit("ready-to-show");
      for (const viewer of viewers.values()) if (viewer.window === this.raw) replayLoad(viewer);
    });
  }
  show() { this.visible = true; this.emit("show"); }
  showInactive() { this.show(); }
  hide() { this.visible = false; this.emit("hide"); }
  close() { this.emit("close", { preventDefault() {} }); this.destroy(); }
  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    this.emit("closed");
    reportWindows();
    if (BrowserWindow.getAllWindows().length === 0) app.emit("window-all-closed");
  }
  isDestroyed() { return this.destroyed; }
  isVisible() { return this.visible; }
  isFocused() { return true; }
  isMinimized() { return false; }
  isMaximized() { return false; }
  isFullScreen() { return false; }
  isNormal() { return true; }
  isModal() { return false; }
  isResizable() { return true; }
  isAlwaysOnTop() { return false; }
  focus() { this.emit("focus"); }
  blur() {}
  setTitle(title) { this.title = String(title); reportWindows(); }
  getTitle() { return this.title; }
  getBounds() { return { ...this.bounds }; }
  getContentBounds() { return { ...this.bounds }; }
  setBounds(bounds) { Object.assign(this.bounds, bounds); }
  getSize() { return [this.bounds.width, this.bounds.height]; }
  getContentSize() { return this.getSize(); }
  setSize(width, height) { this.bounds.width = width; this.bounds.height = height; }
  getPosition() { return [this.bounds.x, this.bounds.y]; }
  setPosition(x, y) { this.bounds.x = x; this.bounds.y = y; }
  getParentWindow() { return this.parent; }
  getChildWindows() { return windows.filter((w) => w.parent === this.self && !w.destroyed).map((w) => w.self); }
  getNativeWindowHandle() { return Buffer.alloc(8); }
  getMediaSourceId() { return "window:" + this.id; }
}

function reportWindows() {
  tell({ type: "windows", windows: windowList() });
}

function windowList() {
  return windows.filter((w) => !w.destroyed).map((w) => ({
    id: w.id, title: w.title, url: w.url, file: w.file, preload: w.preload,
  }));
}

// The window a page belongs to: the one that loaded its path, otherwise the first.
function windowForPage(pageURL) {
  const live = windows.filter((w) => !w.destroyed);
  let pagePath = "/";
  try { pagePath = new URL(pageURL || "/", "http://x").pathname; } catch { /* keep "/" */ }
  const match = live.find((w) => {
    if (w.url) { try { return new URL(w.url).pathname === pagePath; } catch { return false; } }
    if (w.file) return "/" + path.relative(rendererRoot(), w.file).split(path.sep).join("/") === pagePath;
    return false;
  });
  return match || live[0] || null;
}

// A newly connected viewer gets the load events its window would have had.
function replayLoad(viewer) {
  const w = viewer.window;
  if (!w) return;
  loadTarget = viewer;
  try {
    viewerContext.run(viewer, () => {
      w.webContents.emit("dom-ready", {});
      w.webContents.emit("did-finish-load", {});
      w.webContents.emit("did-stop-loading", {});
    });
  } finally {
    loadTarget = null;
  }
}

// ---- Menus --------------------------------------------------------------------------------------

let applicationMenu = null;

class MenuItem {
  constructor(options = {}) {
    Object.assign(this, options);
    this.id = options.id || "item-" + nextId++;
    this.type = options.type || (options.submenu ? "submenu" : "normal");
    this.enabled = options.enabled !== false;
    this.visible = options.visible !== false;
    this.checked = !!options.checked;
    this.submenu = options.submenu ? (options.submenu instanceof Menu ? options.submenu : Menu.buildFromTemplate(expandRole(options.submenu))) : null;
    if (!this.submenu && ROLE_MENUS[options.role]) this.submenu = Menu.buildFromTemplate(ROLE_MENUS[options.role]());
    if (!this.label && options.role) this.label = roleLabel(options.role);
  }
}

class Menu extends EventEmitter {
  constructor() { super(); this.items = []; }
  static buildFromTemplate(template) {
    const menu = new Menu();
    for (const item of template || []) menu.append(item instanceof MenuItem ? item : new MenuItem(item));
    return withFallback(menu, "Menu");
  }
  static setApplicationMenu(menu) { applicationMenu = menu; broadcast({ t: "menu", menu: serializeMenu(menu) }); }
  static getApplicationMenu() { return applicationMenu; }
  static sendActionToFirstResponder() {}
  append(item) { this.items.push(item instanceof MenuItem ? item : new MenuItem(item)); }
  insert(index, item) { this.items.splice(index, 0, item instanceof MenuItem ? item : new MenuItem(item)); }
  getMenuItemById(id) { return findItem(this, (item) => item.id === id); }
  popup(options = {}) {
    const viewer = currentViewer();
    if (viewer) viewer.post({ t: "context-menu", menu: serializeMenu(this) });
    popupMenu = this;
    if (typeof options.callback === "function") setImmediate(options.callback);
  }
  closePopup() {}
}
let popupMenu = null;

function expandRole(items) { return Array.isArray(items) ? items : []; }

function roleLabel(role) {
  const labels = {
    about: `About ${APP_NAME}`, quit: `Quit ${APP_NAME}`, hide: `Hide ${APP_NAME}`, undo: "Undo", redo: "Redo",
    cut: "Cut", copy: "Copy", paste: "Paste", pasteandmatchstyle: "Paste and Match Style", selectall: "Select All",
    delete: "Delete", reload: "Reload", forcereload: "Force Reload", toggledevtools: "Toggle Developer Tools",
    resetzoom: "Actual Size", zoomin: "Zoom In", zoomout: "Zoom Out", togglefullscreen: "Toggle Full Screen",
    minimize: "Minimize", zoom: "Zoom", close: "Close Window", front: "Bring All to Front",
    appmenu: APP_NAME, filemenu: "File", editmenu: "Edit", viewmenu: "View", windowmenu: "Window", help: "Help",
  };
  return labels[String(role).toLowerCase()] || String(role);
}

const ROLE_MENUS = {
  appMenu: () => [{ role: "about" }, { type: "separator" }, { role: "hide" }, { type: "separator" }, { role: "quit" }],
  fileMenu: () => [{ role: "close" }],
  editMenu: () => [{ role: "undo" }, { role: "redo" }, { type: "separator" }, { role: "cut" }, { role: "copy" }, { role: "paste" }, { role: "selectAll" }],
  viewMenu: () => [{ role: "reload" }, { role: "toggleDevTools" }, { type: "separator" }, { role: "resetZoom" }, { role: "zoomIn" }, { role: "zoomOut" }, { type: "separator" }, { role: "togglefullscreen" }],
  windowMenu: () => [{ role: "minimize" }, { role: "zoom" }],
};

function findItem(menu, test) {
  for (const item of menu ? menu.items : []) {
    if (test(item)) return item;
    const inner = item.submenu && findItem(item.submenu, test);
    if (inner) return inner;
  }
  return null;
}

function serializeMenu(menu) {
  if (!menu) return null;
  return menu.items.filter((item) => item.visible).map((item) => ({
    id: item.id, label: item.label || "", type: item.type, role: item.role ? String(item.role).toLowerCase() : null,
    accelerator: item.accelerator ? String(item.accelerator) : null, enabled: item.enabled, checked: item.checked,
    submenu: item.submenu ? serializeMenu(item.submenu) : null,
  }));
}

function clickMenuItem(viewer, id) {
  const item = findItem(applicationMenu, (x) => x.id === id) || findItem(popupMenu, (x) => x.id === id);
  if (!item || !item.enabled) return;
  if (item.type === "checkbox") item.checked = !item.checked;
  if (item.type === "radio") item.checked = true;
  if (typeof item.click === "function") {
    viewerContext.run(viewer, () => {
      try { item.click(item, BrowserWindow.getFocusedWindow(), { triggeredByAccelerator: false }); } catch (error) { console.error(error); }
    });
  }
  if (item.type === "checkbox" || item.type === "radio") broadcast({ t: "menu", menu: serializeMenu(applicationMenu) });
}

// ---- ipcMain ------------------------------------------------------------------------------------

class IpcMain extends EventEmitter {
  constructor() { super(); this.handlers = new Map(); }
  handle(channel, handler) {
    if (this.handlers.has(channel)) throw new Error(`Attempted to register a second handler for '${channel}'`);
    this.handlers.set(channel, handler);
  }
  handleOnce(channel, handler) {
    this.handle(channel, (...args) => { this.handlers.delete(channel); return handler(...args); });
  }
  removeHandler(channel) { this.handlers.delete(channel); }
}
const ipcMain = new IpcMain();

function ipcEvent(viewer, extra = {}) {
  const frame = { url: viewer.sender.getURL(), processId: 1, routingId: viewer.sender.id, frameTreeNodeId: viewer.sender.id, send: (channel, ...args) => viewer.sender.send(channel, ...args) };
  return Object.assign({
    sender: viewer.sender, senderFrame: frame, frameId: 1, processId: 1, ports: [],
    reply: (channel, ...args) => viewer.sender.send(channel, ...args),
    preventDefault() {}, defaultPrevented: false,
  }, extra);
}

async function invoke(viewer, channel, args) {
  const handler = ipcMain.handlers.get(channel);
  if (!handler) throw new Error(`No handler registered for '${channel}'`);
  return viewerContext.run(viewer, () => handler(ipcEvent(viewer), ...args));
}

function sendSync(viewer, channel, args) {
  const event = ipcEvent(viewer);
  let returnValue;
  Object.defineProperty(event, "returnValue", { get: () => returnValue, set: (v) => { returnValue = v; }, enumerable: true });
  viewerContext.run(viewer, () => ipcMain.emit(channel, event, ...args));
  return returnValue;
}

// ---- Desktop-only APIs, handed to the viewer ----------------------------------------------------

const homeDir = path.join(DATA, "home");
const uploadsDir = path.join(homeDir, "Uploads");
const downloadsDir = path.join(homeDir, "Downloads");
const downloads = new Map(); // token -> file

function offerDownload(viewer, file) {
  const token = crypto.randomUUID();
  downloads.set(token, file);
  if (viewer) viewer.post({ t: "download", url: PREFIX + "download/" + token, name: path.basename(file) });
}

// Hands a file to the viewer once the app has finished writing it.
function watchForSave(viewer, file) {
  let last = -1;
  let stable = 0;
  const started = Date.now();
  const timer = setInterval(() => {
    let size = -1;
    try { size = fs.statSync(file).size; } catch { /* not yet */ }
    if (size >= 0 && size === last) stable++; else stable = 0;
    last = size;
    if (stable >= 2 || Date.now() - started > 10 * 60 * 1000) {
      clearInterval(timer);
      if (size >= 0) offerDownload(viewer, file);
    }
  }, 300);
}

function uniquePath(dir, name) {
  fs.mkdirSync(dir, { recursive: true });
  const ext = path.extname(name);
  const base = path.basename(name, ext) || "Untitled";
  let candidate = path.join(dir, base + ext);
  for (let i = 2; fs.existsSync(candidate); i++) candidate = path.join(dir, `${base} ${i}${ext}`);
  return candidate;
}

function dialogArgs(args) {
  return args.length > 1 || (args[0] && typeof args[0].isDestroyed === "function") ? args[1] || {} : args[0] || {};
}

const dialog = {
  async showOpenDialog(...args) {
    const options = dialogArgs(args);
    const viewer = currentViewer();
    if (!viewer) return { canceled: true, filePaths: [] };
    const answer = await viewer.ask("open", { title: options.title, buttonLabel: options.buttonLabel, properties: options.properties || [], filters: options.filters || [] });
    const paths = Array.isArray(answer && answer.filePaths) ? answer.filePaths.filter((p) => typeof p === "string" && p.startsWith(uploadsDir + path.sep)) : [];
    return { canceled: paths.length === 0, filePaths: paths };
  },
  showOpenDialogSync() { note("dialog.showOpenDialogSync"); return undefined; },
  async showSaveDialog(...args) {
    const options = dialogArgs(args);
    const name = path.basename(String(options.defaultPath || "Untitled"));
    const file = uniquePath(downloadsDir, name);
    watchForSave(currentViewer(), file);
    return { canceled: false, filePath: file };
  },
  showSaveDialogSync(...args) {
    const options = dialogArgs(args);
    const file = uniquePath(downloadsDir, path.basename(String(options.defaultPath || "Untitled")));
    watchForSave(currentViewer(), file);
    return file;
  },
  async showMessageBox(...args) {
    const options = dialogArgs(args);
    const viewer = currentViewer();
    const buttons = (options.buttons && options.buttons.length ? options.buttons : ["OK"]).map(String);
    if (!viewer) return { response: options.defaultId || 0, checkboxChecked: false };
    const answer = await viewer.ask("message", { type: options.type, title: options.title, message: options.message, detail: options.detail, buttons, defaultId: options.defaultId, cancelId: options.cancelId, checkboxLabel: options.checkboxLabel });
    const response = answer && Number.isInteger(answer.response) ? answer.response : (options.cancelId ?? buttons.length - 1);
    return { response, checkboxChecked: !!(answer && answer.checkboxChecked) };
  },
  showMessageBoxSync(...args) {
    const options = dialogArgs(args);
    const viewer = currentViewer();
    if (viewer) viewer.post({ t: "toast", title: options.title || APP_NAME, body: [options.message, options.detail].filter(Boolean).join("\n") });
    return options.defaultId || 0;
  },
  showErrorBox(title, content) {
    broadcast({ t: "toast", title: String(title), body: String(content), kind: "error" });
  },
  showCertificateTrustDialog() { return Promise.resolve(); },
};

const shell = {
  async openExternal(url) {
    const text = String(url);
    if (!/^(https?|mailto):/i.test(text)) { note("shell.openExternal for " + text.split(":")[0] + ": links"); return; }
    const viewer = currentViewer();
    if (viewer) viewer.post({ t: "open", url: text });
  },
  async openPath(file) {
    const target = path.resolve(String(file));
    if (fs.existsSync(target) && fs.statSync(target).isFile()) offerDownload(currentViewer(), target);
    return "";
  },
  showItemInFolder(file) { shell.openPath(file); },
  async trashItem(file) { fs.rmSync(String(file), { recursive: true, force: true }); },
  beep() {},
  writeShortcutLink() { return false; },
  readShortcutLink() { throw new Error("Not available"); },
};

class Notification extends EventEmitter {
  constructor(options = {}) { super(); this.title = options.title || APP_NAME; this.body = options.body || ""; this.subtitle = options.subtitle || ""; }
  static isSupported() { return true; }
  show() {
    broadcast({ t: "toast", title: String(this.title), body: [this.subtitle, this.body].filter(Boolean).join("\n") });
    setImmediate(() => this.emit("show"));
  }
  close() { this.emit("close"); }
}

const clipboard = {
  writeText(text) { const v = currentViewer(); if (v) { v.clipboard = String(text); v.post({ t: "clipboard", text: String(text) }); } },
  readText() { const v = currentViewer(); return v ? v.clipboard : ""; },
  writeHTML(html) { clipboard.writeText(String(html).replace(/<[^>]*>/g, "")); },
  readHTML() { return clipboard.readText(); },
  write(data) { if (data && data.text != null) clipboard.writeText(data.text); },
  clear() { clipboard.writeText(""); },
  availableFormats() { return ["text/plain"]; },
  has() { return false; },
  readImage() { return nativeImage.createEmpty(); },
  writeImage() { note("clipboard.writeImage"); },
  readBookmark() { return { title: "", url: "" }; },
  writeBookmark() {},
  readFindText() { return ""; },
  writeFindText() {},
  readRTF() { return ""; },
  writeRTF() {},
  readBuffer() { return Buffer.alloc(0); },
  writeBuffer() {},
};

// ---- The rest of `electron` ---------------------------------------------------------------------

const dataPaths = {};
function appDataPath() { return path.join(homeDir, "Library", "Application Support"); }
function defaultPath(name) {
  switch (name) {
    case "home": return homeDir;
    case "appData": return appDataPath();
    case "userData": case "sessionData": return path.join(appDataPath(), APP_NAME);
    case "temp": return path.join(DATA, "tmp");
    case "exe": case "module": return process.execPath;
    case "desktop": return path.join(homeDir, "Desktop");
    case "documents": return path.join(homeDir, "Documents");
    case "downloads": return downloadsDir;
    case "music": return path.join(homeDir, "Music");
    case "pictures": return path.join(homeDir, "Pictures");
    case "videos": return path.join(homeDir, "Movies");
    case "recent": return path.join(DATA, "tmp", "recent");
    case "logs": return path.join(homeDir, "Library", "Logs", APP_NAME);
    case "crashDumps": return path.join(DATA, "tmp", "crashes");
    case "assets": return path.dirname(process.execPath);
    default: throw new Error(`Failed to get '${name}' path`);
  }
}

let ready = false;
let resolveReady;
const readyPromise = new Promise((resolve) => { resolveReady = resolve; });
let appName = APP_NAME;

const app = withFallback(Object.assign(new EventEmitter(), {
  whenReady: () => readyPromise,
  isReady: () => ready,
  getPath(name) { const p = dataPaths[name] || defaultPath(name); if (!["exe", "module", "assets"].includes(name)) fs.mkdirSync(p, { recursive: true }); return p; },
  setPath(name, value) { dataPaths[name] = String(value); },
  getName: () => appName,
  setName(name) { appName = String(name); },
  getVersion: () => APP_VERSION,
  getAppPath: () => APP_DIR,
  getLocale: () => "en-US",
  getSystemLocale: () => "en-US",
  getLocaleCountryCode: () => "US",
  getPreferredSystemLanguages: () => ["en-US"],
  requestSingleInstanceLock: () => true,
  hasSingleInstanceLock: () => true,
  releaseSingleInstanceLock() {},
  quit() { note("app.quit"); },
  exit() { note("app.exit"); },
  relaunch() { note("app.relaunch"); },
  focus() {},
  hide() {},
  show() {},
  isHidden: () => false,
  setAppUserModelId() {},
  setAsDefaultProtocolClient: () => false,
  removeAsDefaultProtocolClient: () => false,
  isDefaultProtocolClient: () => false,
  setLoginItemSettings() {},
  getLoginItemSettings: () => ({ openAtLogin: false, openAsHidden: false, wasOpenedAtLogin: false, wasOpenedAsHidden: false, restoreState: false }),
  disableHardwareAcceleration() {},
  enableSandbox() {},
  setAboutPanelOptions() {},
  showAboutPanel() { broadcast({ t: "toast", title: APP_NAME, body: `Version ${APP_VERSION}` }); },
  setBadgeCount: () => true,
  getBadgeCount: () => 0,
  getAppMetrics: () => [],
  getGPUFeatureStatus: () => ({}),
  getGPUInfo: () => Promise.resolve({}),
  addRecentDocument() {},
  clearRecentDocuments() {},
  isInApplicationsFolder: () => !!config.packaged,
  moveToApplicationsFolder: () => false,
  isEmojiPanelSupported: () => false,
  isAccessibilitySupportEnabled: () => false,
  setAccessibilitySupportEnabled() {},
  getFileIcon: () => Promise.resolve(nativeImage.createEmpty()),
  commandLine: { appendSwitch() {}, appendArgument() {}, hasSwitch: () => false, getSwitchValue: () => "", removeSwitch() {} },
  dock: withFallback({ setIcon() {}, setBadge() {}, getBadge: () => "", bounce: () => 0, cancelBounce() {}, show: () => Promise.resolve(), hide() {}, isVisible: () => true, setMenu() {}, getMenu: () => null }, "app.dock"),
  isPackaged: !!config.packaged,
  name: APP_NAME,
  userAgentFallback: "",
  applicationMenu: null,
  runningUnderARM64Translation: false,
  accessibilitySupportEnabled: false,
}), "app");
Object.defineProperty(app, "name", { get: () => appName, set: (v) => { appName = String(v); } });

const session = {
  defaultSession: null,
  fromPartition: () => session.defaultSession,
  fromPath: () => session.defaultSession,
};
session.defaultSession = withFallback(Object.assign(new EventEmitter(), {
  webRequest: withFallback({ onBeforeRequest() {}, onBeforeSendHeaders() {}, onHeadersReceived() {}, onCompleted() {}, onErrorOccurred() {} }, "session.webRequest"),
  cookies: withFallback(Object.assign(new EventEmitter(), { get: async () => [], set: async () => {}, remove: async () => {}, flushStore: async () => {} }), "session.cookies"),
  protocol: null,
  setPermissionRequestHandler() {},
  setPermissionCheckHandler() {},
  setDevicePermissionHandler() {},
  setDisplayMediaRequestHandler() {},
  setProxy: async () => {},
  resolveProxy: async () => "DIRECT",
  clearCache: async () => {},
  clearStorageData: async () => {},
  clearHostResolverCache: async () => {},
  getUserAgent: () => "",
  setUserAgent() {},
  setSpellCheckerLanguages() {},
  getSpellCheckerLanguages: () => [],
  setPreloads() {},
  getPreloads: () => [],
  registerPreloadScript() {},
  loadExtension: async () => ({}),
  getAllExtensions: () => [],
  getStoragePath: () => app.getPath("userData"),
  isPersistent: () => true,
}), "session.defaultSession");

// Apps that serve their windows from their own scheme (app://, electron-serve): the handlers are
// kept, and pages for such windows are answered through them.
const protocolHandlers = new Map(); // scheme -> { kind, handler }
function registered(kind) {
  return (scheme, handler) => { protocolHandlers.set(String(scheme), { kind, handler }); return true; };
}
const protocol = withFallback({
  registerSchemesAsPrivileged() {},
  handle: registered("handle"),
  unhandle(scheme) { protocolHandlers.delete(String(scheme)); },
  isProtocolHandled: (scheme) => protocolHandlers.has(String(scheme)),
  registerFileProtocol: registered("file"), registerStringProtocol: registered("string"), registerBufferProtocol: registered("buffer"),
  registerHttpProtocol: () => true, registerStreamProtocol: registered("stream"),
  unregisterProtocol: (scheme) => protocolHandlers.delete(String(scheme)),
  interceptFileProtocol: () => true, interceptStringProtocol: () => true, interceptBufferProtocol: () => true,
  interceptHttpProtocol: () => true, interceptStreamProtocol: () => true, uninterceptProtocol: () => true,
  isProtocolRegistered: (scheme) => protocolHandlers.has(String(scheme)), isProtocolIntercepted: () => false,
}, "protocol");

// net.fetch, which (unlike Node's fetch) reads file:// URLs too: protocol handlers rely on it.
async function netFetch(input, init) {
  const url = typeof input === "string" ? input : input && input.url ? input.url : String(input);
  if (/^file:/i.test(url)) {
    const file = decodeURIComponent(new URL(url).pathname);
    try {
      const data = await fs.promises.readFile(file);
      return new Response(data, { status: 200, headers: { "content-type": MIME[path.extname(file).toLowerCase()] || "application/octet-stream" } });
    } catch {
      return new Response("Not found", { status: 404 });
    }
  }
  return fetch(input, init);
}

function makeImage() {
  return withFallback({
    isEmpty: () => true, getSize: () => ({ width: 0, height: 0 }), toPNG: () => Buffer.alloc(0), toJPEG: () => Buffer.alloc(0),
    toBitmap: () => Buffer.alloc(0), toDataURL: () => "data:image/png;base64,", resize() { return this; }, crop() { return this; },
    setTemplateImage() {}, isTemplateImage: () => false, getAspectRatio: () => 1, getScaleFactors: () => [1], addRepresentation() {},
  }, "nativeImage");
}
const nativeImage = withFallback({
  createEmpty: makeImage, createFromPath: makeImage, createFromBuffer: makeImage, createFromDataURL: makeImage,
  createFromBitmap: makeImage, createFromNamedImage: makeImage, createThumbnailFromPath: async () => makeImage(),
}, "nativeImage");

const display = { id: 1, label: "Display", bounds: { x: 0, y: 0, width: 1440, height: 900 }, workArea: { x: 0, y: 25, width: 1440, height: 875 }, size: { width: 1440, height: 900 }, workAreaSize: { width: 1440, height: 875 }, scaleFactor: 2, rotation: 0, internal: true, monochrome: false, colorDepth: 24, colorSpace: "", depthPerComponent: 8, displayFrequency: 60, accelerometerSupport: "unknown", touchSupport: "unknown", detected: true };
const screen = withFallback(Object.assign(new EventEmitter(), {
  getPrimaryDisplay: () => display, getAllDisplays: () => [display], getDisplayNearestPoint: () => display,
  getDisplayMatching: () => display, getCursorScreenPoint: () => ({ x: 0, y: 0 }),
  screenToDipPoint: (p) => p, dipToScreenPoint: (p) => p,
}), "screen");

const nativeTheme = withFallback(Object.assign(new EventEmitter(), {
  themeSource: "system", shouldUseHighContrastColors: false, shouldUseInvertedColorScheme: false, inForcedColorsMode: false, prefersReducedTransparency: false,
}), "nativeTheme");
Object.defineProperty(nativeTheme, "shouldUseDarkColors", {
  get: () => (nativeTheme.themeSource === "dark" ? true : nativeTheme.themeSource === "light" ? false : !!(currentViewer() && currentViewer().dark)),
});

const safeStorage = {
  // The session's data is a throwaway copy, so "encrypted" values only need to round-trip.
  isEncryptionAvailable: () => true,
  encryptString: (text) => Buffer.concat([Buffer.from("ot1:"), Buffer.from(String(text), "utf8")]),
  decryptString: (buffer) => Buffer.from(buffer).toString("utf8").replace(/^ot1:/, ""),
  setUsePlainTextEncryption() {},
  getSelectedStorageBackend: () => "basic_text",
};

const systemPreferences = withFallback(Object.assign(new EventEmitter(), {
  isDarkMode: () => nativeTheme.shouldUseDarkColors, getMediaAccessStatus: () => "granted", askForMediaAccess: async () => true,
  getUserDefault: () => undefined, setUserDefault() {}, getAccentColor: () => "0a84ffff", getColor: () => "#000000",
  getSystemColor: () => "#0a84ff", isTrustedAccessibilityClient: () => false, canPromptTouchID: () => false,
  getAnimationSettings: () => ({ shouldRenderRichAnimation: true, scrollAnimationsEnabledBySystem: true, prefersReducedMotion: false }),
  subscribeNotification: () => 0, unsubscribeNotification() {}, subscribeLocalNotification: () => 0, unsubscribeLocalNotification() {},
  subscribeWorkspaceNotification: () => 0, unsubscribeWorkspaceNotification() {}, postNotification() {}, postLocalNotification() {},
  getEffectiveAppearance: () => (nativeTheme.shouldUseDarkColors ? "dark" : "light"),
}), "systemPreferences");

class Tray extends EventEmitter {
  constructor() { super(); note("Tray"); }
  setImage() {} setPressedImage() {} setToolTip() {} setTitle() {} getTitle() { return ""; } setContextMenu() {}
  setIgnoreDoubleClickEvents() {} popUpContextMenu() {} closeContextMenu() {} getBounds() { return { x: 0, y: 0, width: 0, height: 0 }; }
  isDestroyed() { return false; } destroy() {} displayBalloon() {} removeBalloon() {} focus() {}
}

function unusedClass(name) {
  return class extends EventEmitter { constructor() { super(); note(name); return withFallback(this, name); } };
}

const utilityProcess = {
  fork(modulePath, args = [], options = {}) {
    const child = require("node:child_process").fork(modulePath, args, { ...options, env: { ...process.env, ...(options.env || {}), ELECTRON_RUN_AS_NODE: "1" } });
    const wrapped = withFallback(Object.assign(new EventEmitter(), {
      pid: child.pid, stdout: child.stdout, stderr: child.stderr,
      postMessage: (message) => child.send(message), kill: () => child.kill(),
    }), "UtilityProcess");
    child.on("message", (message) => wrapped.emit("message", message));
    child.on("spawn", () => wrapped.emit("spawn"));
    child.on("exit", (code) => wrapped.emit("exit", code));
    return wrapped;
  },
};

const electron = {
  app,
  autoUpdater: withFallback(Object.assign(new EventEmitter(), { setFeedURL() {}, getFeedURL: () => "", checkForUpdates() {}, quitAndInstall() {} }), "autoUpdater"),
  BaseWindow: BrowserWindow,
  BrowserView: unusedClass("BrowserView"),
  BrowserWindow,
  clipboard: withFallback(clipboard, "clipboard"),
  contentTracing: noop("contentTracing"),
  contextBridge: noop("contextBridge"),
  crashReporter: withFallback({ start() {}, getLastCrashReport: () => null, getUploadedReports: () => [], addExtraParameter() {}, removeExtraParameter() {}, getParameters: () => ({}) }, "crashReporter"),
  desktopCapturer: withFallback({ getSources: async () => [] }, "desktopCapturer"),
  dialog: withFallback(dialog, "dialog"),
  globalShortcut: withFallback({ register: () => true, registerAll() {}, isRegistered: () => false, unregister() {}, unregisterAll() {} }, "globalShortcut"),
  inAppPurchase: noop("inAppPurchase"),
  ipcMain,
  Menu,
  MenuItem,
  MessageChannelMain: unusedClass("MessageChannelMain"),
  nativeImage,
  nativeTheme,
  net: withFallback({ fetch: netFetch, isOnline: () => true, online: true, request: (...args) => require("node:https").request(...args) }, "net"),
  netLog: noop("netLog"),
  Notification,
  powerMonitor: withFallback(Object.assign(new EventEmitter(), { getSystemIdleState: () => "active", getSystemIdleTime: () => 0, isOnBatteryPower: () => false, onBatteryPower: false }), "powerMonitor"),
  powerSaveBlocker: withFallback({ start: () => 1, stop() {}, isStarted: () => false }, "powerSaveBlocker"),
  protocol,
  pushNotifications: noop("pushNotifications"),
  safeStorage,
  screen,
  session,
  ShareMenu: unusedClass("ShareMenu"),
  shell: withFallback(shell, "shell"),
  systemPreferences,
  TouchBar: Object.assign(unusedClass("TouchBar"), { TouchBarButton: unusedClass("TouchBarButton"), TouchBarLabel: unusedClass("TouchBarLabel"), TouchBarSpacer: unusedClass("TouchBarSpacer"), TouchBarGroup: unusedClass("TouchBarGroup"), TouchBarSlider: unusedClass("TouchBarSlider"), TouchBarPopover: unusedClass("TouchBarPopover"), TouchBarSegmentedControl: unusedClass("TouchBarSegmentedControl"), TouchBarScrubber: unusedClass("TouchBarScrubber"), TouchBarColorPicker: unusedClass("TouchBarColorPicker"), TouchBarOtherItemsProxy: unusedClass("TouchBarOtherItemsProxy") }),
  Tray,
  utilityProcess: withFallback(utilityProcess, "utilityProcess"),
  webContents: withFallback({
    getAllWebContents: () => windows.filter((w) => !w.destroyed).map((w) => w.webContents),
    getFocusedWebContents: () => { const w = BrowserWindow.getFocusedWindow(); return w ? w.webContents : null; },
    fromId: (id) => { const w = windows.find((x) => x.webContents.id === id); return w ? w.webContents : undefined; },
  }, "webContents"),
  WebContentsView: unusedClass("WebContentsView"),
  webFrameMain: noop("webFrameMain"),
  View: unusedClass("View"),
  ImageView: unusedClass("ImageView"),
};
session.defaultSession.protocol = protocol;
const electronModule = withFallback(electron, "electron");
globalThis.__opentrafficElectron = electronModule;

// `require('electron')` (and its subpaths) from the app gets the stand-in.
const ELECTRON_NAMES = new Set(["electron", "electron/main", "electron/common", "electron/renderer"]);
const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (ELECTRON_NAMES.has(request)) return electronModule;
  return originalLoad.call(this, request, parent, isMain);
};

// `import ... from 'electron'` too.
if (typeof Module.register === "function") {
  const names = Object.keys(electron).filter((name) => /^[A-Za-z_$][\w$]*$/.test(name));
  const loader = `
    export async function resolve(specifier, context, next) {
      if (${JSON.stringify([...ELECTRON_NAMES])}.includes(specifier)) return { url: "opentraffic:electron", shortCircuit: true };
      return next(specifier, context);
    }
    export async function load(url, context, next) {
      if (url === "opentraffic:electron") {
        return { format: "module", shortCircuit: true, source: "const e = globalThis.__opentrafficElectron; export default e; " +
          ${JSON.stringify(names)}.map((n) => "export const " + n + " = e." + n + ";").join(" ") };
      }
      return next(url, context);
    }`;
  try { Module.register("data:text/javascript," + encodeURIComponent(loader)); } catch (error) { console.warn("[OpenTraffic] ESM hook unavailable:", error.message); }
}

// What a main process looks like. (process.resourcesPath is already the Electron binary's own.)
const processValues = [["type", "browser"], ["defaultApp", !config.packaged], ["mas", false]];
// A finished app's extra resources are in its own bundle, not the Electron that runs this copy.
if (config.resourcesPath) processValues.push(["resourcesPath", config.resourcesPath]);
for (const [key, value] of processValues) {
  try { Object.defineProperty(process, key, { value, configurable: true, writable: true }); } catch { /* read-only */ }
}

// ---- Local services: only the ones OpenTraffic allowed ------------------------------------------

const allowedPorts = new Set((config.allowedPorts || []).map(Number));
const allowedSockets = new Set(config.allowedSockets || []);
const waitingPorts = new Map(); // port -> [fail callbacks]

function isLocalHost(host) {
  const h = String(host || "localhost").toLowerCase().replace(/^\[|\]$/g, "");
  if (h === "localhost" || h.endsWith(".localhost") || h === "0.0.0.0" || h === "::" || h === "::1") return true;
  if (/^127\./.test(h) || /^::ffff:127\./.test(h)) return true;
  if (/^10\./.test(h) || /^192\.168\./.test(h) || /^169\.254\./.test(h) || /^172\.(1[6-9]|2\d|3[01])\./.test(h)) return true;
  if (/^f[cd][0-9a-f]{2}:/.test(h) || /^fe80:/.test(h) || h.endsWith(".local")) return true;
  return false;
}

function connectTarget(args) {
  const first = Array.isArray(args[0]) ? args[0][0] : args[0];
  if (first && typeof first === "object") return { port: first.port, host: first.host, path: first.path };
  if (typeof first === "string" && !/^\d+$/.test(first)) return { path: first };
  return { port: first, host: typeof args[1] === "string" ? args[1] : undefined };
}

const originalConnect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
  const target = connectTarget(args);
  if (target.path) {
    const socketPath = path.resolve(String(target.path));
    if (!allowedSockets.has(socketPath) && !socketPath.startsWith(DATA + path.sep)) return refuse(this, `socket ${socketPath}`, null);
  } else if (isLocalHost(target.host)) {
    const port = Number(target.port);
    if (!allowedPorts.has(port)) return refuse(this, `${target.host || "localhost"}:${port}`, port, target.host);
  }
  return originalConnect.apply(this, args);
};

// Holds a connection OpenTraffic hasn't allowed while the host decides: allowing restarts this
// process with the port allowed (the viewer's call is retried); denying or no answer fails it.
function refuse(socket, what, port, host) {
  const fail = () => {
    const error = Object.assign(new Error(`connect ECONNREFUSED ${what} (OpenTraffic hasn't allowed this local service for the shared preview)`), { code: "ECONNREFUSED", errno: -61, syscall: "connect" });
    socket.destroy(error);
  };
  if (port == null) { process.nextTick(fail); return socket; }
  if (!waitingPorts.has(port)) { waitingPorts.set(port, []); tell({ type: "want", port, host: host || "localhost" }); }
  waitingPorts.get(port).push(fail);
  setTimeout(() => {
    const list = waitingPorts.get(port);
    if (list && list.includes(fail)) { list.splice(list.indexOf(fail), 1); fail(); }
  }, 20000).unref();
  return socket;
}

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.type === "deny" && waitingPorts.has(message.port)) {
    const list = waitingPorts.get(message.port);
    waitingPorts.delete(message.port);
    list.forEach((fail) => fail());
  }
});

// ---- HTTP + WebSocket server --------------------------------------------------------------------

const MAX_FRAME = 64 * 1024 * 1024;

class Socket extends EventEmitter {
  constructor(raw) {
    super();
    this.raw = raw;
    this.buffer = Buffer.alloc(0);
    this.parts = [];
    this.opcode = 0;
    this.closed = false;
    raw.setNoDelay(true);
    raw.on("data", (data) => this.feed(data));
    raw.on("close", () => this.gone());
    raw.on("error", () => this.gone());
  }
  feed(data) {
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, data]) : data;
    while (this.buffer.length >= 2) {
      const b0 = this.buffer[0];
      const b1 = this.buffer[1];
      let length = b1 & 0x7f;
      let offset = 2;
      if (length === 126) { if (this.buffer.length < 4) return; length = this.buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (this.buffer.length < 10) return; length = Number(this.buffer.readBigUInt64BE(2)); offset = 10; }
      if (length > MAX_FRAME) { this.close(); return; }
      const masked = (b1 & 0x80) !== 0;
      const maskAt = offset;
      if (masked) offset += 4;
      if (this.buffer.length < offset + length) return;
      let payload = Buffer.from(this.buffer.subarray(offset, offset + length));
      if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= this.buffer[maskAt + (i & 3)];
      this.buffer = this.buffer.subarray(offset + length);
      const opcode = b0 & 0x0f;
      if (opcode === 8) { this.close(); return; }
      if (opcode === 9) { this.frame(10, payload); continue; }
      if (opcode === 10) continue;
      if (opcode !== 0) { this.opcode = opcode; this.parts = []; }
      this.parts.push(payload);
      if (b0 & 0x80) {
        const message = Buffer.concat(this.parts);
        this.parts = [];
        if (this.opcode === 1) this.emit("message", message.toString("utf8"));
      }
    }
  }
  frame(opcode, payload) {
    if (this.closed) return;
    const length = payload.length;
    let header;
    if (length < 126) header = Buffer.from([0x80 | opcode, length]);
    else if (length < 65536) { header = Buffer.alloc(4); header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(length, 2); }
    else { header = Buffer.alloc(10); header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(length), 2); }
    this.raw.write(Buffer.concat([header, payload]));
  }
  send(text) { this.frame(1, Buffer.from(text, "utf8")); }
  close() {
    if (this.closed) return;
    this.frame(8, Buffer.alloc(0));
    this.raw.end();
    this.gone();
  }
  gone() {
    if (this.closed) return;
    this.closed = true;
    this.emit("close");
  }
}

function acceptSocket(req, raw, head) {
  const key = req.headers["sec-websocket-key"];
  if (!key) return raw.destroy();
  const accept = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  raw.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const socket = new Socket(raw);
  if (head && head.length) socket.feed(head);
  return socket;
}

function onViewerSocket(req, socket) {
  const url = new URL(req.url, "http://x");
  const id = (url.searchParams.get("client") || crypto.randomUUID()).slice(0, 64);
  const viewer = viewerFor(id, url.searchParams.get("page") || "/");
  viewer.window = windowForPage(url.searchParams.get("page") || "/");
  viewer.dark = url.searchParams.get("dark") === "1";
  viewer.attach(socket);
  lastActive = viewer;
  if (url.searchParams.has("stamp") && url.searchParams.get("stamp") !== preloadStamp(viewer.window)) {
    viewer.post({ t: "reload" }); // the app's preload changed since this page loaded
    return;
  }
  tell({ type: "viewers", count: [...viewers.values()].filter((v) => v.connected).length });
  viewer.post({ t: "state", app: { name: APP_NAME, version: APP_VERSION }, menu: serializeMenu(applicationMenu), window: viewer.window ? { id: viewer.window.id, title: viewer.window.title } : null });

  socket.on("message", async (text) => {
    let message;
    try { message = JSON.parse(text); } catch { return; }
    lastActive = viewer;
    switch (message.t) {
      case "invoke": {
        try {
          const value = await invoke(viewer, String(message.channel), decode(message.args || []));
          viewer.post({ t: "result", id: message.id, ok: true, value: encode(value) });
        } catch (error) {
          viewer.post({ t: "result", id: message.id, ok: false, error: { name: error && error.name, message: String(error && error.message || error) } });
        }
        break;
      }
      case "send":
        viewerContext.run(viewer, () => {
          try { ipcMain.emit(String(message.channel), ipcEvent(viewer), ...decode(message.args || [])); } catch (error) { console.error(error); }
        });
        break;
      case "reply": {
        const resolve = viewer.requests.get(message.id);
        if (resolve) { viewer.requests.delete(message.id); resolve(decode(message.value)); }
        break;
      }
      case "menu":
        clickMenuItem(viewer, String(message.id));
        break;
      case "clipboard":
        viewer.clipboard = String(message.text || "");
        break;
      case "theme":
        viewer.dark = !!message.dark;
        nativeTheme.emit("updated");
        break;
      case "loaded":
        replayLoad(viewer);
        break;
    }
  });
  socket.on("close", () => {
    if (viewer.socket !== socket) return; // replaced by a newer connection (a reload)
    viewer.cancelRequests();
    // Kept a little while, so a reload keeps the same `event.sender`.
    setTimeout(() => {
      if (!viewer.connected && viewers.get(id) === viewer) viewers.delete(id);
      tell({ type: "viewers", count: [...viewers.values()].filter((v) => v.connected).length });
    }, 30000).unref();
  });
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) { reject(new Error("too large")); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function send(res, status, body, type = "text/plain; charset=utf-8", extra = {}) {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store", ...extra });
  res.end(body);
}

function preloadScript(req) {
  const window = windowForPage(req.headers.referer);
  let shim = "";
  try { shim = fs.readFileSync(SHIM_PATH, "utf8"); } catch (error) { console.error("[OpenTraffic] Couldn't read the preload shim:", error.message); }
  const info = {
    stamp: preloadStamp(window),
    app: { name: APP_NAME, version: APP_VERSION },
    window: window ? window.id : null,
    preloadFile: window && window.preload,
    versions: { electron: process.versions.electron, chrome: process.versions.chrome, node: process.versions.node },
    arch: process.arch,
  };
  let modules = "";
  if (window && window.preload) {
    try { modules = preloadModules(window.preload); } catch (error) { console.error("[OpenTraffic] Couldn't read the preload script:", error.message); }
  }
  return `window.__opentrafficElectronConfig = ${JSON.stringify(info)};\n${shim}\n` +
    `;(function(){ var run = window.__opentrafficElectronRunPreload; if (run) run(${JSON.stringify(window && window.preload || "")}, {${modules}}); })();\n`;
}

// The preload and every module it requires (followed through node_modules, like Node would), as
// functions the page runs with its own require. Node's built-in modules and native addons aren't
// shipped: the page has small stand-ins for some (events, timers, url, path, process).
const MODULE_WRAPPER = "require, module, exports, process, __dirname, __filename, global, Buffer, setImmediate, clearImmediate";
function preloadModules(entry) {
  const seen = new Map(); // file -> deps
  const order = [];
  const queue = [path.resolve(entry)];
  let bytes = 0;
  while (queue.length) {
    const file = queue.shift();
    if (seen.has(file)) continue;
    let source = fs.readFileSync(file, "utf8");
    if (file.endsWith(".json")) source = "module.exports = " + source + ";";
    bytes += source.length;
    if (seen.size > 2000 || bytes > 20 * 1024 * 1024) throw new Error("the preload's modules are too large to send to a page");
    const deps = {};
    for (const match of source.matchAll(/\brequire\s*\(\s*(['"`])([^'"`\n]+)\1\s*\)/g)) {
      const request = match[2];
      if (deps[request]) continue;
      if (ELECTRON_NAMES.has(request) || Module.isBuiltin(request)) { deps[request] = "builtin:" + request.replace(/^node:/, ""); continue; }
      try {
        const resolved = require.resolve(request, { paths: [path.dirname(file)] });
        if (resolved.endsWith(".node")) { deps[request] = "missing:" + request + " (a native module)"; continue; }
        deps[request] = resolved;
        queue.push(resolved);
      } catch {
        deps[request] = "missing:" + request;
      }
    }
    seen.set(file, deps);
    order.push([file, source]);
  }
  return order.map(([file, source]) =>
    `${JSON.stringify(file)}: { deps: ${JSON.stringify(seen.get(file))}, run: function (${MODULE_WRAPPER}) {\n${source}\n} }`).join(",\n");
}

// What the window's preload is, by content: a page running another one reloads. (A rebuild that
// writes the same preload again leaves pages alone.)
function preloadStamp(window) {
  try {
    if (!window || !window.preload) return "";
    return crypto.createHash("sha256").update(fs.readFileSync(window.preload)).digest("hex").slice(0, 16);
  } catch {
    return "";
  }
}

// Where loadFile windows' files are served from: the folder of the first loaded file.
function rendererRoot() {
  const w = windows.find((x) => !x.destroyed && x.file);
  return w ? path.dirname(w.file) : null;
}

const MIME = {
  ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon", ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf",
  ".wasm": "application/wasm", ".map": "application/json", ".txt": "text/plain; charset=utf-8", ".mp4": "video/mp4", ".webm": "video/webm", ".mp3": "audio/mpeg", ".wav": "audio/wav",
};

// A window on the app's own scheme: ask its protocol handler, as Electron would.
async function serveFromProtocol(window, req, res, url) {
  const base = new URL(window.url);
  const entry = protocolHandlers.get(base.protocol.slice(0, -1));
  if (!entry) return send(res, 502, `The app hasn't registered its ${base.protocol} protocol.`);
  const target = new URL(url.pathname === "/" ? base.pathname + base.search : url.pathname + url.search, base).href;
  const fromFile = (file, type) => fs.readFile(file, (error, data) => {
    if (error) return send(res, 404, "Not found");
    send(res, 200, data, type || MIME[path.extname(file).toLowerCase()] || "application/octet-stream", { "cache-control": "no-cache" });
  });
  try {
    if (entry.kind === "handle") {
      const response = await entry.handler(new Request(target, { method: req.method, headers: { accept: String(req.headers.accept || "*/*") } }));
      const body = Buffer.from(await response.arrayBuffer());
      const headers = {};
      response.headers.forEach((value, key) => { if (!["content-length", "content-encoding", "transfer-encoding"].includes(key)) headers[key] = value; });
      if (!headers["content-type"]) headers["content-type"] = MIME[path.extname(new URL(target).pathname).toLowerCase()] || "application/octet-stream";
      res.writeHead(response.status, { ...headers, "cache-control": "no-cache" });
      return res.end(body);
    }
    const request = { url: target, method: req.method, headers: {}, referrer: "" };
    entry.handler(request, (result) => {
      if (entry.kind === "file") return fromFile(typeof result === "string" ? result : result && result.path);
      const data = result && result.data !== undefined ? result.data : result;
      const type = (result && result.mimeType) || "text/html; charset=utf-8";
      send(res, (result && result.statusCode) || 200, Buffer.isBuffer(data) ? data : Buffer.from(String(data == null ? "" : data)), type);
    });
  } catch (error) {
    send(res, 500, String(error && error.message || error));
  }
}

function serveRenderer(req, res, url) {
  const custom = windows.find((x) => !x.destroyed && x.url && !/^https?:/i.test(x.url));
  if (custom && !windows.some((x) => !x.destroyed && x.file)) return serveFromProtocol(custom, req, res, url);
  const root = rendererRoot();
  if (!root) return send(res, 404, "No window has loaded a file.");
  let rel = decodeURIComponent(url.pathname);
  if (rel === "/") {
    const w = windows.find((x) => !x.destroyed && x.file);
    rel = "/" + path.relative(root, w.file).split(path.sep).join("/");
  }
  const file = path.resolve(root, "." + rel);
  if (file !== root && !file.startsWith(root + path.sep)) return send(res, 403, "Outside the app.");
  fs.readFile(file, (error, data) => {
    if (error) return send(res, 404, "Not found");
    send(res, 200, data, MIME[path.extname(file).toLowerCase()] || "application/octet-stream", { "cache-control": "no-cache" });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  if (!url.pathname.startsWith(PREFIX)) {
    if (req.method === "GET" || req.method === "HEAD") return serveRenderer(req, res, url);
    return send(res, 405, "Method not allowed");
  }
  const route = url.pathname.slice(PREFIX.length);
  try {
    if (route === "preload.js" && req.method === "GET") return send(res, 200, preloadScript(req), "text/javascript; charset=utf-8");
    if (route === "state" && req.method === "GET") {
      return send(res, 200, JSON.stringify({ app: { name: APP_NAME, version: APP_VERSION }, windows: windowList(), viewers: viewers.size, menu: serializeMenu(applicationMenu) }), "application/json");
    }
    if (route === "ipc-sync" && req.method === "POST") {
      const body = JSON.parse((await readBody(req, 8 * 1024 * 1024)).toString("utf8"));
      const viewer = viewerFor(String(body.client || url.searchParams.get("client") || "").slice(0, 64) || crypto.randomUUID(), body.page || req.headers.referer);
      lastActive = viewer;
      try {
        const value = sendSync(viewer, String(body.channel), decode(body.args || []));
        return send(res, 200, JSON.stringify({ ok: true, value: encode(value) }), "application/json");
      } catch (error) {
        return send(res, 200, JSON.stringify({ ok: false, error: { message: String(error && error.message || error) } }), "application/json");
      }
    }
    if (route === "upload" && req.method === "POST") {
      if (!viewers.has(String(url.searchParams.get("client")))) return send(res, 409, "Not connected");
      const name = path.basename(String(url.searchParams.get("name") || "file")).replace(/[\u0000-\u001f]/g, "") || "file";
      const data = await readBody(req, 512 * 1024 * 1024);
      const file = uniquePath(path.join(uploadsDir, crypto.randomUUID().slice(0, 8)), name);
      fs.writeFileSync(file, data);
      return send(res, 200, JSON.stringify({ path: file }), "application/json");
    }
    if (route.startsWith("download/") && req.method === "GET") {
      const file = downloads.get(route.slice("download/".length));
      if (!file || !fs.existsSync(file)) return send(res, 404, "Gone");
      res.writeHead(200, {
        "content-type": MIME[path.extname(file).toLowerCase()] || "application/octet-stream",
        "content-disposition": `attachment; filename*=UTF-8''${encodeURIComponent(path.basename(file))}`,
        "cache-control": "no-store",
      });
      return fs.createReadStream(file).pipe(res);
    }
    send(res, 404, "Not found");
  } catch (error) {
    send(res, 500, String(error && error.message || error));
  }
});

server.on("upgrade", (req, raw, head) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname !== PREFIX + "ipc") { raw.destroy(); return; }
  onViewerSocket(req, acceptSocket(req, raw, head));
});

// ---- Start --------------------------------------------------------------------------------------

for (const dir of [homeDir, uploadsDir, downloadsDir, path.join(DATA, "tmp")]) fs.mkdirSync(dir, { recursive: true });

server.on("error", (error) => {
  tell({ type: "failed", message: `Couldn't listen on port ${config.port}: ${error.message}` });
  process.exit(1);
});
server.listen(Number(config.port) || 0, "127.0.0.1", async () => {
  started = true;
  const port = server.address().port;
  allowedPorts.add(port);
  app.emit("will-finish-launching");
  // "ready" comes on its own, as in Electron: an ES module main may await it at the top level.
  const failed = (error) => {
    console.error("[OpenTraffic] The app's main script failed to load:", error);
    tell({ type: "failed", message: String(error && error.message || error) });
  };
  const isESM = /\.mjs$/.test(MAIN) || (!/\.cjs$/.test(MAIN) && pkg.type === "module");
  let loaded;
  if (isESM) {
    // Its listeners are in place once it has loaded, or, if it awaits "ready" first, a moment later.
    loaded = Promise.race([import(pathToFileURL(MAIN).href).catch(failed), new Promise((resolve) => setTimeout(resolve, 300))]);
  } else {
    try { require(MAIN); } catch (error) { failed(error); }
    loaded = Promise.resolve();
  }
  await loaded;
  setImmediate(() => {
    ready = true;
    app.emit("ready", {}, {});
    resolveReady();
    // Windows usually exist a moment after "ready".
    setTimeout(() => tell({ type: "ready", port, pid: process.pid, windows: windowList(), app: { name: APP_NAME, version: APP_VERSION } }), 150);
  });
});

