import { Download, Volume2, VolumeX } from "lucide-react"
import { motion } from "motion/react"
import { useEffect, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { links, media, starCount } from "@/lib/site"
import { CopyCommand } from "./CopyCommand"
import { GitHubMark } from "./GitHubMark"
import { useCalm } from "./Reveal"
import { ThemeToggle } from "./ThemeToggle"

export function Nav({ docs = false }: { docs?: boolean }) {
  return (
    <header className="sticky top-0 z-40 border-b border-border/60 bg-background/80 backdrop-blur-md">
      <div className="mx-auto flex h-16 max-w-6xl items-center gap-3 px-4 sm:gap-6 sm:px-6">
        <a href="/#top" className="flex shrink-0 items-center gap-2 sm:gap-2.5">
          <img src="/brand/app-icon.png" alt="" className="size-11 shrink-0" />
          <span className="font-heading text-lg sm:text-xl">OpenTraffic</span>
        </a>
        <nav className="ml-auto hidden items-center gap-7 text-sm font-medium text-foreground/80 lg:flex">
          <a href="/#features" className="hover:text-foreground">Features</a>
          <a href="/#cli" className="hover:text-foreground">CLI</a>
          <a href="/#agents" className="hover:text-foreground">Coding agents</a>
          <a href="/#install" className="hover:text-foreground">Install</a>
          <a href="/docs" aria-current={docs ? "page" : undefined} className={docs ? "text-foreground underline underline-offset-8" : "hover:text-foreground"}>Docs</a>
          <a href="/docs/changelog" className="hover:text-foreground">Changelog</a>
        </nav>
        <div className="ml-auto flex items-center gap-2 sm:gap-3 lg:ml-0">
          <a href="/docs" aria-current={docs ? "page" : undefined} className="text-sm font-medium lg:hidden">Docs</a>
          <Button asChild size="sm" className="hidden rounded-full px-4 sm:inline-flex">
            <a href="/#install">Download</a>
          </Button>
          <StarButton />
          <ThemeToggle />
        </div>
      </div>
    </header>
  )
}

/** "Star" on GitHub, with the count once GitHub's API answers. */
function StarButton() {
  const [stars, setStars] = useState<number | null>(null)
  useEffect(() => {
    starCount().then(setStars)
  }, [])
  return (
    <a
      href={links.source}
      aria-label={!stars ? "OpenTraffic on GitHub" : `Star OpenTraffic on GitHub (${stars} stars)`}
      className="inline-flex h-8 items-center gap-1.5 rounded-full border px-3 text-sm font-medium text-foreground/80 hover:bg-muted hover:text-foreground"
    >
      <GitHubMark className="size-4" />
      <span className="hidden sm:inline">Star</span>
      {!!stars && <span className="tabular-nums text-muted-foreground">{stars.toLocaleString("en")}</span>}
    </a>
  )
}

export function Hero({ version }: { version: string | null }) {
  const calm = useCalm()
  return (
    <section className="relative overflow-hidden">
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
            Put your dev server on a public URL in one click. Your team points, comments, and suggests the fix, and
            your coding agent makes it.
          </p>
          <div className="mx-auto mt-6 flex max-w-xl flex-col items-stretch gap-3 sm:flex-row sm:items-center">
            <CopyCommand command={links.installCommand} className="flex-1" />
            <Button asChild size="lg" variant="outline" className="h-12 rounded-full px-5">
              <a href={links.dmg}>
                <Download className="size-4" /> Download
              </a>
            </Button>
          </div>
          <p className="mt-4 text-sm text-muted-foreground">
            For macOS 14 or later · Free and{" "}
            <a href={links.source} className="underline underline-offset-4 hover:text-foreground">open source</a>
            {version && (
              <>
                {" · "}
                <a href="/docs/changelog" className="underline underline-offset-4 hover:text-foreground">v{version}</a>
              </>
            )}
          </p>
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
            <a href={media("demo.mp4")} className="underline underline-offset-4 hover:text-foreground">
              Watch the walkthrough with captions
            </a>
          </p>
        </motion.div>
      </div>
    </section>
  )
}

/** A hairline along the bottom of the video: how far it's got, and where to jump to (click, drag, or arrow keys). */
function Scrubber({ video }: { video: React.RefObject<HTMLVideoElement | null> }) {
  const bar = useRef<HTMLDivElement>(null)
  const [progress, setProgress] = useState(0)
  const [duration, setDuration] = useState(0)
  useEffect(() => {
    let frame = 0
    const tick = () => {
      const v = video.current
      if (v && v.duration) {
        setProgress(v.currentTime / v.duration)
        setDuration(v.duration)
      }
      frame = requestAnimationFrame(tick)
    }
    frame = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frame)
  }, [video])
  const seek = (clientX: number) => {
    const v = video.current
    const r = bar.current?.getBoundingClientRect()
    if (!v || !r || !v.duration) return
    v.currentTime = Math.min(1, Math.max(0, (clientX - r.left) / r.width)) * v.duration
  }
  const step = (seconds: number) => {
    const v = video.current
    if (v && v.duration) v.currentTime = Math.min(v.duration, Math.max(0, v.currentTime + seconds))
  }
  const clock = (t: number) => `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, "0")}`
  return (
    <div
      ref={bar}
      role="slider"
      tabIndex={0}
      aria-label="Video position"
      aria-valuemin={0}
      aria-valuemax={Math.round(duration)}
      aria-valuenow={Math.round(progress * duration)}
      aria-valuetext={`${clock(progress * duration)} of ${clock(duration)}`}
      className="group absolute inset-x-0 bottom-0 flex h-4 cursor-pointer touch-none items-end outline-none"
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId)
        seek(e.clientX)
      }}
      onPointerMove={(e) => {
        if (e.currentTarget.hasPointerCapture(e.pointerId)) seek(e.clientX)
      }}
      onKeyDown={(e) => {
        if (e.key === "ArrowRight") step(5)
        else if (e.key === "ArrowLeft") step(-5)
        else return
        e.preventDefault()
      }}
    >
      {/* Inverts what's behind it, so it shows on the video's dark and light scenes alike. */}
      <div className="relative h-[2px] w-full bg-white/20 mix-blend-difference transition-[height] duration-200 group-hover:h-1 group-focus-visible:h-1">
        <div className="absolute inset-y-0 left-0 bg-white/80 group-hover:bg-white" style={{ width: `${progress * 100}%` }} />
      </div>
    </div>
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
        src={media("promo.mp4")}
        poster={media("promo-poster.jpg")}
        autoPlay
        muted
        loop
        playsInline
        aria-label="OpenTraffic in 76 seconds: it finds your dev servers, shares one in a click, checks every hop, and lets your team point, comment, draw, and suggest changes that your coding agent makes, each its own commit; see it on someone's phone, lead the demo, and password protect it"
      />
      <Scrubber video={video} />
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
