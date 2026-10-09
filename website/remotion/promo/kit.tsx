import { Audio, Easing, Img, interpolate, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion"
import { sans } from "../theme"

// The promo's look: black and white. Only the app's own windows bring color.
export const bg = "#000000"
export const fg = "#fafafa"
export const dim = "#8e8e93"

// 120 BPM at 30 fps: a beat is 15 frames, a bar 60. The music (audio/music.py) is on the same grid.
export const BEAT = 15
export const BAR = 60

export const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const
export const ease = Easing.bezier(0.22, 1, 0.36, 1)

/** A sound effect at a frame. */
export const Sfx = ({ at, name, volume = 0.6 }: { at: number; name: string; volume?: number }) => (
  <Sequence from={Math.round(at)} durationInFrames={90} layout="none">
    <Audio src={staticFile(`promo/${name}.wav`)} volume={volume} />
  </Sequence>
)

/** A line of big type that pops in at `at` (frames from the parent sequence) and out at `out`. */
export const Slam = ({
  at,
  out,
  children,
  size = 132,
  color = fg,
  style,
}: {
  at: number
  out?: number
  children: React.ReactNode
  size?: number
  color?: string
  style?: React.CSSProperties
}) => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const s = spring({ frame: frame - at, fps, config: { damping: 14, stiffness: 260, mass: 0.6 } })
  const gone = out === undefined ? 0 : interpolate(frame, [out, out + 6], [0, 1], clamp)
  if (frame < at) return null
  return (
    <div
      style={{
        fontFamily: sans,
        fontWeight: 700,
        fontSize: size,
        lineHeight: 1.2,
        letterSpacing: "-0.04em",
        color,
        opacity: Math.min(1, s * 1.5) * (1 - gone),
        transform: `translateY(${(1 - s) * 40 - gone * 30}px) scale(${0.92 + 0.08 * s})`,
        filter: `blur(${(1 - Math.min(1, s * 1.3)) * 12 + gone * 8}px)`,
        ...style,
      }}
    >
      {children}
    </div>
  )
}

/** A capture with a soft shadow, as a positioned box. */
export const Capture = ({ src, width, style }: { src: string; width: number; style?: React.CSSProperties }) => (
  <Img src={staticFile(src)} style={{ display: "block", width, filter: "drop-shadow(0 30px 60px rgba(0,0,0,.55)) drop-shadow(0 0 1px rgba(255,255,255,.12))", ...style }} />
)

/** Words set in reverse, white on black type: the promo's only emphasis. */
export const Mark = ({ children }: { children: React.ReactNode }) => (
  <span style={{ display: "inline-block", lineHeight: 1, background: fg, color: bg, padding: "0.03em 0.16em 0.09em", borderRadius: "0.1em" }}>{children}</span>
)

/** The dark stage: a dotted grid and a glow that breathes with the kick once the beat is in. */
export const Stage = ({ pulseFrom = 120 }: { pulseFrom?: number }) => {
  const frame = useCurrentFrame()
  const beat = frame >= pulseFrom ? Math.exp(-(frame % BEAT) / 4) : 0
  return (
    <div style={{ position: "absolute", inset: 0, background: bg, overflow: "hidden" }}>
      <div style={{ position: "absolute", inset: 0, backgroundImage: "radial-gradient(rgba(255,255,255,.07) 1.2px, transparent 1.2px)", backgroundSize: "28px 28px", maskImage: "radial-gradient(ellipse at center, #000 30%, transparent 80%)" }} />
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: "55%",
          width: 1600,
          height: 1000,
          transform: `translate(-50%, -50%) scale(${1 + beat * 0.04})`,
          background: `radial-gradient(closest-side, rgba(255,255,255,${0.05 + beat * 0.035}), transparent)`,
        }}
      />
    </div>
  )
}

/** A pill like a copied link. */
export const Pill = ({ children, style }: { children: React.ReactNode; style?: React.CSSProperties }) => (
  <div style={{ display: "inline-flex", alignItems: "center", gap: 16, padding: "18px 30px", borderRadius: 999, background: "rgba(255,255,255,.06)", border: "1px solid rgba(255,255,255,.18)", color: fg, fontFamily: sans, fontSize: 34, ...style }}>
    {children}
  </div>
)
