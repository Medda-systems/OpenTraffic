import catalog from './catalog.json'

const files = import.meta.glob('./content/*.md', { query: '?raw', import: 'default', eager: true }) as Record<string, string>
export const docs = catalog.map((page) => ({ ...page, body: files[`./content/${page.slug}.md`] }))
export type Doc = (typeof docs)[number]
export const groups = [...new Set(docs.map((page) => page.group))]
export const docPath = (slug: string) => slug === 'introduction' ? '/docs' : `/docs/${slug}`
export const headingId = (text: string) => text.toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').trim().replace(/\s+/g, '-')
export const plainText = (text: string) => text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[*`#_]/g, '')
export const headings = (body: string) => [...body.replace(/```[\s\S]*?```/g, '').matchAll(/^## (.+)$/gm)].map((m) => ({ title: plainText(m[1]), id: headingId(plainText(m[1])) }))

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
