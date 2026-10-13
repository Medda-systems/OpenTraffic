import { Download, ExternalLink, ShieldCheck } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { homebrewCommands, links } from "@/lib/site"
import { CopyCommand } from "./CopyCommand"
import { Reveal } from "./Reveal"

const agents = [
  {
    name: "Agent skill · Claude Code, Codex, opencode",
    command: "curl -fsSL https://opentraffic.dev/skill | sh",
  },
  {
    name: "Claude Code",
    command: 'claude mcp add --scope user opentraffic --env OPENTRAFFIC_CLIENT="Claude Code" -- /Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp',
  },
  {
    name: "Codex",
    config: `[mcp_servers.opentraffic]
command = "/Applications/OpenTraffic.app/Contents/MacOS/opentraffic-mcp"
env = { OPENTRAFFIC_CLIENT = "Codex" }
tool_timeout_sec = 330`,
  },
]

export function Agents() {
  return (
    <section id="agents" className="scroll-mt-16 border-y bg-muted/30">
      <div className="mx-auto grid max-w-6xl gap-12 px-6 py-24 lg:grid-cols-2 lg:items-center">
        <Reveal>
          <Badge variant="outline" className="rounded-full">Skill · MCP</Badge>
          <h2 className="mt-4 text-4xl md:text-5xl">Feedback your coding agent can act on.</h2>
          <p className="mt-4 text-lg text-muted-foreground">
            Claude Code, Codex, Cursor, opencode, and any MCP client can share your dev server, wait for comments, fix
            what people point at, reply in the thread, and resolve it — while you watch it happen on the page.
          </p>
          <ul className="mt-6 space-y-2 text-sm text-muted-foreground">
            <li><span className="font-mono text-foreground">share</span> — publish a port and get the link</li>
            <li><span className="font-mono text-foreground">wait_for_feedback</span> — block until someone comments</li>
            <li><span className="font-mono text-foreground">reply_to_comment</span> · <span className="font-mono text-foreground">resolve_comment</span> — close the loop</li>
            <li><span className="font-mono text-foreground">get_screenshot</span> · <span className="font-mono text-foreground">get_errors</span> — see what they saw</li>
          </ul>
        </Reveal>
        <Reveal delay={0.1}>
          <div className="space-y-4">
            {agents.map((agent) => (
              <div key={agent.name} className="rounded-2xl border bg-card p-5">
                <div className="text-sm font-semibold">{agent.name}</div>
                {agent.command ? (
                  <CopyCommand command={agent.command} className="mt-3 text-xs" wrap />
                ) : (
                  <pre className="mt-3 rounded-xl bg-muted/60 p-4 font-mono text-xs leading-relaxed break-all whitespace-pre-wrap">{agent.config}</pre>
                )}
              </div>
            ))}
            <p className="text-xs text-muted-foreground">
              The skill teaches your agent the <span className="font-mono">opentraffic</span> command (<a className="underline underline-offset-4" href="/docs/agent-skill">more</a>); the MCP server adds tools like waiting for feedback. Run <span className="font-mono">opentraffic setup</span> once first.
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

function Note({ children }: { children: React.ReactNode }) {
  return <p className="mt-4 text-sm leading-relaxed text-muted-foreground">{children}</p>
}

export function Install({ version }: { version: string | null }) {
  return (
    <section id="install" className="scroll-mt-16">
      <div className="mx-auto max-w-3xl px-6 py-24">
        <Reveal className="text-center">
          <h2 className="text-4xl md:text-5xl">Install OpenTraffic</h2>
          <p className="mt-4 text-lg text-muted-foreground">
            Free for macOS 14 or later, on Apple silicon and Intel{version ? ` · version ${version}` : ""}. It updates itself after that.
          </p>
        </Reveal>
        <Reveal delay={0.1}>
          <Tabs defaultValue="terminal" className="mt-10">
            <TabsList className="mx-auto grid w-full max-w-md grid-cols-3">
              <TabsTrigger value="terminal">Terminal</TabsTrigger>
              <TabsTrigger value="download">Download</TabsTrigger>
              <TabsTrigger value="homebrew">Homebrew</TabsTrigger>
            </TabsList>
            <div className="mt-6 rounded-2xl border bg-card p-6 md:p-8">
              <TabsContent value="terminal" className="mt-0">
                <div className="flex items-center gap-2">
                  <h3 className="font-sans text-lg font-semibold">One command</h3>
                  <Badge variant="secondary" className="rounded-full">Recommended</Badge>
                </div>
                <CopyCommand command={links.installCommand} className="mt-4" />
                <Note>
                  Downloads the latest release, checks its checksum and code signature, quits a running copy, and puts
                  OpenTraffic in Applications. <a className="underline underline-offset-4" href={links.installScript}>Read the script</a>.
                </Note>
              </TabsContent>
              <TabsContent value="download" className="mt-0">
                <h3 className="font-sans text-lg font-semibold">Disk image</h3>
                <div className="mt-4 flex flex-wrap gap-3">
                  <Button asChild className="rounded-full">
                    <a href={links.dmg}><Download className="size-4" /> Download OpenTraffic.dmg</a>
                  </Button>
                  <Button asChild variant="outline" className="rounded-full">
                    <a href={links.releases}>All versions and checksums <ExternalLink className="size-4" /></a>
                  </Button>
                </div>
                <Note>
                  Open it and drag OpenTraffic into Applications. It's signed by Medda Systems and notarized by Apple,
                  so it opens without any warning.
                </Note>
              </TabsContent>
              <TabsContent value="homebrew" className="mt-0">
                <h3 className="font-sans text-lg font-semibold">Homebrew</h3>
                <div className="mt-4 space-y-2">
                  {homebrewCommands.map((command) => <CopyCommand key={command} command={command} />)}
                </div>
                <Note>
                  Homebrew asks you to trust casks from taps outside its own collection; the second line trusts just
                  this one.
                </Note>
              </TabsContent>
            </div>
          </Tabs>
        </Reveal>
        <Reveal delay={0.15}>
          <div className="mt-6 flex items-start gap-3 rounded-2xl border border-dashed p-5 text-sm text-muted-foreground">
            <ShieldCheck className="mt-0.5 size-5 shrink-0 text-foreground" />
            <p>
              Cloudflare shares need <a className="underline underline-offset-4" href={links.cloudflared}>cloudflared</a>{" "}
              (<span className="font-mono">brew install cloudflared</span>). Tailscale, ngrok, and OpenTunnel are optional —
              OpenTraffic tells you what's missing when you pick them.
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  )
}
