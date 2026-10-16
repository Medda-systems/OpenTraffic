import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion"
import { links } from "@/lib/site"
import { Reveal } from "./Reveal"

const questions = [
  {
    q: "Is OpenTraffic free?",
    a: "Yes. OpenTraffic costs nothing. Cloudflare Quick Tunnels and OpenTunnel need no account at all; Tailscale and ngrok use your own accounts with them.",
  },
  {
    q: "Do the people I share with need anything?",
    a: "Just a browser. They open the link; with live collaboration on, they see each other's cursors and can comment without signing up.",
  },
  {
    q: "Is it open source?",
    a: "Yes. The code is on GitHub under the MIT License, and issues and pull requests are welcome. The OpenTraffic name and logo are trademarks of Medda Systems AB.",
  },
  {
    q: "Does it work with Vite, Next.js, and other dev servers?",
    a: "Yes. Dev servers that reject unfamiliar hostnames get a one-click Host header fix, and apps that call an API on another local port work through the same share.",
  },
  {
    q: "Which way of sharing should I pick?",
    a: "Temporary URL for a quick look. OpenTunnel when you want the same link every time. Tailscale to keep it inside your team's network. ngrok to inspect and replay requests or add a password. Your own domain on Cloudflare for something permanent.",
  },
  {
    q: "Is OpenTraffic signed?",
    a: "Yes. Every release is signed by Medda Systems AB and notarized by Apple, so macOS opens it without warnings. Updates are also signed with Medda Systems' own key, and OpenTraffic checks that signature before installing them.",
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
            OpenTraffic by{" "}
            <a className="inline-flex items-baseline gap-1.5 text-foreground hover:underline" href={links.medda}>
              <img src="/brand/medda-icon.svg" alt="" className="size-3.5 self-center dark:invert" />
              Medda Systems
            </a>
          </span>
        </div>
        <nav className="flex flex-wrap gap-x-6 gap-y-2 md:ml-auto">
          <a className="hover:text-foreground" href="/docs">Docs</a>
          <a className="hover:text-foreground" href={links.source}>Source</a>
          <a className="hover:text-foreground" href="/docs/changelog">Changelog</a>
          <a className="hover:text-foreground" href={links.releases}>Releases</a>
          <a className="hover:text-foreground" href={links.homebrewTap}>Homebrew tap</a>
          <a className="hover:text-foreground" href="/#install">Install</a>
          <a className="hover:text-foreground" href={links.license}>MIT License</a>
        </nav>
      </div>
      <p className="mx-auto max-w-6xl px-6 pb-10 text-xs text-muted-foreground/80">
        Cloudflare, Tailscale, ngrok, OpenTunnel, and Anomaly are trademarks of their respective owners. OpenTraffic is an
        independent app and isn't affiliated with or endorsed by them.
      </p>
    </footer>
  )
}
