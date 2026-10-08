import { ink } from "../theme"

/** A macOS-style arrow, optionally with a collaborator's name tag. */
export const Cursor = ({ x, y, color = ink, label, pressed = 0 }: { x: number; y: number; color?: string; label?: string; pressed?: number }) => (
  <div style={{ position: "absolute", left: x, top: y, transform: `scale(${1 - pressed * 0.15})`, transformOrigin: "0 0", zIndex: 50 }}>
    <svg width="28" height="34" viewBox="0 0 28 34" style={{ filter: "drop-shadow(0 2px 3px rgba(0,0,0,.25))" }}>
      <path d="M2 2 L2 27 L8.5 21 L13 31 L17.5 29 L13 19.5 L22 19.5 Z" fill={color} stroke="#fff" strokeWidth="2.2" strokeLinejoin="round" />
    </svg>
    {label ? (
      <div style={{ position: "absolute", left: 22, top: 26, background: color, color: "#fff", fontSize: 17, fontWeight: 600, padding: "4px 10px", borderRadius: 999, whiteSpace: "nowrap" }}>
        {label}
      </div>
    ) : null}
  </div>
)
