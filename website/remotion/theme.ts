import { loadFont } from "@remotion/fonts"
import { staticFile } from "remotion"

// The landing page's look (medda.se): neutral shadcn palette, Geist, DM Serif Text headlines.
export const ink = "#0b1220"
export const muted = "#6b7280"
export const line = "rgba(15, 23, 42, 0.08)"
export const card = "#ffffff"
export const live = "#16a34a"
export const sans = "'Geist', system-ui, sans-serif"
export const serif = "'DM Serif Text', Georgia, serif"
export const mono = "ui-monospace, 'SF Mono', Menlo, monospace"

/** Collaborators in the demo session. */
export const people = {
  you: { name: "You", color: "#0b1220" },
  lea: { name: "Lea", color: "#e11d48" },
  sam: { name: "Sam", color: "#2563eb" },
}

export const fontsReady = Promise.all([
  loadFont({ family: "Geist", url: staticFile("fonts/geist.woff2"), weight: "100 900" }),
  loadFont({ family: "DM Serif Text", url: staticFile("fonts/dm-serif-text.woff2") }),
])

export const shadow = "0 1px 2px rgba(15,23,42,.06), 0 12px 32px rgba(15,23,42,.10), 0 40px 80px rgba(15,23,42,.08)"
