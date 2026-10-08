import { useEffect, useState } from "react"
import { Agents, Install } from "@/components/site/Install"
import { Faq, Footer } from "@/components/site/Faq"
import { Features, Providers } from "@/components/site/Features"
import { Hero, Nav } from "@/components/site/Hero"
import { latestVersion } from "@/lib/site"

export default function App() {
  const [version, setVersion] = useState<string | null>(null)
  useEffect(() => {
    latestVersion().then(setVersion)
  }, [])
  return (
    <div className="min-h-screen">
      <Nav />
      <main>
        <Hero version={version} />
        <Providers />
        <Features />
        <Agents />
        <Install version={version} />
        <Faq />
      </main>
      <Footer />
    </div>
  )
}
