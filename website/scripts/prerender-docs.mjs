import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { docs, docPath, renderDoc } from '../dist-ssr/prerender.js'
import { resolve } from 'node:path'

const template = await readFile('dist/index.html', 'utf8')
const escape = (value) => value.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
// Link the client documentation stylesheet in the static document so
// prose and navigation render correctly before JavaScript and in non-JavaScript readers.
const { readdir } = await import('node:fs/promises')
const styles = (await readdir('dist/assets')).filter((name) => name.startsWith('Docs-') && name.endsWith('.css'))
for (const page of docs) {
  const url = `https://opentraffic.dev${docPath(page.slug)}`
  const title = `${page.title} — OpenTraffic Docs`
  const folder = resolve('dist', docPath(page.slug).slice(1))
  await mkdir(folder, { recursive: true })
  let html = template.replace(/<title>.*?<\/title>/, `<title>${escape(title)}</title>`)
    .replace(/(<meta name="description" content=")[^"]*/, `$1${escape(page.description)}`)
    .replace(/(<link rel="canonical" href=")[^"]*/, `$1${url}`)
    .replace(/(<meta property="og:url" content=")[^"]*/, `$1${url}`)
    .replace(/(<meta property="og:title" content=")[^"]*/, `$1${escape(title)}`)
    .replace(/(<meta property="og:description" content=")[^"]*/, `$1${escape(page.description)}`)
    .replace('<div id="root"></div>', () => `<div id="root" data-docs-slug="${page.slug}">${renderDoc(page.slug)}</div>`)
    .replace('</head>', `${styles.map((name) => `<link rel="stylesheet" href="/assets/${name}">`).join('\n')}\n</head>`)
  await writeFile(`${folder}/index.html`, html)
  await writeFile(`dist/docs/${page.slug}.md`, `# ${page.title}\n\n${page.description}\n\n${page.body}`)
}
await writeFile('dist/404.html', template
  .replace(/<title>.*?<\/title>/, '<title>Page not found — OpenTraffic</title>')
  .replace(/<link rel="canonical"[^>]*>/, '<meta name="robots" content="noindex">')
  .replace('<div id="root"></div>', () => `<div id="root" data-docs-slug="not-found">${renderDoc('not-found')}</div>`)
  .replace('</head>', `${styles.map((name) => `<link rel="stylesheet" href="/assets/${name}">`).join('\n')}\n</head>`))
const urls = ['/', ...docs.map((page) => docPath(page.slug))]
await writeFile('dist/sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls.map((url) => `<url><loc>https://opentraffic.dev${url}</loc></url>`).join('')}</urlset>\n`)
await writeFile('dist/robots.txt', 'User-agent: *\nAllow: /\nSitemap: https://opentraffic.dev/sitemap.xml\n')
await writeFile('dist/llms.txt', `# OpenTraffic\n\n> Documentation for the macOS app for sharing localhost and live collaboration.\n\n## Guides\n\n${docs.map((page) => `- [${page.title}](https://opentraffic.dev/docs/${page.slug}.md): ${page.description}`).join('\n')}\n`)
console.log(`Generated ${docs.length} static documentation pages, Markdown copies, sitemap, and llms.txt.`)
