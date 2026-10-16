// Records a real collaboration session on the shared demo site from two seats: Ava, the host (who
// watches, opens the comment, looks at Mia's phone, and leads everyone into hers), and Lea (who
// comments with a suggested edit, comments on an area, and follows Ava). Sam points and draws; Mia is
// on an iPhone. Four headless Chromes in one session, the visitors through the public link and Ava
// through the host link; the comments are fixed by the coding agent OpenTraffic runs for them (sent to it
// at set moments, as the comment's Send to button does, so the recording doesn't race the agent).
//
// It records in slow motion so the result is smooth: the pages' animations and transitions run ten
// times slower (pages inside device views too), the script moves everyone one 1/30 s step at a time,
// and both seats are screenshotted after each step. Played back at 30 fps, everything moves at its
// real speed, except the agent, which works at its own speed (a few seconds become a fraction of one).
// A screenshot doesn't show the seat's own pointer, so its position is saved per frame for the video.
//   node record-session.mjs <public-url> <host-url> <api-token> [out-folder]
import { spawn } from "node:child_process"
import fs from "node:fs"

const [url, hostUrl, token, OUT = "/tmp/ot-session"] = process.argv.slice(2)
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const API = "http://127.0.0.1:47799/v1/shares/Orbit"
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const FPS = 30
const SLOW = 10 // wall-clock seconds per recorded second
const SCALE = 1.5

// Slows the page's JavaScript clock along with its animations, so timers (a point pulse's lifetime,
// the stale-cursor sweep) keep their real length in the recording. Starts at normal speed.
const SLOW_CLOCK = `(() => {
  const realPerf = performance.now.bind(performance)
  const offset = Date.now() - realPerf()
  const st = window.setTimeout, si = window.setInterval
  let scale = 1, anchorReal = realPerf(), anchorVirtual = anchorReal
  const virtual = () => anchorVirtual + (realPerf() - anchorReal) / scale
  window.__otTimeScale = (s) => { anchorVirtual = virtual(); anchorReal = realPerf(); scale = s }
  performance.now = virtual
  Date.now = () => Math.round(offset + virtual())
  window.setTimeout = (fn, ms = 0, ...args) => st(fn, ms * scale, ...args)
  window.setInterval = (fn, ms = 0, ...args) => si(fn, ms * scale, ...args)
})()`

fs.rmSync(OUT, { recursive: true, force: true })
for (const seat of ["ava", "lea"]) fs.mkdirSync(`${OUT}/${seat}`, { recursive: true })

const chromes = []
function launch(port, scale) {
  const dir = `/tmp/ot-chrome-${port}`
  fs.rmSync(dir, { recursive: true, force: true })
  chromes.push(spawn(CHROME, [
    `--remote-debugging-port=${port}`, "--headless=new", `--user-data-dir=${dir}`, "--no-first-run",
    "--no-default-browser-check", "--hide-scrollbars", "--mute-audio", "--window-size=1440,900",
    `--force-device-scale-factor=${scale}`, "--blink-settings=preferredColorScheme=1", "about:blank",
  ], { stdio: "ignore" }))
}

class Page {
  rate = 1
  static async open(port) {
    for (let i = 0; i < 50; i++) {
      try {
        const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
        const page = list.find((t) => t.type === "page")
        if (page) return await new Page().connect(page.webSocketDebuggerUrl)
      } catch {}
      await sleep(200)
    }
    throw new Error(`Chrome on ${port} didn't start`)
  }
  async connect(ws) {
    this.id = 0
    this.pending = new Map()
    this.listeners = []
    this.ws = new WebSocket(ws)
    await new Promise((resolve) => (this.ws.onopen = resolve))
    this.ws.onmessage = (event) => {
      const message = JSON.parse(event.data)
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id)
        this.pending.delete(message.id)
        message.error ? reject(new Error(message.error.message)) : resolve(message.result)
      } else if (message.method) {
        for (const l of this.listeners) l(message)
      }
    }
    return this
  }
  send(method, params = {}) {
    const id = ++this.id
    this.ws.send(JSON.stringify({ id, method, params }))
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }))
  }
  once(method) {
    return new Promise((resolve) => {
      const l = (m) => { if (m.method === method) { this.listeners = this.listeners.filter((x) => x !== l); resolve(m) } }
      this.listeners.push(l)
    })
  }
  async visit(name, to = url, setup) {
    await this.send("Page.enable")
    await this.send("Runtime.enable")
    if (setup) await setup(this)
    await this.send("Page.addScriptToEvaluateOnNewDocument", {
      source: `try { localStorage.setItem("__opentraffic_collab_name", ${JSON.stringify(name)}) } catch {}`,
    })
    await this.send("Page.addScriptToEvaluateOnNewDocument", { source: SLOW_CLOCK })
    // Pages that load later (a device view's frame, a reload) run at the session's speed too.
    this.listeners.push((m) => {
      if (m.method !== "Runtime.executionContextCreated" || !m.params.context.auxData?.isDefault || this.rate === 1) return
      this.send("Runtime.evaluate", { expression: `window.__otTimeScale && __otTimeScale(${this.rate})`, contextId: m.params.context.id }).catch(() => {})
      this.send("Animation.setPlaybackRate", { playbackRate: 1 / this.rate }).catch(() => {})
    })
    const loaded = this.once("Page.loadEventFired")
    await this.send("Page.navigate", { url: to })
    await loaded
    await this.send("DOM.enable")
  }
  async rect(selector) {
    const { result } = await this.send("Runtime.evaluate", {
      expression: `JSON.stringify(document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect())`,
      returnByValue: true,
    })
    return JSON.parse(result.value)
  }
  async center(selector, fx = 0.5, fy = 0.5) {
    const r = await this.rect(selector)
    return { x: r.x + r.width * fx, y: r.y + r.height * fy }
  }
  /** Center of an element inside the overlay's (closed) shadow root, by class and/or label. */
  async overlay({ cls, label, text }) {
    const { root } = await this.send("DOM.getDocument", { depth: -1, pierce: true })
    const matches = []
    const walk = (node) => {
      const attrs = node.attributes ?? []
      const value = (name) => { const i = attrs.indexOf(name); return i >= 0 ? attrs[i + 1] : undefined }
      const classes = (value("class") ?? "").split(/\s+/)
      const own = (node.children ?? []).filter((c) => c.nodeType === 3).map((c) => c.nodeValue).join("").trim()
      if (node.nodeType === 1 && (!cls || classes.includes(cls)) && (!label || [value("aria-label"), value("title")].includes(label)) && (!text || own === text)) matches.push(node)
      for (const child of [...(node.children ?? []), ...(node.shadowRoots ?? []), ...(node.contentDocument ? [node.contentDocument] : [])]) walk(child)
    }
    walk(root)
    for (const node of matches.reverse()) {
      try {
        const { model } = await this.send("DOM.getBoxModel", { nodeId: node.nodeId })
        const q = model.content
        return { x: (q[0] + q[4]) / 2, y: (q[1] + q[5]) / 2 }
      } catch {}
    }
    throw new Error(`overlay element not found: ${cls ?? ""} ${label ?? ""} ${text ?? ""}`)
  }
}

// ------------------------------------------------------------------ the frame clock
// Scripts run as coroutines in recorded time: `wait(ms)` parks until that frame. Each frame, the
// clock wakes whoever is due, lets them act, waits for its slot in wall-clock time, and shoots.
let frame = 0
let running = 0
const waiters = []
function until(f) {
  running--
  return new Promise((resolve) => waiters.push({ f, resolve: () => { running++; resolve() } }))
}
const wait = (ms) => until(frame + Math.max(1, Math.round((ms / 1000) * FPS)))
function script(fn) {
  running++
  return fn().finally(() => running--)
}
/** Runs scripts side by side; the caller is parked until they're all done. */
async function together(...fns) {
  const all = Promise.all(fns.map(script))
  running--
  try { await all } finally { running++ }
}

/** A person at a browser: moves and clicks like a hand would. */
class Person {
  constructor(page, at) {
    this.page = page
    this.at = at
    this.pointer = "arrow"
    this.down = false
  }
  move() { return this.page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: this.at.x, y: this.at.y, ...(this.down ? { button: "left", buttons: 1 } : {}) }) }
  /** Glides along a gentle curve, a step per frame. A drift's glide (`owner`) stops when the drift does. */
  async glide(to, ms, owner) {
    const from = this.at
    const bend = { x: (from.x + to.x) / 2 + (to.y - from.y) * 0.16, y: (from.y + to.y) / 2 - (to.x - from.x) * 0.16 }
    const steps = Math.max(1, Math.round((ms / 1000) * FPS))
    for (let k = 1; k <= steps; k++) {
      if (owner && this.owner !== owner) return
      const t = k / steps
      const e = t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2
      this.at = {
        x: (1 - e) ** 2 * from.x + 2 * (1 - e) * e * bend.x + e * e * to.x,
        y: (1 - e) ** 2 * from.y + 2 * (1 - e) * e * bend.y + e * e * to.y,
      }
      await this.move()
      await until(frame + 1)
    }
  }
  /** Presses, glides to `to` holding the button, and lets go (a slider, a box, a stroke). */
  async drag(to, ms) {
    this.down = true
    await this.page.send("Input.dispatchMouseEvent", { type: "mousePressed", x: this.at.x, y: this.at.y, button: "left", buttons: 1, clickCount: 1 })
    await wait(80)
    await this.glide(to, ms)
    await wait(80)
    await this.page.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: this.at.x, y: this.at.y, button: "left", buttons: 0, clickCount: 1 })
    this.down = false
  }
  /** A pen stroke along `path(t)` (t from 0 to 1), the button held: it speeds up and slows down like a
   * hand, and moves several times a frame, as a real pointer does. */
  async stroke(path, ms) {
    await this.glide(path(0), 400)
    this.down = true
    await this.page.send("Input.dispatchMouseEvent", { type: "mousePressed", x: this.at.x, y: this.at.y, button: "left", buttons: 1, clickCount: 1 })
    const frames = Math.max(1, Math.round((ms / 1000) * FPS))
    const SUB = 4
    for (let k = 1; k <= frames * SUB; k++) {
      const t = k / (frames * SUB)
      const e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2
      this.at = path(e)
      await this.move()
      if (k % SUB === 0) await until(frame + 1)
    }
    await this.page.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: this.at.x, y: this.at.y, button: "left", buttons: 0, clickCount: 1 })
    this.down = false
  }
  async click(modifiers = 0) {
    const { x, y } = this.at
    this.down = true
    await this.page.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1, modifiers })
    await wait(70)
    await this.page.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1, modifiers })
    this.down = false
  }
}

async function api(method, path, body) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "x-opentraffic-client": "Claude Code" },
    body: body ? JSON.stringify(body) : undefined,
  })
  return response.json()
}

// A command for the capture build of OpenTraffic (Support/DemoCapture.swift), applied when it acknowledges.
const CAPTURE = process.env.OPENTRAFFIC_CAPTURE ?? "/tmp/ot-capture"
async function appCommand(command) {
  const ack = () => { try { return fs.readFileSync(`${CAPTURE}/ack.txt`, "utf8") } catch { return "0" } }
  const before = ack()
  fs.writeFileSync(`${CAPTURE}/command.json`, JSON.stringify(command))
  for (let i = 0; i < 100 && ack() === before; i++) await sleep(50)
}

async function shoot(page, seat) {
  const { data } = await page.send("Page.captureScreenshot", { format: "jpeg", quality: 88, optimizeForSpeed: true })
  fs.writeFileSync(`${OUT}/${seat}/${String(frame).padStart(4, "0")}.jpg`, Buffer.from(data, "base64"))
}

launch(9301, SCALE); launch(9302, SCALE); launch(9303, 1); launch(9304, 1)
const marks = {}
const mark = (name) => (marks[name] = frame)
const comments = async () => (await api("GET", "/comments?status=all")).comments
try {
  const [avaPage, leaPage, samPage, miaPage] = [await Page.open(9301), await Page.open(9302), await Page.open(9303), await Page.open(9304)]
  // Joining in this order gives the same colours every time after a restart: orange, blue, green, purple.
  await avaPage.visit("Ava", hostUrl)
  await leaPage.visit("Lea")
  await samPage.visit("Sam")
  await miaPage.visit("Mia", url, async (page) => {
    await page.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
    await page.send("Emulation.setUserAgentOverride", { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1" })
  })
  const ava = new Person(avaPage, { x: 1100, y: 640 })
  const lea = new Person(leaPage, { x: 1180, y: 720 })
  const sam = new Person(samPage, { x: 260, y: 760 })
  for (const p of [ava, lea, sam]) await p.move()
  await sleep(3000)
  const pages = [avaPage, leaPage, samPage, miaPage]
  const timeScale = (rate) => Promise.all(pages.map(async (page) => {
    page.rate = rate
    await page.send("Animation.enable")
    await page.send("Animation.setPlaybackRate", { playbackRate: 1 / rate })
    await page.send("Runtime.evaluate", { expression: `__otTimeScale(${rate})` })
  }))
  await timeScale(SLOW)

  // People don't hold their mouse still: drift around a spot while there's nothing to do.
  // A drift owns the person's pointer until it's stopped; stopping it ends its glide at once.
  const drifters = new Set()
  const drift = (person, around, radius) => {
    const token = Symbol()
    person.owner = token
    drifters.add(person)
    return script(async () => {
      while (person.owner === token) {
        const a = Math.random() * Math.PI * 2
        await person.glide({ x: around.x + Math.cos(a) * radius, y: around.y + Math.sin(a) * radius * 0.6 }, 1400 + Math.random() * 900, token)
        if (person.owner !== token) break
        await wait(300 + Math.random() * 500)
      }
    })
  }
  const still = (person) => { person.owner = null }
  const type = async (page, text, gap = 45) => {
    for (const ch of text) { await page.send("Input.insertText", { text: ch }); await wait(ch === " " ? 70 : gap) }
  }
  const wheel = async (person, dy, ms) => {
    const steps = Math.max(1, Math.round((ms / 1000) * FPS))
    for (let k = 0; k < steps; k++) {
      await person.page.send("Input.dispatchMouseEvent", { type: "mouseWheel", x: person.at.x, y: person.at.y, deltaX: 0, deltaY: dy / steps })
      await until(frame + 1)
    }
  }
  // Where a slider's thumb is for `value` (the range runs over its own min and max).
  const thumb = async (page, label, value) => {
    const at = await page.overlay({ label })
    const { result } = await page.send("Runtime.evaluate", { expression: "0" }) // keeps the protocol order
    void result
    const { root } = await page.send("DOM.getDocument", { depth: -1, pierce: true })
    let node = null
    const walk = (n) => { const a = n.attributes ?? []; const i = a.indexOf("aria-label"); if (!node && n.nodeName === "INPUT" && i >= 0 && a[i + 1] === label) node = n; for (const c of [...(n.children ?? []), ...(n.shadowRoots ?? [])]) walk(c) }
    walk(root)
    const { model } = await page.send("DOM.getBoxModel", { nodeId: node.nodeId })
    const attr = (name) => Number(node.attributes[node.attributes.indexOf(name) + 1])
    const q = model.border
    return { x: q[0] + 8 + ((value - attr("min")) / (attr("max") - attr("min"))) * (q[4] - q[0] - 16), y: at.y }
  }

  const done = script(async () => {
    await wait(600)

    // Lea and Sam look around.
    mark("wander")
    await together(
      async () => { await lea.glide({ x: 830, y: 330 }, 1300); await lea.glide({ x: 1010, y: 480 }, 1000) },
      async () => { await sam.glide({ x: 430, y: 540 }, 1200); await sam.glide({ x: 600, y: 300 }, 1100) },
    )

    // Sam points at the headline (⌥-click) while Lea drifts toward the comment button.
    mark("point")
    const headline = await samPage.center("h1", 0.42, 0.3)
    const commentButton = await leaPage.overlay({ label: "Add a comment" })
    await together(
      async () => { await sam.glide(headline, 800); await wait(150); mark("ping"); await sam.click(1); await wait(1500) },
      () => lea.glide({ x: commentButton.x - 160, y: commentButton.y - 140 }, 1600),
    )

    // Lea turns on comment mode and picks the trial button, the outline following what she's over.
    mark("arm")
    await lea.glide(commentButton, 700)
    await wait(150)
    await lea.click()
    lea.pointer = "crosshair"
    script(async () => { await sam.glide({ x: 760, y: 650 }, 1500); drift(sam, { x: 780, y: 640 }, 70) })
    await wait(300)
    mark("pick")
    for (const [selector, fx, fy] of [[".cards .card:nth-child(3)", 0.5, 0.45], [".cards .card:nth-child(2)", 0.5, 0.45], ["header p", 0.35, 0.5], ["h1", 0.55, 0.5]]) {
      await lea.glide(await leaPage.center(selector, fx, fy), 650)
      await wait(420)
    }
    await lea.glide(await leaPage.center("#start", 0.58, 0.5), 650)
    await wait(600)
    mark("compose")
    await lea.click()
    lea.pointer = "arrow"
    await wait(450)
    await type(leaPage, "Can we make this button bigger? It's easy to miss.")
    await wait(400)

    // She suggests the change itself: new words, and a bigger button, previewed as she goes.
    mark("edit")
    const editText = await leaPage.overlay({ text: "Edit text" })
    await lea.glide(editText, 600)
    await wait(120)
    await lea.click()
    await wait(300)
    await leaPage.send("Input.dispatchKeyEvent", { type: "keyDown", key: "a", code: "KeyA", modifiers: 4, commands: ["selectAll"] })
    await type(leaPage, "Start your free trial", 55)
    await wait(400)
    mark("style")
    const editStyle = await leaPage.overlay({ text: "Edit style" })
    await lea.glide(editStyle, 600)
    await wait(120)
    await lea.click()
    await wait(500)
    for (const [label, from, to] of [["Size", 15, 19], ["Padding ↔", 18, 26], ["Padding ↕", 11, 15]]) {
      await lea.glide(await thumb(leaPage, label, from), 650)
      await wait(150)
      await lea.drag(await thumb(leaPage, label, to), 700)
      await wait(350)
    }
    await wait(700)
    mark("post")
    const post = await leaPage.overlay({ text: "Post" })
    await lea.glide(post, 600)
    await wait(120)
    await lea.click()

    // Ava sees the pin arrive and opens it: what Lea wrote, the change she suggested, a picture.
    let pin
    for (;;) {
      try { pin = await avaPage.overlay({ cls: "pin" }); break } catch { await wait(100) }
    }
    mark("pinned")
    await wait(500)
    mark("open")
    await together(() => ava.glide({ x: pin.x + 3, y: pin.y + 3 }, 900), () => lea.glide({ x: 1080, y: 560 }, 1200))
    drift(lea, { x: 1060, y: 560 }, 60)
    await wait(200)
    await ava.click()
    mark("opened")
    // She sends it to the coding agent (what the comment's "Send to" button in OpenTraffic does).
    const first = (await comments()).find((c) => c.text.startsWith("Can we make"))
    await appCommand({ select: "Orbit", sendToAgent: first.id })
    mark("sent")
    await ava.glide({ x: pin.x + 330, y: pin.y + 160 }, 900)
    await wait(1200)
    await ava.glide({ x: pin.x + 3, y: pin.y + 3 }, 700)
    await wait(120)
    await ava.click() // the pin again closes it

    // While the agent works on it: Sam circles the headline with the pen, and Lea comments on the
    // space between two cards.
    mark("draw")
    still(sam)
    const draw = await samPage.overlay({ label: "Draw on the page" })
    await sam.glide(draw, 700)
    await wait(120)
    await sam.click()
    const h1 = await samPage.rect("h1")
    const cx = h1.x + h1.width * 0.5, cy = h1.y + h1.height * 0.5
    // A loose loop around the headline, a little more than once round, its size wandering like a hand's.
    const ring = (t) => {
      const a = t * Math.PI * 2.12 - 0.5
      const wobble = 1 + 0.035 * Math.sin(t * Math.PI * 3.2) + 0.03 * t
      return { x: cx + Math.cos(a) * h1.width * 0.56 * wobble, y: cy + Math.sin(a) * h1.height * 0.74 * wobble }
    }
    await sam.stroke(ring, 1500)
    await wait(300)
    mark("area")
    still(lea)
    const cards = JSON.parse((await leaPage.send("Runtime.evaluate", { expression: "JSON.stringify([...document.querySelectorAll('.card')].slice(0,2).map(c => c.getBoundingClientRect()))", returnByValue: true })).result.value)
    const commentAgain = await leaPage.overlay({ label: "Add a comment" })
    await lea.glide(commentAgain, 800)
    await wait(120)
    await lea.click()
    lea.pointer = "crosshair"
    await lea.glide({ x: cards[0].right - 46, y: cards[0].top + 22 }, 800)
    await wait(150)
    await lea.drag({ x: cards[1].left + 46, y: cards[0].bottom - 22 }, 900)
    lea.pointer = "arrow"
    await wait(400)
    await type(leaPage, "Too much space between the cards.")
    await wait(300)
    await leaPage.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, modifiers: 4 })
    await leaPage.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, modifiers: 4 })
    mark("areaPosted")
    await wait(300)
    for (;;) {
      const area = (await comments()).find((c) => c.text.startsWith("Too much space"))
      if (area) { await appCommand({ select: "Orbit", sendToAgent: area.id }); break }
      await wait(100)
    }
    await leaPage.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 })
    script(async () => { await sam.glide(draw, 700); await wait(120); await sam.click(); drift(sam, { x: 700, y: 600 }, 80) }) // pen off
    drift(lea, { x: 1060, y: 560 }, 60)

    // The agent fixes Lea's first comment; she's told, and takes a look: the page with the fix.
    for (;;) {
      const first = (await comments()).find((c) => c.text.startsWith("Can we make"))
      if (first?.resolved) break
      await wait(200)
    }
    mark("fixed")
    // The dev server puts the fix on everyone's page by itself (Orbit's runs with live updates).
    await wait(600)
    mark("updated")
    let look
    for (;;) {
      try { look = await leaPage.overlay({ text: "Take a look" }); break } catch { await wait(100) }
    }
    mark("told")
    await wait(900)
    still(lea)
    await lea.glide(look, 900)
    await wait(150)
    await lea.click()
    mark("look")
    await wait(3200)

    // Both fixes in, with their after pictures (taken from the host's page).
    for (;;) {
      const all = await comments()
      if (all.length >= 2 && all.every((c) => c.resolved && c.hasAfterScreenshot)) break
      await wait(200)
    }
    await wait(400)

    // Ava looks at the page on Mia's phone, and Mia turns it.
    mark("people")
    const avatars = await avaPage.overlay({ label: "Show who's here" })
    await ava.glide(avatars, 900)
    await wait(150)
    await ava.click()
    await wait(700)
    const view = await avaPage.overlay({ label: "View at Mia's size" })
    await ava.glide(view, 700)
    await wait(150)
    mark("phone")
    await ava.click()
    await ava.glide({ x: 1240, y: 520 }, 900)
    await wait(1800)
    mark("turn")
    await miaPage.send("Emulation.setDeviceMetricsOverride", { width: 844, height: 390, deviceScaleFactor: 3, mobile: true })
    await wait(2600)
    await miaPage.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true })
    await wait(2200)
    const close = await avaPage.overlay({ label: "Close" })
    await ava.glide(close, 700)
    await wait(150)
    await ava.click()
    mark("phoneClosed")
    await wait(500)

    // Ava leads with her phone open: everyone following sees it, and scrolls with her.
    mark("lead")
    const lead = await avaPage.overlay({ text: "Lead" })
    await ava.glide(lead, 900)
    await wait(150)
    await ava.click()
    await wait(900)
    const viewButton = await avaPage.overlay({ label: "View as phone or desktop" })
    await ava.glide(viewButton, 700)
    await wait(150)
    await ava.click()
    await wait(500)
    const phoneOption = await avaPage.overlay({ text: "Phone" })
    await ava.glide(phoneOption, 600)
    await wait(150)
    mark("leadPhone")
    await ava.click()
    await ava.glide({ x: 720, y: 520 }, 900)
    await wait(1500)
    mark("leadScroll")
    await wheel(ava, 900, 1500)
    await wait(1400)
    await wheel(ava, -500, 1000)
    await wait(1600)
    mark("end")
    for (const p of drifters) still(p)
  })

  // The clock.
  const pointers = { ava: [], lea: [] }
  const start = performance.now()
  let finished = false
  done.then(() => (finished = true), (e) => { console.error(e); finished = true })
  while (!finished) {
    for (const w of waiters.filter((w) => w.f <= frame)) { waiters.splice(waiters.indexOf(w), 1); w.resolve() }
    while (running > 0) await sleep(2) // everyone due acts, then parks again
    const slot = start + (frame + 1) * (1000 / FPS) * SLOW
    await sleep(Math.max(0, slot - performance.now()))
    await Promise.all([shoot(avaPage, "ava"), shoot(leaPage, "lea")])
    for (const [seat, p] of [["ava", ava], ["lea", lea]]) pointers[seat].push([Math.round(p.at.x), Math.round(p.at.y), p.pointer === "crosshair" ? 1 : 0, p.down ? 1 : 0])
    if (frame % 30 === 0) process.stdout.write(`${frame / 30}s `)
    frame++
  }
  const session = { fps: FPS, frames: frame, viewport: { width: 1440, height: 813, scale: SCALE }, marks, pointers }
  fs.writeFileSync(`${OUT}/session.json`, JSON.stringify(session))
  console.log(`\nrecorded ${frame} frames`, JSON.stringify(marks))
  await timeScale(1)
  await sleep(Number(process.env.HOLD_AFTER ?? 0) * 1000)
} finally {
  for (const c of chromes) c.kill()
}
