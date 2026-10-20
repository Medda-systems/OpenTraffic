/*
 * OpenTraffic Mac app viewer, served at /__opentraffic/macapp/viewer.js by the mirror server.
 * Draws a shared Mac app's windows from frame tiles, lays real web elements over the pixels from the
 * app's accessibility tree (so the collaboration overlay picks, labels and pins them like any page),
 * and sends the viewer's clicks, scrolling and typing back, showing their effect at once. Every window
 * the app opens is a surface of its own: sheets, alerts, popovers and menus over their window, second
 * windows beside the main one (or as tabs when side by side would make everything too small). On small
 * screens (or when chosen in the bar) a Simple view shows the same trees as a page of real text and
 * web controls instead of the scaled window. The viewer tells the server the room it has and its color
 * scheme (`viewport`), so the host can size the app's window and pick its appearance for it, and
 * follows the host's control mode (`control`): watching only, or asking for control first.
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
  const GAP = 32; // between windows side by side, in points
  const TABS_H = 40; // room for the window tabs above the windows, CSS pixels
  const BEZEL = 14; // the phone frame around a simulated device's screen, in points
  const TAB_BELOW = 0.8; // tabs when side by side would scale the windows below this share of one at a time
  // Kinds drawn over the window they belong to (`parent`); the others are windows of their own.
  const ATTACHED = new Set(["sheet", "alert", "popover", "menu"]);
  const SIMPLE_BELOW = 700; // viewports narrower than this get the Simple view unless the viewer chose
  const VIEW_PREF = "opentraffic.macapp.view"; // localStorage: "simple" or "window", the viewer's choice
  const HAD_CONTROL = "opentraffic.macapp.control"; // sessionStorage: "1" while the host has given this page control
  const COLLAB_NAME = "__opentraffic_collab_name"; // collab.js's localStorage: the name this person goes by
  const COLLAB_CLIENT = "__opentraffic_collab_client"; // collab.js's localStorage: this browser's private id
  const VIEWPORT_DELAY = 250; // a resized browser says its new size after this much quiet
  const INPUT = new Set(["act", "pointer", "text", "key", "setText", "menuAction", "windowAction"]); // need control
  const SET_TEXT_INTERVAL = 120; // Simple view fields: at most this often a setText while typing
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
  const simpleRoot = $("otm-simple");
  const simpleWins = $("otm-s-windows");
  const thumb = $("otm-thumb");
  const simpleTitle = $("otm-s-title");
  if (!desk || !fitBox || !stage) return;

  const state = {
    boot: null, scale: 1, appName: "the app", appearance: "light",
    windows: new Map(), // id -> window surface
    order: [], // window ids, main first
    bounds: { x: 0, y: 0, w: 1, h: 1 },
    socket: null, attempt: 0, retry: null, status: "running", statusMessage: null,
    activeWindow: null, // the window keys go to when no field has focus
    tabbed: false, // the top-level windows show one at a time, as tabs
    tab: null, // the top-level window shown while tabbed
    lastLocal: 0, // when the viewer last clicked or typed
    simple: false, // the Simple view is showing (its elements carry the ids, not the layer's)
    viewPref: null, // "simple", "window" or null (by width)
    control: { mode: "everyone", you: true, requested: false, holder: null }, // the host's control mode, for this viewer
    asked: false, // this page asked for control (so "Give Back" makes sense; the host's page never asks)
    viewportSent: null, // the last viewport message, as JSON
    device: null, // { name, screen: { x, y, w, h, r } | null } for an iPhone app in the Simulator
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
    if (INPUT.has(message.t) && !state.control.you) return false; // the server would drop it anyway
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
      case "menu": return applyMenu(m);
      case "control": return applyControl(m);
      // (windowAction is client to server only.)
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
    state.device = readDevice(m.app && m.app.device);
    if (nameEl) nameEl.textContent = name === "the app" ? "Mac app" : name;
    if (simpleTitle) simpleTitle.textContent = name === "the app" ? "Mac app" : name;
    document.title = (name === "the app" ? "Mac app" : name) + " · OpenTraffic";
    if (iconEl && !iconEl.getAttribute("src")) {
      iconEl.onload = () => (iconEl.hidden = false);
      iconEl.onerror = () => (iconEl.hidden = true);
      iconEl.src = ICON_PATH;
    }
    setStatus("running", null);
    applyWindows(m.windows);
    // A new connection: the server knows nothing of this viewer yet.
    state.viewportSent = null;
    sendViewport();
    renderControl();
    if (readSession(HAD_CONTROL) === "1") requestControl(); // the host gave this page control before a drop or reload
  }

  // An iPhone app's device (`app.device`): its name and where its screen is in the Simulator's window.
  function readDevice(d) {
    if (!d || typeof d !== "object") return null;
    const s = d.screen && typeof d.screen === "object" ? d.screen : null;
    const ok = s && ["x", "y", "w", "h"].every((k) => Number.isFinite(Number(s[k]))) && Number(s.w) > 0 && Number(s.h) > 0;
    const screen = ok ? { x: Number(s.x), y: Number(s.y), w: Number(s.w), h: Number(s.h), r: Math.max(0, Number(s.radius) || 0) } : null;
    return { name: typeof d.name === "string" ? d.name : "", screen };
  }

  function clearAll() {
    closeMenu();
    menus.contextJSON = menus.dismissed = null;
    hideContext();
    for (const win of state.windows.values()) removeWindow(win);
    state.windows.clear();
    state.order = [];
    state.activeWindow = null;
    state.tab = null;
    layout();
  }

  function applyWindows(list) {
    if (!Array.isArray(list)) return;
    const seen = new Set();
    const order = [];
    const added = [];
    for (const info of list) {
      if (!info || typeof info !== "object" || !Number.isInteger(info.id) || seen.has(info.id)) continue;
      const w = Math.max(1, Number(info.w) || 0), h = Math.max(1, Number(info.h) || 0);
      seen.add(info.id);
      order.push(info.id);
      let win = state.windows.get(info.id);
      if (!win) {
        win = makeWindow(info.id);
        state.windows.set(info.id, win);
        added.push(win);
      }
      win.info = { id: info.id, title: String(info.title || ""), w, h, x: Number(info.x) || 0, y: Number(info.y) || 0,
        kind: typeof info.kind === "string" ? info.kind : "main", parent: Number.isInteger(info.parent) ? info.parent : null,
        focused: info.focused === true };
      win.el.dataset.kind = win.info.kind;
      if (win.info.focused) win.el.dataset.focused = "";
      else delete win.el.dataset.focused;
      // What the comment picker calls a spot in the window that has no element of its own.
      win.label = (win.info.title || state.appName) + (win.info.kind === "main" ? " window" : " " + win.info.kind);
      win.layer.setAttribute("aria-label", win.label);
      // Sheets and alerts hold their window until answered, like a modal dialog.
      const dialog = win.info.kind === "sheet" || win.info.kind === "alert";
      setAttr(win.el, "role", dialog ? "dialog" : null);
      setAttr(win.el, "aria-modal", dialog ? "true" : null);
      setAttr(win.el, "aria-label", dialog || win.info.kind === "popover" ? win.label : null);
      sizeCanvas(win, false);
    }
    for (const [id, win] of state.windows) {
      if (seen.has(id)) continue;
      removeWindow(win);
      state.windows.delete(id);
      if (state.activeWindow === id) state.activeWindow = null;
    }
    state.order = order;
    // A window that just opened comes to the front, as on a Mac: its tab shows when they are tabs.
    for (const win of added) if (win.info.focused && !parentOf(win)) state.tab = win.id;
    layout();
    scheduleSimple();
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
      items: new Map(), // key -> { el, node, kind, s (its Simple view element) }
      list: [], // the items of the latest tree, in its order
      s: null, // the window's Simple view container
      v: null, seq: 0, chain: Promise.resolve(), removed: false, optimistic: new Set(),
    };
  }

  function removeWindow(win) {
    win.removed = true;
    for (const item of win.optimistic) clearTimeout(item.revert);
    win.el.remove();
    if (win.s) win.s.remove();
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

  // The window a surface is drawn over (its parent while that is shown), or null for a window of its own.
  function parentOf(win) {
    const p = win && win.info && ATTACHED.has(win.info.kind) && win.info.parent !== null ? state.windows.get(win.info.parent) : null;
    return p && p !== win && p.info ? p : null;
  }
  // The window of its own a surface belongs to (itself for one).
  function topOf(win) {
    for (let i = 0; win && i < 8; i++) {
      const p = parentOf(win);
      if (!p) return win;
      win = p;
    }
    return win;
  }
  const tops = () => state.order.map((id) => state.windows.get(id)).filter((w) => w && w.info && !parentOf(w));
  const focusedTop = () => {
    for (const w of state.windows.values()) if (w.info && w.info.focused) return topOf(w);
    return null;
  };

  // How much fit-to-viewport would scale a w by h desk, with room for the tabs when they show.
  function fitFactor(w, h, tabbed) {
    const availW = Math.max(1, desk.clientWidth - PAD * 2), availH = Math.max(1, desk.clientHeight - PAD * 2 - (tabbed ? TABS_H : 0));
    return Math.min(1, availW / w, availH / h);
  }

  // Places the windows: the main one and second windows side by side (or one at a time, as tabs, when
  // side by side would make them much smaller), sheets, popovers and menus where the app has them over
  // their window, alerts centred on it. Then scales the whole desk down to fit.
  function layout() {
    const top = tops();
    const side = new Map();
    let x = 0, sideH = 1, maxW = 1, maxH = 1;
    for (const w of top) {
      side.set(w.id, x);
      x += w.info.w + GAP;
      sideH = Math.max(sideH, w.info.h);
      maxW = Math.max(maxW, w.info.w);
      maxH = Math.max(maxH, w.info.h);
    }
    const sideW = Math.max(1, x - GAP);
    const wasTabbed = state.tabbed;
    state.tabbed = top.length > 1 && !state.simple && fitFactor(sideW, sideH, false) < fitFactor(maxW, maxH, true) * TAB_BELOW;
    if (state.tabbed && !top.some((w) => w.id === state.tab)) state.tab = (focusedTop() || top[0]).id;
    if (!state.tabbed) state.tab = null;

    const placed = new Map(); // id -> { x, y, shown }
    function place(win, depth) {
      if (placed.has(win.id)) return placed.get(win.id);
      const p = depth < 8 ? parentOf(win) : null;
      let at;
      if (!p) {
        at = state.tabbed ? { x: 0, y: 0, shown: win.id === state.tab } : { x: side.has(win.id) ? side.get(win.id) : 0, y: 0, shown: true };
      } else {
        const pa = place(p, depth + 1);
        const i = win.info, pi = p.info;
        if (i.kind === "alert") {
          // Centred over its window; an alert sheet stays where the app put it, under the title bar.
          const dy = i.y - pi.y;
          at = { x: pa.x + (pi.w - i.w) / 2, y: pa.y + (dy >= 0 && dy + i.h <= pi.h ? dy : Math.max(0, (pi.h - i.h) / 3)), shown: pa.shown };
        } else {
          at = { x: pa.x + i.x - pi.x, y: pa.y + i.y - pi.y, shown: pa.shown };
        }
      }
      placed.set(win.id, at);
      return at;
    }
    let minX = 0, minY = 0, maxX = 1, maxY = 1, first = true;
    state.order.forEach((id, index) => {
      const win = state.windows.get(id);
      if (!win || !win.info) return;
      const at = place(win, 0);
      win.el.style.zIndex = String(index + 1);
      win.el.classList.toggle("otm-hidden", !at.shown);
      if (!at.shown || parentOf(win)) return; // the windows of their own decide the desk's size; surfaces may overhang
      const { w, h } = win.info;
      if (first) { minX = at.x; minY = at.y; maxX = at.x + w; maxY = at.y + h; first = false; }
      minX = Math.min(minX, at.x); minY = Math.min(minY, at.y); maxX = Math.max(maxX, at.x + w); maxY = Math.max(maxY, at.y + h);
    });
    state.bounds = { x: minX, y: minY, w: Math.max(1, maxX - minX), h: Math.max(1, maxY - minY) };
    // A simulated device: only its screen shows, in a phone frame, and the desk is the phone's size.
    const phone = phoneFrame(top, placed);
    if (phone) {
      minX = phone.x;
      minY = phone.y;
      state.bounds = { x: phone.x, y: phone.y, w: phone.w, h: phone.h };
    }
    for (const id of state.order) {
      const win = state.windows.get(id);
      if (!win || !win.info) continue;
      const at = placed.get(id);
      const { w, h } = win.info;
      Object.assign(win.el.style, { left: at.x - minX + "px", top: at.y - minY + "px", width: w + "px", height: h + "px" });
    }
    applyPhone(phone);
    syncMenuSurfaces();
    renderTabs(top);
    if (wasTabbed !== state.tabbed) desk.classList.toggle("otm-desk-tabbed", state.tabbed);
    fit();
  }

  // The phone around a simulated device's screen: its window (the Simulator's) is the only one, and
  // the screen was found in it. Desk coordinates of the frame, its screen and its window.
  function phoneFrame(top, placed) {
    const screen = state.device && state.device.screen;
    if (!screen || top.length !== 1 || state.tabbed) return null;
    const win = top[0], at = placed.get(win.id);
    if (!at || !at.shown) return null;
    return { win, s: screen, x: at.x + screen.x - BEZEL, y: at.y + screen.y - BEZEL, w: screen.w + 2 * BEZEL, h: screen.h + 2 * BEZEL };
  }

  // Clips the device's window to its screen (rounded like the device's) and puts the frame behind it.
  // The window keeps its size and points, so taps, the layer and comments stay where they are.
  const bezel = document.createElement("div");
  bezel.className = "otm-bezel";
  bezel.setAttribute("aria-hidden", "true");
  bezel.hidden = true;
  stage.prepend(bezel);

  function applyPhone(phone) {
    for (const win of state.windows.values()) {
      if (phone && win === phone.win) {
        const { s } = phone, { w, h } = win.info;
        win.el.dataset.device = "";
        win.el.style.clipPath = "inset(" + s.y + "px " + Math.max(0, w - s.x - s.w) + "px " + Math.max(0, h - s.y - s.h) + "px " + s.x + "px round " + s.r + "px)";
      } else if (win.el.dataset.device !== undefined) {
        delete win.el.dataset.device;
        win.el.style.clipPath = "";
      }
    }
    bezel.hidden = !phone;
    if (phone) Object.assign(bezel.style, { left: "0px", top: "0px", width: phone.w + "px", height: phone.h + "px", borderRadius: phone.s.r + BEZEL + "px" });
    document.body.classList.toggle("otm-phone", !!phone);
  }

  // A menu the app popped up shows as a web menu (with real, choosable items) where the app put it;
  // its pixels only show while there is no web menu for it.
  function syncMenuSurfaces() {
    for (const win of state.windows.values()) {
      if (win.info && win.info.kind === "menu") win.el.classList.toggle("otm-covered", !!contextBox);
    }
  }

  // The window tabs, while the windows show one at a time.
  const tabsEl = document.createElement("div");
  tabsEl.className = "otm-tabs";
  tabsEl.setAttribute("role", "tablist");
  tabsEl.setAttribute("aria-label", "Windows");
  tabsEl.setAttribute("data-opentraffic-ui", "");
  tabsEl.hidden = true;
  desk.prepend(tabsEl);

  function renderTabs(top) {
    tabsEl.hidden = !state.tabbed;
    if (!state.tabbed) {
      if (tabsEl.childElementCount) tabsEl.textContent = "";
      return;
    }
    const want = top.map((w) => w.id).join(",") + "|" + state.tab + "|" + state.control.you + "|" + top.map((w) => w.info.title).join("\u0000");
    if (tabsEl.dataset.want === want) return;
    tabsEl.dataset.want = want;
    tabsEl.textContent = "";
    for (const w of top) {
      const tab = document.createElement("span");
      tab.className = "otm-tab";
      tab.dataset.window = String(w.id);
      const b = document.createElement("button");
      b.type = "button";
      b.className = "otm-tab-title";
      b.setAttribute("role", "tab");
      b.setAttribute("aria-selected", String(w.id === state.tab));
      b.textContent = w.info.title || (w.info.kind === "main" ? state.appName : "Window");
      b.addEventListener("click", () => showTab(w.id));
      tab.appendChild(b);
      if (w.info.kind !== "main" && state.control.you) {
        const x = document.createElement("button");
        x.type = "button";
        x.className = "otm-tab-close";
        x.setAttribute("aria-label", "Close " + (w.info.title || "window"));
        x.textContent = "×";
        x.addEventListener("click", () => send({ t: "windowAction", window: w.id, action: "close" }));
        tab.appendChild(x);
      }
      tabsEl.appendChild(tab);
    }
  }

  // Shows a window's tab and makes it the app's key window, so typing goes there.
  function showTab(id) {
    state.tab = id;
    state.activeWindow = id;
    send({ t: "windowAction", window: id, action: "focus" });
    layout();
  }

  function fit() {
    const { w, h } = state.bounds;
    const f = fitFactor(w, h, state.tabbed);
    stage.style.width = w + "px";
    stage.style.height = h + "px";
    stage.style.transform = f === 1 ? "" : "scale(" + f + ")";
    fitBox.style.width = w * f + "px";
    fitBox.style.height = h * f + "px";
  }
  window.addEventListener("resize", () => layout());

  // ---------------------------------------------------------------- viewport and appearance
  //
  // The room the main window has here (the desk less its margins, CSS pixels = points at scale 1) and
  // the browser's color scheme: the host may resize the app's window to fill it and show the app in
  // the viewer's appearance. The Simple view has no size wish (0 by 0); only its scheme counts.

  const darkQuery = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
  const lightQuery = window.matchMedia ? window.matchMedia("(prefers-color-scheme: light)") : null;
  function colorScheme() {
    if (darkQuery && darkQuery.matches) return "dark";
    if (lightQuery && lightQuery.matches) return "light";
    return null;
  }

  function currentViewport() {
    if (state.simple || desk.hidden) return { t: "viewport", w: 0, h: 0, appearance: colorScheme() };
    const w = Math.max(0, Math.floor(desk.clientWidth - PAD * 2));
    const h = Math.max(0, Math.floor(desk.clientHeight - PAD * 2 - (state.tabbed ? TABS_H : 0)));
    return { t: "viewport", w, h, appearance: colorScheme() };
  }

  function sendViewport() {
    const m = currentViewport();
    const json = JSON.stringify(m);
    if (json === state.viewportSent) return;
    if (send(m)) state.viewportSent = json;
  }

  let viewportTimer = null;
  function viewportSoon() {
    clearTimeout(viewportTimer);
    viewportTimer = setTimeout(sendViewport, VIEWPORT_DELAY);
  }
  window.addEventListener("resize", viewportSoon);
  for (const q of [darkQuery, lightQuery]) if (q && q.addEventListener) q.addEventListener("change", sendViewport);

  // ---------------------------------------------------------------- control
  //
  // `control` says whether this viewer may drive the app. Without it (watch only, or ask to control
  // before the host allowed) nothing is sent and nothing reacts as if it was: fields are read-only,
  // menus and the tab close buttons go away, and the desktop bar says why, with Request Control when
  // the host takes requests. The collaboration overlay (cursors, comments) works the same either way.

  function readSession(key) {
    try { return sessionStorage.getItem(key); } catch { return null; }
  }
  function writeSession(key, value) {
    try { value === null ? sessionStorage.removeItem(key) : sessionStorage.setItem(key, value); } catch { /* private mode */ }
  }
  function readLocal(key) {
    try { return localStorage.getItem(key); } catch { return null; }
  }

  const controlEl = document.createElement("span");
  controlEl.className = "otm-control";
  controlEl.setAttribute("data-opentraffic-ui", "");
  controlEl.setAttribute("role", "status");
  controlEl.hidden = true;
  const controlText = document.createElement("span");
  controlText.className = "otm-control-text";
  const controlButton = document.createElement("button");
  controlButton.type = "button";
  controlButton.className = "otm-control-button";
  controlButton.setAttribute("data-opentraffic-ui", "");
  controlEl.append(controlText, controlButton);
  {
    const views = document.querySelector(".otm-views");
    const barEl = $("otm-bar");
    if (views) views.before(controlEl);
    else if (barEl) barEl.appendChild(controlEl);
  }

  function requestControl() {
    const name = (readLocal(COLLAB_NAME) || "").trim().slice(0, 32) || null;
    const client = readLocal(COLLAB_CLIENT) || null;
    state.asked = true;
    send({ t: "requestControl", name, client });
  }

  controlButton.addEventListener("click", () => {
    const c = state.control;
    if (c.mode !== "askToControl") return;
    if (c.you || c.requested) {
      writeSession(HAD_CONTROL, null);
      state.asked = false;
      send({ t: "releaseControl" });
    } else requestControl();
  });

  function applyControl(m) {
    const mode = m.mode === "watchOnly" || m.mode === "askToControl" ? m.mode : "everyone";
    const c = { mode, you: m.you !== false, requested: m.requested === true, holder: typeof m.holder === "string" && m.holder ? m.holder : null };
    const was = state.control;
    state.control = c;
    if (mode === "askToControl" && c.you && state.asked) writeSession(HAD_CONTROL, "1");
    else if (!c.you || mode !== "askToControl") writeSession(HAD_CONTROL, null);
    if (!c.requested && !c.you) state.asked = false;
    document.body.dataset.control = c.you ? "yes" : "no";
    for (const el of document.querySelectorAll(".otm-field, .otm-s-field")) el.readOnly = !c.you;
    if (!c.you) {
      // Whatever was under way stops here: menus, a press, a drag.
      closeMenu();
      hideContext();
      if (document.activeElement && (stage.contains(document.activeElement) || (simpleRoot && simpleRoot.contains(document.activeElement)))) document.activeElement.blur();
    }
    renderControl();
    if (was.you !== c.you) layout();
  }

  function renderControl() {
    const c = state.control;
    const app = state.appName === "the app" ? "the app" : state.appName;
    let text = "", button = "", title = "";
    if (c.mode === "watchOnly") {
      if (!c.you) {
        text = "Watching only";
        title = "The host lets viewers watch " + app + ", not click or type in it. Comments still work.";
      }
    } else if (c.mode === "askToControl") {
      if (c.you && state.asked) {
        text = "You have control";
        button = "Give Back";
        title = "The host gave you control of " + app + ". Give it back when you're done.";
      } else if (c.you) {
        text = "";
      } else if (c.requested) {
        text = "Asked the host…";
        button = "Cancel";
        title = "Waiting for the host to give you control of " + app + ".";
      } else {
        text = c.holder ? c.holder + " has control" : "Watching";
        button = "Request Control";
        title = "Ask the host to let you click and type in " + app + ".";
      }
    }
    controlText.textContent = text;
    controlButton.textContent = button;
    controlButton.hidden = !button;
    controlEl.title = title;
    controlEl.hidden = !text && !button;
    controlEl.dataset.mode = c.mode;
  }

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
        scheduleThumbs();
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
    const list = [];
    let z = 0;
    for (const node of m.nodes) {
      if (!node || typeof node.key !== "string" || seen.has(node.key)) continue;
      seen.add(node.key);
      const kind = kindOf(node.role);
      let item = win.items.get(node.key);
      if (item && item.kind !== kind && !hasFocus(item)) {
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
      list.push(item);
    }
    win.list = list;
    for (const [key, item] of win.items) {
      if (seen.has(key)) continue;
      if (hasFocus(item)) {
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
    scheduleSimple();
  }

  const hasFocus = (item) => document.activeElement === item.el || (!!item.s && document.activeElement === item.s);

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
      el.readOnly = !state.control.you;
      el.addEventListener("blur", () => onFieldBlur(el));
    } else {
      el.className = "otm-node";
    }
    if (!state.simple) el.id = domId(key); // the view that shows carries the ids
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
      syncValue(item, el, value);
      if (node.focused === true && !state.simple && document.activeElement !== el && Date.now() - state.lastLocal > FOCUS_QUIET_MS && mayTakeFocus()) {
        el.focus({ preventScroll: true }); // the app moved its focus here (Tab, a sheet opening)
      }
    }
  }

  // The app's value into one of our fields, unless the viewer is typing in it right now.
  function syncValue(item, el, value) {
    const typing = Date.now() - (item.typedAt || 0) < TYPING_QUIET_MS;
    const mine = document.activeElement === el;
    if (value !== null && el.value !== value && !(mine && typing)) {
      const atEnd = mine && el.selectionStart === el.value.length && el.selectionEnd === el.value.length;
      el.value = value;
      if (atEnd) el.setSelectionRange(value.length, value.length);
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
      if (item && (item.el === el || item.s === el) && item.stale) {
        item.el.remove();
        if (item.s) item.s.remove();
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
    if (item.s) {
      item.s.classList.remove("otm-pressed");
      if (item.s.__input) syncCheck(item);
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
    if (!state.control.you) return;
    const hit = locate(e);
    if (!hit) return;
    state.lastLocal = Date.now();
    state.activeWindow = hit.win.id;
    // A press in another window of its own makes that one the app's key window first, as a click would.
    const top = topOf(hit.win), focused = focusedTop();
    if (top && focused && top !== focused) send({ t: "windowAction", window: top.id, action: "focus" });
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
    if (!state.control.you) return;
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
    if (!state.control.you) return;
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
    if (!state.control.you) return;
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
    if (e.defaultPrevented || e.isComposing || e.keyCode === 229 || !state.control.you) return;
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

  // ---------------------------------------------------------------- the Simple view
  //
  // On a phone the window scaled down is unreadable, so below SIMPLE_BELOW px (or when the viewer picks
  // it in the bar) the windows give way to a page built from the same trees: containers become
  // sections, text real text, controls web controls, in reading order, with a live thumbnail of the real
  // window on top. Its elements are made from the same items as the layer and carry the same ids
  // (ax-<hash>); only the view that shows carries them, so a comment's `#ax-…` anchor finds the element
  // in either view. Taps and typing become the same protocol messages: act, setText, key, pointer.

  const SECTION_ROLES = new Set(["AXWindow", "AXGroup", "AXSplitGroup", "AXScrollArea", "AXTabGroup", "AXToolbar",
    "AXRadioGroup", "AXSheet", "AXLayoutArea", "AXLayoutItem", "AXBrowser", "AXDrawer", "AXGrid", "AXMenu"]);
  const LIST_ROLES = new Set(["AXList", "AXTable", "AXOutline"]);
  const BUTTON_ROLES = new Set(["AXButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle", "AXMenuItem",
    "AXMenuBarItem", "AXLink"]);
  const SKIP_ROLES = new Set(["AXScrollBar", "AXSplitter", "AXGrowArea", "AXValueIndicator", "AXMenuBar"]);
  const HOLDERS = new Set(["section", "list", "row"]); // Simple kinds whose children are laid out inside them
  const TOL = 2; // points two frames may overlap and still count as separate rows or columns

  const textOf = (node) => (typeof node.label === "string" && node.label) || (typeof node.value === "string" ? node.value : "");

  // What a node becomes in the Simple view, or null for nothing.
  function simpleKind(node, hasKids) {
    const role = typeof node.role === "string" ? node.role : "";
    if (SKIP_ROLES.has(role)) return null;
    const kind = kindOf(role);
    if (kind !== "node") return kind; // text, password, textarea
    if (CHECK_ROLES.has(role)) return "check";
    if (role === "AXIncrementor" || role === "AXSlider") return "stepper";
    if (BUTTON_ROLES.has(role)) return "button";
    if (role === "AXHeading") return "heading";
    if (role === "AXStaticText") return "static";
    if (role === "AXImage") return "image";
    if (role === "AXProgressIndicator") return "progress";
    if (LIST_ROLES.has(role)) return "list";
    if (role === "AXRow" || role === "AXCell") return "row";
    if (hasKids || SECTION_ROLES.has(role)) return "section";
    return textOf(node) ? "static" : null;
  }

  function makeSimple(item, sk) {
    const role = item.node.role;
    const tag = { section: "section", list: "div", row: "div", heading: "h2", static: "p", button: "button", check: "label",
      stepper: "div", image: "canvas", progress: "div", textarea: "textarea" }[sk] || "input"; // input: text, password
    const el = document.createElement(tag);
    el.className = "otm-s-node otm-s-" + sk;
    el.__sk = sk;
    if (sk === "section" || sk === "list") {
      el.__head = document.createElement("div");
      el.__head.className = "otm-s-head";
      el.__body = document.createElement("div");
      el.__body.className = "otm-s-body";
      if (sk === "list") el.setAttribute("role", "list");
      el.append(el.__head, el.__body);
    } else if (sk === "row") {
      el.setAttribute("role", "listitem");
      el.__body = el;
    } else if (sk === "heading" || sk === "static") {
      el.className = "otm-s-node otm-s-text" + (sk === "heading" ? " otm-s-title" : "");
    } else if (sk === "button") {
      el.type = "button";
      el.__label = document.createElement("span");
      el.__value = document.createElement("span");
      el.__value.className = "otm-s-popvalue";
      el.append(el.__label, el.__value);
      if (role === "AXPopUpButton" || role === "AXMenuButton") {
        const chev = document.createElement("span");
        chev.className = "otm-s-chev";
        chev.setAttribute("aria-hidden", "true");
        el.append(chev);
      }
    } else if (sk === "check") {
      el.__input = document.createElement("input");
      el.__input.type = "checkbox";
      el.__label = document.createElement("span");
      el.append(el.__input, el.__label);
    } else if (sk === "stepper") {
      el.setAttribute("role", role === "AXSlider" ? "slider" : "spinbutton");
      el.tabIndex = 0;
      const part = (cls, text) => {
        const p = document.createElement("span");
        p.className = cls;
        p.textContent = text;
        return p;
      };
      el.__value = part("otm-s-value", "");
      el.append(part("otm-s-minus", "−"), el.__value, part("otm-s-plus", "+"));
      el.lastChild.setAttribute("aria-hidden", "true");
      el.firstChild.setAttribute("aria-hidden", "true");
    } else if (sk === "image") {
      el.setAttribute("role", "img");
      el.width = el.height = 1;
    } else if (sk === "progress") {
      el.setAttribute("role", "progressbar");
      el.__bar = document.createElement("span");
      el.append(el.__bar);
    } else {
      // A field: text, password or textarea.
      if (sk !== "textarea") el.type = sk === "password" ? "password" : "text";
      el.className = "otm-s-node otm-s-field";
      el.readOnly = !state.control.you;
      el.autocomplete = sk === "password" ? "new-password" : "off";
      el.spellcheck = false;
      el.setAttribute("autocapitalize", "off");
      el.setAttribute("autocorrect", "off");
      el.setAttribute("data-1p-ignore", "");
      el.addEventListener("blur", () => {
        if (pendingText && pendingText.el === el) flushSetText();
        onFieldBlur(el);
      });
    }
    if (state.simple) el.id = domId(item.node.key);
    el.dataset.key = item.node.key;
    return el;
  }

  function setText(el, text) {
    if (el.textContent !== text) el.textContent = text;
  }

  function syncCheck(item) {
    const v = item.node.value;
    item.s.__input.checked = v === "1";
    item.s.__input.indeterminate = v === "2";
  }

  function updateSimple(win, item, root) {
    const el = item.s, node = item.node, sk = el.__sk;
    const role = typeof node.role === "string" ? node.role : "";
    const label = typeof node.label === "string" ? node.label : "";
    const value = typeof node.value === "string" ? node.value : null;
    const off = node.enabled === false;
    if (el.dataset.role !== role) el.dataset.role = role;
    setAttr(el, "aria-label", label || (root ? win.label : null));
    setAttr(el, "aria-disabled", off ? "true" : null);
    if (sk === "section" || sk === "list") {
      el.classList.toggle("otm-s-root", !!root);
      el.classList.toggle("otm-s-card", sk === "section" && !root && !!label);
      setText(el.__head, root && win.info.kind === "main" ? "" : label || (root ? win.info.title : ""));
    } else if (sk === "row") {
      setAttr(el, "aria-selected", node.selected === true ? "true" : null);
    } else if (sk === "static") {
      setText(el, textOf(node));
      el.classList.toggle("otm-s-title", role === "AXHeading" || (Number(node.h) >= 22 && textOf(node).length <= 60));
    } else if (sk === "heading") {
      setText(el, textOf(node));
    } else if (sk === "button") {
      el.disabled = off;
      setText(el.__label, label || value || "Button");
      setText(el.__value, label && value && value !== label ? value : "");
    } else if (sk === "check") {
      const radio = role === "AXRadioButton";
      if (el.__input.type !== (radio ? "radio" : "checkbox")) el.__input.type = radio ? "radio" : "checkbox";
      el.__input.disabled = off;
      el.__input.tabIndex = -1; // the label is the control; the box inside follows it
      el.tabIndex = off ? -1 : 0;
      setAttr(el, "role", radio ? "radio" : "checkbox");
      if (!win.optimistic.has(item)) syncCheck(item);
      setAttr(el, "aria-checked", el.__input.indeterminate ? "mixed" : el.__input.checked ? "true" : "false");
      setText(el.__label, label);
    } else if (sk === "stepper") {
      setText(el.__value, value === null ? "" : value);
      setAttr(el, "aria-valuenow", value !== null && value !== "" && Number.isFinite(Number(value)) ? value : null);
    } else if (sk === "image") {
      const s = state.scale, w = Math.max(1, Math.round(Number(node.w) || 1)), h = Math.max(1, Math.round(Number(node.h) || 1));
      if (el.width !== Math.round(w * s) || el.height !== Math.round(h * s)) {
        el.width = Math.round(w * s);
        el.height = Math.round(h * s);
      }
      el.style.width = w + "px";
    } else if (sk === "progress") {
      const n = Number(value);
      const pct = value === null || value === "" || !Number.isFinite(n) ? null : Math.max(0, Math.min(100, n <= 1 ? n * 100 : n));
      el.__bar.style.width = pct === null ? "" : pct + "%";
      el.classList.toggle("otm-s-indeterminate", pct === null);
      setAttr(el, "aria-valuenow", pct === null ? null : String(Math.round(pct)));
    } else {
      el.disabled = off;
      if (el.placeholder !== label) el.placeholder = label;
      syncValue(item, el, value);
    }
  }

  // Reading order for one container's children: split into rows where nothing spans the gap, a row's
  // leaf controls side by side become one line (label, field, stepper), and anything else splits into
  // columns at its widest gap, read left column first. Returns blocks: an item, or an array (a line).
  function readingOrder(items) {
    const n = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
    const top = (i) => n(i.node.y), bottom = (i) => n(i.node.y) + Math.max(0, n(i.node.h));
    const left = (i) => n(i.node.x), right = (i) => n(i.node.x) + Math.max(0, n(i.node.w));
    const inline = (i) => !HOLDERS.has(i.s.__sk) && i.s.__sk !== "image" && n(i.node.h) <= 60;
    const byYX = (a, b) => top(a) - top(b) || left(a) - left(b);
    const byXY = (a, b) => left(a) - left(b) || top(a) - top(b);
    function split(list, start, end, sort) {
      const sorted = [...list].sort(sort);
      const parts = [[sorted[0]]];
      let reach = end(sorted[0]);
      for (const it of sorted.slice(1)) {
        if (start(it) >= reach - TOL) parts.push([it]);
        else parts[parts.length - 1].push(it);
        reach = parts[parts.length - 1].length === 1 ? end(it) : Math.max(reach, end(it));
      }
      return parts;
    }
    function cut(list) {
      if (list.length <= 1) return list;
      const rows = split(list, top, bottom, byYX);
      if (rows.length > 1) return rows.flatMap(cut);
      if (list.every(inline)) return [[...list].sort(byXY)];
      const cols = split(list, left, right, byXY);
      if (cols.length > 1) {
        // Split at the widest gap only; each side is cut again.
        let at = 1, gap = -Infinity;
        for (let i = 1; i < cols.length; i++) {
          const g = Math.min(...cols[i].map(left)) - Math.max(...cols[i - 1].map(right));
          if (g > gap) { gap = g; at = i; }
        }
        return [...cut(cols.slice(0, at).flat()), ...cut(cols.slice(at).flat())];
      }
      return [...list].sort(byYX);
    }
    return cut(items);
  }

  // Puts `els` into `parent` in this order, moving only what's out of place (moving a focused field
  // would blur it). Anything else in `parent` goes, except an element the viewer is typing in.
  function placeChildren(parent, els) {
    els.forEach((el, i) => {
      const at = parent.children[i];
      if (at !== el) parent.insertBefore(el, at || null);
    });
    for (const extra of [...parent.children].slice(els.length)) {
      if (!extra.contains(document.activeElement)) extra.remove();
    }
  }

  function placeBlocks(body, blocks) {
    const lines = body.__lines || (body.__lines = new Map());
    const used = new Map();
    const els = blocks.map((b) => {
      if (!Array.isArray(b)) {
        if (b.s.__sk === "stepper") b.s.classList.remove("otm-s-novalue");
        return b.s;
      }
      const id = b[0].node.key;
      let line = lines.get(id);
      if (!line) {
        line = document.createElement("div");
        line.className = "otm-s-line";
      }
      used.set(id, line);
      for (const it of b) {
        // A stepper next to text already showing its number doesn't show it twice.
        if (it.s.__sk === "stepper") it.s.classList.toggle("otm-s-novalue", b.some((o) => o !== it && o.s.__sk === "static" && textOf(o.node) === it.node.value));
      }
      placeChildren(line, b.map((it) => it.s));
      return line;
    });
    body.__lines = used;
    if (body.firstChild && body.firstChild.nodeType === Node.TEXT_NODE) body.textContent = ""; // a row that had only text
    placeChildren(body, els);
  }

  // Builds (or updates) the Simple element of `item` and everything under it; null when it shows nothing.
  function buildSimple(win, kids, item, root) {
    const children = kids.get(item) || [];
    let sk = simpleKind(item.node, children.length > 0);
    if (!sk) return null;
    if (!item.s || item.s.__sk !== sk) {
      if (item.s && item.s === document.activeElement) sk = item.s.__sk;
      else {
        if (item.s) item.s.remove();
        item.s = makeSimple(item, sk);
      }
    }
    updateSimple(win, item, root);
    if (!HOLDERS.has(sk)) return item.s;
    const shown = children.filter((c) => buildSimple(win, kids, c, false));
    if (sk === "row" && !shown.length) {
      setText(item.s, textOf(item.node));
      return item.s;
    }
    placeBlocks(item.s.__body, readingOrder(shown));
    if (!shown.length && !(typeof item.node.label === "string" && item.node.label)) return root ? item.s : null;
    return item.s;
  }

  function renderSimpleWindow(win) {
    if (!win.s) {
      win.s = document.createElement("div");
      win.s.className = "otm-s-window";
      win.s.dataset.window = String(win.id);
    }
    win.s.dataset.kind = win.info.kind;
    win.s.setAttribute("aria-label", win.label || "");
    if (win.info.kind === "sheet" || win.info.kind === "alert") win.s.setAttribute("role", "dialog");
    // Parents from depth: nodes come parent first.
    const kids = new Map(), roots = [], stack = [];
    for (const item of win.list) {
      const d = Number.isFinite(Number(item.node.depth)) ? Number(item.node.depth) : 1;
      while (stack.length && stack[stack.length - 1].d >= d) stack.pop();
      const parent = stack.length ? stack[stack.length - 1].item : null;
      if (parent) {
        if (!kids.has(parent)) kids.set(parent, []);
        kids.get(parent).push(item);
      } else roots.push(item);
      stack.push({ item, d });
    }
    placeChildren(win.s, roots.map((r) => buildSimple(win, kids, r, true)).filter(Boolean));
  }

  let simpleQueued = false;
  function scheduleSimple() {
    if (!state.simple || simpleQueued) return;
    simpleQueued = true;
    requestAnimationFrame(() => {
      simpleQueued = false;
      renderSimple();
    });
  }

  function renderSimple() {
    if (!state.simple || !simpleWins) return;
    const els = [];
    for (const id of state.order) {
      const win = state.windows.get(id);
      if (!win || !win.info || win.info.kind === "menu") continue; // a menu shows as the web context menu
      renderSimpleWindow(win);
      els.push(win.s);
    }
    placeChildren(simpleWins, els);
    const main = state.windows.get(state.order[0]);
    if (simpleTitle) simpleTitle.textContent = main && main.info.title ? main.info.title : state.appName === "the app" ? "Mac app" : state.appName;
    scheduleThumbs();
  }

  // The live thumbnail of the main window, and image elements cut from the windows' pixels.
  let thumbQueued = false;
  function scheduleThumbs() {
    if (!state.simple || thumbQueued) return;
    thumbQueued = true;
    requestAnimationFrame(drawThumbs);
  }
  function drawThumbs() {
    thumbQueued = false;
    if (!state.simple) return;
    const main = state.windows.get(state.order[0]);
    if (thumb && main && main.info) {
      const h = thumb.clientHeight || 56;
      const w = Math.max(1, Math.round(Math.min(h * (main.info.w / main.info.h), 160)));
      const dpr = window.devicePixelRatio || 1;
      if (thumb.style.width !== w + "px") thumb.style.width = w + "px";
      if (thumb.width !== Math.round(w * dpr) || thumb.height !== Math.round(h * dpr)) {
        thumb.width = Math.round(w * dpr);
        thumb.height = Math.round(h * dpr);
      }
      const ctx = thumb.getContext("2d");
      ctx.imageSmoothingQuality = "high";
      ctx.drawImage(main.canvas, 0, 0, thumb.width, thumb.height);
    }
    for (const win of state.windows.values()) {
      for (const item of win.list) {
        if (!item.s || item.s.__sk !== "image" || !item.s.isConnected) continue;
        const s = state.scale, n = item.node;
        const ctx = item.s.getContext("2d");
        ctx.clearRect(0, 0, item.s.width, item.s.height);
        ctx.drawImage(win.canvas, (Number(n.x) || 0) * s, (Number(n.y) || 0) * s, item.s.width, item.s.height, 0, 0, item.s.width, item.s.height);
      }
    }
  }

  // The Simple element under an event target, with its window and item.
  function simpleHit(target) {
    const el = target instanceof Element ? target.closest(".otm-s-node") : null;
    const winEl = el ? el.closest(".otm-s-window") : null;
    const win = winEl ? state.windows.get(Number(winEl.dataset.window)) : null;
    const item = win ? win.items.get(el.dataset.key) : null;
    return item && item.s === el ? { win, item, el } : null;
  }

  // A tap on something without an action of its own (a row, say): a click at its centre, as on the window.
  function tapAt(win, item) {
    const n = item.node;
    const x = round((Number(n.x) || 0) + (Number(n.w) || 0) / 2), y = round((Number(n.y) || 0) + (Number(n.h) || 0) / 2);
    pointer(win, "down", x, y, null);
    pointer(win, "up", x, y, null);
  }

  function stepAt(win, item, up) {
    const action = up ? "increment" : "decrement";
    if (actions(item).includes(action)) send({ t: "act", window: win.id, key: item.node.key, action });
  }

  if (simpleRoot) {
    simpleRoot.addEventListener("click", (e) => {
      const hit = simpleHit(e.target);
      if (hit && !state.control.you) {
        if (!hit.el.classList.contains("otm-s-field")) e.preventDefault(); // a checkbox doesn't flip; fields stay selectable
        return;
      }
      if (!hit || !enabled(hit.item)) return;
      const { win, item, el } = hit;
      const sk = el.__sk;
      if (sk !== "button" && sk !== "stepper" && sk !== "row") return; // fields focus; checks go by `change`
      state.lastLocal = Date.now();
      state.activeWindow = win.id;
      if (sk === "button") {
        e.preventDefault();
        const acts = actions(item);
        if (acts.includes("press")) {
          send({ t: "act", window: win.id, key: item.node.key, action: "press" });
          optimistic(win, item, () => el.classList.add("otm-pressed"), PRESS_HOLD_MS + 50);
        } else if (acts.includes("showMenu")) send({ t: "act", window: win.id, key: item.node.key, action: "showMenu" });
        else tapAt(win, item);
      } else if (sk === "stepper") {
        const r = el.getBoundingClientRect();
        stepAt(win, item, e.clientX >= r.left + r.width / 2);
      } else tapAt(win, item);
    });

    simpleRoot.addEventListener("change", (e) => {
      const input = e.target;
      if (!(input instanceof HTMLInputElement) || (input.type !== "checkbox" && input.type !== "radio")) return;
      const hit = simpleHit(input);
      if (!hit || hit.el.__sk !== "check" || !enabled(hit.item) || !state.control.you) return;
      const { win, item, el } = hit;
      const now = input.checked;
      state.lastLocal = Date.now();
      if (actions(item).includes("press")) send({ t: "act", window: win.id, key: item.node.key, action: "press" });
      else tapAt(win, item);
      optimistic(win, item, () => {
        input.checked = now;
        input.indeterminate = false;
        el.setAttribute("aria-checked", now ? "true" : "false");
      });
    });

    simpleRoot.addEventListener("keydown", (e) => {
      if (e.isComposing || e.keyCode === 229 || !state.control.you) return;
      const hit = simpleHit(e.target);
      if (!hit || !enabled(hit.item)) return;
      const { win, item, el } = hit;
      if (el.__sk === "stepper" && (e.key === "ArrowUp" || e.key === "ArrowDown" || e.key === "ArrowRight" || e.key === "ArrowLeft")) {
        e.preventDefault();
        stepAt(win, item, e.key === "ArrowUp" || e.key === "ArrowRight");
      } else if (el.__sk === "check" && (e.key === " " || e.key === "Enter")) {
        e.preventDefault();
        el.__input.click();
      } else if (el.classList.contains("otm-s-field") && (e.key === "Enter" || e.key === "Escape")) {
        if (e.key === "Enter" && el.localName === "textarea") return; // a newline, sent with the value
        // The value first (setText also focuses the field in the app), then the key there.
        item.typedAt = state.lastLocal = Date.now();
        flushSetText();
        send({ t: "key", window: win.id, code: e.key, modifiers: modifiers(e) });
      }
    });

    // Fields send their whole value (setText): the page's caret, autocorrect and keyboard are the
    // phone's, so whole values stay right where keystrokes could land in the wrong place.
    const fieldHit = (target) => {
      const hit = simpleHit(target);
      return hit && hit.el.classList.contains("otm-s-field") ? hit : null;
    };
    simpleRoot.addEventListener("input", (e) => {
      const hit = fieldHit(e.target);
      if (!hit) return;
      hit.item.typedAt = state.lastLocal = Date.now();
      state.activeWindow = hit.win.id;
      if (e.isComposing || e.inputType === "insertCompositionText") return;
      queueSetText(hit);
    });
    simpleRoot.addEventListener("compositionend", (e) => {
      const hit = fieldHit(e.target);
      if (!hit) return;
      hit.item.typedAt = state.lastLocal = Date.now();
      queueSetText(hit);
    });
  }

  let pendingText = null, textTimer = null, textSentAt = 0;
  function queueSetText(hit) {
    if (pendingText && pendingText.el !== hit.el) flushSetText();
    pendingText = hit;
    const wait = SET_TEXT_INTERVAL - (Date.now() - textSentAt);
    if (wait <= 0) flushSetText();
    else if (!textTimer) textTimer = setTimeout(flushSetText, wait);
  }
  function flushSetText() {
    clearTimeout(textTimer);
    textTimer = null;
    if (!pendingText) return;
    const { win, item, el } = pendingText;
    pendingText = null;
    textSentAt = Date.now();
    send({ t: "setText", window: win.id, key: item.node.key, value: el.value });
  }

  // Which view shows: the viewer's choice from the bar, else by width.
  function readPref() {
    try {
      const v = localStorage.getItem(VIEW_PREF);
      return v === "simple" || v === "window" ? v : null;
    } catch {
      return null;
    }
  }
  state.viewPref = readPref();

  function applyView() {
    const simple = !!simpleRoot && (state.viewPref ? state.viewPref === "simple" : window.innerWidth < SIMPLE_BELOW);
    for (const b of document.querySelectorAll(".otm-view")) b.setAttribute("aria-pressed", String((b.dataset.view === "simple") === simple));
    if (simple === state.simple && document.body.dataset.view) return;
    const a = document.activeElement;
    if (a && a !== document.body && (simple ? stage.contains(a) : simpleRoot && simpleRoot.contains(a))) a.blur();
    flushSetText();
    state.simple = simple;
    document.body.dataset.view = simple ? "simple" : "window";
    desk.hidden = simple;
    if (simpleRoot) simpleRoot.hidden = !simple;
    // Hand the ids over: never two elements with one id, so anchors stay unique and resolve to what shows.
    for (const win of state.windows.values()) {
      for (const [key, item] of win.items) {
        if (simple) item.el.removeAttribute("id");
        else item.el.id = domId(key);
        if (item.s) {
          if (simple) item.s.id = domId(key);
          else item.s.removeAttribute("id");
        }
      }
    }
    if (simple) {
      renderSimple();
      window.scrollTo(0, 0);
    } else layout();
    sendViewport();
  }

  function chooseView(view) {
    state.viewPref = view;
    try { localStorage.setItem(VIEW_PREF, view); } catch { /* private mode: for this page only */ }
    applyView();
  }
  for (const b of document.querySelectorAll(".otm-view")) b.addEventListener("click", () => chooseView(b.dataset.view));
  window.addEventListener("resize", () => {
    applyView();
    if (state.simple) scheduleThumbs();
  });

  // ---------------------------------------------------------------- menus
  //
  // The app's menu bar sits in the desktop bar (the app's name opens its own menu, as on a Mac); a
  // menu opens as a web menu in the style of the Electron preview's, and choosing an item sends
  // `menuAction` with its titles. When the titles don't fit, one "Menu" button lists every menu.
  // A menu the app pops up (a right click's context menu) shows as a web menu where the app put it.
  // Cmd shortcuts that belong to a menu item are sent as that item's `menuAction`: Cmd keys posted as
  // events never reach an app that isn't frontmost, but a menu item can always be chosen.

  const MODS = { "⌃": "ctrl", "⌥": "alt", "⇧": "shift", "⌘": "cmd" };
  const KEY_NAMES = { "↩": "Enter", "⌤": "Enter", "⎋": "Escape", "⌫": "Backspace", "⌦": "Delete", "⇥": "Tab", "←": "ArrowLeft",
    "→": "ArrowRight", "↑": "ArrowUp", "↓": "ArrowDown", "↖": "Home", "↘": "End", "⇞": "PageUp", "⇟": "PageDown", Space: " " };
  const EDIT_KEYS = new Set(["KeyA", "KeyC", "KeyV", "KeyX", "KeyZ"]); // a focused field's own editing keys
  const CLIPBOARD_KEYS = new Set(["KeyC", "KeyV", "KeyX"]); // the host's clipboard is no use to a viewer

  const menus = { bar: [], barJSON: null, contextJSON: null, dismissed: null, open: null };
  const bar = $("otm-bar");
  const menusEl = document.createElement("span");
  menusEl.className = "otm-menus";
  menusEl.setAttribute("role", "menubar");
  menusEl.setAttribute("data-opentraffic-ui", "");
  const allButton = document.createElement("button");
  allButton.type = "button";
  allButton.className = "otm-menu-all";
  allButton.textContent = "Menu";
  allButton.setAttribute("data-opentraffic-ui", "");
  allButton.setAttribute("aria-haspopup", "menu");
  allButton.setAttribute("aria-expanded", "false");
  if (bar && nameEl) {
    nameEl.after(menusEl);
    menusEl.after(allButton);
  }

  // A shortcut as the server writes it ("⇧⌘S", "fn⌃F", "⌘↩") as modifiers and a key.
  function parseShortcut(text) {
    if (typeof text !== "string" || !text) return null;
    let s = text;
    const m = { fn: false, ctrl: false, alt: false, shift: false, cmd: false };
    if (s.startsWith("fn")) { m.fn = true; s = s.slice(2); }
    while (s && MODS[s[0]] && s.length > 1) { m[MODS[s[0]]] = true; s = s.slice(1); }
    return s ? { ...m, key: s } : null;
  }

  function shortcutMatches(sc, e) {
    if (!sc || sc.fn || e.ctrlKey !== sc.ctrl || e.altKey !== sc.alt || e.metaKey !== sc.cmd) return false;
    const named = KEY_NAMES[sc.key] || (/^F\d{1,2}$/.test(sc.key) ? sc.key : null);
    if (named) return e.key === named && e.shiftKey === sc.shift;
    if (/^[A-Z]$/.test(sc.key)) return e.code === "Key" + sc.key && e.shiftKey === sc.shift;
    if (/^[0-9]$/.test(sc.key)) return e.code === "Digit" + sc.key && e.shiftKey === sc.shift;
    // Punctuation: the character decides; Shift may be what makes it ("⌘?" is typed as ⇧⌘/).
    return e.key === sc.key && (!sc.shift || e.shiftKey);
  }

  // The first item (depth first) whose shortcut the key event types, with its path.
  function findShortcut(items, e, path) {
    for (const item of items || []) {
      if (!item || item.separator) continue;
      const here = path.concat(String(item.title));
      if (Array.isArray(item.items) && item.items.length) {
        const hit = findShortcut(item.items, e, here);
        if (hit) return hit;
      } else if (shortcutMatches(parseShortcut(item.shortcut), e)) {
        return { item, path: here };
      }
    }
    return null;
  }

  function applyMenu(m) {
    const list = Array.isArray(m.bar) ? m.bar.filter((x) => x && typeof x.title === "string") : [];
    const barJSON = JSON.stringify(list) + "|" + state.appName;
    if (barJSON !== menus.barJSON) {
      menus.barJSON = barJSON;
      menus.bar = list;
      const open = menus.open;
      renderMenuBar();
      // A menu that was open shows its new items, under its (new) title.
      if (open) {
        const index = open.index === -1 ? -1 : list.findIndex((x) => x.title === open.title);
        const anchor = index === -1 ? (open.index === -1 ? allButton : null) : titleButtons().find((b) => b !== allButton && Number(b.dataset.menu) === index);
        if (anchor) openMenu(index, anchor);
        else closeMenu();
      }
    }
    const ctx = m.context && typeof m.context === "object" && Array.isArray(m.context.items) ? m.context : null;
    const json = ctx ? JSON.stringify(ctx) : null;
    if (!ctx) menus.dismissed = null;
    if (json === menus.contextJSON) return;
    menus.contextJSON = json;
    if (!ctx || json === menus.dismissed || !state.control.you) return hideContext();
    showContext(ctx);
  }

  function renderMenuBar() {
    if (!bar) return;
    menusEl.textContent = "";
    const list = menus.bar;
    // The app's own menu (first, titled with the app's name) opens from the name, as on a Mac.
    const appMenu = list.length && nameEl && list[0].title === state.appName;
    if (nameEl) {
      if (appMenu) {
        nameEl.setAttribute("role", "button");
        nameEl.setAttribute("tabindex", "0");
        nameEl.setAttribute("aria-haspopup", "menu");
        nameEl.setAttribute("aria-expanded", "false");
        nameEl.dataset.menu = "0";
        nameEl.classList.add("otm-menu-title");
      } else {
        for (const a of ["role", "tabindex", "aria-haspopup", "aria-expanded"]) nameEl.removeAttribute(a);
        delete nameEl.dataset.menu;
        nameEl.classList.remove("otm-menu-title");
      }
    }
    list.forEach((top, i) => {
      if (i === 0 && appMenu) return;
      const b = document.createElement("button");
      b.type = "button";
      b.className = "otm-menu-title";
      b.textContent = top.title;
      b.dataset.menu = String(i);
      b.setAttribute("role", "menuitem");
      b.setAttribute("aria-haspopup", "menu");
      b.setAttribute("aria-expanded", "false");
      if (top.enabled === false) b.disabled = true;
      menusEl.appendChild(b);
    });
    bar.dataset.menus = list.length ? "yes" : "no";
    fitMenuBar();
  }

  // Titles that don't fit give way to the one "Menu" button.
  function fitMenuBar() {
    if (!bar) return;
    bar.classList.remove("otm-bar-compact");
    if (!menus.bar.length) return;
    if (menusEl.scrollWidth > menusEl.clientWidth + 1 || bar.scrollWidth > bar.clientWidth + 1) bar.classList.add("otm-bar-compact");
  }
  window.addEventListener("resize", fitMenuBar);

  function titleButtons() {
    return [nameEl, ...menusEl.querySelectorAll(".otm-menu-title"), allButton].filter((b) => b && (b === allButton || b.dataset.menu !== undefined));
  }

  function setExpanded(anchor) {
    for (const b of titleButtons()) if (b) b.setAttribute("aria-expanded", String(b === anchor));
  }

  // Builds a menu's items into `box`: separators as lines, submenus as a heading over their items.
  function buildItems(box, items, path, choose) {
    let lastLine = true;
    for (const item of items || []) {
      if (!item || typeof item !== "object") continue;
      if (item.separator) {
        if (!lastLine) {
          const hr = document.createElement("hr");
          hr.setAttribute("role", "separator");
          box.appendChild(hr);
        }
        lastLine = true;
        continue;
      }
      const title = String(item.title || "");
      if (!title) continue;
      lastLine = false;
      const here = path.concat(title);
      if (Array.isArray(item.items) && item.items.length) {
        const head = document.createElement("div");
        head.className = "otm-menu-head";
        head.textContent = title;
        box.appendChild(head);
        const group = document.createElement("div");
        group.className = "otm-menu-sub";
        group.setAttribute("role", "group");
        group.setAttribute("aria-label", title);
        buildItems(group, item.items, here, choose);
        box.appendChild(group);
        continue;
      }
      const b = document.createElement("button");
      b.type = "button";
      b.className = "otm-menu-item";
      b.setAttribute("role", item.checked ? "menuitemcheckbox" : "menuitem");
      if (item.checked) b.setAttribute("aria-checked", "true");
      const check = document.createElement("span");
      check.className = "otm-menu-check";
      check.textContent = item.checked ? "✓" : "";
      const label = document.createElement("span");
      label.className = "otm-menu-label";
      label.textContent = title;
      b.append(check, label);
      if (typeof item.shortcut === "string" && item.shortcut) {
        const acc = document.createElement("span");
        acc.className = "otm-menu-acc";
        acc.textContent = item.shortcut;
        b.appendChild(acc);
      }
      if (item.enabled === false) b.disabled = true;
      else b.addEventListener("click", () => choose(here));
      box.appendChild(b);
    }
    if (box.lastElementChild && box.lastElementChild.localName === "hr") box.lastElementChild.remove();
  }

  function makeMenuBox(kind) {
    const box = document.createElement("div");
    box.className = "otm-menu otm-menu-" + kind;
    box.setAttribute("role", "menu");
    box.setAttribute("data-opentraffic-ui", "");
    box.addEventListener("keydown", menuKeys);
    return box;
  }

  function placeBox(box, x, y, below) {
    const r = box.getBoundingClientRect();
    const left = Math.max(8, Math.min(x, innerWidth - r.width - 8));
    let top = below === undefined ? y : below;
    if (top + r.height > innerHeight - 8) top = Math.max(8, (below === undefined ? y : innerHeight) - r.height - 8);
    box.style.left = Math.round(left) + "px";
    box.style.top = Math.round(Math.max(8, top)) + "px";
  }

  // Opens menu `index` of the bar under its title (-1: every menu, under the "Menu" button).
  function openMenu(index, anchor) {
    if (menus.open && menus.open.box) menus.open.box.remove();
    const box = makeMenuBox("bar");
    const choose = (path) => {
      closeMenu();
      flashTitle(path[0]);
      send({ t: "menuAction", path, context: false });
    };
    if (index === -1) {
      for (const top of menus.bar) {
        if (!Array.isArray(top.items) || !top.items.length) continue;
        buildItems(box, [{ title: top.title, items: top.items }], [], choose);
      }
    } else {
      const top = menus.bar[index];
      if (!top) return closeMenu();
      box.setAttribute("aria-label", top.title);
      buildItems(box, top.items, [top.title], choose);
    }
    document.body.appendChild(box);
    const r = anchor.getBoundingClientRect();
    placeBox(box, r.left, 0, r.bottom + 6);
    menus.open = { index, title: index >= 0 && menus.bar[index] ? menus.bar[index].title : null, anchor, box };
    setExpanded(anchor);
  }

  function closeMenu() {
    if (menus.open && menus.open.box) menus.open.box.remove();
    menus.open = null;
    setExpanded(null);
  }

  function flashTitle(title) {
    const b = titleButtons().find((x) => x !== allButton && x.dataset.menu !== undefined && menus.bar[Number(x.dataset.menu)] &&
      menus.bar[Number(x.dataset.menu)].title === title);
    const el = bar && bar.classList.contains("otm-bar-compact") ? allButton : b;
    if (!el) return;
    el.classList.add("otm-menu-flash");
    setTimeout(() => el.classList.remove("otm-menu-flash"), 220);
  }

  function onTitle(e) {
    const t = e.target instanceof Element ? e.target.closest(".otm-menu-title, .otm-menu-all") : null;
    if (!t || t.disabled) return null;
    return t === allButton ? { index: -1, el: t } : { index: Number(t.dataset.menu), el: t };
  }
  if (bar) {
    bar.addEventListener("click", (e) => {
      const hit = onTitle(e);
      if (!hit || !state.control.you) return;
      e.stopPropagation();
      if (menus.open && menus.open.anchor === hit.el) return closeMenu();
      openMenu(hit.index, hit.el);
    });
    bar.addEventListener("keydown", (e) => {
      const hit = onTitle(e);
      if (!hit || !state.control.you || (e.key !== "Enter" && e.key !== " " && e.key !== "ArrowDown")) return;
      e.preventDefault();
      e.stopPropagation();
      openMenu(hit.index, hit.el);
      const first = menus.open && menus.open.box.querySelector(".otm-menu-item:not([disabled])");
      if (first) first.focus();
    });
    // With a menu open, pointing at another title opens that one, as in a menu bar.
    bar.addEventListener("pointerover", (e) => {
      const hit = onTitle(e);
      if (hit && menus.open && menus.open.anchor !== hit.el && menus.open.index !== -1 && hit.index !== -1) openMenu(hit.index, hit.el);
    });
  }

  // Arrow keys move between items; Left/Right move between menus; Escape closes.
  function menuKeys(e) {
    const box = e.currentTarget;
    const items = [...box.querySelectorAll(".otm-menu-item:not([disabled])")];
    const i = items.indexOf(document.activeElement);
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      const next = items[(i + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length];
      if (next) next.focus();
    } else if ((e.key === "ArrowRight" || e.key === "ArrowLeft") && menus.open && menus.open.index >= 0 && box === menus.open.box) {
      const titles = titleButtons().filter((b) => b !== allButton && !b.disabled);
      const at = titles.indexOf(menus.open.anchor);
      const next = titles[(at + (e.key === "ArrowRight" ? 1 : -1) + titles.length) % titles.length];
      if (next) {
        openMenu(Number(next.dataset.menu), next);
        const first = menus.open && menus.open.box.querySelector(".otm-menu-item:not([disabled])");
        if (first) first.focus();
      }
    } else if (e.key === "Escape") {
      if (box === menus.open?.box) {
        const anchor = menus.open.anchor;
        closeMenu();
        anchor.focus();
      } else dismissContext();
    } else return;
    e.preventDefault();
    e.stopPropagation();
  }

  // The context menu: where the app popped it up, over the window (or near the top in the Simple view).
  let contextBox = null;
  function showContext(ctx) {
    hideContext();
    const box = makeMenuBox("context");
    box.setAttribute("aria-label", "Context menu");
    buildItems(box, ctx.items, [], (path) => {
      menus.dismissed = menus.contextJSON;
      hideContext();
      send({ t: "menuAction", path, context: true });
    });
    if (!box.childElementCount) return;
    document.body.appendChild(box);
    contextBox = box;
    syncMenuSurfaces();
    const win = state.windows.get(ctx.window);
    const r = win && win.el && !state.simple ? win.el.getBoundingClientRect() : null;
    if (r && r.width) {
      const f = r.width / win.info.w || 1;
      placeBox(box, r.left + Number(ctx.x || 0) * f, r.top + Number(ctx.y || 0) * f);
    } else {
      placeBox(box, (innerWidth - box.getBoundingClientRect().width) / 2, 72);
    }
  }

  function hideContext() {
    if (contextBox) contextBox.remove();
    contextBox = null;
    syncMenuSurfaces();
  }

  // Closes the app's context menu without choosing (as a click elsewhere or Escape does on a Mac).
  function dismissContext() {
    if (!contextBox) return;
    menus.dismissed = menus.contextJSON;
    hideContext();
    send({ t: "menuAction", path: [], context: true });
  }

  // A press outside an open menu closes it, and (like on a Mac) goes no further.
  document.addEventListener("pointerdown", (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (menus.open && !(t && (menus.open.box.contains(t) || t.closest(".otm-menu-title, .otm-menu-all")))) closeMenu();
    if (contextBox && !(t && contextBox.contains(t))) {
      dismissContext();
      if (t && stage.contains(t)) {
        e.preventDefault();
        e.stopPropagation();
        swallowClick = true;
      }
    }
  }, true);
  let swallowClick = false;
  document.addEventListener("click", (e) => {
    if (!swallowClick) return;
    swallowClick = false;
    e.preventDefault();
    e.stopPropagation();
  }, true);
  document.addEventListener("pointerup", (e) => {
    if (swallowClick) e.stopPropagation();
  }, true);

  // Menu shortcuts: a key combination with Cmd or Ctrl that a menu item has is that item's menuAction.
  // Left to the browser: the comment box and other page fields, copy/cut/paste (the host's clipboard
  // is no use here), and a focused field's own select all and undo.
  document.addEventListener("keydown", (e) => {
    if (e.defaultPrevented || e.isComposing || e.keyCode === 229 || !(e.metaKey || e.ctrlKey) || !menus.bar.length || !state.control.you) return;
    const t = e.target;
    const inStage = t instanceof Element && stage.contains(t);
    const inSimple = t instanceof Element && simpleRoot && simpleRoot.contains(t);
    const field = t instanceof HTMLElement && (t.isContentEditable || t.localName === "input" || t.localName === "textarea" || t.localName === "select");
    if (field && !inStage && !inSimple) return;
    if (CLIPBOARD_KEYS.has(e.code) && !e.altKey && !e.ctrlKey) return;
    if (field && EDIT_KEYS.has(e.code) && !e.altKey && !e.ctrlKey) return;
    if (!state.socket) return;
    const hit = findShortcut(menus.bar, e, []);
    if (!hit) return;
    e.preventDefault();
    e.stopPropagation();
    if (hit.item.enabled === false) return;
    closeMenu();
    flashTitle(hit.path[0]);
    send({ t: "menuAction", path: hit.path, context: false });
  }, true);

  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || e.defaultPrevented) return;
    if (menus.open) {
      closeMenu();
      e.preventDefault();
      e.stopPropagation();
    } else if (contextBox) {
      dismissContext();
      e.preventDefault();
      e.stopPropagation();
    }
  }, true);

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

  applyView();
  setLive(false);
  connect();
})();
