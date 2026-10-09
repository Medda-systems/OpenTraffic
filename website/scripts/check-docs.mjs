import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { docs, docPath, headings, searchDocs } from '../dist-ssr/prerender.js'

const pathMap = new Map(docs.map((page) => [docPath(page.slug), page]))
for (const page of docs) {
  assert.equal((page.body.match(/^```/gm) ?? []).length % 2, 0, `Unclosed code fence: ${page.slug}`)
  for (const block of page.body.matchAll(/```json\n([\s\S]*?)```/g)) JSON.parse(block[1])
  const html = await readFile(`dist${docPath(page.slug)}/index.html`, 'utf8')
  assert.ok(html.includes(`${page.title.replace(/&/g, '&amp;')} — OpenTraffic Docs`), `Missing title: ${page.slug}`)
  assert.ok(html.includes('class="docs-prose"'), `Missing static article: ${page.slug}`)
  assert.ok(html.includes(`https://opentraffic.dev${docPath(page.slug)}`), `Missing canonical: ${page.slug}`)
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1])
  assert.equal(new Set(ids).size, ids.length, `Duplicate element IDs: ${page.slug}`)
  for (const heading of headings(page.body)) assert.ok(ids.includes(heading.id), `Broken outline: ${page.slug}#${heading.id}`)
  for (const match of page.body.matchAll(/\]\((\/docs[^)]*)\)/g)) {
    const [path, hash] = match[1].split('#')
    if (path.startsWith('/docs/images/')) { await readFile(`dist${path}`); continue }
    const target = pathMap.get(path)
    assert.ok(target, `Broken link: ${page.slug} → ${path}`)
    if (hash) assert.ok(headings(target.body).some((heading) => heading.id === hash), `Broken anchor: ${match[1]}`)
  }
  assert.ok(!/\]\((?:specs|script|Integrations)\//.test(page.body), `Private repository link: ${page.slug}`)
  const markdown = await readFile(`dist/docs/${page.slug}.md`, 'utf8')
  assert.ok(markdown.includes(page.body), `Markdown mismatch: ${page.slug}`)
}
assert.equal(searchDocs('webhook signature')[0].page.slug, 'webhooks')
assert.equal(searchDocs('localHost BRIDGE')[0].page.slug, 'localhost-bridge')
assert.equal(searchDocs('this-does-not-exist-123456').length, 0)
assert.ok(searchDocs('   ').length > 0)
console.log(`Verified ${docs.length} static pages, titles, canonical URLs, outlines, links, Markdown exports, and search behavior.`)
