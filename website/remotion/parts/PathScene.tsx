import { interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion"
import { card, ink, line, live, muted, sans, serif, shadow } from "../theme"

const stages = [
  { title: "localhost:5173", detail: "Vite answered HTTP 200", icon: "⌘" },
  { title: "This Mac", detail: "OpenTraffic's proxy", icon: "◐" },
  { title: "OpenTunnel", detail: "Connected, end-to-end TLS", icon: "◎" },
  { title: "Public URL", detail: "orbit.…opentunnel.xyz", icon: "↗" },
]

/** The detail view's connection path: each stage lights up as its health check passes. */
export const PathScene = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const enter = spring({ frame, fps, config: { damping: 18 } })

  return (
    <div style={{ position: "absolute", inset: 0, display: "grid", placeItems: "center", fontFamily: sans, color: ink }}>
      <div style={{ width: 1500, background: card, borderRadius: 28, boxShadow: shadow, border: `1px solid ${line}`, padding: "56px 64px", opacity: enter, transform: `translateY(${(1 - enter) * 24}px)` }}>
        <div style={{ fontFamily: serif, fontSize: 52, lineHeight: 1.1 }}>From your Mac to the world, checked at every step.</div>
        <div style={{ fontSize: 22, color: muted, marginTop: 14 }}>OpenTraffic watches the whole path and tells you which part needs fixing, and how.</div>
        <div style={{ display: "flex", alignItems: "center", marginTop: 56 }}>
          {stages.map((stage, i) => {
            const at = 18 + i * 16
            const lit = spring({ frame: frame - at, fps, config: { damping: 14 } })
            const link = interpolate(frame, [at + 4, at + 16], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })
            return (
              <div key={stage.title} style={{ display: "flex", alignItems: "center", flex: i < stages.length - 1 ? 1 : "none" }}>
                <div style={{ width: 230, textAlign: "center" }}>
                  <div style={{ width: 92, height: 92, margin: "0 auto", borderRadius: 999, display: "grid", placeItems: "center", fontSize: 38, background: lit > 0.5 ? "rgba(22,163,74,.10)" : "rgba(15,23,42,.04)", border: `2px solid ${lit > 0.5 ? live : line}`, transform: `scale(${0.9 + 0.1 * lit})`, color: lit > 0.5 ? live : muted }}>
                    {stage.icon}
                  </div>
                  <div style={{ fontSize: 23, fontWeight: 600, marginTop: 18 }}>{stage.title}</div>
                  <div style={{ fontSize: 17, color: muted, marginTop: 6, opacity: lit }}>{stage.detail}</div>
                </div>
                {i < stages.length - 1 ? (
                  <div style={{ flex: 1, height: 4, borderRadius: 4, background: line, position: "relative", marginTop: -60, overflow: "hidden" }}>
                    <div style={{ position: "absolute", inset: 0, width: `${link * 100}%`, background: live }} />
                    {/* Traffic flowing once the link is up. */}
                    {link >= 1 ? <div style={{ position: "absolute", top: -3, width: 10, height: 10, borderRadius: 99, background: "#86efac", left: `${((frame * 3 + i * 40) % 110) - 5}%` }} /> : null}
                  </div>
                ) : null}
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}
