import { Img } from "remotion"
import { type Seat, type Session, sessionFrame } from "../session"

const Arrow = ({ pressed }: { pressed: boolean }) => (
  <svg width="26" height="32" viewBox="0 0 28 34" style={{ transform: `scale(${pressed ? 0.88 : 1})`, transformOrigin: "2px 2px", filter: "drop-shadow(0 1.5px 2px rgba(0,0,0,.35))" }}>
    <path d="M2 2 L2 27 L8.5 21 L13 31 L17.5 29 L13 19.5 L22 19.5 Z" fill="#000" stroke="#fff" strokeWidth="2" strokeLinejoin="round" />
  </svg>
)

// macOS's crosshair, which the page asks for in comment mode.
const Crosshair = () => (
  <svg width="30" height="30" viewBox="-15 -15 30 30" style={{ position: "absolute", left: -15, top: -15, filter: "drop-shadow(0 0 1px rgba(255,255,255,.9))" }}>
    <path d="M0 -12 V12 M-12 0 H12" stroke="#000" strokeWidth="1.6" />
  </svg>
)

/**
 * One seat's screen at a recorded frame, `width` pixels wide, with that person's own pointer drawn
 * where it was (a screenshot doesn't include it).
 */
export const SessionView = ({ session, seat, frame, width, pointer = true }: { session: Session; seat: Seat; frame: number; width: number; pointer?: boolean }) => {
  const f = Math.max(0, Math.min(session.frames - 1, Math.round(frame)))
  const k = width / session.viewport.width
  const height = session.viewport.height * k
  const [x, y, crosshair, pressed] = session.pointers[seat][f]
  return (
    <div style={{ position: "relative", width, height, overflow: "hidden" }}>
      <Img src={sessionFrame(seat, f)} style={{ display: "block", width, height }} />
      {pointer ? (
        <div style={{ position: "absolute", left: x * k - (crosshair ? 0 : 2), top: y * k - (crosshair ? 0 : 2), transform: `scale(${Math.max(1, k * 0.75)})`, transformOrigin: "0 0" }}>
          {crosshair ? <Crosshair /> : <Arrow pressed={!!pressed} />}
        </div>
      ) : null}
    </div>
  )
}
