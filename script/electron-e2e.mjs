#!/usr/bin/env node
// End-to-end run of Electron app sharing: the electron-orbit fixture shared through an isolated
// OpenTraffic copy and driven from headless Chrome through its public address, the way a viewer would
// use it. Node only, no npm packages (the fixture installs its own Electron); Chrome is driven over raw
// CDP. See docs/electron-e2e.md.
//
//   node script/electron-e2e.mjs [--work <dir>] [--app <OpenTraffic.app>] [--build] [--via opentunnel]
//                                [--name <share>] [--steps a,b,...] [--skip a,b,...] [--keep]
//
// It copies Examples/electron-orbit to the work folder (so a step can edit its main.js) and installs it,
// launches the OpenTraffic copy with its own home and API socket, runs the fixture's dev script (its
// window hidden) and shares its dev server with the copy's own command, then runs the steps below at
// 1440 px and 390 px. Every step saves a screenshot in <work>/shots; the run stops at the first failure,
// names the step and exits 1. At the end the shares are stopped (which removes their OpenTunnel routes)
// and removed, the fixture stops and the copy quits (SIGTERM to the process the script started).
//
// Never use it with the OpenTraffic you use day to day: --app must be a copy with its own bundle
// identifier (docs/macapp-e2e.md builds one), and the script refuses one that is already running.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

// ---------------------------------------------------------------- options

const argv = process.argv.slice(2);
const opt = (name, fallback) => { const i = argv.indexOf("--" + name); return i >= 0 ? argv[i + 1] : fallback; };
const flag = (name) => argv.includes("--" + name);
if (flag("help") || flag("h")) {
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 18).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
  process.exit(0);
}
const APP = path.resolve(opt("app", "/Users/Shared/OpenTraffic-e2e/OpenTraffic.app"));
const WORK = path.resolve(opt("work", path.join(os.tmpdir(), "ot-electron-e2e-" + new Date().toISOString().replace(/[-:]/g, "").slice(0, 15))));
const VIA = opt("via", "opentunnel");
const SHARE = opt("name", "Electron Orbit E2E");
const APP_SHARE = SHARE + " (finished app)";
const ONLY = opt("steps", "") ? new Set(opt("steps").split(",").map((s) => s.trim())) : null;
const SKIP = new Set(opt("skip", "").split(",").map((s) => s.trim()).filter(Boolean));
const KEEP = flag("keep");
const BUILD = flag("build");
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const BUNDLE_ID = "se.medda.opentraffic.e2e";

const SHOTS = path.join(WORK, "shots");
const HOME = path.join(WORK, "home");
const SOCKET = path.join(WORK, "ot.sock");
const FIXTURE = path.join(WORK, "orbit");
const FIXTURE_HOME = path.join(WORK, "orbit-home"); // the fixture's own Electron keeps its data here
const FINISHED_APP = path.join(FIXTURE, "dist", "Orbit.app");
const DOWNLOADS = path.join(WORK, "downloads");
const CLI = path.join(APP, "Contents", "MacOS", "opentraffic-cli");
const APP_BINARY = path.join(APP, "Contents", "MacOS", "OpenTraffic");

// Spawned programs must behave normally, even when this runs inside an Electron host.
const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const quote = (s) => /^[\w./:@-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'";

// ---------------------------------------------------------------- steps and the summary

const results = []; // { name, ok, ms, note }
let stepNumber = 0;
let page = null; // set once Chrome runs
class Skip extends Error {}

async function step(name, fn, { always = false } = {}) {
  if (!always && ((ONLY && !ONLY.has(name)) || SKIP.has(name))) return;
  const n = String(++stepNumber).padStart(2, "0");
  const started = Date.now();
  process.stdout.write(`${n} ${name} … `);
  try {
    const note = await fn();
    const ms = Date.now() - started;
    results.push({ name, ok: true, ms, note: note || "" });
    console.log(`PASS (${(ms / 1000).toFixed(1)} s)${note ? " " + note : ""}`);
    if (page) await page.shot(`${n}-${name}`).catch(() => {});
  } catch (e) {
    const ms = Date.now() - started;
    if (e instanceof Skip) {
      results.push({ name, ok: true, skipped: true, ms, note: e.message });
      console.log(`SKIP ${e.message}`);
      return;
    }
    results.push({ name, ok: false, ms, note: e.message });
    console.log(`FAIL (${(ms / 1000).toFixed(1)} s): ${e.message}`);
    if (page) await page.shot(`${n}-${name}-FAILED`).catch(() => {});
    await finish(1, name);
  }
}

function summary() {
  const lines = ["", "Step                                                   Result   Seconds"];
  for (const r of results) lines.push(`${r.name.padEnd(54)} ${(r.skipped ? "skip" : r.ok ? "pass" : "FAIL").padEnd(8)} ${(r.ms / 1000).toFixed(1).padStart(7)}${r.note ? "  " + r.note : ""}`);
  const total = results.reduce((s, r) => s + r.ms, 0);
  lines.push(`${"total".padEnd(54)} ${"".padEnd(8)} ${(total / 1000).toFixed(1).padStart(7)}`);
  return lines.join("\n");
}

const cleanups = []; // run in reverse at the end
let finishing = false;
async function finish(code, failedStep) {
  if (finishing) return;
  finishing = true;
  for (const fn of cleanups.reverse()) {
    try { await fn(); } catch (e) { console.log("cleanup: " + e.message); }
  }
  console.log(summary());
  fs.mkdirSync(WORK, { recursive: true });
  fs.writeFileSync(path.join(WORK, "summary.json"), JSON.stringify({ app: APP, via: VIA, failed: failedStep || null, steps: results }, null, 2));
  console.log(`\nScreenshots: ${SHOTS}\nSummary: ${path.join(WORK, "summary.json")}`);
  if (failedStep) console.log(`FAILED at step "${failedStep}"`);
  process.exit(code);
}
process.on("SIGINT", () => finish(130, "interrupted"));

const assert = (cond, message) => { if (!cond) throw new Error(message); };

// ---------------------------------------------------------------- processes, the copy and its command

function run(cmd, args, { cwd = root, timeout = 600_000, extraEnv = {} } = {}) {
  const r = spawnSync(cmd, args, { cwd, env: { ...env, ...extraEnv }, encoding: "utf8", timeout, maxBuffer: 64 << 20 });
  if (r.error) throw new Error(`${path.basename(cmd)}: ${r.error.message}`);
  return r;
}

// A program of the fixture's, in a process group of its own so stopping it stops what it started.
function startGroup(cmd, args, { cwd, extraEnv = {}, log }) {
  const out = fs.openSync(log, "a");
  const child = spawn(cmd, args, { cwd, env: { ...env, ...extraEnv }, detached: true, stdio: ["ignore", out, out] });
  const stop = async () => {
    try { process.kill(-child.pid, "SIGTERM"); } catch { return; }
    for (let i = 0; i < 50; i++) { try { process.kill(-child.pid, 0); } catch { return; } await sleep(100); }
    try { process.kill(-child.pid, "SIGKILL"); } catch { /* gone */ }
  };
  return { child, stop };
}

const freePort = () => new Promise((resolve, reject) => {
  const server = net.createServer();
  server.listen(0, "127.0.0.1", () => { const { port } = server.address(); server.close(() => resolve(port)); });
  server.on("error", reject);
});

async function portOtherThan5173() {
  for (;;) { const port = await freePort(); if (port !== 5173) return port; } // 5173 belongs to the user's own dev server
}

const copyRunning = () => run("/usr/bin/pgrep", ["-f", APP_BINARY]).stdout.trim().split("\n").filter(Boolean).map(Number);
let launched = false;

// The copy's own command, talking to its socket. Only while the copy runs: the command starts its
// app when nobody answers, and that would be the copy without its own home.
function cli(args, { json = false, ok = true, timeout = 180_000 } = {}) {
  assert(launched && copyRunning().length, "the OpenTraffic copy isn't running");
  const r = run(CLI, json ? [...args, "--json"] : args, { timeout, extraEnv: { OPENTRAFFIC_SOCKET: SOCKET } });
  const out = (r.stdout || "") + (r.stderr || "");
  if (ok && r.status !== 0) throw new Error(`opentraffic ${args.join(" ")} exited ${r.status}: ${out.trim().slice(0, 600)}`);
  if (!ok) return { status: r.status, out };
  if (!json) return out;
  try { return JSON.parse(r.stdout); } catch { throw new Error(`opentraffic ${args.join(" ")} didn't print JSON: ${out.trim().slice(0, 600)}`); }
}

async function until(fn, what, timeout = 10_000, every = 150) {
  const end = Date.now() + timeout;
  let last;
  for (;;) {
    try { last = await fn(); if (last) return last; } catch (e) { last = e.message; }
    if (Date.now() > end) throw new Error(`timed out after ${timeout / 1000} s waiting for ${what}` + (typeof last === "string" && last ? ` (${last})` : ""));
    await sleep(every);
  }
}

const answers = async (url) => { try { return (await fetch(url, { signal: AbortSignal.timeout(5000) })).status; } catch { return 0; } };

// ---------------------------------------------------------------- Chrome over CDP

async function startChrome() {
  if (!fs.existsSync(CHROME)) throw new Error("Google Chrome not found (set CHROME to its binary)");
  const profile = path.join(WORK, "chrome");
  fs.rmSync(profile, { recursive: true, force: true });
  const chrome = spawn(CHROME, [
    "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run",
    "--no-default-browser-check", "--hide-scrollbars", "--mute-audio", "--window-size=1440,900", "about:blank",
  ], { env, stdio: "ignore" });
  cleanups.push(async () => { chrome.kill(); await sleep(300); fs.rmSync(profile, { recursive: true, force: true }); });
  let port = null;
  for (let i = 0; i < 300 && !port; i++) {
    try { port = fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n")[0]; } catch { await sleep(100); }
  }
  assert(port, "Chrome didn't start");
  const targets = async () => (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).filter((t) => t.type === "page");
  let target = null;
  for (let i = 0; i < 600 && !target; i++) { // a busy Mac can take a while
    try { target = (await targets())[0]; } catch { /* not yet */ }
    if (!target) await sleep(100);
  }
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let nextId = 0;
  const pending = new Map();
  const listeners = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? reject(new Error(m.error.message)) : resolve(m.result);
    } else if (m.method) for (const l of listeners) l(m);
  };
  const cdp = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
  const errors = [];
  const events = [];
  listeners.push((m) => {
    if (m.method === "Runtime.exceptionThrown") errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
    if (m.method === "Runtime.consoleAPICalled" && m.params.type === "error") errors.push(m.params.args.map((a) => a.value ?? a.description).join(" "));
    if (m.method.startsWith("Browser.download") || m.method.startsWith("Page.download")) events.push(m);
  });
  await cdp("Page.enable");
  await cdp("Runtime.enable");
  await cdp("DOM.enable");
  await cdp("Emulation.setFocusEmulationEnabled", { enabled: true });

  const p = {
    cdp, errors, events, targets,
    closeTarget: (id) => fetch(`http://127.0.0.1:${port}/json/close/${id}`),
    async eval(expression) {
      const r = await cdp("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true, userGesture: true });
      if (r.exceptionDetails) throw new Error("page: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
      return r.result.value;
    },
    waitFor(expression, what, timeout = 10_000) { return until(() => p.eval(expression), what, timeout, 80); },
    async shot(name) {
      fs.mkdirSync(SHOTS, { recursive: true });
      const r = await cdp("Page.captureScreenshot", { format: "png" });
      fs.writeFileSync(path.join(SHOTS, name + ".png"), Buffer.from(r.data, "base64"));
    },
    mouse: (type, x, y, extra = {}) => cdp("Input.dispatchMouseEvent", { type, x, y, button: "none", ...extra }),
    async click(pt, button = "left") {
      await p.mouse("mouseMoved", pt.x, pt.y);
      await p.mouse("mousePressed", pt.x, pt.y, { button, clickCount: 1, buttons: button === "left" ? 1 : 2 });
      await p.mouse("mouseReleased", pt.x, pt.y, { button, clickCount: 1 });
    },
    async key(k, code, vk, { text, modifiers = 0 } = {}) {
      await cdp("Input.dispatchKeyEvent", { type: text ? "keyDown" : "rawKeyDown", key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers, ...(text ? { text, unmodifiedText: text } : {}) });
      await cdp("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers });
    },
    async size(width, height, { mobile = false } = {}) {
      await cdp("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: mobile ? 3 : 1, mobile });
      await cdp("Emulation.setTouchEmulationEnabled", { enabled: mobile, maxTouchPoints: mobile ? 5 : 1 });
    },
    // The collaboration overlay and the Electron bar live in closed shadow roots, which only DevTools
    // can see into. `match(tag, attributes, text)`; text is the node's own text, when it has one.
    async overlayElements(match) {
      const { root: doc } = await cdp("DOM.getDocument", { depth: -1, pierce: true });
      const found = [];
      const textOf = (n) => (n.children || []).filter((c) => c.nodeType === 3).map((c) => c.nodeValue).join("");
      const walk = (n) => {
        const attrs = {};
        for (let i = 0; i + 1 < (n.attributes || []).length; i += 2) attrs[n.attributes[i]] = n.attributes[i + 1];
        if (n.nodeType === 1 && match(n.nodeName.toLowerCase(), attrs, textOf(n), n)) found.push({ nodeId: n.nodeId, backendNodeId: n.backendNodeId, attrs, node: n });
        for (const c of [...(n.children || []), ...(n.shadowRoots || [])]) walk(c);
      };
      walk(doc);
      return found;
    },
    async overlayElement(match) { return (await p.overlayElements(match))[0] || null; },
    async overlayCenter(el) {
      // Just added nodes may not be laid out yet.
      const { model } = await until(() => cdp("DOM.getBoxModel", { backendNodeId: el.backendNodeId }), "a box for <" + el.node.nodeName.toLowerCase() + ">", 5000, 100);
      const q = model.border;
      return { x: (q[0] + q[4]) / 2, y: (q[1] + q[5]) / 2, w: model.width, h: model.height, left: q[0], top: q[1], right: q[4], bottom: q[5] };
    },
  };
  return p;
}

// Where an overlay element is, once it is laid out.
const boxOf = (match, what, timeout = 10_000) => until(async () => {
  const el = await page.overlayElement(match);
  if (!el) return null;
  const box = await page.overlayCenter(el);
  return box.w > 0 && box.h > 0 && box;
}, what + " laid out", timeout);

// All the text inside a node found by overlayElements (its descendants' text nodes).
const allText = (n) => n.nodeType === 3 ? n.nodeValue : [...(n.children || []), ...(n.shadowRoots || [])].map(allText).join(" ");

// ---------------------------------------------------------------- the shared page

// The Electron bar (electron-preload-shim.js) is a closed shadow root on a [data-opentraffic-ui] host.
const electronBar = () => page.overlayElement((tag, a) => tag === "div" && a.class === "bar");
const electronButton = (label) => page.overlayElement((tag, a, text) => tag === "button" && text === label);
const toastWith = async (text) => (await page.overlayElements((tag, a) => tag === "div" && /^toast( |$)/.test(a.class || ""))).find((t) => allText(t.node).includes(text));
const LOG = `document.getElementById('log').textContent`;
const NOTES = `[...document.querySelectorAll('#notes li')].map((li) => li.textContent)`;
const visible = (selector) => `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return null; const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 ? { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height } : null; })()`;
const centerOf = (selector, what, timeout = 10_000) => until(() => page.eval(visible(selector)), what + " on the page", timeout);
const connected = `(async () => { try { return (await orbit.echoBytes(new Uint8Array([1]))).length === 1; } catch { return false; } })()`;

// ---------------------------------------------------------------- the run

console.log(`Electron end-to-end: ${APP} via ${VIA}; work folder ${WORK}`);
fs.mkdirSync(WORK, { recursive: true });

await step("prepare the fixture", async () => {
  // A scratch copy of Examples/electron-orbit with its own Electron: a step edits its main.js.
  const source = path.join(root, "Examples", "electron-orbit");
  const installed = fs.existsSync(path.join(FIXTURE, "node_modules", "electron", "dist", "Electron.app"))
    && fs.readFileSync(path.join(FIXTURE, "package-lock.json"), "utf8") === fs.readFileSync(path.join(source, "package-lock.json"), "utf8");
  if (!installed) fs.rmSync(FIXTURE, { recursive: true, force: true });
  fs.mkdirSync(FIXTURE, { recursive: true });
  for (const item of ["package.json", "package-lock.json", "main.js", "preload.js", "dev.mjs", "package.mjs", "renderer"]) {
    fs.cpSync(path.join(source, item), path.join(FIXTURE, item), { recursive: true });
  }
  if (!installed) {
    const r = run("npm", ["ci", "--no-audit", "--no-fund"], { cwd: FIXTURE });
    assert(r.status === 0, "npm ci failed: " + (r.stderr || r.stdout).slice(-800));
  }
  const electron = JSON.parse(fs.readFileSync(path.join(FIXTURE, "node_modules", "electron", "package.json"), "utf8")).version;
  return `Electron ${electron}${installed ? " (installed before)" : ""}`;
}, { always: true });

await step("build the OpenTraffic copy", async () => {
  if (!BUILD) {
    assert(fs.existsSync(APP_BINARY), `no OpenTraffic copy at ${APP}; run with --build (see docs/electron-e2e.md)`);
    throw new Skip("reusing " + APP + " (--build rebuilds it)");
  }
  const r = run(path.join(root, "script", "build_and_run.sh"), ["--build-only"], {
    timeout: 1_800_000,
    extraEnv: { OPENTRAFFIC_CONFIGURATION: "release", OPENTRAFFIC_BUNDLE_ID: BUNDLE_ID, OPENTRAFFIC_DIST_DIR: path.dirname(APP) },
  });
  assert(r.status === 0, "build_and_run.sh failed: " + (r.stderr || r.stdout).slice(-1500));
}, { always: true });

await step("launch the copy", async () => {
  const id = run("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleIdentifier", path.join(APP, "Contents", "Info.plist")]).stdout.trim();
  assert(id && id !== "se.medda.opentraffic", `${APP} is OpenTraffic itself (${id}); use a copy with its own bundle identifier`);
  assert(!copyRunning().length, `${APP} is already running; quit it first (kill -TERM $(pgrep -f ${quote(APP_BINARY)}))`);
  fs.mkdirSync(HOME, { recursive: true });
  fs.rmSync(SOCKET, { force: true });
  const r = run("/usr/bin/open", ["-j", "-n", "-g", "-a", APP, "--env", `CFFIXED_USER_HOME=${HOME}`, "--env", `OPENTRAFFIC_SOCKET=${SOCKET}`,
    "--args", "--background", "-migratedLegacyDefaults", "<true/>", "-hasCompletedOnboarding", "<true/>", "-apiEnabled", "<true/>"]);
  assert(r.status === 0, "open failed: " + r.stderr);
  launched = true;
  const pid = await until(() => copyRunning()[0], "the copy's process", 30_000);
  cleanups.push(async () => {
    if (KEEP) return console.log(`(--keep) the copy keeps running (pid ${pid}): OPENTRAFFIC_SOCKET=${SOCKET} ${quote(CLI)}`);
    // SIGTERM to this process, which quits the way the Quit menu does. Not "tell application id … to
    // quit": with a copy started by `open -n` that can start another copy, without this one's home.
    try { process.kill(pid, "SIGTERM"); } catch { /* gone */ }
    await until(() => !copyRunning().includes(pid), "the copy to quit", 30_000).catch((e) => console.log("cleanup: " + e.message));
  });
  await until(() => copyRunning().length && fs.existsSync(SOCKET), "the copy's API socket", 30_000);
  await until(() => run(CLI, ["list"], { extraEnv: { OPENTRAFFIC_SOCKET: SOCKET } }).status === 0, "the copy's API", 30_000);
  return `pid ${pid}`;
}, { always: true });

let RENDERER_PORT = 0;
await step("start the fixture", async () => {
  // `npm run dev`: the renderer's dev server, a small local API and Electron. Its window stays hidden
  // (ORBIT_HIDDEN) and its data stays in the work folder (CFFIXED_USER_HOME), off the Mac's real home.
  RENDERER_PORT = await portOtherThan5173();
  const apiPort = await portOtherThan5173();
  fs.mkdirSync(FIXTURE_HOME, { recursive: true });
  const dev = startGroup(process.execPath, ["dev.mjs"], {
    cwd: FIXTURE, log: path.join(WORK, "orbit-dev.log"),
    extraEnv: { ORBIT_RENDERER_PORT: String(RENDERER_PORT), ORBIT_API_PORT: String(apiPort), ORBIT_HIDDEN: "1", CFFIXED_USER_HOME: FIXTURE_HOME },
  });
  cleanups.push(() => KEEP ? console.log(`(--keep) the fixture keeps running (process group ${dev.child.pid})`) : dev.stop());
  await until(async () => (await answers(`http://127.0.0.1:${RENDERER_PORT}/`)) === 200, "the renderer's dev server", 30_000, 300);
  const service = await until(() => {
    const listed = cli(["services"], { json: true });
    return (listed.services || []).find((s) => s.port === RENDERER_PORT && /\(Electron app\)$/.test(s.title || ""));
  }, "the copy to list the dev server as an Electron app", 60_000, 1000);
  return `${service.title} on port ${RENDERER_PORT}, its API on ${apiPort}`;
}, { always: true });

let URL_ = null;
await step("share the fixture", async () => {
  const out = cli(["share", String(RENDERER_PORT), "--via", VIA, "--name", SHARE]);
  URL_ = (out.match(/https:\/\/\S+/) || [])[0];
  assert(URL_, "no public URL in: " + out.trim());
  cleanups.push(async () => {
    if (KEEP) return console.log(`(--keep) ${SHARE} stays live at ${URL_}`);
    // Stopping removes the share's OpenTunnel route; removing it drops its settings and comments.
    try { cli(["stop", SHARE]); } catch (e) { console.log("cleanup: " + e.message); }
    try { cli(["remove", SHARE, "--yes"]); } catch (e) { console.log("cleanup: " + e.message); }
  });
  const status = await until(() => { const s = cli(["status", SHARE], { json: true }); return s.state === "running" && s; }, "the share to run", 60_000);
  assert(status.name === SHARE, `the share is called ${JSON.stringify(status.name)}, not ${JSON.stringify(SHARE)}`);
  assert(status.collaboration, "live collaboration is off");
  await until(async () => (await answers(URL_)) === 200, "the public URL to answer 200", 60_000, 1000);
  return `${URL_} (${status.name})`;
}, { always: true });

page = await startChrome();
await page.size(1440, 900);

async function loadPage(what) {
  await page.cdp("Page.navigate", { url: URL_ });
  await page.waitFor(`document.readyState === 'complete' && !!document.getElementById('notes') && typeof orbit === 'object'`, "the app's page with its preload", 30_000);
  await page.waitFor(`!!document.querySelector('opentraffic-collab')`, "the collaboration overlay", 15_000);
  await until(() => page.overlayElement((tag, a) => a["aria-label"] === "Live Collaboration"), "the Live Collaboration toolbar", 15_000);
  await until(async () => { const bar = await electronBar(); return bar && allText(bar.node).includes("desktop preview"); }, "the desktop preview bar", 15_000);
  await until(() => page.eval(connected), "the app's main process to answer " + what, 15_000);
}

let NOTES_AT_START = [];
await step("page loads with the collab toolbar at 1440 px", async () => {
  await loadPage("at 1440 px");
  const title = await page.eval(`document.title`);
  assert(title === "Orbit", "the page is called " + JSON.stringify(title));
  const bar = await electronBar();
  assert(allText(bar.node).includes("Orbit"), "the desktop preview bar doesn't name Orbit: " + allText(bar.node));
  const pill = await boxOf((tag, a) => a["aria-label"] === "Live Collaboration", "the toolbar");
  assert(pill.right <= 1440 && pill.bottom <= 900 && pill.w > 0, "the toolbar is off screen: " + JSON.stringify(pill));
  NOTES_AT_START = await page.waitFor(`(async () => { await new Promise((r) => setTimeout(r, 300)); return ${NOTES}; })()`, "the notes list");
  return `${NOTES_AT_START.length} notes in the sandboxed copy's data`;
});

await step("ipcRenderer invoke, send and sendSync round trips", async () => {
  // invoke: bytes go to the main process and back as bytes.
  const echo = await page.eval(`(async () => { const r = await orbit.echoBytes(new Uint8Array([7, 8, 9])); return { length: r.length, first: r.first, back: r.back instanceof Uint8Array ? [...r.back] : String(r.back) }; })()`);
  assert(echo.length === 3 && echo.first === 7 && JSON.stringify(echo.back) === "[7,8,9]", "invoke echo: " + JSON.stringify(echo));
  // sendSync: a synchronous answer from main.
  const version = await page.eval(`orbit.versionSync()`);
  assert(version?.app === "0.1.0" && version?.name === "Orbit", "sendSync answered " + JSON.stringify(version));
  // send + event.reply: the page sent ping 41 when it loaded; main replied pong 42. Once more:
  await page.eval(`orbit.ping(99), true`);
  await page.waitFor(`${LOG}.includes('pong 100')`, "pong 100 after ping 99");
  assert(await page.eval(`${LOG}.includes('pong 42')`), "no pong 42 for the ping the page sent on load");
  // invoke with a reply that changes data: a note through the form.
  const note = "E2E note " + Date.now().toString(36);
  await page.click(await centerOf("#text", "the note field"));
  await page.cdp("Input.insertText", { text: note });
  await page.click(await centerOf("#save", "Save"));
  await page.waitFor(`${NOTES}.includes(${JSON.stringify(note)})`, "the new note in the list");
  return `echo ${JSON.stringify(echo.back)}, sendSync ${version.name} ${version.app}, note added`;
});

await step("main-to-renderer events reach the page", async () => {
  await page.waitFor(`document.getElementById('greeting').textContent === 'Welcome to Orbit'`, "the hello event's greeting");
  await page.waitFor(`${LOG}.includes('notes changed: ')`, "the notes:changed event after adding a note");
  // The app's timer sends a tick to every window every 5 s.
  const tick = await page.eval(`new Promise((resolve) => { const off = orbit.on('tick', (t) => { off(); resolve(t); }); setTimeout(() => resolve(null), 8000); })`);
  assert(typeof tick === "number" && Math.abs(Date.now() - tick) < 60_000, "no tick from main within 8 s: " + tick);
  return "hello, notes:changed, tick";
});

await step("the app menu template shows and its items run", async () => {
  const menuButton = await until(() => electronButton("Menu"), "the bar's Menu button");
  await page.click(await page.overlayCenter(menuButton));
  const heads = await until(async () => { const h = await page.overlayElements((tag, a) => tag === "div" && a.class === "head"); return h.length && h; }, "the menu");
  const headings = heads.map((h) => allText(h.node).trim()).filter(Boolean);
  assert(headings.includes("Orbit") && headings.includes("Notes"), "the menu's sections: " + JSON.stringify(headings));
  const items = (await page.overlayElements((tag, a) => tag === "button" && a.class === "item")).map((b) => allText(b.node).replace(/\s+/g, " ").trim());
  assert(items.some((t) => t.startsWith("New Note") && t.includes("⌘N")) && items.includes("Export…"), "the menu's items: " + JSON.stringify(items));
  await page.shot(String(stepNumber).padStart(2, "0") + "-menu-open");
  // New Note: main sends menu:new-note, the page focuses the note field.
  await page.eval(`document.activeElement && document.activeElement.blur(), true`);
  const newNote = (await page.overlayElements((tag, a) => tag === "button" && a.class === "item")).find((b) => allText(b.node).trim().startsWith("New Note"));
  await page.click(await page.overlayCenter(newNote));
  await page.waitFor(`document.activeElement?.id === 'text'`, "the note field focused by New Note");
  // Its accelerator works on the page too.
  await page.eval(`document.activeElement.blur(), true`);
  await page.key("n", "KeyN", 78, { modifiers: 4 }); // ⌘N
  await page.waitFor(`document.activeElement?.id === 'text'`, "the note field focused by ⌘N");
  return `${headings.join(", ")}: ${items.join(", ")}`;
});

await step("an open dialog uploads a file", async () => {
  const file = path.join(WORK, "upload-e2e.txt");
  const content = "Uploaded by the Electron e2e " + Date.now().toString(36);
  fs.writeFileSync(file, content);
  await page.click(await centerOf("#open", "Open file…"));
  const input = await until(() => page.overlayElement((tag, a) => tag === "input" && a.type === "file"), "the open dialog's file picker");
  await page.shot(String(stepNumber).padStart(2, "0") + "-open-dialog");
  await page.cdp("DOM.setFileInputFiles", { files: [file], backendNodeId: input.backendNodeId });
  await page.waitFor(`${LOG}.includes('opened: ') && ${LOG}.includes(${JSON.stringify(content)})`, "main to read the uploaded file", 20_000);
  const line = await page.eval(`${LOG}.split('\\n').find((l) => l.startsWith('opened: '))`);
  assert(line.includes('"name":"upload-e2e.txt"') && line.includes(`"size":${content.length}`), "main read " + line);
  return line.slice(0, 120);
});

await step("a save dialog downloads the file", async () => {
  fs.rmSync(DOWNLOADS, { recursive: true, force: true });
  fs.mkdirSync(DOWNLOADS, { recursive: true });
  await page.cdp("Browser.setDownloadBehavior", { behavior: "allow", downloadPath: DOWNLOADS, eventsEnabled: true })
    .catch(() => page.cdp("Page.setDownloadBehavior", { behavior: "allow", downloadPath: DOWNLOADS }));
  await page.click(await centerOf("#export", "Export…"));
  await page.waitFor(`${LOG}.includes('exported: notes.json')`, "the app to save notes.json", 15_000);
  const saved = await until(() => {
    const files = fs.readdirSync(DOWNLOADS).filter((f) => !f.endsWith(".crdownload"));
    return files.length && files;
  }, "the download in the browser", 20_000, 250);
  const notes = JSON.parse(fs.readFileSync(path.join(DOWNLOADS, saved[0]), "utf8"));
  assert(saved[0] === "notes.json" && Array.isArray(notes) && notes.length === NOTES_AT_START.length + 1, `downloaded ${saved.join(", ")} with ${notes.length} notes`);
  assert(await toastWith("Saved notes.json"), "no Saved notes.json toast");
  return `${saved[0]}, ${notes.length} notes`;
});

await step("openExternal opens a new tab", async () => {
  const before = new Set((await page.targets()).map((t) => t.id));
  await page.click(await centerOf("#link", "Open website"));
  const tab = await until(async () => (await page.targets()).find((t) => !before.has(t.id) && /opentraffic\.dev/.test(t.url)), "a new tab with https://opentraffic.dev", 15_000, 250);
  await sleep(500);
  const fallback = await toastWith("wants to open a link");
  // The opened site can't reach back into the shared page.
  const opener = await new Promise((resolve) => {
    const ws = new WebSocket(tab.webSocketDebuggerUrl);
    const done = (value) => { try { ws.close(); } catch { /* closed */ } resolve(value); };
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression: "window.opener === null", returnByValue: true } }));
    ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id === 1) done(m.result?.result?.value); };
    ws.onerror = () => done("unreachable");
    setTimeout(() => done("no answer"), 10_000);
  });
  await page.closeTarget(tab.id);
  assert(!fallback, "the tab opened, yet the page also shows the link as blocked (“wants to open a link”)");
  assert(opener === true, "the new tab has the shared page as its opener: " + opener);
  return tab.url + ", no opener";
});

await step("a Notification shows as a toast", async () => {
  await page.click(await centerOf("#notify", "Notify"));
  const toast = await until(() => toastWith("Hello from Orbit"), "the notification's toast", 10_000);
  const text = allText(toast.node).replace(/\s+/g, " ").trim();
  assert(text.includes("Orbit"), "the toast says " + text);
  return text;
});

const COMMENT = "E2E check: is Save the right word? " + Date.now().toString(36);
await step("a pinned comment shows in opentraffic comments", async () => {
  const tool = await page.overlayElement((tag, a) => tag === "button" && a["aria-label"] === "Add a comment");
  assert(tool, "no comment tool in the toolbar");
  await page.click(await page.overlayCenter(tool));
  const save = await centerOf("#save", "Save");
  await page.mouse("mouseMoved", save.x, save.y);
  await sleep(200);
  await page.click(save);
  await until(() => page.overlayElement((tag, a) => a.role === "dialog" && a["aria-label"] === "New comment" && !("hidden" in a)), "the comment box");
  await page.cdp("Input.insertText", { text: COMMENT });
  const post = await page.overlayElement((tag, a) => tag === "button" && a["aria-label"] === "Post comment");
  await page.click(await page.overlayCenter(post));
  await until(() => page.overlayElement((tag, a) => a.role === "dialog" && a["aria-label"] === "New comment" && "hidden" in a), "the comment box to close after posting");
  const comment = await until(() => {
    const list = cli(["comments", SHARE], { json: true });
    return (Array.isArray(list) ? list : list.comments || []).find((c) => c.text === COMMENT);
  }, "the comment in `opentraffic comments`", 20_000, 500);
  const pinned = [comment.label, comment.anchor].filter(Boolean).join(" ");
  assert(/save/i.test(pinned), "the comment isn't pinned to Save: " + JSON.stringify(comment).slice(0, 400));
  const text = cli(["comments", SHARE]);
  assert(text.includes(COMMENT), "`opentraffic comments` doesn't list it: " + text.slice(0, 400));
  // Out of the comment mode again.
  await page.key("Escape", "Escape", 27);
  return [comment.label, comment.anchor].filter(Boolean).join(" · ");
});

await step("editing main.js restarts the backend without a page reload", async () => {
  await page.eval(`window.__e2ePage = 1, true`);
  const file = path.join(FIXTURE, "main.js");
  const source = fs.readFileSync(file, "utf8");
  const from = "event.returnValue = { app: app.getVersion(), name: app.getName() };";
  assert(source.includes(from), "the fixture's version:sync handler isn't where it was");
  const started = Date.now();
  fs.writeFileSync(file, source.replace(from, "event.returnValue = { app: app.getVersion(), name: app.getName(), edited: true };"));
  await page.waitFor(`(() => { try { return orbit.versionSync()?.edited === true; } catch { return false; } })()`, "the edited handler to answer", 30_000);
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  assert(await page.eval(`window.__e2ePage === 1`), "the page reloaded");
  await until(() => page.eval(connected), "invoke after the restart", 10_000);
  return `the new main.js answered after ${seconds} s`;
});

await step("Reset app data restores the data", async () => {
  const before = await page.eval(`orbit.listNotes().then((n) => n.length)`);
  assert(before === NOTES_AT_START.length + 1, `${before} notes before the reset`);
  cli(["restart", SHARE, "--reset-data"]);
  const after = await until(async () => { try { const n = await page.eval(`orbit.listNotes().then((n) => n.map((x) => x.text))`); return n.length === NOTES_AT_START.length && n; } catch { return false; } },
    `the ${NOTES_AT_START.length} notes the copy started with`, 30_000, 300);
  assert(JSON.stringify(after) === JSON.stringify(NOTES_AT_START), "the notes after the reset: " + JSON.stringify(after));
  assert(await page.eval(`window.__e2ePage === 1`), "the page reloaded");
  return `${before} -> ${after.length} notes`;
});

await step("a finished app shares under its --name", async () => {
  // `opentraffic share dist/Orbit.app --name …`: built like Forge or electron-builder would, running.
  const built = run(process.execPath, ["package.mjs"], { cwd: FIXTURE });
  assert(built.status === 0 && fs.existsSync(FINISHED_APP), "package.mjs failed: " + (built.stderr || built.stdout).slice(-600));
  const finished = startGroup(path.join(FINISHED_APP, "Contents", "MacOS", "Electron"), [], {
    cwd: FIXTURE, log: path.join(WORK, "orbit-app.log"), extraEnv: { ORBIT_HIDDEN: "1", CFFIXED_USER_HOME: FIXTURE_HOME },
  });
  cleanups.push(() => finished.stop());
  try {
    // A name another share has is refused.
    const taken = await until(() => { const r = cli(["share", FINISHED_APP, "--via", VIA, "--name", SHARE.toUpperCase()], { ok: false }); return !/isn't a running Electron app/.test(r.out) && r; }, "the copy to find the running app", 30_000, 1000);
    assert(taken.status !== 0 && /already exists/.test(taken.out), "a taken name was accepted: " + taken.out.trim().slice(0, 300));
    const out = cli(["share", FINISHED_APP, "--via", VIA, "--name", APP_SHARE]);
    const url = (out.match(/https:\/\/\S+/) || [])[0];
    assert(url, "no public URL in: " + out.trim());
    const status = cli(["status", APP_SHARE], { json: true });
    assert(status.name === APP_SHARE, `the finished app's share is called ${JSON.stringify(status.name)}`);
    await until(async () => (await answers(url)) === 200, "its public URL to answer 200", 60_000, 1000);
    cli(["stop", APP_SHARE]);
    await until(async () => (await answers(url)) !== 200, "its public URL to stop answering", 30_000, 1000);
    cli(["remove", APP_SHARE, "--yes"]);
    return `${status.name} at ${url}; the taken name was refused`;
  } finally {
    await finished.stop();
  }
});

await step("phone view at 390 px", async () => {
  await page.size(390, 844, { mobile: true });
  await loadPage("at 390 px");
  const pill = await boxOf((tag, a) => a["aria-label"] === "Live Collaboration", "the toolbar");
  const bar = await boxOf((tag, a) => tag === "div" && a.class === "bar", "the desktop preview bar");
  // Like most desktop apps' pages, Orbit's has no viewport meta tag: the phone lays it out 980 px wide
  // and shows it zoomed out. The toolbar and the bar must be inside that screen.
  const screen = await page.eval(`({ width: innerWidth, height: innerHeight })`);
  const inside = (box) => box.left >= 0 && box.right <= screen.width + 1 && box.top >= 0 && box.bottom <= screen.height + 1;
  assert(inside(pill), `the collaboration toolbar isn't on the phone's screen (${screen.width}×${screen.height}): ` + JSON.stringify(pill));
  assert(inside(bar), `the desktop preview bar isn't on the phone's screen (${screen.width}×${screen.height}): ` + JSON.stringify(bar));
  assert(await page.eval(visible("#save")), "the app's Save button isn't on screen");
  const width = await page.eval(`document.documentElement.scrollWidth`);
  await page.shot(String(stepNumber).padStart(2, "0") + "-phone-view");
  await page.size(1440, 900);
  await loadPage("back at 1440 px");
  return `laid out ${screen.width}×${screen.height}, page ${width} px wide; toolbar ${Math.round(pill.w)} px, bar ${Math.round(bar.w)} px`;
});

await step("opentraffic restart keeps the page connected", async () => {
  await page.eval(`window.__e2ePage = 2, true`);
  const before = cli(["status", SHARE], { json: true });
  cli(["restart", SHARE]);
  const after = await until(() => { const s = cli(["status", SHARE], { json: true }); return s.state === "running" && s; }, "the share to run again", 60_000, 500);
  assert(after.publicURL === before.publicURL, `the address changed: ${before.publicURL} -> ${after.publicURL}`);
  await until(() => page.eval(connected), "the page to reach the app's main process again", 60_000, 500);
  await page.waitFor(`orbit.versionSync()?.name === 'Orbit'`, "sendSync after the restart", 15_000);
  assert(await page.eval(`window.__e2ePage === 2`), "the page reloaded");
  return after.publicURL;
});

await step("no page errors", async () => {
  const errors = page.errors.filter((e) => !/WebSocket|ERR_|net::/.test(e));
  assert(!errors.length, errors.slice(0, 5).join(" | "));
});

await step("stop", async () => {
  if (KEEP) throw new Skip("--keep leaves the share live");
  cli(["stop", SHARE]);
  const status = await until(() => { const s = cli(["status", SHARE], { json: true }); return s.state === "stopped" && s; }, "the share to stop", 30_000, 500);
  // Its OpenTunnel route is gone: the address no longer reaches the app.
  await until(async () => (await answers(URL_)) !== 200, "the public URL to stop answering", 30_000, 1000);
  return `${status.state}; ${URL_} answers ${await answers(URL_)}`;
});

await finish(0);
