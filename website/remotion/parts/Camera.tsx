import { AbsoluteFill, Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion"

/** Where the camera looks at a given frame: a point in scene pixels and a zoom. */
export type Shot = { at: number; x: number; y: number; zoom: number }

const ease = Easing.bezier(0.65, 0, 0.35, 1)

/** Pans and zooms over a scene laid out in its own pixels, easing between shots. */
export const Camera = ({ shots, children }: { shots: Shot[]; children: React.ReactNode }) => {
  const frame = useCurrentFrame()
  const { width, height } = useVideoConfig()
  const at = shots.map((s) => s.at)
  const value = (key: "x" | "y" | "zoom") =>
    shots.length === 1
      ? shots[0][key]
      : interpolate(frame, at, shots.map((s) => s[key]), { easing: ease, extrapolateLeft: "clamp", extrapolateRight: "clamp" })
  const zoom = value("zoom")
  return (
    <AbsoluteFill style={{ overflow: "hidden" }}>
      <div
        style={{
          position: "absolute",
          left: 0,
          top: 0,
          transformOrigin: "0 0",
          transform: `translate(${width / 2}px, ${height / 2}px) scale(${zoom}) translate(${-value("x")}px, ${-value("y")}px)`,
        }}
      >
        {children}
      </div>
    </AbsoluteFill>
  )
}
