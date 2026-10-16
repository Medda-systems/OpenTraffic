import catalog from './catalog.json'

import changelog from '../../../CHANGELOG.md?raw'
import versionFile from '../../../VERSION?raw'

const files = import.meta.glob('./content/*.md', { query: '?raw', import: 'default', eager: true }) as Record<string, string>
// The changelog page is the repository's CHANGELOG.md, without its own title.
files['./content/changelog.md'] = changelog.replace(/^# .*\n+/, '')
export const docs = catalog.map((page) => ({ ...page, body: files[`./content/${page.slug}.md`] }))
export type Doc = (typeof docs)[number]
export const groups = [...new Set(docs.map((page) => page.group))]
export const docPath = (slug: string) => slug === 'introduction' ? '/docs' : `/docs/${slug}`
/** The current version, from the repository's VERSION file. */
export const version = versionFile.trim()
/** A changelog heading, "1.0.13 (16 October 2026)": the version, and the day it was published. */
export function datedHeading(text: string) {
  const match = /^(\d+(?:\.\d+)+) \((\d{1,2}) ([A-Z][a-z]+) (\d{4})\)$/.exec(text.trim())
  if (!match) return null
  const [, title, day, month, year] = match
  const index = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'].indexOf(month)
  if (index < 0) return null
  return { title, date: `${day} ${month} ${year}`, short: `${day} ${month.slice(0, 3)}`, iso: `${year}-${String(index + 1).padStart(2, '0')}-${day.padStart(2, '0')}` }
}
const slug = (text: string) => text.toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').trim().replace(/\s+/g, '-')
// A dated heading's id is its version alone ("1013"), as before headings had dates.
export const headingId = (text: string) => slug(datedHeading(text)?.title ?? text)
export const plainText = (text: string) => text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[*`#_]/g, '')
export const headings = (body: string) => [...body.replace(/```[\s\S]*?```/g, '').matchAll(/^## (.+)$/gm)].map((m) => {
  const text = plainText(m[1])
  const dated = datedHeading(text)
  return { title: dated?.title ?? text, date: dated, id: headingId(text) }
})

export function searchDocs(query: string) {
  const terms = query.toLowerCase().trim().split(/\s+/).filter(Boolean)
  if (!terms.length) return docs.slice(0, 6).map((page) => ({ page, excerpt: page.description }))
  return docs.map((page) => {
    const body = plainText(page.body).replace(/\s+/g, ' ')
    const haystack = `${page.title} ${page.description} ${body}`.toLowerCase()
    const score = terms.every((term) => haystack.includes(term))
      ? terms.reduce((sum, term) => sum + (page.title.toLowerCase().includes(term) ? 10 : 0) + (page.description.toLowerCase().includes(term) ? 4 : 0) + 1, 0) : 0
    const position = body.toLowerCase().indexOf(terms[0])
    const start = Math.max(0, position - 45)
    return { page, score, excerpt: position < 0 ? page.description : `${start ? '…' : ''}${body.slice(start, start + 170)}…` }
  }).filter((result) => result.score > 0).sort((a, b) => b.score - a.score).slice(0, 12)
}
