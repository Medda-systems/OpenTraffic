import { interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion"
import { card, ink, line, live, mono, muted, people, sans, serif, shadow } from "../theme"
import { Cursor } from "./Cursor"
import { path, press } from "./MenuBarScene"

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const

/** Text typed out from `start`, a few characters per frame. */
const typed = (frame: number, start: number, text: string, speed = 1.6) =>
  text.slice(0, Math.max(0, Math.floor((frame - start) * speed)))

const Avatar = ({ name, color, size = 34 }: { name: string; color: string; size?: number }) => (
  <div style={{ width: size, height: size, borderRadius: 99, background: color, color: "#fff", display: "grid", placeItems: "center", fontSize: size * 0.42, fontWeight: 700, border: "2px solid #fff" }}>{name[0]}</div>
)

/** The shared site, with OpenTraffic's overlay and, later, a coding agent fixing a comment. */
export const CollabScene = () => {
  const frame = useCurrentFrame()
  const { fps } = useVideoConfig()
  const enter = spring({ frame, fps, config: { damping: 18 } })
  const split = spring({ frame: frame - 210, fps, config: { damping: 20, stiffness: 90 } })
  const pinned = frame >= 112
  const pinIn = spring({ frame: frame - 112, fps, config: { damping: 12 } })
  const comment = typed(frame, 116, "Can we make this button bigger? It's easy to miss.")
  const bigger = spring({ frame: frame - 292, fps, config: { damping: 12 } })
  const replied = frame >= 310
  const resolved = frame >= 330
  const ripple = interpolate(frame, [158, 192], [0, 1], clamp)

  // Positions inside the browser window (1500 × 860).
  const lea = path(frame, [[0, 1180, 640], [60, 860, 600], [86, 1300, 800], [94, 1300, 800], [110, 300, 515], [160, 560, 580], [210, 640, 620]])
  const sam = path(frame, [[0, 300, 760], [80, 520, 420], [150, 432, 288], [175, 432, 288], [230, 620, 680]])

  return (
    <div style={{ position: "absolute", inset: 0, fontFamily: sans, color: ink }}>
      {/* Browser window: scales left to make room for the agent. */}
      <div style={{ position: "absolute", left: 210, top: 110, width: 1500, height: 860, transformOrigin: "0 50%", transform: `translate(${-170 * split}px, ${(1 - enter) * 30}px) scale(${1 - 0.3 * split})`, opacity: enter, background: card, borderRadius: 18, boxShadow: shadow, border: `1px solid ${line}`, overflow: "hidden" }}>
        <div style={{ height: 58, display: "flex", alignItems: "center", gap: 10, padding: "0 20px", borderBottom: `1px solid ${line}`, background: "#f8fafc" }}>
          {["#ff5f57", "#febc2e", "#28c840"].map((c) => <div key={c} style={{ width: 14, height: 14, borderRadius: 99, background: c }} />)}
          <div style={{ marginLeft: 120, flex: 1, maxWidth: 760, height: 36, borderRadius: 10, background: "#eef2f7", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 17, color: muted }}>
            🔒 orbit.k3v9qx2mz7ab.opentunnel.xyz/pricing
          </div>
        </div>
        {/* The developer's site. */}
        <div style={{ padding: "64px 90px", position: "relative", height: 802, background: "linear-gradient(180deg,#faf5ff, #ffffff 60%)" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 34, fontSize: 19, color: muted }}>
            <b style={{ color: "#6d28d9", fontSize: 26 }}>◆ Orbit</b>
            <span>Product</span><span>Pricing</span><span>Docs</span>
          </div>
          <div style={{ fontFamily: serif, fontSize: 84, lineHeight: 1.05, marginTop: 70, width: 900, position: "relative" }}>
            Plan launches with your whole team.
            {/* Sam points here. */}
            {ripple > 0 && ripple < 1 ? (
              <div style={{ position: "absolute", left: 340, top: 70, width: 30 + 160 * ripple, height: 30 + 160 * ripple, transform: "translate(-50%,-50%)", borderRadius: 999, border: `4px solid ${people.sam.color}`, opacity: 1 - ripple }} />
            ) : null}
          </div>
          <div style={{ fontSize: 24, color: muted, marginTop: 24, width: 760 }}>Roadmaps, launch checklists, and a calendar everyone actually reads.</div>
          <div style={{ marginTop: 40, display: "inline-block", position: "relative" }}>
            <div style={{ background: "#6d28d9", color: "#fff", borderRadius: 12, fontWeight: 600, fontSize: 19 + 9 * bigger, padding: `${12 + 8 * bigger}px ${24 + 16 * bigger}px`, boxShadow: "0 8px 24px rgba(109,40,217,.3)" }}>
              Start free trial
            </div>
            {/* Lea's comment, pinned to the button. */}
            {pinned ? (
              <>
                <div style={{ position: "absolute", right: -14, top: -14, transform: `scale(${pinIn})`, width: 34, height: 34, borderRadius: "50% 50% 50% 0", background: resolved ? live : people.lea.color, color: "#fff", display: "grid", placeItems: "center", fontSize: 16, fontWeight: 700, boxShadow: shadow }}>
                  {resolved ? "✓" : "1"}
                </div>
                <div style={{ position: "absolute", left: "calc(100% + 34px)", top: -40, width: 470, background: card, borderRadius: 16, boxShadow: shadow, border: `1px solid ${line}`, padding: 18, opacity: pinIn, transform: `translateY(${(1 - pinIn) * 10}px)` }}>
                  <div style={{ display: "flex", gap: 10, alignItems: "center" }}>
                    <Avatar {...people.lea} size={30} />
                    <b style={{ fontSize: 18 }}>Lea</b>
                    <span style={{ fontSize: 15, color: muted }}>on “Start free trial”</span>
                    <div style={{ flex: 1 }} />
                    {resolved ? <span style={{ fontSize: 14, fontWeight: 600, color: live }}>Resolved</span> : null}
                  </div>
                  <div style={{ fontSize: 19, marginTop: 10, lineHeight: 1.35, minHeight: 52 }}>{comment}</div>
                  {replied ? (
                    <div style={{ marginTop: 12, paddingTop: 12, borderTop: `1px solid ${line}`, display: "flex", gap: 10 }}>
                      <div style={{ width: 30, height: 30, borderRadius: 8, background: "#d97757", color: "#fff", display: "grid", placeItems: "center", fontSize: 15, fontWeight: 700 }}>✳</div>
                      <div>
                        <div style={{ fontSize: 15, color: muted }}><b style={{ color: ink }}>Claude Code</b> · via MCP</div>
                        <div style={{ fontSize: 18, marginTop: 2 }}>{typed(frame, 310, "Made it larger in a1b2c3 — reload to see it.", 2.2)}</div>
                      </div>
                    </div>
                  ) : null}
                </div>
              </>
            ) : null}
          </div>
        </div>
        {/* OpenTraffic's presence pill. */}
        <div style={{ position: "absolute", right: 28, bottom: 28, display: "flex", alignItems: "center", gap: 14, background: ink, color: "#fff", borderRadius: 999, padding: "10px 12px 10px 18px", boxShadow: shadow }}>
          <div style={{ display: "flex" }}>
            {[people.you, people.lea, people.sam].map((p, i) => <div key={p.name} style={{ marginLeft: i ? -10 : 0 }}><Avatar {...p} /></div>)}
          </div>
          <span style={{ fontSize: 17 }}>3 here</span>
          <div style={{ background: "rgba(255,255,255,.14)", borderRadius: 999, padding: "8px 14px", fontSize: 16, transform: `scale(${1 - press(frame, 92) * 0.1})` }}>💬 Comment</div>
          <div style={{ background: "rgba(255,255,255,.14)", borderRadius: 999, padding: "8px 14px", fontSize: 16 }}>👆 Point</div>
        </div>
        <Cursor x={lea.x} y={lea.y} color={people.lea.color} label="Lea" pressed={Math.max(press(frame, 92), press(frame, 110))} />
        <Cursor x={sam.x} y={sam.y} color={people.sam.color} label="Sam" pressed={press(frame, 158)} />
      </div>

      {/* The coding agent, picking the comment up over MCP. */}
      <div style={{ position: "absolute", right: 56, top: 150, width: 740, height: 780, background: "#0d1117", borderRadius: 18, boxShadow: shadow, padding: "26px 30px", fontFamily: mono, fontSize: 19, lineHeight: 1.7, color: "#c9d1d9", opacity: split, transform: `translateX(${(1 - split) * 120}px)` }}>
        <div style={{ fontFamily: sans, fontSize: 17, color: "#8b949e", marginBottom: 18 }}>Claude Code · ~/code/orbit</div>
        {frame >= 228 ? <div><span style={{ color: "#d97757" }}>⏺</span> opentraffic · <b style={{ color: "#fff" }}>wait_for_feedback</b></div> : null}
        {frame >= 244 ? (
          <div style={{ color: "#8b949e", paddingLeft: 26 }}>
            comment.created · <span style={{ color: "#f0abfc" }}>Lea</span> on /pricing<br />“{typed(frame, 246, "Can we make this button bigger?", 3)}”
          </div>
        ) : null}
        {frame >= 262 ? <div style={{ marginTop: 14 }}><span style={{ color: "#d97757" }}>⏺</span> Update <b style={{ color: "#fff" }}>src/components/Hero.tsx</b></div> : null}
        {frame >= 270 ? <div style={{ paddingLeft: 26, color: "#f85149" }}>- &lt;Button size="sm"&gt;</div> : null}
        {frame >= 276 ? <div style={{ paddingLeft: 26, color: "#3fb950" }}>+ &lt;Button size="lg"&gt;</div> : null}
        {frame >= 300 ? <div style={{ marginTop: 14 }}><span style={{ color: "#d97757" }}>⏺</span> opentraffic · <b style={{ color: "#fff" }}>reply_to_comment</b></div> : null}
        {frame >= 322 ? <div><span style={{ color: "#d97757" }}>⏺</span> opentraffic · <b style={{ color: "#fff" }}>resolve_comment</b></div> : null}
        {frame >= 336 ? <div style={{ marginTop: 18, color: "#3fb950" }}>✓ Lea's feedback is fixed and resolved.</div> : null}
      </div>
    </div>
  )
}
