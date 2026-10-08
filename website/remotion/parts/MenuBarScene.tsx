import { Easing, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion"
import { card, ink, line, live, muted, sans, shadow } from "../theme"
import { Cursor } from "./Cursor"

const ease = Easing.bezier(0.22, 1, 0.36, 1)

/** Moves between points over frame ranges: [[frame, x, y], …]. */
export const path = (frame: number, points: [number, number, number][]) => {
  const frames = points.map((p) => p[0])
  return {
    x: interpolate(frame, frames, points.map((p) => p[1]), { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: ease }),
    y: interpolate(frame, frames, points.map((p) => p[2]), { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: ease }),
  }
}

/** A short press, for clicks at `at`. */
export const press = (frame: number, at: number) => interpolate(frame, [at - 3, at, at + 5], [0, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })

const MenuBar = () => (
  <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 44, display: "flex", alignItems: "center", padding: "0 22px", gap: 26, fontSize: 19, color: ink, background: "rgba(255,255,255,.72)", backdropFilter: "blur(20px)", borderBottom: `1px solid ${line}` }}>
    <b>Finder</b>
    {["File", "Edit", "View", "Go", "Window"].map((m) => <span key={m}>{m}</span>)}
    <div style={{ flex: 1 }} />
    <Img src={staticFile("brand/menu-glyph.svg")} style={{ height: 18, opacity: 0.9 }} />
    <span style={{ fontVariantNumeric: "tabular-nums" }}>Thu 14:32</span>
  </div>
)

const Row = ({ title, detail, children, highlight = 0 }: { title: string; detail: string; children?: React.ReactNode; highlight?: number }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 16, padding: "14px 16px", borderRadius: 14, background: `rgba(15,23,42,${0.035 * highlight})` }}>
    <div style={{ width: 44, height: 44, borderRadius: 11, background: "linear-gradient(135deg,#8b5cf6,#6366f1)", display: "grid", placeItems: "center", color: "#fff", fontWeight: 700, fontSize: 20 }}>O</div>
    <div style={{ flex: 1 }}>
      <div style={{ fontSize: 21, fontWeight: 600 }}>{title}</div>
      <div style={{ fontSize: 16, color: muted, marginTop: 2 }}>{detail}</div>
    </div>
    {children}
  </div>
)

const providers: { name: string; logo: string | null; note: string }[] = [
  { name: "Temporary URL", logo: "provider-cloudflare.svg", note: "Cloudflare" },
  { name: "Lasting address", logo: null, note: "OpenTunnel" },
  { name: "Private on your tailnet", logo: "provider-tailscale.svg", note: "Tailscale" },
  { name: "Public with ngrok", logo: "provider-ngrok.svg", note: "ngrok" },
]

export const MenuBarScene = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const open = spring({ frame: frame - 12, fps, config: { damping: 18, stiffness: 140 } })
  const menu = spring({ frame: frame - 80, fps, config: { damping: 20, stiffness: 180 } })
  const menuGone = frame > 116
  const isLive = frame >= 118
  const liveIn = spring({ frame: frame - 118, fps, config: { damping: 16 } })
  const toast = interpolate(frame, [126, 136, 168, 178], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" })
  const cursor = path(frame, [[0, 1100, 620], [40, 1650, 34], [55, 1652, 30], [70, 1700, 247], [100, 1600, 336]])
  // The camera zooms in on the menu bar corner, so the popover fills the frame.
  const zoom = interpolate(frame, [0, 30], [1.25, 1.5], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: ease })

  return (
    <div style={{ position: "absolute", inset: 0, fontFamily: sans, color: ink }}>
     <div style={{ position: "absolute", inset: 0, transformOrigin: "0 0", transform: `translate(${960 - zoom * 1400}px, 0) scale(${zoom})` }}>
      <MenuBar />
      {/* The popover under the menu bar symbol. */}
      <div style={{ position: "absolute", top: 56, right: 120, width: 640, background: card, borderRadius: 22, boxShadow: shadow, border: `1px solid ${line}`, padding: 20, transformOrigin: "88% 0", transform: `scale(${0.92 + 0.08 * open})`, opacity: open }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12, padding: "4px 6px 14px" }}>
          <Img src={staticFile("brand/menu-glyph.svg")} style={{ height: 22 }} />
          <b style={{ fontSize: 21 }}>OpenTraffic</b>
          <div style={{ flex: 1 }} />
          {isLive ? <span style={{ fontSize: 16, color: live, fontWeight: 600, opacity: liveIn }}>● 1 live</span> : null}
        </div>
        {isLive ? (
          <div style={{ opacity: liveIn, transform: `translateY(${(1 - liveIn) * 8}px)`, margin: "0 0 12px", padding: 16, borderRadius: 16, border: `1px solid ${line}`, background: "rgba(22,163,74,.05)" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, fontSize: 19, fontWeight: 600 }}>
              <span style={{ width: 10, height: 10, borderRadius: 99, background: live, boxShadow: `0 0 0 ${4 + 3 * Math.sin(frame / 6)}px rgba(22,163,74,.18)` }} />
              Orbit
              <span style={{ fontSize: 15, color: muted, fontWeight: 500 }}>· OpenTunnel</span>
            </div>
            <div style={{ fontSize: 17, color: ink, marginTop: 8, fontFamily: "ui-monospace, Menlo, monospace" }}>https://orbit.k3v9qx2mz7ab.opentunnel.xyz</div>
          </div>
        ) : null}
        <div style={{ fontSize: 14, fontWeight: 700, letterSpacing: 0.6, color: muted, padding: "6px 6px 8px" }}>READY TO SHARE</div>
        {/* Shared servers leave the list. */}
        {!isLive ? (
          <Row title="Orbit" detail="Vite · localhost:5173 · up 12 min" highlight={frame > 60 ? 1 : 0}>
            <div style={{ background: ink, color: "#fff", borderRadius: 999, padding: "9px 18px", fontSize: 17, fontWeight: 600, transform: `scale(${1 - press(frame, 75) * 0.06})` }}>Share ▾</div>
          </Row>
        ) : null}
        <Row title="API" detail="Node · localhost:3001 · up 12 min">
          <div style={{ border: `1px solid ${line}`, borderRadius: 999, padding: "9px 18px", fontSize: 17, fontWeight: 600 }}>Share ▾</div>
        </Row>
      </div>

      {/* The Share menu. */}
      {!menuGone ? (
        <div style={{ position: "absolute", top: 262, right: 150, width: 380, background: card, borderRadius: 16, boxShadow: shadow, border: `1px solid ${line}`, padding: 8, opacity: menu, transform: `translateY(${(1 - menu) * -8}px)` }}>
          {providers.map((p, i) => {
            const active = i === 1 && frame >= 96
            return (
              <div key={p.name} style={{ display: "flex", alignItems: "center", gap: 14, padding: "12px 14px", borderRadius: 10, background: active ? "#2563eb" : "transparent", color: active ? "#fff" : ink }}>
                <div style={{ width: 30, display: "grid", placeItems: "center" }}>
                  {p.logo ? (
                    <Img src={staticFile(`brand/${p.logo}`)} style={{ height: 20, filter: active ? "invert(1)" : "none" }} />
                  ) : (
                    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="9" /><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18" /></svg>
                  )}
                </div>
                <div style={{ fontSize: 18, fontWeight: 500 }}>{p.name}</div>
                <div style={{ flex: 1 }} />
                <div style={{ fontSize: 14, opacity: 0.7 }}>{p.note}</div>
              </div>
            )
          })}
        </div>
      ) : null}

      <Cursor x={cursor.x} y={cursor.y} pressed={Math.max(press(frame, 52), press(frame, 75), press(frame, 112))} />
     </div>

      {/* "Link copied" toast. */}
      <div style={{ position: "absolute", left: "50%", top: 760, transform: `translate(-50%, ${(1 - toast) * 20}px)`, opacity: toast, background: ink, color: "#fff", padding: "16px 26px", borderRadius: 999, fontSize: 21, fontWeight: 500, boxShadow: shadow, display: "flex", gap: 12, alignItems: "center" }}>
        <span style={{ color: "#4ade80" }}>✓</span> Link copied — anyone with it can open your local site
      </div>

    </div>
  )
}
