#!/usr/bin/env node
// End-to-end run of Mac app sharing: the Orbit fixture shared through an isolated OpenTraffic copy
// and driven from headless Chrome through its public address, the way a viewer would use it.
// Node only, no npm packages; Chrome is driven over raw CDP. See docs/macapp-e2e.md.
//
//   node script/macapp-e2e.mjs [--work <dir>] [--app <OpenTraffic.app>] [--build] [--via opentunnel]
//                              [--steps a,b,...] [--keep] [--card]
//
// It builds a scratch copy of Examples/macapp-orbit (so the rebuild step can edit its sources), launches
// the OpenTraffic copy with its own home and API socket, shares the fixture with the copy's own command,
// then runs the steps below at 1440 px (and the phone view at 390 px). Every step saves a screenshot in
// <work>/shots; the run stops at the first failure, names the step, and exits 1. At the end the share is
// stopped (which removes its OpenTunnel route) and the copy quits. --card also opens the copy's window
// and presses Allow and Take Back on the share's card through Accessibility (it shows on the screen).
//
// Never use it with the OpenTraffic you use day to day: --app must be a copy with its own bundle
// identifier (docs/macapp-e2e.md builds one), and the script refuses one that is already running.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
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
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 17).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
  process.exit(0);
}
const APP = path.resolve(opt("app", "/Users/Shared/OpenTraffic-e2e/OpenTraffic.app"));
const WORK = path.resolve(opt("work", path.join(os.tmpdir(), "ot-e2e-" + new Date().toISOString().replace(/[-:]/g, "").slice(0, 15))));
const VIA = opt("via", "opentunnel");
const SHARE = opt("name", "Orbit E2E");
const ONLY = opt("steps", "") ? new Set(opt("steps").split(",").map((s) => s.trim())) : null;
const SKIP = new Set(opt("skip", "").split(",").map((s) => s.trim()).filter(Boolean));
const KEEP = flag("keep");
const BUILD = flag("build");
const CARD = flag("card");
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const BUNDLE_ID = "se.medda.opentraffic.e2e";

const SHOTS = path.join(WORK, "shots");
const HOME = path.join(WORK, "home");
const SOCKET = path.join(WORK, "ot.sock");
const FIXTURE = path.join(WORK, "orbit");
const FIXTURE_APP = path.join(FIXTURE, "dist", "Orbit.app");
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
  const lines = ["", "Step                                     Result   Seconds"];
  for (const r of results) lines.push(`${r.name.padEnd(40)} ${(r.skipped ? "skip" : r.ok ? "pass" : "FAIL").padEnd(8)} ${(r.ms / 1000).toFixed(1).padStart(7)}${r.note ? "  " + r.note : ""}`);
  const total = results.reduce((s, r) => s + r.ms, 0);
  lines.push(`${"total".padEnd(40)} ${"".padEnd(8)} ${(total / 1000).toFixed(1).padStart(7)}`);
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

// ---------------------------------------------------------------- the OpenTraffic copy and its command

function run(cmd, args, { cwd = root, timeout = 600_000, extraEnv = {} } = {}) {
  const r = spawnSync(cmd, args, { cwd, env: { ...env, ...extraEnv }, encoding: "utf8", timeout, maxBuffer: 64 << 20 });
  if (r.error) throw new Error(`${path.basename(cmd)}: ${r.error.message}`);
  return r;
}

const copyRunning = () => run("/usr/bin/pgrep", ["-f", APP_BINARY]).stdout.trim().split("\n").filter(Boolean).map(Number);
let launched = false;
let copyPID = null;

// The copy's own command, talking to its socket. Only while the copy runs: the command starts its
// app when nobody answers, and that would be the copy without its own home.
function cli(args, { json = false, ok = true, timeout = 180_000 } = {}) {
  assert(launched && copyRunning().length, "the OpenTraffic copy isn't running");
  const r = run(CLI, json ? [...args, "--json"] : args, { timeout, extraEnv: { OPENTRAFFIC_SOCKET: SOCKET } });
  const out = (r.stdout || "") + (r.stderr || "");
  if (ok && r.status !== 0) throw new Error(`opentraffic ${args.join(" ")} exited ${r.status}: ${out.trim().slice(0, 600)}`);
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
  let target = null;
  for (let i = 0; i < 600 && !target; i++) { // a busy Mac can take a while
    try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page"); } catch { /* not yet */ }
    if (!target) await sleep(100);
  }
  const p = await attachPage(target.webSocketDebuggerUrl);
  // Another viewer, as a second person would be: a browser context of its own, so its own storage and
  // collaboration id (the page asks for control with it). close() disposes of it.
  p.newViewer = async () => {
    const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    const browser = await connectCDP(webSocketDebuggerUrl);
    const { browserContextId } = await browser.cdp("Target.createBrowserContext", {});
    const { targetId } = await browser.cdp("Target.createTarget", { url: "about:blank", browserContextId });
    const q = await attachPage(`ws://127.0.0.1:${port}/devtools/page/${targetId}`);
    q.close = async () => {
      q.ws.close();
      await browser.cdp("Target.disposeBrowserContext", { browserContextId }).catch(() => {});
      browser.ws.close();
    };
    return q;
  };
  return p;
}

// A CDP connection: cdp(method, params) and event listeners.
async function connectCDP(url) {
  const ws = new WebSocket(url);
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
  return { ws, cdp, listeners };
}

// A page target, with what the steps do to it.
async function attachPage(url) {
  const { ws, cdp, listeners } = await connectCDP(url);
  const errors = [];
  listeners.push((m) => {
    if (m.method === "Runtime.exceptionThrown") errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
    if (m.method === "Runtime.consoleAPICalled" && m.params.type === "error") errors.push(m.params.args.map((a) => a.value ?? a.description).join(" "));
  });
  await cdp("Page.enable");
  await cdp("Runtime.enable");
  await cdp("Emulation.setFocusEmulationEnabled", { enabled: true });

  const p = {
    cdp, errors, ws,
    async eval(expression) {
      const r = await cdp("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
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
    async tap(pt) {
      await cdp("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: pt.x, y: pt.y }] });
      await cdp("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
    },
    async key(k, code, vk, { text, modifiers = 0 } = {}) {
      await cdp("Input.dispatchKeyEvent", { type: text ? "keyDown" : "rawKeyDown", key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers, ...(text ? { text, unmodifiedText: text } : {}) });
      await cdp("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers });
    },
    async size(width, height, { mobile = false } = {}) {
      await cdp("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: mobile ? 3 : 1, mobile });
      await cdp("Emulation.setTouchEmulationEnabled", { enabled: mobile, maxTouchPoints: mobile ? 5 : 1 });
    },
    scheme: (value) => cdp("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value }] }),
    // The collaboration overlay lives in closed shadow roots, which only DevTools can see into.
    async overlayElement(match) {
      const { root: doc } = await cdp("DOM.getDocument", { depth: -1, pierce: true });
      const found = [];
      const walk = (n) => {
        const attrs = {};
        for (let i = 0; i + 1 < (n.attributes || []).length; i += 2) attrs[n.attributes[i]] = n.attributes[i + 1];
        if (match(n.nodeName.toLowerCase(), attrs)) found.push({ nodeId: n.nodeId, backendNodeId: n.backendNodeId, attrs });
        for (const c of [...(n.children || []), ...(n.shadowRoots || [])]) walk(c);
      };
      walk(doc);
      return found[0] || null;
    },
    async overlayCenter(el) {
      const { model } = await cdp("DOM.getBoxModel", { backendNodeId: el.backendNodeId });
      const q = model.border;
      return { x: (q[0] + q[4]) / 2, y: (q[1] + q[5]) / 2, w: model.width, h: model.height };
    },
  };
  return p;
}

// ---------------------------------------------------------------- the viewer page

// Expressions over the viewer's accessibility layer (macapp-viewer.js): one element per AX node, with
// data-key (its path), data-role and aria-label, inside .otm-window[data-kind=main|sheet|popover|…].
const NODES = (kind = "main") => `[...document.querySelectorAll('.otm-window[data-kind="${kind}"] .otm-node')]`;
const FIND = (role, label, kind = "main", exact = true) =>
  `${NODES(kind)}.find((el) => el.dataset.role === ${JSON.stringify(role)} && (${exact} ? el.getAttribute('aria-label') === ${JSON.stringify(label)} : (el.getAttribute('aria-label') || '').includes(${JSON.stringify(label)})))`;
const HAS_TEXT = (label, kind = "main") => `!!${FIND("AXStaticText", label, kind)}`;
const ROWS = `${NODES()}.filter((el) => /\\/Outline:\\/Row:(#\\d+)?$/.test(el.dataset.key)).length`;
const ROW_OF = (customer) => `(${FIND("AXStaticText", customer)} || {}).dataset?.key?.replace(/\\/Cell:.*$/, '')`;
const visible = (expr) => `(() => { const el = ${expr}; if (!el) return null; const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 ? { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height, top: r.top, left: r.left } : null; })()`;

async function centerOf(expr, what, timeout = 10_000) {
  return until(() => page.eval(visible(expr)), what + " on the page", timeout);
}
const openCount = () => page.eval(`(${NODES()}.find((el) => el.dataset.role === 'AXStaticText' && / open$/.test(el.getAttribute('aria-label') || '')) || null)?.getAttribute('aria-label') ?? null`);

// A surface (sheet, alert, popover) is on screen for the viewer once its canvas has pixels; give the
// app's presentation animation a moment more, as a person would take, before clicking in it.
async function surfaceShown(kind) {
  await page.waitFor(`(() => { const c = document.querySelector('.otm-window[data-kind="${kind}"] canvas'); if (!c || !c.width) return false;
    const d = c.getContext('2d').getImageData(Math.floor(c.width / 2), Math.floor(c.height / 2), 1, 1).data; return d[3] === 255; })()`, `the ${kind}'s pixels`, 10_000);
  await sleep(500);
}

// ---------------------------------------------------------------- the run

console.log(`Mac app end-to-end: ${APP} via ${VIA}; work folder ${WORK}`);
fs.mkdirSync(WORK, { recursive: true });

await step("display is healthy", async () => {
  // A slow window server makes every later number and timeout meaningless (docs/macapp-window-hiding.md).
  const probe = path.join(WORK, "display-probe");
  if (!fs.existsSync(probe)) {
    fs.writeFileSync(probe + ".swift", 'import CoreGraphics\nimport Foundation\nlet t = Date()\nvar n: UInt32 = 0\nCGGetActiveDisplayList(0, nil, &n)\nprint(Int(Date().timeIntervalSince(t) * 1000))\n');
    const c = run("/usr/bin/xcrun", ["swiftc", "-O", probe + ".swift", "-o", probe]);
    assert(c.status === 0, "couldn't build the display probe: " + c.stderr);
  }
  const ms = Number(run(probe, []).stdout.trim());
  assert(ms < 1000, `CGGetActiveDisplayList took ${ms} ms; wait until it answers in well under a second`);
  return `CGGetActiveDisplayList ${ms} ms`;
}, { always: true });

await step("build the fixture", async () => {
  // A scratch copy of Examples/macapp-orbit: the rebuild step edits its sources.
  fs.rmSync(FIXTURE, { recursive: true, force: true });
  fs.mkdirSync(FIXTURE, { recursive: true });
  for (const item of ["Package.swift", "Sources", "package.sh"]) fs.cpSync(path.join(root, "Examples", "macapp-orbit", item), path.join(FIXTURE, item), { recursive: true });
  const r = run("/bin/sh", [path.join(FIXTURE, "package.sh")], { cwd: FIXTURE });
  assert(r.status === 0 && fs.existsSync(FIXTURE_APP), "package.sh failed: " + (r.stderr || r.stdout).slice(-800));
}, { always: true });

await step("build the OpenTraffic copy", async () => {
  if (!BUILD) {
    assert(fs.existsSync(APP_BINARY), `no OpenTraffic copy at ${APP}; run with --build (see docs/macapp-e2e.md)`);
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
  copyPID = pid;
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

let URL_ = null;
await step("share the fixture", async () => {
  const help = cli(["help", "share"]);
  const collab = help.includes("--collab") ? ["--collab"] : [];
  const out = cli(["share", FIXTURE_APP, "--via", VIA, "--name", SHARE, ...collab]);
  URL_ = (out.match(/https:\/\/\S+/) || [])[0];
  assert(URL_, "no public URL in: " + out.trim());
  cleanups.push(async () => {
    if (KEEP) return console.log(`(--keep) ${SHARE} stays live at ${URL_}`);
    // Stopping removes the share's OpenTunnel route; removing it drops its settings and comments.
    try { cli(["stop", SHARE]); } catch (e) { console.log("cleanup: " + e.message); }
    try { cli(["remove", SHARE, "--yes"]); } catch (e) { console.log("cleanup: " + e.message); }
  });
  const status = await until(() => { const s = cli(["status", SHARE], { json: true }); return s.macApp?.state === "running" && s.collaboration && s; }, "the Mac app to run with collaboration on", 60_000);
  await until(async () => (await fetch(URL_)).status === 200, "the public URL to answer 200", 60_000, 1000);
  return `${URL_} (${status.macApp.name}, data ${status.macApp.data})`;
}, { always: true });

page = await startChrome();
await page.size(1440, 900);
await page.scheme("light");

await step("page loads with the collab toolbar and the window", async () => {
  await page.cdp("Page.navigate", { url: URL_ });
  await page.waitFor(`document.getElementById('otm-dot')?.dataset.state === 'live'`, "the viewer to connect", 30_000);
  await page.waitFor(`${NODES()}.length > 60 && ${HAS_TEXT("Orbit Orders")}`, "Orbit's window and its elements", 30_000);
  await page.waitFor(`document.body.dataset.appearance === 'light'`, "the light appearance the browser asks for", 30_000);
  const name = await page.eval(`document.getElementById('otm-name').textContent`);
  assert(name === "Orbit", "the bar names " + JSON.stringify(name));
  assert(await page.eval(`!!document.querySelector('opentraffic-collab')`), "no collaboration overlay on the page");
  const pill = await page.overlayElement((tag, a) => a["aria-label"] === "Live Collaboration");
  assert(pill, "no Live Collaboration toolbar in the overlay");
  // The canvas has the app's pixels: the title bar text area isn't transparent.
  await page.waitFor(`(() => { const c = document.querySelector('.otm-window[data-kind="main"] canvas'); if (!c || !c.width) return false;
    const d = c.getContext('2d').getImageData(Math.floor(c.width / 2), Math.floor(c.height / 2), 1, 1).data; return d[3] === 255; })()`, "the window's pixels", 15_000);
  assert(await page.eval(ROWS) === 30, "orders listed: " + await page.eval(ROWS));
  return `${await page.eval(`${NODES()}.length`)} elements`;
});

const COMMENT = "E2E check: is this the right label? " + Date.now().toString(36);
await step("the picker selects Add Order with a label naming it", async () => {
  const tool = await page.overlayElement((tag, a) => tag === "button" && a["aria-label"] === "Add a comment");
  assert(tool, "no comment tool in the toolbar");
  await page.click(await page.overlayCenter(tool));
  const add = await centerOf(FIND("AXButton", "Add Order"), "Add Order");
  await page.mouse("mouseMoved", add.x, add.y);
  const hit = await page.eval(`(() => { const el = document.elementFromPoint(${add.x}, ${add.y}); return el && el.getAttribute('aria-label') + '|' + el.dataset.role; })()`);
  assert(hit === "Add Order|AXButton", "the picker would pick " + hit);
  await page.click(add);
  const composer = await until(() => page.overlayElement((tag, a) => a.role === "dialog" && a["aria-label"] === "New comment" && !("hidden" in a)), "the comment box");
  assert(composer, "no comment box");
  await page.cdp("Input.insertText", { text: COMMENT });
  const post = await page.overlayElement((tag, a) => tag === "button" && a["aria-label"] === "Post comment");
  await page.click(await page.overlayCenter(post));
  await until(() => page.overlayElement((tag, a) => a.role === "dialog" && a["aria-label"] === "New comment" && "hidden" in a), "the comment box to close after posting");
});

await step("the pinned comment is in opentraffic comments with the element's label", async () => {
  const comment = await until(() => {
    const list = cli(["comments", SHARE], { json: true });
    const all = Array.isArray(list) ? list : list.comments || [];
    return all.find((c) => c.text === COMMENT);
  }, "the comment in `opentraffic comments`", 20_000, 500);
  assert(comment.label === "Button “Add Order”", "its label is " + JSON.stringify(comment.label));
  const text = cli(["comments", SHARE]);
  assert(text.includes("Add Order"), "`opentraffic comments` doesn't show the label: " + text.slice(0, 400));
  return comment.label;
});

await step("dark appearance", async () => {
  // The app follows the first viewer's color scheme (light here) for the whole session; the host's
  // choice overrides it. Dark is only possible while this Mac uses Dark (docs/macapp-mirror-protocol.md).
  const macDark = run("/usr/bin/defaults", ["read", "-g", "AppleInterfaceStyle"]).stdout.trim() === "Dark";
  if (!macDark) throw new Skip("this Mac uses Light, and a shared app can only be dark while the Mac is");
  cli(["set", SHARE, "--appearance", "dark"]);
  await page.waitFor(`document.body.dataset.appearance === 'dark' && ${NODES()}.length > 60`, "the app to restart in dark", 30_000);
  // The window's background pixels are dark now.
  const darkPixel = `(() => { const c = document.querySelector('.otm-window[data-kind="main"] canvas'); if (!c || !c.width) return false;
    const d = c.getContext('2d').getImageData(Math.floor(c.width * 0.7), Math.floor(c.height * 0.8), 1, 1).data; return d[3] === 255 && d[0] + d[1] + d[2] < 200; })()`;
  await page.waitFor(darkPixel, "dark pixels", 15_000);
  await page.shot(String(stepNumber).padStart(2, "0") + "-dark-appearance-dark");
  cli(["set", SHARE, "--appearance", "viewer"]);
  await page.waitFor(`document.body.dataset.appearance === 'light' && ${NODES()}.length > 60`, "the app back in the viewer's light", 30_000);
  await page.waitFor(`!${darkPixel}`, "light pixels again", 15_000);
});

await step("selecting a row shows its order", async () => {
  const row = await centerOf(`${NODES()}.find((el) => el.dataset.key.includes('/Row') && el.getAttribute('aria-label') === 'Grace Hopper')`, "Grace Hopper's row");
  await page.click(row);
  await page.waitFor(`${HAS_TEXT("Order #1003 · Shipped")}`, "Grace Hopper's order (#1003) in the detail pane", 10_000);
});

await step("the toggle changes the app", async () => {
  // The order's total, outside the list: an amount like "131,00 US$" or "$131.00".
  const total = `(${NODES()}.find((el) => el.dataset.role === 'AXStaticText' && !el.dataset.key.includes('/ScrollArea:') && /\\d[.,]\\d\\d/.test(el.getAttribute('aria-label') || '')) || null)?.getAttribute('aria-label')`;
  const before = await page.eval(`${FIND("AXCheckBox", "Express shipping")}.getAttribute('aria-checked')`);
  const totalBefore = await page.eval(total);
  assert(totalBefore, "no total in the detail pane");
  await page.click(await centerOf(FIND("AXCheckBox", "Express shipping"), "Express shipping"));
  const want = before === "true" ? "false" : "true";
  // The app's truth: the checkbox stays flipped and the total takes in (or drops) the express fee.
  await page.waitFor(`${FIND("AXCheckBox", "Express shipping")}.getAttribute('aria-checked') === '${want}' && ${total} !== ${JSON.stringify(totalBefore)}`,
    "Express shipping " + want + " with a new total", 10_000);
  await sleep(600);
  assert(await page.eval(`${FIND("AXCheckBox", "Express shipping")}.getAttribute('aria-checked')`) === want, "the checkbox went back");
  return `total ${totalBefore} -> ${await page.eval(total)}`;
});

await step("the stepper changes the quantity", async () => {
  const quantity = `(${NODES()}.find((el) => el.dataset.role === 'AXStaticText' && /^Quantity: \\d+$/.test(el.getAttribute('aria-label') || '')) || null)?.getAttribute('aria-label')`;
  const before = Number((await page.eval(quantity) || "").replace(/\D/g, ""));
  assert(before >= 1 && before < 20, "quantity " + before);
  const up = await centerOf(`${NODES()}.find((el) => /\\/Incrementor:\\/Button:$/.test(el.dataset.key))`, "the stepper's up arrow");
  await page.click(up);
  await page.waitFor(HAS_TEXT(`Quantity: ${before + 1}`), `Quantity: ${before + 1}`, 10_000);
  return `${before} -> ${before + 1}`;
});

await step("the segmented filter filters the list", async () => {
  await page.click(await centerOf(FIND("AXRadioButton", "Shipped"), "the Shipped segment"));
  await page.waitFor(`${ROWS} === 10 && ${FIND("AXRadioButton", "Shipped")}.getAttribute('aria-checked') === 'true'`, "10 shipped orders", 10_000);
  await page.click(await centerOf(FIND("AXRadioButton", "All"), "the All segment"));
  await page.waitFor(`${ROWS} === 30`, "all 30 orders again", 10_000);
});

const CUSTOMER = "Eve Example";
await step("typing a customer and Add Order adds the order", async () => {
  const field = await centerOf(`${NODES()}.find((el) => el.dataset.key === '/Window:/Group:/TextField:')`, "the New customer field");
  await page.click(field);
  await page.waitFor(`document.activeElement?.dataset?.key === '/Window:/Group:/TextField:'`, "the field to take focus");
  await page.cdp("Input.insertText", { text: CUSTOMER });
  await page.waitFor(`${NODES()}.find((el) => el.dataset.key === '/Window:/Group:/TextField:')?.value === ${JSON.stringify(CUSTOMER)}`, "the typed name in the field");
  await sleep(400); // the app's own field has it too before the button is pressed
  await page.click(await centerOf(FIND("AXButton", "Add Order"), "Add Order"));
  await page.waitFor(`${ROWS} === 31 && ${HAS_TEXT(CUSTOMER)}`, "a 31st order for " + CUSTOMER, 10_000);
});

await step("scrolling the long list reaches its end", async () => {
  const list = await centerOf(`${NODES()}.find((el) => el.dataset.role === 'AXOutline')`, "the order list");
  const last = visible(FIND("AXStaticText", "Evelyn Berezin"));
  assert(!(await page.eval(last)), "the last order is already in view");
  for (let i = 0; i < 40 && !(await page.eval(last)); i++) {
    await page.mouse("mouseWheel", list.x, list.y, { deltaX: 0, deltaY: 240 });
    await sleep(120);
  }
  await page.waitFor(last, "Evelyn Berezin (order 30) to scroll into view", 10_000);
});

await step("a sheet opens and closes", async () => {
  await page.click(await centerOf(FIND("AXButton", "Edit Address…"), "Edit Address…"));
  await page.waitFor(`!!${FIND("AXButton", "Cancel", "sheet")}`, "the address sheet with its Cancel button", 10_000);
  await surfaceShown("sheet");
  await page.shot(String(stepNumber).padStart(2, "0") + "-sheet-open");
  await page.click(await centerOf(FIND("AXButton", "Cancel", "sheet"), "the sheet's Cancel"));
  await page.waitFor(`!document.querySelector('.otm-window[data-kind="sheet"]')`, "the sheet to close", 10_000);
});

await step("an alert opens and is dismissed", async () => {
  await page.click(await centerOf(FIND("AXButton", "Delete Order"), "Delete Order"));
  const kind = await until(() => page.eval(`["alert", "sheet", "dialog"].find((k) => [...document.querySelectorAll('.otm-window[data-kind="' + k + '"] .otm-node')]
    .some((el) => el.dataset.role === 'AXButton' && el.getAttribute('aria-label') === 'Cancel')) || null`), "the delete alert with its Cancel button");
  await surfaceShown(kind);
  await page.shot(String(stepNumber).padStart(2, "0") + "-alert-open");
  await page.click(await centerOf(FIND("AXButton", "Cancel", kind), "the alert's Cancel"));
  await page.waitFor(`!document.querySelector('.otm-window[data-kind="${kind}"]')`, "the alert to close", 10_000);
  assert(await page.eval(ROWS) === 31, "the order was deleted anyway");
  return "shown as " + kind;
});

await step("a popover opens and is dismissed", async () => {
  await page.click(await centerOf(FIND("AXButton", "Tracking"), "Tracking"));
  await page.waitFor(`!!document.querySelector('.otm-window[data-kind="popover"]') && ${NODES("popover")}.length > 1`, "the tracking popover", 10_000);
  await surfaceShown("popover");
  await page.shot(String(stepNumber).padStart(2, "0") + "-popover-open");
  await page.key("Escape", "Escape", 27);
  await page.waitFor(`!document.querySelector('.otm-window[data-kind="popover"]')`, "the popover to close", 10_000);
});

await step("the app menu's action runs", async () => {
  const title = `[...document.querySelectorAll('#otm-bar .otm-menus .otm-menu-title')].find((b) => b.textContent === 'Orders')`;
  await page.click(await centerOf(title, "the Orders menu title"));
  const item = `[...document.querySelectorAll('.otm-menu-bar .otm-menu-item')].find((b) => b.querySelector('.otm-menu-label')?.textContent === 'Mark All Shipped')`;
  await page.click(await centerOf(item, "Orders > Mark All Shipped"));
  await page.waitFor(HAS_TEXT("0 open"), "0 open orders", 10_000);
});

await step("a context menu item runs", async () => {
  // The name in the list (the detail pane's title has it too).
  const name = await centerOf(`${NODES()}.find((el) => el.dataset.key.includes('/Row') && el.getAttribute('aria-label') === ${JSON.stringify(CUSTOMER)})`, CUSTOMER + "'s row");
  const before = await page.eval(ROWS);
  await page.click(name, "right");
  const item = `[...document.querySelectorAll('.otm-menu-context .otm-menu-item')].find((b) => b.querySelector('.otm-menu-label')?.textContent === 'Duplicate')`;
  await page.click(await centerOf(item, "the row's context menu with Duplicate", 10_000));
  await page.waitFor(`${ROWS} === ${before + 1}`, `${before + 1} orders after Duplicate`, 10_000);
});

await step("viewport resize resizes the window", async () => {
  // The window's own size in points (the canvas's CSS size at scale 1) and how far the page scales it down.
  const size = () => page.eval(`(() => { const c = document.querySelector('.otm-window[data-kind="main"] canvas');
    const w = parseFloat(c.style.width); return { points: Math.round(w), shown: Math.round(c.getBoundingClientRect().width) }; })()`);
  const before = await size();
  await page.size(1100, 760);
  // Not merely scaled down: the app's window takes the browser's width (1100 less the page's margins).
  const after = await until(async () => { const s = await size(); return s.points < before.points - 200 && s.points <= 1100 && Math.abs(s.shown - s.points) <= 2 && s; },
    "the app's window to be resized to the smaller browser", 15_000);
  await page.shot(String(stepNumber).padStart(2, "0") + "-viewport-1100");
  await page.size(1440, 900);
  await until(async () => (await size()).points >= before.points - 2, "the window to grow back", 15_000);
  return `${before.points} -> ${after.points} -> ${(await size()).points} points`;
});

await step("phone view at 390 px", async () => {
  await page.size(390, 844, { mobile: true });
  await page.waitFor(`document.body.dataset.view === 'simple'`, "the Simple view", 15_000);
  const add = `[...document.querySelectorAll('#otm-simple .otm-s-node')].find((el) => el.textContent.trim() === 'Add Order' && el.getClientRects().length)`;
  await page.waitFor(`!!(${add})`, "Add Order in the Simple view", 10_000);
  // The orders the app has laid out, each with its customer; none blank.
  const items = await page.eval(`[...document.querySelectorAll('#otm-simple [role=listitem]')].map((el) => el.textContent.trim())`);
  assert(items.length >= 10 && items.every(Boolean), "the Simple view's list items: " + JSON.stringify(items.slice(0, 40)));
  assert(items.some((t) => t.includes("Evelyn Berezin")), "the scrolled-to order isn't listed: " + JSON.stringify(items.slice(0, 40)));
  const width = await page.eval(`document.documentElement.scrollWidth`);
  assert(width <= 390, "the page is wider than the phone: " + width);
  await page.eval(`window.scrollTo(0, 0), true`);
  await page.shot(String(stepNumber).padStart(2, "0") + "-phone-view-at-390-px-top");
  await page.size(1440, 900);
  await page.waitFor(`document.body.dataset.view === 'window'`, "the window view again", 15_000);
  return `${items.length} orders as list items`;
});

await step("watch-only mode blocks input", async () => {
  const set = cli(["help", "set"]);
  if (!set.includes("--control")) throw new Error("`opentraffic set` has no --control option to switch the share to watch only");
  cli(["set", SHARE, "--control", "watch-only"]);
  await page.waitFor(`document.body.dataset.control === 'no' && document.querySelector('.otm-control-text')?.textContent === 'Watching only'`, "the bar to say Watching only", 10_000);
  const before = await page.eval(`${FIND("AXCheckBox", "Express shipping")}.getAttribute('aria-checked')`);
  await page.click(await centerOf(FIND("AXCheckBox", "Express shipping"), "Express shipping"));
  await sleep(1500);
  assert(await page.eval(`${FIND("AXCheckBox", "Express shipping")}.getAttribute('aria-checked')`) === before, "a watcher's click changed the app");
  cli(["set", SHARE, "--control", "everyone"]);
  await page.waitFor(`document.body.dataset.control === 'yes'`, "control back", 10_000);
});

// Ask to control: a second viewer (a browser of its own) asks, the host answers from the terminal.
const ASKER = "E2E Asker";
const EXPRESS = FIND("AXCheckBox", "Express shipping");
const checked = (pg) => pg.eval(`${EXPRESS}?.getAttribute('aria-checked') ?? null`);
const controlBar = (pg) => pg.eval(`(() => { const c = document.querySelector('.otm-control'); return c && !c.hidden
  ? { text: document.querySelector('.otm-control-text').textContent, button: document.querySelector('.otm-control-button').hidden ? '' : document.querySelector('.otm-control-button').textContent, you: document.body.dataset.control } : { text: '', button: '', you: document.body.dataset.control }; })()`);
const barIs = (pg, text, button, what, timeout = 15_000) => until(async () => { const b = await controlBar(pg); return b.text === text && b.button === button && b; }, what, timeout);
const clickIn = async (pg, expr, what) => pg.click(await until(() => pg.eval(visible(expr)), what + " on the page", 10_000));
// A click on Express shipping that must not reach the app: the box stays as it was.
async function clickIgnored(pg, who) {
  const before = await checked(pg);
  await clickIn(pg, EXPRESS, "Express shipping");
  await sleep(1500);
  const now = await checked(pg), other = await checked(page);
  assert(now === before && other === before, `${who}'s click changed the app (${before} -> ${now}, first page ${other})`);
}
const controlStatus = () => cli(["status", SHARE], { json: true }).macApp?.control;
// The second viewer: a browser of its own at the same size, named ASKER in the collaboration overlay.
async function openAsker() {
  asker = await page.newViewer();
  await asker.cdp("Page.enable");
  await asker.cdp("Runtime.enable");
  await asker.cdp("Emulation.setFocusEmulationEnabled", { enabled: true });
  await asker.size(1440, 900);
  await asker.scheme("light");
  await asker.cdp("Page.navigate", { url: URL_ });
  await asker.waitFor(`document.getElementById('otm-dot')?.dataset.state === 'live' && ${NODES()}.length > 60`, "the second viewer to connect", 30_000);
  await asker.eval(`localStorage.setItem('__opentraffic_collab_name', ${JSON.stringify(ASKER)}), true`);
  await barIs(asker, "Watching", "Request Control", "Request Control on the second page");
}
async function askForControl() {
  await clickIn(asker, `document.querySelector('.otm-control-button')`, "Request Control");
  await barIs(asker, "Asked the host…", "Cancel", "the second page to wait for the host");
}
let asker = null, watcher = null, watched = "";
const shotAsker = async (suffix) => asker && asker.shot(`${String(stepNumber).padStart(2, "0")}-${suffix}-asker`).catch(() => {});
cleanups.push(async () => {
  if (watcher) watcher.kill();
  if (asker) await asker.close().catch(() => {});
});

await step("ask to control: a second viewer asks", async () => {
  if (!cli(["help"]).includes("control <share>")) throw new Error("`opentraffic control` doesn't exist in this copy");
  // `opentraffic watch` hears of the request.
  watcher = spawn(CLI, ["watch", SHARE, "--json"], { env: { ...env, OPENTRAFFIC_SOCKET: SOCKET }, stdio: ["ignore", "pipe", "ignore"] });
  watcher.stdout.on("data", (d) => { watched += d; });
  cli(["set", SHARE, "--control", "ask"]);
  await barIs(page, "Watching", "Request Control", "the first page to watch, with Request Control");
  let s = controlStatus();
  assert(s?.mode === "askToControl" && !s.holder && !s.requests.length, "status before anyone asks: " + JSON.stringify(s));
  await openAsker();
  await sleep(500); // the watch has its cursor
  await askForControl();
  s = await until(() => { const c = controlStatus(); return c?.requests?.length === 1 && c; }, "the request in `opentraffic status --json`", 10_000, 300);
  const request = s.requests[0];
  assert(request.name === ASKER && Number.isInteger(request.viewer) && Math.abs(Date.parse(request.since) - Date.now()) < 60_000, "the request: " + JSON.stringify(request));
  const text = cli(["status", SHARE]);
  assert(/Control\s+ask to control · only you control Orbit/.test(text) && text.includes(`${ASKER} (${request.viewer}) asks to control it`), "`opentraffic status` says: " + text);
  const event = await until(() => watched.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .find((e) => e?.type === "control.requested"), "`opentraffic watch` to report the request", 10_000, 200);
  assert(event.person === ASKER && event.viewer === request.viewer && event.share === SHARE, "the watched event: " + JSON.stringify(event));
  await shotAsker("ask-to-control-a-second-viewer-asks");
  return `${ASKER} is viewer ${request.viewer}; watch: ${JSON.stringify(event).slice(0, 120)}`;
});

await step("control allow lets the asker click, not the first page", async () => {
  const viewer = controlStatus().requests[0].viewer;
  const out = cli(["control", SHARE, "allow", String(viewer)]);
  assert(out.includes(`${ASKER} has control of Orbit`), "`control allow` says: " + out.trim());
  await barIs(asker, "You have control", "Give Back", "the second page to get control");
  await barIs(page, `${ASKER} has control`, "Request Control", "the first page to see who has control");
  const s = controlStatus();
  assert(s.holder?.name === ASKER && s.holder.viewer === viewer && s.holder.connected === true && !s.requests.length, "status with control given: " + JSON.stringify(s));
  // The asker's click reaches the app; the first page sees it too.
  const before = await checked(asker);
  const want = before === "true" ? "false" : "true";
  await clickIn(asker, EXPRESS, "Express shipping on the second page");
  await asker.waitFor(`${EXPRESS}?.getAttribute('aria-checked') === '${want}'`, "the asker's click to change Express shipping", 10_000);
  await page.waitFor(`${EXPRESS}?.getAttribute('aria-checked') === '${want}'`, "the first page to see the change", 10_000);
  // The first page still only watches.
  await clickIgnored(page, "the first page");
  await shotAsker("control-allow");
  return `Express shipping ${before} -> ${want} by the asker; the first page's click ignored`;
});

await step("control take-back blocks the asker again", async () => {
  const out = cli(["control", SHARE, "take-back"]);
  assert(out.includes("Took control of Orbit back"), "`control take-back` says: " + out.trim());
  await barIs(asker, "Watching", "Request Control", "the second page to lose control");
  await barIs(page, "Watching", "Request Control", "the first page to see nobody has control");
  assert(!controlStatus().holder, "status still has a holder: " + JSON.stringify(controlStatus()));
  await clickIgnored(asker, "the asker");
  // Nobody to take control from now.
  const again = cli(["control", SHARE, "take-back"], { ok: false });
  assert(again.includes("Nobody has control"), "a second take-back says: " + again.trim());
  await shotAsker("control-take-back");
});

await step("control deny shows the asker the refusal", async () => {
  await clickIn(asker, `document.querySelector('.otm-control-button')`, "Request Control");
  await barIs(asker, "Asked the host…", "Cancel", "the second page to ask again");
  await until(() => controlStatus()?.requests?.length === 1, "the new request in the status", 10_000, 300);
  const out = cli(["control", SHARE, "deny", ASKER]);
  assert(out.includes(`Turned down ${ASKER}'s request`), "`control deny` says: " + out.trim());
  await barIs(asker, "The host said not now", "Request Control", "the refusal on the second page");
  const s = controlStatus();
  assert(!s.requests.length && !s.holder, "status after deny: " + JSON.stringify(s));
  const none = cli(["control", SHARE, "allow"], { ok: false });
  assert(none.includes("Nobody is asking"), "allow without a request says: " + none.trim());
  await clickIgnored(asker, "the refused asker");
  await shotAsker("control-deny");
  cli(["set", SHARE, "--control", "everyone"]);
  await page.waitFor(`document.body.dataset.control === 'yes'`, "control back for everyone", 10_000);
  await asker.waitFor(`document.body.dataset.control === 'yes'`, "control back for the second page", 10_000);
  await asker.close();
  asker = null;
  watcher.kill();
  watcher = null;
});

// The card's buttons, through Accessibility: a helper that opens the copy's window on the share with a
// GetURL Apple event to the copy's pid (never through Launch Services, which could start another copy
// without its home and socket), reads the window and presses buttons by their titles.
const CARD_PROBE_SOURCE = `import ApplicationServices
import Foundation
let a = CommandLine.arguments
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func texts(_ e: AXUIElement) -> [String] { [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attr(e, $0) as? String } }
func find(_ e: AXUIElement, _ depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
  if match(e) { return e }
  guard depth < 40 else { return nil }
  for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, depth + 1, match) { return f } }
  return nil
}
if a[1] == "trusted" { print(AXIsProcessTrusted()); exit(0) }
let pid = pid_t(a[2])!
let windows = (attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
switch a[1] {
case "show":
  let e = NSAppleEventDescriptor(eventClass: AEEventClass(0x4755524C), eventID: AEEventID(0x4755524C), targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                 returnID: AEReturnID(-1), transactionID: AETransactionID(0))
  e.setParam(NSAppleEventDescriptor(string: a[3]), forKeyword: AEKeyword(0x2D2D2D2D))
  do { _ = try e.sendEvent(options: [.noReply, .neverInteract], timeout: 10) } catch { print(error); exit(1) }
case "has":
  exit(windows.contains { find($0) { texts($0).contains { $0.contains(a[3]) } } != nil } ? 0 : 2)
case "press":
  for w in windows { if let b = find(w, 0, { attr($0, kAXRoleAttribute) as? String == "AXButton" && texts($0).contains(a[3]) }) {
    exit(AXUIElementPerformAction(b, kAXPressAction as CFString) == .success ? 0 : 1) } }
  exit(2)
case "enabled":
  for w in windows { if let b = find(w, 0, { attr($0, kAXRoleAttribute) as? String == "AXButton" && texts($0).contains(a[3]) }) {
    exit(attr(b, kAXEnabledAttribute) as? Bool == true ? 0 : 1) } }
  exit(2)
case "close":
  for w in windows { if let b = attr(w, kAXCloseButtonAttribute) { _ = AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) } }
default: exit(64)
}
`;
function cardProbe(...args) {
  const probe = path.join(WORK, "card-probe");
  if (!fs.existsSync(probe)) {
    fs.writeFileSync(probe + ".swift", CARD_PROBE_SOURCE);
    const c = run("/usr/bin/xcrun", ["swiftc", "-O", probe + ".swift", "-o", probe]);
    assert(c.status === 0, "couldn't build the card probe: " + c.stderr);
  }
  return run(probe, args.map(String));
}

// Opens the copy's window on the share and waits for its card. A window that opens on another Space
// (a full-screen app is in front) shows Accessibility no content: the step is skipped then.
async function showCard() {
  if (cardProbe("trusted").stdout.trim() !== "true") throw new Skip("this terminal has no Accessibility permission to press the card's buttons");
  const shown = cardProbe("show", copyPID, "opentraffic://show?name=" + encodeURIComponent(SHARE));
  assert(shown.status === 0, "couldn't open the copy's window: " + shown.stdout + shown.stderr);
  cleanups.push(async () => { cardProbe("close", copyPID); });
  try {
    await until(() => cardProbe("has", copyPID, "Live Collaboration").status === 0, "the card", 8_000, 300);
  } catch {
    cardProbe("close", copyPID);
    throw new Skip("the copy's window opened on another Space (a full-screen app is in front), where Accessibility can't read it");
  }
}

await step("the card's Allow and Take Back", async () => {
  if (!CARD) throw new Skip("--card opens the copy's window and presses the card's buttons through Accessibility");
  await showCard();
  cli(["set", SHARE, "--control", "ask"]);
  await openAsker();
  await askForControl();
  await until(() => cardProbe("has", copyPID, `${ASKER} asks for control`).status === 0, `“${ASKER} asks for control” on the card`, 15_000, 300);
  assert(cardProbe("press", copyPID, "Allow").status === 0, "no Allow button on the card");
  await barIs(asker, "You have control", "Give Back", "the second page to get control from the card");
  assert(controlStatus().holder?.name === ASKER, "status after Allow: " + JSON.stringify(controlStatus()));
  await until(() => cardProbe("has", copyPID, `${ASKER} has control of Orbit`).status === 0, `“${ASKER} has control of Orbit” on the card`, 10_000, 300);
  assert(cardProbe("press", copyPID, "Take Back").status === 0, "no Take Back button on the card");
  await barIs(asker, "Watching", "Request Control", "the second page to lose control from the card");
  assert(!controlStatus().holder, "status after Take Back: " + JSON.stringify(controlStatus()));
  await until(() => cardProbe("has", copyPID, "they can ask you for control").status === 0, "the card to say viewers watch", 10_000, 300);
  cardProbe("close", copyPID);
  cli(["set", SHARE, "--control", "everyone"]);
  await asker.waitFor(`document.body.dataset.control === 'yes'`, "control back for the second page", 10_000);
  await asker.close();
  asker = null;
});

await step("Reset Data restores the orders", async () => {
  assert(await page.eval(ROWS) !== 30 || (await openCount()) !== "20 open", "nothing to reset");
  await page.eval(`window.__e2ePage = 1`);
  cli(["restart", SHARE, "--reset-data"]);
  await page.waitFor(`${ROWS} === 30 && ${HAS_TEXT("20 open")} && !${HAS_TEXT(CUSTOMER)}`, "the 30 original orders, 20 open", 60_000);
  assert(await page.eval(`window.__e2ePage === 1 && document.getElementById('otm-dot').dataset.state === 'live'`), "the page reloaded or disconnected");
});

await step("Restart keeps the page connected", async () => {
  await page.eval(`(${FIND("AXButton", "Add Order")}).__e2eMark = 1`);
  cli(["restart", SHARE, "--app"]);
  await page.waitFor(`!!${FIND("AXButton", "Add Order")} && ${FIND("AXButton", "Add Order")}.__e2eMark !== 1 && ${NODES()}.length > 60`, "the new boot's window", 60_000);
  assert(await page.eval(`window.__e2ePage === 1 && document.getElementById('otm-dot').dataset.state === 'live'`), "the page reloaded or disconnected");
  const s = cli(["status", SHARE], { json: true });
  assert(s.macApp?.state === "running" && s.macApp.viewers >= 1, "status after the restart: " + JSON.stringify(s.macApp));
  return `${s.macApp.viewers} viewer(s)`;
});

await step("an edited label is rebuilt and shows in the browser", async () => {
  const file = path.join(FIXTURE, "Sources", "Orbit", "OrdersView.swift");
  const source = fs.readFileSync(file, "utf8");
  assert(source.includes('Button("Add Order")'), "the fixture's Add Order button isn't where it was");
  await page.eval(`window.__e2eBanner = []; new MutationObserver(() => { const b = document.getElementById('otm-banner'); if (!b.hidden) window.__e2eBanner.push(b.textContent); }).observe(document.getElementById('otm-banner'), { attributes: true, childList: true, subtree: true }), true`);
  const started = Date.now();
  fs.writeFileSync(file, source.replace('Button("Add Order")', 'Button("Add New Order")'));
  await page.waitFor(`!!${FIND("AXButton", "Add New Order")}`, "Add New Order in the browser", 180_000);
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  assert(await page.eval(`window.__e2ePage === 1`), "the page reloaded");
  const banners = await page.eval(`[...new Set(window.__e2eBanner)]`);
  return `label changed after ${seconds} s; banners: ${banners.join(" / ") || "none"}`;
});

// A rebuild that fails: the host and viewers are told, viewers keep the previous version; a fix clears it.
const ORDERS = path.join(FIXTURE, "Sources", "Orbit", "OrdersView.swift");
const BROKEN = '\nlet e2eBrokenBuild: Int = "not a number" // macapp-e2e: a compile error\n';
const buildStatus = () => cli(["status", SHARE], { json: true }).macApp?.build;
const buildNote = () => page.eval(`(() => { const b = document.getElementById('otm-build'); return b && !b.hidden ? b.textContent : null; })()`);
let buildWatcher = null, buildWatched = "", cardShown = false;
const buildEvents = () => buildWatched.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter((e) => e && /^build\./.test(e.type));
cleanups.push(async () => {
  if (buildWatcher) buildWatcher.kill();
  // Leave the scratch sources buildable for a --keep run.
  try { const src = fs.readFileSync(ORDERS, "utf8"); if (src.includes(BROKEN)) fs.writeFileSync(ORDERS, src.replace(BROKEN, "")); } catch { /* gone */ }
});

await step("a broken build warns and keeps the previous version", async () => {
  const source = fs.readFileSync(ORDERS, "utf8");
  assert(source.includes('Button("Add New Order")'), "the rebuild step's Add New Order isn't in the sources (run it first)");
  assert(buildStatus()?.state === "idle", "build before the change: " + JSON.stringify(buildStatus()));
  buildWatcher = spawn(CLI, ["watch", SHARE, "--json"], { env: { ...env, OPENTRAFFIC_SOCKET: SOCKET }, stdio: ["ignore", "pipe", "ignore"] });
  buildWatcher.stdout.on("data", (d) => { buildWatched += d; });
  await sleep(500); // the watch has its cursor
  const started = Date.now();
  fs.writeFileSync(ORDERS, source.replace('Button("Add New Order")', 'Button("Add Fixed Order")') + BROKEN);
  const failed = await until(() => { const b = buildStatus(); return b?.state === "failed" && b; }, "`opentraffic status --json` to report the failed build", 180_000, 500);
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  assert(/OrdersView\.swift:\d+:\d+: error: /.test(failed.message || ""), "the failure's message: " + failed.message);
  assert(failed.log && fs.readFileSync(failed.log, "utf8").includes("error:"), "the build log " + failed.log + " has no error");
  assert(/swift build/.test(failed.command || ""), "the build command: " + failed.command);
  const text = cli(["status", SHARE]);
  assert(/Build\s+failed · viewers see the previous version of Orbit/.test(text) && text.includes("error:") && text.includes("Log: "), "`opentraffic status` says: " + text);
  // Viewers: a banner, and still the previous version.
  const note = await until(buildNote, "the viewer's build banner", 10_000);
  assert(note === "The host's latest changes to Orbit didn't build, so you see the previous version.", "the banner says: " + note);
  assert(await page.eval(`!!${FIND("AXButton", "Add New Order")} && !${FIND("AXButton", "Add Fixed Order")}`), "the page doesn't show the previous version's Add New Order");
  assert(await page.eval(`window.__e2ePage === 1 && document.getElementById('otm-dot').dataset.state === 'live'`), "the page reloaded or disconnected");
  const events = await until(() => { const e = buildEvents(); return e.some((x) => x.type === "build.failed") && e; }, "`opentraffic watch` to report the failure", 10_000, 200);
  assert(events[0].type === "build.started" && events[0].share === SHARE, "the first build event: " + JSON.stringify(events[0]));
  const failure = events.find((e) => e.type === "build.failed");
  assert(failure.build === "failed" && /error: /.test(failure.message || "") && failure.log === failed.log, "the failure event: " + JSON.stringify(failure));
  return `failed after ${seconds} s: ${failed.message.replace(/^.*?(OrdersView)/, "$1").slice(0, 90)}; watch: ${events.map((e) => e.type).join(", ")}`;
});

await step("the card's build warning and Build Again", async () => {
  if (!CARD) throw new Skip("--card opens the copy's window and presses the card's buttons through Accessibility");
  const before = buildStatus();
  assert(before?.state === "failed", "build before: " + JSON.stringify(before));
  await showCard();
  cardShown = true;
  await until(() => cardProbe("has", copyPID, "Orbit didn't build").status === 0, "“Orbit didn't build” on the card", 15_000, 300);
  assert(cardProbe("has", copyPID, "error: ").status === 0, "the card doesn't show the compiler's error");
  assert(cardProbe("enabled", copyPID, "Show Log").status === 0, "no enabled Show Log on the card");
  const watched = buildEvents().length;
  assert(cardProbe("press", copyPID, "Build Again").status === 0, "no Build Again button on the card");
  // It builds again (the card says Building… meanwhile) and, the sources still broken, fails again.
  let sawBuilding = false;
  const again = await until(() => {
    if (!sawBuilding && cardProbe("has", copyPID, "Building Orbit…").status === 0) sawBuilding = true;
    const b = buildStatus();
    return b?.state === "failed" && b.log !== before.log && b;
  }, "a new failed build after Build Again", 180_000, 300);
  const events = buildEvents().slice(watched).map((e) => e.type);
  assert(events.join(",") === "build.started,build.failed", "watch after Build Again: " + events.join(", "));
  await until(() => cardProbe("has", copyPID, "Orbit didn't build").status === 0, "the warning back on the card", 10_000, 300);
  assert(await buildNote(), "the viewer's banner went away");
  return `${path.basename(before.log)} -> ${path.basename(again.log)}; card showed Building…: ${sawBuilding}`;
});

await step("fixing the build clears the warning and shows the new version", async () => {
  const source = fs.readFileSync(ORDERS, "utf8");
  assert(source.includes(BROKEN), "the sources aren't broken");
  const watched = buildEvents().length;
  const started = Date.now();
  fs.writeFileSync(ORDERS, source.replace(BROKEN, ""));
  await page.waitFor(`!!${FIND("AXButton", "Add Fixed Order")}`, "Add Fixed Order in the browser", 180_000);
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  await until(async () => (await buildNote()) === null, "the viewer's build banner to go", 10_000);
  assert(await page.eval(`window.__e2ePage === 1`), "the page reloaded");
  const b = buildStatus();
  assert(b?.state === "idle" && !b.message, "build after the fix: " + JSON.stringify(b));
  assert(!/Build\s+failed/.test(cli(["status", SHARE])), "`opentraffic status` still says it failed");
  const events = await until(() => { const e = buildEvents().slice(watched); return e.some((x) => x.type === "build.succeeded") && e; }, "`opentraffic watch` to report the good build", 10_000, 200);
  assert(events.map((e) => e.type).join(",") === "build.started,build.succeeded", "watch after the fix: " + events.map((e) => e.type).join(", "));
  if (cardShown) {
    await until(() => cardProbe("has", copyPID, "Orbit didn't build").status === 2, "the card's warning to go", 10_000, 300);
    cardProbe("close", copyPID);
  }
  buildWatcher.kill();
  buildWatcher = null;
  return `new label after ${seconds} s; watch: ${events.map((e) => e.type).join(", ")}`;
});

await step("WebKit", async () => {
  // Safari can only be driven through safaridriver with Develop > Allow Remote Automation on, which
  // also takes over the user's Safari; there's no headless WebKit without npm packages.
  throw new Skip("no headless WebKit here (Safari's WebDriver needs Allow Remote Automation and drives the user's Safari)");
});

await step("no page errors", async () => {
  const errors = page.errors.filter((e) => !/WebSocket|ERR_|net::/.test(e));
  assert(!errors.length, errors.slice(0, 5).join(" | "));
});

await finish(0);
