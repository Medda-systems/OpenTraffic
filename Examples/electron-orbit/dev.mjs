// Like `electron-vite dev`: serves the renderer and a small local API, then starts Electron with
// ELECTRON_RENDERER_URL pointing at the renderer server.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { extname, join } from "node:path";

const RENDERER_PORT = Number(process.env.ORBIT_RENDERER_PORT || 5199);
const API_PORT = Number(process.env.ORBIT_API_PORT || 5198);
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

createServer(async (req, res) => {
  const path = new URL(req.url, "http://x").pathname;
  const file = join(import.meta.dirname, "renderer", path === "/" ? "index.html" : path);
  try {
    const data = await readFile(file);
    res.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404).end("not found");
  }
}).listen(RENDERER_PORT, "127.0.0.1");

createServer((req, res) => {
  res.writeHead(200, { "content-type": "application/json", "access-control-allow-origin": "*" });
  res.end(JSON.stringify({ ok: true, service: "orbit-api", at: new Date().toISOString() }));
}).listen(API_PORT, "127.0.0.1");

const electron = createRequire(import.meta.url)("electron");
// Started from inside another Electron app's terminal, this would make ours run as plain Node.
const { ELECTRON_RUN_AS_NODE, ...env } = process.env;
const child = spawn(electron, ["."], {
  cwd: import.meta.dirname,
  stdio: "inherit",
  env: { ...env, ELECTRON_RENDERER_URL: `http://localhost:${RENDERER_PORT}`, ORBIT_API_PORT: String(API_PORT) },
});
child.on("exit", (code) => process.exit(code ?? 0));
