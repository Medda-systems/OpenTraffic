import { Bell, Lock, Network, ShieldCheck, SquareTerminal, Webhook } from "lucide-react"
import { useEffect, useRef, type ReactNode } from "react"
import { media } from "@/lib/site"
import { Reveal, useCalm } from "./Reveal"

const providers = [
  { name: "Cloudflare", logo: "/brand/provider-cloudflare.svg", what: "A temporary trycloudflare.com URL with no account, or a lasting hostname on your own domain." },
  // OpenTunnel is made by Anomaly, whose mark stands for it here as in the app.
  { name: "OpenTunnel", logo: "/brand/provider-opentunnel.svg", what: "A lasting opentunnel.xyz address, encrypted until it reaches your Mac. No account." },
  { name: "Tailscale", logo: "/brand/provider-tailscale.svg", what: "Private to the devices on your tailnet, or public through Funnel." },
  { name: "ngrok", logo: "/brand/provider-ngrok.svg", what: "Your ngrok domain, with a request inspector, replay, and password or sign-in protection." },
]

export function Providers() {
  return (
    <section className="border-y bg-muted/30">
      <div className="mx-auto max-w-6xl px-6 py-16">
        <Reveal>
          <p className="text-center text-sm font-medium tracking-wide text-muted-foreground uppercase">One menu, four ways to publish</p>
        </Reveal>
        <div className="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {providers.map((provider, i) => (
            <Reveal key={provider.name} delay={i * 0.06}>
              <div className="h-full rounded-2xl border bg-card p-5">
                <div className="flex h-8 items-center gap-2.5">
                  {/* ngrok's mark is a wordmark in the middle of a square, so it needs more height. */}
                  <img src={provider.logo} alt="" className={provider.name === "ngrok" ? "-my-3 h-12 w-auto dark:invert" : provider.name === "OpenTunnel" ? "h-7 w-auto dark:invert" : "h-6 w-auto dark:invert"} />
                  {/* ngrok's mark already spells its name. */}
                  {provider.name === "ngrok" ? <span className="sr-only">ngrok</span> : <span className="font-semibold">{provider.name}</span>}
                </div>
                <p className="mt-3 text-sm text-muted-foreground">{provider.what}</p>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  )
}

/** A short silent clip of the real app that plays only while it's on screen (a still for reduced motion). */
function Loop({ name, label, still = false }: { name: string; label: string; still?: boolean }) {
  const calm = useCalm()
  const video = useRef<HTMLVideoElement>(null)
  useEffect(() => {
    const v = video.current
    if (!v || calm) return
    const observer = new IntersectionObserver(([entry]) => (entry.isIntersecting ? void v.play().catch(() => {}) : v.pause()), { threshold: 0.35 })
    observer.observe(v)
    return () => observer.disconnect()
  }, [calm])
  const frame = "overflow-hidden rounded-2xl border bg-black shadow-[0_1px_2px_rgba(15,23,42,.06),0_24px_64px_rgba(15,23,42,.16)]"
  if (still) {
    return (
      <div className={frame}>
        <img className="block aspect-video w-full" src={media(`loops/${name}.jpg`)} alt={label} loading="lazy" />
      </div>
    )
  }
  return (
    <div className={frame}>
      <video
        ref={video}
        className="block aspect-video w-full"
        src={media(`loops/${name}.mp4`)}
        poster={media(`loops/${name}.jpg`)}
        muted
        loop
        playsInline
        preload="none"
        aria-label={label}
      />
    </div>
  )
}

const story: { loop: string; title: string; text: string; label: string; still?: boolean }[] = [
  {
    loop: "share",
    title: "One click from localhost to a link",
    text: "Every web server on your Mac shows up in the menu bar, with its page title and how long it's been up. Share one, and the link is on your clipboard.",
    label: "The OpenTraffic menu listing local dev servers, one shared with a click",
  },
  {
    loop: "collaborate",
    title: "Collaborate on the real thing",
    text: "Everyone who opens the link sees each other's cursors and can follow you as you browse. They point, draw, and pin comments to an element or an area, with a picture of it.",
    label: "Visitors' cursors on a shared page, one of them pinning a comment to a button",
  },
  {
    loop: "suggest",
    title: "Suggest the exact change",
    text: "Change the text, colours, size, or spacing right on the page, with a palette and sliders. The comment carries the exact change, old to new, so nobody has to guess.",
    label: "A visitor editing a button's text and dragging its size while the page updates live",
  },
  {
    loop: "phone",
    title: "See it on their phone",
    text: "Everyone's device shows up. View the page at anyone's exact size and comment right inside it, or lead with your phone open and everyone following sees it too.",
    label: "The page shown on a visitor's phone, which turns, then everyone following the host's phone",
  },
  {
    loop: "agent",
    title: "Your coding agent fixes it",
    text: "Claude Code, Codex, Cursor, opencode, and other agents get the comment with the exact change, fix it, and reply. Each fix is its own commit on a branch, and only people you trust can start a run.",
    label: "A comment being fixed by a coding agent, and the visitor told it's done",
  },
]

export function Story() {
  return (
    <section id="features" className="scroll-mt-16">
      <div className="mx-auto max-w-6xl px-6 py-24 md:py-32">
        <Reveal className="mx-auto max-w-2xl text-center">
          <h2 className="text-4xl text-balance md:text-5xl">From “it works on my machine” to “have a look”.</h2>
          <p className="mt-4 text-lg text-muted-foreground">No config files, no copying ports around.</p>
        </Reveal>
        <div className="mt-20 space-y-24 md:mt-28 md:space-y-36">
          {story.map((row, i) => (
            <div key={row.loop} className="grid items-center gap-8 md:grid-cols-12 md:gap-14">
              <Reveal className={`min-w-0 md:col-span-5 ${i % 2 ? "md:order-2" : ""}`}>
                <p className="font-mono text-xs text-muted-foreground">0{i + 1}</p>
                <h3 className="mt-3 text-3xl leading-tight text-balance md:text-4xl">{row.title}</h3>
                <p className="mt-4 text-lg leading-relaxed text-muted-foreground">{row.text}</p>
              </Reveal>
              <Reveal delay={0.1} className={`min-w-0 md:col-span-7 ${i % 2 ? "md:order-1" : ""}`}>
                <Loop name={row.loop} label={row.label} still={row.still} />
              </Reveal>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}

function Item({ icon, title, children }: { icon: ReactNode; title: string; children: ReactNode }) {
  return (
    <div className="border-t pt-6">
      <div className="flex items-center gap-2.5">
        <span className="text-muted-foreground">{icon}</span>
        <h3 className="font-sans text-base font-semibold tracking-tight">{title}</h3>
      </div>
      <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{children}</p>
    </div>
  )
}

export function More() {
  const icon = "size-4"
  return (
    <section className="border-t bg-muted/30">
      <div className="mx-auto max-w-6xl px-6 py-24">
        <Reveal>
          <h2 className="text-3xl md:text-4xl">And everything else you'd want</h2>
        </Reveal>
        <Reveal delay={0.1}>
          <div className="mt-12 grid gap-x-10 gap-y-10 sm:grid-cols-2 lg:grid-cols-3">
            <Item icon={<SquareTerminal className={icon} />} title="A complete command line">
              <span className="font-mono text-[0.92em] text-foreground">opentraffic share 5173 --collab</span>, then read and answer comments, follow logs, or protect it. Everything the app does, with JSON for scripts.
            </Item>
            <Item icon={<ShieldCheck className={icon} />} title="Protection and roles">
              A password or Google and GitHub sign-in on ngrok, email sign-in on your own domain, and per person: trusted, can comment, or view only.
            </Item>
            <Item icon={<Network className={icon} />} title="Apps made of several servers">
              Your frontend calls an API on another port? Those calls go through the same share, so the whole app works for visitors.
            </Item>
            <Item icon={<Bell className={icon} />} title="Stays out of your way">
              Auto-stop timers, projects that start together, notifications when someone joins, and global shortcuts.
            </Item>
            <Item icon={<Webhook className={icon} />} title="Hooks into your tools">
              opentraffic:// links for Shortcuts and Raycast, a local REST API, and signed webhooks that turn feedback into tickets.
            </Item>
            <Item icon={<Lock className={icon} />} title="Private by default">
              No account, no analytics, no telemetry. Credentials stay in your Keychain, and releases are signed and notarized.
            </Item>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

/** A session in the terminal, as the opentraffic command prints it. */
function TerminalSession() {
  const prompt = <span className="text-white/40">$ </span>
  return (
    <div className="overflow-hidden rounded-2xl border border-white/10 bg-[#0b0b0c] shadow-[0_24px_64px_rgba(0,0,0,.35)]">
      <div className="flex items-center gap-1.5 border-b border-white/10 px-4 py-3">
        <span className="size-2.5 rounded-full bg-white/15" />
        <span className="size-2.5 rounded-full bg-white/15" />
        <span className="size-2.5 rounded-full bg-white/15" />
        <span className="ml-3 font-mono text-xs text-white/40">~/orbit</span>
      </div>
      <pre className="overflow-x-auto p-5 font-mono text-[12.5px] leading-6 text-white/85 md:text-[13px]">
        {prompt}opentraffic share 5173 --collab{"\n"}
        <b className="text-white">Orbit</b> is live at <span className="text-cyan-300">https://orbit-launch.trycloudflare.com</span>{"\n"}
        <span className="text-white/45">  Temporary URL · anyone with the link · live collaboration</span>{"\n\n"}
        {prompt}opentraffic comments orbit{"\n"}
        <span className="text-white/45">3f2a91c0</span>  Lea on “Start free trial” at / · 2 min ago{"\n"}
        {"  "}Can we make this button bigger? It's easy to miss.{"\n\n"}
        {prompt}opentraffic reply orbit 3f2a91c0 "Made it larger, reload to see it."{"\n"}
        Replied to Lea's comment.{"\n"}
        {prompt}opentraffic resolve orbit 3f2a91c0{"\n"}
        Resolved Lea's comment.
      </pre>
    </div>
  )
}

export function Terminal() {
  return (
    <section id="cli" className="scroll-mt-16 border-t">
      <div className="mx-auto grid max-w-6xl items-center gap-12 px-6 py-24 md:grid-cols-12 md:gap-14 md:py-32">
        <Reveal className="min-w-0 md:col-span-5">
          <p className="font-mono text-xs text-muted-foreground">opentraffic</p>
          <h2 className="mt-3 text-4xl text-balance md:text-5xl">At home in the terminal.</h2>
          <p className="mt-4 text-lg leading-relaxed text-muted-foreground">
            The <span className="font-mono text-[0.92em] text-foreground">opentraffic</span> command comes with the app and does everything its windows do: share, read and answer feedback, protect, follow logs, and stream events. Every command speaks JSON.
          </p>
          <a href="/docs/cli" className="mt-6 inline-block text-sm font-medium underline underline-offset-4 hover:text-muted-foreground">
            The command line guide →
          </a>
        </Reveal>
        <Reveal delay={0.1} className="min-w-0 md:col-span-7">
          <TerminalSession />
        </Reveal>
      </div>
    </section>
  )
}

