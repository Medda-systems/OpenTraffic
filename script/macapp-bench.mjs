#!/usr/bin/env node
// Latency and bandwidth benchmark for a shared Mac app's mirror (docs/macapp-benchmarks.md). It talks
// the mirror protocol (docs/macapp-mirror-protocol.md) over a WebSocket of its own, like a viewer
// would, and times what a viewer waits for. Node only, no npm packages.
//
//   node script/macapp-bench.mjs <url> [<url> ...] [options]
//   node script/macapp-bench.mjs --self-test          against script/macapp-viewer-stub.mjs --react
//
// <url>: a share's public URL (https://orbit.opentunnel.xyz), a loopback address of the share's proxy
// or mirror server (http://127.0.0.1:52011), or the socket itself (ws://…/__opentraffic/macapp/ws).
// Several URLs run one after another (local first, then the tunnel) and get a comparison table.
//
// What it measures, per URL:
//   connect      socket upgrade, hello, first tree, first full frame of the main window (--connects)
//   network      WebSocket ping round trip (the mirror server answers pings; --pings)
//   idle         tiles and bytes per second with nobody touching the app (--idle seconds)
//   press        `act press` on an element to the next changed `tree` of its window, to the first tile,
//                and to the first tile over the element (the pixels a viewer sees change) (--samples)
//   type         one `text` character to the field's new value in a `tree` and to the first tile over
//                the field (keystroke echo) (--samples)
//   scroll       tiles and bytes per second while wheeling over the largest list (--scroll seconds)
//   restart      with --restart-cmd: run the command (e.g. `opentraffic restart Orbit --app`) and time
//                the new boot's hello and its first full frame
// It never sends `viewport`, so it doesn't resize the app's window or change its appearance (a browser
// viewer connected at the same time does). Input phases are skipped when a `control` message says this
// viewer doesn't control the app. Bandwidth is also reported while pressing and typing. Before every sample it waits for the stream to
// be quiet (no tile or tree for --quiet ms), so an earlier change isn't counted as the answer.
//
// Options:
//   --label NAME         a name per URL, in order (default: "local" for loopback, else the host)
//   --password PW        the share's password, sent as HTTP Basic auth
//   --origin ORIGIN      Origin header (default: the URL's own origin, which a share's proxy accepts)
//   --press TEXT         element to press: its key, or a label it contains (default: first checkbox)
//   --type-into TEXT     text field to type into: key or label (default: first text field)
//   --samples N          press and keystroke samples (30)      --connects N   connect samples (5)
//   --pings N            ping samples (20)                      --idle S       idle seconds (5)
//   --scroll S           scrolling seconds (5)                  --quiet MS     quiet gap (250)
//   --timeout MS         per-sample timeout (3000)              --phases a,b   subset of the phases above
//   --restart-cmd CMD    shell command that restarts the app (restart phase runs only with it)
//   --json FILE          write the JSON summary there instead of printing it after the tables
// Exits 1 when a URL can't be measured at all; misses (no answer within --timeout) are counted, not fatal.
import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const WS_PATH = "/__opentraffic/macapp/ws";
const PHASES = ["connect", "network", "idle", "press", "type", "scroll", "restart"];
const now = () => performance.now();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- arguments

const argv = process.argv.slice(2);
const VALUE_OPTIONS = new Set(["--label", "--password", "--origin", "--press", "--type-into", "--samples", "--connects", "--pings",
  "--idle", "--scroll", "--quiet", "--timeout", "--phases", "--restart-cmd", "--json", "--url"]);
const urls = [], labels = [], opts = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--help" || a === "-h") { usage(0); }
  else if (a === "--self-test") opts.selfTest = true;
  else if (VALUE_OPTIONS.has(a)) {
    if (i + 1 >= argv.length) usage(2, a + " needs a value");
    const v = argv[++i];
    if (a === "--url") urls.push(v);
    else if (a === "--label") labels.push(v);
    else opts[a.slice(2)] = v;
  } else if (a.startsWith("--")) usage(2, "unknown option " + a);
  else urls.push(a);
}
const num = (name, fallback) => {
  if (opts[name] === undefined) return fallback;
  const n = Number(opts[name]);
  if (!Number.isFinite(n) || n < 0) usage(2, "--" + name + " must be a number");
  return n;
};
const cfg = {
  samples: num("samples", 30), connects: Math.max(1, num("connects", 5)), pings: num("pings", 20),
  idle: num("idle", 5), scroll: num("scroll", 5), quiet: num("quiet", 250), timeout: num("timeout", 3000),
  phases: new Set((opts.phases || PHASES.join(",")).split(",").map((s) => s.trim()).filter(Boolean)),
  restartCmd: opts["restart-cmd"] || null, password: opts.password ?? null, origin: opts.origin || null,
  press: opts.press || null, typeInto: opts["type-into"] || null, json: opts.json || null,
};
for (const p of cfg.phases) if (!PHASES.includes(p)) usage(2, "unknown phase " + p + " (phases: " + PHASES.join(", ") + ")");
if (!opts.selfTest && urls.length === 0) usage(2, "give the share's URL");

function usage(code, problem) {
  if (problem) console.error("macapp-bench: " + problem);
  console.error("usage: node script/macapp-bench.mjs <url> [<url> ...] [--label NAME ...] [--password PW] [--press TEXT]\n" +
    "         [--type-into TEXT] [--samples 30] [--idle 5] [--scroll 5] [--restart-cmd CMD] [--json FILE]\n" +
    "       node script/macapp-bench.mjs --self-test\n(see the comment at the top of the script, and docs/macapp-benchmarks.md)");
  process.exit(code);
}

// ---- target URL

function target(raw) {
  let url;
  try { url = new URL(/^[a-z]+:\/\//i.test(raw) ? raw : "http://" + raw); } catch { throw new Error("not a URL: " + raw); }
  const secure = url.protocol === "https:" || url.protocol === "wss:";
  if (!["http:", "https:", "ws:", "wss:"].includes(url.protocol)) throw new Error("not an http(s) or ws(s) URL: " + raw);
  const hostname = url.hostname.replace(/^\[|\]$/g, "");
  const port = Number(url.port) || (secure ? 443 : 80);
  const origin = cfg.origin || (secure ? "https://" : "http://") + url.host;
  const loopback = /^(127\.|localhost$|::1$)/.test(hostname);
  return { raw, secure, hostname, port, host: url.host, origin, loopback, path: WS_PATH,
    ws: (secure ? "wss://" : "ws://") + url.host + WS_PATH };
}

// ---- WebSocket client (RFC 6455): masked text out, text and binary in, ping/pong, close.

function encodeFrame(opcode, payload) {
  const n = payload.length, mask = crypto.randomBytes(4);
  const head = n < 126 ? Buffer.from([0x80 | opcode, 0x80 | n])
    : n < 65536 ? Buffer.from([0x80 | opcode, 0x80 | 126, n >> 8, n & 255])
    : (() => { const b = Buffer.alloc(10); b[0] = 0x80 | opcode; b[1] = 0x80 | 127; b.writeBigUInt64BE(BigInt(n), 2); return b; })();
  const body = Buffer.alloc(n);
  for (let i = 0; i < n; i++) body[i] = payload[i] ^ mask[i & 3];
  return Buffer.concat([head, mask, body]);
}

function readTile(buf) {
  return { window: buf.readUInt32BE(0), seq: buf.readUInt32BE(4), x: buf.readUInt16BE(8), y: buf.readUInt16BE(10),
    w: buf.readUInt16BE(12), h: buf.readUInt16BE(14), format: buf.readUInt8(16), imageBytes: buf.length - 17 };
}

class Mirror {
  constructor(t) {
    this.t = t;
    this.listeners = new Set();
    this.trees = new Map();         // window id -> latest tree message
    this.pendingFrames = new Map(); // window id -> {seq, full, remaining, bytes}
    this.counts = { wire: 0, text: 0, binary: 0, tiles: 0, trees: 0, frames: 0 };
    this.lastActivity = now();
    this.hello = null;
    this.control = null; // the last `control` message; none means this viewer controls the app
    this.boots = 0;      // new boots seen on this socket (the app restarted)
    this.open = false;
    this.pongWaiters = [];
  }

  // Resolves with timings in ms from the start: upgrade (HTTP 101), hello, firstTree, fullFrame (the main
  // window's first full frame complete) and that frame's bytes.
  connect(timeout = 15000) {
    const t0 = now();
    const timings = { upgrade: null, hello: null, firstTree: null, fullFrame: null, fullFrameBytes: null };
    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = (err) => { if (!settled) { settled = true; clearTimeout(timer); this.destroy(); reject(err); } };
      const timer = setTimeout(() => fail(new Error("no full frame within " + timeout + " ms (got " +
        Object.entries(timings).filter(([, v]) => v !== null).map(([k]) => k).join(", ") + ")")), timeout);
      const off = this.on((ev) => {
        if (ev.type === "text" && ev.m.t === "hello" && timings.hello === null) timings.hello = ev.at - t0;
        if (ev.type === "text" && ev.m.t === "tree" && timings.firstTree === null) timings.firstTree = ev.at - t0;
        if (ev.type === "frameDone" && ev.full && this.hello && ev.window === mainWindow(this.hello)) {
          timings.fullFrame = ev.at - t0;
          timings.fullFrameBytes = ev.bytes;
          off(); settled = true; clearTimeout(timer); resolve(timings);
        }
        if (ev.type === "close") fail(new Error("the socket closed before the first full frame"));
      });
      const t = this.t;
      const key = crypto.randomBytes(16).toString("base64");
      const headers = { Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": key, Origin: t.origin };
      if (cfg.password !== null) headers.Authorization = "Basic " + Buffer.from("bench:" + cfg.password).toString("base64");
      const req = (t.secure ? https : http).request({ host: t.hostname, port: t.port, path: t.path, headers, servername: t.hostname, agent: false });
      req.setTimeout(timeout, () => req.destroy(new Error("no answer to the upgrade within " + timeout + " ms")));
      req.on("error", fail);
      req.on("response", (res) => {
        const why = res.statusCode === 401 ? " (the share has a password: pass --password)"
          : res.statusCode === 403 ? " (Origin refused: pass --origin with the share's own origin)" : "";
        res.resume();
        fail(new Error("HTTP " + res.statusCode + " instead of a WebSocket from " + t.ws + why));
      });
      req.on("upgrade", (res, socket, head) => {
        const expected = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        if (res.headers["sec-websocket-accept"] !== expected) { socket.destroy(); return fail(new Error("bad Sec-WebSocket-Accept")); }
        timings.upgrade = now() - t0;
        socket.setTimeout(0);
        socket.setNoDelay(true);
        this.socket = socket;
        this.open = true;
        this.buffer = Buffer.alloc(0);
        this.parts = [];
        socket.on("data", (chunk) => this.receive(chunk));
        socket.on("close", () => { if (this.open) { this.open = false; this.emit({ type: "close", at: now() }); } });
        socket.on("error", () => {});
        if (head && head.length) this.receive(head);
      });
      req.end();
    });
  }

  on(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit(ev) { for (const fn of [...this.listeners]) fn(ev); }

  receive(chunk) {
    const at = now();
    this.counts.wire += chunk.length;
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
    for (;;) {
      const b = this.buffer;
      if (b.length < 2) return;
      const fin = (b[0] & 0x80) !== 0, opcode = b[0] & 0x0f, masked = (b[1] & 0x80) !== 0;
      let len = b[1] & 0x7f, off = 2;
      if (len === 126) { if (b.length < 4) return; len = b.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (b.length < 10) return; len = Number(b.readBigUInt64BE(2)); off = 10; }
      const maskOff = off;
      if (masked) off += 4;
      if (b.length < off + len) return;
      let payload = b.subarray(off, off + len);
      if (masked) { payload = Buffer.from(payload); for (let i = 0; i < len; i++) payload[i] ^= b[maskOff + (i & 3)]; }
      this.buffer = b.subarray(off + len);
      if (opcode === 8) { this.close(); return; }
      if (opcode === 9) { this.write(10, payload); continue; }
      if (opcode === 10) { const w = this.pongWaiters.shift(); if (w) w(at); continue; }
      if (opcode !== 0) this.partsOpcode = opcode;
      this.parts.push(payload);
      if (!fin) continue;
      const whole = this.parts.length === 1 ? this.parts[0] : Buffer.concat(this.parts);
      this.parts = [];
      if (this.partsOpcode === 1) this.onText(whole, at); else if (this.partsOpcode === 2) this.onBinary(whole, at);
    }
  }

  onText(buf, at) {
    this.counts.text += buf.length;
    let m;
    try { m = JSON.parse(buf.toString("utf8")); } catch { return; }
    if (!m || typeof m !== "object") return;
    if (m.t === "hello") {
      if (this.hello && this.hello.boot !== m.boot) this.boots++;
      this.hello = m; this.windows = m.windows || []; this.trees.clear(); this.pendingFrames.clear();
    }
    else if (m.t === "control") this.control = m;
    else if (m.t === "windows") this.windows = m.windows || [];
    else if (m.t === "tree") { this.trees.set(m.window, m); this.counts.trees++; this.lastActivity = at; }
    else if (m.t === "frame") {
      this.counts.frames++;
      this.pendingFrames.set(m.window, { seq: m.seq, full: !!m.full, remaining: m.tiles, bytes: 0 });
      if (m.tiles === 0) this.finishFrame(m.window, at);
    }
    this.emit({ type: "text", m, at });
  }

  onBinary(buf, at) {
    this.counts.binary += buf.length;
    if (buf.length < 17) return;
    const tile = readTile(buf);
    this.counts.tiles++;
    this.lastActivity = at;
    this.emit({ type: "tile", tile, bytes: buf.length, at });
    const f = this.pendingFrames.get(tile.window);
    if (f && f.seq === tile.seq) { f.bytes += buf.length; if (--f.remaining <= 0) this.finishFrame(tile.window, at); }
  }

  finishFrame(window, at) {
    const f = this.pendingFrames.get(window);
    this.pendingFrames.delete(window);
    this.emit({ type: "frameDone", window, seq: f.seq, full: f.full, bytes: f.bytes, at });
  }

  write(opcode, payload) { if (this.open) this.socket.write(encodeFrame(opcode, payload)); }
  send(obj) { this.write(1, Buffer.from(JSON.stringify(obj))); }

  ping(timeout) {
    return new Promise((resolve) => {
      const t0 = now();
      let done = false;
      const waiter = (at) => { if (!done) { done = true; clearTimeout(timer); resolve(at - t0); } };
      const timer = setTimeout(() => { done = true; const i = this.pongWaiters.indexOf(waiter); if (i >= 0) this.pongWaiters.splice(i, 1); resolve(null); }, timeout);
      this.pongWaiters.push(waiter);
      this.write(9, Buffer.from("bench"));
    });
  }

  close() {
    if (!this.open) return;
    this.write(8, Buffer.from([3, 232]));
    this.open = false;
    const s = this.socket;
    setTimeout(() => s.destroy(), 200).unref();
    this.emit({ type: "close", at: now() });
  }
  destroy() { this.open = false; if (this.socket) this.socket.destroy(); }

  snapshot() { return { at: now(), ...this.counts }; }

  // Waits until no tile or tree came for `quiet` ms (at most `max` ms); true when it got quiet.
  async waitQuiet(quiet, max = 3000) {
    const start = now();
    while (now() - start < max) {
      const gap = now() - this.lastActivity;
      if (gap >= quiet) return true;
      await sleep(Math.min(50, quiet - gap + 1));
    }
    return false;
  }
}

function mainWindow(hello) {
  const ws = hello.windows || [];
  return (ws.find((w) => w.kind === "main") || ws[0] || {}).id;
}

// ---- statistics

function stats(values, misses = 0) {
  const v = values.filter((x) => x !== null && Number.isFinite(x)).sort((a, b) => a - b);
  const pick = (q) => (v.length ? v[Math.min(v.length - 1, Math.ceil(q * v.length) - 1)] : null);
  const r = (x) => (x === null ? null : Math.round(x * 10) / 10);
  return { n: v.length, misses, p50: r(pick(0.5)), p95: r(pick(0.95)), max: r(v.length ? v[v.length - 1] : null),
    min: r(v.length ? v[0] : null), mean: r(v.length ? v.reduce((a, b) => a + b, 0) / v.length : null) };
}

function rate(a, b) {
  const seconds = (b.at - a.at) / 1000;
  const tiles = b.tiles - a.tiles, bytes = b.wire - a.wire, binary = b.binary - a.binary;
  const r1 = (x) => Math.round(x * 10) / 10;
  return { seconds: r1(seconds), tiles, trees: b.trees - a.trees, bytes,
    tilesPerSec: r1(tiles / seconds), kBPerSec: r1(bytes / 1000 / seconds), treesPerSec: r1((b.trees - a.trees) / seconds),
    avgTileKB: tiles ? r1(binary / tiles / 1000) : null };
}

// ---- finding elements

const intersects = (t, r) => t.x < r.x + r.w && r.x < t.x + t.w && t.y < r.y + r.h && r.y < t.y + t.h;
const visible = (n) => n.w > 0 && n.h > 0;

function allNodes(conn) {
  const out = [];
  for (const [window, tree] of conn.trees) for (const n of tree.nodes || []) out.push({ window, node: n });
  return out;
}

function findNode(conn, wanted, fallback, what) {
  const nodes = allNodes(conn);
  if (wanted) {
    const lower = wanted.toLowerCase();
    const hit = nodes.find(({ node }) => node.key === wanted) ||
      nodes.find(({ node }) => visible(node) && fallback.accepts(node) && (node.label || "").toLowerCase().includes(lower)) ||
      nodes.find(({ node }) => (node.label || "").toLowerCase().includes(lower) || node.key.toLowerCase().includes(lower));
    if (!hit) throw new Error("no element matching " + JSON.stringify(wanted) + " to " + what + "; candidates: " + candidates(nodes, fallback.accepts));
    return hit;
  }
  for (const pick of fallback.order) {
    const hit = nodes.find(({ node }) => visible(node) && node.enabled !== false && pick(node));
    if (hit) return hit;
  }
  return null;
}

function candidates(nodes, accepts) {
  const list = nodes.filter(({ node }) => accepts(node) && visible(node)).slice(0, 15).map(({ node }) => node.label || node.key);
  return list.length ? list.map((l) => JSON.stringify(l)).join(", ") : "none visible";
}

const RISKY = /delete|remove|quit|close|cancel|reset|clear|sign out|log out/i;
const PRESS = {
  accepts: (n) => (n.actions || []).includes("press"),
  order: [
    (n) => n.role === "AXCheckBox" && (n.actions || []).includes("press"),
    (n) => (n.actions || []).includes("press") && !RISKY.test(n.label || ""),
  ],
};
const FIELD = {
  accepts: (n) => n.role === "AXTextField" || n.role === "AXTextArea" || n.role === "AXComboBox",
  order: [(n) => n.role === "AXTextField", (n) => n.role === "AXTextArea"],
};
const LIST = ["AXList", "AXTable", "AXOutline", "AXScrollArea", "AXCollection", "AXBrowser"];

// ---- one input sample: send, then time the answers

function measure(conn, send, { window, rect, vBefore, field }) {
  return new Promise((resolve) => {
    const t0 = now();
    const r = { tree: null, tile: null, elementTile: null };
    const finish = () => { off(); clearTimeout(timer); resolve(r); };
    const off = conn.on((ev) => {
      const dt = ev.at - t0;
      if (ev.type === "text" && ev.m.t === "tree" && ev.m.window === window && ev.m.v !== vBefore && r.tree === null) {
        if (!field || (ev.m.nodes || []).some((n) => n.key === field.key && n.value !== field.value)) r.tree = dt;
      }
      if (ev.type === "tile") {
        if (r.tile === null) r.tile = dt;
        if (r.elementTile === null && ev.tile.window === window && (!visible(rect) || intersects(ev.tile, rect))) r.elementTile = dt;
      }
      if (ev.type === "close") finish();
      if (r.tree !== null && r.elementTile !== null) finish();
    });
    const timer = setTimeout(finish, cfg.timeout);
    send();
  });
}

// ---- one URL

async function bench(raw, label) {
  const t = target(raw);
  const run = { label, url: raw, ws: t.ws, origin: t.origin, loopback: t.loopback, app: null, windows: null, scale: null,
    targets: {}, latency: {}, bandwidth: {}, notes: [] };
  const note = (s) => { run.notes.push(s); console.error("  note: " + s); };
  console.error(`\n== ${label}: ${t.ws}`);

  // connect: fresh sockets, the last one stays open for the rest
  let conn;
  const connectTimes = { upgrade: [], hello: [], firstTree: [], fullFrame: [] };
  const fullFrameBytes = [];
  const connects = cfg.phases.has("connect") ? cfg.connects : 1;
  for (let i = 0; i < connects; i++) {
    if (conn) { conn.close(); await sleep(300); }
    conn = new Mirror(t);
    const c = await conn.connect();
    for (const k of Object.keys(connectTimes)) connectTimes[k].push(c[k]);
    fullFrameBytes.push(c.fullFrameBytes);
  }
  run.app = conn.hello.app ? conn.hello.app.name : null;
  run.scale = conn.hello.scale;
  run.windows = (conn.windows || []).map((w) => ({ id: w.id, kind: w.kind, w: w.w, h: w.h }));
  if (cfg.phases.has("connect")) {
    run.latency["connect: socket upgrade"] = stats(connectTimes.upgrade);
    run.latency["connect: hello"] = stats(connectTimes.hello);
    run.latency["connect: first tree"] = stats(connectTimes.firstTree);
    run.latency["connect: first full frame"] = stats(connectTimes.fullFrame);
    run.firstFullFrameKB = Math.round(fullFrameBytes.reduce((a, b) => a + b, 0) / fullFrameBytes.length / 100) / 10;
  }
  // let the rest of the opening burst (other windows' frames, menus) arrive
  await conn.waitQuiet(Math.max(cfg.quiet, 500), 5000);

  if (cfg.phases.has("network") && cfg.pings > 0) {
    const rtts = [];
    for (let i = 0; i < cfg.pings; i++) { rtts.push(await conn.ping(cfg.timeout)); await sleep(50); }
    const misses = rtts.filter((x) => x === null).length;
    run.latency["network: ping round trip"] = stats(rtts, misses);
    if (misses === rtts.length) note("no pong came back: the server or a proxy in between doesn't answer WebSocket pings");
  }

  if (cfg.phases.has("idle") && cfg.idle > 0) {
    const a = conn.snapshot();
    await sleep(cfg.idle * 1000);
    run.bandwidth.idle = rate(a, conn.snapshot());
  }

  // A viewer without control has its input dropped (docs/macapp-mirror-protocol.md, `control`).
  const controls = !conn.control || conn.control.you !== false;
  if (!controls && ["press", "type", "scroll"].some((p) => cfg.phases.has(p))) {
    note(`input phases skipped: this viewer doesn't control the app (mode ${conn.control.mode}); set the share's control to Everyone`);
  }

  if (cfg.phases.has("press") && cfg.samples > 0 && controls) {
    const hit = findNode(conn, cfg.press, PRESS, "press");
    if (!hit) note("press skipped: no visible, enabled element with a press action (pass --press)");
    else {
      const { window, node } = hit;
      run.targets.press = { window, key: node.key, role: node.role, label: node.label };
      console.error(`  press: ${node.role} ${JSON.stringify(node.label)} in window ${window}`);
      if (!PRESS.order[0](node) && !cfg.press) note(`no checkbox to toggle, pressing ${JSON.stringify(node.label)} instead; the app's state changes ${cfg.samples} times`);
      const res = { tree: [], tile: [], elementTile: [] };
      let notQuiet = 0, presses = 0;
      const a = conn.snapshot();
      for (let i = 0; i < cfg.samples && conn.open; i++) {
        if (!(await conn.waitQuiet(cfg.quiet))) notQuiet++;
        const tree = conn.trees.get(window);
        const current = (tree.nodes || []).find((n) => n.key === node.key) || node;
        const r = await measure(conn, () => conn.send({ t: "act", window, key: node.key, action: "press" }), { window, rect: current, vBefore: tree.v });
        presses++;
        for (const k of Object.keys(res)) res[k].push(r[k]);
      }
      run.bandwidth.pressing = rate(a, conn.snapshot());
      const miss = (k) => res[k].filter((x) => x === null).length;
      run.latency["press -> tree"] = stats(res.tree, miss("tree"));
      run.latency["press -> first tile"] = stats(res.tile, miss("tile"));
      run.latency["press -> tile over element"] = stats(res.elementTile, miss("elementTile"));
      if (notQuiet) note(`press: ${notQuiet} of ${presses} samples started without a ${cfg.quiet} ms quiet gap (the app kept changing)`);
      if (node.role === "AXCheckBox" && presses % 2 === 1) { await conn.waitQuiet(cfg.quiet); conn.send({ t: "act", window, key: node.key, action: "press" }); }
    }
  }

  if (cfg.phases.has("type") && cfg.samples > 0 && controls) {
    const hit = findNode(conn, cfg.typeInto, FIELD, "type into");
    if (!hit) note("type skipped: no visible, enabled text field (pass --type-into)");
    else {
      const { window, node } = hit;
      run.targets.type = { window, key: node.key, role: node.role, label: node.label };
      console.error(`  type: ${node.role} ${JSON.stringify(node.label)} in window ${window}`);
      const original = node.value ?? "";
      const res = { tree: [], tile: [], elementTile: [] };
      const letters = "benchmark";
      const clear = async () => { conn.send({ t: "setText", window, key: node.key, value: "" }); await sleep(100); await conn.waitQuiet(cfg.quiet); };
      await clear();
      const a = conn.snapshot();
      for (let i = 0; i < cfg.samples && conn.open; i++) {
        if (i > 0 && i % 12 === 0) await clear();
        await conn.waitQuiet(cfg.quiet);
        const tree = conn.trees.get(window);
        const current = (tree.nodes || []).find((n) => n.key === node.key) || node;
        const r = await measure(conn, () => conn.send({ t: "text", window, text: letters[i % letters.length] }),
          { window, rect: current, vBefore: tree.v, field: { key: node.key, value: current.value } });
        for (const k of Object.keys(res)) res[k].push(r[k]);
      }
      run.bandwidth.typing = rate(a, conn.snapshot());
      const miss = (k) => res[k].filter((x) => x === null).length;
      run.latency["keystroke -> tree"] = stats(res.tree, miss("tree"));
      run.latency["keystroke -> first tile"] = stats(res.tile, miss("tile"));
      run.latency["keystroke -> tile over field"] = stats(res.elementTile, miss("elementTile"));
      conn.send({ t: "setText", window, key: node.key, value: original });
      await sleep(200);
    }
  }

  if (cfg.phases.has("scroll") && cfg.scroll > 0 && controls) {
    const lists = allNodes(conn).filter(({ node }) => LIST.includes(node.role) && visible(node)).sort((a, b) => b.node.w * b.node.h - a.node.w * a.node.h);
    if (!lists.length) note("scroll skipped: no visible list, table or scroll area");
    else {
      const { window, node } = lists[0];
      run.targets.scroll = { window, key: node.key, role: node.role, label: node.label };
      console.error(`  scroll: ${node.role} ${JSON.stringify(node.label)} in window ${window}`);
      const x = Math.round(node.x + node.w / 2), y = Math.round(node.y + node.h / 2);
      await conn.waitQuiet(cfg.quiet);
      conn.send({ t: "pointer", window, kind: "move", x, y, dx: 0, dy: 0, modifiers: [] });
      const a = conn.snapshot();
      const end = now() + cfg.scroll * 1000;
      for (let i = 0; now() < end && conn.open; i++) {
        conn.send({ t: "pointer", window, kind: "wheel", x, y, dx: 0, dy: Math.floor(i / 20) % 2 === 0 ? 40 : -40, modifiers: [] });
        await sleep(50);
      }
      run.bandwidth.scrolling = rate(a, conn.snapshot());
    }
  }

  if (conn.boots) note(`the app restarted ${conn.boots} time(s) during the run (a new boot in hello), e.g. for another viewer's appearance; samples around it are off`);

  if (cfg.phases.has("restart") && cfg.restartCmd) {
    const oldBoot = conn.hello.boot;
    console.error(`  restart: ${cfg.restartCmd}`);
    const t0 = now();
    let sameSocket = true, helloAt = null, frameAt = null;
    const done = new Promise((resolve) => {
      const watch = (c) => c.on((ev) => {
        if (ev.type === "text" && ev.m.t === "hello" && ev.m.boot !== oldBoot && helloAt === null) helloAt = ev.at - t0;
        if (ev.type === "frameDone" && ev.full && helloAt !== null && frameAt === null && ev.window === mainWindow(c.hello)) { frameAt = ev.at - t0; resolve(); }
        if (ev.type === "close" && frameAt === null) {
          sameSocket = false;
          (async () => {
            while (now() - t0 < 60000) {
              const next = new Mirror(t);
              watch(next);
              try { await next.connect(5000); conn = next; return; } catch { await sleep(200); }
            }
            resolve();
          })();
        }
      });
      watch(conn);
      setTimeout(resolve, 60000).unref();
    });
    const child = spawn("/bin/sh", ["-c", cfg.restartCmd], { stdio: ["ignore", "ignore", "inherit"] });
    const exit = new Promise((r) => child.on("exit", (code) => r(code)));
    await done;
    const code = await Promise.race([exit, sleep(1000).then(() => "still running")]);
    if (code !== 0) note("restart command exited " + code);
    run.latency["restart -> new hello"] = stats([helloAt], helloAt === null ? 1 : 0);
    run.latency["restart -> first full frame"] = stats([frameAt], frameAt === null ? 1 : 0);
    run.restartSameSocket = sameSocket;
  }

  conn.close();
  return run;
}

// ---- output

function machine() {
  const sh = (cmd, args) => { try { return execFileSync(cmd, args, { encoding: "utf8", timeout: 5000 }).trim(); } catch { return null; } };
  return { model: sh("/usr/sbin/sysctl", ["-n", "hw.model"]), cpu: (os.cpus()[0] || {}).model || null, cores: os.cpus().length,
    memoryGB: Math.round(os.totalmem() / 2 ** 30), macOS: sh("/usr/bin/sw_vers", ["-productVersion"]), node: process.version };
}

const fmt = (x) => (x === null || x === undefined ? "-" : String(x));
function table(rows, header) {
  const all = [header, ...rows].map((r) => r.map(fmt));
  const widths = header.map((_, i) => Math.max(...all.map((r) => r[i].length)));
  return all.map((r, ri) => r.map((c, i) => (i === 0 ? c.padEnd(widths[i]) : c.padStart(widths[i]))).join("  ") +
    (ri === 0 ? "\n" + widths.map((w) => "-".repeat(w)).join("  ") : "")).join("\n");
}

function print(result) {
  const lines = [];
  for (const run of result.runs) {
    lines.push("", `${run.label}: ${run.ws}${result.selfTest ? "   [harness self-test against the stub, NOT product performance]" : ""}`);
    if (run.error) { lines.push("  FAILED: " + run.error); continue; }
    lines.push(`app ${fmt(run.app)}, ${run.windows.length} window(s), scale ${fmt(run.scale)}` +
      (run.firstFullFrameKB !== undefined ? `, first full frame ${run.firstFullFrameKB} kB` : ""));
    lines.push(table(Object.entries(run.latency).map(([k, s]) => [k, s.n, s.p50, s.p95, s.max, s.misses]), ["latency (ms)", "n", "p50", "p95", "max", "misses"]));
    if (Object.keys(run.bandwidth).length) {
      lines.push("");
      lines.push(table(Object.entries(run.bandwidth).map(([k, b]) => [k, b.seconds, b.tilesPerSec, b.kBPerSec, b.treesPerSec, b.avgTileKB]),
        ["bandwidth", "s", "tiles/s", "kB/s", "trees/s", "kB/tile"]));
    }
    const px = run.latency["press -> tile over element"];
    if (px && px.p50 !== null && run.loopback && !result.selfTest) {
      lines.push(`target: press -> tile over element p50 ${px.p50} ms locally (goal < 120 ms; the mock's polled JPEG was about 300 ms): ${px.p50 < 120 ? "met" : "NOT met"}`);
    }
    for (const n of run.notes) lines.push("note: " + n);
  }
  const ok = result.runs.filter((r) => !r.error);
  if (ok.length > 1) {
    const names = [...new Set(ok.flatMap((r) => Object.keys(r.latency)))];
    lines.push("", table(names.map((n) => [n, ...ok.map((r) => (r.latency[n] ? `${fmt(r.latency[n].p50)} / ${fmt(r.latency[n].p95)}` : "-"))]),
      ["p50 / p95 ms", ...ok.map((r) => r.label)]));
  }
  console.log(lines.join("\n"));
}

// ---- main

let stub = null;
async function startStub() {
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  stub = spawn(process.execPath, [path.join(here, "macapp-viewer-stub.mjs"), "--port", "0", "--react"], { env, stdio: ["ignore", "pipe", "inherit"] });
  process.on("exit", () => { try { stub.kill(); } catch { /* gone */ } });
  return new Promise((resolve, reject) => {
    let text = "";
    stub.stdout.on("data", (d) => { text += d; const m = text.match(/MACAPP_STUB (http:\/\/127\.0\.0\.1:\d+)/); if (m) resolve(m[1]); });
    stub.on("exit", (code) => reject(new Error("stub exited " + code)));
    setTimeout(() => reject(new Error("stub didn't start")), 30000).unref();
  });
}

if (opts.selfTest) {
  const base = await startStub();
  urls.length = 0;
  urls.push(base);
  labels.length = 0;
  labels.push("stub");
  if (!cfg.restartCmd) {
    const boot = crypto.randomUUID().toUpperCase();
    cfg.restartCmd = `curl -s -o /dev/null -X POST -d '{"boot":"${boot}"}' ${base}/__stub/hello && curl -s -o /dev/null -X POST ${base}/__stub/close`;
  }
}

const result = { tool: "macapp-bench", version: 1, date: new Date().toISOString(), selfTest: !!opts.selfTest, machine: machine(),
  settings: { samples: cfg.samples, connects: cfg.connects, pings: cfg.pings, idleSeconds: cfg.idle, scrollSeconds: cfg.scroll,
    quietMs: cfg.quiet, timeoutMs: cfg.timeout, phases: [...cfg.phases], restartCmd: cfg.restartCmd ? true : false }, runs: [] };
let failed = false;
for (let i = 0; i < urls.length; i++) {
  let label = labels[i], ws = null;
  try {
    const t = target(urls[i]);
    ws = t.ws;
    label = label || (t.loopback ? "local" : t.hostname);
    result.runs.push(await bench(urls[i], label));
  } catch (err) {
    failed = true;
    console.error("  error: " + err.message);
    result.runs.push({ label: label || urls[i], url: urls[i], ws: ws || urls[i], error: err.message });
  }
}
print(result);
if (cfg.json) { fs.writeFileSync(cfg.json, JSON.stringify(result, null, 2) + "\n"); console.log("\nJSON summary written to " + cfg.json); }
else console.log("\n" + JSON.stringify(result, null, 2));
if (stub) stub.kill();
process.exit(failed ? 1 : 0);
