#!/usr/bin/env node
// Headless Chrome test of the Mac app viewer page (macapp-viewer.html/.js/.css) against the stub
// replay server (script/macapp-viewer-stub.mjs). Node only, no npm packages; Chrome driven over raw CDP.
//
//   node script/macapp-viewer-test.mjs [--out <dir>]      screenshots go to <dir> when given
//
// Checks: one layer element per node with the protocol's DOM ids, stable across trees; collab.js's
// picker sees and labels the elements (not the canvas); clicks, typing (IME too), keys, pointer, wheel
// map to the protocol's messages; optimistic feedback; tiles paint; cursor, status, reconnect and boot;
// fit-to-viewport; no console errors. Exits 1 on a failure; skips (exit 0) without Google Chrome.
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

// collab.js's own picker label code, taken from the file, so the check follows it when it changes.
function collabLabelSource() {
  const src = fs.readFileSync(path.join(root, "Sources", "OpenTraffic", "Resources", "collab.js"), "utf8");
  const take = (start) => {
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
  };
  return ["const CONTROL_RE", "const MAX_LABEL", "function oneLine", "const INPUT_KINDS", "const EDITABLE_SEL", "function fieldKind", "function labelFor"]
    .map(take).join("\n");
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
  const tag = await evaluate(`document.getElementById('otm-bar').textContent.replace(/\\s+/g, ' ').trim()`);
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

await check("collab.js's picker hits the overlay elements and labels them by their names", async () => {
  const c = await nodeCenter(ADD);
  const hit = await evaluate(`(() => { const el = document.elementFromPoint(${c.x}, ${c.y}); return el && (el.localName + '#' + el.id); })()`);
  assert(hit === "div#ax-3tt01y", "elementFromPoint at Add Order: " + hit);
  const labels = await evaluate(`(() => { ${collabLabelSource()}
    const at = (key) => document.querySelector('[data-key="' + CSS.escape(key) + '"]');
    return { add: labelFor(at(${JSON.stringify(ADD)})), heading: labelFor(at(${JSON.stringify(G + "/StaticText:New Order")})),
      field: labelFor(at(${JSON.stringify(CUSTOMER)})), row: labelFor(at(${JSON.stringify(G + "/List:/Row:Grace Hopper#2")})),
      blank: labelFor(at(${JSON.stringify(G)})), unique: document.querySelectorAll('#ax-3tt01y').length }; })()`);
  assert(labels.add === "Add Order", "Add Order labelled " + labels.add);
  assert(labels.heading === "New Order", "heading labelled " + labels.heading);
  assert(labels.field === "text field", "field labelled " + labels.field);
  assert(labels.row === "Grace Hopper", "row labelled " + labels.row);
  assert(labels.blank === "Orbit window", "blank group labelled " + labels.blank);
  assert(labels.unique === 1, "#ax-3tt01y isn't unique");
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
  await shot("2-typing");
  // A tree with the app's (older) value while typing doesn't overwrite what the viewer typed.
  await stubSend({ ...tree2, v: "tree-2c" });
  await sleep(150);
  assert(await evaluate(`${byKey(CUSTOMER)}.value`) === look.value, "a tree overwrote the field mid-typing");
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

await check("fits a small viewport and still maps clicks to window points", async () => {
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
