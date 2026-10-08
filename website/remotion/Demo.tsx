import { AbsoluteFill, interpolate, Sequence, useCurrentFrame } from "remotion"
import { CollabScene } from "./parts/CollabScene"
import { EndCard } from "./parts/EndCard"
import { MenuBarScene } from "./parts/MenuBarScene"
import { PathScene } from "./parts/PathScene"
import { ink, muted, sans } from "./theme"

// Scenes: [start, length, step caption].
const scenes = [
  { from: 0, length: 190, step: "1", caption: "Pick a dev server from the menu bar and share it" },
  { from: 190, length: 110, step: "2", caption: "Every hop is checked, from localhost to the public URL" },
  { from: 300, length: 360, step: "3", caption: "Visitors see each other, point, and pin comments" },
  { from: 660, length: 100, step: "", caption: "" },
] as const

export const DEMO_FRAMES = 760

/** Fades a scene in and out at its edges. */
const Fade = ({ length, children }: { length: number; children: React.ReactNode }) => {
  const frame = useCurrentFrame()
  const opacity = interpolate(frame, [0, 10, length - 10, length], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })
  return <AbsoluteFill style={{ opacity }}>{children}</AbsoluteFill>
}

const Caption = ({ step, text, agent }: { step: string; text: string; agent: boolean }) => {
  const frame = useCurrentFrame()
  const show = interpolate(frame, [6, 18], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })
  const label = agent && frame > 210 ? { step: "4", text: "Your coding agent fixes it and replies, over MCP" } : { step, text }
  return (
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 34, display: "flex", justifyContent: "center", opacity: show, fontFamily: sans }}>
      <div style={{ display: "flex", alignItems: "center", gap: 14, background: "rgba(255,255,255,.9)", border: "1px solid rgba(15,23,42,.08)", borderRadius: 999, padding: "10px 24px 10px 10px", fontSize: 22, color: ink, boxShadow: "0 8px 24px rgba(15,23,42,.08)" }}>
        <span style={{ width: 34, height: 34, borderRadius: 99, background: ink, color: "#fff", display: "grid", placeItems: "center", fontSize: 17, fontWeight: 700 }}>{label.step}</span>
        {label.text}
      </div>
    </div>
  )
}

export const Demo = () => (
  <AbsoluteFill style={{ background: "#fafafa", fontFamily: sans }}>
    {/* medda.se's dotted grid, fading toward the edges. */}
    <AbsoluteFill style={{ backgroundImage: "radial-gradient(rgba(15,23,42,.10) 1.2px, transparent 1.2px)", backgroundSize: "26px 26px", maskImage: "radial-gradient(ellipse at center, #000 40%, transparent 85%)" }} />
    <Sequence from={scenes[0].from} durationInFrames={scenes[0].length}>
      <Fade length={scenes[0].length}><MenuBarScene /></Fade>
      <Caption step={scenes[0].step} text={scenes[0].caption} agent={false} />
    </Sequence>
    <Sequence from={scenes[1].from} durationInFrames={scenes[1].length}>
      <Fade length={scenes[1].length}><PathScene /></Fade>
      <Caption step={scenes[1].step} text={scenes[1].caption} agent={false} />
    </Sequence>
    <Sequence from={scenes[2].from} durationInFrames={scenes[2].length}>
      <Fade length={scenes[2].length}><CollabScene /></Fade>
      <Caption step={scenes[2].step} text={scenes[2].caption} agent />
    </Sequence>
    <Sequence from={scenes[3].from} durationInFrames={scenes[3].length}>
      <Fade length={scenes[3].length + 20}><EndCard /></Fade>
    </Sequence>
    <div style={{ display: "none", color: muted }} />
  </AbsoluteFill>
)
