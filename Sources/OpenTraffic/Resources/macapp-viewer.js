/*
 * OpenTraffic Mac app viewer, served at /__opentraffic/macapp/viewer.js by the mirror server.
 * Draws a shared Mac app's windows from frame tiles, lays real web elements over the pixels from the
 * app's accessibility tree (so the collaboration overlay picks, labels and pins them like any page),
 * and sends the viewer's clicks, scrolling and typing back, showing their effect at once.
 * The whole contract is docs/macapp-mirror-protocol.md.
 */
(() => {
  "use strict";
  if (window.__opentrafficMacApp) return;
  window.__opentrafficMacApp = true;

  const WS_PATH = "/__opentraffic/macapp/ws";
  const ICON_PATH = "/__opentraffic/macapp/icon.png";
  const MOVE_INTERVAL = 1000 / 30; // pointer moves: at most 30 a second
  const WHEEL_INTERVAL = 1000 / 60;
  const OPTIMISTIC_MS = 1500; // optimistic feedback gives way to the app's truth by then at the latest
  const PRESS_HOLD_MS = 250; // a pressed button stays pressed this long after the click
  const TYPING_QUIET_MS = 1000; // a focused field takes the app's value only after this much quiet
  const FOCUS_QUIET_MS = 500; // the app's focus moves ours only when the viewer hasn't just clicked or typed
  const BACKOFF = [500, 1000, 2000, 4000, 8000];
  const PAD = 24; // desk margin around the windows, CSS pixels
  const NAMED_KEYS = new Set(["Enter", "Escape", "Tab", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]);
  const CURSORS = { default: "default", pointer: "pointer", text: "text", grab: "grab" };
  const STATUS_TEXT = {
    restarting: (app) => "Restarting " + app + "…",
    crashed: (app) => app + " quit unexpectedly.",
    stopped: (app) => app + " isn't running.",
  };

  // AX roles as ARIA roles, so the overlay and assistive tech know what an element is.
  const ARIA = {
    AXButton: "button", AXPopUpButton: "button", AXMenuButton: "button", AXDisclosureTriangle: "button",
    AXCheckBox: "checkbox", AXRadioButton: "radio", AXIncrementor: "spinbutton", AXSlider: "slider",
    AXLink: "link", AXImage: "img", AXList: "list", AXTable: "grid", AXOutline: "tree", AXRow: "row",
    AXCell: "gridcell", AXGroup: "group", AXRadioGroup: "radiogroup", AXTabGroup: "tablist", AXToolbar: "toolbar",
    AXSheet: "dialog", AXHeading: "heading", AXProgressIndicator: "progressbar", AXMenu: "menu",
    AXMenuItem: "menuitem", AXMenuBar: "menubar", AXScrollBar: "scrollbar", AXSplitter: "separator",
    AXComboBox: "combobox", AXValueIndicator: "slider",
  };
  // Roles whose label is also the element's text, so the comment picker and screenshots see real words.
  const TEXT_ROLES = new Set(["AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXLink",
    "AXMenuItem", "AXStaticText", "AXHeading", "AXCell", "AXDisclosureTriangle"]);
  const CHECK_ROLES = new Set(["AXCheckBox", "AXRadioButton"]);

  function kindOf(role) {
    if (role === "AXSecureTextField") return "password";
    if (role === "AXTextField" || role === "AXSearchField" || role === "AXComboBox") return "text";
    if (role === "AXTextArea") return "textarea";
    return "node";
  }

  // The node's DOM id: "ax-" + djb2 of the key over UTF-16 code units, unsigned 32-bit, base 36.
  function domId(key) {
    let h = 5381;
    for (let i = 0; i < key.length; i++) h = ((h << 5) + h + key.charCodeAt(i)) >>> 0;
    return "ax-" + h.toString(36);
  }

  const $ = (id) => document.getElementById(id);
  const desk = $("otm-desk");
  const fitBox = $("otm-fit");
  const stage = $("otm-stage");
  const dot = $("otm-dot");
  const nameEl = $("otm-name");
  const iconEl = $("otm-icon");
  const banner = $("otm-banner");
  if (!desk || !fitBox || !stage) return;

  const state = {
    boot: null, scale: 1, appName: "the app", appearance: "light",
    windows: new Map(), // id -> window surface
    order: [], // window ids, main first
    bounds: { x: 0, y: 0, w: 1, h: 1 },
    socket: null, attempt: 0, retry: null, status: "running", statusMessage: null,
    activeWindow: null, // the window keys go to when no field has focus
    lastLocal: 0, // when the viewer last clicked or typed
  };

  // ---------------------------------------------------------------- connection

  function connect() {
    clearTimeout(state.retry);
    const url = new URL(WS_PATH, location.href);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.search = url.hash = "";
    let ws;
    try {
      ws = new WebSocket(url.href);
    } catch {
      return reconnectLater();
    }
    ws.binaryType = "arraybuffer";
    state.socket = ws;
    ws.onmessage = (e) => {
      if (state.socket !== ws) return;
      if (typeof e.data === "string") onText(e.data);
      else if (e.data instanceof ArrayBuffer) onTile(e.data);
    };
    ws.onclose = () => {
      if (state.socket !== ws) return;
      state.socket = null;
      setLive(false);
      reconnectLater();
    };
    ws.onerror = () => {}; // a close follows
  }

  function reconnectLater() {
    const wait = BACKOFF[Math.min(state.attempt, BACKOFF.length - 1)];
    state.attempt++;
    clearTimeout(state.retry);
    state.retry = setTimeout(connect, wait * (0.8 + Math.random() * 0.4));
  }

  function setLive(live) {
    if (!dot) return;
    dot.dataset.state = live ? "live" : "connecting";
    dot.title = live ? "Connected to the app" : "Reconnecting to the app…";
  }

  function send(message) {
    const ws = state.socket;
    if (!ws || ws.readyState !== WebSocket.OPEN) return false;
    ws.send(JSON.stringify(message));
    return true;
  }

  function onText(text) {
    let m;
    try {
      m = JSON.parse(text);
    } catch {
      return;
    }
    if (!m || typeof m !== "object") return;
    switch (m.t) {
      case "hello": return onHello(m);
      case "windows": return applyWindows(m.windows);
      case "tree": return applyTree(m);
      case "frame": return onFrame(m);
      case "cursor": return setCursor(m.shape);
      case "status": return setStatus(m.state, m.message);
      default: return; // unknown and reserved messages are ignored
    }
  }

  // ---------------------------------------------------------------- hello, windows, fit

  function onHello(m) {
    if (state.boot !== null && m.boot !== state.boot) clearAll(); // the app restarted
    state.boot = typeof m.boot === "string" ? m.boot : null;
    state.attempt = 0;
    setLive(true);
    const scale = Number(m.scale) > 0 ? Number(m.scale) : 1;
    const rescale = scale !== state.scale;
    state.scale = scale;
    if (rescale) for (const win of state.windows.values()) sizeCanvas(win, true);
    state.appearance = m.appearance === "dark" ? "dark" : "light";
    document.body.dataset.appearance = state.appearance;
    const name = m.app && typeof m.app.name === "string" && m.app.name.trim() ? m.app.name.trim() : "the app";
    state.appName = name;
    if (nameEl) nameEl.textContent = name === "the app" ? "Mac app" : name;
    document.title = (name === "the app" ? "Mac app" : name) + " · OpenTraffic";
    if (iconEl && !iconEl.getAttribute("src")) {
      iconEl.onload = () => (iconEl.hidden = false);
      iconEl.onerror = () => (iconEl.hidden = true);
      iconEl.src = ICON_PATH;
    }
    setStatus("running", null);
    applyWindows(m.windows);
  }

  function clearAll() {
    for (const win of state.windows.values()) removeWindow(win);
    state.windows.clear();
    state.order = [];
    state.activeWindow = null;
  }

  function applyWindows(list) {
    if (!Array.isArray(list)) return;
    const seen = new Set();
    const order = [];
    for (const info of list) {
      if (!info || typeof info !== "object" || !Number.isInteger(info.id) || seen.has(info.id)) continue;
      const w = Math.max(1, Number(info.w) || 0), h = Math.max(1, Number(info.h) || 0);
      seen.add(info.id);
      order.push(info.id);
      let win = state.windows.get(info.id);
      if (!win) {
        win = makeWindow(info.id);
        state.windows.set(info.id, win);
      }
      win.info = { id: info.id, title: String(info.title || ""), w, h, x: Number(info.x) || 0, y: Number(info.y) || 0,
        kind: typeof info.kind === "string" ? info.kind : "main", parent: Number.isInteger(info.parent) ? info.parent : null };
      win.el.dataset.kind = win.info.kind;
      // What the comment picker calls a spot in the window that has no element of its own.
      win.layer.setAttribute("aria-label", (win.info.title || state.appName) + (win.info.kind === "main" ? " window" : " " + win.info.kind));
      sizeCanvas(win, false);
    }
    for (const [id, win] of state.windows) {
      if (seen.has(id)) continue;
      removeWindow(win);
      state.windows.delete(id);
      if (state.activeWindow === id) state.activeWindow = null;
    }
    state.order = order;
    layout();
  }

  function makeWindow(id) {
    const el = document.createElement("section");
    el.className = "otm-window";
    el.dataset.window = String(id);
    const canvas = document.createElement("canvas");
    canvas.className = "otm-pixels";
    canvas.setAttribute("aria-hidden", "true");
    canvas.width = canvas.height = 1;
    const layer = document.createElement("div");
    layer.className = "otm-layer";
    el.append(canvas, layer);
    stage.appendChild(el);
    return {
      id, el, canvas, ctx: canvas.getContext("2d"), layer, info: null,
      items: new Map(), // key -> { el, node, kind }
      v: null, seq: 0, chain: Promise.resolve(), removed: false, optimistic: new Set(),
    };
  }

  function removeWindow(win) {
    win.removed = true;
    for (const item of win.optimistic) clearTimeout(item.revert);
    win.el.remove();
  }

  // Canvas backing store: the window's size in points times the frames' scale. Keeps what was drawn.
  function sizeCanvas(win, force) {
    const { w, h } = win.info || { w: 1, h: 1 };
    const pw = Math.max(1, Math.round(w * state.scale)), ph = Math.max(1, Math.round(h * state.scale));
    win.canvas.style.width = w + "px";
    win.canvas.style.height = h + "px";
    if (!force && win.canvas.width === pw && win.canvas.height === ph) return;
    let keep = null;
    if (win.canvas.width > 1 && win.canvas.height > 1) {
      keep = document.createElement("canvas");
      keep.width = win.canvas.width;
      keep.height = win.canvas.height;
      keep.getContext("2d").drawImage(win.canvas, 0, 0);
    }
    win.canvas.width = pw;
    win.canvas.height = ph;
    if (keep) win.ctx.drawImage(keep, 0, 0, keep.width * (force ? pw / keep.width : 1), keep.height * (force ? ph / keep.height : 1));
  }

  // Places the windows (relative to the main window), then scales the whole desk down to fit.
  function layout() {
    let minX = 0, minY = 0, maxX = 1, maxY = 1, first = true;
    state.order.forEach((id, i) => {
      const win = state.windows.get(id);
      const { x, y, w, h } = win.info;
      if (first) { minX = x; minY = y; maxX = x + w; maxY = y + h; first = false; }
      minX = Math.min(minX, x); minY = Math.min(minY, y); maxX = Math.max(maxX, x + w); maxY = Math.max(maxY, y + h);
      win.el.style.zIndex = String(i + 1);
    });
    state.bounds = { x: minX, y: minY, w: Math.max(1, maxX - minX), h: Math.max(1, maxY - minY) };
    for (const id of state.order) {
      const win = state.windows.get(id);
      const { x, y, w, h } = win.info;
      Object.assign(win.el.style, { left: x - minX + "px", top: y - minY + "px", width: w + "px", height: h + "px" });
    }
    fit();
  }

  function fit() {
    const { w, h } = state.bounds;
    const availW = Math.max(1, desk.clientWidth - PAD * 2), availH = Math.max(1, desk.clientHeight - PAD * 2);
    const f = Math.min(1, availW / w, availH / h);
    stage.style.width = w + "px";
    stage.style.height = h + "px";
    stage.style.transform = f === 1 ? "" : "scale(" + f + ")";
    fitBox.style.width = w * f + "px";
    fitBox.style.height = h * f + "px";
  }
  window.addEventListener("resize", fit);

  // ---------------------------------------------------------------- frames

  function onFrame(m) {
    const win = state.windows.get(m.window);
    if (win && Number.isInteger(m.seq)) win.seq = m.seq;
  }

  // One binary tile: a 17-byte big-endian header, then a JPEG or WebP image of w*scale by h*scale pixels.
  // Tiles decode in parallel and paint in arrival order.
  function onTile(buffer) {
    if (buffer.byteLength <= 17) return;
    const v = new DataView(buffer);
    const win = state.windows.get(v.getUint32(0));
    if (!win) return;
    const x = v.getUint16(8), y = v.getUint16(10), w = v.getUint16(12), h = v.getUint16(14);
    const type = v.getUint8(16) === 1 ? "image/webp" : "image/jpeg";
    const decoding = createImageBitmap(new Blob([new Uint8Array(buffer, 17)], { type })).catch(() => null);
    win.chain = win.chain.then(() => decoding).then((bitmap) => {
      if (!bitmap) return;
      if (!win.removed) {
        const s = state.scale;
        win.ctx.drawImage(bitmap, x * s, y * s, w * s, h * s);
      }
      bitmap.close();
    });
  }

  // ---------------------------------------------------------------- the accessibility layer

  // A full snapshot of one window's tree: reconcile by key, so elements (and comments pinned to them)
  // survive, and a field being typed in is never dropped or overwritten mid-word.
  function applyTree(m) {
    const win = state.windows.get(m.window);
    if (!win || !Array.isArray(m.nodes)) return;
    if (m.v !== win.v) {
      win.v = m.v;
      for (const item of [...win.optimistic]) settle(win, item);
    }
    const seen = new Set();
    let z = 0;
    for (const node of m.nodes) {
      if (!node || typeof node.key !== "string" || seen.has(node.key)) continue;
      seen.add(node.key);
      const kind = kindOf(node.role);
      let item = win.items.get(node.key);
      if (item && item.kind !== kind && document.activeElement !== item.el) {
        item.el.remove();
        item = null;
      }
      if (!item) {
        item = { el: makeNode(node.key, kind), kind, node, stale: false, revert: null };
        win.items.set(node.key, item);
        win.layer.appendChild(item.el);
      }
      item.node = node;
      item.stale = false;
      item.el.classList.remove("otm-stale");
      item.el.style.zIndex = String(++z);
      updateNode(win, item);
    }
    for (const [key, item] of win.items) {
      if (seen.has(key)) continue;
      if (item.el === document.activeElement) {
        // Gone from the app's tree while the viewer types in it: keep it until it loses focus.
        item.stale = true;
        item.el.classList.add("otm-stale");
        item.el.style.zIndex = String(++z);
        continue;
      }
      settle(win, item);
      item.el.remove();
      win.items.delete(key);
    }
  }

  function makeNode(key, kind) {
    let el;
    if (kind === "textarea") el = document.createElement("textarea");
    else if (kind === "node") el = document.createElement("div");
    else {
      el = document.createElement("input");
      el.type = kind === "password" ? "password" : "text";
    }
    if (kind !== "node") {
      el.className = "otm-node otm-field";
      el.autocomplete = kind === "password" ? "new-password" : "off";
      el.spellcheck = false;
      el.setAttribute("autocapitalize", "off");
      el.setAttribute("autocorrect", "off");
      el.setAttribute("data-1p-ignore", ""); // password managers: this isn't a login form on this site
      el.addEventListener("blur", () => onFieldBlur(el));
    } else {
      el.className = "otm-node";
    }
    el.id = domId(key);
    el.dataset.key = key;
    return el;
  }

  function updateNode(win, item) {
    const { el, node, kind } = item;
    const role = typeof node.role === "string" ? node.role : "";
    const label = typeof node.label === "string" ? node.label : "";
    const value = typeof node.value === "string" ? node.value : null;
    const n = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
    Object.assign(el.style, { left: n(node.x) + "px", top: n(node.y) + "px", width: Math.max(0, n(node.w)) + "px", height: Math.max(0, n(node.h)) + "px" });
    if (el.dataset.role !== role) el.dataset.role = role;
    const aria = kind === "node" ? ARIA[role] : null;
    setAttr(el, "role", aria || null);
    setAttr(el, "aria-label", label || null);
    setAttr(el, "aria-disabled", node.enabled === false ? "true" : null);
    setAttr(el, "aria-selected", node.selected === true ? "true" : null);
    if (CHECK_ROLES.has(role) && !win.optimistic.has(item)) setAttr(el, "aria-checked", value === "1" ? "true" : value === "2" ? "mixed" : "false");
    if ((role === "AXIncrementor" || role === "AXSlider" || role === "AXProgressIndicator") && value !== null && value !== "" && Number.isFinite(Number(value))) {
      setAttr(el, "aria-valuenow", value);
    } else setAttr(el, "aria-valuenow", null);
    if (kind === "node") {
      const text = TEXT_ROLES.has(role) ? label || (role === "AXStaticText" && value) || "" : "";
      if (el.textContent !== text) el.textContent = text;
      el.style.lineHeight = Math.max(0, n(node.h)) + "px";
    } else {
      el.disabled = node.enabled === false;
      const typing = Date.now() - (item.typedAt || 0) < TYPING_QUIET_MS;
      const mine = document.activeElement === el;
      if (value !== null && el.value !== value && !(mine && typing)) {
        const atEnd = mine && el.selectionStart === el.value.length && el.selectionEnd === el.value.length;
        el.value = value;
        if (atEnd) el.setSelectionRange(value.length, value.length);
      }
      if (node.focused === true && !mine && Date.now() - state.lastLocal > FOCUS_QUIET_MS && mayTakeFocus()) {
        el.focus({ preventScroll: true }); // the app moved its focus here (Tab, a sheet opening)
      }
    }
  }

  function setAttr(el, name, value) {
    if (value === null) {
      if (el.hasAttribute(name)) el.removeAttribute(name);
    } else if (el.getAttribute(name) !== value) el.setAttribute(name, value);
  }

  // The app may move focus into the layer only when the viewer isn't busy elsewhere on the page
  // (the comment box, say).
  function mayTakeFocus() {
    const a = document.activeElement;
    return !a || a === document.body || a === document.documentElement || stage.contains(a);
  }

  function onFieldBlur(el) {
    for (const win of state.windows.values()) {
      const item = win.items.get(el.dataset.key);
      if (item && item.el === el && item.stale) {
        el.remove();
        win.items.delete(el.dataset.key);
      }
    }
  }

  // ---------------------------------------------------------------- optimistic feedback

  function optimistic(win, item, apply, hold) {
    settle(win, item);
    apply();
    win.optimistic.add(item);
    item.revert = setTimeout(() => settle(win, item), hold || OPTIMISTIC_MS);
  }

  // Back to what the app said last.
  function settle(win, item) {
    clearTimeout(item.revert);
    item.revert = null;
    if (!win.optimistic.delete(item)) return;
    item.el.classList.remove("otm-pressed", "otm-flip-on", "otm-flip-off");
    if (CHECK_ROLES.has(item.node.role)) {
      const v = item.node.value;
      setAttr(item.el, "aria-checked", v === "1" ? "true" : v === "2" ? "mixed" : "false");
    }
  }

  // ---------------------------------------------------------------- input

  function modifiers(e) {
    const list = [];
    if (e.metaKey) list.push("cmd");
    if (e.shiftKey) list.push("shift");
    if (e.altKey) list.push("alt");
    if (e.ctrlKey) list.push("ctrl");
    return list;
  }

  const round = (v) => Math.round(v * 10) / 10;

  // The window under an event, the layer item it hit and the point in window points.
  function locate(e, win) {
    if (!win) {
      const el = e.target instanceof Element ? e.target.closest(".otm-window") : null;
      win = el ? state.windows.get(Number(el.dataset.window)) : null;
    }
    if (!win || !win.info) return null;
    const r = win.el.getBoundingClientRect();
    const f = r.width / win.info.w || 1;
    const nodeEl = e.target instanceof Element ? e.target.closest(".otm-node") : null;
    const item = nodeEl && nodeEl.dataset.key ? win.items.get(nodeEl.dataset.key) : null;
    return { win, item: item && item.el === nodeEl ? item : null, x: round((e.clientX - r.left) / f), y: round((e.clientY - r.top) / f) };
  }

  const isField = (item) => !!item && item.kind !== "node";
  const actions = (item) => (item && Array.isArray(item.node.actions) ? item.node.actions : []);
  const enabled = (item) => !!item && item.node.enabled !== false;
  // Elements a click acts on directly through accessibility, instead of a synthesized click.
  function clickAction(item) {
    if (!item || isField(item) || !enabled(item)) return null;
    if (item.node.role === "AXIncrementor" && actions(item).includes("increment")) return "halves";
    return actions(item).includes("press") ? "press" : null;
  }

  function pointer(win, kind, x, y, e, dx, dy) {
    state.activeWindow = win.id;
    return send({ t: "pointer", window: win.id, kind, x, y, dx: dx || 0, dy: dy || 0, modifiers: e ? modifiers(e) : [] });
  }

  let pressing = null; // { win, item } between pointerdown and click on a button
  let dragging = null; // { win, pointerId, right } between a synthesized down and up

  stage.addEventListener("pointerdown", (e) => {
    const hit = locate(e);
    if (!hit) return;
    state.lastLocal = Date.now();
    state.activeWindow = hit.win.id;
    if (e.button === 2) {
      dragging = { win: hit.win, pointerId: e.pointerId, right: true };
      pointer(hit.win, "rightdown", hit.x, hit.y, e);
      return;
    }
    if (e.button !== 0) return;
    if (clickAction(hit.item)) {
      pressing = { win: hit.win, item: hit.item };
      optimistic(hit.win, hit.item, () => hit.item.el.classList.add("otm-pressed"));
      if (document.activeElement && stage.contains(document.activeElement)) document.activeElement.blur();
      e.preventDefault();
      return;
    }
    dragging = { win: hit.win, pointerId: e.pointerId, right: false };
    if (!isField(hit.item)) {
      try { stage.setPointerCapture(e.pointerId); } catch { /* not capturable */ }
    }
    pointer(hit.win, "down", hit.x, hit.y, e);
  });

  stage.addEventListener("pointerup", (e) => {
    if (pressing) {
      const p = pressing;
      pressing = null;
      // The click (or not) decides; the pressed look lingers briefly, until the app's next tree.
      clearTimeout(p.item.revert);
      p.item.revert = setTimeout(() => settle(p.win, p.item), PRESS_HOLD_MS + 50);
      return;
    }
    if (!dragging || dragging.pointerId !== e.pointerId) return;
    const d = dragging;
    dragging = null;
    const hit = locate(e, d.win);
    if (hit) pointer(d.win, d.right ? "rightup" : "up", hit.x, hit.y, e);
    try { stage.releasePointerCapture(e.pointerId); } catch { /* not captured */ }
  });

  stage.addEventListener("pointercancel", (e) => {
    if (dragging && dragging.pointerId === e.pointerId) {
      const d = dragging;
      dragging = null;
      const hit = locate(e, d.win);
      if (hit) pointer(d.win, d.right ? "rightup" : "up", hit.x, hit.y, e);
    }
    if (pressing) {
      settle(pressing.win, pressing.item);
      pressing = null;
    }
  });

  stage.addEventListener("click", (e) => {
    const hit = locate(e);
    if (!hit || e.button !== 0) return;
    const how = clickAction(hit.item);
    if (!how) return;
    e.preventDefault();
    const { win, item } = hit;
    state.lastLocal = Date.now();
    if (how === "halves") {
      const r = item.el.getBoundingClientRect();
      const up = e.clientY < r.top + r.height / 2;
      send({ t: "act", window: win.id, key: item.node.key, action: up ? "increment" : "decrement" });
      return;
    }
    send({ t: "act", window: win.id, key: item.node.key, action: "press" });
    if (CHECK_ROLES.has(item.node.role)) {
      const was = item.el.getAttribute("aria-checked") === "true";
      if (item.node.role === "AXRadioButton" && was) return; // a radio button stays on
      optimistic(win, item, () => {
        item.el.classList.add(was ? "otm-flip-off" : "otm-flip-on");
        item.el.setAttribute("aria-checked", was ? "false" : "true");
      });
    }
  });

  stage.addEventListener("contextmenu", (e) => e.preventDefault());

  // Pointer moves: the latest position, at most 30 a second (with a trailing one so the last spot lands).
  let move = null, moveSent = 0, moveTimer = null;
  function flushMove() {
    moveTimer = null;
    if (!move) return;
    const m = move;
    move = null;
    moveSent = Date.now();
    pointer(m.win, "move", m.x, m.y, m.e);
  }
  stage.addEventListener("pointermove", (e) => {
    const hit = dragging ? locate(e, dragging.win) : locate(e);
    if (!hit) return;
    move = { win: hit.win, x: hit.x, y: hit.y, e: { metaKey: e.metaKey, shiftKey: e.shiftKey, altKey: e.altKey, ctrlKey: e.ctrlKey } };
    const wait = MOVE_INTERVAL - (Date.now() - moveSent);
    if (wait <= 0) flushMove();
    else if (!moveTimer) moveTimer = setTimeout(flushMove, wait);
  });

  // Wheel: deltas add up between sends (at most 60 a second); the page itself never scrolls.
  let wheel = null, wheelSent = 0, wheelTimer = null;
  function flushWheel() {
    wheelTimer = null;
    if (!wheel) return;
    const w = wheel;
    wheel = null;
    wheelSent = Date.now();
    pointer(w.win, "wheel", w.x, w.y, w.e, round(w.dx), round(w.dy));
  }
  stage.addEventListener("wheel", (e) => {
    const hit = locate(e);
    if (!hit) return;
    e.preventDefault();
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? hit.win.info.h : 1;
    const f = hit.win.el.getBoundingClientRect().width / hit.win.info.w || 1;
    const prev = wheel && wheel.win === hit.win ? wheel : { dx: 0, dy: 0 };
    wheel = { win: hit.win, x: hit.x, y: hit.y, dx: prev.dx + (e.deltaX * unit) / f, dy: prev.dy + (e.deltaY * unit) / f,
      e: { metaKey: e.metaKey, shiftKey: e.shiftKey, altKey: e.altKey, ctrlKey: e.ctrlKey } };
    const wait = WHEEL_INTERVAL - (Date.now() - wheelSent);
    if (wait <= 0) flushWheel();
    else if (!wheelTimer) wheelTimer = setTimeout(flushWheel, wait);
  }, { passive: false });

  // Typing in a field. Text comes from `input` events (so IMEs and dead keys work); only named keys
  // come from keydown. A plain insertion is sent as `text`; anything that replaced a selection, pasted,
  // undid or the like sends the field's whole new value as `setText`.
  const fieldOf = (target) => {
    if (!(target instanceof Element) || !target.classList.contains("otm-field")) return null;
    for (const win of state.windows.values()) {
      const item = win.items.get(target.dataset.key);
      if (item && item.el === target) return { win, item };
    }
    return null;
  };
  let collapsedBefore = true;
  let keySentAt = 0;

  stage.addEventListener("beforeinput", (e) => {
    const t = e.target;
    collapsedBefore = !(t && typeof t.selectionStart === "number") || t.selectionStart === t.selectionEnd;
  });

  stage.addEventListener("input", (e) => {
    const f = fieldOf(e.target);
    if (!f || e.isComposing || e.inputType === "insertCompositionText") return;
    const { win, item } = f;
    item.typedAt = state.lastLocal = Date.now();
    state.activeWindow = win.id;
    const type = e.inputType || "";
    if (type === "insertText" && e.data && collapsedBefore) {
      send({ t: "text", window: win.id, text: e.data });
    } else if ((type.startsWith("delete") && !type.startsWith("deleteBy") && collapsedBefore && Date.now() - keySentAt < 200) ||
               (type === "insertLineBreak" && Date.now() - keySentAt < 200)) {
      // Backspace, Delete or Enter: already sent as a key.
    } else {
      send({ t: "setText", window: win.id, key: item.node.key, value: item.el.value });
    }
  });

  stage.addEventListener("compositionend", (e) => {
    const f = fieldOf(e.target);
    if (!f || !e.data) return;
    f.item.typedAt = state.lastLocal = Date.now();
    send({ t: "text", window: f.win.id, text: e.data });
  });

  stage.addEventListener("keydown", (e) => {
    const f = fieldOf(e.target);
    if (!f || e.isComposing || e.keyCode === 229 || !NAMED_KEYS.has(e.key)) return;
    f.item.typedAt = state.lastLocal = Date.now();
    keySentAt = Date.now();
    send({ t: "key", window: f.win.id, code: e.key, modifiers: modifiers(e) });
    if (e.key === "Tab") e.preventDefault(); // the app moves its focus; ours follows its next tree
  });

  // Keys while no field of ours has focus (after clicking a button or a custom view in the app) go to
  // the app too, unless the page has another editable thing focused (the comment box, say).
  document.addEventListener("keydown", (e) => {
    if (e.defaultPrevented || e.isComposing || e.keyCode === 229) return;
    const t = e.target;
    if (t instanceof Element && (stage.contains(t) && t.classList.contains("otm-field"))) return;
    if (t instanceof Element && t !== document.body && t !== document.documentElement && !stage.contains(t)) return;
    if (t instanceof HTMLElement && t.isContentEditable) return;
    const id = state.activeWindow !== null && state.windows.has(state.activeWindow) ? state.activeWindow : state.order[0];
    if (id === undefined || !state.socket) return;
    const code = e.key === " " ? "Space" : e.key;
    if (NAMED_KEYS.has(code) || code === "Space") {
      if (e.metaKey && code !== "Space") return;
      send({ t: "key", window: id, code, modifiers: modifiers(e) });
      e.preventDefault();
    } else if ([...e.key].length === 1 && !e.metaKey && !e.ctrlKey) {
      send({ t: "text", window: id, text: e.key });
      e.preventDefault();
    }
  });

  // ---------------------------------------------------------------- cursor and status

  function setCursor(shape) {
    stage.style.cursor = CURSORS[shape] || "default";
  }

  function setStatus(s, message) {
    state.status = typeof s === "string" ? s : "running";
    state.statusMessage = typeof message === "string" && message.trim() ? message.trim() : null;
    if (!banner) return;
    if (state.status === "running") {
      banner.hidden = true;
      banner.textContent = "";
      delete banner.dataset.state;
      return;
    }
    const text = state.statusMessage || (STATUS_TEXT[state.status] || (() => state.appName + " is " + state.status + "."))(state.appName);
    banner.textContent = text;
    banner.dataset.state = state.status;
    banner.hidden = false;
  }

  setLive(false);
  connect();
})();
