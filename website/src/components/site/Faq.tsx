import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion"
import { links } from "@/lib/site"
import { Reveal } from "./Reveal"

const questions = [
  {
    q: "Is OpenTraffic free?",
    a: "Yes. OpenTraffic is free and MIT licensed. Cloudflare Quick Tunnels and OpenTunnel need no account at all; Tailscale and ngrok use your own accounts with them.",
  },
  {
    q: "Do the people I share with need anything?",
    a: "Just a browser. They open the link; with live collaboration on, they see each other's cursors and can comment without signing up.",
  },
  {
    q: "Which way of sharing should I pick?",
    a: "Temporary URL for a quick look. OpenTunnel when you want the same link every time. Tailscale to keep it inside your team's network. ngrok to inspect and replay requests or add a password. Your own domain on Cloudflare for something permanent.",
  },
  {
    q: "Why does macOS ask me to approve the first launch?",
    a: "Releases aren't notarized by Apple yet. The one-line installer avoids the prompt; for the disk image or Homebrew, approve it once in System Settings → Privacy & Security → Open Anyway. Notarized releases are on the way.",
  },
  {
    q: "What does OpenTraffic send anywhere?",
    a: "Nothing about you. There's no analytics or telemetry. It talks to the tunnel providers you choose, checks GitHub once a day for updates (you can turn that off), and keeps credentials in your Keychain.",
  },
]

export function Faq() {
  return (
    <section className="border-t">
      <div className="mx-auto max-w-3xl px-6 py-24">
        <Reveal>
          <h2 className="text-center text-4xl md:text-5xl">Questions</h2>
        </Reveal>
        <Reveal delay={0.1}>
          <Accordion type="single" collapsible className="mt-10">
            {questions.map(({ q, a }) => (
              <AccordionItem key={q} value={q}>
                <AccordionTrigger className="font-sans text-left text-base font-medium">{q}</AccordionTrigger>
                <AccordionContent className="text-base leading-relaxed text-muted-foreground">{a}</AccordionContent>
              </AccordionItem>
            ))}
          </Accordion>
        </Reveal>
      </div>
    </section>
  )
}

export function Footer() {
  return (
    <footer className="border-t">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-6 py-10 text-sm text-muted-foreground md:flex-row md:items-center">
        <div className="flex items-center gap-2.5">
          <img src="/brand/app-icon.png" alt="" className="size-6" />
          <span>
            OpenTraffic by <a className="text-foreground hover:underline" href={links.medda}>Medda Systems</a>
          </span>
        </div>
        <nav className="flex flex-wrap gap-x-6 gap-y-2 md:ml-auto">
          <a className="hover:text-foreground" href={links.releases}>Releases</a>
          <a className="hover:text-foreground" href={links.homebrewTap}>Homebrew tap</a>
          <a className="hover:text-foreground" href="#install">Install</a>
          <span>MIT License</span>
        </nav>
      </div>
      <p className="mx-auto max-w-6xl px-6 pb-10 text-xs text-muted-foreground/80">
        Cloudflare, Tailscale, ngrok, OpenTunnel, and Anomaly are trademarks of their respective owners. OpenTraffic is an
        independent app and isn't affiliated with or endorsed by them.
      </p>
    </footer>
  )
}
