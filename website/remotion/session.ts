import { staticFile } from "remotion"

/** A collaboration session recorded by capture/record-session.mjs, one frame per video frame. */
export type Session = {
  fps: number
  frames: number
  viewport: { width: number; height: number; scale: number }
  /** Frame numbers of the moments in the script: wander, point, ping, arm, pick, compose, post, pinned, open, opened, reply, end. */
  marks: Record<string, number>
  /** Per seat and frame: the seat's own pointer [x, y, crosshair, pressed], in page pixels. */
  pointers: Record<Seat, [number, number, number, number][]>
}

export type Seat = "ava" | "lea"

export const loadSession = async (): Promise<Session> => (await fetch(staticFile("capture/session/session.json"))).json()

export const sessionFrame = (seat: Seat, frame: number) => staticFile(`capture/session/${seat}/${String(frame).padStart(4, "0")}.jpg`)
