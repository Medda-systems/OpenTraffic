/*
 * OpenTraffic live collaboration overlay, served at /__opentraffic/collab.js.
 * Presence pill, live cursors, follow-the-host, pinned comments (with replies, a screenshot
 * and the commenter's browser), "look here" pointer pulses, and, when the share collects
 * them, browser errors for a shared local site.
 * Wire protocol and behaviour: specs/collab-plan.md.
 */
(() => {
  "use strict";

  // Only the top-level page joins, and only once.
  if (window.top !== window || window.__opentrafficCollab) return;
  window.__opentrafficCollab = true;

  const NAME_KEY = "__opentraffic_collab_name";
  const COLLAPSED_KEY = "__opentraffic_collab_collapsed";
  const CLIENT_KEY = "__opentraffic_collab_client";
  const RESOLVED_KEY = "__opentraffic_collab_show_resolved";
  const SESSION_KEY = "__opentraffic_collab"; // sessionStorage: follow/lead state across reloads
  const FULL_CLOSE = 1013; // "try again later": the session has as many people as it allows
  const FULL_RETRY = 30000;
  const WS_PATH = "/__opentraffic/ws";
  const MAX_FRAME = 4000; // UTF-8 bytes; the hub drops frames over 4 KB
  const CURSOR_INTERVAL = 50; // <= 20 cursor messages/s
  const SCROLL_INTERVAL = 100; // <= 10 scroll messages/s
  const CURSOR_TTL = 30000;
  const COMMENT_INTERVAL = 2200; // hub: one comment per 2 s (plus a little jitter margin)
  const POINT_WINDOW = 1100; // hub: two points per second
  const POINT_GAP = 550; // hub: at least 0.5 s between points
  const PING_MS = 1600; // point pulse lifetime
  const MAX_PINGS = 24;
  const MAX_COMMENTS = 1000; // the hub keeps at most 500
  const REPLY_INTERVAL = 1100; // hub: one reply per second
  const ERRORS_INTERVAL = 5200; // hub: one errors message per 5 s
  const ERRORS_KEPT = 20;
  const ERRORS_RECENT = 120000; // errors attached to a comment: the last 2 minutes
  const SHOT_TIMEOUT = 1500; // screenshot render + upload, then the comment goes without one
  const SHOT_MAX_BYTES = 600 * 1024;
  const UPLOAD_PATH = "/__opentraffic/upload";
  const ATTACHMENT_PATH = "/__opentraffic/attachments/";
  const SVG_NS = "http://www.w3.org/2000/svg";

  // #region helpers (pure validators and formatters)
  const MAX_DEPTH = 8;
  const MAX_ANCHOR = 256;
  const MAX_TEXT = 1000;
  const MAX_LABEL = 80;
  const MAX_TITLE = 200;
  const MAX_REPLIES = 200; // the hub keeps at most 200 per comment
  const ERRORS_PER_MESSAGE = 10;
  const OWN_PREFIX = "/__opentraffic/";
  const GREY = "#8e8e93";
  const COLOR_RE = /^#[0-9a-fA-F]{6}$/;
  const CONTROL_RE = /[\u0000-\u001f\u007f-\u009f]/g;
  const CLIENT_RE = /^[A-Za-z0-9_-]{1,64}$/;
  const ID_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  // Same rule as the hub: starts with one "/", no backslashes or control characters
  // (browsers turn "/\evil.com" into "//evil.com").
  const PATH_RE = /^\/(?![\/\\])[^\\\u0000-\u001f\u007f-\u009f]*$/;
  // "." and ".." segments, also percent-encoded ("%2e", "%2E"): browsers resolve them away, so
  // "/.//evil.com" would become "//evil.com".
  const DOT_SEGMENT_RE = /(?:^|\/)(?:\.|%2e){1,2}(?=\/|$)/i;
  // welcome.uploadToken: authorizes this connection's screenshot uploads.
  const UPLOAD_TOKEN_RE = /^[A-Za-z0-9_-]{22}$/;
  // Only selectors shaped like anchorFor()'s output, so peers can't make us evaluate
  // arbitrary (possibly very slow) selectors.
  const ANCHOR_RE =
    /^(?:body|#(?:[\w\u0080-\uffff-]|\\[0-9a-fA-F]{1,6} |\\[^\n\r\f0-9a-fA-F])+)(?: > (?:[\w\u0080-\uffff-]|\\[^\n\r\f])+:nth-of-type\(\d{1,5}\))*$/;

  const clamp01 = (n) => (n < 0 ? 0 : n > 1 ? 1 : n);
  const finite = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
  const round4 = (n) => Math.round(n * 1e4) / 1e4;
  const hexColor = (v) => (typeof v === "string" && COLOR_RE.test(v) ? v : GREY);
  const validPath = (p) => typeof p === "string" && p.length <= 512 && PATH_RE.test(p) && !DOT_SEGMENT_RE.test(p);
  // Page paths are pathnames only: query strings and fragments can carry tokens (?code=, magic
  // links), so they're cut from anything we send, show or compare.
  function pathOnly(p) {
    if (typeof p !== "string") return p;
    const i = p.search(/[?#]/);
    return i < 0 ? p : p.slice(0, i);
  }
  // Peer, comment, reply and attachment ids: [A-Za-z0-9_-]{1,64}.
  const validId = (v) => typeof v === "string" && CLIENT_RE.test(v);
  const validUploadToken = (v) => typeof v === "string" && UPLOAD_TOKEN_RE.test(v);

  // Free text with the query strings and fragments of URLs and paths removed
  // ("GET /api/login?token=abc -> 500" -> "GET /api/login -> 500"), and bare "?key=value" or
  // "#key=value" strings too. Closing brackets ending a token are kept.
  function scrubQueries(s) {
    if (typeof s !== "string") return "";
    return s.replace(/[^\s"'`<>]+/g, (t) => {
      const i = t.search(/[?#]/);
      if (i < 0) return t;
      const head = t.slice(0, i);
      if (!head.includes("/") && !/^[?#][^=]*=/.test(t.slice(i))) return t;
      return head + /[)\]}]*$/.exec(t)[0];
    });
  }

  function cleanName(v) {
    if (typeof v !== "string") return "";
    return Array.from(v.replace(CONTROL_RE, "").trim()).slice(0, 32).join("").trim();
  }

  function cleanPeer(p) {
    if (!p || typeof p !== "object" || !validId(p.id)) return null;
    return {
      id: p.id,
      name: cleanName(p.name) || "Guest",
      color: hexColor(p.color),
      path: typeof p.path === "string" ? pathOnly(p.path).slice(0, 512) : "",
      isHost: p.isHost === true,
    };
  }

  // One line, no control characters, collapsed whitespace, at most `max` code points.
  function oneLine(v, max) {
    if (typeof v !== "string") return "";
    const s = v.slice(0, max * 8).replace(CONTROL_RE, " ").replace(/\s+/g, " ").trim();
    return Array.from(s).slice(0, max).join("").trim();
  }

  // Comment text: keeps line breaks and tabs, drops other control characters.
  function cleanText(v) {
    if (typeof v !== "string") return "";
    return v.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, "").trim();
  }

  // Position fields shared by cursor, comment and point messages, or null.
  function cleanPos(m) {
    const x = finite(m.x);
    const y = finite(m.y);
    if (x === null || y === null) return null;
    const rx = finite(m.rx);
    const ry = finite(m.ry);
    const ok = typeof m.anchor === "string" && m.anchor.length <= MAX_ANCHOR && rx !== null && ry !== null && ANCHOR_RE.test(m.anchor);
    return { anchor: ok ? m.anchor : null, rx: clamp01(rx || 0), ry: clamp01(ry || 0), x: clamp01(x), y: Math.min(Math.max(0, y), 1e7) };
  }

  function cleanComment(c) {
    if (!c || typeof c !== "object" || !validId(c.id)) return null;
    // The hub counts characters, which can be more UTF-16 units; be lenient on the upper bound.
    const path = pathOnly(c.path);
    if (!validPath(path) || typeof c.text !== "string" || c.text.length > MAX_TEXT * 4) return null;
    const text = cleanText(c.text);
    const pos = cleanPos(c);
    const createdAt = finite(c.createdAt);
    if (!text || !pos || createdAt === null || createdAt < 0) return null;
    return Object.assign(pos, {
      id: c.id,
      author: cleanName(c.author) || "Guest",
      color: hexColor(c.color),
      path,
      text,
      label: oneLine(c.label, MAX_LABEL),
      title: oneLine(c.title, MAX_TITLE),
      createdAt,
      resolved: c.resolved === true,
      canDelete: c.canDelete === true,
      replies: Array.isArray(c.replies) ? c.replies.slice(-MAX_REPLIES).map(cleanReply).filter(Boolean) : [],
      screenshot: validId(c.screenshot) ? c.screenshot : null,
      env: cleanEnv(c.env),
      errors: Array.isArray(c.errors) ? c.errors.slice(0, ERRORS_PER_MESSAGE).map(cleanErrorItem).filter(Boolean) : [],
    });
  }

  function cleanReply(r) {
    if (!r || typeof r !== "object" || !validId(r.id) || typeof r.text !== "string" || r.text.length > MAX_TEXT * 4) return null;
    const text = cleanText(r.text);
    const createdAt = finite(r.createdAt);
    if (!text || createdAt === null || createdAt < 0) return null;
    return {
      id: r.id,
      author: cleanName(r.author) || "Guest",
      color: hexColor(r.color),
      text,
      createdAt,
      fromHost: r.fromHost === true,
      agent: cleanName(r.agent), // "" when written by a person
    };
  }

  const VIEWPORT_RE = /^\d{1,5}x\d{1,5}$/;

  // Env = { browser <= 60, os <= 60, viewport "1280x800", dpr, language <= 20 }, or null.
  // Same rules for what we send and what we show.
  function cleanEnv(e) {
    if (!e || typeof e !== "object") return null;
    const browser = oneLine(e.browser, 60);
    const os = oneLine(e.os, 60);
    if (!browser || !os || typeof e.viewport !== "string" || !VIEWPORT_RE.test(e.viewport)) return null;
    const dpr = finite(e.dpr);
    return {
      browser,
      os,
      viewport: e.viewport,
      dpr: dpr !== null && dpr > 0 && dpr <= 10 ? Math.round(dpr * 100) / 100 : 1,
      language: oneLine(e.language, 20),
    };
  }

  const ERROR_KINDS = ["error", "rejection", "console", "network"];

  // ErrorItem = { kind, message <= 300, source? <= 200, line?: int, path, at: ms }, or null.
  // Query strings and fragments are cut from the path and from URLs in message and source.
  function cleanErrorItem(e) {
    if (!e || typeof e !== "object" || !ERROR_KINDS.includes(e.kind)) return null;
    const message = oneLine(scrubQueries(oneLine(e.message, 600)), 300);
    const path = pathOnly(e.path);
    const at = finite(e.at);
    if (!message || !validPath(path) || at === null || at < 0) return null;
    const item = { kind: e.kind, message, path, at: Math.round(at) };
    const source = oneLine(scrubQueries(oneLine(e.source, 400)), 200);
    if (source) item.source = source;
    const line = finite(e.line);
    if (line !== null && line % 1 === 0 && line >= 0 && line <= 1e7) item.line = line;
    return item;
  }

  const UA_BRANDS = [["Microsoft Edge", "Edge"], ["Opera", "Opera"], ["Google Chrome", "Chrome"], ["Brave", "Brave"]];
  const UA_PLATFORMS = { macOS: "macOS", Windows: "Windows", Android: "Android", Linux: "Linux", "Chrome OS": "ChromeOS", "Chromium OS": "ChromeOS", iOS: "iOS" };
  const UA_BROWSERS = [
    [/\bEdg(?:e|A|iOS)?\/(\d+)/, "Edge"],
    [/\b(?:OPR|OPT|OPX)\/(\d+)/, "Opera"],
    [/\bOpera\b.*\bVersion\/(\d+)/, "Opera"],
    [/\bSamsungBrowser\/(\d+)/, "Samsung Internet"],
    [/\b(?:Firefox|FxiOS)\/(\d+)/, "Firefox"],
    [/\b(?:Chrome|CriOS)\/(\d+)/, "Chrome"],
    [/\bVersion\/(\d+)[^ ]*(?: Mobile\/\S+)? Safari\//, "Safari"],
  ];

  // { browser: "Chrome 141", os: "macOS" } from navigator.userAgentData when it names a known
  // brand/platform, else from the user agent string. `touchPoints` tells iPads (which claim
  // to be Macs) apart.
  function browserInfo(ua, data, touchPoints) {
    ua = typeof ua === "string" ? ua.slice(0, 1024) : "";
    let browser = "";
    let os = "";
    try {
      if (data && typeof data === "object") {
        const brands = Array.isArray(data.brands) ? data.brands : [];
        for (const [brand, name] of UA_BRANDS) {
          const b = brands.find((x) => x && x.brand === brand);
          const major = b && /^\d{1,5}/.exec(String(b.version));
          if (major) { browser = name + " " + major[0]; break; }
        }
        if (typeof data.platform === "string" && Object.prototype.hasOwnProperty.call(UA_PLATFORMS, data.platform)) os = UA_PLATFORMS[data.platform];
      }
    } catch { /* hostile userAgentData */ }
    if (!browser) {
      for (const [re, name] of UA_BROWSERS) {
        const m = re.exec(ua);
        if (m) { browser = name + " " + m[1]; break; }
      }
      if (!browser && /AppleWebKit/.test(ua) && /\b(?:iPhone|iPad|iPod|Macintosh)\b/.test(ua)) browser = "Safari";
    }
    if (!os) {
      if (/\biPad\b/.test(ua)) os = "iPadOS";
      else if (/\b(?:iPhone|iPod)\b/.test(ua)) os = "iOS";
      else if (/\bAndroid\b/.test(ua)) os = "Android";
      else if (/\bWindows\b/.test(ua)) os = "Windows";
      else if (/\bCrOS\b/.test(ua)) os = "ChromeOS";
      else if (/\bMac OS X\b|\bMacintosh\b/.test(ua)) os = touchPoints > 1 ? "iPadOS" : "macOS";
      else if (/\bLinux\b|\bX11\b/.test(ua)) os = "Linux";
    }
    return { browser: oneLine(browser, 60) || "Unknown browser", os: oneLine(os, 60) || "Unknown OS" };
  }

  // A URL as shown in error reports: same-origin -> path, else origin + path. Never the query.
  function shortUrl(raw) {
    try {
      const u = new URL(String(raw), document.baseURI);
      if (u.protocol !== "http:" && u.protocol !== "https:") return u.protocol;
      return (u.origin === location.origin ? "" : u.origin) + u.pathname;
    } catch {
      return "";
    }
  }

  // OpenTraffic's own scripts and endpoints (errors there aren't the app's).
  function isOwnUrl(raw) {
    try {
      const u = new URL(String(raw), document.baseURI);
      return u.origin === location.origin && u.pathname.startsWith(OWN_PREFIX);
    } catch {
      return false;
    }
  }

  const INPUT_KINDS = {
    password: "password field", checkbox: "checkbox", radio: "radio button", range: "slider",
    color: "color picker", file: "file picker", button: "button", submit: "button", reset: "button",
    image: "button", search: "search field", email: "email field", number: "number field",
    tel: "phone field", url: "URL field", date: "date field", "datetime-local": "date field",
    month: "date field", week: "date field", time: "time field",
  };
  const EDITABLE_SEL = 'textarea, [contenteditable]:not([contenteditable="false" i])';

  // Kind name for form controls and editable text, else null. Never reads values.
  function fieldKind(el) {
    if (el.localName === "input") return INPUT_KINDS[(el.getAttribute("type") || "").toLowerCase()] || "text field";
    if (el.closest("textarea")) return "text area";
    if (el.closest("select")) return "dropdown";
    const ce = el.closest("[contenteditable]");
    if (el.isContentEditable === true || document.designMode === "on" ||
        (ce && (ce.getAttribute("contenteditable") || "").toLowerCase() !== "false")) return "editable text";
    return null;
  }

  // Short description of the element under a pin: aria-label, alt, title or visible text
  // (form controls: their kind only). Walks up a few ancestors for icon-only targets.
  function labelFor(target) {
    for (let el = target, i = 0; el && el.nodeType === 1 && i < 4; el = el.parentElement, i++) {
      if (el === document.body || el === document.documentElement) break;
      const kind = fieldKind(el);
      if (kind) return kind;
      for (const attr of ["aria-label", "alt", "title"]) {
        const v = oneLine(el.getAttribute(attr), MAX_LABEL);
        if (v) return v;
      }
      if (el.querySelector(EDITABLE_SEL)) continue; // its text could include typed content
      const t = oneLine(typeof el.innerText === "string" ? el.innerText : el.textContent, MAX_LABEL);
      if (t) return t;
    }
    return "";
  }

  function relTime(t, now) {
    const s = Math.max(0, (now - t) / 1000);
    if (s < 45) return "just now";
    const m = Math.max(1, Math.floor(s / 60));
    if (m < 60) return m + " min ago";
    const hr = Math.floor(m / 60);
    if (hr < 24) return hr + (hr === 1 ? " hour ago" : " hours ago");
    const d = Math.floor(hr / 24);
    if (d === 1) return "yesterday";
    if (d < 7) return d + " days ago";
    return new Date(t).toLocaleDateString();
  }

  function makeClientId() {
    const bytes = new Uint8Array(22);
    try {
      crypto.getRandomValues(bytes);
    } catch {
      for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    }
    let s = "";
    for (const b of bytes) s += ID_ALPHABET[b & 63];
    return s;
  }

  function initials(name) {
    const words = name.split(/\s+/).filter(Boolean);
    const first = (w) => Array.from(w)[0] || "";
    const s = first(words[0] || "?") + (words.length > 1 ? first(words[words.length - 1]) : "");
    return s.toUpperCase();
  }

  // A same-origin pathname we may navigate to, or null. Never a full URL, a query string or
  // anything that resolves to a "//host" path.
  function safePath(p) {
    if (!validPath(p)) return null;
    try {
      const u = new URL(p, location.origin);
      if (u.origin !== location.origin || u.pathname.startsWith("//")) return null;
      return validPath(u.pathname) ? u.pathname : null;
    } catch {
      return null;
    }
  }

  // location.pathname (never the query or fragment), coerced into the shape the hub accepts.
  function currentPath() {
    const p = ("/" + location.pathname.replace(/^\/+/, "")).replace(/\\/g, "%5C");
    return validPath(p) ? p : "/";
  }

  // Dark or light text, whichever reads better on the peer's colour.
  function textOn(hex) {
    const n = parseInt(hex.slice(1), 16);
    const lum = 0.299 * (n >> 16) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255);
    return lum > 160 ? "#1d1d1f" : "#ffffff";
  }

  function uniqueIdSelector(el) {
    const id = el.id;
    if (!id || typeof id !== "string" || id.length > 64) return null;
    try {
      const sel = "#" + CSS.escape(id);
      return document.querySelectorAll(sel).length === 1 ? sel : null;
    } catch {
      return null;
    }
  }

  function nthOfType(el) {
    let n = 1;
    for (let s = el.previousElementSibling; s; s = s.previousElementSibling) if (s.localName === el.localName) n++;
    return CSS.escape(el.localName) + ":nth-of-type(" + n + ")";
  }

  // Short selector for `target`: "#id", or a tag:nth-of-type path from the nearest
  // uniquely-id'd ancestor (or body). Targets deeper than MAX_DEPTH / MAX_ANCHOR anchor
  // to their ancestor at that depth. Returns { selector, el } (el = what it resolves to).
  function anchorFor(target, skip) {
    const chain = [];
    let el = target;
    let rootSel = null;
    for (; el && el.nodeType === 1; el = el.parentElement) {
      if (el === skip || el === document.documentElement) return null;
      if (el === document.body) { rootSel = "body"; break; }
      if ((rootSel = uniqueIdSelector(el))) break;
      chain.push(el);
    }
    if (!rootSel) return null;
    let selector = rootSel;
    let anchorEl = el;
    for (let i = chain.length - 1, depth = 0; i >= 0 && depth < MAX_DEPTH; i--, depth++) {
      const next = selector + " > " + nthOfType(chain[i]);
      if (next.length > MAX_ANCHOR) break;
      selector = next;
      anchorEl = chain[i];
    }
    return { selector, el: anchorEl };
  }
  // #endregion helpers

  // ---------------------------------------------------------------- storage

  function getItem(area, key) {
    try { return window[area].getItem(key); } catch { return null; }
  }
  function setItem(area, key, value) {
    try {
      if (value == null) window[area].removeItem(key);
      else window[area].setItem(key, value);
    } catch { /* storage unavailable */ }
  }
  function readSession() {
    try {
      const v = JSON.parse(getItem("sessionStorage", SESSION_KEY) || "{}");
      return v && typeof v === "object" ? v : {};
    } catch {
      return {};
    }
  }
  const session = readSession(); // { follow?: 0|1, followAt?, navTo?, lead?: bool }
  const saveSession = () => setItem("sessionStorage", SESSION_KEY, JSON.stringify(session));

  // Lets the hub recognise our own comments after a reload. Never shown to others.
  let clientId = getItem("localStorage", CLIENT_KEY);
  if (!clientId || !CLIENT_RE.test(clientId)) {
    clientId = makeClientId();
    setItem("localStorage", CLIENT_KEY, clientId);
  }

  // ---------------------------------------------------------------- state

  let ws = null;
  let joined = false; // welcome received on the current socket
  let uploadToken = null; // welcome.uploadToken: authorizes this connection's screenshot uploads
  let sessionFull = false; // the last socket closed because the session is full
  let stopped = false; // page is being hidden/unloaded
  let failures = 0;
  let retryTimer = 0;
  let shown = false; // pill appears after the first welcome or failure
  let me = null;
  let welcomedAt = 0;
  const peers = new Map(); // id -> Peer (excluding me)
  const cursors = new Map(); // id -> cursor view + last position
  let leadOn = false; // hub says the host is leading
  let following = false;
  let navigating = false;
  let lastLead = {}; // { path?, ratio? } from the latest lead/welcome
  let alias = null; // lead path that redirected to where we are now
  let lastPath = currentPath();
  let collapsed = getItem("localStorage", COLLAPSED_KEY) === "1";
  let editing = false;
  let listOpen = false;

  const comments = new Map(); // id -> Comment (every page)
  const pins = new Map(); // id -> { el, n, v } markers shown on this page
  const pings = new Set(); // { el, pos, timer } point pulses
  let showResolved = getItem("localStorage", RESOLVED_KEY) === "1";
  let openCount = 0; // unresolved comments on this page
  let armed = null; // "comment" | "point": the next page click is ours
  let draft = null; // { pos, label, el } while the composer is open
  let hoverEl = null; // outlined element in comment mode
  let bubbleId = null; // comment whose bubble is open
  let confirmDelete = false;
  let lastCommentAt = 0;
  let pointTimes = [0, 0]; // send times of the last two points
  let cycle = -1; // badge: index of the last pin revealed
  let posting = 0; // token of the comment waiting for its screenshot (0: none)
  let postSeq = 0;
  let lastReplyAt = 0;
  let replyFor = null; // comment whose reply draft is in the reply box
  const replyDrafts = new Map(); // comment id -> unsent reply text
  const failedShots = new Set(); // attachment ids whose image didn't load
  // welcome.features.errors: this share collects browser errors. null until the first welcome:
  // errors are collected from the start and only sent once a welcome says the share wants them.
  let errorsOn = null;
  // The page's fetch before our error capture wraps it; uploads go through this.
  const pageFetch = typeof window.fetch === "function" ? window.fetch : null;

  // Following survives full page loads. A load we caused (navTo) keeps following; landing
  // somewhere else on our own (link click) stops it.
  if (session.navTo) {
    if (session.navTo !== lastPath) alias = session.navTo; // server redirect; don't loop
    delete session.navTo;
    session.followAt = lastPath;
  } else if (session.follow === 1 && session.followAt && session.followAt !== lastPath) {
    session.follow = 0;
  }
  saveSession();

  const isLeading = () => !!(me && me.isHost && leadOn && joined);

  // ---------------------------------------------------------------- UI

  const CSS_TEXT = `
:host { all: initial; --tb-font: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, Roboto, Helvetica, Arial, sans-serif; }
* { box-sizing: border-box; }
[hidden] { display: none !important; }
.layer { position: fixed; inset: 0; overflow: hidden; pointer-events: none; }
.cursor { position: absolute; left: 0; top: 0; transition: transform 90ms linear; will-change: transform; }
.cursor svg { display: block; width: 16px; height: 20px; filter: drop-shadow(0 1px 1.5px rgba(0,0,0,.35)); }
.tag { position: absolute; left: 12px; top: 17px; max-width: 160px; padding: 2px 6px; border-radius: 6px;
  font: 600 11px/1.35 var(--tb-font); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.pill, .pop { --bg: rgba(255,255,255,.94); --fg: #1d1d1f; --muted: #6e6e73; --line: rgba(0,0,0,.1); --accent: #0a84ff; }
.pill { position: fixed; right: 16px; bottom: 16px; max-width: calc(100vw - 32px); display: flex; align-items: center; gap: 8px;
  padding: 4px 6px 4px 4px; border-radius: 999px; background: var(--bg); color: var(--fg);
  box-shadow: 0 6px 20px rgba(0,0,0,.12), 0 0 0 .5px var(--line);
  -webkit-backdrop-filter: blur(14px); backdrop-filter: blur(14px);
  font: 500 12px/1.2 var(--tb-font); pointer-events: auto; user-select: none; -webkit-user-select: none; }
@media (prefers-color-scheme: dark) {
  .pill, .pop { --bg: rgba(44,44,46,.92); --fg: #f5f5f7; --muted: #a1a1a6; --line: rgba(255,255,255,.14); }
  .pill { box-shadow: 0 6px 20px rgba(0,0,0,.45), 0 0 0 .5px var(--line); }
}
button { all: unset; box-sizing: border-box; cursor: pointer; border-radius: 6px; }
button:focus-visible { outline: 2px solid #0a84ff; outline-offset: 1px; }
.avatars { display: flex; align-items: center; border-radius: 999px; }
.av { width: 26px; height: 26px; margin-left: -7px; border-radius: 50%; border: 2px solid var(--bg);
  display: grid; place-items: center; font-size: 10px; font-weight: 700; letter-spacing: -.02em; }
.av:first-child { margin-left: 0; }
.av.more { background: var(--line); color: var(--fg); }
.count { color: var(--muted); white-space: nowrap; }
.name { max-width: 120px; padding: 2px 5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; }
.name:hover { background: var(--line); }
input { all: unset; width: 110px; padding: 2px 6px; border-radius: 6px; background: var(--line); font-weight: 600; cursor: text; }
.switch { display: flex; align-items: center; gap: 6px; padding: 2px 4px; white-space: nowrap; }
.track { position: relative; flex: none; width: 26px; height: 16px; border-radius: 8px; background: var(--line); transition: background .15s; }
.track::after { content: ""; position: absolute; top: 2px; left: 2px; width: 12px; height: 12px; border-radius: 50%;
  background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.3); transition: transform .15s; }
.switch[aria-checked="true"] .track { background: #30d158; }
.switch[aria-checked="true"] .track::after { transform: translateX(10px); }
.tool { flex: none; width: 26px; height: 26px; display: grid; place-items: center; border-radius: 50%; color: var(--fg); }
.tool:hover, .badge:hover { background: var(--line); }
.tool[aria-pressed="true"] { background: var(--accent); color: #fff; }
.tool svg, .badge svg { display: block; }
.badge { flex: none; display: flex; align-items: center; gap: 3px; height: 22px; padding: 0 7px 0 5px; border-radius: 11px;
  background: var(--line); font-weight: 700; font-variant-numeric: tabular-nums; }
.status { color: var(--muted); white-space: nowrap; }
.status::before { content: ""; display: inline-block; width: 7px; height: 7px; margin-right: 5px; border-radius: 50%;
  background: #ff9f0a; vertical-align: 1px; }
.status.dot { font-size: 0; }
.status.dot::before { margin-right: 0; }
.collapse { width: 18px; height: 18px; display: grid; place-items: center; color: var(--muted); font-size: 14px; }
.list { position: absolute; right: 0; bottom: calc(100% + 8px); min-width: 180px; max-width: 280px; max-height: 280px;
  overflow: auto; padding: 6px; border-radius: 10px; background: var(--bg); color: var(--fg);
  box-shadow: 0 6px 20px rgba(0,0,0,.15), 0 0 0 .5px var(--line); }
.list .head { padding: 2px 4px 4px; color: var(--muted); font-weight: 600; }
.list .sep { height: 1px; margin: 5px 2px; background: var(--line); }
.list .switch { display: flex; width: 100%; padding: 3px 4px; }
.row { display: flex; align-items: center; gap: 6px; padding: 3px 4px; white-space: nowrap; }
.row .dot { flex: none; width: 8px; height: 8px; border-radius: 50%; }
.row .who { font-weight: 600; overflow: hidden; text-overflow: ellipsis; }
.row .where { margin-left: auto; padding-left: 8px; color: var(--muted); overflow: hidden; text-overflow: ellipsis; max-width: 140px; }
.pin { position: absolute; left: 0; top: 0; min-width: 22px; height: 22px; margin-top: -22px; padding: 0 5px;
  border-radius: 11px 11px 11px 2px; border: 1.5px solid #fff; display: grid; place-items: center;
  font: 700 11px/1 var(--tb-font); font-variant-numeric: tabular-nums; box-shadow: 0 2px 6px rgba(0,0,0,.3);
  pointer-events: auto; will-change: transform; }
.pin.open { box-shadow: 0 0 0 2px var(--accent, #0a84ff), 0 2px 6px rgba(0,0,0,.3); }
.pin.resolved { opacity: .55; }
.pin.resolved::after { content: "\\2713"; position: absolute; right: -6px; top: -6px; width: 13px; height: 13px; border-radius: 50%;
  border: 1px solid #fff; background: #30d158; color: #fff; font: 700 8px/11px var(--tb-font); text-align: center; }
.outline { position: absolute; left: 0; top: 0; border: 2px solid #0a84ff; border-radius: 4px; background: rgba(10,132,255,.08); }
.draft { position: absolute; left: 0; top: 0; width: 12px; height: 12px; margin: -6px 0 0 -6px; border-radius: 50%;
  border: 2px solid #fff; background: #0a84ff; box-shadow: 0 0 0 3px rgba(10,132,255,.35); }
.ping { position: absolute; left: 0; top: 0; }
.ring { position: absolute; left: -28px; top: -28px; width: 56px; height: 56px; border-radius: 50%; border: 3px solid currentColor;
  opacity: 0; animation: tb-ring 1.2s ease-out forwards; }
.ring + .ring { animation-delay: .3s; }
.ping .tag { left: 14px; top: 10px; animation: tb-fade .4s ease-in 1.1s forwards; }
@keyframes tb-ring { from { transform: scale(.15); opacity: 1; } to { transform: scale(1); opacity: 0; } }
@keyframes tb-fade { from { opacity: 1; } to { opacity: 0; } }
.pop { position: fixed; left: 0; top: 0; width: 260px; max-width: calc(100vw - 16px); padding: 10px; border-radius: 12px;
  background: var(--bg); color: var(--fg); box-shadow: 0 10px 30px rgba(0,0,0,.2), 0 0 0 .5px var(--line);
  -webkit-backdrop-filter: blur(14px); backdrop-filter: blur(14px); font: 400 13px/1.4 var(--tb-font); pointer-events: auto; }
textarea { all: unset; box-sizing: border-box; display: block; width: 100%; min-height: 64px; max-height: 180px; padding: 6px 8px; border-radius: 8px;
  background: var(--line); white-space: pre-wrap; overflow-wrap: anywhere; overflow: auto; cursor: text; }
.actions { display: flex; align-items: center; justify-content: flex-end; gap: 6px; margin-top: 8px; }
.note { margin-right: auto; color: #ff9f0a; font-size: 11px; font-weight: 600; }
.act { padding: 4px 10px; border-radius: 7px; background: var(--line); font: 600 12px/1.3 var(--tb-font); }
.act.primary { background: var(--accent); color: #fff; }
.act.danger { background: #ff3b30; color: #fff; }
.act:disabled { opacity: .45; cursor: default; }
.meta { display: flex; align-items: center; gap: 6px; min-width: 0; }
.meta .dot { flex: none; width: 8px; height: 8px; border-radius: 50%; }
.meta .who { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.meta .when { margin-left: auto; flex: none; color: var(--muted); font-size: 11px; }
.elabel { margin-top: 4px; color: var(--muted); font-size: 11px; overflow-wrap: anywhere; }
.text { margin-top: 6px; max-height: 200px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere;
  user-select: text; -webkit-user-select: text; }
.bubble { width: 290px; }
.shot { display: block; margin-top: 8px; border-radius: 8px; overflow: hidden; background: var(--line); cursor: zoom-in; }
.shot:focus-visible { outline: 2px solid #0a84ff; outline-offset: 1px; }
.shot img { display: block; width: 100%; height: 120px; object-fit: cover; object-position: center top; }
.envline { margin-top: 6px; color: var(--muted); font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.thread { margin-top: 8px; border-top: .5px solid var(--line); max-height: 220px; overflow: auto; }
.reply { padding-top: 7px; }
.reply .text { margin-top: 2px; max-height: none; overflow: visible; }
.agent { flex: none; max-width: 130px; padding: 1px 6px; border-radius: 6px; background: rgba(191,90,242,.16); color: #a54bd6;
  font-size: 10px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.replybox { min-height: 36px; margin-top: 8px; }
.errs { flex: none; display: flex; align-items: center; gap: 4px; color: #ff9f0a; font-size: 11px; font-weight: 600; white-space: nowrap; cursor: help; }
.errs svg { display: block; flex: none; }
@media (prefers-color-scheme: dark) {
  .agent { background: rgba(191,90,242,.28); color: #da8fff; }
}
@media (max-width: 520px) {
  .pill { gap: 5px; }
  .pill > .count, .pill > .switch .label, .pill > .errs .label { display: none; }
  .name { max-width: 64px; }
}
@media (prefers-reduced-motion: reduce) {
  .cursor, .track, .track::after { transition: none; }
  .ring { transform: scale(.6); animation: tb-fade 1.5s ease-in forwards; }
  .ring + .ring { display: none; }
}
`;

  // Inline styles through the CSSOM, which a strict style-src allows (style attributes it doesn't).
  function css(el, props) {
    for (const [k, v] of Object.entries(props)) el.style.setProperty(k, String(v), "important");
  }
  function h(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function button(cls, text, label) {
    const b = h("button", cls, text);
    b.type = "button";
    if (label) b.setAttribute("aria-label", label);
    return b;
  }
  function icon(size, ...paths) {
    const svg = document.createElementNS(SVG_NS, "svg");
    for (const [k, v] of [["viewBox", "0 0 24 24"], ["width", size], ["height", size], ["aria-hidden", "true"], ["fill", "none"],
      ["stroke", "currentColor"], ["stroke-width", "2"], ["stroke-linecap", "round"], ["stroke-linejoin", "round"]]) svg.setAttribute(k, v);
    for (const d of paths) {
      const p = document.createElementNS(SVG_NS, "path");
      p.setAttribute("d", d);
      svg.append(p);
    }
    return svg;
  }
  const BUBBLE_PATH = "M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v9a1.5 1.5 0 0 1-1.5 1.5h-7.5l-4.5 3.5v-3.5h-2a1.5 1.5 0 0 1-1.5-1.5v-9a1.5 1.5 0 0 1 1.5-1.5z";
  const stop = (e) => e.stopPropagation();
  const narrow = window.matchMedia("(max-width: 520px)");

  // Unstyled sandbox for screenshot style defaults; attached only while capturing.
  const shotBox = document.createElement("opentraffic-shot");
  css(shotBox, { all: "initial", display: "none" });
  const shotSandbox = shotBox.attachShadow({ mode: "closed" });

  const host = document.createElement("opentraffic-collab");
  css(host, {
    all: "initial", position: "fixed", top: 0, right: 0, bottom: 0, left: 0, display: "block",
    "pointer-events": "none", "z-index": 2147483647,
  });
  const root = host.attachShadow({ mode: "closed" });
  // A constructed stylesheet (allowed under a strict style-src), else a <style> element.
  let styleEl = null;
  try {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(CSS_TEXT);
    root.adoptedStyleSheets = [sheet];
  } catch {
    styleEl = h("style", null, CSS_TEXT);
  }
  const pinLayer = h("div", "layer"); // comment markers (clickable)
  const layer = h("div", "layer"); // cursors, point pulses, comment-mode outline
  const outline = h("div", "outline");
  const draftDot = h("div", "draft");
  outline.hidden = draftDot.hidden = true;
  layer.append(outline, draftDot);

  const pill = h("div", "pill");
  pill.setAttribute("role", "group");
  pill.setAttribute("aria-label", "Live Collaboration");
  const listEl = h("div", "list");
  const listHead = h("div", "head");
  const listRows = h("div");
  const resolvedBtn = button("switch");
  resolvedBtn.setAttribute("role", "switch");
  resolvedBtn.append(h("span", "track"), h("span", "label", "Show resolved"));
  listEl.append(listHead, listRows, h("div", "sep"), resolvedBtn);
  const avatarsEl = button("avatars", null, "Show who's here");
  const countEl = h("span", "count");
  const nameBtn = button("name");
  nameBtn.title = "Your name \u2014 click to rename";
  const nameInput = h("input");
  nameInput.maxLength = 32;
  nameInput.setAttribute("aria-label", "Your name");
  const switchBtn = button("switch");
  switchBtn.setAttribute("role", "switch");
  const switchLabel = h("span", "label");
  switchBtn.append(h("span", "track"), switchLabel);
  const badgeBtn = button("badge");
  const badgeNum = h("span");
  badgeBtn.append(icon(13, BUBBLE_PATH), badgeNum);
  const commentBtn = button("tool", null, "Add a comment");
  commentBtn.title = "Comment \u2014 then click anything on the page";
  commentBtn.append(icon(16, BUBBLE_PATH, "M12 7.5v5M9.5 10h5"));
  const pointBtn = button("tool", null, "Point at something");
  pointBtn.title = "Point \u2014 then click anything (or Alt+click)";
  pointBtn.append(icon(16, "M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3", "M6.5 12a5.5 5.5 0 1 0 11 0a5.5 5.5 0 1 0-11 0", "M11 12a1 1 0 1 0 2 0a1 1 0 1 0-2 0"));
  const offlineText = () => (sessionFull ? "Session is full" : "Reconnecting\u2026");
  const statusEl = h("span", "status");
  const errsEl = h("span", "errs");
  const errsLabel = h("span", "label", "Errors shared with host");
  errsEl.append(icon(13, "M12 3.5l9.5 16.5h-19z", "M12 10v4.5", "M12 17.2v.3"), errsLabel);
  errsEl.title = "Errors shared with host: this share collects browser errors. JavaScript errors, console errors " +
    "and failed requests on these pages are sent to the host to help fix them (never form contents).";
  errsEl.setAttribute("role", "img");
  errsEl.setAttribute("aria-label", errsEl.title);
  errsEl.tabIndex = 0;
  const collapseBtn = button("collapse");
  pill.append(listEl, avatarsEl, countEl, nameBtn, nameInput, switchBtn, badgeBtn, commentBtn, pointBtn, errsEl, statusEl, collapseBtn);

  const composer = h("div", "pop composer");
  composer.setAttribute("role", "dialog");
  composer.setAttribute("aria-label", "New comment");
  const textArea = h("textarea");
  textArea.maxLength = MAX_TEXT;
  textArea.rows = 3;
  textArea.placeholder = "Add a comment\u2026";
  textArea.setAttribute("aria-label", "Comment");
  const noteEl = h("span", "note");
  const cancelBtn = button("act", "Cancel", "Cancel comment");
  const postBtn = button("act primary", "Post", "Post comment");
  const composerRow = h("div", "actions");
  composerRow.append(noteEl, cancelBtn, postBtn);
  composer.append(textArea, composerRow);
  composer.hidden = noteEl.hidden = true;

  const bubble = h("div", "pop bubble");
  bubble.setAttribute("role", "dialog");
  const bDot = h("span", "dot");
  const bWho = h("span", "who");
  const bWhen = h("span", "when");
  const bMeta = h("div", "meta");
  bMeta.append(bDot, bWho, bWhen);
  const bLabel = h("div", "elabel");
  const bText = h("div", "text");
  const bShot = h("a", "shot");
  bShot.target = "_blank";
  bShot.rel = "noopener noreferrer";
  bShot.title = "Open the screenshot in a new tab";
  const bShotImg = h("img");
  bShotImg.alt = "Screenshot of the commented element";
  bShotImg.decoding = "async"; // attached only while a comment with a screenshot is open
  const bEnv = h("div", "envline");
  const bThread = h("div", "thread");
  bThread.setAttribute("role", "list");
  bThread.setAttribute("aria-label", "Replies");
  const replyArea = h("textarea", "replybox");
  replyArea.maxLength = MAX_TEXT;
  replyArea.rows = 2;
  replyArea.placeholder = "Reply\u2026";
  replyArea.setAttribute("aria-label", "Reply");
  const replyNote = h("span", "note");
  const resolveBtn = button("act");
  const deleteBtn = button("act");
  const replyBtn = button("act primary", "Reply", "Send reply");
  const bActions = h("div", "actions");
  bActions.append(replyNote, resolveBtn, deleteBtn, replyBtn);
  bubble.append(bMeta, bLabel, bText, bShot, bEnv, bThread, replyArea, bActions);
  bubble.hidden = replyNote.hidden = bShot.hidden = bEnv.hidden = bThread.hidden = true;

  if (styleEl) root.append(styleEl);
  root.append(pinLayer, layer, composer, bubble, pill);

  // Appended to <html>, not <body>, which SPAs may replace; re-attached if removed.
  function mount() {
    if (!host.isConnected && document.documentElement) document.documentElement.appendChild(host);
  }

  const HOST_MARK = " \u00b7 host";
  const describe = (p) =>
    p.name + (p === me ? " (you)" : "") + (p.isHost ? HOST_MARK : "") + " \u2014 " + (p.path || "/");

  function avatar(p) {
    const a = h("span", "av", initials(p.name));
    css(a, { background: p.color, color: textOn(p.color) });
    a.title = describe(p);
    return a;
  }

  function render() {
    mount();
    pill.hidden = !shown;
    const everyone = me ? [me, ...peers.values()] : [];
    const maxAv = narrow.matches ? 3 : 5;
    const avs = everyone.slice(0, maxAv).map(avatar);
    if (everyone.length > maxAv) {
      const more = h("span", "av more", "+" + (everyone.length - maxAv));
      more.title = everyone.slice(maxAv).map(describe).join("\n");
      avs.push(more);
    }
    avatarsEl.replaceChildren(...avs);
    avatarsEl.hidden = !everyone.length;

    listEl.hidden = !listOpen || !everyone.length;
    if (listOpen) {
      listHead.textContent = everyone.length + " here";
      listRows.replaceChildren(
        ...everyone.map((p) => {
          const row = h("div", "row");
          const dot = h("span", "dot");
          css(dot, { background: p.color });
          row.title = describe(p);
          row.append(dot, h("span", "who", p.name + (p === me ? " (you)" : "") + (p.isHost ? HOST_MARK : "")), h("span", "where", p.path || "/"));
          return row;
        })
      );
      resolvedBtn.setAttribute("aria-checked", String(showResolved));
    }

    const full = !collapsed;
    countEl.hidden = !full || !joined;
    countEl.textContent = everyone.length + " here";
    nameBtn.hidden = !full || !me || editing;
    nameBtn.textContent = me ? me.name : "";
    nameInput.hidden = !full || !editing;

    const isHost = !!(me && me.isHost);
    switchBtn.hidden = !full || !joined || !(isHost || leadOn);
    switchLabel.textContent = isHost ? "Lead" : "Following host";
    switchBtn.setAttribute("aria-label", switchLabel.textContent);
    switchBtn.setAttribute("aria-checked", String(isHost ? leadOn : following));
    switchBtn.title = isHost ? "Visitors follow your page and scroll position" : "Follow the host's page and scroll position";

    const tools = full && joined;
    commentBtn.hidden = pointBtn.hidden = !tools;
    commentBtn.setAttribute("aria-pressed", String(armed === "comment"));
    pointBtn.setAttribute("aria-pressed", String(armed === "point"));
    badgeBtn.hidden = !tools || !openCount;
    badgeNum.textContent = String(openCount);
    badgeBtn.title = openCount + (openCount === 1 ? " open comment" : " open comments") + " on this page \u2014 show next";
    badgeBtn.setAttribute("aria-label", badgeBtn.title);

    errsEl.hidden = !joined || errorsOn !== true;
    errsLabel.hidden = collapsed;

    statusEl.hidden = joined;
    statusEl.textContent = statusEl.title = offlineText();
    statusEl.classList.toggle("dot", collapsed);
    collapseBtn.textContent = collapsed ? "\u2039" : "\u203a";
    collapseBtn.title = collapsed ? "Expand" : "Collapse";
    collapseBtn.setAttribute("aria-label", collapseBtn.title);
  }
  if (narrow.addEventListener) narrow.addEventListener("change", render);

  // Keep overlay interactions from reaching the page's own handlers.
  for (const el of [pill, pinLayer, composer, bubble]) for (const t of ["click", "pointerdown", "mousedown"]) el.addEventListener(t, stop);
  avatarsEl.addEventListener("click", () => {
    listOpen = !listOpen;
    render();
  });
  collapseBtn.addEventListener("click", () => {
    collapsed = !collapsed;
    listOpen = false;
    setItem("localStorage", COLLAPSED_KEY, collapsed ? "1" : null);
    finishRename(false);
    disarm();
    render();
  });
  switchBtn.addEventListener("click", () => (me && me.isHost ? setLeading(!leadOn) : setFollowing(!following)));
  resolvedBtn.addEventListener("click", () => {
    showResolved = !showResolved;
    setItem("localStorage", RESOLVED_KEY, showResolved ? "1" : null);
    renderPins();
  });
  commentBtn.addEventListener("click", () => arm("comment"));
  pointBtn.addEventListener("click", () => arm("point"));
  badgeBtn.addEventListener("click", revealNext);

  nameBtn.addEventListener("click", () => {
    editing = true;
    nameInput.value = me ? me.name : "";
    render();
    nameInput.focus();
    nameInput.select();
  });
  nameInput.addEventListener("keydown", (e) => {
    e.stopPropagation(); // don't trigger the site's keyboard shortcuts
    if (e.key === "Enter") { e.preventDefault(); finishRename(true); }
    else if (e.key === "Escape") { e.preventDefault(); finishRename(false); }
  });
  for (const t of ["keyup", "keypress", "input"]) nameInput.addEventListener(t, stop);
  nameInput.addEventListener("blur", () => finishRename(false));

  function finishRename(save) {
    if (!editing) return;
    editing = false;
    const name = cleanName(nameInput.value);
    if (save && me && name && name !== me.name) {
      setItem("localStorage", NAME_KEY, name);
      me.name = name;
      send({ type: "rename", name });
    }
    render();
  }

  // ---------------------------------------------------------------- positions

  // Viewport point for { anchor, rx, ry, x, y }: the anchor element when it resolves and is
  // rendered, else the page-relative fallback.
  function toViewport(p) {
    if (p.anchor) {
      try {
        const el = document.querySelector(p.anchor);
        if (el && el.getClientRects().length) {
          const r = el.getBoundingClientRect();
          return { x: r.left + p.rx * r.width, y: r.top + p.ry * r.height, el };
        }
      } catch { /* invalid selector */ }
    }
    return { x: p.x * document.documentElement.scrollWidth - window.scrollX, y: p.y - window.scrollY, el: null };
  }

  // Position fields (as sent in cursor/comment/point) for a pointer over `target`.
  function positionAt(target, cx, cy, px, py) {
    const pos = {
      x: round4(clamp01(px / Math.max(1, document.documentElement.scrollWidth))),
      y: Math.max(0, Math.round(py)),
    };
    const a = target && target !== host ? anchorFor(target, host) : null;
    if (a) {
      const r = a.el.getBoundingClientRect();
      pos.anchor = a.selector;
      pos.rx = r.width ? round4(clamp01((cx - r.left) / r.width)) : 0.5;
      pos.ry = r.height ? round4(clamp01((cy - r.top) / r.height)) : 0.5;
    }
    return pos;
  }

  const translate = (el, x, y) => css(el, { transform: `translate3d(${Math.round(x)}px, ${Math.round(y)}px, 0)` });

  // Places a popover next to (x, y), flipping to stay inside the viewport.
  function popAt(el, x, y) {
    const w = el.offsetWidth;
    const ht = el.offsetHeight;
    const vw = document.documentElement.clientWidth || window.innerWidth;
    const vh = window.innerHeight;
    let left = x + 14;
    let top = y + 10;
    if (left + w > vw - 8) left = Math.max(8, Math.min(vw - w - 8, x - 14 - w));
    if (top + ht > vh - 8) top = Math.max(8, y - 10 - ht);
    css(el, { left: Math.round(left) + "px", top: Math.round(top) + "px" });
  }

  function placeAll() {
    for (const [id, c] of cursors) place(id, c);
    for (const [id, p] of pins) {
      p.v = toViewport(comments.get(id));
      translate(p.el, p.v.x, p.v.y);
    }
    for (const g of pings) {
      const v = toViewport(g.pos);
      translate(g.el, v.x, v.y);
    }
    const target = draft ? draft.el : armed === "comment" ? hoverEl : null;
    if (target && target.isConnected && target !== host) {
      const r = target.getBoundingClientRect();
      css(outline, { width: Math.round(r.width + 4) + "px", height: Math.round(r.height + 4) + "px" });
      translate(outline, r.left - 2, r.top - 2);
      outline.hidden = false;
    } else outline.hidden = true;
    if (draft) {
      const v = toViewport(draft.pos);
      translate(draftDot, v.x, v.y);
      draftDot.hidden = false;
      popAt(composer, v.x, v.y);
    }
    const open = bubbleId && pins.get(bubbleId);
    if (open) popAt(bubble, open.v.x + 10, open.v.y - 22);
  }

  let placeRaf = 0;
  const needsPlace = () => !!(cursors.size || pins.size || pings.size || armed || draft || bubbleId);
  function schedulePlace() {
    if (placeRaf || !needsPlace()) return;
    placeRaf = requestAnimationFrame(() => {
      placeRaf = 0;
      placeAll();
    });
  }

  // Layout can move pins without scrolling or resizing; watch the DOM (throttled) while they show.
  let observer = null;
  let observeTimer = 0;
  function watchDom() {
    const on = !!(pins.size || draft || bubbleId) && typeof MutationObserver === "function";
    if (on && !observer) {
      observer = new MutationObserver(() => {
        if (!observeTimer) observeTimer = setTimeout(() => { observeTimer = 0; schedulePlace(); }, 150);
      });
      observer.observe(document.documentElement, {
        childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ["class", "style", "hidden", "open"],
      });
    } else if (!on && observer) {
      observer.disconnect();
      observer = null;
    }
  }

  // ---------------------------------------------------------------- remote cursors

  function makeCursor(peer) {
    const el = h("div", "cursor");
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 16 20");
    const arrow = document.createElementNS(SVG_NS, "path");
    arrow.setAttribute("d", "M1.5 1.5v15l4-3.6 2.6 6 2.4-1-2.6-5.9h5.4z");
    arrow.setAttribute("stroke", "#fff");
    arrow.setAttribute("stroke-width", "1.2");
    arrow.setAttribute("stroke-linejoin", "round");
    svg.append(arrow);
    const tag = h("span", "tag");
    el.append(svg, tag);
    const c = { el, arrow, tag, anchor: null, rx: 0, ry: 0, x: 0, y: 0, at: 0 };
    paintCursor(c, peer);
    return c;
  }

  function paintCursor(c, peer) {
    c.arrow.setAttribute("fill", peer.color);
    c.tag.textContent = peer.name;
    css(c.tag, { background: peer.color, color: textOn(peer.color) });
  }

  function place(id, c) {
    const peer = peers.get(id);
    if (!peer || peer.path !== lastPath) { c.el.hidden = true; return; }
    const v = toViewport(c);
    c.el.hidden = false;
    translate(c.el, v.x, v.y);
  }

  function dropCursor(id) {
    const c = cursors.get(id);
    if (c) { c.el.remove(); cursors.delete(id); }
  }
  function clearCursors() {
    for (const id of [...cursors.keys()]) dropCursor(id);
  }

  // Stale-cursor sweep runs only while cursors exist.
  let sweepTimer = 0;
  function sweep() {
    const now = Date.now();
    for (const [id, c] of cursors) if (now - c.at > CURSOR_TTL) dropCursor(id);
    if (!cursors.size) { clearInterval(sweepTimer); sweepTimer = 0; }
  }

  function onCursor(m) {
    const peer = peers.get(m.id);
    const pos = cleanPos(m);
    if (!peer || !pos) return;
    let c = cursors.get(m.id);
    if (!c) {
      c = makeCursor(peer);
      cursors.set(m.id, c);
      layer.append(c.el);
      if (!sweepTimer) sweepTimer = setInterval(sweep, 5000);
    }
    Object.assign(c, pos);
    c.at = Date.now();
    mount();
    place(m.id, c);
  }

  // ---------------------------------------------------------------- comments and pins

  function setComments(list) {
    comments.clear();
    for (const raw of Array.isArray(list) ? list.slice(-MAX_COMMENTS) : []) {
      const c = cleanComment(raw);
      if (c) comments.set(c.id, c);
    }
    renderPins();
  }

  function upsertComment(raw) {
    const c = cleanComment(raw);
    if (!c) return;
    if (!comments.has(c.id) && comments.size >= MAX_COMMENTS) comments.delete(comments.keys().next().value);
    comments.set(c.id, c);
    renderPins();
  }

  function removeComment(id) {
    if (typeof id === "string" && comments.delete(id)) renderPins();
  }

  // Comments on this page, oldest first; a pin's number is its index + 1.
  const pageComments = () =>
    [...comments.values()].filter((c) => c.path === lastPath).sort((a, b) => a.createdAt - b.createdAt);

  function renderPins() {
    const keep = new Set();
    openCount = 0;
    pageComments().forEach((c, i) => {
      if (!c.resolved) openCount++;
      else if (!showResolved) return;
      keep.add(c.id);
      let p = pins.get(c.id);
      if (!p) {
        const id = c.id;
        p = { el: button("pin"), n: 0, v: null };
        p.el.addEventListener("click", () => (bubbleId === id ? closeBubble() : openBubble(id)));
        pins.set(id, p);
      }
      p.n = i + 1;
      p.el.textContent = String(p.n);
      css(p.el, { background: c.color, color: textOn(c.color) });
      p.el.classList.toggle("resolved", c.resolved);
      const nr = c.replies.length;
      p.el.setAttribute("aria-label", "Comment " + p.n + " by " + c.author + (c.resolved ? " (resolved)" : "") +
        (nr ? ", " + nr + (nr === 1 ? " reply" : " replies") : ""));
      pinLayer.append(p.el); // keeps DOM (and tab) order by number
    });
    for (const [id, p] of pins) if (!keep.has(id)) { p.el.remove(); pins.delete(id); }
    if (bubbleId && !keep.has(bubbleId)) closeBubble();
    else renderBubble();
    watchDom();
    render();
    placeAll();
  }

  function openBubble(id) {
    bubbleId = id;
    confirmDelete = false;
    renderBubble();
    watchDom();
    placeAll();
  }

  let confirmTimer = 0;
  function closeBubble() {
    if (!bubbleId) return;
    bubbleId = null;
    confirmDelete = false;
    clearTimeout(confirmTimer);
    renderBubble();
    if (root.activeElement === replyArea) replyArea.blur();
    watchDom();
  }

  // The reply box belongs to one comment at a time; unsent text is kept per comment.
  function switchReplyDraft(id) {
    if (replyFor === id) return;
    if (replyFor) {
      const v = replyArea.value;
      replyDrafts.delete(replyFor);
      if (v.trim()) replyDrafts.set(replyFor, v);
      if (replyDrafts.size > 20) replyDrafts.delete(replyDrafts.keys().next().value);
    }
    replyFor = id;
    replyArea.value = (id && replyDrafts.get(id)) || "";
    replyNote.hidden = true;
    replyBtn.disabled = !cleanText(replyArea.value);
  }

  function replyEl(r, now) {
    const el = h("div", "reply");
    el.setAttribute("role", "listitem");
    const meta = h("div", "meta");
    const dot = h("span", "dot");
    css(dot, { background: r.color });
    meta.append(dot, h("span", "who", r.author + (r.fromHost && !r.agent ? HOST_MARK : "")));
    if (r.agent) {
      const badge = h("span", "agent", r.agent === r.author ? "Agent" : "Agent \u00b7 " + r.agent);
      badge.title = "Written by " + r.agent + " through OpenTraffic";
      meta.append(badge);
    }
    const when = h("span", "when", relTime(r.createdAt, now));
    when.title = new Date(r.createdAt).toLocaleString();
    meta.append(when);
    el.append(meta, h("div", "text", r.text));
    return el;
  }

  function renderThread(c) {
    const switched = bThread.dataset.for !== c.id;
    const atEnd = bThread.scrollTop + bThread.clientHeight >= bThread.scrollHeight - 4;
    const grew = c.replies.length > bThread.childElementCount;
    const now = Date.now();
    bThread.replaceChildren(...c.replies.map((r) => replyEl(r, now)));
    bThread.dataset.for = c.id;
    bThread.hidden = !c.replies.length;
    if (switched || (grew && atEnd)) bThread.scrollTop = bThread.scrollHeight;
  }

  function renderBubble() {
    const c = bubbleId ? comments.get(bubbleId) : null;
    const p = bubbleId ? pins.get(bubbleId) : null;
    for (const [id, q] of pins) {
      q.el.classList.toggle("open", id === bubbleId);
      q.el.setAttribute("aria-expanded", String(id === bubbleId));
    }
    bubble.hidden = !c || !p;
    switchReplyDraft(c && p ? c.id : null);
    if (!c || !p) return;
    const n = " comment " + p.n;
    bubble.setAttribute("aria-label", "Comment " + p.n + " by " + c.author);
    css(bDot, { background: c.color });
    bWho.textContent = c.author;
    bWhen.textContent = relTime(c.createdAt, Date.now()) + (c.resolved ? " \u00b7 resolved" : "");
    bWhen.title = new Date(c.createdAt).toLocaleString();
    bLabel.textContent = c.label;
    bLabel.hidden = !c.label;
    bText.textContent = c.text;
    const shot = c.screenshot && !failedShots.has(c.screenshot) ? ATTACHMENT_PATH + c.screenshot : "";
    bShot.hidden = !shot;
    if (shot) {
      bShot.href = shot;
      if (bShotImg.getAttribute("src") !== shot) bShotImg.src = shot;
      if (!bShotImg.isConnected) bShot.append(bShotImg);
    } else {
      bShot.removeAttribute("href");
      bShotImg.removeAttribute("src");
      bShotImg.remove();
    }
    bEnv.hidden = !c.env;
    if (c.env) {
      bEnv.textContent = [c.env.browser, c.env.os, c.env.viewport].join(" \u00b7 ");
      bEnv.title = c.env.browser + ", " + c.env.os + ", window " + c.env.viewport + " at " + c.env.dpr + "x" +
        (c.env.language ? ", " + c.env.language : "");
    }
    renderThread(c);
    replyArea.setAttribute("aria-label", "Reply to" + n);
    resolveBtn.textContent = c.resolved ? "Reopen" : "Resolve";
    resolveBtn.setAttribute("aria-label", resolveBtn.textContent + n);
    deleteBtn.hidden = !c.canDelete;
    deleteBtn.textContent = confirmDelete ? "Really delete?" : "Delete";
    deleteBtn.classList.toggle("danger", confirmDelete);
    deleteBtn.setAttribute("aria-label", (confirmDelete ? "Really delete" : "Delete") + n + (confirmDelete ? "?" : ""));
  }

  bShotImg.addEventListener("error", () => {
    const id = bShotImg.getAttribute("src");
    if (id && id.startsWith(ATTACHMENT_PATH)) failedShots.add(id.slice(ATTACHMENT_PATH.length));
    bShot.hidden = true;
    schedulePlace();
  });

  function sendReply() {
    const c = bubbleId && comments.get(bubbleId);
    const text = cleanText(replyArea.value).slice(0, MAX_TEXT);
    if (!c || !text) return;
    if (!joined) return flash(replyNote, offlineText(), 2000);
    const wait = REPLY_INTERVAL - (Date.now() - lastReplyAt);
    if (wait > 0) return flash(replyNote, "Wait a moment", wait);
    if (!send({ type: "reply", id: c.id, text })) return flash(replyNote, "Couldn't send", 2000);
    lastReplyAt = Date.now();
    replyArea.value = "";
    replyDrafts.delete(c.id);
    replyBtn.disabled = true;
    replyNote.hidden = true;
  }

  replyArea.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.isComposing) return;
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); sendReply(); }
    else if (e.key === "Escape") { e.preventDefault(); closeBubble(); }
  });
  for (const t of ["keyup", "keypress"]) replyArea.addEventListener(t, stop);
  replyArea.addEventListener("input", (e) => {
    e.stopPropagation();
    replyBtn.disabled = !cleanText(replyArea.value);
  });
  replyBtn.addEventListener("click", sendReply);

  resolveBtn.addEventListener("click", () => {
    const c = bubbleId && comments.get(bubbleId);
    if (c) send({ type: "resolve", id: c.id, resolved: !c.resolved }); // the hub echoes the change
  });
  deleteBtn.addEventListener("click", () => {
    const c = bubbleId && comments.get(bubbleId);
    if (!c || !c.canDelete) return;
    clearTimeout(confirmTimer);
    if (!confirmDelete) {
      confirmDelete = true;
      confirmTimer = setTimeout(() => { confirmDelete = false; renderBubble(); }, 4000);
    } else {
      confirmDelete = false;
      send({ type: "delete", id: c.id });
    }
    renderBubble();
  });

  // Badge: scroll to the next open comment on this page and open it.
  function revealNext() {
    const list = pageComments().filter((c) => !c.resolved);
    if (!list.length) return;
    cycle = (cycle + 1) % list.length;
    const c = list[cycle];
    const v = toViewport(c);
    const behavior = reducedMotion.matches ? "auto" : "smooth";
    if (v.el && typeof v.el.scrollIntoView === "function" && v.el.getBoundingClientRect().height < window.innerHeight * 0.8) {
      v.el.scrollIntoView({ block: "center", inline: "nearest", behavior });
    } else {
      window.scrollTo({ top: Math.max(0, window.scrollY + v.y - window.innerHeight / 2), behavior });
    }
    openBubble(c.id);
  }

  // ---------------------------------------------------------------- comment mode and composer

  let crossSheet = null;
  let crossInline = null; // previous inline cursor on <html> when the stylesheet route failed
  function setCrosshair(on) {
    const d = document;
    if (on) {
      try {
        if (!crossSheet) {
          crossSheet = new CSSStyleSheet();
          crossSheet.replaceSync("*, *::before, *::after { cursor: crosshair !important; }");
        }
        if (!d.adoptedStyleSheets.includes(crossSheet)) d.adoptedStyleSheets = [...d.adoptedStyleSheets, crossSheet];
        return;
      } catch { /* constructable stylesheets unsupported */ }
      const s = d.documentElement.style;
      if (crossInline === null) crossInline = [s.getPropertyValue("cursor"), s.getPropertyPriority("cursor")];
      s.setProperty("cursor", "crosshair", "important");
    } else {
      try {
        if (crossSheet && d.adoptedStyleSheets.includes(crossSheet)) d.adoptedStyleSheets = d.adoptedStyleSheets.filter((x) => x !== crossSheet);
      } catch { /* unsupported */ }
      if (crossInline !== null) {
        const s = d.documentElement.style;
        if (crossInline[0]) s.setProperty("cursor", crossInline[0], crossInline[1]);
        else s.removeProperty("cursor");
        crossInline = null;
      }
    }
  }

  function arm(mode) {
    if (armed === mode) return disarm();
    disarm();
    if (!joined) return;
    armed = mode;
    closeBubble();
    setCrosshair(true);
    render();
  }

  function disarm() {
    closeComposer();
    if (!armed) return;
    armed = null;
    hoverEl = null;
    outline.hidden = true;
    setCrosshair(false);
    render();
  }

  // Opens the composer for a click on `target`; clicking elsewhere moves it, keeping the text.
  function openComposer(target, e) {
    if (posting) return; // the draft stays where it was posted from
    draft = { pos: positionAt(target, e.clientX, e.clientY, e.pageX, e.pageY), label: labelFor(target), el: target };
    composer.hidden = false;
    noteEl.hidden = true;
    postBtn.disabled = !cleanText(textArea.value);
    watchDom();
    placeAll();
    try { textArea.focus({ preventScroll: true }); } catch { textArea.focus(); }
  }

  function closeComposer() {
    if (!draft) return;
    draft = null;
    setPosting(0); // cancels a post waiting for its screenshot
    composer.hidden = draftDot.hidden = noteEl.hidden = true;
    outline.hidden = true;
    textArea.value = "";
    if (root.activeElement === textArea) textArea.blur();
    clearTimeout(flashTimers.get(noteEl));
    watchDom();
  }

  const flashTimers = new Map();
  function flash(el, text, ms) {
    el.textContent = text;
    el.hidden = false;
    clearTimeout(flashTimers.get(el));
    flashTimers.set(el, setTimeout(() => { el.hidden = true; }, Math.max(800, ms)));
  }
  const note = (text, ms) => flash(noteEl, text, ms);

  function setPosting(token) {
    posting = token;
    postBtn.textContent = token ? "Posting\u2026" : "Post";
    postBtn.disabled = !!token || !cleanText(textArea.value);
    textArea.readOnly = !!token;
    composer.setAttribute("aria-busy", String(!!token));
  }

  // Posts the draft: a screenshot is attempted first (at most SHOT_TIMEOUT), then the comment
  // goes with whatever we have. Cancelling the composer meanwhile drops it.
  async function postComment() {
    if (!draft || posting) return;
    const text = cleanText(textArea.value).slice(0, MAX_TEXT);
    if (!text) return;
    if (!joined) return note(offlineText(), 2000);
    const wait = COMMENT_INTERVAL - (Date.now() - lastCommentAt);
    if (wait > 0) return note("Wait a moment", wait);
    const token = ++postSeq;
    const { pos, label, el } = draft;
    noteEl.hidden = true;
    setPosting(token);
    let shot = null;
    try { shot = await screenshot(el, pos); } catch { shot = null; }
    if (posting !== token || !draft) return; // cancelled
    setPosting(0);
    if (!joined) return note(offlineText(), 2000);
    const msg = Object.assign({ type: "comment", text, path: lastPath }, pos);
    if (label) msg.label = label;
    const title = oneLine(document.title, MAX_TITLE);
    if (title) msg.title = title;
    if (shot) msg.screenshot = shot;
    const env = currentEnv();
    if (env) msg.env = env;
    const errs = errorsOn === true ? recentErrors() : [];
    if (errs.length) msg.errors = errs;
    // Very long non-ASCII text can exceed the frame limit; shed optional fields first
    // (oldest attached errors one by one, then the rest).
    while (msg.errors && frameBytes(msg) > MAX_FRAME) {
      msg.errors.shift();
      if (!msg.errors.length) delete msg.errors;
    }
    for (const k of ["title", "label", "env", "anchor"]) {
      if (frameBytes(msg) <= MAX_FRAME) break;
      delete msg[k];
      if (k === "anchor") { delete msg.rx; delete msg.ry; }
    }
    if (!send(msg)) return note("Couldn't send", 2000);
    lastCommentAt = Date.now();
    disarm();
  }

  textArea.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.isComposing) return;
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); postComment(); }
    else if (e.key === "Escape") { e.preventDefault(); disarm(); }
  });
  for (const t of ["keyup", "keypress"]) textArea.addEventListener(t, stop);
  textArea.addEventListener("input", (e) => {
    e.stopPropagation();
    postBtn.disabled = !!posting || !cleanText(textArea.value);
  });
  postBtn.addEventListener("click", postComment);
  cancelBtn.addEventListener("click", disarm);

  // ---------------------------------------------------------------- environment

  function currentEnv() {
    try {
      const nav = navigator;
      const { browser, os } = browserInfo(nav.userAgent, nav.userAgentData, nav.maxTouchPoints);
      const dim = (n) => Math.max(0, Math.min(99999, Math.round(n) || 0));
      return cleanEnv({
        browser, os, viewport: dim(window.innerWidth) + "x" + dim(window.innerHeight), dpr: window.devicePixelRatio, language: nav.language,
      });
    } catch {
      return null;
    }
  }

  // ---------------------------------------------------------------- screenshot
  //
  // Best effort, never more than SHOT_TIMEOUT: the pinned element (or its nearest ancestor of at
  // least 320x200 CSS px), cropped to 1600x1200 around the pin, is cloned with computed styles
  // inlined, drawn through an SVG foreignObject onto a canvas, encoded as WebP (JPEG where the
  // browser can't) under 600 KB and uploaded with this connection's upload token. Typed values
  // never get in: inputs, textareas and selects are rebuilt empty, password fields are masked, and
  // editable rich text ([contenteditable], or the whole page in design mode) becomes an empty box
  // of the same size and background. Not reproduced: web fonts,
  // CSS background images, cross-origin or unloaded images, video, iframes, scroll offsets
  // inside scrolled elements, closed shadow roots.

  const XHTML_NS = "http://www.w3.org/1999/xhtml";
  const SHOT_MIN_W = 320;
  const SHOT_MIN_H = 200;
  const SHOT_MAX_W = 1600;
  const SHOT_MAX_H = 1200;
  const SHOT_NODES = 6000;
  const SHOT_SKIP = new Set(["script", "style", "link", "meta", "noscript", "template", "base", "title", "source", "track"]);
  const SHOT_BLANK = new Set(["iframe", "frame", "video", "audio", "object", "embed", "portal", "fencedframe"]);
  const BUTTON_TYPES = new Set(["submit", "button", "reset", "image"]);
  // Properties copied into the clone; "*" marks inherited ones (omitted when equal to the parent's,
  // unless the browser's own stylesheet sets them for that element type, like a textarea's font).
  // The rest are omitted when equal to the element type's default.
  const SHOT_PROPS = (
    "display position top right bottom left float clear z-index box-sizing width height min-width min-height max-width " +
    "max-height margin-top margin-right margin-bottom margin-left padding-top padding-right padding-bottom padding-left " +
    "overflow-x overflow-y vertical-align opacity transform transform-origin clip-path filter mix-blend-mode isolation " +
    "flex-direction flex-wrap flex-grow flex-shrink flex-basis order justify-content align-items align-content align-self " +
    "justify-items justify-self row-gap column-gap grid-template-columns grid-template-rows grid-template-areas " +
    "grid-auto-flow grid-auto-columns grid-auto-rows grid-column-start grid-column-end grid-row-start grid-row-end " +
    "table-layout column-count column-width border-top-width border-right-width border-bottom-width border-left-width " +
    "border-top-style border-right-style border-bottom-style border-left-style border-top-color border-right-color " +
    "border-bottom-color border-left-color border-top-left-radius border-top-right-radius border-bottom-right-radius " +
    "border-bottom-left-radius outline-width outline-style outline-color outline-offset box-shadow background-color " +
    "background-image background-size background-position background-repeat background-clip background-origin " +
    "object-fit object-position text-overflow text-decoration-line text-decoration-color text-decoration-style " +
    "text-decoration-thickness -webkit-line-clamp -webkit-box-orient appearance " +
    "*color *font-family *font-size *font-weight *font-style *font-variant *font-stretch *font-feature-settings " +
    "*font-variation-settings *line-height *letter-spacing *word-spacing *text-align *text-transform *text-indent " +
    "*text-shadow *text-underline-offset *white-space *word-break *overflow-wrap *hyphens *direction *writing-mode " +
    "*tab-size *visibility *list-style-type *list-style-position *border-collapse *border-spacing *caption-side " +
    "*empty-cells *quotes *-webkit-text-fill-color *-webkit-text-stroke-width *-webkit-text-stroke-color *color-scheme " +
    "*accent-color *fill *fill-opacity *fill-rule *stroke *stroke-width *stroke-opacity *stroke-linecap *stroke-linejoin " +
    "*stroke-dasharray *image-rendering *-webkit-font-smoothing"
  ).split(" ");
  const PROP_NAMES = SHOT_PROPS.map((p) => p.replace("*", ""));
  const PROP_INHERITED = SHOT_PROPS.map((p) => p[0] === "*");
  const ROOT_FIX = { margin: "0", position: "relative", left: "0", top: "0", right: "auto", bottom: "auto", float: "none", transform: "none" };
  const XML_BAD = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/g;

  // Default computed values per element type, from a hidden, unstyled sandbox.
  function baselines() {
    document.documentElement.appendChild(shotBox);
    const cache = new Map();
    return {
      get(el) {
        const key = el.namespaceURI + " " + el.localName + " " + (el.getAttribute("type") || "");
        let v = cache.get(key);
        if (!v) {
          const probe = document.createElementNS(el.namespaceURI, el.localName);
          if (el.hasAttribute("type")) probe.setAttribute("type", el.getAttribute("type"));
          shotSandbox.appendChild(probe);
          const cs = getComputedStyle(probe);
          v = PROP_NAMES.map((n) => cs.getPropertyValue(n));
          probe.remove();
          cache.set(key, v);
        }
        return v;
      },
      done() { shotBox.remove(); },
    };
  }

  // [property, value] pairs worth copying (see SHOT_PROPS).
  function styleDecls(vals, parentVals, base, neutral) {
    const out = [];
    for (let i = 0; i < PROP_NAMES.length; i++) {
      const v = vals[i];
      if (!v) continue;
      if (parentVals && (PROP_INHERITED[i] ? v === parentVals[i] && base[i] === neutral[i] : v === base[i])) continue;
      out.push([PROP_NAMES[i], v]);
    }
    return out;
  }
  const styleText = (...a) => styleDecls(...a).map(([k, v]) => k + ":" + v + ";").join("");
  // The clone's styles go through the CSSOM too (style attributes trip a strict style-src).
  function setStyles(el, decls) {
    for (const [k, v] of decls) el.style.setProperty(k, String(v));
  }

  const editableAttr = (el) => {
    const v = el.getAttribute("contenteditable");
    return v !== null && v.toLowerCase() !== "false";
  };
  // Editable rich text: [contenteditable] other than "false", inherited editing, or design mode.
  const isEditable = (el) => document.designMode === "on" || el.isContentEditable === true || editableAttr(el);
  // Whether `el` is editable or inside editable content (across shadow roots).
  function inEditable(el) {
    for (let e = el; e && e.nodeType === 1; e = e.parentElement || (e.parentNode && e.parentNode.host) || null) {
      if (isEditable(e)) return true;
    }
    return false;
  }

  // An inert copy: same tag (plain <div> for custom elements, so no page code runs) and
  // attributes, minus styles, classes, handlers and form state.
  function bareCopy(node, keepValue) {
    const custom = node.namespaceURI === XHTML_NS && node.localName.includes("-");
    const out = custom ? document.createElement("div") : document.createElementNS(node.namespaceURI, node.localName);
    if (custom) return out;
    for (const a of node.attributes) {
      const n = a.name.toLowerCase();
      if (n === "style" || n === "class" || n === "checked" || n === "selected" || n === "is" || n.startsWith("on") ||
          (n === "value" && !keepValue)) continue;
      try { out.setAttributeNS(a.namespaceURI, a.name, a.value.replace(XML_BAD, "")); } catch { /* not a valid XML name */ }
    }
    return out;
  }

  // Same-origin, loaded images and canvases as data URLs; anything else stays blank.
  function imageData(node, ctx, isCanvas) {
    if (ctx.imageBytes > 8e6) return null;
    try {
      let src = null;
      if (isCanvas) {
        if (node.width && node.height) src = node.toDataURL("image/webp", 0.9);
      } else {
        const url = node.currentSrc || node.getAttribute("src");
        if (!url || !node.complete || !node.naturalWidth) return null;
        const u = new URL(url, document.baseURI);
        if (u.protocol === "data:") src = url.length < 2e6 ? url : null;
        else if (u.origin === location.origin || u.protocol === "blob:") {
          const r = node.getBoundingClientRect();
          const k = Math.min(1, Math.max((r.width * ctx.scale) / node.naturalWidth, (r.height * ctx.scale) / node.naturalHeight) || 1);
          const c = document.createElement("canvas");
          c.width = Math.max(1, Math.round(node.naturalWidth * k));
          c.height = Math.max(1, Math.round(node.naturalHeight * k));
          const g = c.getContext("2d");
          if (!g) return null;
          g.drawImage(node, 0, 0, c.width, c.height);
          src = c.toDataURL("image/webp", 0.9);
        }
      }
      if (!src || !src.startsWith("data:image/")) return null;
      ctx.imageBytes += src.length;
      return src;
    } catch {
      return null; // tainted
    }
  }

  // Children as rendered: an open shadow root's content, a slot's assigned nodes.
  function renderedChildren(node) {
    if (node.localName === "slot" && typeof node.assignedNodes === "function") {
      const assigned = node.assignedNodes({ flatten: true });
      if (assigned.length) return assigned;
    }
    return node.shadowRoot ? node.shadowRoot.childNodes : node.childNodes;
  }

  function shotClone(node, parentVals, ctx) {
    if (node.nodeType === 3) return document.createTextNode(node.data.replace(XML_BAD, ""));
    if (node.nodeType !== 1 || node === host || SHOT_SKIP.has(node.localName)) return null;
    if (++ctx.nodes > SHOT_NODES || performance.now() > ctx.until) throw new Error("too big");
    const cs = getComputedStyle(node);
    if (cs.display === "none") return null;
    const tag = node.namespaceURI === XHTML_NS ? node.localName : "";
    let out;
    let kids = false;
    let extra = null;
    if (parentVals ? isEditable(node) : inEditable(node)) {
      // Editable rich text: an empty box with the same size, background and border.
      out = document.createElement("div");
      if (/^inline(?: flow)?$/.test(cs.display)) {
        const r = node.getBoundingClientRect();
        extra = { display: "inline-block", "box-sizing": "border-box", width: r.width + "px", height: r.height + "px" };
      }
    } else if (tag === "input" || tag === "textarea" || tag === "select") {
      const type = tag === "input" ? (node.getAttribute("type") || "").toLowerCase() : "";
      if (type === "password") {
        out = document.createElement("div");
        extra = { "background-color": "#8e8e93", "background-image": "none", color: "transparent" };
      } else out = bareCopy(node, BUTTON_TYPES.has(type));
    } else if (SHOT_BLANK.has(tag)) {
      out = document.createElement("div");
    } else if (tag === "canvas" || tag === "img") {
      const data = imageData(node, ctx, tag === "canvas");
      out = tag === "canvas" ? document.createElement(data ? "img" : "div") : bareCopy(node, true);
      for (const a of ["srcset", "sizes", "loading", "src"]) out.removeAttribute(a);
      if (data) out.setAttribute("src", data);
    } else {
      out = bareCopy(node, true);
      kids = true;
    }
    const vals = PROP_NAMES.map((n) => cs.getPropertyValue(n));
    setStyles(out, styleDecls(vals, parentVals, ctx.base.get(out), ctx.base.get(ctx.span)));
    if (!parentVals) setStyles(out, Object.entries(ROOT_FIX));
    if (extra) setStyles(out, Object.entries(extra));
    if (kids && ctx.pseudo.length < 200) {
      for (const which of ["::before", "::after"]) {
        const ps = getComputedStyle(node, which);
        const content = ps.getPropertyValue("content");
        if (!content || content === "none" || content === "normal") continue;
        const cls = "tb" + ctx.pseudo.length;
        out.setAttribute("class", ((out.getAttribute("class") || "") + " " + cls).trim());
        const pv = PROP_NAMES.map((n) => ps.getPropertyValue(n));
        ctx.pseudo.push("." + cls + which + "{" + styleText(pv, vals, ctx.base.get(ctx.span), ctx.base.get(ctx.span)) + "content:" + content + "}");
      }
    }
    if (kids) {
      for (const k of renderedChildren(node)) {
        const c = shotClone(k, vals, ctx);
        if (c) out.appendChild(c);
      }
    }
    return out;
  }

  // The element a screenshot shows: the target or its nearest ancestor of at least 320x200.
  function shotRoot(target) {
    for (let e = target; e && e.nodeType === 1; e = e.parentElement || (e.parentNode && e.parentNode.host) || null) {
      if (e === host) return null;
      if (e === document.body || e === document.documentElement) break;
      const r = e.getBoundingClientRect();
      if (r.width >= SHOT_MIN_W && r.height >= SHOT_MIN_H) return e;
    }
    return document.body;
  }

  // First opaque-ish background behind `el` (JPEG has no transparency).
  function backdrop(el) {
    for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
      const bg = getComputedStyle(e).backgroundColor;
      if (bg && bg !== "transparent" && !/^rgba\(.*,\s*0\)$/.test(bg)) return bg;
    }
    return "#ffffff";
  }

  function loadImage(src) {
    return new Promise((resolve, reject) => {
      const img = document.createElement("img");
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error("render failed"));
      img.src = src;
    });
  }

  function canvasBlob(canvas, type, quality) {
    return new Promise((resolve) => {
      try { canvas.toBlob(resolve, type, quality); } catch { resolve(null); } // tainted
    });
  }

  // WebP (JPEG where unsupported), quality stepping down until it fits.
  async function encodeShot(canvas, deadline) {
    let type = "image/webp";
    for (const q of [0.82, 0.68, 0.54, 0.4, 0.28]) {
      if (performance.now() > deadline) return null;
      let blob = await canvasBlob(canvas, type, q);
      if (blob && blob.type !== type && type === "image/webp") {
        type = "image/jpeg";
        blob = await canvasBlob(canvas, type, q);
      }
      if (!blob || blob.type !== type) return null;
      if (blob.size <= SHOT_MAX_BYTES) return blob;
    }
    return null;
  }

  async function renderShot(target, pin, deadline) {
    const el = shotRoot(target);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    const cw = Math.min(r.width, SHOT_MAX_W);
    const ch = Math.min(r.height, SHOT_MAX_H);
    if (cw < 1 || ch < 1) return null;
    const v = toViewport(pin);
    const ox = Math.max(0, Math.min(r.width - cw, v.x - r.left - cw / 2));
    const oy = Math.max(0, Math.min(r.height - ch, v.y - r.top - ch / 2));
    const scale = Math.min(2, window.devicePixelRatio || 1);
    const ctx = {
      nodes: 0, until: Math.min(deadline - 300, performance.now() + 1000), pseudo: [], imageBytes: 0, scale,
      base: baselines(), span: document.createElement("span"),
    };
    let clone;
    try { clone = shotClone(el, null, ctx); } finally { ctx.base.done(); }
    if (!clone) return null;
    const wrap = document.createElement("div");
    setStyles(wrap, Object.entries({ margin: "0", padding: "0", overflow: "hidden", width: r.width + "px", height: r.height + "px" }));
    if (ctx.pseudo.length) wrap.appendChild(h("style", null, ctx.pseudo.join("\n")));
    wrap.appendChild(clone);
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("width", String(cw));
    svg.setAttribute("height", String(ch));
    svg.setAttribute("viewBox", [ox, oy, cw, ch].join(" "));
    const fo = document.createElementNS(SVG_NS, "foreignObject");
    for (const [k, val] of [["x", 0], ["y", 0], ["width", r.width], ["height", r.height]]) fo.setAttribute(k, String(val));
    fo.appendChild(wrap);
    svg.appendChild(fo);
    const markup = new XMLSerializer().serializeToString(svg);
    if (markup.length > 3e7 || performance.now() > deadline) return null;
    const img = await loadImage("data:image/svg+xml;charset=utf-8," + encodeURIComponent(markup));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(cw * scale));
    canvas.height = Math.max(1, Math.round(ch * scale));
    const g = canvas.getContext("2d");
    if (!g) return null;
    g.fillStyle = "#ffffff";
    g.fillRect(0, 0, canvas.width, canvas.height);
    g.fillStyle = backdrop(el);
    g.fillRect(0, 0, canvas.width, canvas.height);
    g.drawImage(img, 0, 0, canvas.width, canvas.height);
    return encodeShot(canvas, deadline);
  }

  // Renders and uploads a screenshot for a comment; its attachment id, or null on any failure
  // or after SHOT_TIMEOUT.
  async function screenshot(target, pin) {
    if (!me || !validUploadToken(uploadToken) || !pageFetch || !target || target.nodeType !== 1 || typeof XMLSerializer !== "function") return null;
    const peerId = me.id;
    const token = uploadToken;
    const deadline = performance.now() + SHOT_TIMEOUT;
    const abort = typeof AbortController === "function" ? new AbortController() : null;
    let timer = 0;
    const late = new Promise((resolve) => {
      timer = setTimeout(() => {
        if (abort) abort.abort();
        resolve(null);
      }, SHOT_TIMEOUT);
    });
    const work = (async () => {
      await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0))); // let "Posting..." paint
      const blob = await renderShot(target, pin, deadline);
      if (!blob || performance.now() > deadline) return null;
      const res = await pageFetch.call(window, UPLOAD_PATH, {
        method: "POST", body: blob, credentials: "same-origin", cache: "no-store",
        headers: { "Content-Type": blob.type, "X-OpenTraffic-Peer": peerId, "X-OpenTraffic-Upload-Token": token },
        signal: abort ? abort.signal : undefined,
      });
      if (!res || !res.ok) return null;
      const data = await res.json();
      return data && validId(data.id) ? data.id : null;
    })().catch(() => null);
    try {
      return await Promise.race([work, late]);
    } finally {
      clearTimeout(timer);
    }
  }

  // ---------------------------------------------------------------- browser errors
  //
  // Only sent when the share collects them (welcome.features.errors). Hooks are installed at page
  // start and buffer up to ERRORS_PER_MESSAGE unsent items until the first welcome says whether the
  // share wants them; once it says no, they stay inert and the buffer is dropped.

  const errorLog = []; // the last ERRORS_KEPT distinct items, oldest first
  let errorQueue = []; // not sent yet
  let errorsTimer = 0;
  let lastErrorsAt = 0;
  let errorHooks = false;
  const errorKey = (e) => [e.kind, e.message, e.source || "", e.line || "", e.path].join("\n");
  const collecting = () => errorsOn !== false;

  function recordError(kind, message, source, line) {
    if (!collecting()) return;
    try {
      if (source && isOwnUrl(source)) return; // OpenTraffic's own scripts
      const item = cleanErrorItem({ kind, message, source: source ? shortUrl(source) : "", line, path: lastPath, at: Date.now() });
      if (!item) return;
      const key = errorKey(item);
      const i = errorLog.findIndex((e) => errorKey(e) === key);
      if (i >= 0) errorLog.splice(i, 1);
      errorLog.push(item);
      if (errorLog.length > ERRORS_KEPT) errorLog.shift();
      if (!errorQueue.some((e) => errorKey(e) === key)) {
        errorQueue.push(item);
        if (errorQueue.length > ERRORS_PER_MESSAGE) errorQueue.shift();
      }
      scheduleErrors();
    } catch { /* reporting never breaks the page */ }
  }

  // Attached to a comment: up to 10 from the last 2 minutes.
  function recentErrors() {
    const since = Date.now() - ERRORS_RECENT;
    return errorLog.filter((e) => e.at >= since).slice(-ERRORS_PER_MESSAGE).map((e) => Object.assign({}, e));
  }

  function scheduleErrors() {
    if (errorsTimer || !errorQueue.length) return;
    errorsTimer = setTimeout(flushErrors, Math.max(0, lastErrorsAt + ERRORS_INTERVAL - Date.now()));
  }

  function flushErrors() {
    errorsTimer = 0;
    if (errorsOn !== true || !joined || !errorQueue.length) return; // a later welcome flushes again
    const msg = { type: "errors", items: errorQueue.map(cleanErrorItem).filter(Boolean).slice(-ERRORS_PER_MESSAGE) };
    while (msg.items.length > 1 && frameBytes(msg) > MAX_FRAME) msg.items.shift();
    errorQueue = [];
    if (msg.items.length && send(msg)) lastErrorsAt = Date.now();
  }

  function setErrorsFeature(on) {
    errorsOn = on;
    if (on) {
      scheduleErrors();
    } else {
      errorLog.length = 0;
      errorQueue = [];
      clearTimeout(errorsTimer);
      errorsTimer = 0;
    }
  }

  // Readable text for an error, rejection reason or console argument.
  function errorText(v) {
    try {
      if (typeof v === "string") return v;
      if (v && typeof v === "object" && typeof v.message === "string") {
        const name = typeof v.name === "string" ? v.name : "";
        return (name ? name + ": " : "") + v.message;
      }
      const j = JSON.stringify(v);
      return typeof j === "string" ? j.slice(0, 600) : String(v);
    } catch {
      return "";
    }
  }

  const STACK_RE = /((?:https?|blob):\/\/[^\s()]+?):(\d+):\d+/;
  // Script URL and line of an error's top stack frame, if any.
  function stackTop(err) {
    try {
      const m = err && typeof err.stack === "string" ? STACK_RE.exec(err.stack.slice(0, 4000)) : null;
      return m ? { source: m[1], line: Number(m[2]) } : { source: "", line: undefined };
    } catch {
      return { source: "", line: undefined };
    }
  }

  // "GET /api/items" for a request, or null for OpenTraffic's own endpoints.
  function requestLine(input, init) {
    let method = "GET";
    let url;
    if (typeof Request === "function" && input instanceof Request) {
      method = input.method;
      url = input.url;
    } else url = String(input);
    if (init && typeof init === "object" && typeof init.method === "string") method = init.method;
    if (isOwnUrl(url)) return null;
    const where = shortUrl(url);
    return where ? (oneLine(method, 16).toUpperCase() || "GET") + " " + where : null;
  }
  const netError = (req, status) => recordError("network", req + " \u2192 " + status);

  function installErrorHooks() {
    if (errorHooks) return;
    errorHooks = true;

    window.addEventListener("error", (e) => {
      if (!collecting() || !e || typeof e.message !== "string") return; // failed resources are plain Events
      const top = e.filename ? { source: e.filename, line: e.lineno } : stackTop(e.error);
      recordError("error", e.message || errorText(e.error), top.source, top.line);
    });
    window.addEventListener("unhandledrejection", (e) => {
      if (!collecting()) return;
      const top = stackTop(e.reason);
      recordError("rejection", errorText(e.reason), top.source, top.line);
    });

    const con = window.console;
    if (con && typeof con.error === "function") {
      const consoleError = con.error;
      let inside = false; // no recursion if anything below logs
      con.error = function error(...args) {
        if (collecting() && !inside) {
          inside = true;
          try {
            const first = args.find((a) => typeof a === "string");
            recordError("console", first !== undefined ? first : args[0] instanceof Error ? errorText(args[0]) : "");
          } catch { /* ignore */ } finally {
            inside = false;
          }
        }
        return consoleError.apply(this, args);
      };
    }

    const fetch0 = window.fetch;
    if (typeof fetch0 === "function") {
      window.fetch = function fetch(input, init) {
        const p = fetch0.apply(this, arguments);
        if (collecting()) {
          try {
            const req = requestLine(input, init);
            if (req && p && typeof p.then === "function") {
              p.then(
                (res) => { if (res && res.status >= 500) netError(req, res.status); },
                (err) => { if (!(err && err.name === "AbortError")) netError(req, "failed"); }
              );
            }
          } catch { /* ignore */ }
        }
        return p;
      };
    }

    const XP = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
    if (XP && typeof XP.open === "function" && typeof XP.send === "function") {
      const opened = new WeakMap();
      const open0 = XP.open;
      const send0 = XP.send;
      XP.open = function open(method, url) {
        try { opened.set(this, [method, url]); } catch { /* ignore */ }
        return open0.apply(this, arguments);
      };
      XP.send = function send() {
        const info = collecting() ? opened.get(this) : null;
        if (info) {
          try {
            const req = requestLine(info[1], { method: String(info[0]) });
            if (req) {
              let aborted = false;
              const onAbort = () => { aborted = true; };
              this.addEventListener("abort", onAbort);
              this.addEventListener("loadend", () => {
                this.removeEventListener("abort", onAbort);
                if (aborted) return;
                if (this.status >= 500) netError(req, this.status);
                else if (this.status === 0) netError(req, "failed");
              }, { once: true });
            }
          } catch { /* ignore */ }
        }
        return send0.apply(this, arguments);
      };
    }
  }

  // ---------------------------------------------------------------- point

  function sendPoint(target, e) {
    const now = Date.now();
    if (now - pointTimes[0] < POINT_WINDOW || now - pointTimes[1] < POINT_GAP) return false; // <= 2/s, >= 0.5 s apart
    const msg = Object.assign({ type: "point" }, positionAt(target, e.clientX, e.clientY, e.pageX, e.pageY));
    if (!send(msg)) return false;
    pointTimes = [pointTimes[1], now];
    return true;
  }

  function dropPing(g) {
    clearTimeout(g.timer);
    g.el.remove();
    pings.delete(g);
  }
  function clearPings() {
    for (const g of [...pings]) dropPing(g);
  }

  // A "look here" pulse; the hub sends it to everyone on our path, including the sender.
  function onPoint(m) {
    if (typeof m.id !== "string" || !m.id || m.id.length > 64) return;
    const pos = cleanPos(m);
    if (!pos) return;
    const peer = me && m.id === me.id ? me : peers.get(m.id);
    const name = cleanName(m.name) || (peer ? peer.name : "Guest");
    const color = typeof m.color === "string" && COLOR_RE.test(m.color) ? m.color : peer ? peer.color : GREY;
    if (pings.size >= MAX_PINGS) dropPing(pings.values().next().value);
    const el = h("div", "ping");
    css(el, { color });
    const tag = h("span", "tag", name);
    css(tag, { background: color, color: textOn(color) });
    el.append(h("span", "ring"), h("span", "ring"), tag);
    const g = { el, pos, timer: 0 };
    g.timer = setTimeout(() => dropPing(g), PING_MS);
    pings.add(g);
    layer.append(el);
    mount();
    const v = toViewport(pos);
    translate(el, v.x, v.y);
  }

  // ---------------------------------------------------------------- page clicks

  // While armed, page clicks are ours: links and buttons must not fire. Alt+click points.
  function onPageEvent(e) {
    if (e.target === host) return; // the overlay's own UI
    if (e.type === "pointerdown" && bubbleId) closeBubble(); // outside click
    let ours = !!armed;
    if (e.type === "click") {
      if (armed === "comment") openComposer(e.target, e);
      else if (armed === "point") {
        sendPoint(e.target, e);
        disarm();
      } else if (e.altKey && joined && e.target && e.target.nodeType === 1 && !fieldKind(e.target)) {
        sendPoint(e.target, e);
        ours = true;
      }
    }
    if (!ours) return;
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
  }
  for (const t of ["pointerdown", "mousedown", "pointerup", "mouseup", "click", "dblclick", "auxclick"]) {
    window.addEventListener(t, onPageEvent, true);
  }

  window.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    const a = root.activeElement;
    if (a === nameInput || a === replyArea || (a === textArea && draft)) return; // handled there
    if (bubbleId) closeBubble();
    else if (armed) disarm();
    else return;
    e.stopPropagation();
  }, true);

  // ---------------------------------------------------------------- following / leading

  const maxScroll = () => Math.max(0, (document.scrollingElement || document.documentElement).scrollHeight - window.innerHeight);
  const scrollRatio = () => { const max = maxScroll(); return max > 0 ? clamp01(window.scrollY / max) : 0; };
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  function setFollowing(on) {
    following = on;
    session.follow = on ? 1 : 0;
    session.followAt = on ? lastPath : undefined;
    saveSession();
    render();
    if (on) applyLead(true);
  }

  function applyLead(withScroll) {
    if (!following || !leadOn || navigating) return;
    const { path, ratio } = lastLead;
    if (path && path !== lastPath && path !== alias) {
      navigating = true;
      setTimeout(() => { navigating = false; }, 5000); // e.g. a cancelled beforeunload prompt
      session.navTo = path;
      saveSession();
      location.assign(path); // safePath() guarantees a same-origin path
    } else if (withScroll && ratio !== undefined) {
      const max = maxScroll();
      if (max > 0) window.scrollTo({ top: ratio * max, behavior: reducedMotion.matches ? "auto" : "smooth" });
    }
  }

  // Merges path/ratio from a lead or welcome message. Returns whether a ratio was present.
  function takeLead(m) {
    const path = safePath(m.path);
    const ratio = finite(m.ratio);
    if (path !== null && path !== lastLead.path) lastLead = { path };
    if (ratio !== null) lastLead.ratio = clamp01(ratio);
    return ratio !== null;
  }

  function onLead(m) {
    const on = m.on === true;
    const was = leadOn;
    if (me && me.isHost) {
      // Our previous page's socket closing can produce a stale "off" right after we
      // re-asserted leading on this page; assert it once more.
      if (!on && session.lead && Date.now() - welcomedAt < 5000) {
        send({ type: "lead", on: true });
        return;
      }
      leadOn = on;
      session.lead = on;
      saveSession();
      if (on !== was) render();
      return;
    }
    leadOn = on;
    if (!on) {
      lastLead = {};
      if (was) render();
      return;
    }
    const hasRatio = takeLead(m);
    if (!was) setFollowing(true); // following defaults on whenever the host starts leading
    else applyLead(hasRatio);
  }

  function setLeading(on) {
    leadOn = on;
    session.lead = on;
    saveSession();
    send({ type: "lead", on });
    if (on) queueScroll();
    render();
  }

  let scrollTimer = 0;
  let lastScrollAt = 0;
  function queueScroll(delay = 0) {
    if (scrollTimer) return;
    const wait = Math.max(delay, SCROLL_INTERVAL - (Date.now() - lastScrollAt));
    scrollTimer = setTimeout(() => {
      scrollTimer = 0;
      if (!isLeading()) return;
      lastScrollAt = Date.now();
      send({ type: "scroll", ratio: round4(scrollRatio()) });
    }, wait);
  }

  // Programmatic scrolls (ours) only fire `scroll`; these mean the visitor scrolled.
  const SCROLL_KEYS = new Set(["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " ", "Spacebar"]);
  function onUserScroll(e) {
    if (!following || !leadOn || e.target === host) return;
    if (e.type === "keydown") {
      const t = e.target;
      if (!SCROLL_KEYS.has(e.key) || e.metaKey || e.ctrlKey || e.altKey) return;
      if (t && (t.isContentEditable || (t.closest && t.closest("input, textarea, select, button, [contenteditable]")))) return;
    }
    setFollowing(false);
  }
  for (const t of ["wheel", "touchmove", "keydown"]) window.addEventListener(t, onUserScroll, { capture: true, passive: true });

  window.addEventListener("scroll", (e) => {
    schedulePlace();
    if (e.target === document && isLeading()) queueScroll();
  }, { capture: true, passive: true });
  window.addEventListener("resize", schedulePlace, { passive: true });
  window.addEventListener("load", schedulePlace, { capture: true, passive: true }); // images etc. change layout

  // ---------------------------------------------------------------- path tracking

  // kind: "push" (pushState/popstate: the visitor navigated) or "replace" (no intent implied).
  function onNav(kind) {
    const p = currentPath();
    if (p === lastPath) return;
    lastPath = p;
    if (kind !== "replace") alias = null;
    if (following) {
      if (kind === "replace") { session.followAt = p; saveSession(); }
      else setFollowing(false);
    }
    if (me) me.path = p;
    send({ type: "path", path: p });
    if (isLeading()) queueScroll(300); // let the new view render before sampling scroll
    disarm();
    closeBubble();
    clearPings();
    cycle = -1;
    renderPins();
    schedulePlace();
    render();
  }

  for (const [fn, kind] of [["pushState", "push"], ["replaceState", "replace"]]) {
    const orig = history[fn];
    if (typeof orig !== "function") continue;
    history[fn] = function (...args) {
      const result = orig.apply(this, args);
      onNav(kind);
      return result;
    };
  }
  window.addEventListener("popstate", () => onNav("push"));
  window.addEventListener("hashchange", () => onNav("push"));
  // Fallback for routers that captured history.pushState before this script ran.
  setInterval(() => onNav("replace"), 1000);

  // ---------------------------------------------------------------- local cursor

  let pending = null;
  let moveQueued = false;
  let lastCursorAt = 0;
  let cursorShown = false;

  window.addEventListener("pointermove", (e) => {
    if (e.pointerType !== "mouse" && e.pointerType !== "pen") return;
    if (armed === "comment" && !draft) {
      hoverEl = e.target !== host ? e.target : null;
      schedulePlace();
    }
    pending = { target: e.target, cx: e.clientX, cy: e.clientY, px: e.pageX, py: e.pageY };
    if (moveQueued) return;
    moveQueued = true;
    const wait = Math.max(0, CURSOR_INTERVAL - (performance.now() - lastCursorAt));
    setTimeout(() => requestAnimationFrame(flushMove), wait);
  }, { capture: true, passive: true });

  function flushMove() {
    moveQueued = false;
    const p = pending;
    pending = null;
    if (!p || !joined) return;
    lastCursorAt = performance.now();
    if (send(Object.assign({ type: "cursor" }, positionAt(p.target, p.cx, p.cy, p.px, p.py)))) cursorShown = true;
  }

  function hideCursor() {
    pending = null;
    if (cursorShown) send({ type: "cursor-hide" });
    cursorShown = false;
  }
  document.addEventListener("pointerout", (e) => {
    if (e.relatedTarget) return;
    hideCursor();
    if (hoverEl) { hoverEl = null; schedulePlace(); }
  }, { passive: true });
  window.addEventListener("blur", hideCursor);
  document.addEventListener("visibilitychange", () => { if (document.hidden) hideCursor(); });

  // ---------------------------------------------------------------- connection

  const encoder = typeof TextEncoder === "function" ? new TextEncoder() : null;
  const byteLength = (s) => (encoder ? encoder.encode(s).length : s.length * 3);
  const frameBytes = (msg) => byteLength(JSON.stringify(msg));

  function send(msg) {
    if (!ws || ws.readyState !== 1) return false;
    const text = JSON.stringify(msg);
    if (text.length > MAX_FRAME || (text.length * 3 > MAX_FRAME && byteLength(text) > MAX_FRAME)) return false;
    ws.send(text);
    return true;
  }

  function onWelcome(m) {
    const you = cleanPeer(m.you);
    if (!you) return;
    me = you;
    me.path = lastPath;
    peers.clear();
    clearCursors();
    clearPings();
    for (const raw of Array.isArray(m.peers) ? m.peers.slice(0, 200) : []) {
      const p = cleanPeer(raw);
      if (p && p.id !== me.id) peers.set(p.id, p);
    }
    joined = shown = true;
    sessionFull = false;
    failures = 0;
    uploadToken = validUploadToken(m.uploadToken) ? m.uploadToken : null;
    welcomedAt = Date.now();
    leadOn = m.leading === true;
    lastLead = {};
    setErrorsFeature(!!(m.features && typeof m.features === "object" && m.features.errors === true));
    setComments(m.comments);
    if (me.isHost) {
      following = false;
      if (session.lead) { leadOn = true; send({ type: "lead", on: true }); } // re-assert after reconnect/reload
      if (leadOn) queueScroll(300);
      render();
    } else {
      if (leadOn) takeLead(m);
      setFollowing(leadOn && session.follow !== 0); // resumes following after a reload
    }
  }

  function onPeer(m) {
    const p = cleanPeer(m.peer);
    if (!p || !me || p.id === me.id) return;
    peers.set(p.id, p);
    const c = cursors.get(p.id);
    if (c) { paintCursor(c, p); place(p.id, c); }
    render();
  }

  function onMessage(ev) {
    if (typeof ev.data !== "string" || ev.data.length > 8388608) return; // welcome carries every comment
    let m;
    try { m = JSON.parse(ev.data); } catch { return; }
    if (!m || typeof m !== "object") return;
    if (m.type !== "welcome" && !joined) return;
    switch (m.type) {
      case "welcome": return onWelcome(m);
      case "join":
      case "update": return onPeer(m);
      case "leave": peers.delete(m.id); dropCursor(m.id); return render();
      case "cursor": return onCursor(m);
      case "cursor-hide": return dropCursor(m.id);
      case "lead": return onLead(m);
      case "comment": return upsertComment(m.comment);
      case "comment-delete": return removeComment(m.id);
      case "point": return onPoint(m);
      default: return; // unknown types are ignored
    }
  }

  function connect() {
    retryTimer = 0;
    if (ws || stopped) return;
    let sock;
    try {
      sock = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + WS_PATH);
    } catch {
      retry();
      return;
    }
    ws = sock;
    sock.addEventListener("open", () => {
      const hello = { type: "hello", path: lastPath, client: clientId };
      const name = cleanName(getItem("localStorage", NAME_KEY));
      if (name) hello.name = name;
      send(hello);
    });
    sock.addEventListener("message", onMessage);
    sock.addEventListener("close", (e) => {
      if (ws !== sock) return;
      ws = null;
      joined = false;
      sessionFull = !!e && e.code === FULL_CLOSE;
      uploadToken = null;
      cursorShown = false;
      peers.clear();
      clearCursors();
      clearPings();
      disarm(); // Comment/Point mode needs a connection
      if (stopped) return;
      shown = true;
      render();
      retry();
    });
  }

  // Exponential backoff, 1 s -> 30 s, with jitter; about 30 s while the session is full.
  function retry() {
    if (stopped || retryTimer) return;
    failures++;
    if (failures === 6 && !sessionFull) console.info("OpenTraffic collaboration: can't connect; still retrying.");
    const base = Math.min(30000, 1000 * 2 ** Math.min(failures - 1, 5));
    const delay = sessionFull ? FULL_RETRY * (0.85 + Math.random() * 0.3) : base / 2 + Math.random() * (base / 2);
    retryTimer = setTimeout(connect, delay);
  }

  window.addEventListener("pagehide", () => {
    stopped = true;
    if (ws) ws.close();
  });
  window.addEventListener("pageshow", (e) => {
    if (!e.persisted) return;
    stopped = false;
    connect();
  });

  installErrorHooks();
  render();
  connect();
})();
