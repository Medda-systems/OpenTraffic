import { interpolate, useCurrentFrame } from "remotion"
import type { Seat, Session } from "../session"
import { ink, muted, sans } from "../theme"
import { Camera, type Shot } from "./Camera"
import { SessionView } from "./SessionView"

// A real session on the shared page, recorded in two browsers at once (capture/record-session.mjs):
// Ava's screen (she's the host) and Lea's, played as a run of slices of the recording, each from one
// seat, some a little faster than real time.
const toolbar = 76
const pageWidth = 1920
export const browser = { width: pageWidth, height: 1084 + toolbar }

const seats: Record<Seat, { name: string; color: string }> = {
  ava: { name: "Ava", color: "#F38020" },
  lea: { name: "Lea", color: "#2F80ED" },
}

/** A slice of the recording: from one seat, between two recorded frames, at a speed. */
type Slice = { seat: Seat; from: number; to: number; speed?: number }

const slices = (m: Record<string, number>): Slice[] => [
  // Everyone's cursors; Sam points at the headline.
  { seat: "ava", from: m.wander - 8, to: m.ping + 34 },
  // Lea picks the trial button, writes, and suggests the change: new words, a bigger button.
  { seat: "lea", from: m.arm - 10, to: m.pick + 70 },
  { seat: "lea", from: m.compose - 40, to: m.style + 20 },
  { seat: "lea", from: m.style + 20, to: m.post + 12, speed: 1.6 },
  // Ava opens it; the coding agent is already at work.
  { seat: "ava", from: m.pinned - 6, to: m.opened + 80 },
  // Sam draws around the headline (as Ava sees it); Lea comments on the space between two cards.
  { seat: "ava", from: m.draw + 16, to: m.draw + 92 },
  { seat: "lea", from: m.area + 16, to: m.areaPosted + 12, speed: 1.3 },
  // The fixes land: Lea's page has them, she's told, and takes a look.
  { seat: "lea", from: m.updated + 16, to: m.look + 80 },
  // Ava looks at the page on Mia's phone, and Mia turns it.
  { seat: "ava", from: m.people - 4, to: m.phoneClosed - 20, speed: 1.3 },
  // Ava leads with her phone open; Lea, following, sees it and scrolls with her.
  { seat: "ava", from: m.lead - 6, to: m.leadPhone + 50 },
  { seat: "lea", from: m.leadPhone + 30, to: m.end, speed: 1.2 },
]

/** The slices laid out in scene frames, and a way to find a recorded moment in them. */
export function browserTimeline(session: Session) {
  let start = 0
  const laid = slices(session.marks).map((s) => {
    const length = Math.round((s.to - s.from) / (s.speed ?? 1))
    const slice = { ...s, start, length }
    start += length
    return slice
  })
  const sliceAt = (frame: number) => laid.find((s) => frame < s.start + s.length) ?? laid[laid.length - 1]
  /** The scene frame where the recording reaches `mark` (+ offset, in recorded frames), in the first slice that has it. */
  const at = (mark: string, offset = 0, seat?: Seat) => {
    const rec = session.marks[mark] + offset
    const s = laid.find((l) => (!seat || l.seat === seat) && rec >= l.from && rec <= l.to) ?? laid.find((l) => l.from >= rec) ?? laid[laid.length - 1]
    return s.start + Math.round((Math.max(rec, s.from) - s.from) / (s.speed ?? 1))
  }
  return {
    slices: laid,
    length: start,
    at,
    /** The seat and recorded frame shown at a scene frame. */
    recAt: (frame: number) => {
      const s = sliceAt(frame)
      return { seat: s.seat, rec: s.from + (frame - s.start) * (s.speed ?? 1), slice: s }
    },
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
  const timeline = browserTimeline(session)
  const { at, recAt, slices: laid } = timeline
  const { seat, rec } = recAt(frame)
  // A short dip to white at each cut, so it reads as "another moment" (or "another screen").
  const cuts = laid.slice(1).map((s) => s.start)
  const dip = Math.min(...cuts.map((c) => interpolate(Math.abs(frame - c), [0, 5], [0.55, 0], { extrapolateRight: "clamp" })))
  const fit = 1600 / browser.width
  const whole = { x: browser.width / 2, y: browser.height / 2, zoom: fit }
  // Page pixels (1440 wide) to scene pixels.
  const k = pageWidth / session.viewport.width
  const on = (x: number, y: number, zoom: number) => ({ x: x * k, y: y * k + toolbar, zoom })
  const shots: Shot[] = [
    { at: 0, ...whole },
    // Sam points at the headline.
    { at: at("ping", -24), ...whole },
    { at: at("ping", -6), ...on(560, 230, 1.05) },
    { at: at("ping", 30), ...on(560, 230, 1.05) },
    { at: at("arm", -4, "lea"), ...whole },
    // Lea writes, then suggests the change.
    { at: at("compose", -16, "lea"), ...whole },
    { at: at("compose", 6, "lea"), ...on(560, 300, 1.3) },
    { at: at("post", 4, "lea"), ...on(560, 300, 1.3) },
    // Ava opens it.
    { at: at("pinned", 4, "ava"), ...whole },
    { at: at("opened", 2, "ava"), ...on(560, 300, 1.3) },
    { at: at("opened", 70, "ava"), ...on(560, 300, 1.3) },
    // Sam's circle, Lea's area.
    { at: at("draw", 18, "ava"), ...on(560, 220, 1.15) },
    { at: at("draw", 90, "ava"), ...on(560, 220, 1.15) },
    { at: at("area", 18, "lea"), ...on(520, 420, 1.2) },
    { at: at("areaPosted", 10, "lea"), ...on(520, 420, 1.2) },
    // The fix, the notice, the look.
    { at: at("updated", 18, "lea"), ...whole },
    // Mia's phone, then the lead.
    { at: at("people", -2, "ava"), ...whole },
  ]
  // In time order, one per frame (interpolation needs strictly increasing frames).
  const ordered = [...shots].sort((a, b) => a.at - b.at).filter((s, i, all) => i === 0 || s.at > all[i - 1].at)
  return (
    <Camera shots={ordered}>
      <div style={{ width: browser.width, height: browser.height, borderRadius: 18, overflow: "hidden", background: "#fff", boxShadow: "0 1px 2px rgba(15,23,42,.06), 0 30px 70px rgba(15,23,42,.18)", position: "relative" }}>
        <Chrome seat={seat} />
        <SessionView session={session} seat={seat} frame={rec} width={pageWidth} />
        <div style={{ position: "absolute", inset: 0, background: "#fff", opacity: dip }} />
      </div>
    </Camera>
  )
}
