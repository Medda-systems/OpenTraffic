import { Easing, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion"
import { ink, sans } from "../theme"
import { Camera } from "./Camera"
import { Cursor } from "./Cursor"

// The real menu bar popover, captured at 2x (720 px wide = 360 pt), shown at that size. It opens as
// the demo servers start one after another (captured as OpenTraffic found them), then Orbit is shared.
const glyph = { x: 1240, y: 24 }
const popover = { left: glyph.x - 360, top: 56 }
// Points inside the captures, in their pixels.
const shareButton = { x: popover.left + 617, y: popover.top + 352 }

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const
const glide = Easing.bezier(0.45, 0, 0.2, 1)

/** Follows the cursor through [frame, x, y] stops. */
function path(frame: number, stops: [number, number, number][]) {
  const at = stops.map((s) => s[0])
  return {
    x: interpolate(frame, at, stops.map((s) => s[1]), { ...clamp, easing: glide }),
    y: interpolate(frame, at, stops.map((s) => s[2]), { ...clamp, easing: glide }),
  }
}

const press = (frame: number, at: number) => interpolate(frame, [at - 3, at, at + 4], [0, 1, 0], clamp)

/** When the servers show up in the popover, and when sharing starts (scene frames). */
export const detection = { two: 50, three: 76, uptime: 112 }
const D = 96 // the share happens this much later than without the detection part
export const SHARE_SCENE_FRAMES = 240

const listAt = (frame: number) =>
  frame < detection.two ? "detect-empty" : frame < detection.three ? "detect-two" : frame < detection.uptime ? "detect-three" : "popover-before"

export const ShareScene = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const open = spring({ frame: frame - 24, fps, config: { damping: 20, stiffness: 220 } })
  const live = interpolate(frame, [D + 76, D + 84], [0, 1], clamp)
  const cursor = path(frame, [
    [0, 760, 640],
    [22, glyph.x + 4, glyph.y + 2],
    [40, glyph.x + 4, glyph.y + 2],
    [70, 1720, 520],
    [D + 40, 1720, 520],
    [D + 68, shareButton.x - 18, shareButton.y - 10],
    [D + 96, shareButton.x - 18, shareButton.y - 10],
    [D + 118, 1720, 640],
  ])
  return (
    <Camera
      shots={[
        { at: 0, x: 960, y: 540, zoom: 1 },
        { at: 30, x: 960, y: 540, zoom: 1 },
        // Never above the menu bar.
        { at: 110, x: 1200, y: 490, zoom: 1.12 },
      ]}
    >
      <div style={{ position: "relative", width: 1920, height: 1080, fontFamily: sans }}>
        {/* The menu bar, with OpenTraffic's icon. */}
        <div style={{ position: "absolute", left: -480, right: -480, top: 0, height: 48, background: "rgba(255,255,255,.72)", borderBottom: "1px solid rgba(15,23,42,.06)", display: "flex", alignItems: "center", justifyContent: "flex-end", gap: 34, padding: "0 516px", color: ink, fontSize: 20, fontWeight: 500 }}>
          <div style={{ position: "absolute", left: glyph.x + 480 - 26, top: 6, width: 52, height: 36, borderRadius: 8, background: `rgba(15,23,42,${0.1 * open})` }} />
          <Img src={staticFile("brand/menu-glyph.svg")} style={{ position: "absolute", left: glyph.x + 480 - 17, top: 13, width: 34, height: 22 }} />
          <span>Wed 9:41</span>
        </div>
        <div
          style={{
            position: "absolute",
            left: popover.left,
            top: popover.top,
            width: 720,
            opacity: open,
            transform: `translateY(${(1 - open) * -10}px)`,
            filter: "drop-shadow(0 18px 40px rgba(15,23,42,.18)) drop-shadow(0 2px 6px rgba(15,23,42,.10))",
          }}
        >
          <Img src={staticFile(`capture/${listAt(frame)}.png`)} style={{ position: "absolute", width: 720, opacity: 1 - live }} />
          <Img src={staticFile("capture/popover-live.png")} style={{ position: "absolute", width: 720, opacity: live }} />
        </div>
        <Cursor x={cursor.x} y={cursor.y} pressed={Math.max(press(frame, 24), press(frame, D + 74))} />
      </div>
    </Camera>
  )
}
