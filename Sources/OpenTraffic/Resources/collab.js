/*
 * OpenTraffic live collaboration overlay, served at /__opentraffic/collab.js.
 * Presence pill, live cursors, follow-the-host, pinned comments (with replies, a screenshot
 * and the commenter's browser), "look here" pointer pulses, and, when the share collects
 * them, browser errors for a shared local site.
 * Wire protocol and behaviour: specs/collab-plan.md.
 */
(() => {
  "use strict";

  // Only the top-level page joins, and only once. The one exception is the page inside a device view
  // on our own stage (same origin, set up by the overlay above it): it joins as part of the same person,
  // so they can comment at that size, and its comment box and bubbles open outside the device.
  const stageApi = (() => {
    try {
      const f = window.frameElement;
      return f && f.__opentrafficStage && window.parent.location.origin === location.origin ? f.__opentrafficStage : null;
    } catch {
      return null;
    }
  })();
  if ((window.top !== window && !stageApi) || window.__opentrafficCollab) return;
  window.__opentrafficCollab = true;
  const inFrame = !!stageApi;

  const NAME_KEY = "__opentraffic_collab_name";
  const COLLAPSED_KEY = "__opentraffic_collab_collapsed";
  const CLIENT_KEY = "__opentraffic_collab_client";
  const RESOLVED_KEY = "__opentraffic_collab_show_resolved";
  const FIXES_KEY = "__opentraffic_collab_fixes_seen"; // localStorage: fixes we've told this person about
  const SESSION_KEY = "__opentraffic_collab"; // sessionStorage: follow/lead state across reloads
  const FULL_CLOSE = 1013; // "try again later": the session has as many people as it allows
  const FULL_RETRY = 30000;
  const WS_PATH = "/__opentraffic/ws";
  const MAX_FRAME = 4000; // UTF-8 bytes; the hub drops frames over 4 KB
  const CURSOR_INTERVAL = 50; // <= 20 cursor messages/s
  const SCROLL_INTERVAL = 50; // <= 20 scroll messages/s
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
  const AFTER_SETTLE = 1500; // let hot reload apply a fix before picturing it
  const AFTER_GAP = 2200; // hub: one picture of a fix per 2 s
  const FIXES_KEPT = 100;
  const MAX_PROGRESS = 120;
  const SHOT_MAX_BYTES = 600 * 1024;
  const UPLOAD_PATH = "/__opentraffic/upload";
  const ATTACHMENT_PATH = "/__opentraffic/attachments/";
  const SVG_NS = "http://www.w3.org/2000/svg";
  // Marks of the coding agents OpenTraffic knows, on a 24x24 grid: Claude, Cursor and OpenCode from
  // Simple Icons (CC0), Codex from Lobe Icons (MIT); trademarks of their owners, shown only to say which
  // agent is at work. Unknown agents get a sparkle.
  const AGENT_MARKS = {
    claude: "m 4.7144 15.9555 4.7174 -2.6471 .079 -.2307 -.079 -.1275 h -.2307 l -.7893 -.0486 -2.6956 -.0729 -2.3375 -.0971 -2.2646 -.1214 -.5707 -.1215 -.5343 -.7042 .0546 -.3522 .4797 -.3218 .686 .0608 1.5179 .1032 2.2767 .1578 1.6514 .0972 2.4468 .255 h .3886 l .0546 -.1579 -.1336 -.0971 -.1032 -.0972 L 6.973 9.8356 l -2.55 -1.6879 -1.3356 -.9714 -.7225 -.4918 -.3643 -.4614 -.1578 -1.0078 .6557 -.7225 .8803 .0607 .2246 .0607 .8925 .686 1.9064 1.4754 2.4893 1.8336 .3643 .3035 .1457 -.1032 .0182 -.0728 -.164 -.2733 -1.3539 -2.4467 -1.445 -2.4893 -.6435 -1.032 -.17 -.6194 c -.0607 -.255 -.1032 -.4674 -.1032 -.7285 L 6.287 .1335 6.6997 0 l .9957 .1336 .419 .3642 .6192 1.4147 1.0018 2.2282 1.5543 3.0296 .4553 .8985 .2429 .8318 .091 .255 h .1579 v -.1457 l .1275 -1.706 .2368 -2.0947 .2307 -2.6957 .0789 -.7589 .3764 -.9107 .7468 -.4918 .5828 .2793 .4797 .686 -.0668 .4433 -.2853 1.8517 -.5586 2.9021 -.3643 1.9429 h .2125 l .2429 -.2429 .9835 -1.3053 1.6514 -2.0643 .7286 -.8196 .85 -.9046 .5464 -.4311 h 1.0321 l .759 1.1293 -.34 1.1657 -1.0625 1.3478 -.8804 1.1414 -1.2628 1.7 -.7893 1.36 .0729 .1093 .1882 -.0183 2.8535 -.607 1.5421 -.2794 1.8396 -.3157 .8318 .3886 .091 .3946 -.3278 .8075 -1.967 .4857 -2.3072 .4614 -3.4364 .8136 -.0425 .0304 .0486 .0607 1.5482 .1457 .6618 .0364 h 1.621 l 3.0175 .2247 .7892 .522 .4736 .6376 -.079 .4857 -1.2142 .6193 -1.6393 -.3886 -3.825 -.9107 -1.3113 -.3279 h -.1822 v .1093 l 1.0929 1.0686 2.0035 1.8092 2.5075 2.3314 .1275 .5768 -.3218 .4554 -.34 -.0486 -2.2039 -1.6575 -.85 -.7468 -1.9246 -1.621 h -.1275 v .17 l .4432 .6496 2.3436 3.5214 .1214 1.0807 -.17 .3521 -.6071 .2125 -.6679 -.1214 -1.3721 -1.9246 L 14.38 17.959 l -1.1414 -1.9428 -.1397 .079 -.674 7.2552 -.3156 .3703 -.7286 .2793 -.6071 -.4614 -.3218 -.7468 .3218 -1.4753 .3886 -1.9246 .3157 -1.53 .2853 -1.9004 .17 -.6314 -.0121 -.0425 -.1397 .0182 -1.4328 1.9672 -2.1796 2.9446 -1.7243 1.8456 -.4128 .164 -.7164 -.3704 .0667 -.6618 .4008 -.5889 2.386 -3.0357 1.4389 -1.882 .929 -1.0868 -.0062 -.1579 h -.0546 l -6.3385 4.1164 -1.1293 .1457 -.4857 -.4554 .0608 -.7467 .2307 -.2429 1.9064 -1.3114 Z",
    codex: "M 8.086 .457 a 6.105 6.105 0 0 1 3.046 -.415 c 1.333 .153 2.521 .72 3.564 1.7 a .117 .117 0 0 0 .107 .029 c 1.408 -.346 2.762 -.224 4.061 .366 l .063 .03 .154 .076 c 1.357 .703 2.33 1.77 2.918 3.198 .278 .679 .418 1.388 .421 2.126 a 5.655 5.655 0 0 1 -.18 1.631 .167 .167 0 0 0 .04 .155 5.982 5.982 0 0 1 1.578 2.891 c .385 1.901 -.01 3.615 -1.183 5.14 l -.182 .22 a 6.063 6.063 0 0 1 -2.934 1.851 .162 .162 0 0 0 -.108 .102 c -.255 .736 -.511 1.364 -.987 1.992 -1.199 1.582 -2.962 2.462 -4.948 2.451 -1.583 -.008 -2.986 -.587 -4.21 -1.736 a .145 .145 0 0 0 -.14 -.032 c -.518 .167 -1.04 .191 -1.604 .185 a 5.924 5.924 0 0 1 -2.595 -.622 6.058 6.058 0 0 1 -2.146 -1.781 c -.203 -.269 -.404 -.522 -.551 -.821 a 7.74 7.74 0 0 1 -.495 -1.283 6.11 6.11 0 0 1 -.017 -3.064 .166 .166 0 0 0 .008 -.074 .115 .115 0 0 0 -.037 -.064 5.958 5.958 0 0 1 -1.38 -2.202 5.196 5.196 0 0 1 -.333 -1.589 6.915 6.915 0 0 1 .188 -2.132 c .45 -1.484 1.309 -2.648 2.577 -3.493 .282 -.188 .55 -.334 .802 -.438 .286 -.12 .573 -.22 .861 -.304 a .129 .129 0 0 0 .087 -.087 A 6.016 6.016 0 0 1 5.635 2.31 C 6.315 1.464 7.132 .846 8.086 .457 z m -.804 7.85 a .848 .848 0 0 0 -1.473 .842 l 1.694 2.965 -1.688 2.848 a .849 .849 0 0 0 1.46 .864 l 1.94 -3.272 a .849 .849 0 0 0 .007 -.854 l -1.94 -3.393 z m 5.446 6.24 a .849 .849 0 0 0 0 1.695 h 4.848 a .849 .849 0 0 0 0 -1.696 h -4.848 z",
    cursor: "M 11.503 .131 1.891 5.678 a .84 .84 0 0 0 -.42 .726 v 11.188 c 0 .3 .162 .575 .42 .724 l 9.609 5.55 a 1 1 0 0 0 .998 0 l 9.61 -5.55 a .84 .84 0 0 0 .42 -.724 V 6.404 a .84 .84 0 0 0 -.42 -.726 L 12.497 .131 a 1.01 1.01 0 0 0 -.996 0 M 2.657 6.338 h 18.55 c .263 0 .43 .287 .297 .515 L 12.23 22.918 c -.062 .107 -.229 .064 -.229 -.06 V 12.335 a .59 .59 0 0 0 -.295 -.51 l -9.11 -5.257 c -.109 -.063 -.064 -.23 .061 -.23",
    opencode: "M 22 24 H 2 V 0 h 20 z M 17 4.8 H 7 v 14.4 h 10 z",
  };
  // Brand colours that read on any background (the hub gives Claude Code's cursor the same one).
  const AGENT_COLORS = { claude: "#D97757", codex: "#3941FF" };
  const AGENT_COLOR = "#bf5af2"; // everyone else's, as the hub's
  const agentColor = (name) => AGENT_COLORS[agentBrand(name)] || AGENT_COLOR;
  const SPARKLE = "M12 2.5l2.3 6.2 6.2 2.3-6.2 2.3L12 19.5l-2.3-6.2L3.5 11l6.2-2.3z";

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
      // A coding agent working on a comment; its cursor rests on that comment's element.
      isAgent: p.isAgent === true,
      at: p.isAgent === true && p.at && typeof p.at === "object" ? cleanPos(p.at) : null,
      device: cleanDevice(p.device),
      // What they may do; the host decides in OpenTraffic.
      role: ROLES.includes(p.role) ? p.role : "commenter",
      inView: p.inView === true,
    };
  }

  const ROLES = ["trusted", "commenter", "viewer"];

  // Device = { browser <= 60, os <= 60, viewport "390x844" }, or null.
  function cleanDevice(d) {
    if (!d || typeof d !== "object") return null;
    const browser = oneLine(d.browser, 60);
    const os = oneLine(d.os, 60);
    if (!browser || !os || typeof d.viewport !== "string" || !VIEWPORT_RE.test(d.viewport)) return null;
    return { browser, os, viewport: d.viewport };
  }

  // The CSS properties a suggested edit may change (the hub keeps the same list).
  const EDIT_STYLES = ["color", "background-color", "font-size", "font-weight", "line-height", "letter-spacing",
    "padding", "margin", "gap", "border-radius", "border", "width", "height", "text-align", "opacity"];
  // Computed styles recorded with a comment, for agents (the hub keeps the same list).
  const CONTEXT_STYLES = ["color", "background-color", "font-size", "font-weight", "font-family", "line-height",
    "padding", "margin", "border", "border-radius", "display", "width", "height", "opacity", "gap", "text-align"];
  const CSS_VALUE_RE = /^[^;{}<>\\"'`]*$/;
  const cssValue = (v) => { const t = oneLine(v, 120); return t && CSS_VALUE_RE.test(t) && !t.includes("/*") ? t : ""; };

  // Edit = { kind: "text", old, new } | { kind: "style", property, old, new }, or null.
  function cleanEdit(e) {
    if (!e || typeof e !== "object") return null;
    if (e.kind === "text") {
      const nw = oneLine(e.new, 500);
      return nw ? { kind: "text", old: oneLine(e.old, 500), new: nw } : null;
    }
    if (e.kind === "style" && EDIT_STYLES.includes(e.property)) {
      const nw = cssValue(e.new);
      return nw ? { kind: "style", property: e.property, old: cssValue(e.old), new: nw } : null;
    }
    return null;
  }

  // Area = { width, height } in CSS pixels from the comment's position, or null.
  function cleanArea(a) {
    if (!a || typeof a !== "object") return null;
    const w = finite(a.width);
    const ht = finite(a.height);
    return w !== null && ht !== null && w >= 4 && ht >= 4 && w <= 20000 && ht <= 20000 ? { width: w, height: ht } : null;
  }

  // Context = { selector?, styles, component?, source? } (only the host gets it), or null.
  function cleanContext(x) {
    if (!x || typeof x !== "object") return null;
    const styles = {};
    if (x.styles && typeof x.styles === "object") {
      for (const k of CONTEXT_STYLES) { const v = cssValue(x.styles[k]); if (v) styles[k] = v; }
    }
    const out = { selector: oneLine(x.selector, 300), component: oneLine(x.component, 80), source: oneLine(x.source, 200), styles };
    return out.selector || out.component || out.source || Object.keys(styles).length ? out : null;
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
      mine: c.mine === true, // we wrote it
      // Who resolved it ("" when unknown), whether that's an agent or the commenter, and whether
      // the commenter agreed with the fix; `after` pictures the element once fixed.
      resolvedBy: c.resolved === true ? cleanName(c.resolvedBy) : "",
      resolvedByAgent: c.resolved === true && c.resolvedByAgent === true,
      resolvedByAuthor: c.resolved === true && c.resolvedByAuthor === true,
      confirmed: c.resolved === true && c.confirmed === true,
      after: c.resolved === true && validId(c.after) ? c.after : null,
      claim: c.resolved !== true && c.claim && typeof c.claim === "object" && cleanName(c.claim.agent)
        ? { agent: cleanName(c.claim.agent), progress: oneLine(c.claim.progress, MAX_PROGRESS) }
        : null,
      edits: Array.isArray(c.edits) ? c.edits.slice(0, 6).map(cleanEdit).filter(Boolean) : [],
      area: cleanArea(c.area),
      context: cleanContext(c.context),
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
  // A selector a developer can search the code for: the element's tag, id and classes (generated
  // class names left out), under its nearest ancestor with an id.
  const NAMED_ID_RE = /^[A-Za-z][\w-]{0,63}$/;
  function readableSelector(el) {
    const part = (e) => {
      if (e.id && NAMED_ID_RE.test(e.id)) return e.localName + "#" + e.id;
      const classes = [...e.classList]
        .filter((c) => /^[A-Za-z_-][\w-]{0,40}$/.test(c) && !/\d{3,}|^(?:css|sc|jsx|svelte|emotion|tw)-/.test(c))
        .slice(0, 3);
      return e.localName + classes.map((c) => "." + c).join("");
    };
    const parts = [part(el)];
    if (!(el.id && NAMED_ID_RE.test(el.id))) {
      for (let a = el.parentElement, i = 0; a && a !== document.body && i < 6; a = a.parentElement, i++) {
        if (a.id && NAMED_ID_RE.test(a.id)) { parts.unshift("#" + a.id); break; }
      }
    }
    return parts.join(" ").slice(0, 300);
  }

  // A source location as the dev server gives it, made short and free of this machine's paths:
  // "src/components/Hero.tsx:42".
  function shortSource(raw, line) {
    if (typeof raw !== "string" || !raw) return null;
    let p = raw.replace(/^[a-z][\w+.-]*:\/\/[^/]*/i, "").replace(/[?#].*$/, "").replace(/^\/@fs/, "");
    try { p = decodeURIComponent(p); } catch { /* keep as is */ }
    const i = p.lastIndexOf("/src/");
    if (i >= 0) p = p.slice(i + 1);
    else p = p.split("/").filter(Boolean).slice(-3).join("/");
    if (!p || p.includes("node_modules")) return null;
    return p + (line ? ":" + line : "");
  }

  // The file of the first frame of a stack that's the app's own code (not a library or the
  // framework). No line: the stack is of the code as the dev server transformed it, whose lines
  // don't match the source.
  function stackSource(stack) {
    if (typeof stack !== "string") return null;
    for (const lineText of stack.split("\n").slice(0, 20)) {
      const m = /(https?:\/\/[^\s)]+?):\d+:\d+/.exec(lineText);
      if (!m || /node_modules|\/\.vite\/deps\/|\/@react-refresh|react-dom|react_jsx|jsx-dev-runtime|chunk-/.test(m[1])) continue;
      return shortSource(m[1]);
    }
    return null;
  }

  // The component that rendered `el` and the file it's in, from development builds of React, Vue,
  // Svelte or Angular. Production builds don't keep these, so it's null there.
  function componentInfo(el) {
    try {
      for (let e = el, depth = 0; e && depth < 5; e = e.parentElement, depth++) {
        const key = Object.keys(e).find((k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$"));
        if (key) {
          let source = null;
          for (let f = e[key], i = 0; f && i < 60; f = f.return, i++) {
            if (!source && f._debugSource && f._debugSource.fileName) source = shortSource(f._debugSource.fileName, f._debugSource.lineNumber);
            if (!source && f._debugStack) source = stackSource(f._debugStack.stack);
            const t = f.type;
            const name = typeof t === "function" ? t.displayName || t.name
              : t && typeof t === "object" ? t.displayName || (t.render && (t.render.displayName || t.render.name)) || (t.type && (t.type.displayName || t.type.name)) : "";
            if (name) return { component: oneLine(name, 80), source };
          }
          return source ? { component: "", source } : null;
        }
        const vue3 = e.__vueParentComponent;
        if (vue3 && vue3.type) return { component: oneLine(vue3.type.__name || vue3.type.name || "", 80), source: shortSource(vue3.type.__file) };
        const vue2 = e.__vue__;
        if (vue2 && vue2.$options) return { component: oneLine(vue2.$options.name || "", 80), source: shortSource(vue2.$options.__file) };
        const svelte = e.__svelte_meta;
        if (svelte && svelte.loc && svelte.loc.file) return { component: "", source: shortSource(svelte.loc.file, typeof svelte.loc.line === "number" ? svelte.loc.line + 1 : 0) };
      }
      const ng = window.ng;
      if (ng && typeof ng.getOwningComponent === "function") {
        const owner = ng.getOwningComponent(el);
        if (owner && owner.constructor) return { component: oneLine(owner.constructor.name || "", 80), source: null };
      }
    } catch { /* a page's own objects can throw */ }
    return null;
  }

  // What agents get with a comment: where the element comes from and how it looks.
  function elementContext(el) {
    if (!el || el.nodeType !== 1) return null;
    const out = { selector: readableSelector(el), styles: {} };
    try {
      const cs = getComputedStyle(el);
      for (const k of CONTEXT_STYLES) { const v = cssValue(cs.getPropertyValue(k)); if (v) out.styles[k] = v; }
    } catch { /* detached */ }
    const info = componentInfo(el);
    if (info && info.component) out.component = info.component;
    if (info && info.source) out.source = info.source;
    return out;
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
  // In a device view the stage above decides following and leading; the tab's session is the stage's.
  const session = inFrame ? {} : readSession(); // { follow?: 0|1, followAt?, navTo?, lead?: bool, match?: bool }
  const saveSession = () => { if (!inFrame) setItem("sessionStorage", SESSION_KEY, JSON.stringify(session)); };

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
  let viewOpen = false; // the View menu (Phone / Desktop)
  const PHONE = { w: 390, h: 844 };
  const PHONE_PATHS = ["M8 2.5h8a1.5 1.5 0 0 1 1.5 1.5v16a1.5 1.5 0 0 1-1.5 1.5H8A1.5 1.5 0 0 1 6.5 20V4A1.5 1.5 0 0 1 8 2.5z", "M11 18.5h2"];
  const DESKTOP_PATHS = ["M3.5 4.5h17a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1h-17a1 1 0 0 1-1-1v-10a1 1 0 0 1 1-1z", "M9 20.5h6", "M12 16.5v4"];
  // The device view while it's open. mode: "person" (View at their size), "self" (Phone, for yourself,
  // and for your followers when you lead), or "lead" (the host's phone or window, while you follow them).
  let stage = null; // { mode, id?, name, w, ht, kind, fit, follow, path, cursor?, pos, scale, armed }

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
  const forceShow = new Set(); // resolved comments shown anyway (we're looking at their fix)
  const fixQueue = []; // ids of our comments someone fixed, to tell us about
  let toastId = null; // the fix the notice is about
  let captureChain = Promise.resolve(); // pictures of fixes, one at a time
  const capturing = new Set();
  const seenFixes = new Set((() => {
    try {
      const v = JSON.parse(getItem("localStorage", FIXES_KEY) || "[]");
      return Array.isArray(v) ? v.filter(validId).slice(-FIXES_KEPT) : [];
    } catch {
      return [];
    }
  })());
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

  // Whose scrolling leads: the page, or while the host's phone is open, the page in it.
  const frameLeads = () => { try { return !!stageApi.leadView(); } catch { return false; } };
  const frameFollows = () => { try { return !!stageApi.followsLead(); } catch { return false; } };
  const isLeading = () => !!(me && me.isHost && leadOn && joined && (inFrame ? frameLeads() : !(stage && stage.mode === "self")));

  // ---------------------------------------------------------------- UI

  const CSS_TEXT = `
:host { all: initial; --tb-font: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, Roboto, Helvetica, Arial, sans-serif; }
* { box-sizing: border-box; }
[hidden] { display: none !important; }
.layer { position: fixed; inset: 0; overflow: hidden; pointer-events: none; }
.cursor { position: absolute; left: 0; top: 0; transition: transform 90ms linear; will-change: transform; }
.cursor.inking { transition: none; }
.cursor svg { display: block; width: 16px; height: 20px; filter: drop-shadow(0 1px 1.5px rgba(0,0,0,.35)); }
.tag { position: absolute; left: 12px; top: 17px; max-width: 160px; padding: 2px 6px; border-radius: 6px;
  font: 600 11px/1.35 var(--tb-font); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.pill, .pop, .stage, .zoom { --solid: #fbfbfd; --bg: rgba(255,255,255,.94); --fg: #1d1d1f; --muted: #6e6e73; --line: rgba(0,0,0,.1); --accent: #0a84ff; }
.pill { position: fixed; right: 16px; bottom: 16px; max-width: calc(100vw - 32px); display: flex; align-items: center; gap: 8px;
  padding: 4px 6px 4px 4px; border-radius: 999px; background: var(--bg); color: var(--fg);
  box-shadow: 0 6px 20px rgba(0,0,0,.12), 0 0 0 .5px var(--line);
  -webkit-backdrop-filter: blur(14px); backdrop-filter: blur(14px);
  font: 500 12px/1.2 var(--tb-font); pointer-events: auto; user-select: none; -webkit-user-select: none; }
@media (prefers-color-scheme: dark) {
  .pill, .pop, .stage, .zoom { --solid: #2c2c2e; --bg: rgba(44,44,46,.92); --fg: #f5f5f7; --muted: #a1a1a6; --line: rgba(255,255,255,.14); }
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
.list { position: absolute; right: 0; bottom: calc(100% + 8px); min-width: 180px; max-width: 340px; max-height: 320px;
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
.act { padding: 4px 10px; border-radius: 7px; background: var(--line); font: 600 12px/1.3 var(--tb-font); white-space: nowrap; }
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
.bubble { width: 290px; max-height: calc(100vh - 16px); overflow-y: auto; overscroll-behavior: contain; }
/* Cancel/Post and the reply buttons stay in view when a tall box scrolls. */
.composer > .actions, .bubble > .actions { position: sticky; bottom: -10px; z-index: 1; margin: 8px -10px -10px; padding: 8px 10px 10px;
  background: var(--solid); border-radius: 0 0 12px 12px; box-shadow: 0 -1px 0 var(--line); }
.shot { display: block; width: 100%; margin-top: 8px; border-radius: 8px; overflow: hidden; background: var(--line); cursor: zoom-in; }
.shot img { display: block; width: 100%; height: auto; max-height: 180px; object-fit: contain; }
.shotrow { display: flex; align-items: center; justify-content: space-between; gap: 6px; margin-top: 8px; }
.shotrow .cap { margin-top: 0; }
.shotrow + .shot { margin-top: 4px; }
.hold { touch-action: none; user-select: none; -webkit-user-select: none; }
.hold[aria-pressed="true"] { background: var(--accent); color: #fff; }
.zoom { position: fixed; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px;
  padding: 24px; background: rgba(0,0,0,.62); pointer-events: auto; cursor: zoom-out; font: 400 13px/1.4 var(--tb-font); color: var(--fg); }
.zoom img { display: block; max-width: 100%; max-height: calc(100vh - 112px); object-fit: contain; border-radius: 10px;
  background: var(--solid); box-shadow: 0 20px 60px rgba(0,0,0,.45); cursor: default; }
.zoombar { display: flex; align-items: center; gap: 10px; padding: 6px 6px 6px 14px; border-radius: 999px; background: var(--bg);
  box-shadow: 0 6px 20px rgba(0,0,0,.3), 0 0 0 .5px var(--line); cursor: default; }
.zoombar .cap { margin-top: 0; min-width: 40px; }
.zoombar .x { width: 26px; height: 26px; display: grid; place-items: center; border-radius: 50%; background: var(--line); }
.envline { margin-top: 6px; color: var(--muted); font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.thread { margin-top: 8px; border-top: .5px solid var(--line); max-height: 220px; overflow: auto; }
.reply { padding-top: 7px; }
.reply .text { margin-top: 2px; max-height: none; overflow: visible; }
.agent { flex: none; max-width: 130px; padding: 1px 6px; border-radius: 6px; background: rgba(191,90,242,.16); color: #a54bd6;
  font-size: 10px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.replybox { min-height: 36px; margin-top: 8px; }
/* Beside the comment's pin rather than under it. */
.cursor.by-agent { margin: -12px 0 0 26px; }
.cursor.by-agent .tag { display: flex; align-items: center; gap: 4px; font-style: italic; }
.mark { display: inline-block; flex: none; vertical-align: -2px; }
.av .mark { display: block; }
.ttitle { display: flex; align-items: center; gap: 6px; }
.agent .mark { margin-right: 3px; vertical-align: -1px; }
.pin.working::before { content: ""; position: absolute; inset: -5px; border-radius: inherit; border: 2px solid var(--agent, #bf5af2);
  animation: tb-work 1.6s ease-in-out infinite; pointer-events: none; }
@keyframes tb-work { 0%, 100% { opacity: .25; } 50% { opacity: 1; } }
.fixline { margin-top: 8px; padding: 4px 7px; border-radius: 7px; background: rgba(48,209,88,.14); color: #1f8a3a;
  font-size: 12px; font-weight: 600; overflow-wrap: anywhere; }
.fixline.working { background: color-mix(in srgb, var(--agent, #bf5af2) 15%, transparent); color: color-mix(in srgb, var(--agent, #bf5af2) 78%, black); }
/* On an 8px grid: 8px padding and gap, two rows of 16px text, and a 20px mark centred on them. */
.fixline { display: flex; align-items: center; gap: 8px; padding: 8px; border-radius: 8px; }
.fixline .mark { flex: none; width: 20px; height: 20px; margin: 0; }
.fixline .lines { min-width: 0; }
.fixline .t1 { font-weight: 700; line-height: 16px; }
.fixline .t2 { font-weight: 500; line-height: 16px; opacity: .85; overflow-wrap: anywhere; }
.cap { margin-top: 8px; color: var(--muted); font-size: 11px; font-weight: 600; }
.cap + .shot { margin-top: 3px; }
.toast { left: auto; top: auto; right: 16px; bottom: 64px; width: 300px; }
.toast .ttitle { font-weight: 700; }
.toast .ttext { margin-top: 3px; color: var(--muted); overflow-wrap: anywhere; max-height: 3.6em; overflow: hidden; }
.errs { flex: none; display: flex; align-items: center; gap: 4px; color: #ff9f0a; font-size: 11px; font-weight: 600; white-space: nowrap; cursor: help; }
.errs svg { display: block; flex: none; }
.editbar { display: flex; gap: 6px; margin-top: 8px; }
.act.small { padding: 3px 8px; font-size: 11px; }
.act.small[aria-pressed="true"] { background: var(--accent); color: #fff; }
.editfield, .styler .hex, .styler .num { all: unset; box-sizing: border-box; width: 100%; padding: 4px 7px; border-radius: 7px; background: var(--line);
  font: 500 12px/1.4 var(--tb-font); cursor: text; }
.editfield { display: block; margin-top: 6px; }
.composer.styling { width: 300px; }
.composer { max-height: calc(100vh - 16px); overflow-y: auto; overscroll-behavior: contain; }
/* The style editor: a row per property, label | control | reset. */
.styler { display: grid; grid-template-columns: 62px minmax(0, 1fr) 18px; gap: 6px 8px; align-items: center; margin-top: 8px; }
.styler .lbl { color: var(--muted); font-size: 11px; font-weight: 600; white-space: nowrap; }
.styler .ctl { display: flex; align-items: center; gap: 6px; min-width: 0; }
.styler .reset { width: 18px; height: 18px; display: grid; place-items: center; border-radius: 50%; color: var(--muted); }
.styler .reset:hover { background: var(--line); color: var(--fg); }
.styler .reset.off { visibility: hidden; }
.styler .hex { flex: 1; min-width: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; }
.styler .num { flex: none; width: 52px; padding: 3px 6px; text-align: right; font-variant-numeric: tabular-nums; }
.sw { position: relative; flex: none; width: 22px; height: 22px; border-radius: 6px; overflow: hidden;
  box-shadow: inset 0 0 0 1px rgba(0,0,0,.14); }
.sw.clear, .sw.chk { background: repeating-conic-gradient(#d4d4d8 0 25%, #fff 0 50%) 0 0 / 8px 8px; }
.sw .fill { position: absolute; inset: 0; }
.sw[aria-pressed="true"], .sw.on { box-shadow: 0 0 0 2px var(--bg), 0 0 0 4px var(--accent); }
.sw.big { width: 26px; height: 26px; border-radius: 7px; }
.sw.rainbow { background: conic-gradient(#ff3b30, #ff9500, #ffcc00, #34c759, #00c7be, #007aff, #af52de, #ff2d55, #ff3b30); }
.sw.rainbow input { position: absolute; inset: 0; width: 100%; height: 100%; padding: 0; margin: 0; opacity: 0; cursor: pointer; }
.sw.tool2 { display: grid; place-items: center; background: var(--line); box-shadow: none; color: var(--fg); }
.palette { grid-column: 1 / -1; padding: 8px; border-radius: 10px; background: var(--line); }
.palette .pcap { margin: 0 0 5px; color: var(--muted); font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em; }
.palette .swrow { display: flex; flex-wrap: wrap; gap: 4px; margin-bottom: 8px; }
.palette .swgrid { display: grid; grid-template-columns: repeat(10, minmax(0, 1fr)); gap: 3px; }
.palette .swgrid .sw { width: 100%; height: auto; aspect-ratio: 1; border-radius: 5px; }
.palette .pfoot { display: flex; align-items: center; gap: 6px; margin-top: 8px; font-size: 11px; color: var(--muted); }
.palette .pfoot .sp { flex: 1; }
input.range { all: unset; flex: 1; min-width: 0; height: 22px; cursor: pointer; -webkit-appearance: none; appearance: none; background: transparent; }
input.range::-webkit-slider-runnable-track { height: 4px; border-radius: 2px;
  background: linear-gradient(to right, var(--accent) var(--fill, 0%), var(--line) var(--fill, 0%)); }
input.range::-moz-range-track { height: 4px; border-radius: 2px; background: var(--line); }
input.range::-moz-range-progress { height: 4px; border-radius: 2px; background: var(--accent); }
input.range::-webkit-slider-thumb { -webkit-appearance: none; width: 16px; height: 16px; margin-top: -6px; border-radius: 50%;
  background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,.35), 0 0 0 .5px rgba(0,0,0,.15); }
input.range::-moz-range-thumb { width: 16px; height: 16px; border: 0; border-radius: 50%; background: #fff;
  box-shadow: 0 1px 3px rgba(0,0,0,.35), 0 0 0 .5px rgba(0,0,0,.15); }
input.range:focus-visible::-webkit-slider-thumb { box-shadow: 0 0 0 3px rgba(10,132,255,.5); }
.weights { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); flex: 1; padding: 2px; border-radius: 8px; background: var(--line); }
.weights button { padding: 3px 0; border-radius: 6px; text-align: center; font: 13px/1.2 var(--tb-font); }
.weights button[aria-pressed="true"] { background: var(--bg); box-shadow: 0 1px 2px rgba(0,0,0,.18); }
.edits .chip { display: inline-block; width: 10px; height: 10px; margin-right: 4px; border-radius: 3px; vertical-align: -1px;
  box-shadow: inset 0 0 0 1px rgba(0,0,0,.18); }
.edits { margin-top: 8px; padding: 7px 8px; border-radius: 8px; background: var(--line); font-size: 12px; }
.edits .erow { overflow-wrap: anywhere; }
.edits .erow + .erow { margin-top: 3px; }
.edits .old { text-decoration: line-through; opacity: .65; }
.edits .new { font-weight: 600; }
.edits .prop { color: var(--muted); }
.edits .act { margin-top: 6px; }
.source { margin-top: 4px; font: 500 11px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); overflow-wrap: anywhere; }
.areabox { position: absolute; left: 0; top: 0; border: 2px dashed currentColor; border-radius: 6px;
  background: color-mix(in srgb, currentColor 8%, transparent); opacity: .5; }
.areabox.open, .areabox.draft { opacity: 1; }
.areabox.draft { color: #0a84ff; }
.ink { position: absolute; left: 0; top: 0; width: 100%; height: 100%; overflow: visible; }
.ink path { fill: none; stroke-width: 4; stroke-linecap: round; stroke-linejoin: round; transition: opacity .6s; shape-rendering: geometricPrecision; }
.ink path.fading { opacity: 0; }
.row .rl, .row .dev { color: var(--muted); font-size: 11px; }
.list.menu { min-width: 230px; }
.list .opt { display: flex; align-items: center; gap: 8px; width: 100%; padding: 6px; border-radius: 7px; white-space: nowrap; }
.list .opt:hover { background: var(--line); }
.list .opt svg { flex: none; color: var(--muted); }
.list .opt .ot { font-weight: 600; }
.list .opt .od { margin-left: auto; padding-left: 14px; color: var(--muted); font-size: 11px; }
.list .opt[aria-checked="true"] { background: color-mix(in srgb, var(--accent) 14%, transparent); }
.list .opt[aria-checked="true"] svg { color: var(--accent); }
.list .note { padding: 3px 6px 4px; color: var(--muted); font-size: 11px; white-space: normal; }
.row .view { padding: 1px 6px; border-radius: 6px; background: var(--line); font-size: 11px; font-weight: 600; }
/* "View at their size": their window as a device on a stage over the (blurred) page. */
.stage { position: fixed; inset: 0; display: flex; flex-direction: column; align-items: center; gap: 12px; padding: 14px 16px 64px;
  background: rgba(12,12,16,.46); -webkit-backdrop-filter: blur(16px) saturate(1.15); backdrop-filter: blur(16px) saturate(1.15);
  font: 400 13px/1.4 var(--tb-font); pointer-events: auto; animation: tb-in .2s ease-out; }
@keyframes tb-in { from { opacity: 0; } to { opacity: 1; } }
.sbar { position: relative; z-index: 1; flex: none; display: flex; align-items: center; gap: 10px; max-width: 100%; min-width: 0; padding: 5px 5px 5px 12px; border-radius: 999px;
  background: var(--bg); color: var(--fg); box-shadow: 0 10px 30px rgba(0,0,0,.28), 0 0 0 .5px var(--line); font-size: 12px; white-space: nowrap; }
.sbar .who { display: flex; align-items: center; gap: 6px; font-weight: 700; }
.sbar .dot { width: 8px; height: 8px; border-radius: 50%; }
.sbar .smeta { min-width: 0; overflow: hidden; text-overflow: ellipsis; color: var(--muted); }
.sbar .switch { font-weight: 600; }
.seg { flex: none; display: flex; padding: 2px; border-radius: 8px; background: var(--line); }
.seg button { padding: 2px 9px; border-radius: 6px; font-weight: 600; }
.seg button[aria-pressed="true"] { background: var(--bg); box-shadow: 0 1px 2px rgba(0,0,0,.18); }
/* The whole stage, so the device's shadow isn't clipped; padded so the device sits between the bar and the pill. */
.sarea { position: absolute; inset: 0; display: flex; padding: 62px 16px 64px; overflow: auto; overscroll-behavior: contain; }
.device { position: relative; flex: none; margin: auto; }
/* A slim black bezel inside a thin titanium-like rim, with side buttons (on top when turned). */
.device.phone, .device.tablet { padding: var(--bz); border: 1.5px solid transparent; border-radius: calc(var(--r) + var(--bz) + 1.5px);
  background: linear-gradient(#0a0a0b, #0a0a0b) padding-box,
    linear-gradient(150deg, #b4b4b9, #4a4a4e 20%, #2a2a2d 50%, #4a4a4e 80%, #9a9aa0) border-box;
  box-shadow: inset 0 0 0 1px rgba(255,255,255,.05), 0 2px 6px rgba(0,0,0,.18), 0 24px 60px rgba(0,0,0,.38); }
.device.phone .screen, .device.tablet .screen { box-shadow: 0 0 0 1px rgba(0,0,0,.5); }
.device.phone::before, .device.phone::after { content: ""; position: absolute; width: 3px; border-radius: 2px;
  background: linear-gradient(90deg, #6a6a6f, #2e2e31); }
.device.phone::before { left: -4px; top: 20%; height: 12%; }
.device.phone::after { right: -4px; top: 26%; height: 9%; border-radius: 0 2px 2px 0; }
.device.phone.land::before { left: 20%; top: -4px; width: 12%; height: 3px; background: linear-gradient(#6a6a6f, #2e2e31); }
.device.phone.land::after { left: auto; right: 26%; top: auto; bottom: -4px; width: 9%; height: 3px; background: linear-gradient(#2e2e31, #6a6a6f); }
.device.desktop { border-radius: 12px; overflow: hidden; background: #ececef; box-shadow: 0 30px 80px rgba(0,0,0,.5), 0 0 0 .5px rgba(0,0,0,.35); }
.chrome { display: flex; align-items: center; gap: 12px; height: 34px; padding: 0 12px; color: #6e6e73; font-size: 11.5px; }
.chrome .lights { flex: none; display: flex; gap: 7px; }
.chrome .lights span { width: 11px; height: 11px; border-radius: 50%; background: #ff5f57; }
.chrome .lights span + span { background: #febc2e; }
.chrome .lights span + span + span { background: #28c840; }
.chrome .addr { flex: 1; min-width: 0; max-width: 420px; height: 22px; margin: 0 auto; padding: 0 10px; border-radius: 6px; background: rgba(0,0,0,.06);
  display: flex; align-items: center; justify-content: center; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chrome .pad { flex: none; width: 47px; }
.screen { position: relative; overflow: hidden; border-radius: var(--r); background: #fff; transition: width .25s ease, height .25s ease; }
.device.desktop .screen { border-radius: 0; }
.screen iframe { position: absolute; left: 0; top: 0; display: block; border: 0; transform-origin: 0 0; background: #fff; }
.screen .cursor { z-index: 1; }
.gone { position: absolute; inset: 0; z-index: 2; display: grid; place-items: center; padding: 16px; text-align: center;
  background: rgba(0,0,0,.5); color: #fff; font-weight: 600; }
@media (prefers-color-scheme: dark) {
  .device.desktop { background: #2c2c2e; box-shadow: 0 30px 80px rgba(0,0,0,.6), 0 0 0 .5px rgba(255,255,255,.16); }
  .chrome { color: #a1a1a6; }
  .chrome .addr { background: rgba(255,255,255,.08); }
}
@media (max-width: 620px) { .sbar .smeta { display: none; } }
@media (prefers-color-scheme: dark) {
  .agent { background: rgba(191,90,242,.28); color: #da8fff; }
  .fixline { background: rgba(48,209,88,.2); color: #5be07f; }
  .fixline.working { background: color-mix(in srgb, var(--agent, #bf5af2) 26%, transparent); color: color-mix(in srgb, var(--agent, #bf5af2) 55%, white); }
}
@media (max-width: 520px) {
  .pill { gap: 5px; }
  .pill > .count, .pill > .switch .label, .pill > .errs .label { display: none; }
  .name { max-width: 64px; }
}
@media (prefers-reduced-motion: reduce) {
  .cursor, .track, .track::after { transition: none; }
  .pin.working::before { animation: none; opacity: .8; }
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
  // Which agent a name belongs to, as the hub decides it ("Claude Code", "cursor-agent", …), or null.
  function agentBrand(name) {
    const n = String(name || "").toLowerCase();
    if (n.includes("opencode")) return "opencode";
    if (n.includes("claude")) return "claude";
    if (n.includes("codex")) return "codex";
    if (n.includes("cursor")) return "cursor";
    return null;
  }

  // The agent's mark (a sparkle when OpenTraffic has none), filled with the text colour, or with
  // `tinted`, the brand's colour where it has one.
  function agentMark(name, size, tinted) {
    const svg = document.createElementNS(SVG_NS, "svg");
    for (const [k, v] of [["viewBox", "0 0 24 24"], ["width", size], ["height", size], ["aria-hidden", "true"], ["fill", "currentColor"]]) svg.setAttribute(k, v);
    svg.classList.add("mark");
    if (tinted) css(svg, { color: agentColor(name) });
    const p = document.createElementNS(SVG_NS, "path");
    p.setAttribute("d", AGENT_MARKS[agentBrand(name)] || SPARKLE);
    // Codex's ">_" is cut out by the even-odd rule; Claude's overlapping rays need the default one.
    if (agentBrand(name) === "codex") p.setAttribute("fill-rule", "evenodd");
    svg.append(p);
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
  // Where the comment box and bubbles go: our own shadow root, or in a device view, one on the stage's page.
  let uiRoot = root;
  let uiHost = null;
  if (inFrame) {
    const pdoc = window.parent.document;
    uiHost = pdoc.createElement("opentraffic-view-ui");
    uiHost.setAttribute("data-opentraffic-ui", "");
    css(uiHost, { all: "initial", position: "fixed", top: 0, left: 0, width: 0, height: 0, display: "block", "pointer-events": "none", "z-index": 2147483647 });
    uiRoot = uiHost.attachShadow({ mode: "closed" });
    try {
      const sheet = new window.parent.CSSStyleSheet();
      sheet.replaceSync(CSS_TEXT);
      uiRoot.adoptedStyleSheets = [sheet];
    } catch {
      const st = pdoc.createElement("style");
      st.textContent = CSS_TEXT;
      uiRoot.append(st);
    }
    window.addEventListener("pagehide", () => uiHost.remove());
  }
  const pinLayer = h("div", "layer"); // comment markers (clickable)
  const layer = h("div", "layer"); // cursors, point pulses, comment-mode outline
  const outline = h("div", "outline");
  const draftDot = h("div", "draft");
  const draftBox = h("div", "areabox draft"); // an area being dragged out, or the draft's area
  outline.hidden = draftDot.hidden = draftBox.hidden = true;
  const inkSvg = document.createElementNS(SVG_NS, "svg"); // strokes drawn with the Draw tool
  inkSvg.setAttribute("class", "ink");
  layer.append(inkSvg, outline, draftDot, draftBox);

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
  const drawBtn = button("tool", null, "Draw on the page");
  drawBtn.title = "Draw \u2014 everyone on this page sees it for a few seconds";
  drawBtn.append(icon(16, "M4 20l4-1 10.5-10.5a2.1 2.1 0 0 0-3-3L5 16z", "M14 7l3 3"));
  // View: the page as a phone, or as your own window (Desktop).
  const viewBtn = button("tool", null, "View as phone or desktop");
  viewBtn.setAttribute("aria-haspopup", "menu");
  const viewMenu = h("div", "list menu");
  viewMenu.setAttribute("role", "menu");
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
  pill.append(listEl, viewMenu, avatarsEl, countEl, nameBtn, nameInput, switchBtn, badgeBtn, commentBtn, pointBtn, drawBtn, viewBtn, errsEl, statusEl, collapseBtn);

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
  // Suggested edits: new text for the element, or new values for a few of its styles, previewed on
  // the page while the composer is open.
  const editBar = h("div", "editbar");
  const textEditBtn = button("act small", "Edit text", "Suggest new text for it");
  const styleEditBtn = button("act small", "Edit style", "Suggest new styles for it");
  editBar.append(textEditBtn, styleEditBtn);
  const textEdit = h("input", "editfield");
  textEdit.maxLength = 500;
  textEdit.setAttribute("aria-label", "New text");
  const STYLE_FIELDS = ["color", "background-color", "font-size", "font-weight", "padding", "border-radius"];
  const styleEdit = h("div", "styler"); // its rows are built below, with the editor
  composer.append(textArea, editBar, textEdit, styleEdit, composerRow);
  composer.hidden = noteEl.hidden = textEdit.hidden = styleEdit.hidden = true;

  // The style editor: colour swatches with a palette, sliders for sizes, and a weight picker,
  // each row with its own undo. Values are kept only while they differ from how the element is.
  const PALETTE = [ // Tailwind's 100, 300, 500, 700 and 900, a column per hue
    ["#f3f4f6", "#d1d5db", "#6b7280", "#374151", "#111827"], ["#fee2e2", "#fca5a5", "#ef4444", "#b91c1c", "#7f1d1d"],
    ["#ffedd5", "#fdba74", "#f97316", "#c2410c", "#7c2d12"], ["#fef3c7", "#fcd34d", "#f59e0b", "#b45309", "#78350f"],
    ["#dcfce7", "#86efac", "#22c55e", "#15803d", "#14532d"], ["#ccfbf1", "#5eead4", "#14b8a6", "#0f766e", "#134e4a"],
    ["#dbeafe", "#93c5fd", "#3b82f6", "#1d4ed8", "#1e3a8a"], ["#e0e7ff", "#a5b4fc", "#6366f1", "#4338ca", "#312e81"],
    ["#f3e8ff", "#d8b4fe", "#a855f7", "#7e22ce", "#581c87"], ["#fce7f3", "#f9a8d4", "#ec4899", "#be185d", "#831843"],
  ];
  const WEIGHTS = [[300, "Light"], [400, "Regular"], [500, "Medium"], [600, "Semibold"], [700, "Bold"], [800, "Extra bold"]];
  const styleValues = new Map(); // property -> suggested value
  const styleSyncs = [];
  const colorProbe = h("span");
  colorProbe.hidden = true;

  const isColorProp = (prop) => prop === "color" || prop === "background-color";
  // "#rrggbb", "transparent", or rgba() when partly transparent, from what getComputedStyle gives.
  function rgbText(c) {
    const m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+)(%?))?\s*\)$/.exec(String(c || "").trim());
    if (!m) return "";
    const a = m[4] === undefined ? 1 : Number(m[4]) / (m[5] ? 100 : 1);
    if (a <= 0) return "transparent";
    const rgb = [m[1], m[2], m[3]].map((n) => Math.max(0, Math.min(255, Math.round(Number(n)))));
    if (a < 1) return "rgba(" + rgb.join(", ") + ", " + Math.round(a * 100) / 100 + ")";
    return "#" + rgb.map((n) => n.toString(16).padStart(2, "0")).join("");
  }
  // Any CSS colour the browser knows, in the form above ("" if it isn't one).
  function normColor(v) {
    v = String(v || "").trim();
    if (!v || !cssValue(v)) return "";
    try {
      if (!CSS.supports("color", v)) return "";
      colorProbe.style.setProperty("color", v);
      return rgbText(getComputedStyle(colorProbe).color) || v;
    } catch {
      return "";
    }
  }
  // Box values ("4px", "4px 8px", …) as [top, right, bottom, left] numbers.
  function boxSides(v) {
    const p = String(v || "").trim().split(/\s+/).map((x) => parseFloat(x) || 0);
    return [p[0] || 0, p.length > 1 ? p[1] : p[0] || 0, p.length > 2 ? p[2] : p[0] || 0, p.length > 3 ? p[3] : p.length > 1 ? p[1] : p[0] || 0];
  }
  function sameStyle(prop, a, b) {
    if (isColorProp(prop)) return normColor(a) === normColor(b);
    if (prop === "padding" || prop === "border-radius") return boxSides(a).join() === boxSides(b).join();
    return String(a).trim() === String(b).trim();
  }
  const styleNow = (prop) => styleValues.get(prop) || (draft && draft.oldStyles[prop]) || "";
  const num = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : 0; };

  function setStyle(prop, value) {
    if (!draft || !STYLE_FIELDS.includes(prop)) return;
    const v = cssValue(value);
    if (!v || sameStyle(prop, v, draft.oldStyles[prop] || "")) styleValues.delete(prop);
    else styleValues.set(prop, v);
    previewOn(draft.el, draft.node);
    previewStyle(prop, styleValues.get(prop) || "");
    syncStyler();
    updatePostBtn();
  }

  function syncStyler() {
    for (const sync of styleSyncs) sync();
    const now = palette.prop ? normColor(styleNow(palette.prop)) : "";
    for (const b of palette.querySelectorAll(".sw[data-color]")) b.classList.toggle("on", !!now && normColor(b.dataset.color) === now);
  }

  // A row: label, controls, and an undo button for the property.
  function styleRow(label, prop, ...controls) {
    const ctl = h("div", "ctl");
    ctl.append(...controls);
    const reset = button("reset off", null, "Undo the " + label.toLowerCase() + " change");
    reset.title = "Back to how it is";
    reset.append(icon(12, "M3 12a9 9 0 1 0 3-6.7", "M3 4v5h5"));
    reset.addEventListener("click", () => setStyle(prop, ""));
    styleEdit.append(h("span", "lbl", label), ctl, reset);
    styleSyncs.push(() => reset.classList.toggle("off", !styleValues.has(prop)));
    return reset;
  }

  function swatch(color, name) {
    const b = button("sw" + (color === "transparent" ? " clear" : ""), null, name || color);
    b.title = name || color;
    b.dataset.color = color;
    const fill = h("span", "fill");
    css(fill, { "background-color": color });
    b.append(fill);
    b.addEventListener("click", () => setStyle(palette.prop, color));
    return b;
  }

  const palette = h("div", "palette");
  palette.hidden = true;
  palette.prop = null;
  const pageCap = h("div", "pcap", "On this page");
  const pageRow = h("div", "swrow");
  const paletteGrid = h("div", "swgrid");
  for (let shade = 0; shade < 5; shade++) for (const hue of PALETTE) paletteGrid.append(swatch(hue[shade]));
  const clearSwatch = swatch("transparent", "No colour");
  const customColor = h("label", "sw rainbow");
  customColor.title = "Any colour";
  const colorInput = h("input");
  colorInput.type = "color";
  colorInput.setAttribute("aria-label", "Any colour");
  customColor.append(colorInput);
  colorInput.addEventListener("input", () => setStyle(palette.prop, colorInput.value));
  const dropper = button("sw tool2", null, "Pick a colour from the screen");
  dropper.title = "Pick a colour from the screen";
  dropper.append(icon(14, "m2 22 1-1h3l9-9", "M3 21v-3l9-9", "m15 6 3.4-3.4a2.1 2.1 0 1 1 3 3L18 9l.4.4a2.1 2.1 0 1 1-3 3l-3.8-3.8a2.1 2.1 0 1 1 3-3l.4.4Z"));
  dropper.hidden = typeof window.EyeDropper !== "function";
  dropper.addEventListener("click", async () => {
    const prop = palette.prop;
    try {
      const picked = await new window.EyeDropper().open();
      if (prop && draft) setStyle(prop, picked.sRGBHex);
    } catch { /* cancelled */ }
  });
  const paletteFoot = h("div", "pfoot");
  paletteFoot.append(swatch("#ffffff", "White"), swatch("#000000", "Black"), clearSwatch, h("span", "sp"), customColor, dropper);
  palette.append(pageCap, pageRow, h("div", "pcap", "Palette"), paletteGrid, paletteFoot);

  // The colours the page itself uses most, so a suggestion can stay on brand.
  function pageColors() {
    const counts = new Map();
    const add = (c, weight) => {
      const v = rgbText(c);
      if (v.startsWith("#")) counts.set(v, (counts.get(v) || 0) + weight);
    };
    try {
      const all = document.body ? document.body.getElementsByTagName("*") : [];
      for (let i = 0; i < all.length && i < 1500; i++) {
        const cs = getComputedStyle(all[i]);
        if (cs.display === "none" || cs.visibility === "hidden") continue;
        add(cs.backgroundColor, 2);
        if (parseFloat(cs.borderTopWidth) > 0) add(cs.borderTopColor, 1);
        for (const n of all[i].childNodes) if (n.nodeType === 3 && n.nodeValue.trim()) { add(cs.color, 1); break; }
      }
      if (document.body) add(getComputedStyle(document.body).backgroundColor, 4);
    } catch { /* best effort */ }
    return [...counts].sort((a, b) => b[1] - a[1]).slice(0, 10).map(([c]) => c);
  }

  function togglePalette(prop, after) {
    if (!draft) return;
    if (!palette.hidden && palette.prop === prop) {
      palette.hidden = true;
      palette.prop = null;
    } else {
      palette.prop = prop;
      after.after(palette);
      palette.hidden = false;
      clearSwatch.hidden = prop !== "background-color";
      if (!draft.pageColors) draft.pageColors = pageColors();
      pageRow.replaceChildren(...draft.pageColors.map((c) => swatch(c)));
      pageCap.hidden = pageRow.hidden = !draft.pageColors.length;
      const now = normColor(styleNow(prop));
      colorInput.value = /^#[0-9a-f]{6}$/.test(now) ? now : "#000000";
    }
    syncStyler();
    placeAll();
    // The composer stays put; if the palette doesn't fit, it scrolls inside it.
    if (!palette.hidden) {
      const over = palette.getBoundingClientRect().bottom - composer.getBoundingClientRect().bottom + 10;
      if (over > 0) composer.scrollTop += over;
    }
  }

  function colorRow(label, prop) {
    const sw = button("sw big chk", null, "Choose the " + label.toLowerCase() + " colour");
    const fill = h("span", "fill");
    sw.append(fill);
    const field = h("input", "hex");
    field.maxLength = 60;
    field.spellcheck = false;
    field.setAttribute("aria-label", label + " colour, any CSS colour");
    const reset = styleRow(label, prop, sw, field);
    sw.addEventListener("click", () => togglePalette(prop, reset));
    field.addEventListener("input", () => {
      const v = field.value.trim();
      if (!v || normColor(v)) setStyle(prop, v);
    });
    field.addEventListener("blur", syncStyler);
    styleSyncs.push(() => {
      const v = normColor(styleNow(prop));
      css(fill, { "background-color": v || "transparent" });
      if (uiRoot.activeElement !== field) field.value = v;
      sw.setAttribute("aria-expanded", String(palette.prop === prop));
    });
  }

  function sliderRow(label, prop, min, max, read, write) {
    const range = h("input", "range");
    range.type = "range";
    range.min = String(min);
    range.step = "1";
    range.setAttribute("aria-label", label);
    const field = h("input", "num");
    field.inputMode = "decimal";
    field.spellcheck = false;
    field.setAttribute("aria-label", label + " in pixels");
    styleRow(label, prop, range, field);
    range.addEventListener("input", () => setStyle(prop, write(Number(range.value))));
    field.addEventListener("change", () => {
      const n = parseFloat(field.value);
      if (Number.isFinite(n)) setStyle(prop, write(Math.max(0, Math.min(999, Math.round(n)))));
      syncStyler();
    });
    styleSyncs.push(() => {
      const n = Math.round(read(styleNow(prop)));
      // A range around how it is now, so a small drag is a small change.
      const top = Math.max(typeof max === "function" ? max(read((draft && draft.oldStyles[prop]) || "")) : max, n);
      range.max = String(top);
      range.value = String(n);
      css(range, { "--fill": Math.round(((n - min) / (top - min)) * 100) + "%" });
      if (uiRoot.activeElement !== field) field.value = n + "px";
    });
  }

  colorRow("Text", "color");
  colorRow("Background", "background-color");
  sliderRow("Size", "font-size", 8, (now) => Math.max(32, Math.round(now * 2.5)), num, (n) => n + "px");
  const weightBox = h("div", "weights");
  weightBox.setAttribute("role", "group");
  weightBox.setAttribute("aria-label", "Weight");
  const weightBtns = WEIGHTS.map(([w, name]) => {
    const b = button(null, "Aa", name + ", " + w);
    b.title = name + " · " + w;
    css(b, { "font-weight": w });
    b.addEventListener("click", () => setStyle("font-weight", String(w)));
    weightBox.append(b);
    return b;
  });
  styleRow("Weight", "font-weight", weightBox);
  styleSyncs.push(() => {
    const now = Math.round(num(styleNow("font-weight")) / 100) * 100;
    WEIGHTS.forEach(([w], i) => weightBtns[i].setAttribute("aria-pressed", String(w === now)));
  });
  const pad = () => boxSides(styleNow("padding"));
  sliderRow("Padding ↕", "padding", 0, 48, (v) => boxSides(v)[0], (n) => n + "px " + pad()[1] + "px");
  sliderRow("Padding ↔", "padding", 0, 48, (v) => boxSides(v)[1], (n) => pad()[0] + "px " + n + "px");
  sliderRow("Corners", "border-radius", 0, 32, (v) => boxSides(v)[0], (n) => n + "px");

  // Starts the editor on how the element is now.
  function resetStyler() {
    styleValues.clear();
    palette.hidden = true;
    palette.prop = null;
    for (const b of weightBtns) css(b, { "font-family": (draft && draft.font) || "inherit" });
    syncStyler();
  }

  styleEdit.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.isComposing) return;
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); postComment(); }
  });
  for (const t of ["keyup", "keypress", "input", "change"]) styleEdit.addEventListener(t, stop);

  const bubble = h("div", "pop bubble");
  bubble.setAttribute("role", "dialog");
  const bDot = h("span", "dot");
  const bWho = h("span", "who");
  const bWhen = h("span", "when");
  const bMeta = h("div", "meta");
  bMeta.append(bDot, bWho, bWhen);
  const bLabel = h("div", "elabel");
  const bSource = h("div", "source"); // the host's: where the element comes from in the code
  const bText = h("div", "text");
  const bEdits = h("div", "edits"); // suggested changes, old -> new
  const bEditRows = h("div");
  const bPreviewBtn = button("act small", "Preview on the page");
  bPreviewBtn.setAttribute("aria-pressed", "false");
  bEdits.append(bEditRows, bPreviewBtn);
  // One picture: the fix once there's a picture of it, else the comment's own. "Hold to see before"
  // swaps to the comment's picture while it's pressed; clicking the picture shows it large, on the page.
  const bShot = button("shot", null, "Show the picture larger");
  bShot.title = "Show it larger";
  const bShotImg = h("img");
  bShotImg.decoding = "async"; // attached only while a comment with a screenshot is open
  const bFix = h("div", "fixline"); // who's working on it, or who fixed it
  const bShotRow = h("div", "shotrow");
  const bShotCap = h("div", "cap", "After");
  const bHold = holdButton();
  bShotRow.append(bShotCap, bHold);
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
  const confirmBtn = button("act primary", "Looks good", "The fix works");
  const deleteBtn = button("act");
  const replyBtn = button("act primary", "Reply", "Send reply");
  const bActions = h("div", "actions");
  bActions.append(replyNote, resolveBtn, deleteBtn, confirmBtn, replyBtn);
  bubble.append(bMeta, bLabel, bSource, bText, bEdits, bFix, bShotRow, bShot, bEnv, bThread, replyArea, bActions);
  bubble.hidden = replyNote.hidden = bShot.hidden = bEnv.hidden = bThread.hidden = bSource.hidden = bEdits.hidden = true;
  bFix.hidden = bShotRow.hidden = confirmBtn.hidden = true;

  // The picture, large over the page: Esc, the close button, or a click beside it closes it.
  const zoom = h("div", "zoom");
  zoom.setAttribute("role", "dialog");
  zoom.setAttribute("aria-modal", "true");
  zoom.setAttribute("aria-label", "Picture of the commented element");
  const zoomImg = h("img");
  const zoomBar = h("div", "zoombar");
  const zoomCap = h("div", "cap");
  const zoomHold = holdButton();
  const zoomClose = button("x", null, "Close");
  zoomClose.append(icon(14, "M6 6l12 12M18 6L6 18"));
  zoomBar.append(zoomCap, zoomHold, zoomClose);
  zoom.append(zoomImg, zoomBar);
  zoom.hidden = true;
  // Pictures of the open comment: `before` (the comment's own) and `after` (the fix), either may be "".
  const shots = { before: "", after: "", holding: false };

  // "Fixed: take a look", for the person whose comment it was.
  const toast = h("div", "pop toast");
  toast.setAttribute("role", "status");
  const tTitle = h("div", "ttitle");
  const tText = h("div", "ttext");
  const tLater = button("act", "Later", "Dismiss");
  const tLook = button("act primary", "Take a look");
  const tActions = h("div", "actions");
  tActions.append(tLater, tLook);
  toast.append(tTitle, tText, tActions);
  toast.hidden = true;

  // "View at their size": the page someone is on, in a device as big as their window, on a stage
  // over this page. It follows them to other pages, and shows their pointer.
  const viewer = h("div", "stage");
  viewer.setAttribute("role", "dialog");
  viewer.setAttribute("aria-modal", "true");
  const sBar = h("div", "sbar");
  const sDot = h("span", "dot");
  const sName = h("span", "who");
  const sMeta = h("span", "smeta");
  const sFit = button(null, "Fit", "Fit the window");
  const sActual = button(null, "100%", "Actual size");
  const sSeg = h("div", "seg");
  sSeg.append(sFit, sActual);
  const sFollow = button("switch");
  sFollow.setAttribute("role", "switch");
  sFollow.append(h("span", "track"), h("span", "label", "Follow"));
  const vWindow = button("tool", null, "Open in a window at their size");
  vWindow.title = "Open in a window at their size";
  vWindow.append(icon(15, "M14 4h6v6", "M20 4l-8 8", "M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"));
  const vClose = button("tool", null, "Close");
  vClose.title = "Close (Esc)";
  vClose.append(icon(15, "M6 6l12 12", "M18 6L6 18"));
  const sRotate = button("tool", null, "Turn the phone");
  sRotate.title = "Turn the phone";
  sRotate.append(icon(15, "M4 12a8 8 0 0 1 13.7-5.6L20 8.5", "M20 3.5v5h-5", "M20 12a8 8 0 0 1-13.7 5.6L4 15.5", "M4 20.5v-5h5"));
  sBar.append(sName, sMeta, sRotate, sSeg, sFollow, vWindow, vClose);
  const sArea = h("div", "sarea");
  const sDevice = h("div", "device");
  const sChrome = h("div", "chrome");
  const sLights = h("span", "lights");
  sLights.append(h("span"), h("span"), h("span"));
  const sAddr = h("span", "addr");
  sChrome.append(sLights, sAddr, h("span", "pad"));
  const vFrame = h("div", "screen");
  const vIframe = h("iframe");
  vIframe.setAttribute("referrerpolicy", "same-origin");
  const sGone = h("div", "gone");
  sGone.hidden = true;
  vFrame.append(vIframe, sGone);
  sDevice.append(sChrome, vFrame);
  sArea.append(sDevice);
  viewer.append(sBar, sArea);
  viewer.hidden = true;

  if (styleEl) root.append(styleEl);
  root.append(pinLayer, layer, toast, viewer, pill, colorProbe);
  uiRoot.append(composer, bubble, zoom);

  // Appended to <html>, not <body>, which SPAs may replace; re-attached if removed.
  function mount() {
    if (!host.isConnected && document.documentElement) document.documentElement.appendChild(host);
    if (uiHost && !uiHost.isConnected) {
      try { window.parent.document.documentElement.appendChild(uiHost); } catch { /* the stage is gone */ }
    }
  }
  // The overlay's own UI, here or a device view's on this page: page handlers leave it alone.
  const isOurs = (t) => t === host || !!(t && t.nodeType === 1 && t.hasAttribute("data-opentraffic-ui"));

  // People the host set to view only can't comment, reply, or resolve (the hub refuses it too).
  const canComment = () => !me || me.isHost || me.role !== "viewer";
  const ROLE_TEXT = { trusted: "trusted", viewer: "view only" };

  const HOST_MARK = " \u00b7 host";
  const AGENT_MARK = " \u00b7 agent";
  const role = (p) => (p.isHost ? HOST_MARK : p.isAgent ? AGENT_MARK : "");
  const describe = (p) =>
    p.name + (p === me ? " (you)" : "") + role(p) + " \u2014 " + (p.path || "/");

  function avatar(p) {
    const a = h("span", "av", p.isAgent ? null : initials(p.name));
    if (p.isAgent) a.append(agentMark(p.name, 17));
    css(a, { background: p.color, color: textOn(p.color) });
    a.title = describe(p);
    return a;
  }

  let reportedArmed = null;
  function render() {
    mount();
    pill.hidden = !shown || inFrame; // a device view is worked from the stage's pill
    if (inFrame && reportedArmed !== armed) {
      reportedArmed = armed;
      try { stageApi.armed(armed); } catch { /* the stage is gone */ }
    }
    // A device view is the same person (theirs, or ours), not someone else.
    const everyone = me ? [me, ...[...peers.values()].filter((p) => !p.inView)] : [];
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
          row.title = describe(p) + (p.device ? "\n" + p.device.browser + ", " + p.device.os + ", window " + p.device.viewport : "");
          row.append(dot, h("span", "who", p.name + (p === me ? " (you)" : "") + role(p)));
          if (!p.isHost && !p.isAgent && ROLE_TEXT[p.role]) row.append(h("span", "rl", ROLE_TEXT[p.role]));
          if (p.device) row.append(h("span", "dev", p.device.viewport.replace("x", "\u00d7")));
          row.append(h("span", "where", p.path || "/"));
          if (p !== me && p.device && !p.isAgent) {
            const view = button("view", "View", "View at " + p.name + "'s size");
            view.title = "See this page at " + p.name + "'s window size (" + p.device.viewport + ")";
            view.addEventListener("click", () => openViewer(p));
            row.append(view);
          }
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
    commentBtn.hidden = !tools || !canComment();
    pointBtn.hidden = drawBtn.hidden = !tools;
    const tool = stage ? stage.armed : armed; // in a device view, the tool in use there
    commentBtn.setAttribute("aria-pressed", String(tool === "comment"));
    pointBtn.setAttribute("aria-pressed", String(tool === "point"));
    drawBtn.setAttribute("aria-pressed", String(tool === "draw"));
    // View: not on a phone (it already is one), and not in someone's device view.
    const phoneView = !!(stage && stage.mode === "self");
    viewBtn.hidden = !tools || narrow.matches;
    viewBtn.replaceChildren(icon(16, ...(phoneView ? PHONE_PATHS : DESKTOP_PATHS)));
    viewBtn.title = phoneView ? "Phone view (390 × 844)" : "View as phone or desktop";
    viewBtn.setAttribute("aria-expanded", String(viewOpen));
    viewBtn.setAttribute("aria-pressed", String(phoneView));
    viewMenu.hidden = !viewOpen || viewBtn.hidden;
    if (!viewMenu.hidden) renderViewMenu(phoneView);
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
  for (const el of [pill, pinLayer, composer, bubble, toast, viewer]) for (const t of ["click", "pointerdown", "mousedown"]) el.addEventListener(t, stop);
  avatarsEl.addEventListener("click", () => {
    listOpen = !listOpen;
    viewOpen = false;
    render();
  });
  viewBtn.addEventListener("click", () => {
    viewOpen = !viewOpen;
    listOpen = false;
    render();
  });

  function renderViewMenu(phoneView) {
    const option = (paths, title, detail, on, pick) => {
      const b = button("opt");
      b.setAttribute("role", "menuitemradio");
      b.setAttribute("aria-checked", String(on));
      b.append(icon(15, ...paths), h("span", "ot", title), h("span", "od", detail));
      b.addEventListener("click", () => {
        viewOpen = false;
        pick();
        render();
      });
      return b;
    };
    const rows = [
      h("div", "head", "View"),
      option(PHONE_PATHS, "Phone", PHONE.w + " × " + PHONE.h, phoneView, openPhone),
      option(DESKTOP_PATHS, "Desktop", "Your window", !phoneView, () => { if (phoneView) leaveStage(); }),
    ];
    if (me && me.isHost) {
      // What the people following you see.
      rows.push(h("div", "sep"));
      if (phoneView) rows.push(h("div", "note", leadOn ? "Your followers see the phone too." : "When you lead, your followers see the phone too."));
      else {
        const match = button("switch");
        match.setAttribute("role", "menuitemcheckbox");
        match.setAttribute("aria-checked", String(!!session.match));
        match.title = "Followers see the page at your window's exact size, instead of their own";
        match.append(h("span", "track"), h("span", "label", "Followers match my window"));
        match.addEventListener("click", () => {
          session.match = !session.match;
          saveSession();
          pushView();
          render();
        });
        rows.push(match);
      }
    }
    viewMenu.replaceChildren(...rows);
  }
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
  commentBtn.addEventListener("click", () => useTool("comment"));
  pointBtn.addEventListener("click", () => useTool("point"));
  drawBtn.addEventListener("click", () => useTool("draw"));
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
    // Above when it fits there; otherwise as low as the window allows (it grows while you edit styles).
    if (top + ht > vh - 8) top = y - 10 - ht >= 8 ? y - 10 - ht : Math.max(8, vh - 8 - ht);
    css(el, { left: Math.round(left) + "px", top: Math.round(top) + "px" });
  }

  // In a device view: one fixed place for the comment box and bubbles (only one is ever open), beside
  // the device (right, else left) and centred between the stage's bar and the pill. Growing (Edit style,
  // the palette) keeps it centred; taller than the space, it scrolls inside.
  function popOut(el) {
    let dev, area;
    try { dev = stageApi.device(); area = stageApi.area(); } catch { return; }
    const pw = window.parent.innerWidth;
    const room = Math.max(160, Math.floor(area.height));
    css(el, { "max-height": room + "px" });
    const w = el.offsetWidth;
    const ht = Math.min(el.offsetHeight, room);
    const left = dev.right + 16 + w <= pw - 8 ? dev.right + 16 : dev.left - 16 - w >= 8 ? dev.left - 16 - w : pw - w - 16;
    css(el, { left: Math.round(left) + "px", top: Math.round(area.top + (area.height - ht) / 2) + "px" });
  }

  // Beside `target` (right, else left), so a preview of changes to it stays in sight; false if neither side has room.
  function popBeside(el, target) {
    if (!target || !target.isConnected) return false;
    const r = target.getBoundingClientRect();
    const w = el.offsetWidth;
    const ht = el.offsetHeight;
    const vw = document.documentElement.clientWidth || window.innerWidth;
    const vh = window.innerHeight;
    const left = r.right + 12 + w <= vw - 8 ? r.right + 12 : r.left - 12 - w >= 8 ? r.left - 12 - w : null;
    if (left === null) return false;
    // Room below for the palette too, so it can open without the composer moving.
    const room = el === composer && draft && draft.editing === "style" && palette.hidden ? 250 : 0;
    const top = Math.max(8, Math.min(vh - 8 - ht - room, r.top + r.height / 2 - 60));
    css(el, { left: Math.round(left) + "px", top: Math.round(top) + "px" });
    return true;
  }

  function placeAll() {
    for (const [id, c] of cursors) place(id, c);
    for (const [id, p] of pins) {
      p.v = toViewport(comments.get(id));
      translate(p.el, p.v.x, p.v.y);
      if (p.box) {
        translate(p.box, p.v.x, p.v.y);
        p.box.classList.toggle("open", id === bubbleId);
      }
    }
    placeInk();
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
      draftDot.hidden = !!draft.area;
      if (draft.area) {
        css(draftBox, { width: draft.area.width + "px", height: draft.area.height + "px" });
        translate(draftBox, v.x, v.y);
        draftBox.hidden = false;
        outline.hidden = true;
      }
      if (draft.editing && draft.spot && !inFrame) {
        // While editing, it stays where it opened on the page: the element changing size doesn't move it.
        const top = draft.spot.y - (inFrame ? 0 : window.scrollY);
        css(composer, { left: Math.round(draft.spot.x - (inFrame ? 0 : window.scrollX)) + "px", top: Math.round(top) + "px",
          "max-height": Math.max(160, (inFrame ? window.parent : window).innerHeight - 8 - top) + "px" });
      } else {
        composer.style.removeProperty("max-height");
        if (inFrame) popOut(composer);
        else if (!(draft.editing && popBeside(composer, draft.el))) popAt(composer, v.x + (draft.area ? draft.area.width : 0), v.y);
        if (draft.editing && !inFrame) {
          const r = composer.getBoundingClientRect();
          draft.spot = { x: r.left + (inFrame ? 0 : window.scrollX), y: r.top + (inFrame ? 0 : window.scrollY) };
        }
      }
    }
    const open = bubbleId && pins.get(bubbleId);
    if (open) {
      if (inFrame) popOut(bubble);
      else popAt(bubble, open.v.x + 10, open.v.y - 22);
    }
  }

  let placeRaf = 0;
  const needsPlace = () => !!(cursors.size || pins.size || pings.size || strokes.size || armed || draft || bubbleId);
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
    if (peer.isAgent) c.tag.replaceChildren(agentMark(peer.name, 14), document.createTextNode(peer.name + " \u00b7 working"));
    else c.tag.textContent = peer.name;
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
    for (const [id, c] of cursors) if (!c.agent && now - c.at > CURSOR_TTL) dropCursor(id);
    if (!cursors.size) { clearInterval(sweepTimer); sweepTimer = 0; }
  }

  // An agent's cursor rests on the element of the comment it's working on, for as long as it is.
  function showAgent(peer) {
    if (!peer.isAgent || !peer.at) return;
    let c = cursors.get(peer.id);
    if (!c) {
      c = makeCursor(peer);
      c.agent = true;
      c.el.classList.add("by-agent");
      cursors.set(peer.id, c);
      layer.append(c.el);
    } else paintCursor(c, peer);
    Object.assign(c, peer.at);
    mount();
    place(peer.id, c);
  }

  function cursorOf(id, peer) {
    let c = cursors.get(id);
    if (!c) {
      c = makeCursor(peer);
      cursors.set(id, c);
      layer.append(c.el);
      if (!sweepTimer) sweepTimer = setInterval(sweep, 5000);
    }
    return c;
  }

  function onCursor(m) {
    const peer = peers.get(m.id);
    const pos = cleanPos(m);
    if (!peer || !pos || peer.isAgent) return;
    const c = cursorOf(m.id, peer);
    if (c.inkAt && Date.now() - c.inkAt < 250) return; // drawing: the pointer rides on the stroke
    Object.assign(c, pos);
    c.at = Date.now();
    mount();
    place(m.id, c);
    stageCursor(m.id, pos);
  }

  // ---------------------------------------------------------------- comments and pins

  function setComments(list) {
    comments.clear();
    for (const raw of Array.isArray(list) ? list.slice(-MAX_COMMENTS) : []) {
      const c = cleanComment(raw);
      if (c) comments.set(c.id, c);
    }
    // Fixes made while we were away, oldest first.
    [...comments.values()].sort((a, b) => a.createdAt - b.createdAt).forEach(announceFix);
    renderPins();
  }

  function upsertComment(raw) {
    const c = cleanComment(raw);
    if (!c) return;
    const before = comments.get(c.id);
    if (!before && comments.size >= MAX_COMMENTS) comments.delete(comments.keys().next().value);
    comments.set(c.id, c);
    if (!before || !before.resolved) announceFix(c);
    if (!c.resolved) forceShow.delete(c.id);
    renderPins();
    if (toastId === c.id && (!c.resolved || c.confirmed)) hideToast();
  }

  function removeComment(id) {
    if (typeof id !== "string" || !comments.delete(id)) return;
    forceShow.delete(id);
    if (toastId === id) hideToast();
    renderPins();
  }

  // ---------------------------------------------------------------- fixes

  // Someone else resolved our comment: say so once (per browser), with a way to go and see.
  function announceFix(c) {
    if (!c.mine || !c.resolved || c.resolvedByAuthor || c.confirmed || !c.resolvedBy || seenFixes.has(c.id)) return;
    if (toastId === c.id || fixQueue.includes(c.id)) return;
    fixQueue.push(c.id);
    if (!toastId) showNextFix();
  }

  function showNextFix() {
    if (inFrame) return; // the stage's own overlay says it
    toastId = null;
    while (fixQueue.length) {
      const c = comments.get(fixQueue.shift());
      if (!c || !c.resolved || c.confirmed) continue;
      toastId = c.id;
      seenFixes.add(c.id);
      setItem("localStorage", FIXES_KEY, JSON.stringify([...seenFixes].slice(-FIXES_KEPT)));
      tTitle.replaceChildren(
        c.resolvedByAgent ? agentMark(c.resolvedBy, 16, true) : document.createTextNode("\u2713 "),
        document.createTextNode(c.resolvedBy + " fixed your comment")
      );
      const words = Array.from(c.text.replace(/\s+/g, " ")).slice(0, 90).join("");
      tText.textContent = "\u201c" + words + (words.length < c.text.length ? "\u2026" : "") + "\u201d" + (c.path !== lastPath ? " on " + c.path : "");
      toast.hidden = false;
      return;
    }
    toast.hidden = true;
  }

  function hideToast() {
    toastId = null;
    toast.hidden = true;
    if (fixQueue.length) setTimeout(showNextFix, 400);
  }

  tLater.addEventListener("click", hideToast);
  tLook.addEventListener("click", () => {
    const c = toastId && comments.get(toastId);
    hideToast();
    if (c) lookAtFix(c);
  });

  // Shows the fixed element and its thread (going to its page first), and pictures the fix if
  // nobody has yet.
  function lookAtFix(c) {
    if (c.path !== lastPath) {
      const path = safePath(c.path);
      if (path === null) return;
      session.reveal = c.id;
      saveSession();
      location.assign(path); // safePath() guarantees a same-origin path
      return;
    }
    forceShow.add(c.id);
    renderPins();
    revealComment(c);
    if (c.mine && !c.after) queueCapture(c.id, 800);
  }

  // The hub asks the host's page for pictures of fixes on it; ours when we look at our own.
  function onCapture(m) {
    if (!me || !me.isHost || !validId(m.id)) return;
    const c = comments.get(m.id);
    if (c && c.resolved && !c.after && c.path === lastPath) queueCapture(c.id, AFTER_SETTLE);
  }

  function queueCapture(id, delay) {
    if (capturing.has(id)) return;
    capturing.add(id);
    captureChain = captureChain
      .then(() => new Promise((r) => setTimeout(r, delay)))
      .then(() => captureAfter(id))
      .catch(() => {})
      .then(() => new Promise((r) => setTimeout(r, AFTER_GAP)))
      .finally(() => capturing.delete(id));
  }

  async function captureAfter(id) {
    let c = comments.get(id);
    if (!c || !c.resolved || c.after || c.path !== lastPath || !joined) return;
    // The picture is of the fix: the page catches up with it first.
    await refreshPage().catch(() => {});
    c = comments.get(id);
    if (!c || !c.resolved || c.after) return;
    const v = toViewport(c);
    if (!v.el) return; // the element is gone; nothing to picture
    const shot = await screenshot(v.el, c, c.area);
    const now = comments.get(id);
    if (shot && now && now.resolved && !now.after) send({ type: "after", id, screenshot: shot });
  }

  // Comments on this page, oldest first; a pin's number is its index + 1.
  const pageComments = () =>
    [...comments.values()].filter((c) => c.path === lastPath).sort((a, b) => a.createdAt - b.createdAt);

  function renderPins() {
    const keep = new Set();
    openCount = 0;
    pageComments().forEach((c, i) => {
      if (!c.resolved) openCount++;
      // Resolved while someone has it open (an agent fixed it): it stays until they close it.
      else if (c.id === bubbleId) forceShow.add(c.id);
      else if (!showResolved && !forceShow.has(c.id)) return;
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
      p.el.classList.toggle("working", !!c.claim);
      if (c.area && !p.box) {
        p.box = h("div", "areabox");
        layer.prepend(p.box);
      } else if (!c.area && p.box) {
        p.box.remove();
        p.box = null;
      }
      if (p.box) css(p.box, { color: c.color, width: c.area.width + "px", height: c.area.height + "px" });
      if (c.claim) css(p.el, { "--agent": agentColor(c.claim.agent) });
      const nr = c.replies.length;
      p.el.setAttribute("aria-label", "Comment " + p.n + " by " + c.author + (c.resolved ? " (resolved)" : "") +
        (c.claim ? ", " + c.claim.agent + " is working on it" : "") + (nr ? ", " + nr + (nr === 1 ? " reply" : " replies") : ""));
      pinLayer.append(p.el); // keeps DOM (and tab) order by number
    });
    for (const [id, p] of pins) if (!keep.has(id)) { p.el.remove(); if (p.box) p.box.remove(); pins.delete(id); }
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
    closeZoom();
    if (preview && preview.comment === bubbleId) previewOff();
    const was = bubbleId;
    bubbleId = null;
    if (forceShow.delete(was) && !showResolved) setTimeout(renderPins, 0);
    confirmDelete = false;
    clearTimeout(confirmTimer);
    renderBubble();
    if (uiRoot.activeElement === replyArea) replyArea.blur();
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
      const badge = h("span", "agent");
      badge.append(agentMark(r.agent, 12, true), document.createTextNode(r.agent === r.author ? "Agent" : "Agent \u00b7 " + r.agent));
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
    const ctx = me && me.isHost ? c.context : null;
    bSource.hidden = !(ctx && (ctx.component || ctx.source));
    if (!bSource.hidden) {
      bSource.textContent = [ctx.component, ctx.source].filter(Boolean).join(" \u00b7 ");
      bSource.title = "Where it comes from in the code" + (ctx.selector ? "\n" + ctx.selector : "");
    }
    bEdits.hidden = !c.edits.length;
    if (c.edits.length) {
      bEditRows.replaceChildren(...c.edits.map((ed) => {
        const row = h("div", "erow");
        const value = (cls, v) => {
          const span = h("span", cls);
          if (isColorProp(ed.property)) {
            const chip = h("span", "chip");
            css(chip, { "background-color": v }); // a colour property: it can't load anything
            span.append(chip);
          }
          span.append(document.createTextNode(v));
          return span;
        };
        if (ed.kind === "style") row.append(h("span", "prop", ed.property + ": "));
        if (ed.old) row.append(value("old", ed.old), document.createTextNode(" \u2192 "));
        row.append(value("new", ed.new));
        return row;
      }));
      const showing = !!(preview && preview.comment === c.id);
      bPreviewBtn.textContent = showing ? "Stop preview" : "Preview on the page";
      bPreviewBtn.setAttribute("aria-pressed", String(showing));
      bPreviewBtn.hidden = c.resolved;
    }
    const shot = c.screenshot && !failedShots.has(c.screenshot) ? ATTACHMENT_PATH + c.screenshot : "";
    // Who's on it, or who fixed it: a mark spanning two rows, what's happening, and the detail.
    let title = "";
    let detail = "";
    let mark = null;
    if (c.claim) {
      title = c.claim.agent + " is working on this";
      detail = c.claim.progress || "Getting started";
      mark = agentMark(c.claim.agent, 20);
    } else if (c.resolved && c.resolvedBy && !c.resolvedByAuthor) {
      title = "Fixed by " + c.resolvedBy;
      detail = c.confirmed ? (c.mine ? "You" : c.author) + " confirmed the fix"
        : c.mine ? "Confirm it, or reopen it" : "Waiting for " + c.author + " to confirm";
      mark = c.resolvedByAgent ? agentMark(c.resolvedBy, 20, true) : icon(20, "M5 12.5l4.5 4.5L19 7.5");
    }
    if (mark) {
      mark.classList.add("mark");
      const lines = h("div", "lines");
      lines.append(h("div", "t1", title), h("div", "t2", detail));
      bFix.replaceChildren(mark, lines);
    }
    bFix.hidden = !title;
    bFix.classList.toggle("working", !!c.claim);
    if (c.claim) css(bFix, { "--agent": agentColor(c.claim.agent) });
    const after = c.after && !failedShots.has(c.after) ? ATTACHMENT_PATH + c.after : "";
    if (shots.before !== shot || shots.after !== after) {
      shots.before = shot;
      shots.after = after;
      shots.holding = false;
    }
    showShots();
    bEnv.hidden = !c.env;
    if (c.env) {
      bEnv.textContent = [c.env.browser, c.env.os, c.env.viewport].join(" \u00b7 ");
      bEnv.title = c.env.browser + ", " + c.env.os + ", window " + c.env.viewport + " at " + c.env.dpr + "x" +
        (c.env.language ? ", " + c.env.language : "");
    }
    renderThread(c);
    const may = canComment();
    replyArea.hidden = replyBtn.hidden = resolveBtn.hidden = !may;
    replyArea.setAttribute("aria-label", "Reply to" + n);
    resolveBtn.textContent = c.resolved ? "Reopen" : "Resolve";
    resolveBtn.setAttribute("aria-label", resolveBtn.textContent + n);
    // The commenter is asked whether someone else's fix works (Delete makes room meanwhile).
    confirmBtn.hidden = !(may && c.mine && c.resolved && !c.resolvedByAuthor && !c.confirmed);
    deleteBtn.hidden = !c.canDelete || !confirmBtn.hidden;
    deleteBtn.textContent = confirmDelete ? "Really delete?" : "Delete";
    deleteBtn.classList.toggle("danger", confirmDelete);
    deleteBtn.setAttribute("aria-label", (confirmDelete ? "Really delete" : "Delete") + n + (confirmDelete ? "?" : ""));
  }

  bShotImg.addEventListener("error", () => {
    const id = bShotImg.getAttribute("src");
    if (id && id.startsWith(ATTACHMENT_PATH)) failedShots.add(id.slice(ATTACHMENT_PATH.length));
    renderBubble();
    schedulePlace();
  });

  // ---- the open comment's pictures

  // Shows the fix (or, while held, the comment's own picture) in the bubble and the large view.
  function showShots() {
    const pair = !!(shots.before && shots.after);
    const src = shots.after && !(shots.holding && pair) ? shots.after : shots.before;
    const which = src && src === shots.after ? "After" : "Before";
    bShot.hidden = !src;
    if (src) {
      if (bShotImg.getAttribute("src") !== src) bShotImg.src = src;
      if (!bShotImg.isConnected) bShot.append(bShotImg);
      // The other picture, ready for the moment it's held.
      if (pair) h("img").src = src === shots.after ? shots.before : shots.after;
    } else {
      bShotImg.removeAttribute("src");
      bShotImg.remove();
    }
    bShotRow.hidden = zoomCap.hidden = zoomHold.hidden = !pair;
    bShotCap.textContent = zoomCap.textContent = which;
    bShotImg.alt = zoomImg.alt = which === "After" ? "The commented element after the fix" : "Picture of the commented element";
    for (const b of [bHold, zoomHold]) b.setAttribute("aria-pressed", String(shots.holding && pair));
    if (!zoom.hidden) {
      if (src) zoomImg.src = src;
      else closeZoom();
    }
  }

  function setHolding(on) {
    if (shots.holding === on) return;
    shots.holding = on;
    showShots();
  }

  // A button that shows the picture from before the fix for as long as it's pressed (pointer, Space, or Enter).
  function holdButton() {
    const b = button("act small hold", "Hold to see before");
    b.setAttribute("aria-pressed", "false");
    b.title = "Shows the page as it was before the fix while you hold it";
    b.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      try { b.setPointerCapture(e.pointerId); } catch { /* not capturable */ }
      setHolding(true);
    });
    for (const t of ["pointerup", "pointercancel", "lostpointercapture", "blur"]) b.addEventListener(t, () => setHolding(false));
    b.addEventListener("keydown", (e) => {
      if (e.key !== " " && e.key !== "Enter") return;
      e.preventDefault();
      e.stopPropagation();
      if (!e.repeat) setHolding(true);
    });
    b.addEventListener("keyup", (e) => {
      if (e.key !== " " && e.key !== "Enter") return;
      e.preventDefault();
      e.stopPropagation();
      setHolding(false);
    });
    b.addEventListener("click", (e) => e.preventDefault());
    return b;
  }

  function openZoom() {
    const src = bShotImg.getAttribute("src");
    if (!src) return;
    zoomImg.src = src;
    zoom.hidden = false;
    sizeZoom();
    zoomClose.focus();
  }

  // As large as the window allows, up to 3x the picture's pixels (pictures of small elements are small).
  function sizeZoom() {
    const nw = zoomImg.naturalWidth;
    const nh = zoomImg.naturalHeight;
    if (zoom.hidden || !nw || !nh) return;
    const s = Math.min((window.innerWidth - 48) / nw, (window.innerHeight - 112) / nh, 3);
    css(zoomImg, { width: Math.round(nw * s) + "px", height: Math.round(nh * s) + "px" });
  }
  zoomImg.addEventListener("load", sizeZoom);
  window.addEventListener("resize", sizeZoom, { passive: true });

  function closeZoom() {
    if (zoom.hidden) return;
    zoom.hidden = true;
    zoomImg.removeAttribute("src");
    setHolding(false);
    if (!bubble.hidden && !bShot.hidden) bShot.focus();
  }

  bShot.addEventListener("click", openZoom);
  zoomClose.addEventListener("click", closeZoom);
  zoom.addEventListener("click", (e) => { if (e.target === zoom) closeZoom(); });
  zoom.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      closeZoom();
    } else if (e.key === " ") {
      // Holding Space anywhere in the large view shows the picture from before.
      e.preventDefault();
      if (!e.repeat) setHolding(true);
    } else if (e.key === "Tab") {
      // Focus stays in the large view.
      e.preventDefault();
      (uiRoot.activeElement === zoomClose && !zoomHold.hidden ? zoomHold : zoomClose).focus();
    }
  });
  zoom.addEventListener("keyup", (e) => {
    if (e.key !== " ") return;
    e.preventDefault();
    setHolding(false);
  });

  // Shows a comment's suggested edits on its element (only in this browser), or stops showing them.
  bPreviewBtn.addEventListener("click", () => {
    const c = bubbleId && comments.get(bubbleId);
    if (!c) return;
    if (preview && preview.comment === c.id) {
      previewOff();
    } else {
      const v = toViewport(c);
      if (!v.el) return flash(replyNote, "The element isn't on the page", 2000);
      const node = soleTextNode(v.el);
      const p = previewOn(v.el, node);
      p.comment = c.id;
      for (const ed of c.edits) {
        if (ed.kind === "text" && node && oneLine(node.nodeValue, 500) === ed.old) previewText(ed.new);
        else if (ed.kind === "style") previewStyle(ed.property, ed.new);
      }
    }
    renderBubble();
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
  confirmBtn.addEventListener("click", () => {
    const c = bubbleId && comments.get(bubbleId);
    if (c && c.mine && c.resolved) send({ type: "confirm", id: c.id }); // the hub echoes the change
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
    revealComment(list[cycle]);
  }

  // Scrolls a comment on this page into view and opens it.
  function revealComment(c) {
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
    setTouchDrawing(mode === "draw");
    render();
  }

  // While drawing, touches draw instead of scrolling the page.
  let touchSaved = null;
  function setTouchDrawing(on) {
    const st = document.documentElement.style;
    if (on && touchSaved === null) {
      touchSaved = [st.getPropertyValue("touch-action"), st.getPropertyPriority("touch-action")];
      st.setProperty("touch-action", "none", "important");
    } else if (!on && touchSaved !== null) {
      restoreStyle(st, "touch-action", touchSaved);
      touchSaved = null;
    }
  }

  function disarm() {
    closeComposer();
    if (!armed) return;
    armed = null;
    hoverEl = null;
    areaDrag = null;
    endStroke();
    outline.hidden = true;
    if (!draft) draftBox.hidden = true;
    setCrosshair(false);
    setTouchDrawing(false);
    render();
  }

  // ---- previewing suggested edits on the page (the composer's, or a comment's)

  // The element's only text, if it has exactly one run of it (icons beside it are fine) and isn't a
  // form field: suggested text replaces that run in place, so the page's own framework keeps its node.
  function soleTextNode(el) {
    if (!el || el.nodeType !== 1 || fieldKind(el) || el.closest(EDITABLE_SEL)) return null;
    let node = null;
    for (const n of el.childNodes) {
      if (n.nodeType === 3) {
        if (!n.nodeValue.trim()) continue;
        if (node) return null;
        node = n;
      } else if (n.nodeType === 1 && (n.textContent || "").trim()) return null;
    }
    return node && node.nodeValue.trim().length <= 500 ? node : null;
  }

  let preview = null; // { el, node, original, applied, styles: Map(prop -> [value, priority]) }
  function previewOn(el, node) {
    if (preview && preview.el === el) return preview;
    previewOff();
    preview = { el, node, original: node ? node.nodeValue : null, applied: null, styles: new Map() };
    return preview;
  }
  // Shows `text` instead of the element's text, keeping the whitespace around it.
  function previewText(text) {
    if (!preview || !preview.node) return;
    const m = /^(\s*)[\s\S]*?(\s*)$/.exec(preview.original);
    const value = text ? m[1] + text + m[2] : preview.original;
    preview.node.nodeValue = value;
    preview.applied = value;
  }
  function previewStyle(prop, value) {
    if (!preview) return;
    const st = preview.el.style;
    if (!preview.styles.has(prop)) preview.styles.set(prop, [st.getPropertyValue(prop), st.getPropertyPriority(prop)]);
    if (value) st.setProperty(prop, value, "important");
    else restoreStyle(st, prop, preview.styles.get(prop));
  }
  function restoreStyle(st, prop, [value, priority]) {
    if (value) st.setProperty(prop, value, priority);
    else st.removeProperty(prop);
  }
  // Puts the page back (text the page itself has changed since is left alone).
  function previewOff() {
    if (!preview) return;
    const p = preview;
    preview = null;
    if (p.node && p.applied !== null && p.node.nodeValue === p.applied) p.node.nodeValue = p.original;
    for (const [prop, saved] of p.styles) restoreStyle(p.el.style, prop, saved);
  }

  // ---- the composer

  // Opens the composer for a click on `target` (or an area dragged out on the page, `area`);
  // clicking elsewhere moves it, keeping the text.
  function openComposer(target, e, area) {
    if (posting) return; // the draft stays where it was posted from
    previewOff();
    draft = area
      ? { pos: area.pos, label: "Area", el: target, area: area.size, shotPos: area.center }
      : { pos: positionAt(target, e.clientX, e.clientY, e.pageX, e.pageY), label: labelFor(target), el: target };
    draft.node = area ? null : soleTextNode(target);
    draft.oldText = draft.node ? oneLine(draft.node.nodeValue, 500) : "";
    draft.oldStyles = {};
    try {
      const cs = getComputedStyle(target);
      for (const prop of STYLE_FIELDS) draft.oldStyles[prop] = cssValue(cs.getPropertyValue(prop));
      // Browsers that don't give shorthands back give the sides.
      if (!draft.oldStyles.padding) draft.oldStyles.padding = cssValue(["top", "right", "bottom", "left"].map((k) => cs.getPropertyValue("padding-" + k)).join(" "));
      if (!draft.oldStyles["border-radius"]) draft.oldStyles["border-radius"] = cssValue(cs.getPropertyValue("border-top-left-radius"));
      for (const prop of ["color", "background-color"]) draft.oldStyles[prop] = rgbText(draft.oldStyles[prop]) || draft.oldStyles[prop];
      draft.font = cs.fontFamily;
    } catch { /* detached */ }
    resetStyler();
    setEditing(null);
    textEditBtn.hidden = !draft.node;
    styleEditBtn.hidden = !!area || !!fieldKind(target);
    editBar.hidden = textEditBtn.hidden && styleEditBtn.hidden;
    composer.hidden = false;
    noteEl.hidden = true;
    updatePostBtn();
    watchDom();
    placeAll();
    try { textArea.focus({ preventScroll: true }); } catch { textArea.focus(); }
  }

  // Shows the text or style fields ("text", "style", or null for neither), filled with how it is now.
  function setEditing(which) {
    const was = draft && draft.editing;
    if (draft) draft.editing = which === was ? null : which;
    const now = draft ? draft.editing : null;
    textEdit.hidden = now !== "text";
    styleEdit.hidden = now !== "style";
    textEditBtn.setAttribute("aria-pressed", String(now === "text"));
    styleEditBtn.setAttribute("aria-pressed", String(now === "style"));
    composer.classList.toggle("styling", now === "style");
    if (!draft) return;
    if (now === "text" && was !== "text") {
      textEdit.value = draft.oldText;
      try { textEdit.focus({ preventScroll: true }); textEdit.select(); } catch { textEdit.focus(); }
    }
    if (now === "style" && was !== "style") syncStyler();
    draft.spot = null; // placed afresh for what it now shows
    placeAll();
  }

  // What the composer suggests changing, from the fields that differ from how the element is.
  function draftEdits() {
    if (!draft) return [];
    const edits = [];
    const nw = oneLine(textEdit.value, 500);
    if (draft.node && nw && nw !== draft.oldText && draft.textTouched) edits.push({ kind: "text", old: draft.oldText, new: nw });
    for (const prop of STYLE_FIELDS) {
      const v = styleValues.get(prop);
      if (v) edits.push({ kind: "style", property: prop, old: draft.oldStyles[prop] || "", new: v });
    }
    return edits;
  }

  function updatePostBtn() {
    postBtn.disabled = !!posting || !(cleanText(textArea.value) || draftEdits().length);
  }

  function closeComposer() {
    if (!draft) return;
    previewOff();
    draft = null;
    setPosting(0); // cancels a post waiting for its screenshot
    setEditing(null);
    composer.hidden = draftDot.hidden = noteEl.hidden = draftBox.hidden = true;
    outline.hidden = true;
    textArea.value = "";
    if (uiRoot.activeElement === textArea) textArea.blur();
    clearTimeout(flashTimers.get(noteEl));
    watchDom();
  }

  textEditBtn.addEventListener("click", () => setEditing("text"));
  styleEditBtn.addEventListener("click", () => setEditing("style"));
  textEdit.addEventListener("input", (e) => {
    e.stopPropagation();
    if (!draft || !draft.node) return;
    draft.textTouched = true;
    previewOn(draft.el, draft.node);
    previewText(oneLine(textEdit.value, 500));
    updatePostBtn();
  });
  for (const field of [textEdit]) {
    field.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.isComposing) return;
      if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); postComment(); }
      else if (e.key === "Escape") { e.preventDefault(); disarm(); }
    });
    for (const t of ["keyup", "keypress"]) field.addEventListener(t, stop);
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
    textArea.readOnly = !!token;
    if (draft) updatePostBtn();
    else postBtn.disabled = !!token;
    composer.setAttribute("aria-busy", String(!!token));
  }

  // Posts the draft: a screenshot is attempted first (at most SHOT_TIMEOUT), then the comment
  // goes with whatever we have. Cancelling the composer meanwhile drops it.
  async function postComment() {
    if (!draft || posting) return;
    const edits = draftEdits();
    const text = cleanText(textArea.value).slice(0, MAX_TEXT) || (edits.length ? "Suggested edit" : "");
    if (!text) return;
    if (!joined) return note(offlineText(), 2000);
    const wait = COMMENT_INTERVAL - (Date.now() - lastCommentAt);
    if (wait > 0) return note("Wait a moment", wait);
    const token = ++postSeq;
    const { pos, label, el, area, shotPos } = draft;
    previewOff(); // the picture and the styles are the page as it is; the edits say what to change
    const context = elementContext(el);
    noteEl.hidden = true;
    setPosting(token);
    let shot = null;
    try { shot = await screenshot(el, area ? pos : shotPos || pos, area); } catch { shot = null; }
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
    if (edits.length) msg.edits = edits;
    if (area) msg.area = area;
    if (context) msg.context = context;
    const errs = errorsOn === true ? recentErrors() : [];
    if (errs.length) msg.errors = errs;
    // Very long non-ASCII text can exceed the frame limit; shed optional fields first
    // (oldest attached errors one by one, then the rest).
    while (msg.errors && frameBytes(msg) > MAX_FRAME) {
      msg.errors.shift();
      if (!msg.errors.length) delete msg.errors;
    }
    for (const k of ["context", "title", "label", "env", "anchor"]) {
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
    updatePostBtn();
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
  const SHOT_FOCUS_MIN_W = 240; // a small element still shows some of the page around it
  const SHOT_FOCUS_MIN_H = 120;
  const SHOT_PAD_MIN = 16; // margin around the element: a fifth of its size, within these
  const SHOT_PAD_MAX = 48;
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

  // The element a screenshot is drawn from: the target or its nearest ancestor of at least 320x200
  // that holds all of `focus` (the part the picture shows).
  function shotRoot(target, focus) {
    for (let e = target; e && e.nodeType === 1; e = e.parentElement || (e.parentNode && e.parentNode.host) || null) {
      if (e === host) return null;
      if (e === document.body || e === document.documentElement) break;
      const r = e.getBoundingClientRect();
      const holds = r.left <= focus.left + 1 && r.top <= focus.top + 1 && r.right >= focus.right - 1 && r.bottom >= focus.bottom - 1;
      if (r.width >= SHOT_MIN_W && r.height >= SHOT_MIN_H && holds) return e;
    }
    return document.body;
  }

  // The part of the page a screenshot shows, in viewport coordinates: the commented element (or the
  // area dragged out) with a margin of the page around it, so the picture is about what the comment
  // is about. Before and after pictures of a comment frame the same way.
  function shotFocus(target, pin, area) {
    let f;
    if (area) {
      const v = toViewport(pin);
      f = { left: v.x, top: v.y, width: area.width, height: area.height };
    } else {
      const r = target.getBoundingClientRect();
      f = { left: r.left, top: r.top, width: r.width, height: r.height };
    }
    const pad = Math.min(SHOT_PAD_MAX, Math.max(SHOT_PAD_MIN, Math.max(f.width, f.height) * 0.2));
    const w = Math.max(SHOT_FOCUS_MIN_W, f.width + 2 * pad);
    const hgt = Math.max(SHOT_FOCUS_MIN_H, f.height + 2 * pad);
    const cx = f.left + f.width / 2;
    const cy = f.top + f.height / 2;
    return { left: cx - w / 2, top: cy - hgt / 2, right: cx + w / 2, bottom: cy + hgt / 2, width: w, height: hgt };
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

  async function renderShot(target, pin, deadline, area) {
    const focus = shotFocus(target, pin, area);
    const el = shotRoot(target, focus);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    const cw = Math.min(r.width, focus.width, SHOT_MAX_W);
    const ch = Math.min(r.height, focus.height, SHOT_MAX_H);
    if (cw < 1 || ch < 1) return null;
    // Too big for one picture: around the pin instead of the middle.
    const v = focus.width > SHOT_MAX_W || focus.height > SHOT_MAX_H ? toViewport(pin) : null;
    const cx = focus.width > SHOT_MAX_W && v ? v.x : focus.left + focus.width / 2;
    const cy = focus.height > SHOT_MAX_H && v ? v.y : focus.top + focus.height / 2;
    const ox = Math.max(0, Math.min(r.width - cw, cx - r.left - cw / 2));
    const oy = Math.max(0, Math.min(r.height - ch, cy - r.top - ch / 2));
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
  async function screenshot(target, pin, area) {
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
      const blob = await renderShot(target, pin, deadline, area);
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

  // ---------------------------------------------------------------- page refresh
  //
  // When a fix lands (the hub says "refresh": a comment was resolved, or the project's files changed),
  // the page under the overlay catches up without a reload. Its HTML is fetched again and the live
  // page is changed in place, node by node, so what didn't change stays as it is: focus, what's typed
  // into its fields, scroll, and the overlay (outside <body>) with any comment being written. Changed
  // stylesheets are swapped once the new one has loaded; scripts never run again. Pages with their own
  // hot reload (Vite, webpack, Next.js, LiveReload) are left to it. A page its scripts have built
  // (the live page no longer matches its HTML) can't be changed in place: it's reloaded once nobody is
  // in the middle of something, and the open comment and any picture of a fix still to take come along.

  const REFRESH_DEBOUNCE = 300;
  const REFRESH_RETRY = 1500; // someone is busy: try again this much later
  const TYPING_QUIET = 2500; // a field on the page was typed in this recently: wait
  const SETTLE_QUIET = 500; // no changes to the page for this long: it has settled
  const SETTLE_MAX = 4000;
  let baseline = null; // { html, css: Map(href -> text) } as last loaded or applied, once fetched
  let baselineLoad = null;
  let refreshTimer = 0;
  let refreshing = null; // the refresh going on, a promise
  let lastPageInput = 0;
  document.addEventListener("input", (e) => { if (!isOurs(e.target)) lastPageInput = Date.now(); }, true);

  // The page has its own hot reload: it updates itself, and our refresh would only get in the way.
  function hotReloads() {
    return !!document.querySelector('script[src*="/@vite/client"], script[src*="webpack-dev-server"], script[src*="hot-update"], ' +
      'script[src*="/_next/static/chunks/webpack"], script[src*="livereload"], script[src*="/@react-refresh"]') ||
      typeof window.__webpack_hmr === "object" || !!window.__NEXT_HMR_CB || !!window.LiveReload;
  }

  // The page's HTML as the server sends it now, without OpenTraffic's own tags, or null.
  async function fetchPage() {
    if (!pageFetch) return null;
    const url = location.href.split("#")[0];
    try {
      const res = await pageFetch.call(window, url, { credentials: "same-origin", cache: "no-store", headers: { Accept: "text/html" } });
      if (!res || !res.ok || !/text\/html/i.test(res.headers.get("content-type") || "")) return null;
      const text = await res.text();
      return text.length > 5e6 ? null : text;
    } catch {
      return null;
    }
  }

  function parsePage(html) {
    const doc = new DOMParser().parseFromString(html, "text/html");
    for (const n of doc.querySelectorAll("[data-opentraffic]")) n.remove();
    return doc;
  }

  const sameOriginSheets = (doc) => [...doc.querySelectorAll('link[rel~="stylesheet"][href]')]
    .filter((l) => { try { return new URL(l.getAttribute("href"), location.href).origin === location.origin; } catch { return false; } });

  // A stylesheet's address without the mark a swap added to it (which keeps the browser from using the old copy).
  function sheetKey(link) {
    const u = new URL(link.getAttribute("href"), location.href);
    u.searchParams.delete("__opentraffic");
    return u.href;
  }

  async function fetchCss(href) {
    try {
      const res = await pageFetch.call(window, new URL(href, location.href).href, { credentials: "same-origin", cache: "no-store" });
      return res && res.ok ? await res.text() : null;
    } catch {
      return null;
    }
  }

  // What a page's body is made of, ignoring scripts, whitespace, and our own tags: for telling whether
  // scripts have changed the live page since it loaded.
  function bodyShape(body) {
    const copy = body.cloneNode(true);
    for (const n of copy.querySelectorAll("script, noscript, template, [data-opentraffic]")) n.remove();
    return copy.innerHTML.replace(/\s+/g, " ").trim();
  }

  // Remembers the page as loaded, the first time it's needed (one extra request, when idle).
  function loadBaseline() {
    if (!baselineLoad) {
      baselineLoad = (async () => {
        const html = await fetchPage();
        if (html === null) return null;
        const css = new Map();
        for (const l of sameOriginSheets(document)) {
          const text = await fetchCss(sheetKey(l));
          if (text !== null) css.set(sheetKey(l), text);
        }
        baseline = { html, css };
        return baseline;
      })();
    }
    return baselineLoad;
  }

  // Someone is in the middle of something a refresh shouldn't touch.
  function busy(needsReload) {
    const a = document.activeElement;
    const pageField = a && !isOurs(a) && (a.isContentEditable || /^(input|textarea|select)$/i.test(a.tagName));
    if (pageField && Date.now() - lastPageInput < TYPING_QUIET) return true;
    if (!needsReload) return false;
    // A reload would lose these.
    return !!(draft || posting || pageField || (replyArea.value && replyArea.value.trim()) || !zoom.hidden || stage);
  }

  function scheduleRefresh(delay = REFRESH_DEBOUNCE) {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => { refreshPage().catch(() => {}); }, delay);
  }

  // Brings the page up to date; resolves once it is (or nothing changed), true if it changed.
  function refreshPage() {
    if (!refreshing) refreshing = doRefresh().finally(() => { refreshing = null; });
    return refreshing;
  }

  async function doRefresh() {
    if (hotReloads()) return settle();
    const base = await loadBaseline();
    if (!base) return false;
    const html = await fetchPage();
    if (html === null) return false;
    const css = new Map();
    const next = parsePage(html);
    let cssChanged = false;
    for (const l of sameOriginSheets(next)) {
      const key = sheetKey(l);
      const text = await fetchCss(key);
      if (text === null) continue;
      css.set(key, text);
      if (base.css.get(key) !== text) cssChanged = true;
    }
    // Whether the page differs from what the server sends now (the live page, so a stale baseline
    // can't hide a change), and whether its scripts have changed it since it loaded.
    const liveShape = bodyShape(document.body);
    const htmlChanged = liveShape !== bodyShape(next.body) || next.title !== document.title ||
      [...next.head.querySelectorAll("style")].map((st) => st.textContent).join("\n") !==
        [...document.head.querySelectorAll("style:not([data-opentraffic])")].map((st) => st.textContent).join("\n");
    if (!htmlChanged && !cssChanged) return false;
    const built = htmlChanged && liveShape !== bodyShape(parsePage(base.html).body);
    // A page its scripts built differs from its HTML anyway: only a change to the HTML itself counts.
    if (built && html === base.html && !cssChanged) return false;
    if (busy(built)) {
      scheduleRefresh(REFRESH_RETRY);
      return false;
    }
    if (built) {
      reloadKeepingContext();
      return true;
    }
    if (preview) { previewOff(); renderBubble(); }
    const x = window.scrollX, y = window.scrollY;
    if (htmlChanged) {
      if (next.title !== document.title) document.title = next.title;
      morphHead(next.head);
      morphChildren(document.body, next.body);
      syncAttributes(document.body, next.body);
    }
    if (cssChanged) await swapSheets(css, base.css);
    window.scrollTo(x, y);
    baseline = { html, css };
    baselineLoad = Promise.resolve(baseline);
    // The comment being written stays on its element, even if that element was replaced.
    if (draft && draft.el && !draft.el.isConnected && draft.pos && draft.pos.anchor) {
      try { draft.el = document.querySelector(draft.pos.anchor) || draft.el; } catch { /* invalid selector */ }
    }
    renderPins();
    schedulePlace();
    await settle();
    return true;
  }

  // Waits until the page stops changing (hot reload done, images and layout settled), at most SETTLE_MAX.
  function settle() {
    return new Promise((resolve) => {
      let quiet = 0;
      const done = () => { clearTimeout(quiet); clearTimeout(cap); observer.disconnect(); resolve(true); };
      const observer = new MutationObserver((records) => {
        if (records.every((r) => isOurs(r.target))) return;
        clearTimeout(quiet);
        quiet = setTimeout(done, SETTLE_QUIET);
      });
      observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
      quiet = setTimeout(done, SETTLE_QUIET);
      const cap = setTimeout(done, SETTLE_MAX);
    });
  }

  // A full reload, for pages that can't be changed in place: the open comment, any picture of a fix
  // still to take, and the scroll position come back afterwards.
  function reloadKeepingContext() {
    if (inFrame) return; // the device view follows its stage
    if (bubbleId) session.reveal = bubbleId;
    if (capturing.size) session.captureAfter = [...capturing][0];
    session.scroll = [window.scrollX, window.scrollY];
    saveSession();
    location.reload();
  }

  // ---- changing the live page into the new one

  const sameNode = (a, b) => a.nodeType === b.nodeType &&
    (a.nodeType !== 1 || (a.tagName === b.tagName && (a.getAttribute("id") || "") === (b.getAttribute("id") || "")));

  function syncAttributes(live, next) {
    for (const { name, value } of [...next.attributes]) {
      if (live.getAttribute(name) !== value) live.setAttribute(name, value);
    }
    for (const { name } of [...live.attributes]) {
      if (!next.hasAttribute(name) && !name.startsWith("data-opentraffic")) live.removeAttribute(name);
    }
  }

  function morphNode(live, next) {
    if (live.nodeType === 3 || live.nodeType === 8) {
      if (live.nodeValue !== next.nodeValue) live.nodeValue = next.nodeValue;
      return;
    }
    if (live.nodeType !== 1) return;
    if (live.tagName === "SCRIPT") return; // never touched: running scripts again could do anything
    syncAttributes(live, next);
    // A field someone has typed into keeps what they typed.
    if (live.tagName === "TEXTAREA") return;
    morphChildren(live, next);
  }

  function morphChildren(live, next) {
    const theirs = [...next.childNodes];
    let i = 0;
    for (const n of theirs) {
      if (n.nodeType === 1 && n.tagName === "SCRIPT") continue; // a script the page didn't have before isn't run
      let l = live.childNodes[i];
      while (l && isOurs(l)) l = live.childNodes[++i]; // our own nodes stay where they are
      if (l && l.nodeType === 1 && l.tagName === "SCRIPT") {
        // The live page's scripts stay too; line up after them.
        while (l && l.nodeType === 1 && l.tagName === "SCRIPT") l = live.childNodes[++i];
      }
      if (l && sameNode(l, n)) morphNode(l, n);
      else if (l) live.replaceChild(document.importNode(n, true), l);
      else live.appendChild(document.importNode(n, true));
      i++;
    }
    // What's left over is gone from the page, but scripts and our own nodes stay.
    for (const l of [...live.childNodes].slice(i)) {
      if (isOurs(l) || (l.nodeType === 1 && l.tagName === "SCRIPT")) continue;
      l.remove();
    }
  }

  // <style> text and <meta> in the head follow the new page; stylesheets are handled by swapSheets.
  function morphHead(next) {
    const styles = [...document.head.querySelectorAll("style:not([data-opentraffic])")];
    const theirs = [...next.querySelectorAll("style")];
    theirs.forEach((st, k) => {
      if (styles[k]) { if (styles[k].textContent !== st.textContent) styles[k].textContent = st.textContent; }
      else document.head.appendChild(document.importNode(st, true));
    });
    for (const st of styles.slice(theirs.length)) st.remove();
  }

  // Changed stylesheets: the new one goes in next to the old, which leaves once it has loaded (no flash).
  async function swapSheets(css, old) {
    const loads = [];
    for (const l of sameOriginSheets(document)) {
      const key = sheetKey(l);
      if (!css.has(key) || css.get(key) === old.get(key)) continue;
      const fresh = l.cloneNode();
      const u = new URL(key);
      u.searchParams.set("__opentraffic", String(Date.now()));
      fresh.href = u.href;
      loads.push(new Promise((resolve) => {
        const done = () => { l.remove(); resolve(); };
        fresh.addEventListener("load", done, { once: true });
        fresh.addEventListener("error", () => { fresh.remove(); resolve(); }, { once: true });
        setTimeout(resolve, 3000);
      }));
      l.after(fresh);
    }
    await Promise.all(loads);
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
    el.append(h("span", "ring"), h("span", "ring"));
    // Their cursor, if it's on screen, already has their name next to it.
    const c = cursors.get(m.id);
    if (!c || c.el.hidden) {
      const tag = h("span", "tag", name);
      css(tag, { background: color, color: textOn(color) });
      el.append(tag);
    }
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
  let pressedOurs = false;
  function onPageEvent(e) {
    if (e.type === "pointerdown" || (e.type === "click" && isOurs(e.target))) pressedOurs = e.type === "pointerdown" && isOurs(e.target);
    if (isOurs(e.target)) return; // the overlay's own UI
    if (e.type === "pointerdown" && bubbleId) closeBubble(); // outside click
    let ours = !!armed;
    if (armed === "draw") {
      if (e.type === "pointerdown" && e.button === 0) startStroke(e);
      else if (e.type === "pointerup" || e.type === "pointercancel") endStroke();
    } else if (armed === "comment" && !posting) {
      if (e.type === "pointerdown" && e.button === 0) areaDrag = { x: e.clientX, y: e.clientY, moved: false };
      else if (e.type === "pointerup" && areaDrag) {
        const d = areaDrag;
        areaDrag = null;
        if (d.moved) { finishArea(d, e); skipClick = true; }
      }
    }
    if (e.type === "click" && (skipClick || pressedOurs)) {
      // The click that ends dragging out an area, or one that began on the overlay (a slider let go of over the page).
      skipClick = pressedOurs = false;
    } else if (e.type === "click") {
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
  for (const t of ["pointerdown", "mousedown", "pointerup", "pointercancel", "mouseup", "click", "dblclick", "auxclick"]) {
    window.addEventListener(t, onPageEvent, true);
  }

  // ---------------------------------------------------------------- areas

  let areaDrag = null; // { x, y, moved } from pointerdown in comment mode
  let skipClick = false;

  window.addEventListener("pointermove", (e) => {
    if (armed === "draw" && drawing) return addStrokePoint(e);
    if (!areaDrag || armed !== "comment" || !(e.buttons & 1)) return;
    const w = Math.abs(e.clientX - areaDrag.x);
    const ht = Math.abs(e.clientY - areaDrag.y);
    if (!areaDrag.moved && Math.max(w, ht) < 8) return;
    if (!areaDrag.moved && draft) closeComposer();
    areaDrag.moved = true;
    hoverEl = null;
    outline.hidden = true;
    css(draftBox, { width: Math.round(w) + "px", height: Math.round(ht) + "px" });
    translate(draftBox, Math.min(e.clientX, areaDrag.x), Math.min(e.clientY, areaDrag.y));
    draftBox.hidden = false;
  }, { capture: true, passive: true });

  // The smallest element containing the dragged-out box: the comment is pinned to it, so the box
  // keeps its place when the layout moves.
  function finishArea(d, e) {
    const left = Math.max(0, Math.min(d.x, e.clientX));
    const top = Math.max(0, Math.min(d.y, e.clientY));
    const right = Math.min(window.innerWidth - 1, Math.max(d.x, e.clientX));
    const bottom = Math.min(window.innerHeight - 1, Math.max(d.y, e.clientY));
    if (right - left < 8 || bottom - top < 8) { draftBox.hidden = true; return; }
    const corners = [[left, top], [right, top], [left, bottom], [right, bottom]]
      .map(([x, y]) => document.elementFromPoint(x, y)).filter((el) => el && el !== host);
    let container = corners[0] || document.body;
    while (container && container !== document.body && !corners.every((el) => container.contains(el))) container = container.parentElement;
    container = container || document.body;
    const cx = (left + right) / 2;
    const cy = (top + bottom) / 2;
    openComposer(container, null, {
      pos: positionAt(container, left, top, left + window.scrollX, top + window.scrollY),
      center: positionAt(container, cx, cy, cx + window.scrollX, cy + window.scrollY),
      size: { width: Math.round(right - left), height: Math.round(bottom - top) },
    });
  }

  // ---------------------------------------------------------------- drawing
  //
  // Strokes go to everyone on the same page and fade a few seconds after their last point.
  // Nothing is kept: not by the hub, not here.

  const INK_FADE = 2500;
  const MAX_STROKES = 80;
  const MAX_STROKE_POINTS = 2000;
  const strokes = new Map(); // key -> { el, points: [[x, y]], timer }
  let drawing = null; // { stroke, pending: [[x, y]], timer } while our pointer is down
  let strokeSeq = 0;

  const pagePoint = (e) => [round4(clamp01(e.pageX / Math.max(1, document.documentElement.scrollWidth))), Math.max(0, Math.round(e.pageY))];

  function startStroke(e) {
    if (!joined || !me) return;
    endStroke();
    drawing = { stroke: ++strokeSeq % 1000000000, pending: [], timer: 0 };
    addStrokePoint(e);
  }

  function addStrokePoint(e) {
    if (!drawing) return;
    const pt = pagePoint(e);
    drawInk("me:" + drawing.stroke, [pt], me ? me.color : "#0a84ff");
    drawing.pending.push(pt);
    if (drawing.pending.length >= 64) flushStroke();
    else if (!drawing.timer) drawing.timer = setTimeout(flushStroke, 50);
  }

  function flushStroke() {
    if (!drawing) return;
    clearTimeout(drawing.timer);
    drawing.timer = 0;
    while (drawing.pending.length) send({ type: "ink", stroke: drawing.stroke, points: drawing.pending.splice(0, 64) });
  }

  function endStroke() {
    if (!drawing) return;
    flushStroke();
    drawing = null;
  }

  function drawInk(key, points, color) {
    let st = strokes.get(key);
    if (!st) {
      if (strokes.size >= MAX_STROKES) dropStroke(strokes.keys().next().value);
      const el = document.createElementNS(SVG_NS, "path");
      el.setAttribute("stroke", color);
      inkSvg.append(el);
      st = { el, points: [], timer: 0 };
      strokes.set(key, st);
      mount();
    }
    for (const pt of points) if (st.points.length < MAX_STROKE_POINTS) st.points.push(pt);
    shapeStroke(st);
    clearTimeout(st.timer);
    st.timer = setTimeout(() => {
      st.el.classList.add("fading");
      st.timer = setTimeout(() => dropStroke(key), 650);
    }, INK_FADE);
  }

  // A smooth line through the points, like a pen: curves through the midpoints, each point a control.
  function shapeStroke(st) {
    const w = document.documentElement.scrollWidth;
    const sx = window.scrollX;
    const sy = window.scrollY;
    const xy = st.points.map((p) => [p[0] * w - sx, p[1] - sy]);
    const f = (n) => Math.round(n * 10) / 10;
    if (xy.length < 3) {
      st.el.setAttribute("d", xy.map((p, i) => (i ? "L" : "M") + f(p[0]) + " " + f(p[1])).join(" ") + (xy.length === 1 ? " l0.1 0" : ""));
      return;
    }
    let d = "M" + f(xy[0][0]) + " " + f(xy[0][1]);
    for (let i = 1; i < xy.length - 1; i++) {
      const mx = (xy[i][0] + xy[i + 1][0]) / 2;
      const my = (xy[i][1] + xy[i + 1][1]) / 2;
      d += " Q" + f(xy[i][0]) + " " + f(xy[i][1]) + " " + f(mx) + " " + f(my);
    }
    const last = xy[xy.length - 1];
    st.el.setAttribute("d", d + " L" + f(last[0]) + " " + f(last[1]));
  }

  function dropStroke(key) {
    const st = strokes.get(key);
    if (!st) return;
    clearTimeout(st.timer);
    st.el.remove();
    strokes.delete(key);
  }

  function placeInk() {
    for (const st of strokes.values()) shapeStroke(st);
  }

  // Someone else's stroke; the hub sends it to everyone on our page.
  function onInk(m) {
    if (typeof m.id !== "string" || !m.id || m.id.length > 64 || !Array.isArray(m.points) || m.points.length > 64) return;
    const stroke = Number.isInteger(m.stroke) && m.stroke >= 0 ? m.stroke : 0;
    const points = [];
    for (const p of m.points) {
      const x = Array.isArray(p) ? finite(p[0]) : null;
      const y = Array.isArray(p) ? finite(p[1]) : null;
      if (x === null || y === null) return;
      points.push([clamp01(x), Math.min(Math.max(0, y), 1e7)]);
    }
    const peer = peers.get(m.id);
    const color = typeof m.color === "string" && COLOR_RE.test(m.color) ? m.color : peer ? peer.color : GREY;
    // Points come in batches (one every INK_BATCH ms); they're drawn out over that time, as they were drawn,
    // rather than a batch at a time.
    const key = m.id + ":" + stroke;
    const q = inkQueues.get(key) || { id: m.id, color, points: [] };
    q.points.push(...points);
    // What's waiting, this batch and any left over, is drawn out evenly until the next batch is due.
    q.start = performance.now();
    q.total = q.points.length;
    q.done = 0;
    q.step = INK_BATCH / q.total;
    inkQueues.set(key, q);
    if (!inkFrame) inkFrame = requestAnimationFrame(revealInk);
  }

  const INK_BATCH = 50; // ms between a drawer's batches (flushStroke's timer)
  const inkQueues = new Map(); // stroke key -> points still to draw
  let inkFrame = 0;
  function revealInk() {
    inkFrame = 0;
    const now = performance.now();
    for (const [key, q] of inkQueues) {
      const target = Math.min(q.total, Math.floor((now - q.start) / q.step) + 1);
      if (target <= q.done) continue;
      const pts = q.points.splice(0, target - q.done);
      q.done = target;
      drawInk(key, pts, q.color);
      // Their pointer is at the tip of the line they're drawing, and moves with it.
      const peer = peers.get(q.id);
      if (peer && !peer.isAgent) {
        const c = cursorOf(q.id, peer);
        const [x, y] = pts[pts.length - 1];
        Object.assign(c, { anchor: null, rx: 0, ry: 0, x, y });
        c.at = c.inkAt = Date.now();
        c.el.classList.add("inking");
        clearTimeout(c.inkTimer);
        c.inkTimer = setTimeout(() => c.el.classList.remove("inking"), 300);
        mount();
        place(q.id, c);
      }
      if (!q.points.length) inkQueues.delete(key);
    }
    if (inkQueues.size) inkFrame = requestAnimationFrame(revealInk);
  }

  // ---------------------------------------------------------------- devices

  const deviceName = (d) => d.browser + " on " + d.os;
  function deviceKind(os, w, ht) {
    if (!/^(?:iOS|iPadOS|Android)$/.test(os)) return "desktop";
    return Math.min(w, ht) < 600 ? "phone" : "tablet";
  }
  const isHostLeading = () => !!(me && me.isHost && leadOn);
  // What the host shows followers: the phone they're looking at, their own window (when they ask), or nothing.
  function currentView() {
    if (stage && stage.mode === "self") return { kind: "phone", w: stage.w, h: stage.ht };
    if (session.match) return { kind: "window", w: Math.round(window.innerWidth), h: Math.round(window.innerHeight) };
    return null;
  }
  function cleanView(v) {
    if (!v || typeof v !== "object" || (v.kind !== "phone" && v.kind !== "window")) return null;
    const ok = (n) => Number.isInteger(n) && n >= 200 && n <= 8000;
    return ok(v.w) && ok(v.h) ? { kind: v.kind, w: v.w, h: v.h } : null;
  }

  // The overlay in the device view, once it has started there.
  function stageFrame() {
    try { return vIframe.__opentrafficFrame || null; } catch { return null; }
  }
  // The space for the device: the stage area inside its padding (between the bar and the pill).
  function stageRoom() {
    const r = sArea.getBoundingClientRect();
    const cs = getComputedStyle(sArea);
    const top = r.top + parseFloat(cs.paddingTop);
    const bottom = r.bottom - parseFloat(cs.paddingBottom);
    const left = r.left + parseFloat(cs.paddingLeft);
    const right = r.right - parseFloat(cs.paddingRight);
    return { left, top, right, bottom, width: right - left, height: bottom - top };
  }
  const rectOf = (el) => {
    const r = el.getBoundingClientRect();
    return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
  };
  // What the overlay in the device view asks of us.
  vIframe.__opentrafficStage = {
    scale: () => (stage ? stage.scale : 1),
    screen: () => rectOf(vFrame),
    device: () => rectOf(sDevice),
    area: () => stageRoom(), // between the bar and the pill
    armed: (mode) => {
      if (!stage) return;
      stage.armed = mode || null;
      render();
    },
    followsLead: () => !!(stage && stage.mode === "lead" && stage.follow),
    leadView: () => (stage && stage.mode === "self" && isHostLeading() ? currentView() : null),
    following: (on) => {
      if (!stage || stage.mode !== "lead" || stage.follow === on) return;
      stage.follow = following = on;
      session.follow = on ? 1 : 0;
      saveSession();
      render();
      layoutStage();
    },
  };

  function openStage(mode, p) {
    closeViewer();
    disarm();
    closeBubble();
    hideCursor(); // our pointer is in the device view now
    stage = { mode, fit: true, follow: mode !== "self", path: null, pos: null, scale: 1, armed: null, cursor: null };
    if (mode === "person") {
      stage.id = p.id;
      stage.cursor = makeCursor(p);
      stage.cursor.el.hidden = true;
      vFrame.append(stage.cursor.el);
      send({ type: "watch", id: p.id }); // their pointer reaches us on any page
    }
    listOpen = viewOpen = false;
    viewer.hidden = false;
    if (mode === "person") updateStage(p);
    else if (mode === "self") {
      stage.w = PHONE.w;
      stage.ht = PHONE.h;
      stage.kind = "phone";
      showPath(lastPath);
      layoutStage();
    } else updateLeadStage();
    render();
    try { vClose.focus({ preventScroll: true }); } catch { /* old browsers */ }
  }
  function openViewer(p) {
    if (p.device && safePath(p.path || "/")) openStage("person", p);
  }

  // Someone's window, page or name changed (or we opened the stage on them).
  function updateStage(p) {
    if (stage && stage.mode === "person" && stage.left && Date.now() - stage.left < 15000 && p.name === stage.name &&
        p.device && deviceName(p.device) === stage.device) {
      stage.id = p.id; // back after loading a page
      stage.left = 0;
      send({ type: "watch", id: p.id });
    }
    if (!stage || stage.mode !== "person" || p.id !== stage.id) return;
    const [w, ht] = p.device ? p.device.viewport.split("x").map(Number) : [stage.w, stage.ht];
    if (!w || !ht) return;
    stage.name = p.name;
    stage.color = p.color;
    if (p.device) stage.device = deviceName(p.device);
    stage.w = w;
    stage.ht = ht;
    stage.kind = deviceKind(p.device ? p.device.os : "", w, ht);
    sGone.hidden = true;
    paintCursor(stage.cursor, p);
    if (stage.follow || !stage.path) showPath(p.path || "/");
    layoutStage();
  }

  // Following the host's phone or window: its size; the overlay in it follows their page and scrolling.
  function updateLeadStage() {
    const v = lastLead.view;
    if (!stage || stage.mode !== "lead" || !v) return;
    stage.w = v.w;
    stage.ht = v.h;
    stage.kind = v.kind === "phone" ? "phone" : "desktop";
    const leader = [...peers.values()].find((q) => q.isHost && !q.inView);
    stage.name = leader ? leader.name : "The host";
    stage.color = leader ? leader.color : GREY;
    if (!stage.path) showPath(lastLead.path || lastPath);
    layoutStage();
  }

  // The bar: who or what it is, its size, and only the controls that mode has.
  function dressStage() {
    const { mode, w, ht } = stage;
    const size = w + " × " + ht;
    if (mode === "self") {
      sName.replaceChildren(icon(14, ...PHONE_PATHS), document.createTextNode("Phone"));
      sMeta.textContent = size + (isHostLeading() ? " · your followers see it too" : "");
      viewer.setAttribute("aria-label", "Phone view, " + w + " by " + ht);
    } else {
      css(sDot, { background: stage.color || GREY });
      const what = mode === "lead" ? stage.name + "’s " + (stage.kind === "phone" ? "phone" : "window") : stage.name;
      sName.replaceChildren(sDot, document.createTextNode(what));
      sMeta.textContent = (mode === "person" && stage.device ? stage.device + " · " : "") + size;
      viewer.setAttribute("aria-label", what + ", " + w + " by " + ht);
    }
    sRotate.hidden = mode !== "self";
    vWindow.hidden = mode !== "person";
    sFollow.hidden = mode === "self";
    sFollow.querySelector(".label").textContent = mode === "person" ? "Follow " + stage.name : "Follow";
    sFollow.setAttribute("aria-checked", String(stage.follow));
    sFollow.title = mode === "lead"
      ? (stage.follow ? "Going where " + stage.name + " goes" : "Follow " + stage.name + " again")
      : stage.follow ? "Going where " + stage.name + " goes, and keeping their pointer in view" : "Follow " + stage.name + " to other pages";
  }

  function showPath(path) {
    const safe = safePath(path);
    if (!safe || safe === stage.path) return;
    stage.path = safe;
    stage.pos = null;
    if (stage.cursor) stage.cursor.el.hidden = true;
    vIframe.src = safe; // safePath(): same-origin path only
    sAddr.textContent = location.host + safe;
  }

  // Sizes the device: the whole window fits the stage (or is shown at its real size).
  function layoutStage() {
    if (!stage) return;
    dressStage();
    const { w, ht, kind } = stage;
    const bezel = kind === "phone" ? 9 : kind === "tablet" ? 13 : 0; // bezel and rim
    const chrome = kind === "desktop" ? 34 : 0;
    // The device goes below the bar (its height varies with what it shows) and above the pill.
    const padTop = Math.round(sBar.getBoundingClientRect().bottom - viewer.getBoundingClientRect().top + 12);
    css(sArea, { "padding-top": padTop + "px" });
    const room = stageRoom();
    const fitScale = Math.min(1, (room.width - 2 * bezel - 16) / w, (room.height - 2 * bezel - chrome - 16) / ht);
    const scale = stage.fit ? Math.max(0.1, fitScale) : 1;
    stage.scale = scale;
    sDevice.className = "device " + kind + (w > ht ? " land" : "");
    sChrome.hidden = kind !== "desktop";
    const radius = kind === "phone" ? Math.min(48, Math.min(w, ht) * 0.12) : kind === "tablet" ? 18 : 0;
    css(sDevice, { "--bz": bezel - 1.5 + "px", "--r": Math.round(radius * scale) + "px" });
    css(vFrame, { width: Math.round(w * scale) + "px", height: Math.round(ht * scale) + "px" });
    css(vIframe, { width: w + "px", height: ht + "px", transform: "scale(" + scale + ")" });
    sSeg.hidden = fitScale >= 1;
    sFit.setAttribute("aria-pressed", String(stage.fit));
    sActual.setAttribute("aria-pressed", String(!stage.fit));
    sFit.title = "Fit the window (" + Math.round(Math.max(0.1, fitScale) * 100) + "%)";
    placeStageCursor();
    const f = stageFrame();
    if (f) try { f.relayout(); } catch { /* reloading */ }
  }

  // Their pointer, where it is on the page in the frame (it has their width, so their layout). The overlay
  // in the frame draws it; this keeps it in view.
  function placeStageCursor() {
    if (!stage || !stage.cursor) return;
    const c = stage.cursor;
    const pos = stage.pos;
    let doc = null;
    let win = null;
    try { doc = vIframe.contentDocument; win = vIframe.contentWindow; } catch { /* navigated away from us */ }
    if (!pos || !doc || !win || !doc.documentElement) { c.el.hidden = true; return; }
    let x = pos.x * doc.documentElement.scrollWidth - win.scrollX;
    let y = pos.y - win.scrollY;
    if (pos.anchor) {
      try {
        const el = doc.querySelector(pos.anchor);
        if (el && el.getClientRects().length) {
          const r = el.getBoundingClientRect();
          x = r.left + pos.rx * r.width;
          y = r.top + pos.ry * r.height;
        }
      } catch { /* invalid selector */ }
    }
    if (stage.follow && (y < 0 || y > stage.ht)) {
      win.scrollTo({ top: Math.max(0, win.scrollY + y - stage.ht / 3), behavior: reducedMotion.matches ? "auto" : "smooth" });
    }
    c.el.hidden = !!stageFrame() || x < -20 || y < -20 || x > stage.w + 20 || y > stage.ht + 20;
    translate(c.el, x * stage.scale, y * stage.scale);
  }

  function stageCursor(id, pos) {
    if (!stage || stage.mode !== "person" || id !== stage.id) return;
    const peer = peers.get(id);
    stage.pos = pos && peer && safePath(peer.path) === stage.path ? pos : null;
    placeStageCursor();
  }

  // A full page load is a new connection: they leave and join again with a new id.
  function stageLeft(id) {
    if (!stage || stage.mode !== "person" || id !== stage.id) return;
    stage.left = Date.now();
    stage.pos = null;
    stage.cursor.el.hidden = true;
    sGone.textContent = stage.name + " left. This is the last page they were on.";
    sGone.hidden = false;
    // Their new page may have joined before the old one left.
    for (const q of peers.values()) if (!q.inView && q.name === stage.name && q.device && deviceName(q.device) === stage.device) return updateStage(q);
  }

  function setStageFollow(on) {
    if (!stage) return;
    if (stage.mode === "lead") return setFollowing(on);
    stage.follow = on;
    const p = peers.get(stage.id);
    if (on && p) showPath(p.path || "/");
    layoutStage();
  }

  vIframe.addEventListener("load", () => {
    if (!stage) return;
    let win = null;
    try { win = vIframe.contentWindow; void win.location.pathname; } catch { return; }
    sAddr.textContent = location.host + win.location.pathname;
    if (stage.mode !== "person") return;
    // Their page in the frame, and our pointer kept over it.
    const p = peers.get(stage.id);
    if (stage.follow && p && safePath(p.path) !== safePath(win.location.pathname)) setStageFollow(false); // a link clicked in the frame
    win.addEventListener("scroll", placeStageCursor, { passive: true });
    // Scrolling it yourself stops following their pointer.
    for (const t of ["wheel", "touchmove"]) win.addEventListener(t, () => { if (stage && stage.follow) setStageFollow(false); }, { passive: true });
    placeStageCursor();
  });

  // Closes it; returns the page the device view was on.
  function closeViewer() {
    if (!stage) return null;
    const was = stage;
    stage = null;
    if (was.cursor) was.cursor.el.remove();
    if (was.mode === "person") send({ type: "watch", id: null });
    let path = null;
    try { path = safePath(vIframe.contentWindow.location.pathname); } catch { /* not ours */ }
    const f = stageFrame();
    if (f) try { f.close(); } catch { /* reloading */ }
    viewer.hidden = true;
    sGone.hidden = true;
    vIframe.removeAttribute("src");
    for (const el of document.querySelectorAll("opentraffic-view-ui")) el.remove();
    render();
    return path;
  }

  // You closed it (the close button, Esc, or a click beside the device).
  function leaveStage() {
    if (!stage) return;
    const mode = stage.mode;
    const path = closeViewer();
    if (mode === "lead") return setFollowing(false);
    if (mode !== "self") return;
    if (isHostLeading()) pushView(); // followers are back to their own windows (or yours)
    // Carry on with the page you had in the phone.
    if (path && path !== lastPath) {
      session.navTo = path;
      saveSession();
      location.assign(path);
    }
  }

  // Phone for yourself (and your followers, when you lead).
  function openPhone() {
    if (stage && stage.mode === "self") return;
    if (following && !(me && me.isHost)) setFollowing(false); // your own view now
    openStage("self");
    if (isHostLeading()) pushView();
  }

  // Tells followers what you show them. While the phone is open, the page in it leads.
  function pushView() {
    if (!isHostLeading()) return;
    const view = currentView();
    const f = stage && stage.mode === "self" ? stageFrame() : null;
    if (f) {
      try { f.lead(view); return; } catch { /* reloading: it leads once it has joined */ }
    }
    if (!(stage && stage.mode === "self")) send({ type: "lead", on: true, view });
  }

  // Follows the host into their phone (or window), or back out of it.
  function syncLeadStage() {
    if (inFrame || !me || me.isHost) return;
    let view = leadOn ? lastLead.view : null;
    // Their window, and ours is already that size: nothing to show.
    if (view && view.kind === "window" && Math.abs(view.w - window.innerWidth) <= 2 && Math.abs(view.h - window.innerHeight) <= 2) view = null;
    if (following && view) {
      if (!stage || stage.mode !== "lead") openStage("lead");
      else updateLeadStage();
    } else if (stage && stage.mode === "lead" && stage.follow && !view) {
      closeViewer();
      applyLead(true);
    }
  }

  // Comment, Point and Draw work in the device view while it's open.
  function useTool(mode) {
    if (!stage) return arm(mode);
    const f = stageFrame();
    if (f) try { f.arm(mode); } catch { /* reloading */ }
  }

  vClose.addEventListener("click", leaveStage);
  sFit.addEventListener("click", () => { if (stage) { stage.fit = true; layoutStage(); } });
  sActual.addEventListener("click", () => { if (stage) { stage.fit = false; layoutStage(); } });
  sFollow.addEventListener("click", () => stage && setStageFollow(!stage.follow));
  sRotate.addEventListener("click", () => {
    if (!stage || stage.mode !== "self") return;
    [stage.w, stage.ht] = [stage.ht, stage.w];
    layoutStage();
    pushView();
  });
  vWindow.addEventListener("click", () => {
    if (!stage || !stage.path) return;
    window.open(stage.path, "_blank", "popup,width=" + stage.w + ",height=" + stage.ht);
  });
  // A click on the stage around the device closes it; the wheel doesn't scroll the page under it.
  viewer.addEventListener("click", (e) => { if (e.target === viewer || e.target === sArea) leaveStage(); });
  viewer.addEventListener("wheel", (e) => {
    if (sArea.scrollHeight <= sArea.clientHeight && sArea.scrollWidth <= sArea.clientWidth) e.preventDefault();
  }, { passive: false });
  let matchTimer = 0;
  window.addEventListener("resize", () => {
    if (stage) layoutStage();
    // Followers matching our window get its new size.
    clearTimeout(matchTimer);
    if (session.match && isHostLeading() && !stage) matchTimer = setTimeout(pushView, 600);
  }, { passive: true });

  // Our window size changed: tell the session (the hub takes one change a second).
  let deviceTimer = 0;
  let lastViewport = "";
  window.addEventListener("resize", () => {
    clearTimeout(deviceTimer);
    deviceTimer = setTimeout(() => {
      const env = currentEnv();
      if (!env || !joined || env.viewport === lastViewport) return;
      if (send({ type: "env", env })) lastViewport = env.viewport;
    }, 1100);
  }, { passive: true });

  window.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (!zoom.hidden) {
      closeZoom();
      e.stopPropagation();
      return;
    }
    const a = root.activeElement;
    if (a === nameInput || a === replyArea || (a === textArea && draft)) return; // handled there
    if (isOurs(e.target) && e.target !== host) return; // a device view's comment box: it handles its own keys
    if (stage) {
      if (stage.armed) useTool(stage.armed); // cancels the tool in the device view first
      else leaveStage();
    } else if (bubbleId) closeBubble();
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
    if (inFrame) {
      try { stageApi.following(on); } catch { /* the stage is gone */ }
    } else if (stage && stage.mode === "lead") {
      // The overlay in the host's phone follows (or stops); the view stays until you close it.
      stage.follow = on;
      const f = stageFrame();
      if (f) try { f.follow(on); } catch { /* reloading */ }
      layoutStage();
    }
    syncLeadStage();
    if (on) applyLead(true);
  }

  function applyLead(withScroll) {
    if (!following || !leadOn || navigating || stage) return; // a device view covers the page
    const { path, ratio } = lastLead;
    if (path && path !== lastPath && path !== alias) {
      navigating = true;
      setTimeout(() => { navigating = false; }, 5000); // e.g. a cancelled beforeunload prompt
      session.navTo = path;
      saveSession();
      location.assign(path); // safePath() guarantees a same-origin path
    } else if (withScroll && ratio !== undefined) {
      const max = maxScroll();
      if (max > 0) glideTo(ratio * max);
    }
  }

  // Following someone's scrolling: glide toward where they are a little every frame, so we keep up with
  // them. (Starting a fresh smooth scroll on every update lags behind and restarts its easing, which stutters.)
  const GLIDE_TIME = 90; // ms to close most of the gap
  let glide = null; // { target, at }
  function glideTo(top) {
    if (reducedMotion.matches) {
      glide = null;
      window.scrollTo(0, top);
      return;
    }
    const was = glide;
    glide = { target: top, at: was ? was.at : performance.now() };
    if (!was) requestAnimationFrame(glideStep);
  }
  function glideStep() {
    if (!glide) return;
    if (!following) { glide = null; return; }
    const now = performance.now();
    const dt = Math.max(0, now - glide.at);
    glide.at = now;
    const y = window.scrollY;
    const gap = glide.target - y;
    if (Math.abs(gap) < 1) {
      window.scrollTo(0, glide.target);
      glide = null;
      return;
    }
    const step = gap * (1 - Math.exp(-dt / (GLIDE_TIME / 3)));
    window.scrollTo(0, y + (Math.abs(step) < 1 ? Math.sign(gap) : step));
    requestAnimationFrame(glideStep);
  }

  // Merges path/ratio from a lead or welcome message. Returns whether a ratio was present.
  function takeLead(m) {
    const path = safePath(m.path);
    const ratio = finite(m.ratio);
    if (path !== null && path !== lastLead.path) lastLead = { path, view: lastLead.view };
    if (ratio !== null) lastLead.ratio = clamp01(ratio);
    if ("view" in m) lastLead.view = cleanView(m.view);
    return ratio !== null;
  }

  function onLead(m) {
    const on = m.on === true;
    const was = leadOn;
    if (me && me.isHost) {
      // Our previous page's socket closing can produce a stale "off" right after we
      // re-asserted leading on this page; assert it once more.
      if (!on && session.lead && !inFrame && Date.now() - welcomedAt < 5000) {
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
      syncLeadStage();
      return;
    }
    const hasRatio = takeLead(m);
    if (!was) setFollowing(inFrame ? frameFollows() : true); // following defaults on whenever the host starts leading
    else {
      syncLeadStage(); // into (or out of) the host's phone
      applyLead(hasRatio);
    }
  }

  function setLeading(on) {
    leadOn = on;
    session.lead = on;
    saveSession();
    send({ type: "lead", on, view: on ? currentView() : null });
    if (on && stage && stage.mode === "self") pushView(); // the page in your phone leads
    if (on) queueScroll();
    if (stage) layoutStage();
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
    if (!following || !leadOn || isOurs(e.target) || stage) return; // the stage covers the page
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
  window.addEventListener("resize", () => { if (draft) draft.spot = null; schedulePlace(); }, { passive: true });
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
    if (armed === "comment" && !draft && !(areaDrag && areaDrag.moved)) {
      hoverEl = !isOurs(e.target) ? e.target : null;
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
    if (!p || !joined || stage) return; // in a device view, the overlay there sends our pointer
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
    for (const p of peers.values()) showAgent(p);
    joined = shown = true;
    if (stage) {
      // We reconnected: find them again (ids are new) and ask for their pointer again.
      const p = peers.get(stage.id);
      if (p) send({ type: "watch", id: p.id });
      else stageLeft(stage.id);
    }
    sessionFull = false;
    failures = 0;
    uploadToken = validUploadToken(m.uploadToken) ? m.uploadToken : null;
    welcomedAt = Date.now();
    leadOn = m.leading === true;
    lastLead = {};
    setErrorsFeature(!!(m.features && typeof m.features === "object" && m.features.errors === true));
    setComments(m.comments);
    // What the page was as loaded, to tell later changes from what its scripts did (not with hot reload).
    if (!inFrame && !baselineLoad) setTimeout(() => { if (!hotReloads()) loadBaseline().catch(() => {}); }, 1200);
    // Back from a reload that brought the page up to date.
    if (Array.isArray(session.scroll)) {
      const [sx, sy] = session.scroll;
      delete session.scroll;
      saveSession();
      if (Number.isFinite(sx) && Number.isFinite(sy)) requestAnimationFrame(() => window.scrollTo(sx, sy));
    }
    if (validId(session.captureAfter)) {
      const id = session.captureAfter;
      delete session.captureAfter;
      saveSession();
      if (comments.get(id)) queueCapture(id, AFTER_SETTLE);
    }
    if (validId(session.reveal)) {
      // We came here to look at a fix.
      const c = comments.get(session.reveal);
      delete session.reveal;
      saveSession();
      if (c && c.path === lastPath) setTimeout(() => lookAtFix(c), 300);
    }
    if (me.isHost) {
      following = false;
      if (inFrame) {
        // The host's phone: the page in it leads while they lead.
        const view = frameLeads() ? stageApi.leadView() : null;
        if (view) { leadOn = true; session.lead = true; send({ type: "lead", on: true, view }); }
      } else if (session.lead) { leadOn = true; send({ type: "lead", on: true, view: currentView() }); } // re-assert after reconnect/reload
      if (leadOn) queueScroll(300);
      render();
    } else {
      if (leadOn) takeLead(m);
      if (inFrame) {
        // In someone's device view, following is the stage's to decide (and it already knows).
        following = leadOn && frameFollows();
        render();
        if (following) applyLead(true);
      } else setFollowing(leadOn && session.follow !== 0); // resumes following after a reload
    }
  }

  function onPeer(m) {
    const p = cleanPeer(m.peer);
    if (!p || !me) return;
    if (p.id === me.id) {
      // The host changed what we may do.
      me.role = p.role;
      if (!canComment() && armed === "comment") disarm();
      render();
      renderBubble();
      return;
    }
    peers.set(p.id, p);
    updateStage(p);
    const c = cursors.get(p.id);
    if (p.isAgent) showAgent(p);
    else if (c) { paintCursor(c, p); place(p.id, c); }
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
      case "leave": peers.delete(m.id); dropCursor(m.id); stageLeft(m.id); return render();
      case "cursor": return onCursor(m);
      case "cursor-hide": stageCursor(m.id, null); return dropCursor(m.id);
      case "lead": return onLead(m);
      case "comment": return upsertComment(m.comment);
      case "comment-delete": return removeComment(m.id);
      case "point": return onPoint(m);
      case "ink": return onInk(m);
      case "capture": return onCapture(m);
      case "refresh": return scheduleRefresh();
      default: return; // unknown types are ignored
    }
  }

  // In a device view: what the stage above may ask of us.
  if (inFrame) {
    try {
      window.frameElement.__opentrafficFrame = {
        arm: (mode) => arm(mode),
        follow: (on) => { if (following !== on) setFollowing(on); },
        lead: (view) => {
          if (!me || !me.isHost) return;
          leadOn = true;
          session.lead = true;
          send({ type: "lead", on: true, view });
          queueScroll(300);
        },
        relayout: () => {
          if (draft) draft.spot = null;
          schedulePlace();
        },
        close: () => {
          disarm();
          closeBubble();
          if (uiHost) uiHost.remove();
        },
      };
    } catch { /* not our stage after all */ }
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
      if (inFrame) hello.inView = true;
      const env = currentEnv();
      if (env) { hello.env = env; lastViewport = env.viewport; }
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
