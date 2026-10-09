import { Img, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion"
import { ink, line, mono, muted, sans, serif, shadow } from "../theme"
import { GitHubMark } from "./GitHubMark"

export const EndCard = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const icon = spring({ frame, fps, config: { damping: 14 } })
  const text = spring({ frame: frame - 8, fps, config: { damping: 18 } })
  const source = spring({ frame: frame - 24, fps, config: { damping: 16 } })
  return (
    <div style={{ position: "absolute", inset: 0, display: "grid", placeItems: "center", fontFamily: sans, color: ink, textAlign: "center" }}>
      <div>
        <Img src={staticFile("brand/app-icon.png")} style={{ width: 190, transform: `scale(${0.8 + 0.2 * icon})`, opacity: icon }} />
        <div style={{ opacity: text, transform: `translateY(${(1 - text) * 16}px)` }}>
          <div style={{ fontFamily: serif, fontSize: 96, marginTop: 18 }}>OpenTraffic</div>
          <div style={{ fontSize: 30, color: muted, marginTop: 8 }}>Share localhost. Collaborate live.</div>
          <div style={{ marginTop: 44, display: "inline-flex", alignItems: "center", gap: 14, background: "#fff", border: `1px solid ${line}`, boxShadow: shadow, borderRadius: 999, padding: "16px 30px", fontFamily: mono, fontSize: 22 }}>
            <span style={{ color: muted }}>$</span> curl -fsSL opentraffic.dev/install | sh
          </div>
          <div style={{ fontSize: 22, color: muted, marginTop: 26 }}>Free for macOS 14+ · opentraffic.dev</div>
        </div>
        <div style={{ opacity: source, transform: `translateY(${(1 - source) * 16}px)`, marginTop: 30, display: "flex", alignItems: "center", justifyContent: "center", gap: 12, fontSize: 26, fontWeight: 600 }}>
          <GitHubMark size={30} color={ink} />
          Open source on GitHub
        </div>
      </div>
    </div>
  )
}
