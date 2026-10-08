import { Check, Copy } from "lucide-react"
import { useState } from "react"
import { cn } from "@/lib/utils"

/** A shell command with a copy button. */
/** `wrap` lets long commands break across lines instead of scrolling. */
export function CopyCommand({ command, className, wrap = false }: { command: string; className?: string; wrap?: boolean }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    await navigator.clipboard.writeText(command)
    setCopied(true)
    setTimeout(() => setCopied(false), 1600)
  }
  return (
    <div className={cn("group flex items-center gap-3 rounded-xl border bg-card px-4 py-3 font-mono text-sm shadow-xs", className)}>
      <span className="select-none text-muted-foreground">$</span>
      <code className={cn("min-w-0 flex-1", wrap ? "break-all" : "overflow-x-auto whitespace-nowrap")}>{command}</code>
      <button
        type="button"
        onClick={copy}
        aria-label={copied ? "Copied" : "Copy command"}
        className="rounded-md p-1.5 text-muted-foreground transition hover:bg-muted hover:text-foreground"
      >
        {copied ? <Check className="size-4 text-green-600" /> : <Copy className="size-4" />}
      </button>
    </div>
  )
}
