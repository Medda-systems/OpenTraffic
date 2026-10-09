// Drives a real collaboration session on the shared demo site with three headless Chromes
// (Ava watches, Lea comments, Sam points) and records Ava's view frame by frame.
//   node collab-driver.mjs <public-url> <api-token>
import { spawn } from "node:child_process"
import fs from "node:fs"

const [url, token] = process.argv.slice(2)
const OUT = "/tmp/ot-collab-frames"
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
const API = "http://127.0.0.1:47799/v1/shares/Orbit"
const presence = process.argv[4] === "presence"
if (!presence) {
  fs.rmSync(OUT, { recursive: true, force: true })
  fs.mkdirSync(OUT, { recursive: true })
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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
    const loaded = this.once("Page.loadEventFired")
    await this.send("Page.navigate", { url })
    await loaded
  }
  move(x, y) { return this.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y }) }
  async click(x, y, modifiers = 0) {
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1, modifiers })
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1, modifiers })
  }
  async rect(selector) {
    const { result } = await this.send("Runtime.evaluate", {
      expression: `JSON.stringify(document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect())`,
      returnByValue: true,
    })
    return JSON.parse(result.value)
  }
  /** Center of an element inside the overlay's (closed) shadow root, found by tag/class and text. */
  async overlay({ cls, text, label }) {
    const { root } = await this.send("DOM.getDocument", { depth: -1, pierce: true })
    const matches = []
    const walk = (node) => {
      const attrs = node.attributes ?? []
      const classes = (attrs[attrs.indexOf("class") + 1] ?? "").split(/\s+/)
      const ownText = (node.children ?? []).filter((c) => c.nodeType === 3).map((c) => c.nodeValue).join("").trim()
      const labels = [attrs[attrs.indexOf("aria-label") + 1], attrs[attrs.indexOf("title") + 1]]
      if (node.nodeType === 1 && (!cls || classes.includes(cls)) && (!text || ownText === text) && (!label || labels.includes(label))) matches.push(node)
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
    throw new Error(`overlay element not found: ${cls ?? ""} ${text ?? ""} ${label ?? ""}`)
  }
}

let frame = 0
async function capture(viewer, times = 1) {
  for (let i = 0; i < times; i++) {
    const { data } = await viewer.send("Page.captureScreenshot", { format: "jpeg", quality: 92 })
    fs.writeFileSync(`${OUT}/${String(frame++).padStart(4, "0")}.jpg`, Buffer.from(data, "base64"))
  }
}

/** Moves cursors together along straight lines over `steps`, recording a frame each step. */
async function glide(viewer, moves, steps) {
  for (let s = 1; s <= steps; s++) {
    const t = s / steps
    const e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2
    await Promise.all(moves.map(({ page, from, to }) => page.move(from.x + (to.x - from.x) * e, from.y + (to.y - from.y) * e)))
    await sleep(45)
    await capture(viewer)
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

launch(9301, 2); launch(9302, 1); launch(9303, 1)
try {
  const ava = await Page.open(9301)
  const lea = await Page.open(9302)
  const sam = await Page.open(9303)
  await ava.visit("Ava")
  await lea.visit("Lea")
  await sam.visit("Sam")
  for (const p of [ava, lea, sam]) await p.send("DOM.enable")
  await sleep(3500)
  // "presence <seconds>": just keep everyone in the session, for capturing the app meanwhile.
  if (presence) {
    await lea.move(820, 330); await sam.move(420, 520)
    await sleep(Number(process.argv[5] ?? 40) * 1000)
    for (const c of chromes) c.kill()
    process.exit(0)
  }
  await capture(ava, 8)

  // Lea and Sam look around the page.
  const lp = { x: 1180, y: 720 }, sp = { x: 260, y: 760 }
  await glide(ava, [{ page: lea, from: lp, to: { x: 820, y: 330 } }, { page: sam, from: sp, to: { x: 420, y: 520 } }], 26)
  await glide(ava, [{ page: lea, from: { x: 820, y: 330 }, to: { x: 1000, y: 470 } }, { page: sam, from: { x: 420, y: 520 }, to: { x: 560, y: 300 } }], 18)

  // Sam points at the headline (⌥-click).
  const headline = await sam.rect("h1")
  const pointAt = { x: headline.x + headline.width * 0.42, y: headline.y + headline.height * 0.3 }
  await glide(ava, [{ page: sam, from: { x: 560, y: 300 }, to: pointAt }], 10)
  await sam.click(pointAt.x, pointAt.y, 1)
  for (let i = 0; i < 14; i++) { await sleep(60); await capture(ava) }

  // Lea comments on the trial button.
  const commentButton = await lea.overlay({ label: "Add a comment" })
  await glide(ava, [{ page: lea, from: { x: 1000, y: 470 }, to: commentButton }, { page: sam, from: pointAt, to: { x: 700, y: 640 } }], 16)
  await lea.click(commentButton.x, commentButton.y)
  const start = await lea.rect("#start")
  const target = { x: start.x + start.width * 0.55, y: start.y + start.height * 0.5 }
  await glide(ava, [{ page: lea, from: commentButton, to: target }], 18)
  await lea.click(target.x, target.y)
  await sleep(500)
  await lea.send("Input.insertText", { text: "Can we make this button bigger? It's easy to miss." })
  await lea.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, modifiers: 4 })
  await lea.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, modifiers: 4 })
  for (let i = 0; i < 16; i++) { await sleep(80); await capture(ava) }

  // Ava opens the thread.
  const pin = await ava.overlay({ cls: "pin" })
  await ava.move(pin.x, pin.y)
  await ava.click(pin.x, pin.y)
  for (let i = 0; i < 10; i++) { await sleep(80); await capture(ava) }

  // A coding agent replies through OpenTraffic's API (what its MCP tools call).
  const comment = (await api("GET", "/comments")).comments[0]
  fs.writeFileSync(`${OUT}/comment-id.txt`, comment.id)
  await api("POST", `/comments/${comment.id}/replies`, { text: "Made it larger in a1b2c3 — reload to see it." })
  for (let i = 0; i < 24; i++) { await sleep(80); await capture(ava) }
  console.log(`recorded ${frame} frames`)
  // Keeps everyone on the page a little longer, for capturing the app afterwards.
  await sleep(Number(process.env.HOLD_AFTER ?? 0) * 1000)
} finally {
  for (const c of chromes) c.kill()
}
