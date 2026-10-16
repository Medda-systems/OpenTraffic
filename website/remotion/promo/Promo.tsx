import { AbsoluteFill, Audio, Easing, Img, interpolate, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion"
import { GitHubMark } from "../parts/GitHubMark"
import { OPEN_SOURCE } from "../release"
import { SessionView } from "../parts/SessionView"
import { GIT } from "../git"
import { cliSession, Terminal, type TerminalLine, typedAt } from "../parts/Terminal"
import type { Seat, Session } from "../session"
import { mono, sans, serif } from "../theme"
import { BAR, BEAT, bg, Capture, clamp, dim, ease, fg, Mark, Pill, Sfx, Slam, Stage } from "./kit"

// A 76-second promo for social posts: 38 bars at 120 BPM, black and white around the app's own windows.
// Everything on screen is the real app or a real session in a browser (capture/), and the cuts land
// on the beat of the soundtrack (audio/music.py).

const C = (name: string) => `capture/promo/${name}`

// ---------------------------------------------------------------- shared pieces

const Arrow = ({ x, y, pressed = 0 }: { x: number; y: number; pressed?: number }) => (
  <svg width="34" height="42" viewBox="0 0 28 34" style={{ position: "absolute", left: x - 3, top: y - 3, transform: `scale(${1 - pressed * 0.12})`, transformOrigin: "3px 3px", filter: "drop-shadow(0 2px 4px rgba(0,0,0,.6))" }}>
    <path d="M2 2 L2 27 L8.5 21 L13 31 L17.5 29 L13 19.5 L22 19.5 Z" fill="#000" stroke="#fff" strokeWidth="2" strokeLinejoin="round" />
  </svg>
)

const Ring = ({ x, y, at, size = 140 }: { x: number; y: number; at: number; size?: number }) => {
  const frame = useCurrentFrame()
  const t = interpolate(frame, [at, at + 20], [0, 1], clamp)
  if (frame < at || t >= 1) return null
  return <div style={{ position: "absolute", left: x - size / 2, top: y - size / 2, width: size, height: size, borderRadius: 999, border: `5px solid ${fg}`, opacity: 1 - t, transform: `scale(${0.6 + t})` }} />
}

type Box = { x: number; y: number; width: number; height: number }

/** A region of a main-window capture (2360 × 1520), with overlays placed in the capture's pixels. */
const Crop = ({ src, crop, width, children }: { src: string; crop: Box; width: number; children?: React.ReactNode }) => {
  const k = width / crop.width
  return (
    <div style={{ position: "relative", width, height: crop.height * k, overflow: "hidden", borderRadius: 28, boxShadow: "0 40px 90px rgba(0,0,0,.6), 0 0 0 1px rgba(255,255,255,.12)" }}>
      <Img src={staticFile(src)} style={{ position: "absolute", left: -crop.x * k, top: -crop.y * k, width: 2360 * k }} />
      <div style={{ position: "absolute", left: -crop.x * k, top: -crop.y * k, width: 2360 * k, height: 1520 * k }}>
        <div style={{ transform: `scale(${k})`, transformOrigin: "0 0" }}>{children}</div>
      </div>
    </div>
  )
}

const Title = ({ top = 60, children }: { top?: number; children: React.ReactNode }) => (
  <div style={{ position: "absolute", top, left: 0, right: 0, display: "flex", flexDirection: "column", alignItems: "center", textAlign: "center" }}>{children}</div>
)

// The menu bar and the popover under OpenTraffic's icon, in the same place in every scene that uses it.
// The clock sits in from the edge so the share scene's push-in doesn't crop it.
const glyphX = 1400
const popoverAt = { left: glyphX - 360, top: 58 }

const MenuBar = () => (
  <div style={{ position: "absolute", left: 0, right: 0, top: 0, height: 50, background: "rgba(38,38,40,.8)", borderBottom: "1px solid rgba(255,255,255,.08)", display: "flex", alignItems: "center", justifyContent: "flex-end", padding: "0 130px", fontFamily: sans, fontSize: 21, color: fg, fontWeight: 500 }}>
    <div style={{ position: "absolute", left: glyphX - 27, top: 7, width: 54, height: 36, borderRadius: 8, background: "rgba(255,255,255,.16)" }} />
    <Img src={staticFile("brand/menu-glyph.svg")} style={{ position: "absolute", left: glyphX - 18, top: 14, width: 36, height: 22, filter: "invert(1)" }} />
    Wed 9:41
  </div>
)

const Popover = ({ src, left = popoverAt.left, top = popoverAt.top }: { src: string; left?: number; top?: number }) => (
  <div style={{ position: "absolute", left, top }}>
    <Capture src={C(src)} width={720} />
  </div>
)

// ---------------------------------------------------------------- 1. hook (bars 1-2)

const Hook = () => {
  const frame = useCurrentFrame()
  const text = "localhost:5175"
  const typed = text.slice(0, Math.min(text.length, Math.floor(frame / 1.6)))
  const away = interpolate(frame, [54, 62], [0, 1], { ...clamp, easing: Easing.in(Easing.cubic) })
  const rush = interpolate(frame, [92, 120], [1, 1.9], { ...clamp, easing: Easing.in(Easing.cubic) })
  const flash = interpolate(frame, [112, 119], [0, 1], clamp)
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", textAlign: "center" }}>
      <div style={{ position: "absolute", opacity: 1 - away, transform: `translateY(${-away * 80}px)` }}>
        <div style={{ fontFamily: mono, fontSize: 130, fontWeight: 600, color: fg, letterSpacing: "-0.03em" }}>
          {typed}
          <span style={{ display: "inline-block", width: 8, height: 120, marginLeft: 10, verticalAlign: "-14px", background: fg, opacity: Math.floor(frame / 8) % 2 ? 0.2 : 1 }} />
        </div>
        <Slam at={26} size={72} color={dim} style={{ marginTop: 24, fontWeight: 500, letterSpacing: "-0.02em" }}>works on your machine.</Slam>
      </div>
      <div style={{ position: "absolute", transform: `scale(${rush})`, filter: `blur(${(rush - 1) * 10}px)` }}>
        <Slam at={60} size={150}>Now share it</Slam>
        <Slam at={75} size={150}><Mark>with everyone.</Mark></Slam>
      </div>
      <AbsoluteFill style={{ background: "#fff", opacity: flash }} />
    </AbsoluteFill>
  )
}

const hookSfx = () => [
  ...Array.from({ length: 14 }, (_, i) => <Sfx key={`t${i}`} at={i * 1.6} name={`type${(i % 3) + 1}`} volume={0.35} />),
  <Sfx key="w1" at={56} name="whoosh" volume={0.35} />,
]

// ---------------------------------------------------------------- 2. it finds your servers (bars 3-4)

const Detect = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const flash = interpolate(frame, [0, 10], [1, 0], clamp)
  const open = spring({ frame, fps, config: { damping: 15, stiffness: 200 } })
  const src = frame < 22 ? "detect-empty.png" : frame < 48 ? "detect-one.png" : frame < 84 ? "detect-three.png" : "popover-before-dark.png"
  return (
    <AbsoluteFill>
      <MenuBar />
      <div style={{ opacity: open, transform: `translateY(${(1 - open) * -14}px)` }}>
        <Popover src={src} />
      </div>
      <div style={{ position: "absolute", left: 130, top: 300 }}>
        <Slam at={4} out={80} size={130}>Finds every</Slam>
        <Slam at={10} out={80} size={130}><Mark>dev server.</Mark></Slam>
      </div>
      <div style={{ position: "absolute", left: 130, top: 300 }}>
        <Slam at={84} size={130}>Name, port,</Slam>
        <Slam at={90} size={130}><Mark>uptime.</Mark></Slam>
      </div>
      <AbsoluteFill style={{ background: "#fff", opacity: flash }} />
    </AbsoluteFill>
  )
}

const detectSfx = () => [<Sfx key="a" at={22} name="pop" volume={0.55} />, <Sfx key="b" at={48} name="pop" volume={0.55} />, <Sfx key="c" at={52} name="pop" volume={0.45} />, <Sfx key="d" at={84} name="whoosh" volume={0.3} />]

// ---------------------------------------------------------------- 3. one click (bars 5-6)

const Share = () => {
  const frame = useCurrentFrame()
  const button = { x: popoverAt.left + 617, y: popoverAt.top + 352 }
  const p = interpolate(frame, [2, 26], [0, 1], { ...clamp, easing: ease })
  const leave = interpolate(frame, [40, 64], [0, 1], { ...clamp, easing: ease })
  const cursor = {
    x: 760 + (button.x - 10 - 760) * p + (1240 - button.x) * leave,
    y: 760 + (button.y - 6 - 760) * p + (820 - button.y) * leave,
  }
  const pressed = interpolate(frame, [27, 30, 34], [0, 1, 0], clamp)
  const src = frame < 31 ? "popover-before-dark.png" : frame < 40 ? "p-starting.png" : frame < 55 ? "p-checking.png" : "p-online.png"
  const push = interpolate(frame, [0, 120], [1, 1.1], clamp)
  return (
    <AbsoluteFill style={{ transform: `scale(${push})`, transformOrigin: "62% 0%" }}>
      <MenuBar />
      <Popover src={src} />
      <Arrow x={cursor.x} y={cursor.y} pressed={pressed} />
      <div style={{ position: "absolute", left: 130, top: 300 }}>
        <Slam at={30} size={150}>One click.</Slam>
        <Slam at={55} size={150}><Mark>Live link.</Mark></Slam>
        <div style={{ height: 40 }} />
        <Slam at={72} size={34}>
          <Pill>
            <span style={{ fontFamily: mono }}>orbit.wbfsgcylfq2x.opentunnel.xyz</span>
            <span style={{ fontSize: 24, fontWeight: 600, color: bg, background: fg, padding: "6px 14px", borderRadius: 99 }}>Copied</span>
          </Pill>
        </Slam>
      </div>
    </AbsoluteFill>
  )
}

const shareSfx = () => [<Sfx key="c" at={30} name="click" volume={0.9} />, <Sfx key="ch" at={55} name="chime" volume={0.55} />, <Sfx key="p" at={72} name="pop" volume={0.5} />]

// ---------------------------------------------------------------- 4. connection path, then who's here (bars 7-8)

const pathCrop = { x: 560, y: 96, width: 1780, height: 520 }
const nodes = [714, 1198, 1682, 2168].map((x) => ({ x, y: 463 }))
const peopleCrop = { x: 560, y: 880, width: 1780, height: 440 }

const Path = () => {
  const frame = useCurrentFrame()
  const src = frame < 10 ? "m-unchecked.png" : frame < 45 ? "m-reachable.png" : "m-online.png"
  const people = interpolate(frame, [64, 76], [0, 1], { ...clamp, easing: ease })
  return (
    <AbsoluteFill>
      <Title top={90}>
        <div style={{ opacity: 1 - people }}><Slam at={2} size={120}>Every hop, <Mark>checked.</Mark></Slam></div>
      </Title>
      <Title top={90}>
        <Slam at={66} size={120}>See <Mark>who's here.</Mark></Slam>
      </Title>
      <div style={{ position: "absolute", left: 110, top: 330, opacity: 1 - people, transform: `translateY(${-people * 120}px)` }}>
        <Crop src={C(src)} crop={pathCrop} width={1700}>
          <Ring {...nodes[0]} at={10} />
          <Ring {...nodes[1]} at={12} />
          <Ring {...nodes[3]} at={14} />
          <Ring {...nodes[2]} at={45} />
        </Crop>
      </div>
      <div style={{ position: "absolute", left: 110, top: 330, opacity: people, transform: `translateY(${(1 - people) * 120}px)` }}>
        <Crop src={C("main-overview-dark.png")} crop={peopleCrop} width={1700}>
          {[0, 1, 2, 3].map((i) => <Ring key={i} x={622} y={1103 + i * 60} at={72 + i * 6} size={110} />)}
        </Crop>
      </div>
    </AbsoluteFill>
  )
}

const pathSfx = () => [
  <Sfx key="d1" at={10} name="ding1" volume={0.5} />,
  <Sfx key="d2" at={12} name="ding2" volume={0.45} />,
  <Sfx key="d3" at={14} name="ding3" volume={0.4} />,
  <Sfx key="d4" at={45} name="ding4" volume={0.5} />,
  <Sfx key="s" at={46} name="success" volume={0.4} />,
  ...[0, 1, 2, 3].map((i) => <Sfx key={`j${i}`} at={72 + i * 6} name="join" volume={0.45} />),
]

// ---------------------------------------------------------------- 5-11. the session in the browser (bars 9-25)
// Every shot plays the recording at exactly 1× or 2×, so no frame is held or skipped unevenly.

/** A stretch of one seat's recording; the camera eases to `shot` over `ease` frames (10 by default). */
type Segment = { from: number; to: number; seat: Seat; rec: [number, number]; shot?: { x: number; y: number; zoom: number }; ease?: number }

const segmentAt = (segments: Segment[], frame: number) => {
  const s = segments.find((g) => frame >= g.from && frame < g.to) ?? segments[segments.length - 1]
  const t = (frame - s.from) / (s.to - s.from)
  return { s, rec: s.rec[0] + (s.rec[1] - s.rec[0]) * Math.min(1, Math.max(0, t)) }
}

const seatName: Record<Seat, string> = { ava: "Ava", lea: "Lea" }
const seatColor: Record<Seat, string> = { ava: "#F38020", lea: "#2F80ED" }

const Browser = ({ session, segments, width = 1520 }: { session: Session; segments: Segment[]; width?: number }) => {
  const frame = useCurrentFrame()
  const { s, rec } = segmentAt(segments, frame)
  const pageHeight = (session.viewport.height / session.viewport.width) * width
  const prev = segments[Math.max(0, segments.indexOf(s) - 1)]
  const blend = interpolate(frame - s.from, [0, s.ease ?? 10], [0, 1], { ...clamp, easing: Easing.inOut(Easing.cubic) })
  const target = s.shot ?? { x: width / 2, y: pageHeight / 2, zoom: 1 }
  const from = prev.shot ?? { x: width / 2, y: pageHeight / 2, zoom: 1 }
  const shot = { x: from.x + (target.x - from.x) * blend, y: from.y + (target.y - from.y) * blend, zoom: from.zoom + (target.zoom - from.zoom) * blend }
  return (
    <div style={{ width, borderRadius: 22, overflow: "hidden", background: "#fff", boxShadow: "0 50px 100px rgba(0,0,0,.6), 0 0 0 1px rgba(255,255,255,.12)" }}>
      <div style={{ height: 58, display: "flex", alignItems: "center", padding: "0 22px", background: "#f2f2f4", borderBottom: "1px solid rgba(0,0,0,.08)", fontFamily: sans }}>
        <div style={{ display: "flex", gap: 10, width: 240 }}>
          {["#ff5f57", "#febc2e", "#28c840"].map((c) => <span key={c} style={{ width: 15, height: 15, borderRadius: 99, background: c }} />)}
        </div>
        <div style={{ margin: "0 auto", background: "#fff", borderRadius: 10, padding: "7px 22px", fontSize: 19, color: "#111", border: "1px solid rgba(0,0,0,.08)" }}>orbit.wbfsgcylfq2x.opentunnel.xyz</div>
        <div style={{ width: 240, display: "flex", justifyContent: "flex-end", alignItems: "center", gap: 9, fontSize: 19, fontWeight: 600, color: "#111" }}>
          <span style={{ width: 26, height: 26, borderRadius: 99, background: seatColor[s.seat], color: "#fff", display: "grid", placeItems: "center", fontSize: 14 }}>{seatName[s.seat][0]}</span>
          {seatName[s.seat]}'s screen
        </div>
      </div>
      <div style={{ position: "relative", width, height: pageHeight, overflow: "hidden" }}>
        <div style={{ position: "absolute", left: 0, top: 0, transformOrigin: "0 0", transform: `translate(${width / 2}px, ${pageHeight / 2}px) scale(${shot.zoom}) translate(${-shot.x}px, ${-shot.y}px)` }}>
          <SessionView session={session} seat={s.seat} frame={rec} width={width} />
        </div>
      </div>
    </div>
  )
}

const sceneFrameOf = (segments: Segment[], seat: Seat, recorded: number) => {
  for (const s of segments) {
    if (s.seat !== seat) continue
    const [a, b] = s.rec
    if (recorded >= Math.min(a, b) && recorded <= Math.max(a, b)) return s.from + ((recorded - a) / (b - a)) * (s.to - s.from)
  }
  return -1
}

/** Sound effects at recorded moments, for those that are in the scene. */
const sfxAt = (segments: Segment[], effects: [Seat, number, string, number][]) =>
  effects.map(([seat, rec, name, volume], i) => {
    const at = sceneFrameOf(segments, seat, rec)
    return at < 0 ? null : <Sfx key={`${name}${i}`} at={at} name={name} volume={volume} />
  })

// Lea and Sam look around, Sam points, Lea picks the trial button and starts her comment (bars 9-12).
const collabSegments = (m: Record<string, number>, k: number): Segment[] => [
  { from: 0, to: 50, seat: "ava", rec: [m.wander, m.wander + 50], shot: { x: 700 * k, y: 420 * k, zoom: 1.3 } },
  { from: 50, to: 95, seat: "ava", rec: [m.ping - 18, m.ping + 27], shot: { x: 560 * k, y: 300 * k, zoom: 1.35 } },
  { from: 95, to: 195, seat: "lea", rec: [m.compose + 2 - 200, m.compose + 2] },
  { from: 195, to: 240, seat: "lea", rec: [m.compose + 2, m.compose + 47], shot: { x: 460 * k, y: 420 * k, zoom: 1.6 } },
]

const Collab = ({ session }: { session: Session }) => {
  const k = 1520 / session.viewport.width
  return (
    <AbsoluteFill>
      <Title top={44}><Slam at={0} out={47} size={96}>Live cursors.</Slam></Title>
      <Title top={44}><Slam at={50} out={92} size={96}>Point at anything.</Slam></Title>
      <Title top={44}><Slam at={95} out={192} size={96}>Pick any element.</Slam></Title>
      <Title top={44}><Slam at={195} size={96}><Mark>Comment on it.</Mark></Slam></Title>
      <div style={{ position: "absolute", left: 200, top: 176 }}>
        <Browser session={session} segments={collabSegments(session.marks, k)} />
      </div>
    </AbsoluteFill>
  )
}

const collabSfx = (session: Session) => {
  const m = session.marks
  const segments = collabSegments(m, 1)
  const typing = Array.from({ length: 14 }, (_, i) => 197 + i * 3)
  return [
    ...[0, 5, 10].map((d, i) => <Sfx key={`j${i}`} at={4 + d} name="pop" volume={0.35} />),
    ...sfxAt(segments, [["ava", m.ping, "ping", 0.55], ["lea", m.arm + 26, "click", 0.8], ["lea", m.compose, "click", 0.8]]),
    ...typing.map((f, i) => <Sfx key={`t${i}`} at={f} name={`type${(i % 3) + 1}`} volume={0.3} />),
  ]
}

// She suggests the fix: new words, then a bigger button as she drags (bars 13-15).
const suggestSegments = (m: Record<string, number>, k: number): Segment[] => [
  { from: 0, to: 60, seat: "lea", rec: [m.edit + 10, m.edit + 70], shot: { x: 330 * k, y: 330 * k, zoom: 1.7 } },
  { from: 60, to: 180, seat: "lea", rec: [m.style, m.style + 240], shot: { x: 340 * k, y: 370 * k, zoom: 1.6 } },
]

const Suggest = ({ session }: { session: Session }) => {
  const k = 1520 / session.viewport.width
  return (
    <AbsoluteFill>
      <Title top={44}><Slam at={0} out={57} size={96}>Suggest <Mark>the fix.</Mark></Slam></Title>
      <Title top={44}><Slam at={60} size={96}>It changes <Mark>live.</Mark></Slam></Title>
      <div style={{ position: "absolute", left: 200, top: 176 }}>
        <Browser session={session} segments={suggestSegments(session.marks, k)} />
      </div>
    </AbsoluteFill>
  )
}

const suggestSfx = (session: Session) => {
  const m = session.marks
  const segments = suggestSegments(m, 1)
  return [
    ...sfxAt(segments, [["lea", m.edit + 25, "click", 0.7], ["lea", m.style + 22, "click", 0.7]]),
    ...Array.from({ length: 11 }, (_, i) => <Sfx key={`t${i}`} at={18 + i * 3} name={`type${(i % 3) + 1}`} volume={0.28} />),
  ]
}

// Sam circles the headline with the pen (as Ava sees it); Lea comments on the space between two cards (bars 16-17).
const drawSegments = (m: Record<string, number>, k: number): Segment[] => [
  { from: 0, to: 60, seat: "ava", rec: [m.draw + 24, m.draw + 84], shot: { x: 560 * k, y: 230 * k, zoom: 1.35 } },
  { from: 60, to: 120, seat: "lea", rec: [m.area + 48, m.area + 108], shot: { x: 560 * k, y: 470 * k, zoom: 1.35 } },
]

const Draw = ({ session }: { session: Session }) => {
  const k = 1520 / session.viewport.width
  return (
    <AbsoluteFill>
      <Title top={44}><Slam at={0} out={57} size={96}><Mark>Draw</Mark> on it.</Slam></Title>
      <Title top={44}><Slam at={60} size={96}>Or comment on <Mark>an area.</Mark></Slam></Title>
      <div style={{ position: "absolute", left: 200, top: 176 }}>
        <Browser session={session} segments={drawSegments(session.marks, k)} />
      </div>
    </AbsoluteFill>
  )
}

const drawSfx = () => [<Sfx key="w" at={6} name="whoosh" volume={0.3} />, <Sfx key="c" at={62} name="click" volume={0.6} />]

// ---------------------------------------------------------------- 8. the agent fixes it (bars 18-21)
// Three moves: a push in on the comment as the agent picks it up, the fix landing on the page (with a
// hit), and the Before and After in OpenTraffic.

/** The recorded frame where opencode's change shows up on the page (the dev server swaps it in by itself,
 * while the comment is still open and the agent is still writing its reply). */
const FIX = 911

// The recording plays at exactly 1×, or ½× (each frame twice) while the agent works; the camera does the
// moving. The shots are timed from the moment the fix shows up (FIX).
const agentSegments = (m: Record<string, number>, k: number): Segment[] => {
  const open = 24 // Ava opening it
  const push = 2 * (FIX - 2 - (m.opened + 22)) // the agent at work, up to just before the fix, at ½×
  const out = 26 // the fix lands, and the camera eases back
  return [
    // Ava opens it: what Lea asked for, and "opencode is working on this"…
    { from: 0, to: open, seat: "ava", rec: [m.opened - 2, m.opened + 22], shot: { x: 330 * k, y: 470 * k, zoom: 1.35 } },
    // …the camera pushes slowly in on the agent at work…
    { from: open, to: open + push, seat: "ava", rec: [m.opened + 22, FIX - 2], shot: { x: 320 * k, y: 500 * k, zoom: 1.95 }, ease: push },
    // …the fix lands, and it eases back out to the bigger button next to the agent's reply.
    { from: open + push, to: open + push + out, seat: "ava", rec: [FIX - 2, FIX - 2 + out], shot: { x: 300 * k, y: 470 * k, zoom: 1.4 }, ease: 22 },
    // Lea, who asked: her page picks up where Ava's was, and opens out to the notice that it's fixed.
    { from: open + push + out, to: 150, seat: "lea", rec: [m.told - 4, m.told - 4 + 150 - (open + push + out)], shot: { x: 720 * k, y: 406 * k, zoom: 1.02 }, ease: 36 },
  ]
}

/** The scene frame the fix appears. */
const agentLands = (m: Record<string, number>) => 24 + 2 * (FIX - 2 - (m.opened + 22)) + 2
const tools = ["get_feedback", "claim_comment", "reply_to_comment", "resolve_comment"]

const Agent = ({ session }: { session: Session }) => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const k = 1520 / session.viewport.width
  const AGENT_LANDS = agentLands(session.marks)
  const third = interpolate(frame, [148, 156], [0, 1], { ...clamp, easing: ease })
  const result = spring({ frame: frame - 152, fps, config: { damping: 13, stiffness: 190 } })
  return (
    <AbsoluteFill>
      <div style={{ opacity: 1 - third }}>
        <Title top={44}><Slam at={0} out={AGENT_LANDS - 5} size={96}>Your agent <Mark>picks it up.</Mark></Slam></Title>
        <Title top={44}><Slam at={AGENT_LANDS} size={110}><Mark>Fixed.</Mark></Slam></Title>
      </div>
      <div style={{ position: "absolute", left: 200, top: 176, opacity: 1 - third, transform: `scale(${1 - third * 0.06})`, transformOrigin: "50% 45%" }}>
        <Browser session={session} segments={agentSegments(session.marks, k)} />
      </div>
      {frame >= 148 ? (
        <>
          <Title top={60}><Slam at={152} size={110}>Before, after. <Mark>Over MCP.</Mark></Slam></Title>
          <div style={{ position: "absolute", left: 310, top: 270, opacity: third, transform: `scale(${0.9 + 0.1 * result})`, transformOrigin: "50% 40%" }}>
            <Crop src={C("main-feedback-dark.png")} crop={{ x: 600, y: 540, width: 1150, height: 690 }} width={1300} />
          </div>
          {/* A dark band under the tool names, so they read over the window. */}
          <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 210, opacity: third, background: "linear-gradient(to bottom, rgba(0,0,0,0), rgba(0,0,0,.92) 38%, #000)" }} />
          <div style={{ position: "absolute", bottom: 50, left: 0, right: 0, display: "flex", justifyContent: "center", gap: 22 }}>
            {tools.map((t, i) => (
              <Slam key={t} at={168 + i * 8} size={34}>
                <Pill style={{ fontFamily: mono, fontSize: 32, background: "#0c0c0e", ...(i === 3 ? { background: fg, color: bg, borderColor: fg } : {}) }}>{t}</Pill>
              </Slam>
            ))}
          </div>
        </>
      ) : null}
    </AbsoluteFill>
  )
}

const agentSfx = (session: Session) => [
  ...sfxAt(agentSegments(session.marks, 1), [["ava", session.marks.opened, "click", 0.7]]),
  <Sfx key="hit" at={agentLands(session.marks)} name="success" volume={0.75} />,
  <Sfx key="r" at={agentLands(session.marks) + 14} name="pop" volume={0.5} />,
  <Sfx key="t" at={82} name="chime" volume={0.5} />,
  <Sfx key="w2" at={148} name="whoosh" volume={0.35} />,
  ...tools.map((t, i) => <Sfx key={t} at={168 + i * 8} name="pop" volume={0.4} />),
]

// ---------------------------------------------------------------- 9. a commit per fix (bars 22-24)

/** The demo project's history after the recorded session (remotion/git.ts). */
const gitSession: TerminalLine[] = [
  { at: 14, command: "git branch --show-current", output: GIT.branch },
  { at: 44, command: "git log --oneline -2", output: GIT.commits },
]

// The branch graph: main along the bottom, the share's branch above it, a commit per fix, merged back.
const G = { left: 150, right: 1770, main: 905, branch: 735, out: 330, back: 1560 }
const commitsAt = [{ x: 760, at: 78 }, { x: 1180, at: 108 }]

/** A line that draws itself from `at` over `len` frames. */
const Drawn = ({ d, at, len, stroke, width = 6, dash }: { d: string; at: number; len: number; stroke: string; width?: number; dash?: string }) => {
  const frame = useCurrentFrame()
  const t = interpolate(frame, [at, at + len], [0, 1], { ...clamp, easing: ease })
  return <path d={d} pathLength={1} fill="none" stroke={stroke} strokeWidth={width} strokeLinecap="round" strokeDasharray={dash ?? "1 1"} strokeDashoffset={dash ? 0 : 1 - t} opacity={dash ? t : 1} />
}

const Dot = ({ x, y, at, size = 30, filled = true }: { x: number; y: number; at: number; size?: number; filled?: boolean }) => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const s = spring({ frame: frame - at, fps, config: { damping: 10, stiffness: 300 } })
  if (frame < at) return null
  return <circle cx={x} cy={y} r={(size / 2) * s} fill={filled ? fg : bg} stroke={fg} strokeWidth={6} />
}

const Label = ({ x, y, at, children, mono: isMono = false, color = fg, size = 26, anchor = "start" }: { x: number; y: number; at: number; children: React.ReactNode; mono?: boolean; color?: string; size?: number; anchor?: "start" | "middle" | "end" }) => {
  const frame = useCurrentFrame()
  const t = interpolate(frame, [at, at + 10], [0, 1], { ...clamp, easing: ease })
  return (
    <text x={x} y={y + (1 - t) * 12} opacity={t} fill={color} fontSize={size} fontFamily={isMono ? mono : sans} fontWeight={isMono ? 500 : 600} textAnchor={anchor} letterSpacing={isMono ? 0 : -0.3}>
      {children}
    </text>
  )
}

const BranchGraph = () => {
  const curve = (x1: number, y1: number, x2: number, y2: number) => `M ${x1} ${y1} C ${x1 + 110} ${y1}, ${x2 - 110} ${y2}, ${x2} ${y2}`
  const short = (line: string) => line.replace(/^\w+ /, "")
  const clip = (text: string, n: number) => (text.length > n ? text.slice(0, n - 1).trimEnd() + "…" : text)
  return (
    <svg width={1920} height={1080} style={{ position: "absolute", inset: 0 }}>
      <Drawn d={`M ${G.left} ${G.main} L ${G.right} ${G.main}`} at={0} len={40} stroke={dim} />
      <Label x={G.left} y={G.main + 52} at={6} color={dim} size={24} mono>main</Label>
      <Dot x={G.left + 40} y={G.main} at={4} size={22} />
      <Drawn d={curve(G.out, G.main, G.out + 220, G.branch) + ` L ${G.back - 220} ${G.branch}`} at={22} len={36} stroke={fg} />
      <Dot x={G.out} y={G.main} at={20} size={22} />
      <Label x={G.out + 230} y={G.branch - 34} at={34} color={dim} size={22} mono>{GIT.branch}</Label>
      <Label x={G.out - 10} y={G.main + 52} at={26} color={dim} size={24}>The share starts</Label>
      {commitsAt.map((c, i) => {
        const line = GIT.commits[GIT.commits.length - 1 - i] ?? ""
        return (
          <g key={i}>
            <Dot x={c.x} y={G.branch} at={c.at} size={34} />
            <Label x={c.x} y={G.branch + 58} at={c.at + 3} size={22} anchor="middle" color={dim} mono>{line.split(" ")[0]}</Label>
            <Label x={c.x} y={G.branch + 92} at={c.at + 5} size={24} anchor="middle">{clip(short(line), 30)}</Label>
          </g>
        )
      })}
      <Drawn d={curve(G.back - 220, G.branch, G.back, G.main)} at={132} len={22} stroke={fg} />
      <Dot x={G.back} y={G.main} at={152} size={34} filled={false} />
      <Label x={G.back} y={G.main + 52} at={154} color={dim} size={24} anchor="middle">Merged when you stop</Label>
    </svg>
  )
}

const Git = () => (
  <AbsoluteFill>
    <div style={{ position: "absolute", left: 130, top: 120, width: 820 }}>
      <Slam at={0} size={104}>Every fix,</Slam>
      <Slam at={6} size={104}><Mark>its own commit.</Mark></Slam>
    </div>
    <div style={{ position: "absolute", left: 930, top: 150 }}>
      <Terminal width={870} fontSize={20} lines={gitSession} />
    </div>
    <BranchGraph />
  </AbsoluteFill>
)

const gitSfx = () => {
  const out: React.ReactNode[] = []
  for (const line of gitSession) {
    for (let i = 0; i < Math.ceil(line.command.length / 2); i += 2) out.push(<Sfx key={`${line.at}-${i}`} at={line.at + i} name={`type${(i % 3) + 1}`} volume={0.22} />)
    out.push(<Sfx key={`${line.at}-enter`} at={typedAt(line) - 1} name="click" volume={0.45} />)
  }
  out.push(<Sfx key="br" at={22} name="whoosh" volume={0.3} />)
  commitsAt.forEach((c, i) => out.push(<Sfx key={`c${i}`} at={c.at} name="pop" volume={0.6} />))
  out.push(<Sfx key="m" at={152} name="success" volume={0.5} />)
  return out
}

// ---------------------------------------------------------------- 10. their phone (bars 25-26)

const phoneSegments = (m: Record<string, number>, k: number): Segment[] => [
  { from: 0, to: 30, seat: "ava", rec: [m.phone - 24, m.phone + 6], shot: { x: 1120 * k, y: 600 * k, zoom: 1.35 } },
  { from: 30, to: 60, seat: "ava", rec: [m.phone + 6, m.phone + 36], shot: { x: 720 * k, y: 410 * k, zoom: 1.12 } },
  { from: 60, to: 120, seat: "ava", rec: [m.turn - 2, m.turn + 58], shot: { x: 720 * k, y: 410 * k, zoom: 1.12 } },
]

const Phone = ({ session }: { session: Session }) => {
  const k = 1520 / session.viewport.width
  return (
    <AbsoluteFill>
      <Title top={44}><Slam at={0} size={96}>See it on <Mark>their phone.</Mark></Slam></Title>
      <div style={{ position: "absolute", left: 200, top: 176 }}>
        <Browser session={session} segments={phoneSegments(session.marks, k)} />
      </div>
    </AbsoluteFill>
  )
}

const phoneSfx = (session: Session) => [...sfxAt(phoneSegments(session.marks, 1), [["ava", session.marks.phone, "click", 0.7]]), <Sfx key="w" at={62} name="whoosh" volume={0.35} />]

// ---------------------------------------------------------------- 11. lead the demo, everyone in sync (bars 27-28)

const leadSegments = (m: Record<string, number>, seat: Seat): Segment[] => {
  // Close on the phone (the page is 1440 × 813 at 880 wide).
  const shot = { x: 440, y: 240, zoom: 1.22 }
  return [
    { from: 0, to: 60, seat, rec: [m.leadPhone - 10, m.leadPhone + 50], shot },
    { from: 60, to: 120, seat, rec: [m.leadScroll - 2, m.leadScroll + 58], shot },
  ]
}

const Lead = ({ session }: { session: Session }) => (
  <AbsoluteFill>
    <Title top={60}><Slam at={0} size={96}>Lead the demo. <Mark>Everyone's in sync.</Mark></Slam></Title>
    <div style={{ position: "absolute", left: 60, top: 270, display: "flex", gap: 40 }}>
      <Browser session={session} segments={leadSegments(session.marks, "ava")} width={880} />
      <Browser session={session} segments={leadSegments(session.marks, "lea")} width={880} />
    </div>
  </AbsoluteFill>
)

const leadSfx = (session: Session) => sfxAt(leadSegments(session.marks, "ava"), [["ava", session.marks.leadPhone, "click", 0.7], ["ava", session.marks.leadPhone + 20, "join", 0.5]])

// ---------------------------------------------------------------- 12. providers (bars 28-29)

const providers = [
  { kind: "quick", name: "Cloudflare", logo: "brand/provider-cloudflare.svg", line: "A temporary URL. No account." },
  // OpenTunnel is made by Anomaly; the app shows Anomaly's mark for it.
  { kind: "opentunnel", name: "OpenTunnel", logo: "brand/provider-opentunnel.svg", line: "A lasting address, encrypted end to end." },
  { kind: "tailscale", name: "Tailscale", logo: "brand/provider-tailscale.svg", line: "Private to your devices." },
  { kind: "ngrok", name: "ngrok", logo: "brand/provider-ngrok.svg", line: "With a request inspector." },
  { kind: "customDomain", name: "Your domain", logo: "brand/provider-cloudflare.svg", line: "A hostname you own." },
]

const Providers = () => {
  const frame = useCurrentFrame()
  const i = Math.min(providers.length - 1, Math.floor(frame / BEAT))
  const p = providers[i]
  const bump = Math.exp(-(frame - i * BEAT) / 3) * (frame < providers.length * BEAT ? 1 : 0)
  const outro = interpolate(frame, [72, 84], [0, 1], { ...clamp, easing: ease })
  const logoHeight = p.kind === "ngrok" ? 96 : p.kind === "opentunnel" ? 70 : 60
  return (
    <AbsoluteFill>
      <div style={{ position: "absolute", left: 640, top: 92, transform: `scale(${1 + bump * 0.015 - outro * 0.06})`, opacity: 1 - outro * 0.6, transformOrigin: "60% 50%" }}>
        <Capture src={C(`new-${p.kind}-dark.png`)} width={1180} />
      </div>
      <div style={{ position: "absolute", left: 110, top: 320, width: 500, opacity: 1 - outro }}>
        <div style={{ transform: `translateX(${-bump * 30}px)` }}>
          <div style={{ height: 100, display: "flex", alignItems: "center" }}>
            <Img src={staticFile(p.logo)} style={{ height: logoHeight, filter: "grayscale(1) brightness(0) invert(1)" }} />
          </div>
          {/* ngrok's mark already spells its name. */}
          {p.name === "ngrok" ? null : <div style={{ marginTop: 10, fontFamily: sans, fontWeight: 700, fontSize: 64, letterSpacing: "-0.03em", color: fg }}>{p.name}</div>}
        </div>
        <div style={{ marginTop: 22, fontFamily: sans, fontSize: 40, lineHeight: 1.2, color: dim }}>{p.line}</div>
      </div>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", textAlign: "center" }}>
        <Slam at={75} size={140}>One menu.</Slam>
        <Slam at={90} size={140}><Mark>Every way to share.</Mark></Slam>
      </AbsoluteFill>
    </AbsoluteFill>
  )
}

const providerSfx = () => providers.map((p, i) => <Sfx key={p.kind} at={i * BEAT} name="whoosh" volume={0.3} />)

// ---------------------------------------------------------------- 11. a password (bar 26, the second break)

// Turn on a password, then what a visitor sees: OpenTraffic's own sign-in page before the site (captured
// from a protected share, capture/promo/signin/).
const SIGNIN_IN = 30 // the browser slides in
const TYPE_AT = 44 // the password is typed, a character every two frames
const PRESS_AT = 86 // Continue
const signinFrame = (frame: number) => {
  if (frame < TYPE_AT) return "00-empty"
  const typed = Math.floor((frame - TYPE_AT) / 2) + 1
  if (typed <= 10) return `20-pw-${String(typed).padStart(2, "0")}`
  if (typed <= 13) return `25-name-${typed}`
  if (frame < PRESS_AT) return "30-filled"
  if (frame < PRESS_AT + 4) return "35-pressed"
  return "40-opened"
}

const SigninBrowser = ({ width }: { width: number }) => {
  const frame = useCurrentFrame()
  const k = width / 1440
  // Continue, in the page's pixels (1440 × 813).
  const button = { x: 720 * k, y: 538 * k + 58 }
  const p = interpolate(frame, [PRESS_AT - 16, PRESS_AT - 2], [0, 1], { ...clamp, easing: ease })
  const pressed = interpolate(frame, [PRESS_AT - 1, PRESS_AT + 2, PRESS_AT + 6], [0, 1, 0], clamp)
  const opened = frame >= PRESS_AT + 4
  const zoom = interpolate(frame, [SIGNIN_IN + 6, TYPE_AT - 2, PRESS_AT + 4, PRESS_AT + 16], [1, 1.95, 1.95, 1], { ...clamp, easing: ease })
  return (
    <div style={{ position: "relative", width, borderRadius: 22, overflow: "hidden", background: "#fff", boxShadow: "0 50px 100px rgba(0,0,0,.6), 0 0 0 1px rgba(255,255,255,.12)" }}>
      <div style={{ height: 58, display: "flex", alignItems: "center", padding: "0 22px", background: "#f2f2f4", borderBottom: "1px solid rgba(0,0,0,.08)", fontFamily: sans }}>
        <div style={{ display: "flex", gap: 10, width: 200 }}>
          {["#ff5f57", "#febc2e", "#28c840"].map((c) => <span key={c} style={{ width: 15, height: 15, borderRadius: 99, background: c }} />)}
        </div>
        <div style={{ margin: "0 auto", display: "flex", alignItems: "center", gap: 10, background: "#fff", borderRadius: 10, padding: "7px 22px", fontSize: 19, color: "#111", border: "1px solid rgba(0,0,0,.08)" }}>
          <svg width="13" height="16" viewBox="0 0 16 20"><rect x="1" y="8" width="14" height="11" rx="2.5" fill="#6e6e73" /><path d="M4 8V5.5a4 4 0 0 1 8 0V8" stroke="#6e6e73" strokeWidth="2" fill="none" /></svg>
          orbit.wbfsgcylfq2x.opentunnel.xyz
        </div>
        <div style={{ width: 200 }} />
      </div>
      {/* Close on the sign-in card while it's filled in, back out when the site opens. */}
      <div style={{ position: "relative", width, height: 813 * k, overflow: "hidden" }}>
        <div style={{ position: "absolute", inset: 0, transformOrigin: `${720 * k}px ${330 * k}px`, transform: `scale(${zoom})` }}>
          <Img src={staticFile(C(`signin/${signinFrame(frame)}.jpg`))} style={{ display: "block", width, height: 813 * k }} />
          {!opened ? <Arrow x={(width * 0.62 + (button.x - width * 0.62) * p)} y={(700 * k + (button.y - 58 - 700 * k) * p)} pressed={pressed} /> : null}
        </div>
      </div>
    </div>
  )
}

const Protection = () => {
  const frame = useCurrentFrame()
  const swap = interpolate(frame, [SIGNIN_IN - 6, SIGNIN_IN + 8], [0, 1], { ...clamp, easing: ease })
  return (
    <AbsoluteFill>
      <div style={{ position: "absolute", left: 120, top: 330, width: 600 }}>
        <Slam at={0} size={112}>Password</Slam>
        <Slam at={6} size={112}><Mark>protect it.</Mark></Slam>
        <Slam at={TYPE_AT} out={PRESS_AT + 2} size={36} color={dim} style={{ marginTop: 34, fontWeight: 500, letterSpacing: "-0.01em", lineHeight: 1.3 }}>Visitors get a sign-in page first.</Slam>
      </div>
      <div style={{ position: "absolute", left: 120, top: 616 }}>
        <Slam at={PRESS_AT + 6} size={36} color={dim} style={{ fontWeight: 500, letterSpacing: "-0.01em" }}>Then they're in.</Slam>
      </div>
      <div style={{ position: "absolute", left: 1010, top: 130, opacity: 1 - swap, transform: `translateX(${-swap * 80}px) scale(${1 - swap * 0.06})` }}>
        <Capture src={C("protection-dark.png")} width={800} />
        {/* The Password option, in the capture's pixels (1080 wide). */}
        <div style={{ position: "absolute", left: 0, top: 0, transform: `scale(${800 / 1080})`, transformOrigin: "0 0" }}>
          <Ring x={72} y={356} at={8} size={90} />
        </div>
      </div>
      {frame >= SIGNIN_IN - 6 ? (
        <div style={{ position: "absolute", left: 740, top: 200, opacity: swap, transform: `translateX(${(1 - swap) * 120}px)` }}>
          <SigninBrowser width={1080} />
        </div>
      ) : null}
    </AbsoluteFill>
  )
}

const protectionSfx = () => [
  <Sfx key="w" at={0} name="whoosh" volume={0.3} />,
  <Sfx key="c" at={8} name="click" volume={0.8} />,
  <Sfx key="w2" at={SIGNIN_IN - 4} name="whoosh" volume={0.3} />,
  ...Array.from({ length: 13 }, (_, i) => <Sfx key={`t${i}`} at={TYPE_AT + i * 2} name={`type${(i % 3) + 1}`} volume={0.28} />),
  <Sfx key="go" at={PRESS_AT} name="click" volume={0.8} />,
  <Sfx key="in" at={PRESS_AT + 5} name="chime" volume={0.5} />,
]

// ---------------------------------------------------------------- 13. the terminal (bars 30-31)

const CLI_START = 8

const Cli = () => {
  const frame = useCurrentFrame()
  const shared = CLI_START + typedAt(cliSession[0])
  const src = frame < shared + 2 ? "popover-before-dark.png" : frame < shared + 12 ? "p-starting.png" : frame < shared + 24 ? "p-checking.png" : "p-online.png"
  return (
    <AbsoluteFill>
      <Title top={60}>
        <Slam at={0} size={110}>Prefer the <Mark>terminal?</Mark></Slam>
      </Title>
      <div style={{ position: "absolute", left: 100, top: 300 }}>
        <Sequence from={CLI_START} layout="none">
          <Terminal width={1020} fontSize={27} />
        </Sequence>
        <Slam at={86} size={36} color={dim} style={{ marginTop: 34, fontWeight: 500, letterSpacing: "-0.01em" }}>
          Plus a local REST API, an MCP server, and webhooks.
        </Slam>
      </div>
      <Popover src={src} left={1150} top={290} />
    </AbsoluteFill>
  )
}

const cliSfx = () => {
  const out: React.ReactNode[] = []
  for (const line of cliSession) {
    const chars = Math.ceil(line.command.length / 2)
    for (let i = 0; i < chars; i += 2) out.push(<Sfx key={`${line.at}-${i}`} at={CLI_START + line.at + i} name={`type${(i % 3) + 1}`} volume={0.28} />)
    out.push(<Sfx key={`${line.at}-enter`} at={CLI_START + typedAt(line) - 1} name="click" volume={0.6} />)
  }
  out.push(<Sfx key="live" at={CLI_START + typedAt(cliSession[0]) + 24} name="chime" volume={0.5} />)
  return out
}

// ---------------------------------------------------------------- 11b. light and dark, an issue (bar 27)

const CopyClick = () => {
  const frame = useCurrentFrame()
  const p = interpolate(frame, [30, 42], [0, 1], { ...clamp, easing: ease })
  const pressed = interpolate(frame, [41, 44, 48], [0, 1, 0], clamp)
  return <Arrow x={1700 + (1960 - 1700) * p} y={700 + (372 - 700) * p} pressed={pressed} />
}

const Extras = () => {
  const frame = useCurrentFrame()
  const wipe = interpolate(frame, [4, 24], [0, 1], { ...clamp, easing: ease })
  return frame < 30 ? (
    <AbsoluteFill>
      <Title top={60}><Slam at={0} size={110}>Light <Mark>and dark.</Mark></Slam></Title>
      <div style={{ position: "absolute", left: 260, top: 240, width: 1400, height: 902, borderRadius: 26, overflow: "hidden", boxShadow: "0 40px 90px rgba(0,0,0,.6)" }}>
        <Img src={staticFile(C("main-overview.png"))} style={{ position: "absolute", width: 1400 }} />
        <div style={{ position: "absolute", inset: 0, clipPath: `inset(0 0 0 ${wipe * 100}%)` }}>
          <Img src={staticFile(C("main-overview-dark.png"))} style={{ position: "absolute", width: 1400 }} />
        </div>
        <div style={{ position: "absolute", top: 0, bottom: 0, left: `${wipe * 100}%`, width: 4, background: fg, boxShadow: `0 0 30px ${fg}`, opacity: wipe > 0 && wipe < 1 ? 1 : 0 }} />
      </div>
    </AbsoluteFill>
  ) : (
    <AbsoluteFill>
      <Title top={90}><Slam at={30} size={110}>Copy as a <Mark>GitHub issue.</Mark></Slam></Title>
      <div style={{ position: "absolute", left: 210, top: 270 }}>
        <Crop src={C("main-feedback-dark.png")} crop={{ x: 440, y: 120, width: 1920, height: 900 }} width={1500}>
          <Ring x={1955} y={364} at={44} />
          <CopyClick />
        </Crop>
      </div>
    </AbsoluteFill>
  )
}

const extrasSfx = () => [<Sfx key="w" at={4} name="whoosh" volume={0.4} />, <Sfx key="c" at={44} name="click" volume={0.8} />, <Sfx key="p" at={46} name="pop" volume={0.5} />]

// ---------------------------------------------------------------- 14. quick hits (bar 32)

const words = ["No account.", "No telemetry.", "Updates itself.", "Free."]

const Hits = () => (
  <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", textAlign: "center" }}>
    {words.map((w, i) => (
      <div key={w} style={{ position: "absolute" }}>
        <Slam at={i * BEAT} out={i < words.length - 1 ? (i + 1) * BEAT - 4 : undefined} size={170}>
          {i === words.length - 1 ? <Mark>{w}</Mark> : w}
        </Slam>
      </div>
    ))}
  </AbsoluteFill>
)

// ---------------------------------------------------------------- 15. end card (bars 33-34)

const End = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const icon = spring({ frame, fps, config: { damping: 11, stiffness: 180 } })
  const text = spring({ frame: frame - 8, fps, config: { damping: 18 } })
  const more = spring({ frame: frame - 22, fps, config: { damping: 18 } })
  const source = spring({ frame: frame - 34, fps, config: { damping: 16 } })
  const maker = spring({ frame: frame - 46, fps, config: { damping: 18 } })
  const fade = interpolate(frame, [100, 120], [0, 1], clamp)
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", textAlign: "center", fontFamily: sans, color: fg }}>
      <div style={{ position: "absolute", width: 900, height: 900, borderRadius: 999, background: `radial-gradient(closest-side, rgba(255,255,255,${0.1 * icon}), transparent)` }} />
      <div style={{ position: "relative" }}>
        <Img src={staticFile("brand/app-icon.png")} style={{ width: 230, transform: `scale(${0.5 + 0.5 * icon})`, opacity: Math.min(1, icon * 1.4) }} />
        <div style={{ opacity: text, transform: `translateY(${(1 - text) * 20}px)` }}>
          <div style={{ fontFamily: serif, fontSize: 132, marginTop: 10 }}>OpenTraffic</div>
          <div style={{ fontSize: 40, color: dim, marginTop: 4 }}>Share localhost. Collaborate live.</div>
        </div>
        <div style={{ opacity: more, transform: `translateY(${(1 - more) * 20}px)`, marginTop: 52 }}>
          <Pill style={{ fontFamily: mono, fontSize: 30 }}>
            <span style={{ color: dim }}>$</span> curl -fsSL opentraffic.dev/install | sh
          </Pill>
          <div style={{ fontSize: 30, color: dim, marginTop: 30 }}>Free for macOS · opentraffic.dev</div>
        </div>
        {OPEN_SOURCE ? (
          <div style={{ opacity: source, transform: `translateY(${(1 - source) * 20}px)`, marginTop: 40, display: "flex", alignItems: "center", justifyContent: "center", gap: 16, fontSize: 34, fontWeight: 600 }}>
            <GitHubMark size={40} color={fg} />
            Open source on GitHub
          </div>
        ) : null}
      </div>
      <div style={{ position: "absolute", bottom: 70, left: 0, right: 0, opacity: maker, transform: `translateY(${(1 - maker) * 12}px)`, fontSize: 28, letterSpacing: "0.02em", color: dim }}>
        Made by <span style={{ color: fg, fontWeight: 600 }}>Medda</span>
      </div>
      <AbsoluteFill style={{ background: bg, opacity: fade }} />
    </AbsoluteFill>
  )
}

// ---------------------------------------------------------------- the cut

// The music's sections (audio/synth.py): intro 1-2, drop 3-15, break and build 16-17, drop 18-28, break and
// build 29-30, drop 31-36, outro 37-38.
const cut = (session: Session) =>
  [
    { bars: 2, body: <Hook />, sfx: hookSfx() },
    { bars: 2, body: <Detect />, sfx: detectSfx() },
    { bars: 2, body: <Share />, sfx: shareSfx() },
    { bars: 2, body: <Path />, sfx: pathSfx() },
    { bars: 4, body: <Collab session={session} />, sfx: collabSfx(session) },
    { bars: 3, body: <Suggest session={session} />, sfx: suggestSfx(session) },
    { bars: 2, body: <Draw session={session} />, sfx: drawSfx() },
    { bars: 4, body: <Agent session={session} />, sfx: agentSfx(session) },
    { bars: 3, body: <Git />, sfx: gitSfx() },
    { bars: 2, body: <Phone session={session} />, sfx: phoneSfx(session) },
    { bars: 2, body: <Lead session={session} />, sfx: leadSfx(session) },
    { bars: 2, body: <Protection />, sfx: protectionSfx() },
    { bars: 1, body: <Extras />, sfx: extrasSfx() },
    { bars: 2, body: <Providers />, sfx: providerSfx() },
    { bars: 2, body: <Cli />, sfx: cliSfx() },
    { bars: 1, body: <Hits /> },
    { bars: 2, body: <End />, sfx: OPEN_SOURCE ? [<Sfx key="gh" at={34} name="pop" volume={0.45} />] : [] },
  ] as { bars: number; body: React.ReactNode; sfx?: React.ReactNode[] }[]

export const PROMO_FRAMES = 38 * BAR

export const Promo = ({ session }: { session: Session }) => {
  let from = 0
  return (
    <AbsoluteFill style={{ background: bg }}>
      <Stage />
      {cut(session).map((s) => {
        const start = from
        from += s.bars * BAR
        return (
          <Sequence key={start} from={start} durationInFrames={s.bars * BAR}>
            {s.body}
            {s.sfx}
          </Sequence>
        )
      })}
      <Audio src={staticFile("promo/music.wav")} volume={0.72} />
    </AbsoluteFill>
  )
}
