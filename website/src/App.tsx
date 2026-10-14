import { useEffect, useState } from "react"
import { Agents, Install } from "@/components/site/Install"
import { Faq, Footer } from "@/components/site/Faq"
import { More, Providers, Story, Terminal } from "@/components/site/Features"
import { Hero, Nav } from "@/components/site/Hero"
import { latestVersion } from "@/lib/site"

export default function App() {
  const [version, setVersion] = useState<string | null>(null)
  useEffect(() => {
    latestVersion().then(setVersion)
  }, [])
  return (
    // "Top" is the page itself, above the sticky bar, so the logo link scrolls all the way up.
    <div id="top" className="min-h-screen">
      <Nav />
      <main>
        <Hero version={version} />
        <Providers />
        <Story />
        <More />
        <Terminal />
        <Agents />
        <Install version={version} />
        <Faq />
      </main>
      <Footer />
    </div>
  )
}
