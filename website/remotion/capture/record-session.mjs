// Records a real collaboration session on the shared demo site from two seats: Ava (who watches and
// opens the comment) and Lea (who picks an element and comments on it), while Sam points at the
// headline. Three headless Chromes, all in the same session through the public link.
//
// It records in slow motion so the result is smooth: the pages' animations and transitions run ten
// times slower, the script moves everyone one 1/30 s step at a time, and both seats are screenshotted
// after each step. Played back at 30 fps, everything moves at its real speed. A screenshot doesn't
// show the seat's own pointer, so its position is saved per frame for the video to draw.
//   node record-session.mjs <public-url> <api-token> [out-folder]
import { spawn } from "node:child_process"
import fs from "node:fs"

const [url, token, OUT = "/tmp/ot-session"] = process.argv.slice(2)
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
  async visit(name) {
    await this.send("Page.enable")
    await this.send("Page.addScriptToEvaluateOnNewDocument", {
      source: `try { localStorage.setItem("__opentraffic_collab_name", ${JSON.stringify(name)}) } catch {}`,
    })
    await this.send("Page.addScriptToEvaluateOnNewDocument", { source: SLOW_CLOCK })
    const loaded = this.once("Page.loadEventFired")
    await this.send("Page.navigate", { url })
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
  async overlay({ cls, label }) {
    const { root } = await this.send("DOM.getDocument", { depth: -1, pierce: true })
    const matches = []
    const walk = (node) => {
      const attrs = node.attributes ?? []
      const value = (name) => { const i = attrs.indexOf(name); return i >= 0 ? attrs[i + 1] : undefined }
      const classes = (value("class") ?? "").split(/\s+/)
      if (node.nodeType === 1 && (!cls || classes.includes(cls)) && (!label || [value("aria-label"), value("title")].includes(label))) matches.push(node)
      for (const child of [...(node.children ?? []), ...(node.shadowRoots ?? [])]) walk(child)
    }
    walk(root)
    for (const node of matches) {
      try {
        const { model } = await this.send("DOM.getBoxModel", { nodeId: node.nodeId })
        const q = model.content
        return { x: (q[0] + q[4]) / 2, y: (q[1] + q[5]) / 2 }
      } catch {}
    }
    throw new Error(`overlay element not found: ${cls ?? ""} ${label ?? ""}`)
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
  move() { return this.page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: this.at.x, y: this.at.y }) }
  /** Glides along a gentle curve, a step per frame. */
  async glide(to, ms) {
    const from = this.at
    const bend = { x: (from.x + to.x) / 2 + (to.y - from.y) * 0.16, y: (from.y + to.y) / 2 - (to.x - from.x) * 0.16 }
    const steps = Math.max(1, Math.round((ms / 1000) * FPS))
    for (let k = 1; k <= steps; k++) {
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

async function shoot(page, seat) {
  const { data } = await page.send("Page.captureScreenshot", { format: "jpeg", quality: 88, optimizeForSpeed: true })
  fs.writeFileSync(`${OUT}/${seat}/${String(frame).padStart(4, "0")}.jpg`, Buffer.from(data, "base64"))
}

launch(9301, SCALE); launch(9302, SCALE); launch(9303, 1)
const marks = {}
const mark = (name) => (marks[name] = frame)
try {
  const [avaPage, leaPage, samPage] = [await Page.open(9301), await Page.open(9302), await Page.open(9303)]
  // Joining in this order gives the same colours every time after a restart: orange, blue, green.
  await avaPage.visit("Ava")
  await leaPage.visit("Lea")
  await samPage.visit("Sam")
  const ava = new Person(avaPage, { x: 1100, y: 640 })
  const lea = new Person(leaPage, { x: 1180, y: 720 })
  const sam = new Person(samPage, { x: 260, y: 760 })
  for (const p of [ava, lea, sam]) await p.move()
  await sleep(3000)
  const timeScale = (rate) => Promise.all([avaPage, leaPage, samPage].map(async (page) => {
    await page.send("Animation.enable")
    await page.send("Animation.setPlaybackRate", { playbackRate: 1 / rate })
    await page.send("Runtime.evaluate", { expression: `__otTimeScale(${rate})` })
  }))
  await timeScale(SLOW)

  // People don't hold their mouse still: drift around a spot while there's nothing to do.
  let drifting = true
  const drift = (person, around, radius) => script(async () => {
    while (drifting) {
      const a = Math.random() * Math.PI * 2
      await person.glide({ x: around.x + Math.cos(a) * radius, y: around.y + Math.sin(a) * radius * 0.6 }, 1400 + Math.random() * 900)
      await wait(300 + Math.random() * 500)
    }
  })

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
    await wait(450)
    for (const ch of "Can we make this button bigger? It's easy to miss.") {
      await leaPage.send("Input.insertText", { text: ch })
      await wait(ch === " " ? 70 : 45)
    }
    await wait(450)
    mark("post")
    await leaPage.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, modifiers: 4 })
    await leaPage.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, modifiers: 4 })

    // Ava sees the pin arrive and opens it: what Lea wrote, on which element, a picture of it,
    // and her browser.
    let pin
    for (;;) {
      try { pin = await avaPage.overlay({ cls: "pin" }); break } catch { await wait(100) }
    }
    mark("pinned")
    lea.pointer = "arrow"
    await wait(500)
    mark("open")
    await together(() => ava.glide({ x: pin.x + 3, y: pin.y + 3 }, 900), () => lea.glide({ x: 1080, y: 560 }, 1200))
    drift(lea, { x: 1060, y: 560 }, 60)
    await wait(200)
    await ava.click()
    mark("opened")
    await ava.glide({ x: pin.x + 330, y: pin.y + 140 }, 900)
    await wait(1400)

    // A coding agent replies through OpenTraffic's API (what its MCP tools call).
    mark("reply")
    const comment = (await api("GET", "/comments")).comments[0]
    await api("POST", `/comments/${comment.id}/replies`, { text: "Made it larger in a1b2c3 — reload to see it." })
    await wait(3000)
    mark("end")
    drifting = false
  })

  // The clock.
  const pointers = { ava: [], lea: [] }
  const start = performance.now()
  let finished = false
  done.then(() => (finished = true))
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
