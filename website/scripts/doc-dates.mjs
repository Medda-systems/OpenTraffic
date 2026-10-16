// Each docs page's "Updated" date: the day of the last commit that changed its Markdown (the changelog
// page is the repository's CHANGELOG.md). Written to src/docs/dates.json before every build.
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'

const catalog = JSON.parse(readFileSync('src/docs/catalog.json', 'utf8'))
const dates = {}
for (const { slug } of catalog) {
  const file = slug === 'changelog' ? '../CHANGELOG.md' : `src/docs/content/${slug}.md`
  const day = execFileSync('git', ['log', '-1', '--format=%cs', '--', file], { encoding: 'utf8' }).trim()
  if (day) dates[slug] = day
}
writeFileSync('src/docs/dates.json', JSON.stringify(dates, null, 2) + '\n')
console.log(`Dated ${Object.keys(dates).length} documentation pages.`)
