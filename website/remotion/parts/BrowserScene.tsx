import { interpolate, useCurrentFrame } from "remotion"
import type { Seat, Session } from "../session"
import { ink, muted, sans } from "../theme"
import { Camera, type Shot } from "./Camera"
import { SessionView } from "./SessionView"

// A real session on the shared page, recorded in two browsers at once (capture/record-session.mjs):
// Ava's screen, then Lea's while she picks an element and comments on it, then Ava's again.
const toolbar = 76
const pageWidth = 1920
export const browser = { width: pageWidth, height: 1084 + toolbar }

const seats: Record<Seat, { name: string; color: string }> = {
  ava: { name: "Ava", color: "#F38020" },
  lea: { name: "Lea", color: "#2F80ED" },
}

/** Where the scene starts in the recording, and when it switches seats (in scene frames). */
export function browserTimeline(session: Session) {
  const start = Math.max(0, session.marks.wander - 8)
  const at = (mark: string, offset = 0) => session.marks[mark] - start + offset
  return {
    start,
    length: session.frames - start,
    at,
    seatAt: (frame: number): Seat => (frame >= at("arm", -10) && frame < at("pinned", 10) ? "lea" : "ava"),
  }
}

const Chrome = ({ seat }: { seat: Seat }) => (
  <div style={{ height: toolbar, display: "flex", alignItems: "center", padding: "0 26px", borderBottom: "1px solid rgba(15,23,42,.08)", background: "#f6f6f7", fontFamily: sans }}>
    <div style={{ display: "flex", gap: 12, width: 260 }}>
      {["#ff5f57", "#febc2e", "#28c840"].map((c) => <span key={c} style={{ width: 18, height: 18, borderRadius: 99, background: c }} />)}
    </div>
    <div style={{ margin: "0 auto", display: "flex", alignItems: "center", gap: 12, background: "#fff", border: "1px solid rgba(15,23,42,.08)", borderRadius: 12, padding: "10px 26px", fontSize: 22, color: ink }}>
      <svg width="16" height="20" viewBox="0 0 16 20"><rect x="1" y="8" width="14" height="11" rx="2.5" fill={muted} /><path d="M4 8V5.5a4 4 0 0 1 8 0V8" stroke={muted} strokeWidth="2" fill="none" /></svg>
      orbit.wbfsgcylfq2x.opentunnel.xyz
    </div>
    {/* Whose screen this is. */}
    <div style={{ width: 260, display: "flex", justifyContent: "flex-end", alignItems: "center", gap: 10, fontSize: 21, color: ink, fontWeight: 500 }}>
      <span style={{ width: 30, height: 30, borderRadius: 99, background: seats[seat].color, color: "#fff", display: "grid", placeItems: "center", fontSize: 16, fontWeight: 700 }}>{seats[seat].name[0]}</span>
      {seats[seat].name}'s screen
    </div>
  </div>
)

export const BrowserScene = ({ session }: { session: Session }) => {
  const frame = useCurrentFrame()
  const { start, at, seatAt } = browserTimeline(session)
  const seat = seatAt(frame)
  // A short dip to white when the seat changes, so the cut reads as "another screen".
  const cuts = [at("arm", -10), at("pinned", 10)]
  const dip = Math.min(...cuts.map((c) => interpolate(Math.abs(frame - c), [0, 5], [0.55, 0], { extrapolateRight: "clamp" })))
  const fit = 1600 / browser.width
  const whole = { x: browser.width / 2, y: browser.height / 2, zoom: fit }
  const shots: Shot[] = [
    { at: 0, ...whole },
    // Sam points at the headline.
    { at: at("ping", -24), ...whole },
    { at: at("ping", -6), x: 760, y: 470, zoom: 1.05 },
    { at: at("ping", 26), x: 760, y: 470, zoom: 1.05 },
    { at: at("arm", -2), ...whole },
    // Lea picks, then writes.
    { at: at("compose", -16), ...whole },
    { at: at("compose", 6), x: 740, y: 700, zoom: 1.3 },
    { at: at("post", 2), x: 740, y: 700, zoom: 1.3 },
    { at: at("pinned", 18), ...whole },
    // The comment opens, then the agent's reply arrives.
    { at: at("open", 18), ...whole },
    { at: at("opened", 10), x: 720, y: 480, zoom: 1.35 },
  ]
  return (
    <Camera shots={shots}>
      <div style={{ width: browser.width, height: browser.height, borderRadius: 18, overflow: "hidden", background: "#fff", boxShadow: "0 1px 2px rgba(15,23,42,.06), 0 30px 70px rgba(15,23,42,.18)", position: "relative" }}>
        <Chrome seat={seat} />
        <SessionView session={session} seat={seat} frame={start + frame} width={pageWidth} />
        <div style={{ position: "absolute", inset: 0, background: "#fff", opacity: dip }} />
      </div>
    </Camera>
  )
}
