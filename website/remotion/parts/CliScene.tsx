import { Img, Sequence, staticFile, useCurrentFrame } from "remotion"
import { GIT } from "../git"
import { cliSession, Terminal, type TerminalLine, typedAt } from "./Terminal"

const START = 12

/** The command-line tool next to the menu bar popover, which goes live once `share` has run. */
export const CliScene = () => {
  const frame = useCurrentFrame()
  const live = frame >= START + typedAt(cliSession[0]) + 20
  return (
    <div style={{ position: "absolute", inset: 0 }}>
      <div style={{ position: "absolute", left: 120, top: 250 }}>
        <Sequence from={START} layout="none">
          <Terminal width={960} dark={false} fontSize={26} />
        </Sequence>
      </div>
      <Img
        src={staticFile(`capture/${live ? "popover-live" : "popover-before"}.png`)}
        style={{ position: "absolute", left: 1150, top: 230, width: 640, filter: "drop-shadow(0 18px 40px rgba(15,23,42,.18)) drop-shadow(0 2px 6px rgba(15,23,42,.10))" }}
      />
    </div>
  )
}

const gitLines: TerminalLine[] = [
  { at: 0, command: "git branch --show-current", output: GIT.branch },
  { at: 30, command: "git log --oneline -2", output: GIT.commits },
]

/** The project's real history after the session: the share's branch, a commit per fixed comment. */
export const GitScene = () => (
  <div style={{ position: "absolute", inset: 0, display: "grid", placeItems: "center" }}>
    <Sequence from={10} layout="none">
      <Terminal width={1200} dark={false} fontSize={28} lines={gitLines} title="Terminal — orbit" />
    </Sequence>
  </div>
)
