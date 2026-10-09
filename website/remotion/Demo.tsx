import { AbsoluteFill, interpolate, Sequence, useCurrentFrame } from "remotion"
import { BrowserScene, browserTimeline } from "./parts/BrowserScene"
import { CliScene } from "./parts/CliScene"
import { EndCard } from "./parts/EndCard"
import { detection, SHARE_SCENE_FRAMES, ShareScene } from "./parts/ShareScene"
import { fit, window, WindowScene } from "./parts/WindowScene"
import type { Session } from "./session"
import { ink, sans } from "./theme"

// Every scene shows the real app (or a real browser session on a page it shared), captured from a
// demo build; the camera only pans and zooms.
type Line = { at: number; step: string; text: string }

const whole = { x: window.width / 2, y: window.height / 2 }
// The Protection sheet as captured (540 × 520 pt at 2x).
const protection = { width: 1080, height: 1040 }

type Scene = { length: number; lines: Line[]; render: () => React.ReactNode }

const scenes = (session: Session): Scene[] => {
  const browser = browserTimeline(session)
  const at = browser.at
  return [
  {
    length: SHARE_SCENE_FRAMES,
    lines: [
      { at: 0, step: "1", text: "OpenTraffic finds every dev server running on your Mac" },
      { at: detection.uptime - 4, step: "1", text: "With its name, port, and how long it's been up" },
      { at: detection.uptime + 40, step: "1", text: "Pick one and share it" },
    ],
    render: () => <ShareScene />,
  },
  {
    length: 180,
    lines: [
      { at: 0, step: "2", text: "Every hop is checked, from localhost to the public link" },
      { at: 112, step: "2", text: "See who's on the page right now" },
    ],
    render: () => (
      <WindowScene
        src="capture/main-overview.png"
        shots={[
          { at: 0, ...whole, zoom: fit * 0.96 },
          { at: 16, ...whole, zoom: fit },
          { at: 34, ...whole, zoom: fit },
          { at: 66, x: 1450, y: 560, zoom: 1.1 },
          { at: 104, x: 1450, y: 560, zoom: 1.1 },
          { at: 136, x: 1180, y: 1080, zoom: 1.25 },
        ]}
      />
    ),
  },
  {
    length: browser.length,
    lines: [
      { at: 0, step: "3", text: "Everyone with the link sees each other's cursors" },
      { at: at("ping", -20), step: "3", text: "Hold ⌥ and click to point at something" },
      { at: at("arm", -10), step: "3", text: "Pick any element to comment on it" },
      { at: at("compose", 4), step: "3", text: "Say what's wrong: a picture of the element goes with it" },
      { at: at("pinned", 10), step: "3", text: "Open a comment to see what they saw, and in which browser" },
      { at: at("reply", 6), step: "4", text: "Your coding agent replies, over MCP" },
    ],
    render: () => <BrowserScene session={session} />,
  },
  {
    length: 140,
    lines: [{ at: 0, step: "4", text: "Every comment lands in OpenTraffic, ready to resolve" }],
    render: () => (
      <WindowScene
        src="capture/main-feedback.png"
        shots={[
          { at: 0, ...whole, zoom: fit },
          { at: 22, ...whole, zoom: fit },
          { at: 62, x: 1420, y: 650, zoom: 1.05 },
        ]}
      />
    ),
  },
  {
    length: 120,
    lines: [{ at: 0, step: "5", text: "Lock an ngrok share with a password, or Google or GitHub sign-in" }],
    render: () => (
      <WindowScene
        src="capture/protection.png"
        size={protection}
        shots={[
          { at: 0, x: protection.width / 2, y: protection.height / 2, zoom: 0.8 },
          { at: 20, x: protection.width / 2, y: protection.height / 2, zoom: 0.8 },
          { at: 70, x: 540, y: 440, zoom: 1.05 },
        ]}
      />
    ),
  },
  {
    length: 150,
    lines: [{ at: 0, step: "6", text: "Prefer the terminal? Share, copy, and stop from the command line" }],
    render: () => <CliScene />,
  },
  { length: 100, lines: [], render: () => <EndCard /> },
]
}

export const demoFrames = (session: Session) => scenes(session).reduce((sum, scene) => sum + scene.length, 0)

/** Fades a scene in and out at its edges. */
const Fade = ({ length, last, children }: { length: number; last: boolean; children: React.ReactNode }) => {
  const frame = useCurrentFrame()
  const opacity = interpolate(frame, last ? [0, 10] : [0, 10, length - 10, length], last ? [0, 1] : [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })
  return <AbsoluteFill style={{ opacity }}>{children}</AbsoluteFill>
}

/** The step caption, dipping briefly whenever its text changes. */
const Caption = ({ lines, length }: { lines: Line[]; length: number }) => {
  const frame = useCurrentFrame()
  if (lines.length === 0) return null
  const line = [...lines].reverse().find((l) => frame >= l.at) ?? lines[0]
  const edges = interpolate(frame, [6, 18, length - 12, length - 2], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })
  const dip = Math.min(1, ...lines.slice(1).map((l) => interpolate(Math.abs(frame - l.at), [0, 6], [0, 1], { extrapolateRight: "clamp" })))
  return (
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 30, display: "flex", justifyContent: "center", opacity: edges * dip, fontFamily: sans }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14, background: "rgba(255,255,255,.94)", border: "1px solid rgba(15,23,42,.08)", borderRadius: 999, padding: "10px 26px 10px 10px", fontSize: 24, color: ink, boxShadow: "0 8px 24px rgba(15,23,42,.10)" }}>
        <span style={{ width: 36, height: 36, borderRadius: 99, background: ink, color: "#fff", display: "grid", placeItems: "center", fontSize: 18, fontWeight: 700 }}>{line.step}</span>
        {line.text}
      </div>
    </div>
  )
}

/** `captions: false` renders clean frames for the README's pictures. */
export const Demo = ({ session, captions = true }: { session: Session; captions?: boolean }) => {
  let from = 0
  return (
    <AbsoluteFill style={{ background: "#fafafa", fontFamily: sans }}>
      {/* medda.se's dotted grid, fading toward the edges. */}
      <AbsoluteFill style={{ backgroundImage: "radial-gradient(rgba(15,23,42,.10) 1.2px, transparent 1.2px)", backgroundSize: "26px 26px", maskImage: "radial-gradient(ellipse at center, #000 40%, transparent 85%)" }} />
      {scenes(session).map((scene, i, all) => {
        const start = from
        from += scene.length
        const last = i === all.length - 1
        return (
          <Sequence key={i} from={start} durationInFrames={scene.length}>
            <Fade length={scene.length} last={last}>{scene.render()}</Fade>
            {captions ? <Caption lines={scene.lines} length={scene.length} /> : null}
          </Sequence>
        )
      })}
    </AbsoluteFill>
  )
}
