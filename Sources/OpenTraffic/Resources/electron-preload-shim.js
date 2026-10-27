/*
 * OpenTraffic Electron preload shim. Served inside /__opentraffic/electron/preload.js, after one
 * generated line (window.__opentrafficElectronConfig = {...}) and before the app's own preload,
 * which electron-host.js wraps in a function and hands to window.__opentrafficElectronRunPreload.
 *
 * Gives the preload what Electron would: require('electron') with contextBridge and an ipcRenderer
 * that reaches the app's main process (running sandboxed in electron-host.js) over a WebSocket,
 * webFrame, webUtils, and a renderer-like `process`. Also draws the small "desktop preview" bar and
 * does what the main process asks of this viewer: pick a file, answer a message box, download a
 * saved file, open a link, show a notification, show a menu. ES2017, no dependencies.
 */
(function () {
  "use strict";
  var w = window;
  if (w.__opentrafficElectron) return;
  var cfg = w.__opentrafficElectronConfig || {};
  var PREFIX = "/__opentraffic/electron/";
  var appName = (cfg.app && cfg.app.name) || "App";

  // ---- Values over the wire (same codec as electron-host.js) ----------------------------------

  function toBase64(bytes) {
    var s = "";
    for (var i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }
  function fromBase64(text) {
    var s = atob(text);
    var out = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
  }
  function encode(value, depth) {
    depth = depth || 0;
    if (depth > 64) return null;
    if (value === undefined) return { $ot: "undefined" };
    if (value === null || typeof value === "boolean" || typeof value === "string") return value;
    if (typeof value === "number") return isFinite(value) ? value : { $ot: "number", v: String(value) };
    if (typeof value === "bigint") return { $ot: "bigint", v: value.toString() };
    if (typeof value === "function" || typeof value === "symbol") return { $ot: "undefined" };
    if (value instanceof ArrayBuffer) return { $ot: "arraybuffer", v: toBase64(new Uint8Array(value)) };
    if (ArrayBuffer.isView(value)) return { $ot: "bytes", v: toBase64(new Uint8Array(value.buffer, value.byteOffset, value.byteLength)) };
    if (value instanceof Date) return { $ot: "date", v: value.getTime() };
    if (value instanceof Error) return { $ot: "error", name: value.name, message: value.message };
    if (value instanceof Map) return { $ot: "map", v: Array.from(value).map(function (e) { return [encode(e[0], depth + 1), encode(e[1], depth + 1)]; }) };
    if (value instanceof Set) return { $ot: "set", v: Array.from(value).map(function (v) { return encode(v, depth + 1); }) };
    if (value instanceof RegExp) return { $ot: "regexp", source: value.source, flags: value.flags };
    if (typeof File !== "undefined" && value instanceof File) return { name: value.name, size: value.size, type: value.type };
    if (Array.isArray(value)) return value.map(function (v) { return encode(v, depth + 1); });
    var out = {};
    Object.keys(value).forEach(function (k) { out[k] = encode(value[k], depth + 1); });
    return out;
  }
  function decode(value) {
    if (value === null || typeof value !== "object") return value;
    if (Array.isArray(value)) return value.map(decode);
    switch (value.$ot) {
      case "undefined": return undefined;
      case "number": return Number(value.v);
      case "bigint": return typeof BigInt === "function" ? BigInt(value.v) : Number(value.v);
      case "bytes": return fromBase64(value.v);
      case "arraybuffer": return fromBase64(value.v).buffer;
      case "date": return new Date(value.v);
      case "error": var e = new Error(value.message); e.name = value.name; return e;
      case "map": return new Map(value.v.map(function (e) { return [decode(e[0]), decode(e[1])]; }));
      case "set": return new Set(value.v.map(decode));
      case "regexp": return new RegExp(value.source, value.flags);
    }
    var out = {};
    Object.keys(value).forEach(function (k) { out[k] = decode(value[k]); });
    return out;
  }

  // ---- Connection to the app's main process ---------------------------------------------------

  var client;
  try {
    client = sessionStorage.getItem("__opentraffic_electron_client");
    if (!client) { client = "v" + Math.random().toString(36).slice(2) + Date.now().toString(36); sessionStorage.setItem("__opentraffic_electron_client", client); }
  } catch (e) { client = "v" + Math.random().toString(36).slice(2); }

  var socket = null;
  var open = false;
  var queue = [];
  var pending = {}; // id -> {resolve, reject, message}
  var seq = 0;
  var listeners = {}; // channel -> [fn]
  var retry = 250;
  var loaded = false;

  function socketURL() {
    var dark = w.matchMedia && w.matchMedia("(prefers-color-scheme: dark)").matches ? "1" : "0";
    return (location.protocol === "https:" ? "wss://" : "ws://") + location.host + PREFIX + "ipc?client=" + encodeURIComponent(client) +
      "&page=" + encodeURIComponent(location.pathname) + "&dark=" + dark + "&stamp=" + encodeURIComponent(cfg.stamp || "");
  }

  function connect() {
    try { socket = new WebSocket(socketURL()); } catch (e) { return later(); }
    socket.onopen = function () {
      open = true;
      retry = 250;
      setStatus("live");
      // Calls that were waiting when the connection dropped (the backend restarted) go again.
      Object.keys(pending).forEach(function (id) { raw(pending[id].message); });
      var waiting = queue;
      queue = [];
      waiting.forEach(raw);
      if (loaded) raw({ t: "loaded" });
    };
    socket.onmessage = function (event) {
      var message;
      try { message = JSON.parse(event.data); } catch (e) { return; }
      receive(message);
    };
    socket.onclose = function () {
      var was = open;
      open = false;
      socket = null;
      if (was) setStatus("reconnecting");
      later();
    };
  }
  function later() {
    setTimeout(connect, retry);
    retry = Math.min(retry * 2, 3000);
  }
  function raw(message) {
    if (open && socket) socket.send(JSON.stringify(message));
    else queue.push(message);
  }
  var post = raw;

  function receive(message) {
    switch (message.t) {
      case "result": {
        var call = pending[message.id];
        if (!call) return;
        delete pending[message.id];
        if (message.ok) call.resolve(decode(message.value));
        else {
          var error = new Error("Error invoking remote method '" + call.message.channel + "': " + (message.error && message.error.name && message.error.name !== "Error" ? message.error.name + ": " : "Error: ") + (message.error && message.error.message));
          call.reject(error);
        }
        return;
      }
      case "event": return emit(message.channel, decode(message.args || []));
      case "state": state = message; renderBar(); return;
      case "menu": if (state) state.menu = message.menu; renderBar(); return;
      case "request": return answer(message);
      case "download": return download(message.url, message.name);
      case "open": return openLink(message.url);
      case "toast": return toast(message.title, message.body, message.kind);
      case "clipboard":
        try { navigator.clipboard.writeText(message.text).catch(function () {}); } catch (e) { /* not allowed */ }
        return;
      case "context-menu": return showMenu(message.menu, lastPointer.x, lastPointer.y);
      case "reload": return location.reload();
    }
  }

  function emit(channel, args) {
    var list = (listeners[channel] || []).slice();
    var event = { sender: ipcRenderer, senderId: 0, ports: [] };
    list.forEach(function (fn) {
      try { fn.apply(null, [event].concat(args)); } catch (e) { setTimeout(function () { throw e; }); }
    });
  }

  // ---- Electron's renderer modules ------------------------------------------------------------

  var ipcRenderer = {
    invoke: function (channel) {
      var args = Array.prototype.slice.call(arguments, 1);
      return new Promise(function (resolve, reject) {
        var id = "c" + (++seq);
        var message = { t: "invoke", id: id, channel: String(channel), args: encode(args) };
        pending[id] = { resolve: resolve, reject: reject, message: message };
        post(message);
      });
    },
    send: function (channel) {
      post({ t: "send", channel: String(channel), args: encode(Array.prototype.slice.call(arguments, 1)) });
    },
    sendSync: function (channel) {
      var body = JSON.stringify({ client: client, page: location.pathname, channel: String(channel), args: encode(Array.prototype.slice.call(arguments, 1)) });
      // Like Electron, it waits for the main process: while that restarts (new code, a reset) the
      // proxy answers with an error page, so it asks again for a few seconds.
      var deadline = Date.now() + 8000;
      for (;;) {
        var xhr = new XMLHttpRequest();
        try {
          xhr.open("POST", PREFIX + "ipc-sync?client=" + encodeURIComponent(client), false);
          xhr.setRequestHeader("content-type", "application/json");
          xhr.send(body);
        } catch (e) { /* the network failed: as below */ }
        var reply = null;
        if (xhr.status === 200) { try { reply = JSON.parse(xhr.responseText); } catch (e) { /* not the main process */ } }
        if (reply) {
          if (reply.ok) return decode(reply.value);
          console.error("[OpenTraffic] ipcRenderer.sendSync('" + channel + "') failed:", reply.error && reply.error.message);
          return undefined;
        }
        if (Date.now() > deadline) break;
        var pause = Date.now() + 150;
        while (Date.now() < pause) { /* a synchronous call can't wait any other way */ }
      }
      console.error("[OpenTraffic] ipcRenderer.sendSync('" + channel + "') failed: the app's main process didn't answer (HTTP " + xhr.status + ").");
      return undefined;
    },
    sendToHost: function () {},
    postMessage: function (channel, message) { ipcRenderer.send(channel, message); },
    on: function (channel, fn) { (listeners[channel] = listeners[channel] || []).push(fn); return ipcRenderer; },
    addListener: function (channel, fn) { return ipcRenderer.on(channel, fn); },
    once: function (channel, fn) {
      var wrapped = function () { ipcRenderer.removeListener(channel, wrapped); return fn.apply(this, arguments); };
      wrapped.original = fn;
      return ipcRenderer.on(channel, wrapped);
    },
    off: function (channel, fn) { return ipcRenderer.removeListener(channel, fn); },
    removeListener: function (channel, fn) {
      var list = listeners[channel] || [];
      for (var i = list.length - 1; i >= 0; i--) if (list[i] === fn || list[i].original === fn) { list.splice(i, 1); break; }
      return ipcRenderer;
    },
    removeAllListeners: function (channel) {
      if (channel === undefined) listeners = {};
      else delete listeners[channel];
      return ipcRenderer;
    },
    listenerCount: function (channel) { return (listeners[channel] || []).length; },
  };

  var contextBridge = {
    exposeInMainWorld: function (key, api) {
      try { Object.defineProperty(w, key, { value: api, enumerable: true, configurable: true, writable: false }); }
      catch (e) { w[key] = api; }
    },
    exposeInIsolatedWorld: function (_worldId, key, api) { contextBridge.exposeInMainWorld(key, api); },
    executeInMainWorld: function (script) { return script && typeof script.func === "function" ? script.func.apply(null, script.args || []) : undefined; },
  };

  var zoom = 1;
  var webFrame = {
    setZoomFactor: function (factor) { zoom = factor; document.documentElement.style.zoom = String(factor); },
    getZoomFactor: function () { return zoom; },
    setZoomLevel: function (level) { webFrame.setZoomFactor(Math.pow(1.2, level)); },
    getZoomLevel: function () { return Math.log(zoom) / Math.log(1.2); },
    setVisualZoomLevelLimits: function () { return Promise.resolve(); },
    insertCSS: function (css) {
      var style = document.createElement("style");
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);
      return "css" + (++seq);
    },
    removeInsertedCSS: function () {},
    executeJavaScript: function (code) { try { return Promise.resolve((0, eval)(code)); } catch (e) { return Promise.reject(e); } },
    setSpellCheckProvider: function () {},
    getResourceUsage: function () { return {}; },
    clearCache: function () {},
    routingId: 1,
  };

  var webUtils = { getPathForFile: function (file) { return file && file.name ? file.name : ""; } };

  function Emitter() { this._l = {}; }
  Emitter.prototype.on = function (n, f) { (this._l[n] = this._l[n] || []).push(f); return this; };
  Emitter.prototype.addListener = Emitter.prototype.on;
  Emitter.prototype.once = function (n, f) { var self = this; var g = function () { self.off(n, g); f.apply(this, arguments); }; return this.on(n, g); };
  Emitter.prototype.off = function (n, f) { var l = this._l[n] || []; var i = l.indexOf(f); if (i >= 0) l.splice(i, 1); return this; };
  Emitter.prototype.removeListener = Emitter.prototype.off;
  Emitter.prototype.removeAllListeners = function (n) { if (n === undefined) this._l = {}; else delete this._l[n]; return this; };
  Emitter.prototype.emit = function (n) { var a = Array.prototype.slice.call(arguments, 1); var self = this; (this._l[n] || []).slice().forEach(function (f) { f.apply(self, a); }); return (this._l[n] || []).length > 0; };
  Emitter.prototype.listenerCount = function (n) { return (this._l[n] || []).length; };

  var fakeProcess = new Emitter();
  Object.assign(fakeProcess, {
    platform: "darwin",
    arch: cfg.arch || "arm64",
    type: "renderer",
    versions: Object.assign({}, cfg.versions || {}),
    env: {},
    argv: [],
    execPath: "",
    pid: 1,
    contextIsolated: true,
    sandboxed: true,
    isMainFrame: true,
    resourcesPath: "",
    cwd: function () { return "/"; },
    nextTick: function (fn) { var a = Array.prototype.slice.call(arguments, 1); Promise.resolve().then(function () { fn.apply(null, a); }); },
    hrtime: Object.assign(function () { var t = performance.now(); return [Math.floor(t / 1000), Math.floor((t % 1000) * 1e6)]; }, { bigint: function () { return BigInt(Math.floor(performance.now() * 1e6)); } }),
    uptime: function () { return performance.now() / 1000; },
    memoryUsage: function () { return { rss: 0, heapTotal: 0, heapUsed: 0, external: 0 }; },
    getProcessMemoryInfo: function () { return Promise.resolve({ private: 0, shared: 0, residentSet: 0 }); },
    getSystemVersion: function () { return "15.0.0"; },
    getCPUUsage: function () { return { percentCPUUsage: 0, idleWakeupsPerSecond: 0 }; },
    getBlinkMemoryInfo: function () { return { allocated: 0, total: 0 }; },
  });

  var electron = {
    contextBridge: contextBridge,
    ipcRenderer: ipcRenderer,
    webFrame: webFrame,
    webUtils: webUtils,
    crashReporter: { addExtraParameter: function () {}, removeExtraParameter: function () {}, getParameters: function () { return {}; } },
    nativeImage: { createEmpty: function () { return { isEmpty: function () { return true; }, toDataURL: function () { return ""; } }; } },
    clipboard: {
      writeText: function (t) { try { navigator.clipboard.writeText(String(t)); } catch (e) { /* not allowed */ } },
      readText: function () { return ""; },
    },
    shell: { openExternal: function (url) { openLink(String(url)); return Promise.resolve(); } },
  };

  // Enough of Node's path for preloads that join a few paths.
  var pathShim = (function () {
    function normalize(p) {
      var abs = p.charAt(0) === "/", out = [];
      p.split("/").forEach(function (part) {
        if (!part || part === ".") return;
        if (part === "..") { if (out.length && out[out.length - 1] !== "..") out.pop(); else if (!abs) out.push(".."); }
        else out.push(part);
      });
      return (abs ? "/" : "") + out.join("/") || (abs ? "/" : ".");
    }
    var api = {
      sep: "/", delimiter: ":", normalize: normalize,
      join: function () { return normalize(Array.prototype.slice.call(arguments).filter(Boolean).join("/")); },
      resolve: function () { var parts = Array.prototype.slice.call(arguments), p = ""; for (var i = parts.length - 1; i >= 0 && p.charAt(0) !== "/"; i--) p = parts[i] + (p ? "/" + p : ""); return normalize(p.charAt(0) === "/" ? p : "/" + p); },
      dirname: function (p) { var i = String(p).replace(/\/+$/, "").lastIndexOf("/"); return i > 0 ? p.slice(0, i) : i === 0 ? "/" : "."; },
      basename: function (p, ext) { var b = String(p).replace(/\/+$/, "").split("/").pop(); return ext && b.slice(-ext.length) === ext ? b.slice(0, -ext.length) : b; },
      extname: function (p) { var b = api.basename(p), i = b.lastIndexOf("."); return i > 0 ? b.slice(i) : ""; },
      isAbsolute: function (p) { return String(p).charAt(0) === "/"; },
      relative: function (from, to) { return normalize(to); },
    };
    api.posix = api;
    return api;
  })();

  var timers = { setTimeout: setTimeout, clearTimeout: clearTimeout, setInterval: setInterval, clearInterval: clearInterval,
    setImmediate: function (f) { return setTimeout(f, 0); }, clearImmediate: function (id) { clearTimeout(id); } };

  function requireShim(name) {
    switch (name) {
      case "electron": case "electron/renderer": case "electron/common": return electron;
      case "events": case "node:events": { var E = Emitter; E.EventEmitter = Emitter; return E; }
      case "timers": case "node:timers": return timers;
      case "url": case "node:url": return { URL: URL, URLSearchParams: URLSearchParams };
      case "process": case "node:process": return fakeProcess;
      case "path": case "node:path": case "path/posix": return pathShim;
    }
    throw new Error("Cannot find module '" + name + "' (Node's " + name + " isn't available to a preload in OpenTraffic's shared preview)");
  }

  // Runs the preload: `modules` are it and everything it requires, by file, each with what its
  // require() calls resolve to (another file, or "builtin:name").
  w.__opentrafficElectronRunPreload = function (entry, modules) {
    delete w.__opentrafficElectronRunPreload;
    if (!entry || !modules[entry]) return;
    var cache = {};
    function load(file) {
      if (cache[file]) return cache[file].exports;
      var mod = modules[file];
      var module = { exports: {}, id: file, filename: file, loaded: false };
      cache[file] = module;
      var require = function (request) {
        var target = mod.deps[request];
        if (!target) return requireShim(request);
        if (target.indexOf("builtin:") === 0) return requireShim(target.slice(8));
        if (target.indexOf("missing:") === 0) throw new Error("Cannot find module '" + target.slice(8) + "' in the shared preview");
        return load(target);
      };
      mod.run.call(module.exports, require, module, module.exports, fakeProcess, file.replace(/\/[^/]*$/, ""), file, w, undefined, timers.setImmediate, timers.clearImmediate);
      module.loaded = true;
      return module.exports;
    }
    try {
      load(entry);
    } catch (e) {
      console.error("[OpenTraffic] The app's preload script failed:", e);
    }
  };

  Object.defineProperty(w, "__opentrafficElectron", {
    value: Object.freeze({ client: client, app: cfg.app, ipcRenderer: ipcRenderer }),
  });

  // ---- The desktop preview bar and what the app asks of this viewer ---------------------------

  var state = null;
  var status = "connecting";
  var ui = null;
  var lastPointer = { x: 80, y: 80 };
  document.addEventListener("contextmenu", function (e) { lastPointer = { x: e.clientX, y: e.clientY }; }, true);
  document.addEventListener("pointerdown", function (e) {
    if (ui && e.composedPath && e.composedPath().indexOf(ui.host) >= 0) return; // our own menu or bar
    lastPointer = { x: e.clientX, y: e.clientY };
    closeMenu();
  }, true);

  var CSS = [
    ":host { all: initial; }",
    "* { box-sizing: border-box; font: 12px/1.35 -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif; }",
    ".bar { position: fixed; left: 16px; bottom: 16px; z-index: 2147483000; display: flex; align-items: center; gap: 2px; padding: 4px; border-radius: 999px;",
    "  background: rgba(24,24,27,.92); color: #f4f4f5; box-shadow: 0 6px 24px rgba(0,0,0,.22); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); }",
    ".name { display: flex; align-items: center; gap: 6px; padding: 3px 10px 3px 8px; font-weight: 600; }",
    ".dot { width: 7px; height: 7px; border-radius: 50%; background: #22c55e; }",
    ".dot.reconnecting, .dot.connecting { background: #f59e0b; }",
    ".tag { color: #a1a1aa; font-weight: 400; }",
    "button { appearance: none; border: 0; background: transparent; color: inherit; padding: 4px 10px; border-radius: 999px; cursor: pointer; }",
    "button:hover { background: rgba(255,255,255,.12); }",
    ".menu { position: fixed; z-index: 2147483001; min-width: 220px; max-height: 70vh; overflow: auto; padding: 5px; border-radius: 10px;",
    "  background: rgba(250,250,250,.97); color: #18181b; box-shadow: 0 10px 34px rgba(0,0,0,.25), 0 0 0 .5px rgba(0,0,0,.18); }",
    ".menu .head { padding: 6px 10px 3px; color: #71717a; font-weight: 600; font-size: 11px; }",
    ".menu .item { display: flex; justify-content: space-between; gap: 18px; width: 100%; text-align: left; padding: 5px 10px; border-radius: 6px; }",
    ".menu .item:hover { background: #2563eb; color: #fff; }",
    ".menu .item:hover .acc { color: #dbeafe; }",
    ".menu .item[disabled] { color: #a1a1aa; background: transparent; cursor: default; }",
    ".menu .acc { color: #71717a; }",
    ".menu hr { border: 0; border-top: 1px solid #e4e4e7; margin: 4px 6px; }",
    ".sub { padding-left: 10px; }",
    ".toasts { position: fixed; left: 16px; bottom: 60px; z-index: 2147483000; display: flex; flex-direction: column; gap: 8px; max-width: 340px; }",
    ".toast { padding: 10px 12px; border-radius: 12px; background: rgba(24,24,27,.94); color: #f4f4f5; box-shadow: 0 6px 24px rgba(0,0,0,.22); }",
    ".toast b { display: block; margin-bottom: 2px; }",
    ".toast.error { background: #7f1d1d; }",
    ".toast a { color: #93c5fd; }",
    ".toast p { margin: 0; white-space: pre-wrap; }",
    ".scrim { position: fixed; inset: 0; z-index: 2147483002; display: flex; align-items: center; justify-content: center; background: rgba(0,0,0,.28); }",
    ".dialog { width: min(420px, calc(100vw - 32px)); padding: 18px; border-radius: 14px; background: #fafafa; color: #18181b; box-shadow: 0 18px 60px rgba(0,0,0,.35); }",
    ".dialog h2 { margin: 0 0 6px; font-size: 14px; font-weight: 600; }",
    ".dialog p { margin: 0 0 6px; color: #3f3f46; white-space: pre-wrap; }",
    ".dialog .muted { color: #71717a; font-size: 11px; }",
    ".dialog .row { display: flex; justify-content: flex-end; gap: 8px; margin-top: 14px; }",
    ".dialog button { background: #e4e4e7; border-radius: 8px; padding: 6px 14px; }",
    ".dialog button.primary { background: #2563eb; color: #fff; }",
    ".dialog label { display: flex; gap: 6px; align-items: center; margin-top: 8px; }",
  ].join("\n");

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      if (k === "text") node.textContent = attrs[k];
      else if (k.slice(0, 2) === "on") node.addEventListener(k.slice(2), attrs[k]);
      else node.setAttribute(k, attrs[k]);
    });
    (children || []).forEach(function (c) { if (c) node.appendChild(c); });
    return node;
  }

  function ensureUI() {
    if (ui) return ui;
    if (!document.body) return null;
    var host = document.createElement("div");
    host.setAttribute("data-opentraffic-ui", "");
    host.setAttribute("data-opentraffic", "");
    var root = host.attachShadow({ mode: "closed" });
    root.appendChild(el("style", { text: CSS }));
    var toasts = el("div", { class: "toasts" });
    var bar = el("div", { class: "bar" });
    root.appendChild(toasts);
    root.appendChild(bar);
    document.body.appendChild(host);
    ui = { host: host, root: root, bar: bar, toasts: toasts, menu: null };
    return ui;
  }

  function setStatus(next) { status = next; renderBar(); }

  function renderBar() {
    var u = ensureUI();
    if (!u) return;
    u.bar.textContent = "";
    var dot = el("span", { class: "dot " + status, title: status === "live" ? "Connected to the app" : "Reconnecting to the app…" });
    u.bar.appendChild(el("span", { class: "name", title: "A shared preview of a desktop app. Its main process runs sandboxed on the host's Mac, with its own copy of the data." },
      [dot, el("span", { text: appName }), el("span", { class: "tag", text: "desktop preview" })]));
    var menu = state && state.menu;
    if (menu && menu.length) {
      u.bar.appendChild(el("button", { text: "Menu", title: appName + "'s menus", onclick: function (e) {
        e.stopPropagation();
        var r = e.currentTarget.getBoundingClientRect();
        showMenu(menu, r.left, r.top, true);
      } }));
    }
  }

  // Roles the browser can do itself; the rest of Electron's roles make no sense here.
  var ROLES = {
    undo: function () { document.execCommand("undo"); }, redo: function () { document.execCommand("redo"); },
    cut: function () { document.execCommand("cut"); }, copy: function () { document.execCommand("copy"); },
    paste: function () { document.execCommand("paste"); }, selectall: function () { document.execCommand("selectAll"); },
    delete: function () { document.execCommand("delete"); },
    reload: function () { location.reload(); }, forcereload: function () { location.reload(); },
    resetzoom: function () { webFrame.setZoomFactor(1); }, zoomin: function () { webFrame.setZoomFactor(zoom * 1.1); },
    zoomout: function () { webFrame.setZoomFactor(zoom / 1.1); },
    togglefullscreen: function () { if (document.fullscreenElement) document.exitFullscreen(); else document.documentElement.requestFullscreen().catch(function () {}); },
    about: function () { toast(appName, "Version " + ((cfg.app && cfg.app.version) || "")); },
  };
  function usable(item) {
    if (item.type === "separator") return true;
    if (item.submenu) return item.submenu.some(function (x) { return x.type !== "separator" && usable(x); });
    return !item.role || ROLES[item.role] || item.role === "appmenu" || item.role === "editmenu" || item.role === "viewmenu";
  }

  function closeMenu() {
    if (ui && ui.menu) { ui.menu.remove(); ui.menu = null; }
  }

  function showMenu(menu, x, y, above) {
    var u = ensureUI();
    if (!u || !menu) return;
    closeMenu();
    var box = el("div", { class: "menu" });
    box.addEventListener("pointerdown", function (e) { e.stopPropagation(); });
    function add(items, parent, depth) {
      var lastWasSeparator = true;
      items.forEach(function (item) {
        if (!usable(item)) return;
        if (item.type === "separator") {
          if (!lastWasSeparator) parent.appendChild(el("hr"));
          lastWasSeparator = true;
          return;
        }
        lastWasSeparator = false;
        if (item.submenu) {
          parent.appendChild(el("div", { class: "head", text: item.label }));
          var group = el("div", { class: depth ? "sub" : "" });
          parent.appendChild(group);
          add(item.submenu, group, depth + 1);
          return;
        }
        var label = (item.type === "checkbox" || item.type === "radio") ? (item.checked ? "✓ " : "    ") + item.label : item.label;
        var button = el("button", { class: "item", onclick: function () { closeMenu(); activate(item); } },
          [el("span", { text: label }), item.accelerator ? el("span", { class: "acc", text: prettyAccelerator(item.accelerator) }) : null]);
        if (!item.enabled) button.setAttribute("disabled", "");
        parent.appendChild(button);
      });
    }
    add(menu, box, 0);
    u.root.appendChild(box);
    u.menu = box;
    var r = box.getBoundingClientRect();
    var left = Math.max(8, Math.min(x, innerWidth - r.width - 8));
    var top = above ? Math.max(8, y - r.height - 8) : Math.max(8, Math.min(y, innerHeight - r.height - 8));
    box.style.left = left + "px";
    box.style.top = top + "px";
  }

  function activate(item) {
    if (item.role && ROLES[item.role] && !item.submenu) return ROLES[item.role]();
    raw({ t: "menu", id: item.id });
  }

  function prettyAccelerator(acc) {
    return String(acc).replace(/CmdOrCtrl|CommandOrControl|Command|Cmd/gi, "⌘").replace(/Control|Ctrl/gi, "⌃").replace(/Alt|Option/gi, "⌥")
      .replace(/Shift/gi, "⇧").replace(/\+/g, "");
  }

  // Menu shortcuts work on the page, as they would in the app.
  function matches(acc, e) {
    var parts = String(acc).split("+");
    var key = parts.pop().toLowerCase();
    var want = { meta: false, ctrl: false, alt: false, shift: false };
    parts.forEach(function (p) {
      p = p.toLowerCase();
      if (p === "cmdorctrl" || p === "commandorcontrol") { if (/Mac/.test(navigator.platform)) want.meta = true; else want.ctrl = true; }
      else if (p === "cmd" || p === "command" || p === "super" || p === "meta") want.meta = true;
      else if (p === "ctrl" || p === "control") want.ctrl = true;
      else if (p === "alt" || p === "option") want.alt = true;
      else if (p === "shift") want.shift = true;
    });
    return e.key.toLowerCase() === key && e.metaKey === want.meta && e.ctrlKey === want.ctrl && e.altKey === want.alt && e.shiftKey === want.shift;
  }
  document.addEventListener("keydown", function (e) {
    var menu = state && state.menu;
    if (!menu || !(e.metaKey || e.ctrlKey || e.altKey)) return;
    (function walk(items) {
      for (var i = 0; i < items.length; i++) {
        var item = items[i];
        if (item.submenu) { if (walk(item.submenu)) return true; continue; }
        if (item.accelerator && !item.role && item.enabled && matches(item.accelerator, e)) {
          e.preventDefault();
          activate(item);
          return true;
        }
      }
      return false;
    })(menu);
  }, true);

  function toast(title, body, kind, link) {
    var u = ensureUI();
    if (!u) return;
    var node = el("div", { class: "toast" + (kind === "error" ? " error" : "") }, [el("b", { text: title || appName }), body ? el("p", { text: body }) : null]);
    if (link) node.appendChild(link);
    u.toasts.appendChild(node);
    setTimeout(function () { node.remove(); }, link ? 15000 : 6000);
  }

  function openLink(url) {
    if (!/^(https?|mailto):/i.test(url)) return;
    // Not "noopener": with it window.open always returns null, so an opened tab looked blocked too.
    // The new tab loses its opener right away instead.
    var opened = null;
    try { opened = w.open(url, "_blank"); } catch (e) { /* blocked */ }
    if (opened) { try { opened.opener = null; } catch (e) { /* cross-origin already */ } }
    if (!opened) toast(appName + " wants to open a link", null, null, el("a", { href: url, target: "_blank", rel: "noopener", text: url }));
  }

  function download(url, name) {
    var a = el("a", { href: url, download: name || "" });
    document.body.appendChild(a);
    a.click();
    a.remove();
    toast("Saved " + (name || "a file"), null, null, el("a", { href: url, download: name || "", text: "Download again" }));
  }

  function modal(build) {
    var u = ensureUI();
    if (!u) return null;
    var scrim = el("div", { class: "scrim" });
    var box = el("div", { class: "dialog" });
    scrim.appendChild(box);
    u.root.appendChild(scrim);
    build(box, function () { scrim.remove(); });
    // Like a native dialog: its main button has focus, so Return chooses and Escape cancels.
    var primary = box.querySelector("button.primary");
    if (primary) setTimeout(function () { primary.focus(); }, 0);
    box.addEventListener("keydown", function (e) {
      if (e.key !== "Escape") return;
      var buttons = box.querySelectorAll(".row button");
      if (buttons.length > 1) { e.preventDefault(); buttons[0].click(); }
    });
    return scrim;
  }

  function reply(id, value) { raw({ t: "reply", id: id, value: encode(value) }); }

  function upload(file) {
    return fetch(PREFIX + "upload?client=" + encodeURIComponent(client) + "&name=" + encodeURIComponent(file.name), { method: "POST", body: file })
      .then(function (r) { if (!r.ok) throw new Error("upload failed"); return r.json(); })
      .then(function (j) { return j.path; });
  }

  function answer(message) {
    var options = decode(message.options) || {};
    if (message.kind === "open") {
      var props = options.properties || [];
      var input = el("input", { type: "file", style: "display:none" });
      if (props.indexOf("multiSelections") >= 0) input.multiple = true;
      var exts = [];
      (options.filters || []).forEach(function (f) { (f.extensions || []).forEach(function (x) { if (x !== "*") exts.push("." + x); }); });
      if (exts.length) input.accept = exts.join(",");
      modal(function (box, close) {
        box.appendChild(input);
        box.appendChild(el("h2", { text: options.title || appName + " wants a file" }));
        box.appendChild(el("p", { text: "Choose a file from this device. It's uploaded to the app's sandboxed copy, not to anyone's real files." }));
        var status = el("p", { class: "muted" });
        box.appendChild(status);
        var done = false;
        var finish = function (paths) { if (done) return; done = true; close(); reply(message.id, { canceled: !paths.length, filePaths: paths }); };
        input.addEventListener("change", function () {
          var files = Array.prototype.slice.call(input.files || []);
          if (!files.length) return;
          status.textContent = "Uploading " + files.length + (files.length === 1 ? " file…" : " files…");
          Promise.all(files.map(upload)).then(finish, function () { status.textContent = "The upload failed."; });
        });
        box.appendChild(el("div", { class: "row" }, [
          el("button", { text: "Cancel", onclick: function () { finish([]); } }),
          el("button", { class: "primary", text: options.buttonLabel || "Choose…", onclick: function () { input.click(); } }),
        ]));
      });
      return;
    }
    if (message.kind === "message") {
      var buttons = options.buttons && options.buttons.length ? options.buttons : ["OK"];
      modal(function (box, close) {
        box.appendChild(el("h2", { text: options.message || options.title || appName }));
        if (options.detail) box.appendChild(el("p", { text: options.detail }));
        var check = null;
        if (options.checkboxLabel) {
          check = el("input", { type: "checkbox" });
          box.appendChild(el("label", {}, [check, el("span", { text: options.checkboxLabel })]));
        }
        var row = el("div", { class: "row" });
        buttons.forEach(function (label, index) {
          row.appendChild(el("button", { class: index === (options.defaultId || 0) ? "primary" : "", text: label, onclick: function () {
            close();
            reply(message.id, { response: index, checkboxChecked: !!(check && check.checked) });
          } }));
        });
        box.appendChild(row);
      });
      return;
    }
    reply(message.id, null);
  }

  if (w.matchMedia) {
    var scheme = w.matchMedia("(prefers-color-scheme: dark)");
    var onScheme = function () { raw({ t: "theme", dark: scheme.matches }); };
    if (scheme.addEventListener) scheme.addEventListener("change", onScheme);
  }
  document.addEventListener("copy", function () {
    try { raw({ t: "clipboard", text: String(document.getSelection() || "") }); } catch (e) { /* ignore */ }
  }, true);

  function onLoaded() {
    loaded = true;
    renderBar();
    if (open) raw({ t: "loaded" });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", onLoaded);
  else setTimeout(onLoaded, 0);

  connect();
})();
