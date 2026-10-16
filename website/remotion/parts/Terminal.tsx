import { useCurrentFrame } from "remotion"
import { mono, sans } from "../theme"

/**
 * The opentraffic command-line tool's real commands and what each prints: `share` and `stop` print
 * nothing, `copy` prints the public URL once OpenTraffic has copied it (Resources/opentraffic).
 */
export type TerminalLine = { at: number; command: string; output?: string | string[] }

export const cliSession: TerminalLine[] = [
  { at: 0, command: "opentraffic share 5175 --via opentunnel --collab" },
  { at: 62, command: "opentraffic copy Orbit", output: "https://orbit.wbfsgcylfq2x.opentunnel.xyz" },
]

/** Frames it takes to type a line (two characters a frame) plus a beat for "return". */
export const typedAt = (line: { at: number; command: string }) => line.at + Math.ceil(line.command.length / 2) + 4

export const Terminal = ({ width, dark = true, fontSize = 28, lines = cliSession, title = "Terminal — orbit" }: { width: number; dark?: boolean; fontSize?: number; lines?: TerminalLine[]; title?: string }) => {
  const frame = useCurrentFrame()
  const fg = dark ? "#f4f4f5" : "#18181b"
  const dim = dark ? "#71717a" : "#a1a1aa"
  const caret = Math.floor(frame / 8) % 2 === 0
  let active = -1
  lines.forEach((l, i) => { if (frame >= l.at) active = i })
  return (
    <div style={{ width, borderRadius: 18, overflow: "hidden", background: dark ? "#111113" : "#fbfbfb", border: `1px solid ${dark ? "rgba(255,255,255,.12)" : "rgba(0,0,0,.08)"}`, boxShadow: dark ? "0 40px 90px rgba(0,0,0,.6)" : "0 30px 70px rgba(15,23,42,.16)" }}>
      <div style={{ height: 50, display: "flex", alignItems: "center", gap: 10, padding: "0 20px", borderBottom: `1px solid ${dark ? "rgba(255,255,255,.08)" : "rgba(0,0,0,.06)"}`, position: "relative" }}>
        {["#ff5f57", "#febc2e", "#28c840"].map((c) => <span key={c} style={{ width: 14, height: 14, borderRadius: 99, background: dark ? "#3f3f46" : c }} />)}
        <span style={{ position: "absolute", left: 0, right: 0, textAlign: "center", fontFamily: sans, fontSize: 17, color: dim }}>{title}</span>
      </div>
      <div style={{ padding: "26px 30px", fontFamily: mono, fontSize, lineHeight: 1.6, color: fg, minHeight: fontSize * 6 }}>
        {lines.map((line, i) => {
          if (frame < line.at) return null
          const typed = line.command.slice(0, Math.max(0, (frame - line.at) * 2))
          const done = frame >= typedAt(line)
          return (
            <div key={line.command}>
              <div>
                <span style={{ color: dim }}>$ </span>
                {typed}
                {i === active && !done && caret ? <span style={{ background: fg, color: "transparent" }}>_</span> : null}
              </div>
              {done && line.output && frame >= typedAt(line) + 6
                ? [line.output].flat().map((out, k) => frame >= typedAt(line) + 6 + k * 3 ? <div key={k} style={{ color: fg, whiteSpace: "pre" }}>{out}</div> : null)
                : null}
            </div>
          )
        })}
        {active === lines.length - 1 && frame >= typedAt(lines[active]) + 10 ? (
          <div>
            <span style={{ color: dim }}>$ </span>
            {caret ? <span style={{ background: fg, color: "transparent" }}>_</span> : null}
          </div>
        ) : null}
      </div>
    </div>
  )
}
