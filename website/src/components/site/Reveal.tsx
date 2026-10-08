import { motion, useReducedMotion } from "motion/react"
import type { ReactNode } from "react"

/** No entrance animations for people who ask for reduced motion, or with ?static (screenshots). */
export const staticPage = typeof location !== "undefined" && new URLSearchParams(location.search).has("static")

export function useCalm() {
  return useReducedMotion() || staticPage
}

/** Fades content up as it scrolls into view, like medda.se's sections. */
export function Reveal({ children, delay = 0, className }: { children: ReactNode; delay?: number; className?: string }) {
  const calm = useCalm()
  if (calm) return <div className={className}>{children}</div>
  return (
    <motion.div
      className={className}
      initial={{ opacity: 0, y: 18 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-60px" }}
      transition={{ duration: 0.6, delay, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  )
}
