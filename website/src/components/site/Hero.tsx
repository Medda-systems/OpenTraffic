import { Download, Volume2, VolumeX } from "lucide-react"
import { motion } from "motion/react"
import { useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { links } from "@/lib/site"
import { CopyCommand } from "./CopyCommand"
import { useCalm } from "./Reveal"
import { ThemeToggle } from "./ThemeToggle"

export function Nav() {
  return (
    <header className="sticky top-0 z-40 border-b border-border/60 bg-background/80 backdrop-blur-md">
      <div className="mx-auto flex h-16 max-w-6xl items-center gap-6 px-6">
        <a href="#top" className="flex items-center gap-2.5">
          <img src="/brand/app-icon.png" alt="" className="size-8" />
          <span className="font-heading text-xl">OpenTraffic</span>
        </a>
        <nav className="ml-auto hidden items-center gap-7 text-sm font-medium text-foreground/80 md:flex">
          <a href="#features" className="hover:text-foreground">Features</a>
          <a href="#agents" className="hover:text-foreground">Coding agents</a>
          <a href="#install" className="hover:text-foreground">Install</a>
          <a href={links.releases} className="hover:text-foreground">Releases</a>
        </nav>
        <div className="ml-auto flex items-center gap-3 md:ml-0">
          <Button asChild size="sm" className="rounded-full px-4">
            <a href="#install">Download</a>
          </Button>
          <ThemeToggle />
        </div>
      </div>
    </header>
  )
}

export function Hero({ version }: { version: string | null }) {
  const calm = useCalm()
  return (
    <section id="top" className="relative overflow-hidden">
      <div className="bg-dots pointer-events-none absolute inset-0 [mask-image:linear-gradient(to_bottom,black,transparent_85%)]" />
      <div className="relative mx-auto max-w-6xl px-6 pt-7 pb-16 md:pt-8">
        <motion.div
          initial={calm ? false : { opacity: 0, y: 16 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
          className="mx-auto max-w-3xl text-center"
        >
          <h1 className="text-5xl leading-[1.05] text-balance md:text-7xl">
            Share localhost. <br className="hidden sm:block" />Collaborate live.
          </h1>
          <p className="mx-auto mt-5 max-w-2xl text-lg text-pretty text-muted-foreground md:text-xl">
            OpenTraffic lives in your Mac's menu bar. Put the dev server you're running on a public URL in one click,
            then watch your team point, comment, and follow along — and let your coding agent fix what they find.
          </p>
          <div className="mx-auto mt-6 flex max-w-xl flex-col items-stretch gap-3 sm:flex-row sm:items-center">
            <CopyCommand command={links.installCommand} className="flex-1" />
            <Button asChild size="lg" variant="outline" className="h-12 rounded-full px-5">
              <a href={links.dmg}>
                <Download className="size-4" /> Download
              </a>
            </Button>
          </div>
          <div className="mt-3 flex flex-wrap items-center justify-center gap-x-3 gap-y-2 text-xs text-muted-foreground">
            <p>macOS 14 or later · Apple silicon and Intel · Free, MIT licensed</p>
            {version && (
              <a href={links.latestRelease} className="inline-flex items-center gap-1.5 rounded-full border bg-background/70 px-2.5 py-1 font-medium hover:text-foreground">
                <span className="size-1.5 rounded-full bg-green-500" />
                v{version} →
              </a>
            )}
          </div>
        </motion.div>

        <motion.div
          initial={calm ? false : { opacity: 0, y: 28 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, delay: 0.15, ease: [0.22, 1, 0.36, 1] }}
          className="mx-auto mt-8 max-w-5xl"
        >
          <PromoVideo />
          <p className="mt-4 text-center text-sm text-muted-foreground">
            Prefer it slower?{" "}
            <a href="/media/demo.mp4" className="underline underline-offset-4 hover:text-foreground">
              Watch the walkthrough with captions
            </a>
          </p>
        </motion.div>
      </div>
    </section>
  )
}

/** The promo: plays muted (as browsers require), with a button to start it over with sound. */
function PromoVideo() {
  const video = useRef<HTMLVideoElement>(null)
  const [muted, setMuted] = useState(true)
  const toggle = () => {
    const v = video.current
    if (!v) return
    if (v.muted) v.currentTime = 0
    v.muted = !v.muted
    setMuted(v.muted)
    void v.play()
  }
  return (
    <div className="relative overflow-hidden rounded-2xl border bg-black shadow-[0_1px_2px_rgba(15,23,42,.06),0_24px_64px_rgba(15,23,42,.18)]">
      <video
        ref={video}
        className="block aspect-video w-full"
        src="/media/promo.mp4"
        poster="/media/promo-poster.jpg"
        autoPlay
        muted
        loop
        playsInline
        aria-label="OpenTraffic in 46 seconds: it finds your dev servers, shares one in a click, checks every hop, and lets your team point, pick elements, and comment while your coding agent replies"
      />
      <button
        type="button"
        onClick={toggle}
        className="absolute right-3 bottom-3 inline-flex items-center gap-1.5 rounded-full bg-white/90 px-2.5 py-1.5 text-xs font-medium text-black shadow-sm backdrop-blur transition hover:bg-white sm:right-4 sm:bottom-4 sm:gap-2 sm:px-3.5 sm:py-2 sm:text-sm"
      >
        {muted ? <VolumeX className="size-4" /> : <Volume2 className="size-4" />}
        {muted ? "Sound on" : "Sound off"}
      </button>
    </div>
  )
}
