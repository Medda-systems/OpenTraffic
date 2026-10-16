import { AbsoluteFill, Audio, Easing, Img, interpolate, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion"
import { GitHubMark } from "../parts/GitHubMark"
import { OPEN_SOURCE } from "../release"
import { SessionView } from "../parts/SessionView"
import { cliSession, Terminal, type TerminalLine, typedAt } from "../parts/Terminal"
import { GIT } from "../git"
import type { Seat, Session } from "../session"
import { mono, sans, serif } from "../theme"
import { BAR, BEAT, bg, Capture, clamp, dim, ease, fg, Mark, Pill, Sfx, Slam, Stage } from "./kit"

// A 46-second promo for social posts: 23 bars at 120 BPM, black and white around the app's own windows.
// Everything on screen is the real app or a real session in a browser (capture/), and the cuts land
// on the beat of the soundtrack (audio/music.py).

const C = (name: string) => `capture/promo/${name}`

// ---------------------------------------------------------------- shared pieces

const Arrow = ({ x, y, pressed = 0 }: { x: number; y: number; pressed?: number }) => (
  <svg width="34" height="42" viewBox="0 0 28 34" style={{ position: "absolute", left: x - 3, top: y - 3, transform: `scale(${1 - pressed * 0.12})`, transformOrigin: "3px 3px", filter: "drop-shadow(0 2px 4px rgba(0,0,0,.6))" }}>
    <path d="M2 2 L2 27 L8.5 21 L13 31 L17.5 29 L13 19.5 L22 19.5 Z" fill="#000" stroke="#fff" strokeWidth="2" strokeLinejoin="round" />
  </svg>
)

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

// ---------------------------------------------------------------- 2. it finds your servers (bar 3)

const Detect = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const flash = interpolate(frame, [0, 10], [1, 0], clamp)
  const open = spring({ frame, fps, config: { damping: 15, stiffness: 200 } })
  const src = frame < 12 ? "detect-empty.png" : frame < 26 ? "detect-one.png" : frame < 44 ? "detect-three.png" : "popover-before-dark.png"
  return (
    <AbsoluteFill>
      <MenuBar />
      <div style={{ opacity: open, transform: `translateY(${(1 - open) * -14}px)` }}>
        <Popover src={src} />
      </div>
      <div style={{ position: "absolute", left: 130, top: 300 }}>
        <Slam at={4} size={130}>Finds every</Slam>
        <Slam at={10} size={130}><Mark>dev server.</Mark></Slam>
      </div>
      <AbsoluteFill style={{ background: "#fff", opacity: flash }} />
    </AbsoluteFill>
  )
}

const detectSfx = () => [<Sfx key="a" at={12} name="pop" volume={0.55} />, <Sfx key="b" at={26} name="pop" volume={0.55} />, <Sfx key="c" at={30} name="pop" volume={0.45} />]

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

// ---------------------------------------------------------------- 4-7. the session in the browser (bars 6-12)

type Segment = { from: number; to: number; seat: Seat; rec: [number, number]; shot?: { x: number; y: number; zoom: number } }

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
  const blend = interpolate(frame - s.from, [0, 10], [0, 1], { ...clamp, easing: ease })
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

// Lea and Sam look around, Sam points, Lea picks the trial button and comments on it (bars 6-8).
const collabSegments = (m: Record<string, number>, k: number): Segment[] => [
  { from: 0, to: 40, seat: "ava", rec: [m.wander, m.wander + 48], shot: { x: 700 * k, y: 420 * k, zoom: 1.3 } },
  { from: 40, to: 75, seat: "ava", rec: [m.ping - 14, m.ping + 26], shot: { x: 560 * k, y: 300 * k, zoom: 1.35 } },
  { from: 75, to: 135, seat: "lea", rec: [m.compose - 75, m.compose + 2] },
  { from: 135, to: 180, seat: "lea", rec: [m.compose + 2, m.edit - 4], shot: { x: 480 * k, y: 420 * k, zoom: 1.5 } },
]

const Collab = ({ session }: { session: Session }) => {
  const k = 1520 / session.viewport.width
  return (
    <AbsoluteFill>
      <Title top={44}><Slam at={0} out={37} size={96}>Live cursors.</Slam></Title>
      <Title top={44}><Slam at={40} out={72} size={96}>Point at anything.</Slam></Title>
      <Title top={44}><Slam at={75} out={132} size={96}>Pick any element.</Slam></Title>
      <Title top={44}><Slam at={135} size={96}><Mark>Comment on it.</Mark></Slam></Title>
      <div style={{ position: "absolute", left: 200, top: 176 }}>
        <Browser session={session} segments={collabSegments(session.marks, k)} />
      </div>
    </AbsoluteFill>
  )
}

const collabSfx = (session: Session) => {
  const m = session.marks
  const segments = collabSegments(m, 1)
  const at = (seat: Seat, rec: number) => sceneFrameOf(segments, seat, rec)
  const typing = Array.from({ length: 14 }, (_, i) => 137 + i * 3)
  return [
    ...[0, 5, 10].map((d, i) => <Sfx key={`j${i}`} at={4 + d} name="pop" volume={0.35} />),
    <Sfx key="ping" at={at("ava", m.ping)} name="ping" volume={0.55} />,
    <Sfx key="pick" at={at("lea", m.compose)} name="click" volume={0.8} />,
    ...typing.map((f, i) => <Sfx key={`t${i}`} at={f} name={`type${(i % 3) + 1}`} volume={0.3} />),
  ]
}

// Lea suggests the change itself: new words, then a bigger button, as she drags (bars 9-10).
const suggestSegments = (m: Record<string, number>, k: number): Segment[] => {
  const shot = { x: 320 * k, y: 370 * k, zoom: 1.6 }
  return [
    { from: 0, to: 48, seat: "lea", rec: [m.edit + 14, m.style - 6], shot },
    { from: 48, to: 120, seat: "lea", rec: [m.style + 18, m.post - 20], shot },
  ]
}

const Suggest = ({ session }: { session: Session }) => {
  const k = 1520 / session.viewport.width
  return (
    <AbsoluteFill>
      <Title top={44}><Slam at={0} out={57} size={96}>Suggest the <Mark>fix.</Mark></Slam></Title>
      <Title top={44}><Slam at={60} size={96}>It changes <Mark>live.</Mark></Slam></Title>
      <div style={{ position: "absolute", left: 200, top: 176 }}>
        <Browser session={session} segments={suggestSegments(session.marks, k)} />
      </div>
    </AbsoluteFill>
  )
}

const suggestSfx = () => [
  ...Array.from({ length: 10 }, (_, i) => <Sfx key={`t${i}`} at={4 + i * 3.5} name={`type${(i % 3) + 1}`} volume={0.3} />),
  <Sfx key="c" at={48} name="click" volume={0.7} />,
  <Sfx key="w" at={60} name="whoosh" volume={0.3} />,
]

// Ava opens it while the agent is at work; Lea's page has the fix; it's resolved in OpenTraffic (bars 11-12).
const agentSegments = (m: Record<string, number>, k: number): Segment[] => [
  { from: 0, to: 44, seat: "ava", rec: [m.opened - 2, m.opened + 40], shot: { x: 330 * k, y: 480 * k, zoom: 1.5 } },
  { from: 44, to: 80, seat: "lea", rec: [m.told - 4, m.told + 30], shot: { x: 720 * k, y: 406 * k, zoom: 1.02 } },
]

const tools = ["get_feedback", "claim_comment", "reply_to_comment", "resolve_comment"]

const Agent = ({ session }: { session: Session }) => {
  const frame = useCurrentFrame()
  const k = 1520 / session.viewport.width
  const second = interpolate(frame, [78, 86], [0, 1], { ...clamp, easing: ease })
  return (
    <AbsoluteFill>
      <Title top={44}>
        <div style={{ opacity: 1 - second }}>
          <Slam at={0} out={41} size={96}>Your agent gets <Mark>the change.</Mark></Slam>
        </div>
      </Title>
      <Title top={44}>
        <div style={{ opacity: 1 - second }}><Slam at={44} size={96}>And <Mark>fixes it.</Mark></Slam></div>
      </Title>
      <div style={{ position: "absolute", left: 200, top: 176, opacity: 1 - second, transform: `scale(${1 - second * 0.08})` }}>
        <Browser session={session} segments={agentSegments(session.marks, k)} />
      </div>
      {frame >= 78 ? (
        <>
          <Title top={60}><Slam at={80} size={110}>Over <Mark>MCP.</Mark></Slam></Title>
          <div style={{ position: "absolute", left: 310, top: 250, opacity: second }}>
            <Crop src={C("main-feedback-dark.png")} crop={{ x: 520, y: 520, width: 1800, height: 800 }} width={1300} />
          </div>
          <div style={{ position: "absolute", bottom: 70, left: 0, right: 0, display: "flex", justifyContent: "center", gap: 22 }}>
            {tools.map((t, i) => (
              <Slam key={t} at={84 + i * 6} size={34}>
                <Pill style={{ fontFamily: mono, fontSize: 30, ...(i === 3 ? { background: fg, color: bg, borderColor: fg } : {}) }}>{t}</Pill>
              </Slam>
            ))}
          </div>
        </>
      ) : null}
    </AbsoluteFill>
  )
}

const agentSfx = () => [<Sfx key="s" at={46} name="success" volume={0.6} />, <Sfx key="w" at={78} name="whoosh" volume={0.35} />, ...tools.map((t, i) => <Sfx key={t} at={84 + i * 6} name="pop" volume={0.4} />)]

// ---------------------------------------------------------------- 8. a commit per fix (bar 13, the break)

/** The project's history from the run recorded for the session (capture/record-session.mjs). */
export const gitSession: TerminalLine[] = [
  { at: 2, command: "git branch --show-current", output: GIT.branch },
  { at: 26, command: "git log --oneline -2", output: GIT.commits },
]

const Git = () => (
  <AbsoluteFill>
    <div style={{ position: "absolute", left: 130, top: 250, width: 760 }}>
      <Slam at={0} size={104}>Every fix,</Slam>
      <Slam at={6} size={104}><Mark>its own commit.</Mark></Slam>
      <Slam at={30} size={38} color={dim} style={{ marginTop: 34, fontWeight: 500, letterSpacing: "-0.01em" }}>On a branch of its own. Merged back when you stop.</Slam>
    </div>
    <div style={{ position: "absolute", left: 930, top: 300 }}>
      <Terminal width={900} fontSize={25} lines={gitSession} title="Terminal — orbit" />
    </div>
  </AbsoluteFill>
)

const gitSfx = () => {
  const out: React.ReactNode[] = []
  for (const line of gitSession) {
    for (let i = 0; i < Math.ceil(line.command.length / 2); i += 2) out.push(<Sfx key={`${line.at}-${i}`} at={line.at + i} name={`type${(i % 3) + 1}`} volume={0.25} />)
    out.push(<Sfx key={`${line.at}-enter`} at={typedAt(line) - 1} name="click" volume={0.5} />)
  }
  return out
}

// ---------------------------------------------------------------- 9. their phone (bar 14, the build)

const phoneSegments = (m: Record<string, number>, k: number): Segment[] => [
  { from: 0, to: 26, seat: "ava", rec: [m.phone - 2, m.phone + 26], shot: { x: 720 * k, y: 406 * k, zoom: 1.08 } },
  { from: 26, to: 60, seat: "ava", rec: [m.turn + 4, m.turn + 40], shot: { x: 720 * k, y: 406 * k, zoom: 1.08 } },
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

const phoneSfx = () => [<Sfx key="c" at={2} name="click" volume={0.7} />, <Sfx key="w" at={30} name="whoosh" volume={0.4} />]

// ---------------------------------------------------------------- 10. lead everyone into it (bars 15-16)

const leadSegments = (m: Record<string, number>, seat: Seat): Segment[] => [
  { from: 0, to: 50, seat, rec: [m.leadPhone - 6, m.leadPhone + 60] },
  { from: 50, to: 120, seat, rec: [m.leadScroll - 2, m.leadScroll + 100] },
]

const Lead = ({ session }: { session: Session }) => (
  <AbsoluteFill>
    <Title top={60}><Slam at={0} size={100}>Lead everyone <Mark>into it.</Mark></Slam></Title>
    <div style={{ position: "absolute", left: 80, top: 260, display: "flex", gap: 40 }}>
      <Browser session={session} segments={leadSegments(session.marks, "ava")} width={860} />
      <Browser session={session} segments={leadSegments(session.marks, "lea")} width={860} />
    </div>
  </AbsoluteFill>
)

const leadSfx = () => [<Sfx key="c" at={6} name="click" volume={0.7} />, <Sfx key="j" at={22} name="join" volume={0.5} />]

// ---------------------------------------------------------------- 11. draw, and an area (bars 17-18)

const drawSegments = (m: Record<string, number>, k: number): Segment[] => [
  { from: 0, to: 60, seat: "ava", rec: [m.draw + 22, m.draw + 82], shot: { x: 560 * k, y: 230 * k, zoom: 1.4 } },
  { from: 60, to: 120, seat: "lea", rec: [m.area + 30, m.areaPosted], shot: { x: 520 * k, y: 560 * k, zoom: 1.35 } },
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

const drawSfx = () => [<Sfx key="w" at={4} name="whoosh" volume={0.3} />, <Sfx key="c" at={62} name="click" volume={0.6} />, <Sfx key="p" at={118} name="pop" volume={0.5} />]

// ---------------------------------------------------------------- 12. providers (bar 19)

const providers = [
  { kind: "quick", name: "Cloudflare", logo: "brand/provider-cloudflare.svg", line: "A temporary URL. No account." },
  // OpenTunnel is made by Anomaly; the app shows Anomaly's mark for it.
  { kind: "opentunnel", name: "OpenTunnel", logo: "brand/provider-opentunnel.svg", line: "A lasting address, encrypted end to end." },
  { kind: "tailscale", name: "Tailscale", logo: "brand/provider-tailscale.svg", line: "Private to your devices." },
  { kind: "ngrok", name: "ngrok", logo: "brand/provider-ngrok.svg", line: "With a request inspector." },
]

const Providers = () => {
  const frame = useCurrentFrame()
  const i = Math.min(providers.length - 1, Math.floor(frame / BEAT))
  const p = providers[i]
  const bump = Math.exp(-(frame - i * BEAT) / 3) * (frame < providers.length * BEAT ? 1 : 0)
  const outro = 0
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
    </AbsoluteFill>
  )
}

const providerSfx = () => providers.map((p, i) => <Sfx key={p.kind} at={i * BEAT} name="whoosh" volume={0.3} />)

// ---------------------------------------------------------------- 13. the terminal (bar 20)

const CLI_START = 2
// The command-line session, quicker: the copy follows as soon as the share is live.
const quickCli: TerminalLine[] = [cliSession[0], { ...cliSession[1], at: 30 }]

const Cli = () => {
  const frame = useCurrentFrame()
  const shared = CLI_START + typedAt(quickCli[0])
  const src = frame < shared + 2 ? "popover-before-dark.png" : frame < shared + 12 ? "p-starting.png" : frame < shared + 24 ? "p-checking.png" : "p-online.png"
  return (
    <AbsoluteFill>
      <Title top={60}>
        <Slam at={0} size={110}>Prefer the <Mark>terminal?</Mark></Slam>
      </Title>
      <div style={{ position: "absolute", left: 100, top: 300 }}>
        <Sequence from={CLI_START} layout="none">
          <Terminal width={1020} fontSize={27} lines={quickCli} />
        </Sequence>
      </div>
      <Popover src={src} left={1150} top={290} />
    </AbsoluteFill>
  )
}

const cliSfx = () => {
  const out: React.ReactNode[] = []
  for (const line of quickCli) {
    const chars = Math.ceil(line.command.length / 2)
    for (let i = 0; i < chars; i += 2) out.push(<Sfx key={`${line.at}-${i}`} at={CLI_START + line.at + i} name={`type${(i % 3) + 1}`} volume={0.28} />)
    out.push(<Sfx key={`${line.at}-enter`} at={CLI_START + typedAt(line) - 1} name="click" volume={0.6} />)
  }
  out.push(<Sfx key="live" at={CLI_START + typedAt(quickCli[0]) + 20} name="chime" volume={0.5} />)
  return out
}

// ---------------------------------------------------------------- 14. quick hits (bar 21)

const words = ["No account.", "No telemetry.", "Open source.", "Free."]

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

// ---------------------------------------------------------------- 15. end card (bars 22-23)

const End = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const icon = spring({ frame, fps, config: { damping: 11, stiffness: 180 } })
  const text = spring({ frame: frame - 8, fps, config: { damping: 18 } })
  const more = spring({ frame: frame - 22, fps, config: { damping: 18 } })
  const source = spring({ frame: frame - 34, fps, config: { damping: 16 } })
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
      <AbsoluteFill style={{ background: bg, opacity: fade }} />
    </AbsoluteFill>
  )
}

// ---------------------------------------------------------------- the cut

// The music's sections (audio/synth.py): intro 1-2, drop 3-12, break 13, build 14, drop 15-21, outro 22-23.
const cut = (session: Session) =>
  [
    { bars: 2, body: <Hook />, sfx: hookSfx() },
    { bars: 1, body: <Detect />, sfx: detectSfx() },
    { bars: 2, body: <Share />, sfx: shareSfx() },
    { bars: 3, body: <Collab session={session} />, sfx: collabSfx(session) },
    { bars: 2, body: <Suggest session={session} />, sfx: suggestSfx() },
    { bars: 2, body: <Agent session={session} />, sfx: agentSfx() },
    { bars: 1, body: <Git />, sfx: gitSfx() },
    { bars: 1, body: <Phone session={session} />, sfx: phoneSfx() },
    { bars: 2, body: <Lead session={session} />, sfx: leadSfx() },
    { bars: 2, body: <Draw session={session} />, sfx: drawSfx() },
    { bars: 1, body: <Providers />, sfx: providerSfx() },
    { bars: 1, body: <Cli />, sfx: cliSfx() },
    { bars: 1, body: <Hits /> },
    { bars: 2, body: <End />, sfx: OPEN_SOURCE ? [<Sfx key="gh" at={34} name="pop" volume={0.45} />] : [] },
  ] as { bars: number; body: React.ReactNode; sfx?: React.ReactNode[] }[]

export const PROMO_FRAMES = 23 * BAR

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
