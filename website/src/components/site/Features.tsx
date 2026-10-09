import { Activity, Bell, Lock, MessageSquareText, MousePointer2, Network, RefreshCw, Sparkles, Terminal } from "lucide-react"
import type { ReactNode } from "react"
import { Card, CardContent } from "@/components/ui/card"
import { Reveal } from "./Reveal"

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

function Feature({ icon, title, children, delay }: { icon: ReactNode; title: string; children: ReactNode; delay: number }) {
  return (
    <Reveal delay={delay}>
      <Card className="h-full rounded-2xl shadow-none">
        <CardContent className="p-6">
          <div className="grid size-10 place-items-center rounded-xl border bg-muted/50">{icon}</div>
          <h3 className="mt-5 font-sans text-lg font-semibold tracking-tight">{title}</h3>
          <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{children}</p>
        </CardContent>
      </Card>
    </Reveal>
  )
}

export function Features() {
  const icon = "size-5"
  return (
    <section id="features" className="scroll-mt-16">
      <div className="mx-auto max-w-6xl px-6 py-24">
        <Reveal className="max-w-2xl">
          <h2 className="text-4xl md:text-5xl">Everything between “it works on my machine” and “have a look”.</h2>
          <p className="mt-4 text-lg text-muted-foreground">
            No config files, no copying ports around. OpenTraffic finds what's running and keeps it shareable.
          </p>
        </Reveal>
        <div className="mt-14 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          <Feature delay={0} icon={<Sparkles className={icon} />} title="Ready to Share">
            Every web server running on your Mac shows up in the menu bar with its page title and uptime. One click shares it and copies the link.
          </Feature>
          <Feature delay={0.05} icon={<MousePointer2 className={icon} />} title="Live cursors and follow mode">
            Everyone who opens a collaborative link sees each other's cursors and which page they're on. Lead, and the whole session follows you.
          </Feature>
          <Feature delay={0.1} icon={<MessageSquareText className={icon} />} title="Comments pinned to the page">
            Visitors pin feedback to any element, with a picture of it, their browser, and the errors they ran into. Reply and resolve from the app.
          </Feature>
          <Feature delay={0} icon={<Activity className={icon} />} title="Health you can see">
            The connection path checks every hop — your server, this Mac, the tunnel, the public URL — and offers the fix, like the Host header for Vite.
          </Feature>
          <Feature delay={0.05} icon={<Network className={icon} />} title="Apps made of several servers">
            Your frontend calls an API on another port? The localhost bridge routes those calls through the same share, so the whole app works for visitors.
          </Feature>
          <Feature delay={0.1} icon={<Lock className={icon} />} title="Private by default">
            No account, no analytics, no telemetry. Credentials stay in your Keychain, and an ngrok share can ask for a password or a Google or GitHub sign-in.
          </Feature>
          <Feature delay={0} icon={<Bell className={icon} />} title="Stays out of your way">
            Notifications when a link is ready or someone joins, auto-stop timers, projects that start together, and global shortcuts.
          </Feature>
          <Feature delay={0.05} icon={<RefreshCw className={icon} />} title="Updates itself">
            New versions arrive in the background, signed by Medda Systems and verified before they're installed.
          </Feature>
          <Feature delay={0.1} icon={<Terminal className={icon} />} title="At home in the terminal">
            <span className="font-mono text-[0.92em] text-foreground">opentraffic share 3000</span> from any shell, plus opentraffic:// links for Shortcuts and Raycast, a local REST API, and signed webhooks.
          </Feature>
        </div>
      </div>
    </section>
  )
}
