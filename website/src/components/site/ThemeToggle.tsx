import { Moon, Sun } from "lucide-react"
import { useState } from "react"

export function ThemeToggle() {
  const [dark, setDark] = useState(() => document.documentElement.classList.contains("dark"))
  const toggle = () => {
    const next = !dark
    setDark(next)
    document.documentElement.classList.toggle("dark", next)
    localStorage.setItem("theme", next ? "dark" : "light")
  }
  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={dark ? "Use light mode" : "Use dark mode"}
      className="grid size-9 place-items-center rounded-full border bg-background text-foreground transition hover:bg-muted"
    >
      {dark ? <Sun className="size-4" /> : <Moon className="size-4" />}
    </button>
  )
}
