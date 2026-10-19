#!/usr/bin/env node
// A stand-in for the Mac app mirror server, for working on the viewer page without a real app: it
// serves macapp-viewer.html/.js/.css like the mirror server and replays a recorded hello, trees and
// frames (script/macapp-viewer-fixture.json) to every viewer that connects. Node only, no npm packages.
// Protocol: docs/macapp-mirror-protocol.md.
//
//   node script/macapp-viewer-stub.mjs [--port 0] [--fixture <file.json>] [--resources <dir>] [--replay]
//
// Prints "MACAPP_STUB http://127.0.0.1:<port>" once listening (loopback only). --replay sends the
// fixture's `timeline` (named messages after delays) to each viewer, so the page shows some life.
// Control endpoints for tests (and curl):
//   GET  /__stub/received[?clear=1]  the JSON messages viewers sent, oldest first
//   POST /__stub/send[?name=<n>]     send a message (or an array) to every viewer: the body, or the
//                                    fixture's named message <n>; a `frame` whose `tiles` is an array
//                                    of {x,y,w,h,image,format} goes out as the frame plus binary tiles
//   POST /__stub/hello               merge the body into the hello later connections get (e.g. a new boot)
//   POST /__stub/close               close every viewer's socket (they reconnect)
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const port = Number(opt("--port", "0"));
const fixturePath = path.resolve(opt("--fixture", path.join(here, "macapp-viewer-fixture.json")));
const resources = path.resolve(opt("--resources", path.join(here, "..", "Sources", "OpenTraffic", "Resources")));
const replay = args.includes("--replay");

const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8"));
const hello = { ...fixture.hello };
const images = fixture.images || {};
const named = fixture.named || {};
const WS_PATH = "/__opentraffic/macapp/ws";
const FILES = {
  "/": ["macapp-viewer.html", "text/html; charset=utf-8"],
  "/__opentraffic/macapp/viewer.js": ["macapp-viewer.js", "text/javascript; charset=utf-8"],
  "/__opentraffic/macapp/viewer.css": ["macapp-viewer.css", "text/css; charset=utf-8"],
};

const clients = new Set();
const received = [];
const seqs = new Map();

// ---- WebSocket (RFC 6455), just enough for the viewer: text and binary out, text in, ping, close.

function frameBytes(opcode, payload) {
  const n = payload.length;
  const head = n < 126 ? Buffer.from([0x80 | opcode, n])
    : n < 65536 ? Buffer.from([0x80 | opcode, 126, n >> 8, n & 255])
    : (() => { const b = Buffer.alloc(10); b[0] = 0x80 | opcode; b[1] = 127; b.writeBigUInt64BE(BigInt(n), 2); return b; })();
  return Buffer.concat([head, payload]);
}

function accept(req, socket) {
  const key = req.headers["sec-websocket-key"];
  if (!key || (req.headers.upgrade || "").toLowerCase() !== "websocket") return socket.destroy();
  const digest = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + digest + "\r\n\r\n");
  socket.setNoDelay(true);
  const client = {
    socket, open: true, buffer: Buffer.alloc(0), parts: [],
    text: (obj) => client.open && socket.write(frameBytes(1, Buffer.from(JSON.stringify(obj)))),
    binary: (buf) => client.open && socket.write(frameBytes(2, buf)),
    close: () => { if (client.open) { client.open = false; socket.end(frameBytes(8, Buffer.from([3, 232]))); } },
  };
  clients.add(client);
  const gone = () => { client.open = false; clients.delete(client); clearTimers(client); };
  socket.on("close", gone);
  socket.on("error", gone);
  socket.on("data", (chunk) => {
    client.buffer = Buffer.concat([client.buffer, chunk]);
    for (;;) {
      const b = client.buffer;
      if (b.length < 2) return;
      const fin = (b[0] & 0x80) !== 0, opcode = b[0] & 0x0f, masked = (b[1] & 0x80) !== 0;
      let len = b[1] & 0x7f, off = 2;
      if (len === 126) { if (b.length < 4) return; len = b.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (b.length < 10) return; len = Number(b.readBigUInt64BE(2)); off = 10; }
      const maskOff = off;
      if (masked) off += 4;
      if (b.length < off + len) return;
      const payload = Buffer.from(b.subarray(off, off + len));
      if (masked) for (let i = 0; i < len; i++) payload[i] ^= b[maskOff + (i & 3)];
      client.buffer = b.subarray(off + len);
      if (opcode === 8) { client.close(); return; }
      if (opcode === 9) { if (client.open) socket.write(frameBytes(10, payload)); continue; }
      if (opcode === 10) continue;
      client.parts.push(payload);
      if (!fin) continue;
      const whole = Buffer.concat(client.parts);
      client.parts = [];
      if (opcode === 1 || opcode === 0) {
        try { received.push(JSON.parse(whole.toString("utf8"))); }
        catch { received.push({ invalid: whole.toString("utf8") }); }
      }
    }
  });
  greet(client);
}

// ---- the replay

function tile(window, seq, t) {
  const image = Buffer.from(images[t.image] || "", "base64");
  const head = Buffer.alloc(17);
  head.writeUInt32BE(window, 0);
  head.writeUInt32BE(seq, 4);
  head.writeUInt16BE(t.x, 8);
  head.writeUInt16BE(t.y, 10);
  head.writeUInt16BE(t.w, 12);
  head.writeUInt16BE(t.h, 14);
  head.writeUInt8(t.format === 1 ? 1 : 0, 16);
  return Buffer.concat([head, image]);
}

// A frame with its tiles listed expands to the `frame` message plus one binary message per tile.
function deliver(client, message) {
  if (message && message.t === "frame" && Array.isArray(message.tiles)) {
    const seq = Number.isInteger(message.seq) ? message.seq : (seqs.get(message.window) || 0) + 1;
    seqs.set(message.window, Math.max(seq, seqs.get(message.window) || 0));
    client.text({ t: "frame", window: message.window, seq, full: !!message.full, tiles: message.tiles.length });
    for (const t of message.tiles) client.binary(tile(message.window, seq, t));
  } else {
    client.text(message);
  }
}

function greet(client) {
  client.text(hello);
  for (const tree of fixture.trees || []) deliver(client, tree);
  for (const frame of fixture.frames || []) deliver(client, { t: "frame", ...frame });
  if (!replay || !Array.isArray(fixture.timeline)) return;
  client.timers = fixture.timeline.map((step) => setTimeout(() => {
    const m = named[step.send];
    if (m) for (const one of Array.isArray(m) ? m : [m]) deliver(client, one);
  }, step.after));
}

function clearTimers(client) {
  for (const t of client.timers || []) clearTimeout(t);
}

function broadcast(message) {
  for (const one of Array.isArray(message) ? message : [message]) for (const c of clients) deliver(c, one);
}

// ---- HTTP

function body(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      try { resolve(text ? JSON.parse(text) : null); } catch { resolve(undefined); }
    });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://stub");
  const reply = (status, type, data) => {
    res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
    res.end(data);
  };
  const json = (status, obj) => reply(status, "application/json", JSON.stringify(obj));
  if (req.method === "GET" && FILES[url.pathname]) {
    const [file, type] = FILES[url.pathname];
    try { return reply(200, type, fs.readFileSync(path.join(resources, file))); }
    catch { return reply(404, "text/plain", "missing " + file); }
  }
  if (req.method === "GET" && url.pathname === "/__opentraffic/macapp/icon.png" && fixture.icon) {
    return reply(200, "image/png", Buffer.from(fixture.icon, "base64"));
  }
  if (url.pathname === "/favicon.ico") return reply(204, "image/x-icon", "");
  if (req.method === "GET" && url.pathname === "/__stub/received") {
    const list = received.slice();
    if (url.searchParams.get("clear") === "1") received.length = 0;
    return json(200, list);
  }
  if (req.method === "POST" && url.pathname === "/__stub/send") {
    const name = url.searchParams.get("name");
    const message = name ? named[name] : await body(req);
    if (!message) return json(400, { error: name ? "no named message " + name : "body must be JSON" });
    broadcast(message);
    return json(200, { sent: clients.size });
  }
  if (req.method === "POST" && url.pathname === "/__stub/hello") {
    const patch = await body(req);
    if (!patch || typeof patch !== "object") return json(400, { error: "body must be a JSON object" });
    Object.assign(hello, patch);
    return json(200, hello);
  }
  if (req.method === "POST" && url.pathname === "/__stub/close") {
    const n = clients.size;
    for (const c of [...clients]) c.close();
    return json(200, { closed: n });
  }
  reply(404, "text/plain", "not found");
});

server.on("upgrade", (req, socket) => {
  if (new URL(req.url, "http://stub").pathname !== WS_PATH) return socket.destroy();
  accept(req, socket);
});

server.listen(port, "127.0.0.1", () => {
  console.log("MACAPP_STUB http://127.0.0.1:" + server.address().port);
});
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => process.exit(0));
