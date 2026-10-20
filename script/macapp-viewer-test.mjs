#!/usr/bin/env node
// Headless Chrome test of the Mac app viewer page (macapp-viewer.html/.js/.css) against the stub
// replay server (script/macapp-viewer-stub.mjs). Node only, no npm packages; Chrome driven over raw CDP.
//
//   node script/macapp-viewer-test.mjs [--out <dir>]      screenshots go to <dir> when given
//
// Checks: one layer element per node with the protocol's DOM ids, stable across trees; collab.js's
// picker sees and labels the elements (not the canvas); clicks, typing (IME too), keys, pointer, wheel
// map to the protocol's messages; optimistic feedback; tiles paint; cursor, status, reconnect and boot;
// the app's menu bar in the desktop bar, its context menus and its shortcuts as menuAction;
// fit-to-viewport; the Simple view at 390 px (real text and controls in reading order, the same ids and
// messages, comment anchors that resolve in either view, the bar's toggle); no console errors. Exits 1 on a failure; skips (exit 0) without Google Chrome.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const args = process.argv.slice(2);
const outIndex = args.indexOf("--out");
const OUT = outIndex >= 0 ? path.resolve(args[outIndex + 1]) : null;
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const fixture = JSON.parse(fs.readFileSync(path.join(here, "macapp-viewer-fixture.json"), "utf8"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (!fs.existsSync(CHROME)) {
  console.log("SKIP macapp-viewer-test: Google Chrome not found (set CHROME to its binary)");
  process.exit(0);
}
if (OUT) fs.mkdirSync(OUT, { recursive: true });

// Spawned programs must behave normally, even when this runs inside an Electron host.
const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;

const children = [];
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "otm-viewer-test-"));
function cleanup() {
  for (const c of children) try { c.kill(); } catch { /* gone */ }
  setTimeout(() => fs.rmSync(temp, { recursive: true, force: true }), 300);
}
process.on("exit", cleanup);

// ---- the stub

const stub = spawn(process.execPath, [path.join(here, "macapp-viewer-stub.mjs"), "--port", "0"], { env, stdio: ["ignore", "pipe", "inherit"] });
children.push(stub);
const base = await new Promise((resolve, reject) => {
  let text = "";
  stub.stdout.on("data", (d) => {
    text += d;
    const m = text.match(/MACAPP_STUB (http:\/\/127\.0\.0\.1:\d+)/);
    if (m) resolve(m[1]);
  });
  stub.on("exit", (code) => reject(new Error("stub exited " + code)));
  setTimeout(() => reject(new Error("stub didn't start")), 30000).unref(); // generous: busy machines start node slowly
});
const stubPost = async (p, body) => (await fetch(base + p, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) })).json();
const stubSend = (nameOrMessage) => typeof nameOrMessage === "string"
  ? stubPost("/__stub/send?name=" + encodeURIComponent(nameOrMessage))
  : stubPost("/__stub/send", nameOrMessage);
const received = async (clear) => (await fetch(base + "/__stub/received" + (clear ? "?clear=1" : ""))).json();

// ---- Chrome over CDP

const profile = path.join(temp, "chrome");
children.push(spawn(CHROME, [
  "--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run",
  "--no-default-browser-check", "--hide-scrollbars", "--mute-audio", "--window-size=1440,900",
  "--force-device-scale-factor=2", "about:blank",
], { env, stdio: "ignore" }));
let devtools = null;
for (let i = 0; i < 300 && !devtools; i++) {
  try { devtools = fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n")[0]; }
  catch { await sleep(100); }
}
if (!devtools) throw new Error("Chrome didn't start");
let target = null;
for (let i = 0; i < 150 && !target; i++) {
  try { target = (await (await fetch(`http://127.0.0.1:${devtools}/json/list`)).json()).find((t) => t.type === "page"); }
  catch { /* not yet */ }
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
const once = (method) => new Promise((resolve) => {
  const l = (m) => { if (m.method === method) { listeners.splice(listeners.indexOf(l), 1); resolve(m); } };
  listeners.push(l);
});

const consoleErrors = [];
listeners.push((m) => {
  if (m.method === "Runtime.exceptionThrown") consoleErrors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
  if (m.method === "Runtime.consoleAPICalled" && (m.params.type === "error" || m.params.type === "assert")) consoleErrors.push(m.params.args.map((a) => a.value ?? a.description).join(" "));
  if (m.method === "Log.entryAdded" && m.params.entry.level === "error") consoleErrors.push(m.params.entry.text + " " + (m.params.entry.url || ""));
});

async function evaluate(expression) {
  const r = await cdp("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error("page: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
  return r.result.value;
}
async function waitFor(expression, what, timeout = 4000) {
  const end = Date.now() + timeout;
  for (;;) {
    const v = await evaluate(expression);
    if (v) return v;
    if (Date.now() > end) throw new Error("timed out waiting for " + what);
    await sleep(40);
  }
}
async function waitReceived(pred, what, timeout = 3000) {
  const end = Date.now() + timeout;
  for (;;) {
    const list = await received();
    const hit = list.filter(pred);
    if (hit.length) return hit;
    if (Date.now() > end) throw new Error("server never got " + what + "; got " + JSON.stringify(list).slice(0, 600));
    await sleep(40);
  }
}
const mouse = (type, x, y, extra = {}) => cdp("Input.dispatchMouseEvent", { type, x, y, button: "none", ...extra });
async function click(x, y, button = "left") {
  await mouse("mouseMoved", x, y);
  await mouse("mousePressed", x, y, { button, clickCount: 1, buttons: button === "left" ? 1 : 2 });
  await mouse("mouseReleased", x, y, { button, clickCount: 1 });
}
const key = (type, k, code, vk, text) => cdp("Input.dispatchKeyEvent", { type, key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, ...(text ? { text, unmodifiedText: text } : {}) });
async function press(k, code, vk, text) {
  await key(text ? "keyDown" : "rawKeyDown", k, code, vk, text);
  await key("keyUp", k, code, vk);
}
// The viewport point of a point in window 1 (points from its top-left), through fit-to-viewport scaling.
const windowPoint = (x, y) => evaluate(`(() => { const r = document.querySelector('.otm-window[data-window="1"]').getBoundingClientRect();
  const f = r.width / ${fixture.hello.windows[0].w}; return { x: r.left + ${x} * f, y: r.top + ${y} * f }; })()`);
const byKey = (key) => `document.querySelector('[data-key="' + CSS.escape(${JSON.stringify(key)}) + '"]')`;
const nodeCenter = (key, dy = 0.5) => evaluate(`(() => { const el = ${byKey(key)}; if (!el) return null;
  const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height * ${dy} }; })()`);
const pixel = (x, y) => evaluate(`(() => { const c = document.querySelector('.otm-window[data-window="1"] canvas'); const s = c.width / ${fixture.hello.windows[0].w};
  return Array.from(c.getContext('2d').getImageData(Math.round(${x} * s), Math.round(${y} * s), 1, 1).data); })()`);
async function shot(name) {
  if (!OUT) return;
  const r = await cdp("Page.captureScreenshot", { format: "png" });
  fs.writeFileSync(path.join(OUT, name + ".png"), Buffer.from(r.data, "base64"));
}

function domId(key) {
  let h = 5381;
  for (let i = 0; i < key.length; i++) h = ((h << 5) + h + key.charCodeAt(i)) >>> 0;
  return "ax-" + h.toString(36);
}

// collab.js's own picker label and anchor code, taken from the file, so the checks follow it when it changes.
const collabSrc = fs.readFileSync(path.join(root, "Sources", "OpenTraffic", "Resources", "collab.js"), "utf8");
function takeFromCollab(start) {
  const src = collabSrc;
  const i = src.indexOf(start);
  if (i < 0) throw new Error("collab.js no longer has `" + start + "`");
  let depth = 0, seenBrace = false;
  for (let j = i; j < src.length; j++) {
    const c = src[j];
    if ("({[".includes(c)) { depth++; if (c === "{") seenBrace = true; }
    else if (")}]".includes(c)) depth--;
    if (start.startsWith("function") ? seenBrace && depth === 0 && c === "}" : depth === 0 && c === ";") return src.slice(i, j + 1);
  }
  throw new Error("couldn't read `" + start + "` from collab.js");
}
function collabLabelSource() {
  return ["const CONTROL_RE", "const MAX_LABEL", "function oneLine", "const INPUT_KINDS", "const EDITABLE_SEL", "function fieldKind",
    "function nativeElement", "const NATIVE_ROLE_NAMES", "function nativeRoleName", "function nativeLabel", "function labelFor", "function elementContext"]
    .map(takeFromCollab).join("\n");
}

// ---- the checks

const results = [];
async function check(name, fn) {
  try {
    await fn();
    results.push([true, name]);
    console.log("PASS " + name);
  } catch (e) {
    results.push([false, name, e.message]);
    console.log("FAIL " + name + ": " + e.message);
  }
}
const assert = (cond, message) => { if (!cond) throw new Error(message); };

const tree1 = fixture.trees[0];
const tree2 = fixture.named.tree2;
const G = "/Window:/Group:";
const ADD = G + "/Button:Add Order";
const CUSTOMER = G + "/TextField:Customer";
const CHECK = G + "/CheckBox:Express shipping";
const STEPPER = G + "/Incrementor:Quantity";
const nodeCount = `document.querySelectorAll('.otm-window[data-window="1"] .otm-node').length`;

await cdp("Page.enable");
await cdp("Runtime.enable");
await cdp("Log.enable");
await cdp("Emulation.setFocusEmulationEnabled", { enabled: true });
const loaded = once("Page.loadEventFired");
await cdp("Page.navigate", { url: base + "/" });
await loaded;

await check("the layer has one element per node", async () => {
  await waitFor(`${nodeCount} === ${tree1.nodes.length}`, tree1.nodes.length + " layer elements");
  const name = await evaluate(`document.getElementById('otm-name').textContent`);
  assert(name === "Orbit", "bar names " + name);
  const tag = await evaluate(`(document.getElementById('otm-name').textContent + ' ' + document.querySelector('.otm-tag').textContent).replace(/\\s+/g, ' ').trim()`);
  assert(tag === "Orbit · Mac app · running on the host's Mac", "bar says " + tag);
});

await check("element ids are ax-<djb2(key) base36>, with data-key, data-role, aria-label", async () => {
  const els = await evaluate(`[...document.querySelectorAll('.otm-window[data-window="1"] .otm-node')].map((el) => ({ id: el.id, key: el.dataset.key,
    role: el.dataset.role, label: el.getAttribute('aria-label'), aria: el.getAttribute('role'), tag: el.localName, type: el.type || null }))`);
  for (const n of tree1.nodes) {
    const el = els.find((e) => e.key === n.key);
    assert(el, "no element for " + n.key);
    assert(el.id === domId(n.key), n.key + " has id " + el.id);
    assert(el.role === n.role, n.key + " data-role " + el.role);
    assert(el.label === (n.label || null), n.key + " aria-label " + el.label);
  }
  assert(els.find((e) => e.key === ADD).id === "ax-3tt01y", "Add Order isn't #ax-3tt01y");
  assert(els.find((e) => e.key === ADD).aria === "button", "Add Order isn't role=button");
  assert(els.find((e) => e.key === CHECK).aria === "checkbox", "checkbox role");
  const field = els.find((e) => e.key === CUSTOMER);
  assert(field.tag === "input" && field.type === "text", "Customer is " + field.tag + "/" + field.type);
  const pin = els.find((e) => e.key === G + "/SecureTextField:PIN");
  assert(pin.tag === "input" && pin.type === "password", "PIN is " + pin.tag + "/" + pin.type);
  const text = await evaluate(`${byKey(ADD)}.textContent + '|' + getComputedStyle(${byKey(ADD)}).color`);
  assert(text === "Add Order|rgba(0, 0, 0, 0)", "button text/colour: " + text);
});

await check("the first full frame paints the canvas", async () => {
  await waitFor(`(() => { const c = document.querySelector('.otm-window[data-window="1"] canvas'); return c.width === ${fixture.hello.windows[0].w * fixture.hello.scale}; })()`, "canvas sized at scale");
  const end = Date.now() + 3000;
  let p;
  do { p = await pixel(226 + 43, 530 + 12); if (p[2] > 200 && p[0] < 60) break; await sleep(50); } while (Date.now() < end);
  assert(p[2] > 200 && p[0] < 60, "Add Order isn't blue on the canvas: " + p);
  const css = await evaluate(`(() => { const c = document.querySelector('.otm-window[data-window="1"] canvas'); return c.style.width + 'x' + c.style.height; })()`);
  assert(css === "860pxx572px", "canvas CSS size " + css);
  await shot("1-loaded-1440");
});

await check("collab.js's picker hits the overlay elements and labels them by their roles and names", async () => {
  const c = await nodeCenter(ADD);
  const hit = await evaluate(`(() => { const el = document.elementFromPoint(${c.x}, ${c.y}); return el && (el.localName + '#' + el.id); })()`);
  assert(hit === "div#ax-3tt01y", "elementFromPoint at Add Order: " + hit);
  const labels = await evaluate(`(() => { ${collabLabelSource()}
    const at = (key) => document.querySelector('[data-key="' + CSS.escape(key) + '"]');
    return { add: labelFor(at(${JSON.stringify(ADD)})), heading: labelFor(at(${JSON.stringify(G + "/StaticText:New Order")})),
      field: labelFor(at(${JSON.stringify(CUSTOMER)})), row: labelFor(at(${JSON.stringify(G + "/List:/Row:Grace Hopper#2")})),
      blank: labelFor(at(${JSON.stringify(G)})), unique: document.querySelectorAll('#ax-3tt01y').length,
      context: JSON.stringify(elementContext(at(${JSON.stringify(ADD)}))) }; })()`);
  assert(labels.add === "Button \u201cAdd Order\u201d", "Add Order labelled " + labels.add);
  assert(labels.heading === "Text \u201cNew Order\u201d", "heading labelled " + labels.heading);
  assert(labels.field === "Text field \u201cCustomer\u201d", "field labelled " + labels.field);
  assert(labels.row === "Row \u201cGrace Hopper\u201d", "row labelled " + labels.row);
  assert(labels.blank === "Group in \u201cOrbit window\u201d", "blank group labelled " + labels.blank);
  assert(labels.unique === 1, "#ax-3tt01y isn't unique");
  // Agents get the accessibility path as the selector, not the overlay's CSS.
  assert(labels.context === JSON.stringify({ selector: ADD, styles: {} }), "context " + labels.context);
});

await check("ids and elements are stable across trees; the layer follows additions, removals and values", async () => {
  await evaluate(`document.querySelectorAll('.otm-node').forEach((el) => (el.__mark = el.id)), true`);
  await stubSend("tree2");
  await waitFor(`${nodeCount} === ${tree2.nodes.length} && !!${byKey(G + "/List:/Row:Ada")}`, "tree 2 applied");
  const state = await evaluate(`[...document.querySelectorAll('.otm-window[data-window="1"] .otm-node')].map((el) => ({ key: el.dataset.key, id: el.id, mark: el.__mark || null, value: el.value ?? null }))`);
  const before = new Set(tree1.nodes.map((n) => n.key));
  for (const n of tree2.nodes) {
    const el = state.find((e) => e.key === n.key);
    assert(el && el.id === domId(n.key), "missing or wrong id for " + n.key);
    if (before.has(n.key)) assert(el.mark === el.id, "element for " + n.key + " was recreated");
    else assert(el.mark === null, "new node " + n.key + " reused an element");
  }
  assert(!state.some((e) => e.key === G + "/StaticText:3 orders"), "removed node still there");
  assert(state.find((e) => e.key === CUSTOMER).value === "Ada", "field didn't take the app's value");
});

await check("a click on Add Order shows it pressed at once and sends act press", async () => {
  await received(true);
  const c = await nodeCenter(ADD);
  await mouse("mouseMoved", c.x, c.y);
  await mouse("mousePressed", c.x, c.y, { button: "left", clickCount: 1, buttons: 1 });
  const pressed = await evaluate(`${byKey(ADD)}.classList.contains('otm-pressed')`);
  await mouse("mouseReleased", c.x, c.y, { button: "left", clickCount: 1 });
  assert(pressed, "no pressed state while held");
  const acts = await waitReceived((m) => m.t === "act", "act press");
  assert(acts.length === 1 && acts[0].window === 1 && acts[0].key === ADD && acts[0].action === "press", JSON.stringify(acts));
  const all = await received();
  assert(!all.some((m) => m.t === "pointer" && (m.kind === "down" || m.kind === "up")), "a button click also sent pointer down/up");
  await waitFor(`!${byKey(ADD)}.classList.contains('otm-pressed')`, "pressed state to clear", 2000);
});

await check("a checkbox flips at once, sends act press, and goes back to the app's truth on the next tree", async () => {
  await received(true);
  const c = await nodeCenter(CHECK);
  await click(c.x, c.y);
  const now = await evaluate(`${byKey(CHECK)}.getAttribute('aria-checked') + ' ' + ${byKey(CHECK)}.classList.contains('otm-flip-on')`);
  assert(now === "true true", "checkbox right after the click: " + now);
  const acts = await waitReceived((m) => m.t === "act", "act press on the checkbox");
  assert(acts[0].key === CHECK && acts[0].action === "press", JSON.stringify(acts));
  await stubSend({ ...tree2, v: "tree-2b" }); // the app didn't change it after all
  await waitFor(`${byKey(CHECK)}.getAttribute('aria-checked') === 'false' && !${byKey(CHECK)}.classList.contains('otm-flip-on')`, "the app's truth");
});

await check("the stepper's halves send increment and decrement", async () => {
  await received(true);
  const up = await nodeCenter(STEPPER, 0.2);
  await click(up.x, up.y);
  const down = await nodeCenter(STEPPER, 0.8);
  await click(down.x, down.y);
  await waitReceived((m) => m.t === "act" && m.action === "decrement", "decrement");
  const all = (await received()).filter((m) => m.t === "act");
  assert(all.length === 2 && all[0].action === "increment" && all[1].action === "decrement" && all[0].key === STEPPER, JSON.stringify(all));
});

await check("clicks elsewhere, right clicks, moves and the wheel send pointer events at window points", async () => {
  await received(true);
  const p = await windowPoint(400, 400);
  await click(p.x, p.y);
  const r = await nodeCenter(G + "/List:/Row:Ada Lovelace");
  await click(r.x, r.y, "right");
  await mouse("mouseMoved", p.x + 10, p.y + 10);
  await sleep(80);
  await mouse("mouseWheel", r.x, r.y, { deltaX: 0, deltaY: 120 });
  await waitReceived((m) => m.t === "pointer" && m.kind === "wheel", "wheel");
  const ps = (await received()).filter((m) => m.t === "pointer");
  const kinds = ps.map((m) => m.kind).filter((k) => k !== "move");
  assert(JSON.stringify(kinds) === JSON.stringify(["down", "up", "rightdown", "rightup", "wheel"]), "kinds " + JSON.stringify(kinds));
  const down = ps.find((m) => m.kind === "down");
  assert(Math.abs(down.x - 400) <= 1 && Math.abs(down.y - 400) <= 1 && down.window === 1, "down at " + down.x + "," + down.y);
  const rd = ps.find((m) => m.kind === "rightdown");
  assert(Math.abs(rd.y - 105) <= 1, "right click at y " + rd.y);
  assert(ps.some((m) => m.kind === "move" && Math.abs(m.x - 410) <= 1 && Math.abs(m.y - 410) <= 1), "no move to 410,410");
  const wheel = ps.find((m) => m.kind === "wheel");
  assert(wheel.dy === 120 && wheel.dx === 0, "wheel deltas " + wheel.dx + "," + wheel.dy);
  const moves = ps.filter((m) => m.kind === "move").length;
  assert(moves <= 6, moves + " moves for a handful of mouse events");
});

await check("typing in a field sends text (IME-safe), named keys as key, edits of a selection as setText", async () => {
  await received(true);
  const c = await nodeCenter(CUSTOMER);
  await click(c.x + 100, c.y);
  await waitFor(`document.activeElement === ${byKey(CUSTOMER)}`, "the field to take focus");
  const clicks = (await received()).filter((m) => m.t === "pointer" && (m.kind === "down" || m.kind === "up"));
  assert(clicks.length === 2, "a click in the field sends pointer down/up so the app focuses it: " + JSON.stringify(clicks));
  await evaluate(`(() => { const el = ${byKey(CUSTOMER)}; el.setSelectionRange(el.value.length, el.value.length); return true; })()`);
  await received(true);
  await press(" ", "Space", 32, " ");
  await press("L", "KeyL", 76, "L");
  await cdp("Input.insertText", { text: "ove" });
  let ime = true;
  try {
    await cdp("Input.imeSetComposition", { text: "らv", selectionStart: 2, selectionEnd: 2 });
    await cdp("Input.insertText", { text: "😀" });
  } catch { ime = false; }
  await press("Backspace", "Backspace", 8);
  await press("Enter", "Enter", 13, "\r");
  await waitReceived((m) => m.t === "key" && m.code === "Enter", "key Enter");
  const got = await received(true);
  const texts = got.filter((m) => m.t === "text").map((m) => m.text).join("");
  assert(texts === " Love" + (ime ? "😀" : ""), "text messages spell " + JSON.stringify(texts) + " in " + JSON.stringify(got));
  assert(got.every((m) => m.t !== "text" || m.window === 1), "text without window");
  const keys = got.filter((m) => m.t === "key").map((m) => m.code);
  assert(JSON.stringify(keys) === '["Backspace","Enter"]', "keys " + JSON.stringify(keys));
  assert(!got.some((m) => m.t === "setText"), "plain typing sent setText");
  const look = await evaluate(`(() => { const el = ${byKey(CUSTOMER)}; const cs = getComputedStyle(el);
    return { value: el.value, color: cs.color, bg: cs.backgroundColor, font: cs.fontSize + ' ' + cs.fontFamily }; })()`);
  assert(look.value === "Ada Love", "field shows " + JSON.stringify(look.value));
  assert(look.color !== "rgba(0, 0, 0, 0)" && look.bg === "rgb(255, 255, 255)", "typed text isn't visible over a mask: " + JSON.stringify(look));
  assert(look.font.startsWith("13px") && look.font.includes("-apple-system"), "field font " + look.font);
  // A tree with the app's (older) value while typing doesn't overwrite what the viewer typed.
  await stubSend({ ...tree2, v: "tree-2c" });
  await sleep(150);
  assert(await evaluate(`${byKey(CUSTOMER)}.value`) === look.value, "a tree overwrote the field mid-typing");
  await shot("2-typing"); // after the check: a 2x screenshot can outlast the typing pause it relies on
  // Select all, then type: the app gets the whole value.
  await evaluate(`${byKey(CUSTOMER)}.select(), true`);
  await cdp("Input.insertText", { text: "Grace" });
  const set = await waitReceived((m) => m.t === "setText", "setText");
  assert(set[0].key === CUSTOMER && set[0].value === "Grace" && set[0].window === 1, JSON.stringify(set));
});

await check("a focused field survives a tree without it, and takes the app's value after it loses focus", async () => {
  const without = { ...tree2, v: "tree-3", nodes: tree2.nodes.filter((n) => n.key !== CUSTOMER) };
  await evaluate(`${byKey(CUSTOMER)}.__mark = 'kept', true`);
  await stubSend(without);
  await waitFor(`${nodeCount} === ${tree2.nodes.length} && ${byKey(CUSTOMER)}.classList.contains('otm-stale')`, "the stale field");
  assert(await evaluate(`document.activeElement === ${byKey(CUSTOMER)} && ${byKey(CUSTOMER)}.__mark === 'kept'`), "the focused field was dropped");
  await stubSend({ ...tree2, v: "tree-4" });
  await waitFor(`!${byKey(CUSTOMER)}.classList.contains('otm-stale')`, "the field back in the tree");
  assert(await evaluate(`${byKey(CUSTOMER)}.__mark === 'kept'`), "the field was recreated");
  const p = await windowPoint(400, 400);
  await click(p.x, p.y);
  await waitFor(`document.activeElement !== ${byKey(CUSTOMER)}`, "blur");
  await stubSend({ ...tree2, v: "tree-5" });
  await waitFor(`${byKey(CUSTOMER)}.value === 'Ada'`, "the app's value after blur");
});

await check("tiles paint their part of the canvas", async () => {
  const before = await pixel(24 + 150, 470 + 18);
  await stubSend("orderAdded");
  const end = Date.now() + 3000;
  let after;
  do { after = await pixel(24 + 150, 470 + 18); if (after[1] > 150 && after[0] < 120) break; await sleep(40); } while (Date.now() < end);
  assert(before[1] < 250 && before[0] > 200, "unexpected pixel before: " + before);
  assert(after[1] > 150 && after[0] < 120, "banner tile didn't paint: " + after);
  await shot("3-order-added");
});

await check("cursor messages set the CSS cursor", async () => {
  await stubSend("cursorPointer");
  await waitFor(`getComputedStyle(${byKey(G)}).cursor === 'pointer'`, "pointer cursor");
  await stubSend("cursorDefault");
  await waitFor(`getComputedStyle(${byKey(G)}).cursor === 'default'`, "default cursor");
});

await check("status shows a banner for anything but running", async () => {
  await stubSend("restarting");
  await waitFor(`!document.getElementById('otm-banner').hidden && document.getElementById('otm-banner').textContent === 'Rebuilt; restarting Orbit'`, "restarting banner");
  await shot("4-restarting");
  await stubSend("crashed");
  await waitFor(`document.getElementById('otm-banner').textContent === 'Orbit quit unexpectedly.' && document.getElementById('otm-banner').dataset.state === 'crashed'`, "crashed banner");
  await stubSend("running");
  await waitFor(`document.getElementById('otm-banner').hidden`, "banner gone");
});

await check("reconnects after a drop; the same boot keeps the layer", async () => {
  await evaluate(`${byKey(ADD)}.__mark2 = 1, true`);
  await stubPost("/__stub/close");
  await waitFor(`document.getElementById('otm-dot').dataset.state === 'connecting'`, "the dot to show reconnecting");
  await waitFor(`document.getElementById('otm-dot').dataset.state === 'live'`, "reconnect", 6000);
  await waitFor(`${nodeCount} === ${tree1.nodes.length}`, "the replayed tree");
  assert(await evaluate(`${byKey(ADD)}.__mark2 === 1`), "same boot recreated the layer");
});

await check("a different boot clears the layer", async () => {
  await stubPost("/__stub/hello", { boot: "0D7E4C1A-9A3B-4F1D-8E2C-5B6A7C8D9E0F" });
  await stubPost("/__stub/close");
  await waitFor(`document.getElementById('otm-dot').dataset.state === 'connecting'`, "the drop");
  await waitFor(`document.getElementById('otm-dot').dataset.state === 'live' && !!${byKey(ADD)} && ${byKey(ADD)}.__mark2 === undefined`, "a fresh layer", 6000);
  assert(await evaluate(nodeCount) === tree1.nodes.length, "node count after the new boot");
  assert(await evaluate(`document.querySelectorAll('.otm-window').length`) === 1, "old windows left behind");
});

// ---- menus: the app's menu bar in the desktop bar, its context menus, its shortcuts

const MENU = fixture.menu;
const CMD = 4, SHIFT = 8, ALT = 1; // CDP modifier bits
const barTitles = `[...document.querySelectorAll('#otm-bar .otm-menus .otm-menu-title')].map((b) => b.textContent)`;
const titleButton = (title) => `[...document.querySelectorAll('#otm-bar .otm-menus .otm-menu-title')].find((b) => b.textContent === ${JSON.stringify(title)})`;
const menuItem = (kind, title) => `[...document.querySelectorAll('.otm-menu-${kind} .otm-menu-item')].find((b) => b.querySelector('.otm-menu-label').textContent === ${JSON.stringify(title)})`;
const openMenuShape = (kind) => evaluate(`(() => { const box = document.querySelector('.otm-menu-${kind}'); if (!box) return null; const r = box.getBoundingClientRect();
  return { x: r.left, y: r.top, w: r.width, h: r.height, role: box.getAttribute('role'), lines: box.querySelectorAll('hr').length,
    heads: [...box.querySelectorAll('.otm-menu-head')].map((h) => h.textContent),
    items: [...box.querySelectorAll('.otm-menu-item')].map((b) => ({ label: b.querySelector('.otm-menu-label').textContent,
      acc: b.querySelector('.otm-menu-acc') ? b.querySelector('.otm-menu-acc').textContent : null, disabled: b.disabled,
      checked: b.getAttribute('aria-checked') === 'true', check: b.querySelector('.otm-menu-check').textContent })) }; })()`);
async function clickOn(expr) {
  const p = await evaluate(`(() => { const el = ${expr}; if (!el) return null; el.scrollIntoView({ block: 'nearest' });
    const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  assert(p, "nothing to click: " + expr);
  await click(p.x, p.y);
  return p;
}
async function chord(k, code, vk, modifiers) {
  await cdp("Input.dispatchKeyEvent", { type: "rawKeyDown", key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers });
  await cdp("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers });
}
const menuActions = async () => (await received()).filter((m) => m.t === "menuAction");
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

await check("the app's menu bar is in the desktop bar: the name opens the app's own menu, then its other menus", async () => {
  const titles = MENU.bar.slice(1).map((m) => m.title);
  await waitFor(`${barTitles}.join('|') === ${JSON.stringify(titles.join("|"))}`, "the menu titles " + titles.join(", "));
  const name = await evaluate(`(() => { const n = document.getElementById('otm-name'); return n.getAttribute('role') + ' ' + n.getAttribute('aria-haspopup') + ' ' + n.dataset.menu; })()`);
  assert(name === "button menu 0", "the name isn't the app menu's button: " + name);
  assert(await evaluate(`document.getElementById('otm-bar').classList.contains('otm-bar-compact')`) === false, "titles collapsed at 1440 px");
  assert(await evaluate(`getComputedStyle(document.querySelector('.otm-menu-all')).display`) === "none", "the Menu button shows at 1440 px");
  await shot("9-menu-bar");
});

await check("a menu opens under its title with checks, shortcuts, separators and submenus; choosing sends menuAction", async () => {
  await received(true);
  const b = await clickOn(titleButton("Orders"));
  await waitFor(`!!document.querySelector('.otm-menu-bar')`, "the Orders menu");
  const m = await openMenuShape("bar");
  assert(m.role === "menu", "role " + m.role);
  const byLabel = Object.fromEntries(m.items.map((i) => [i.label, i]));
  assert(byLabel["Mark All Shipped"] && byLabel["Mark All Shipped"].acc === "⇧⌘S", "Mark All Shipped: " + JSON.stringify(byLabel["Mark All Shipped"]));
  assert(byLabel["Show Statistics"] && byLabel["Show Statistics"].acc === "⌥⌘I", "Show Statistics: " + JSON.stringify(byLabel["Show Statistics"]));
  assert(same(m.heads, ["Filter"]), "submenu headings " + JSON.stringify(m.heads));
  assert(byLabel.All && byLabel.All.checked && byLabel.All.check === "✓" && !byLabel.Open.checked, "checkmarks " + JSON.stringify([byLabel.All, byLabel.Open]));
  assert(m.lines === 1, "separators " + m.lines);
  assert(m.y >= b.y && Math.abs(m.x - (await evaluate(`${titleButton("Orders")}.getBoundingClientRect().left`))) <= 1, "not under its title: " + JSON.stringify(m));
  assert(await evaluate(`${titleButton("Orders")}.getAttribute('aria-expanded')`) === "true", "title not expanded");
  await shot("10-menu-orders");
  await clickOn(menuItem("bar", "Mark All Shipped"));
  await waitReceived((x) => x.t === "menuAction" && same(x.path, ["Orders", "Mark All Shipped"]) && x.context === false, "menuAction Mark All Shipped");
  assert(await evaluate(`!document.querySelector('.otm-menu-bar')`), "the menu stayed open after choosing");
  // A submenu's item sends its whole path.
  await clickOn(titleButton("Orders"));
  await clickOn(menuItem("bar", "Shipped"));
  await waitReceived((x) => x.t === "menuAction" && same(x.path, ["Orders", "Filter", "Shipped"]), "menuAction Filter > Shipped");
  // The name opens the app's own menu.
  await clickOn(`document.getElementById('otm-name')`);
  await waitFor(`!!${menuItem("bar", "About Orbit")}`, "the app menu");
  await clickOn(menuItem("bar", "About Orbit"));
  await waitReceived((x) => x.t === "menuAction" && same(x.path, ["Orbit", "About Orbit"]), "menuAction About Orbit");
  // A disabled item does nothing; pointing at another title switches menus; Escape closes; no clicks reach the app.
  await clickOn(titleButton("Edit"));
  const edit = await openMenuShape("bar");
  const undo = edit.items.find((i) => i.label === "Undo");
  assert(undo && undo.disabled && undo.acc === "⌘Z", "Undo " + JSON.stringify(undo));
  await clickOn(menuItem("bar", "Undo"));
  const v = await evaluate(`(() => { const r = ${titleButton("View")}.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  await mouse("mouseMoved", v.x, v.y);
  await waitFor(`${titleButton("View")}.getAttribute('aria-expanded') === 'true' && !!${menuItem("bar", "Show Tab Bar")}`, "the View menu on hover");
  await press("Escape", "Escape", 27);
  await waitFor(`!document.querySelector('.otm-menu-bar')`, "Escape to close the menu");
  await sleep(150);
  const sent = await received();
  assert(!sent.some((x) => x.t === "menuAction" && x.path.includes("Undo")), "a disabled item was sent");
  assert(!sent.some((x) => x.t === "pointer" || x.t === "key" || x.t === "act"), "menu clicks reached the app: " + JSON.stringify(sent.filter((x) => x.t !== "menuAction")));
});

await check("menu shortcuts typed in the viewer choose their item; clipboard keys, field editing and the comment box stay with the browser", async () => {
  await evaluate(`document.activeElement && document.activeElement.blur(), true`);
  await received(true);
  await chord("S", "KeyS", 83, CMD | SHIFT);
  await waitReceived((x) => x.t === "menuAction" && same(x.path, ["Orders", "Mark All Shipped"]) && x.context === false, "⇧⌘S as Mark All Shipped");
  await chord("ˆ", "KeyI", 73, CMD | ALT); // ⌥I types ˆ on a Mac keyboard: the key's code decides
  await waitReceived((x) => x.t === "menuAction" && same(x.path, ["Orders", "Show Statistics"]), "⌥⌘I as Show Statistics");
  await chord("z", "KeyZ", 90, CMD); // Undo is disabled: swallowed, not sent
  await chord("c", "KeyC", 67, CMD); // the host's clipboard is no use to a viewer
  await evaluate(`${byKey(CUSTOMER)}.focus(), true`);
  await chord("a", "KeyA", 65, CMD); // a field's own select all
  await evaluate(`(() => { const i = document.createElement('input'); i.id = 't-comment'; document.body.appendChild(i); i.focus(); return true; })()`);
  await chord("S", "KeyS", 83, CMD | SHIFT); // typed in the comment box
  await evaluate(`document.getElementById('t-comment').remove(), true`);
  await sleep(250);
  const actions = await menuActions();
  assert(actions.length === 2, "menu actions sent: " + JSON.stringify(actions));
  const other = (await received()).filter((x) => x.t === "key" || x.t === "text");
  assert(other.length === 0, "shortcuts also went out as keys or text: " + JSON.stringify(other));
});

await check("a context menu the app pops up shows where it is; choosing, clicking elsewhere and Escape answer it", async () => {
  await evaluate(`document.activeElement && document.activeElement.blur(), true`);
  await received(true);
  await stubSend("contextMenu");
  await waitFor(`!!document.querySelector('.otm-menu-context')`, "the context menu");
  const m = await openMenuShape("context");
  const want = await windowPoint(120, 160);
  assert(Math.abs(m.x - want.x) <= 2 && Math.abs(m.y - want.y) <= 2, "context menu at " + m.x + "," + m.y + ", app put it at " + want.x + "," + want.y);
  assert(same(m.items.map((i) => i.label), ["Mark as Shipped", "Duplicate", "Delete"]) && m.lines === 1, "items " + JSON.stringify(m));
  await shot("11-context-menu");
  await clickOn(menuItem("context", "Duplicate"));
  await waitReceived((x) => x.t === "menuAction" && same(x.path, ["Duplicate"]) && x.context === true, "menuAction Duplicate (context)");
  assert(await evaluate(`!document.querySelector('.otm-menu-context')`), "the context menu stayed after choosing");
  // The same menu again before the app closed it doesn't reopen it; a new one does.
  await stubSend("contextMenu");
  await sleep(150);
  assert(await evaluate(`!document.querySelector('.otm-menu-context')`), "a chosen menu came back");
  await stubSend("noContext");
  await stubSend("contextMenuAgain");
  await waitFor(`!!document.querySelector('.otm-menu-context')`, "the second context menu");
  // A click elsewhere closes it, and goes no further (as on a Mac).
  await received(true);
  const away = await windowPoint(600, 420);
  await click(away.x, away.y);
  await waitReceived((x) => x.t === "menuAction" && same(x.path, []) && x.context === true, "the close on a click elsewhere");
  await sleep(150);
  const leaked = (await received()).filter((x) => x.t === "pointer" && x.kind !== "move");
  assert(leaked.length === 0, "the closing click reached the app: " + JSON.stringify(leaked));
  assert(await evaluate(`!document.querySelector('.otm-menu-context')`), "still open after a click elsewhere");
  // Escape closes it without sending Escape to the app.
  await stubSend("noContext");
  await stubSend("contextMenu");
  await waitFor(`!!document.querySelector('.otm-menu-context')`, "the third context menu");
  await received(true);
  await press("Escape", "Escape", 27);
  await waitReceived((x) => x.t === "menuAction" && same(x.path, []) && x.context === true, "the close on Escape");
  await sleep(100);
  assert(!(await received()).some((x) => x.t === "key"), "Escape went to the app too");
  await stubSend("noContext");
});

await check("a menu bar that changes while a menu is open shows the change", async () => {
  await clickOn(titleButton("Orders"));
  await waitFor(`!!${menuItem("bar", "Mark All Shipped")} && !${menuItem("bar", "Mark All Shipped")}.disabled`, "Orders open");
  await stubSend("menuShippedOff");
  await waitFor(`!!${menuItem("bar", "Mark All Shipped")} && ${menuItem("bar", "Mark All Shipped")}.disabled`, "Mark All Shipped switched off in the open menu");
  assert(await evaluate(`${titleButton("Orders")}.getAttribute('aria-expanded')`) === "true", "the open menu lost its title");
  await press("Escape", "Escape", 27);
  await stubSend(MENU);
  await waitFor(`!document.querySelector('.otm-menu-bar')`, "closed");
});

await check("when the titles don't fit, one Menu button lists every menu", async () => {
  try {
    await compactMenu();
  } finally {
    await cdp("Emulation.clearDeviceMetricsOverride");
  }
  await waitFor(`!document.getElementById('otm-bar').classList.contains('otm-bar-compact')`, "the titles back at full width");
});

async function compactMenu() {
  await cdp("Emulation.setDeviceMetricsOverride", { width: 560, height: 700, deviceScaleFactor: 2, mobile: false });
  await waitFor(`document.getElementById('otm-bar').classList.contains('otm-bar-compact') && getComputedStyle(document.querySelector('.otm-menu-all')).display !== 'none'`, "the compact bar");
  const bar = await evaluate(`(() => { const r = document.getElementById('otm-bar').getBoundingClientRect(); return { l: r.left, r: r.right }; })()`);
  assert(bar.l >= 0 && bar.r <= 560, "the bar overflows: " + JSON.stringify(bar));
  await received(true);
  await clickOn(`document.querySelector('.otm-menu-all')`);
  await waitFor(`!!document.querySelector('.otm-menu-bar')`, "the all-menus list");
  const m = await openMenuShape("bar");
  const tops = MENU.bar.map((x) => x.title);
  assert(same(m.heads.filter((h) => tops.includes(h)), tops), "headings " + JSON.stringify(m.heads));
  assert(m.x >= 0 && m.x + m.w <= 560, "the list overflows: " + JSON.stringify(m));
  await shot("12-menu-compact");
  await clickOn(menuItem("bar", "Mark All Shipped"));
  await waitReceived((x) => x.t === "menuAction" && same(x.path, ["Orders", "Mark All Shipped"]), "menuAction from the all-menus list");
  assert(!(await received()).some((x) => x.t === "act" || x.t === "pointer"), "the click went through the menu to the app");
}

// ---- extra windows: sheets, alerts, popovers, second windows and menus as surfaces of their own

const winSel = (id) => `document.querySelector('.otm-window[data-window="${id}"]')`;
// Where a window's surface is once its entrance animation (a sheet sliding in, an alert popping in) is over.
const rectOf = (id) => evaluate(`(async () => { const el = ${winSel(id)}; if (!el) return null;
  await Promise.all(el.getAnimations().map((a) => a.finished.catch(() => null)));
  const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);
  return { l: r.left, t: r.top, w: r.width, h: r.height, r: r.right, b: r.bottom, z: Number(cs.zIndex), shown: cs.display !== 'none' && cs.visibility !== 'hidden',
    role: el.getAttribute('role'), modal: el.getAttribute('aria-modal'), label: el.getAttribute('aria-label'), kind: el.dataset.kind }; })()`);
const factor = () => evaluate(`(() => { const r = ${winSel(1)}.getBoundingClientRect(); return r.width / ${fixture.hello.windows[0].w}; })()`);
const near = (a, b, tol = 1.5) => Math.abs(a - b) <= tol;
const allIdsUnique = () => evaluate(`(() => { const ids = [...document.querySelectorAll('[id^="ax-"]')].map((e) => e.id); return ids.length === new Set(ids).size; })()`);
const SHEET = "/Window:/Sheet:";

await check("a sheet is a surface of its own over its window: a dialog with its own layer and ids, taking input, gone when it closes", async () => {
  await received(true);
  for (const m of fixture.named.sheetOpen) await stubSend(m);
  await waitFor(`!!${winSel(2)} && !!${byKey(SHEET + "/Group:/Button:Cancel")}`, "the sheet's surface and layer");
  const main = await rectOf(1), sheet = await rectOf(2), f = await factor();
  assert(sheet.kind === "sheet" && sheet.role === "dialog" && sheet.modal === "true", "sheet semantics " + JSON.stringify(sheet));
  assert(near(sheet.l, main.l + 240 * f) && near(sheet.t, main.t + 28 * f) && near(sheet.w, 380 * f), "sheet at " + JSON.stringify(sheet) + " over " + JSON.stringify(main));
  assert(sheet.z > main.z, "the sheet is under its window");
  // Keys (and so ids) never collide across windows: the main window has its own Cancel.
  const ids = await evaluate(`[${byKey(SHEET + "/Group:/Button:Cancel")}.id, ${byKey(G + "/Button:Cancel")}.id]`);
  assert(ids[0] === domId(SHEET + "/Group:/Button:Cancel") && ids[1] === domId(G + "/Button:Cancel") && ids[0] !== ids[1], "ids " + ids);
  assert(await allIdsUnique(), "two elements share an ax- id");
  assert(await evaluate(`${byKey(SHEET + "/Group:/Button:Cancel")}.closest('.otm-window').dataset.window`) === "2", "the sheet's element isn't in its own layer");
  const end = Date.now() + 3000;
  let painted = false;
  while (!painted && Date.now() < end) {
    painted = await evaluate(`(() => { const c = ${winSel(2)}.querySelector('canvas'); return c.width === ${380 * 2} && c.getContext('2d').getImageData(20, 20, 1, 1).data[3] > 0; })()`);
    if (!painted) await sleep(50);
  }
  assert(painted, "the sheet's frame didn't paint its canvas");
  // The comment picker finds the sheet's own button and labels it.
  const c = await nodeCenter(SHEET + "/Group:/Button:Cancel");
  const picked = await evaluate(`(() => { ${collabLabelSource()} const el = document.elementFromPoint(${c.x}, ${c.y}); return el.dataset.key + '|' + labelFor(el); })()`);
  assert(picked === SHEET + "/Group:/Button:Cancel|Cancel", "picker over the sheet: " + picked);
  await shot("13-sheet");
  await received(true);
  await click(c.x, c.y);
  const acts = await waitReceived((m) => m.t === "act", "act press on the sheet's Cancel");
  assert(acts[0].window === 2 && acts[0].key === SHEET + "/Group:/Button:Cancel" && acts[0].action === "press", JSON.stringify(acts));
  assert(!(await received()).some((m) => m.t === "windowAction"), "a press in a sheet asked to focus a window");
  await stubSend("onlyMain");
  await waitFor(`!${winSel(2)} && !${byKey(SHEET + "/Group:/Button:Cancel")}`, "the sheet to go");
  assert(await evaluate(`!!${byKey(ADD)} && ${byKey(ADD)}.id === 'ax-3tt01y'`), "the main window's layer suffered");
});

await check("an alert is centred over its window and its buttons act on it", async () => {
  for (const m of fixture.named.alertOpen) await stubSend(m);
  const DELETE = "/Window:/Sheet:alert/Button:Delete";
  await waitFor(`!!${winSel(3)} && !!${byKey(DELETE)}`, "the alert");
  const main = await rectOf(1), alert = await rectOf(3), f = await factor();
  assert(alert.role === "dialog" && alert.kind === "alert", "alert semantics " + JSON.stringify(alert));
  assert(near(alert.l + alert.w / 2, main.l + main.w / 2) && near(alert.t, main.t + 28 * f), "alert at " + JSON.stringify(alert));
  await received(true);
  await clickOn(byKey(DELETE));
  const acts = await waitReceived((m) => m.t === "act", "act press on Delete");
  assert(acts[0].window === 3 && acts[0].key === DELETE, JSON.stringify(acts));
  await stubSend("onlyMain");
  await waitFor(`!${winSel(3)}`, "the alert to go");
});

await check("a popover shows at its frame, overhanging its window without rescaling the desk; clicks in it go to it", async () => {
  const before = await evaluate(`document.getElementById('otm-stage').style.transform + '|' + document.getElementById('otm-fit').style.width`);
  for (const m of fixture.named.popoverOpen) await stubSend(m);
  await waitFor(`!!${winSel(4)}`, "the popover");
  const main = await rectOf(1), pop = await rectOf(4), f = await factor();
  assert(near(pop.l, main.l + 600 * f) && near(pop.t, main.t + 520 * f) && pop.b > main.b, "popover at " + JSON.stringify(pop) + " over " + JSON.stringify(main));
  const after = await evaluate(`document.getElementById('otm-stage').style.transform + '|' + document.getElementById('otm-fit').style.width`);
  assert(after === before, "the desk rescaled for a popover: " + before + " -> " + after);
  await received(true);
  const p = { x: pop.l + 200 * f, y: pop.t + 90 * f };
  await click(p.x, p.y);
  const downs = await waitReceived((m) => m.t === "pointer" && m.kind === "down", "a click in the popover");
  assert(downs[0].window === 4 && near(downs[0].x, 200, 2) && near(downs[0].y, 90, 2), JSON.stringify(downs));
  await stubSend("onlyMain");
  await waitFor(`!${winSel(4)}`, "the popover to go");
});

await check("a second window sits beside the main one with its own surface; a press in another window focuses it first", async () => {
  for (const m of fixture.named.secondWindow) await stubSend(m);
  const STATS = "/Window:Statistics/Group:/Button:Cancel";
  await waitFor(`!!${winSel(5)} && !!${byKey(STATS)}`, "the Statistics window");
  const main = await rectOf(1), stats = await rectOf(5), f = await factor();
  assert(near(stats.l, main.r + 32 * f, 2) && near(stats.t, main.t) && near(stats.w, 360 * f) && stats.shown, "second window at " + JSON.stringify(stats) + ", main " + JSON.stringify(main));
  assert(await evaluate(`document.querySelector('.otm-tabs').hidden`), "tabs show while the windows fit side by side");
  assert(await allIdsUnique(), "ids collide across windows");
  await shot("14-second-window");
  await received(true);
  await clickOn(byKey(STATS));
  let got = await waitReceived((m) => m.t === "act", "act in the second window");
  assert(got[0].window === 5 && got[0].key === STATS, JSON.stringify(got));
  // The app's key window is Statistics (focused in the list): a press in the main window focuses that first.
  await received(true);
  const p = await windowPoint(600, 420);
  await click(p.x, p.y);
  got = await waitReceived((m) => m.t === "pointer" && m.kind === "down", "a click in the main window");
  const list = await received();
  const focus = list.findIndex((m) => m.t === "windowAction");
  const down = list.findIndex((m) => m.t === "pointer" && m.kind === "down");
  assert(focus >= 0 && focus < down && list[focus].window === 1 && list[focus].action === "focus", "no focus before the click: " + JSON.stringify(list));
});

await check("when side by side would be too small the windows become tabs: a tab shows its window and focuses it, × closes it", async () => {
  try {
    await cdp("Emulation.setDeviceMetricsOverride", { width: 1000, height: 800, deviceScaleFactor: 2, mobile: false });
    await waitFor(`!document.querySelector('.otm-tabs').hidden && document.querySelectorAll('.otm-tab').length === 2`, "two tabs");
    let main = await rectOf(1), stats = await rectOf(5);
    assert(!main.shown && stats.shown, "the focused new window isn't the tab that shows: " + JSON.stringify([main.shown, stats.shown]));
    const tabs = await evaluate(`[...document.querySelectorAll('.otm-tab')].map((t) => t.querySelector('.otm-tab-title').textContent + (t.querySelector('.otm-tab-close') ? '×' : ''))`);
    assert(same(tabs, ["Orbit", "Statistics×"]), "tabs " + JSON.stringify(tabs));
    const r = await evaluate(`(() => { const t = document.querySelector('.otm-tabs').getBoundingClientRect(); const w = ${winSel(5)}.getBoundingClientRect(); return { tb: t.bottom, wt: w.top }; })()`);
    assert(r.tb <= r.wt, "the tabs cover the window: " + JSON.stringify(r));
    await shot("15-tabs-1000");
    await received(true);
    await clickOn(`document.querySelector('.otm-tab[data-window="1"] .otm-tab-title')`);
    await waitReceived((m) => m.t === "windowAction" && m.window === 1 && m.action === "focus", "focus from the tab");
    main = await rectOf(1);
    stats = await rectOf(5);
    assert(main.shown && !stats.shown, "the tab didn't switch windows");
    await clickOn(`document.querySelector('.otm-tab[data-window="5"] .otm-tab-close')`);
    await waitReceived((m) => m.t === "windowAction" && m.window === 5 && m.action === "close", "close from the tab");
    await stubSend("onlyMain");
    await waitFor(`!${winSel(5)} && document.querySelector('.otm-tabs').hidden`, "the second window and the tabs to go");
  } finally {
    await cdp("Emulation.clearDeviceMetricsOverride");
  }
  await waitFor(`(() => { const r = ${winSel(1)}.getBoundingClientRect(); return r.width > 0 && getComputedStyle(${winSel(1)}).display !== 'none'; })()`, "the main window back");
});

await check("a popped-up menu's own window gives way to the web context menu", async () => {
  await stubSend("menuWindowOpen");
  await waitFor(`!!${winSel(6)}`, "the menu's window");
  assert((await rectOf(6)).shown, "the menu's pixels hide while there is no web menu");
  await stubSend("contextMenu");
  await waitFor(`!!document.querySelector('.otm-menu-context')`, "the web context menu");
  assert(!(await rectOf(6)).shown, "the menu's pixels show under the web menu");
  await press("Escape", "Escape", 27);
  await stubSend("noContext");
  await stubSend("onlyMain");
  await waitFor(`!${winSel(6)}`, "the menu's window to go");
});

// ---- the Simple view: below 700 px the tree as a page of real text and controls

function collabAnchorSource() {
  return collabLabelSource() + "\n" + ["const MAX_DEPTH", "const MAX_ANCHOR", "function uniqueIdSelector", "function nthOfType", "function anchorFor"]
    .map((s) => takeFromCollab(s)).join("\n");
}
const ROW2 = G + "/List:/Row:Grace Hopper#2";
const PIN = G + "/SecureTextField:PIN";
const PINNED = [ADD, CUSTOMER, CHECK, STEPPER, ROW2, G + "/StaticText:New Order", G + "/List:"];
const inSimple = (key) => `document.querySelector('#otm-simple [data-key="' + CSS.escape(${JSON.stringify(key)}) + '"]')`;
// Anchors collab.js would store for a comment on each element, as { key: selector }.
const anchorsOf = (rootSel) => evaluate(`(() => { ${collabAnchorSource()}
  const out = {};
  for (const key of ${JSON.stringify(PINNED)}) {
    const el = document.querySelector(${JSON.stringify(rootSel)} + ' [data-key="' + CSS.escape(key) + '"]');
    const a = el && anchorFor(el, null);
    out[key] = a && a.el === el ? a.selector : null;
  }
  return out; })()`);
// Where a selector resolves now: which view, and whether it's rendered.
const resolve = (sel) => evaluate(`(() => { const all = document.querySelectorAll(${JSON.stringify(sel)}); const el = all[0];
  return { count: all.length, view: el ? (el.closest('#otm-simple') ? 'simple' : el.closest('#otm-desk') ? 'window' : 'other') : null,
    rendered: !!el && el.getClientRects().length > 0, key: el ? el.dataset.key : null }; })()`);
async function simpleCenter(key, fx = 0.5) {
  return evaluate(`(() => { const el = ${inSimple(key)}; if (!el) return null; el.scrollIntoView({ block: 'center' });
    const r = el.getBoundingClientRect(); return { x: r.left + r.width * ${fx}, y: r.top + r.height / 2 }; })()`);
}
const tap = (p) => cdp("Input.synthesizeTapGesture", { x: p.x, y: p.y, gestureSourceType: "touch" });
let windowAnchors = null;

await check("the window view's comment anchors are the elements' ax- ids (collab.js's anchorFor)", async () => {
  windowAnchors = await anchorsOf("#otm-desk");
  for (const key of PINNED) assert(windowAnchors[key] === "#" + domId(key), key + " anchors as " + windowAnchors[key]);
});

await check("below 700 px the Simple view replaces the window: real text and controls, in reading order", async () => {
  await cdp("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
  await cdp("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
  await waitFor(`document.body.dataset.view === 'simple' && !!${inSimple(ADD)} && ${inSimple(ADD)}.getClientRects().length > 0`, "the Simple view");
  const v = await evaluate(`({ desk: document.getElementById('otm-desk').hidden, simple: document.getElementById('otm-simple').hidden,
    pressed: document.getElementById('otm-view-simple').getAttribute('aria-pressed'), width: document.documentElement.scrollWidth })`);
  assert(v.desk && !v.simple && v.pressed === "true", "views: " + JSON.stringify(v));
  assert(v.width <= 390, "the page is wider than the phone: " + v.width);
  const order = await evaluate(`[...document.querySelectorAll('#otm-simple .otm-s-node')].filter((el) => el.getClientRects().length).map((el) => el.dataset.key)`);
  const want = ["/Window:", G, G + "/StaticText:New Order", G + "/StaticText:Customer", CUSTOMER, G + "/StaticText:PIN", PIN,
    G + "/StaticText:Quantity", G + "/StaticText:1", STEPPER, CHECK, G + "/List:", G + "/List:/Row:Ada Lovelace", G + "/List:/Row:Grace Hopper",
    ROW2, G + "/StaticText:3 orders", G + "/Button:Cancel", ADD];
  assert(JSON.stringify(order) === JSON.stringify(want), "reading order " + JSON.stringify(order));
  const look = await evaluate(`(() => { const at = (k) => document.querySelector('#otm-simple [data-key="' + CSS.escape(k) + '"]');
    const cs = (el) => getComputedStyle(el);
    const add = at(${JSON.stringify(ADD)}), cust = at(${JSON.stringify(CUSTOMER)}), pin = at(${JSON.stringify(PIN)}), chk = at(${JSON.stringify(CHECK)});
    const title = at(${JSON.stringify(G + "/StaticText:New Order")}), row = at(${JSON.stringify(ROW2)}), step = at(${JSON.stringify(STEPPER)});
    return { add: add.localName + '|' + add.textContent + '|' + cs(add).color + '|' + add.getBoundingClientRect().height,
      cust: cust.localName + '|' + cust.type + '|' + cust.placeholder + '|' + cs(cust).fontSize + '|' + cust.getBoundingClientRect().height,
      pin: pin.localName + '|' + pin.type, chk: chk.localName + '|' + (chk.querySelector('input') || {}).type + '|' + chk.textContent + '|' + chk.getAttribute('aria-checked'),
      title: title.localName + '|' + title.textContent + '|' + parseFloat(cs(title).fontSize), row: row.textContent + '|' + row.getAttribute('role') + '|' + row.parentElement.closest('.otm-s-node').getAttribute('role'),
      step: step.getAttribute('role') + '|' + step.classList.contains('otm-s-novalue'),
      lineOfCustomer: cust.parentElement.classList.contains('otm-s-line') && cust.parentElement === at(${JSON.stringify(G + "/StaticText:Customer")}).parentElement }; })()`);
  assert(look.add.startsWith("button|Add Order|rgb(") && Number(look.add.split("|")[3]) >= 44, "Add Order: " + look.add);
  assert(look.cust.startsWith("input|text|Customer|17px|") && Number(look.cust.split("|")[4]) >= 44, "Customer field: " + look.cust);
  assert(look.pin === "input|password", "PIN: " + look.pin);
  assert(look.chk === "label|checkbox|Express shipping|false", "checkbox: " + look.chk);
  assert(look.title.startsWith("p|New Order|") && Number(look.title.split("|")[2]) >= 20, "title: " + look.title);
  assert(look.row === "Grace Hopper|listitem|list", "row: " + look.row);
  assert(look.step === "spinbutton|true", "stepper (its number shows as the text beside it): " + look.step);
  assert(look.lineOfCustomer, "the Customer label and field aren't on one line");
  const thumb = await evaluate(`(() => { const c = document.getElementById('otm-thumb'); const r = c.getBoundingClientRect();
    const d = c.getContext('2d').getImageData(Math.floor(c.width / 2), Math.floor(c.height / 2), 1, 1).data;
    return { w: c.width, top: r.top, alpha: d[3] }; })()`);
  assert(thumb.w > 1 && thumb.alpha === 255 && thumb.top < 120, "live thumbnail: " + JSON.stringify(thumb));
  await evaluate(`window.scrollTo(0, 0), true`);
  await shot("6-simple-390");
});

await check("Simple view ids are the layer's ids, unique, and only on what shows", async () => {
  const ids = await evaluate(`({ simple: [...document.querySelectorAll('#otm-simple .otm-s-node')].filter((el) => el.getClientRects().length).map((el) => [el.dataset.key, el.id]),
    desk: document.querySelectorAll('#otm-desk [id^="ax-"]').length,
    dupes: (() => { const seen = new Set(), d = []; for (const el of document.querySelectorAll('[id]')) { if (seen.has(el.id)) d.push(el.id); seen.add(el.id); } return d; })() })`);
  for (const [key, id] of ids.simple) assert(id === domId(key), key + " has id " + id);
  assert(ids.simple.some(([, id]) => id === "ax-3tt01y"), "no #ax-3tt01y in the Simple view");
  assert(ids.desk === 0, ids.desk + " hidden layer elements still carry ids");
  assert(ids.dupes.length === 0, "duplicate ids " + ids.dupes.join(","));
});

await check("tapping Add Order in the Simple view sends act press; checkbox, stepper and rows map like the window's", async () => {
  await received(true);
  await tap(await simpleCenter(ADD));
  const acts = await waitReceived((m) => m.t === "act", "act press from a tap");
  assert(acts.length === 1 && acts[0].window === 1 && acts[0].key === ADD && acts[0].action === "press", JSON.stringify(acts));
  assert(!(await received()).some((m) => m.t === "pointer"), "the tap also sent pointer events");
  await received(true);
  await tap(await simpleCenter(CHECK));
  await waitReceived((m) => m.t === "act" && m.key === CHECK && m.action === "press", "act press on the checkbox");
  assert(await evaluate(`${inSimple(CHECK)}.querySelector('input').checked && ${inSimple(CHECK)}.getAttribute('aria-checked') === 'true'`), "checkbox didn't flip at once");
  await stubSend({ ...tree1, v: "tree-1s" }); // the app didn't change it after all
  await waitFor(`!${inSimple(CHECK)}.querySelector('input').checked`, "the app's truth on the checkbox");
  await received(true);
  await tap(await simpleCenter(STEPPER, 0.25));
  await tap(await simpleCenter(STEPPER, 0.75));
  await waitReceived((m) => m.t === "act" && m.action === "increment", "increment");
  const steps = (await received()).filter((m) => m.t === "act").map((m) => m.key === STEPPER && m.action);
  assert(JSON.stringify(steps) === '["decrement","increment"]', "stepper " + JSON.stringify(steps));
  await received(true);
  await tap(await simpleCenter(ROW2));
  await waitReceived((m) => m.t === "pointer" && m.kind === "up", "a row tap");
  const ps = (await received()).filter((m) => m.t === "pointer");
  assert(ps.length === 2 && ps[0].kind === "down" && ps[0].x === 648 && ps[0].y === 165 && ps[0].window === 1, "row tap " + JSON.stringify(ps));
});

await check("typing in a Simple view field sends its whole value as setText, then Enter as key", async () => {
  await received(true);
  await tap(await simpleCenter(CUSTOMER));
  await waitFor(`document.activeElement === ${inSimple(CUSTOMER)}`, "the field to take focus");
  await cdp("Input.insertText", { text: "Ada" });
  await cdp("Input.insertText", { text: " Love" });
  await cdp("Input.insertText", { text: "lace" });
  await press("Enter", "Enter", 13, "\r");
  await waitReceived((m) => m.t === "key", "key Enter");
  const got = await received(true);
  const sets = got.filter((m) => m.t === "setText");
  assert(sets.length >= 1 && sets.every((m) => m.key === CUSTOMER && m.window === 1), "setText " + JSON.stringify(sets));
  assert(sets[sets.length - 1].value === "Ada Lovelace", "last setText " + JSON.stringify(sets));
  const last = got.findIndex((m) => m === sets[sets.length - 1]), enter = got.findIndex((m) => m.t === "key");
  assert(enter > last && got[enter].code === "Enter", "Enter didn't follow the value: " + JSON.stringify(got));
  assert(!got.some((m) => m.t === "text" || (m.t === "pointer" && m.kind !== "move")), "typing sent text or pointer: " + JSON.stringify(got));
  await stubSend({ ...tree1, v: "tree-1t" }); // the app's older value while typing doesn't overwrite it
  await sleep(150);
  assert(await evaluate(`${inSimple(CUSTOMER)}.value`) === "Ada Lovelace", "a tree overwrote the field mid-typing");
  await shot("7-simple-typing");
  await evaluate(`document.activeElement.blur(), true`);
});

await check("the Simple view follows new trees and keeps its elements", async () => {
  await evaluate(`document.querySelectorAll('#otm-simple .otm-s-node').forEach((el) => (el.__mark = el.dataset.key)), true`);
  await stubSend("tree2");
  await waitFor(`!!${inSimple(G + "/List:/Row:Ada")} && !${inSimple(G + "/StaticText:3 orders")}`, "tree 2 in the Simple view");
  const st = await evaluate(`[...document.querySelectorAll('#otm-simple .otm-s-node')].map((el) => ({ key: el.dataset.key, mark: el.__mark || null, value: el.value ?? null }))`);
  const before = new Set(tree1.nodes.map((n) => n.key));
  for (const n of tree2.nodes) {
    const el = st.find((e) => e.key === n.key);
    assert(el, "no Simple element for " + n.key);
    if (before.has(n.key)) assert(el.mark === n.key, "element for " + n.key + " was recreated");
  }
  assert(st.find((e) => e.key === CUSTOMER).value === "Ada", "field didn't take the app's value");
  const rows = await evaluate(`[...${inSimple(G + "/List:")}.querySelectorAll('[role=listitem]')].map((el) => el.textContent)`);
  assert(JSON.stringify(rows) === '["Ada Lovelace","Grace Hopper","Grace Hopper","Ada"]', "rows " + JSON.stringify(rows));
});

await check("a sheet floats over the Simple view as a dialog, and its controls act on its window", async () => {
  const sheet = { id: 2, title: "Confirm", w: 400, h: 160, x: 230, y: 28, kind: "sheet", parent: 1 };
  await stubSend({ t: "windows", windows: [fixture.hello.windows[0], sheet] });
  await stubSend({ t: "tree", window: 2, v: "sheet-1", nodes: [
    { key: "/Window:", role: "AXWindow", label: "", value: null, x: 0, y: 0, w: 400, h: 160, depth: 0, enabled: true, focused: false, selected: false, actions: [] },
    { key: "/Window:/StaticText:Place the order?", role: "AXStaticText", label: "Place the order?", value: null, x: 20, y: 20, w: 360, h: 20, depth: 1, enabled: true, focused: false, selected: false, actions: [] },
    { key: "/Window:/Button:Not Now", role: "AXButton", label: "Not Now", value: null, x: 180, y: 120, w: 90, h: 24, depth: 1, enabled: true, focused: false, selected: false, actions: ["press"] },
    { key: "/Window:/Button:Place", role: "AXButton", label: "Place", value: null, x: 290, y: 120, w: 90, h: 24, depth: 1, enabled: true, focused: false, selected: false, actions: ["press"] }] });
  const sheetEl = `document.querySelector('#otm-simple .otm-s-window[data-window="2"]')`;
  await waitFor(`!!${sheetEl} && !!${sheetEl}.querySelector('[data-key="/Window:/Button:Place"]')`, "the sheet in the Simple view");
  const look = await evaluate(`(() => { const el = ${sheetEl}; const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);
    return { pos: cs.position, role: el.getAttribute('role'), head: el.querySelector('.otm-s-head').textContent, bottom: r.bottom, w: r.width,
      text: [...el.querySelectorAll('.otm-s-node')].filter((n) => n.getClientRects().length).map((n) => n.textContent.trim()).filter(Boolean) }; })()`);
  assert(look.pos === "fixed" && look.role === "dialog" && look.bottom <= 844 && look.w <= 390, "sheet: " + JSON.stringify(look));
  assert(look.head === "Confirm" && JSON.stringify(look.text.slice(-3)) === '["Place the order?","Not Now","Place"]', "sheet content: " + JSON.stringify(look));
  await received(true);
  const p = await evaluate(`(() => { const r = ${sheetEl}.querySelector('[data-key="/Window:/Button:Place"]').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  await tap(p);
  const acts = await waitReceived((m) => m.t === "act", "act press in the sheet");
  assert(acts[0].window === 2 && acts[0].key === "/Window:/Button:Place" && acts[0].action === "press", JSON.stringify(acts));
  await evaluate(`document.body.dataset.appearance = 'dark', true`);
  await shot("9-simple-sheet-dark");
  await evaluate(`document.body.dataset.appearance = 'light', true`);
  await stubSend({ t: "windows", windows: [fixture.hello.windows[0]] });
  await waitFor(`!${sheetEl}`, "the sheet to go");
});

await check("a comment pinned in either view finds the same element in the other (collab.js's anchorFor and labelFor)", async () => {
  const simpleAnchors = await anchorsOf("#otm-simple");
  for (const key of PINNED) {
    assert(simpleAnchors[key] === windowAnchors[key], key + ": Simple view anchors as " + simpleAnchors[key] + ", the window as " + windowAnchors[key]);
    const r = await resolve(windowAnchors[key]);
    assert(r.count === 1 && r.view === "simple" && r.rendered && r.key === key, "window anchor " + windowAnchors[key] + " in the Simple view: " + JSON.stringify(r));
  }
  const c = await simpleCenter(ADD);
  const picked = await evaluate(`(() => { ${collabLabelSource()} const el = document.elementFromPoint(${c.x}, ${c.y});
    return el.localName + '#' + el.id + '|' + labelFor(el) + '|' + labelFor(${inSimple(CHECK)}); })()`);
  assert(picked === "button#ax-3tt01y|Button \u201cAdd Order\u201d|Checkbox \u201cExpress shipping\u201d", "picker in the Simple view: " + picked);
  // And back: the bar's toggle shows the window at this size; the Simple view's anchors land on the layer.
  await evaluate(`document.getElementById('otm-view-window').click(), true`);
  await waitFor(`document.body.dataset.view === 'window' && !document.getElementById('otm-desk').hidden`, "the window view");
  for (const key of PINNED) {
    const r = await resolve(simpleAnchors[key]);
    assert(r.count === 1 && r.view === "window" && r.rendered && r.key === key, "Simple anchor " + simpleAnchors[key] + " in the window view: " + JSON.stringify(r));
  }
  assert(await evaluate(`document.querySelectorAll('#otm-simple [id^="ax-"]').length`) === 0, "hidden Simple elements still carry ids");
});

await check("the bar's toggle switches views at any size, and the choice sticks", async () => {
  await cdp("Emulation.setTouchEmulationEnabled", { enabled: false });
  await cdp("Emulation.clearDeviceMetricsOverride");
  await sleep(100);
  assert(await evaluate(`document.body.dataset.view`) === "window", "not the window view at 1440");
  const b = await evaluate(`(() => { const r = document.getElementById('otm-view-simple').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  await click(b.x, b.y);
  await waitFor(`document.body.dataset.view === 'simple' && !!${inSimple(ADD)} && ${inSimple(ADD)}.id === 'ax-3tt01y'`, "Simple view at 1440");
  assert(await evaluate(`localStorage.getItem('opentraffic.macapp.view')`) === "simple", "choice not kept");
  const wide = await evaluate(`(() => { const r = document.getElementById('otm-simple').getBoundingClientRect(); return r.width; })()`);
  assert(wide <= 640, "the Simple view isn't a readable column at 1440: " + wide);
  await shot("8-simple-1440");
  const w = await evaluate(`(() => { const r = document.getElementById('otm-view-window').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
  await click(w.x, w.y);
  await waitFor(`document.body.dataset.view === 'window' && ${byKey(ADD)} === document.getElementById('ax-3tt01y')`, "back to the window");
  const pressed = await evaluate(`document.getElementById('otm-view-window').getAttribute('aria-pressed') + document.getElementById('otm-view-simple').getAttribute('aria-pressed')`);
  assert(pressed === "truefalse", "toggle state " + pressed);
});

await check("fits a small viewport and still maps clicks to window points", async () => {
  // Below 700 px the Simple view shows unless the viewer chose the window in the bar (the check above did).
  assert(await evaluate(`document.body.dataset.view`) === "window", "the viewer's choice of the window view didn't hold");
  await cdp("Emulation.setDeviceMetricsOverride", { width: 600, height: 480, deviceScaleFactor: 2, mobile: false });
  await waitFor(`/scale\\(0\\.\\d+\\)/.test(document.getElementById('otm-stage').style.transform)`, "the stage to scale down");
  const r = await evaluate(`(() => { const r = document.querySelector('.otm-window').getBoundingClientRect(); return { l: r.left, t: r.top, w: r.width, h: r.height, b: r.bottom, ri: r.right }; })()`);
  assert(r.l >= 0 && r.t >= 0 && r.ri <= 600 && r.b <= 480, "window doesn't fit: " + JSON.stringify(r));
  await received(true);
  const p = await windowPoint(400, 400);
  await click(p.x, p.y);
  const c = await nodeCenter(ADD);
  await click(c.x, c.y);
  await waitReceived((m) => m.t === "act", "act at small size");
  const down = (await received()).find((m) => m.t === "pointer" && m.kind === "down");
  assert(down && Math.abs(down.x - 400) <= 2 && Math.abs(down.y - 400) <= 2, "scaled click landed at " + (down && down.x + "," + down.y));
  await shot("5-fit-600");
  await cdp("Emulation.clearDeviceMetricsOverride");
});

await check("no console errors", async () => {
  assert(consoleErrors.length === 0, consoleErrors.join(" | "));
});

const failed = results.filter((r) => !r[0]);
console.log(`\n${results.length - failed.length}/${results.length} checks passed` + (OUT ? `; screenshots in ${OUT}` : ""));
ws.close();
cleanup();
process.exit(failed.length ? 1 : 0);
