import { useEffect, useRef, useState } from 'react'
import { ArrowLeft, ArrowRight, BookOpen, ChevronDown, FileText, Search, X } from 'lucide-react'
import { Nav } from '@/components/site/Hero'
import { docs, docPath, groups, headings, searchDocs } from './data'
import { CopyButton, Markdown } from './Markdown'
import './docs.css'

function Navigation({ slug }: { slug: string }) {
  return <nav aria-label="Documentation">{groups.map((group) => <div className="docs-nav-group" key={group}>
    <p>{group}</p>{docs.filter((page) => page.group === group).map((page) => <a key={page.slug} href={docPath(page.slug)} aria-current={slug === page.slug ? 'page' : undefined}>{page.title}</a>)}
  </div>)}</nav>
}

function SearchDialog({ dialogRef }: { dialogRef: React.RefObject<HTMLDialogElement | null> }) {
  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState(0)
  const results = searchDocs(query)
  const active = Math.min(selected, Math.max(0, results.length - 1))
  const list = useRef<HTMLDivElement>(null)
  useEffect(() => { list.current?.querySelector(`[data-index="${active}"]`)?.scrollIntoView({ block: 'nearest' }) }, [active])
  return <dialog ref={dialogRef} className="docs-search-dialog" aria-label="Search documentation" onClick={(event) => { if (event.target === event.currentTarget) dialogRef.current?.close() }}>
    <div className="docs-search-input"><Search size={19} aria-hidden="true" />
      <input autoFocus aria-label="Search all documentation" role="combobox" aria-controls="docs-search-results" aria-expanded="true" aria-autocomplete="list" aria-activedescendant={results.length ? `docs-result-${active}` : undefined} placeholder="Search documentation…" value={query} onChange={(event) => { setQuery(event.target.value); setSelected(0) }} onKeyDown={(event) => {
        if (event.key === 'ArrowDown') { event.preventDefault(); setSelected((v) => Math.min(v + 1, results.length - 1)) }
        if (event.key === 'ArrowUp') { event.preventDefault(); setSelected((v) => Math.max(v - 1, 0)) }
        if (event.key === 'Enter' && results[active]) { event.preventDefault(); window.location.assign(docPath(results[active].page.slug)) }
      }} />
      <button type="button" aria-label="Close search" onClick={() => dialogRef.current?.close()}><X size={18} /></button>
    </div>
    <div className="docs-search-results" ref={list} id="docs-search-results" role="listbox" aria-label="Search results">
      <p className="docs-search-label" role="presentation">{query.trim() ? `${results.length} matching ${results.length === 1 ? 'guide' : 'guides'}` : 'Start exploring'}</p>
      {!results.length && <p className="docs-search-empty" role="presentation">No guides match “{query}”. Try a provider name, “token”, or “feedback”.</p>}
      {results.map(({ page, excerpt }, index) => <a id={`docs-result-${index}`} key={page.slug} data-index={index} role="option" aria-selected={index === active} href={docPath(page.slug)} onMouseEnter={() => setSelected(index)}>
        <FileText size={18} aria-hidden="true" /><div><span className="docs-search-group">{page.group}</span><strong>{page.title}</strong><p>{excerpt}</p></div><ArrowRight size={16} aria-hidden="true" />
      </a>)}
    </div><div className="docs-search-footer"><span>↑ ↓ navigate · Enter open · Esc close</span><span>Search stays on your device</span></div>
  </dialog>
}

export default function Docs({ slug = 'introduction' }: { slug?: string }) {
  const index = docs.findIndex((page) => page.slug === slug)
  const page = docs[index]
  const toc = page ? headings(page.body) : []
  const [activeHeading, setActiveHeading] = useState('')
  const dialog = useRef<HTMLDialogElement>(null)
  const openSearch = () => { dialog.current?.showModal(); dialog.current?.querySelector('input')?.focus() }
  useEffect(() => {
    const keyboard = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); if (dialog.current?.open) dialog.current.close(); else openSearch() }
    }
    window.addEventListener('keydown', keyboard)
    return () => window.removeEventListener('keydown', keyboard)
  }, [])
  useEffect(() => {
    if (!page) return
    document.title = `${page.title} — OpenTraffic Docs`
    document.querySelector('meta[name="description"]')?.setAttribute('content', page.description)
    document.querySelector('link[rel="canonical"]')?.setAttribute('href', `https://opentraffic.dev${docPath(page.slug)}`)
    const sidebar = document.querySelector<HTMLElement>('.docs-sidebar')
    const currentLink = sidebar?.querySelector<HTMLElement>('[aria-current="page"]')
    if (sidebar && currentLink) sidebar.scrollTop = Math.max(0, currentLink.offsetTop - sidebar.clientHeight / 2)
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) setActiveHeading(entry.target.id)
    }, { rootMargin: '-80px 0px -60% 0px' })
    document.querySelectorAll('.docs-prose h2').forEach((element) => observer.observe(element))
    if (window.location.hash) { document.getElementById(decodeURIComponent(window.location.hash.slice(1)))?.scrollIntoView() }
    return () => observer.disconnect()
  }, [page])
  return <div className="docs-shell">
    <a className="docs-skip" href="#docs-content">Skip to content</a>
    <Nav docs />
    <div className="docs-toolbar"><div><a href="/docs" className="docs-label"><BookOpen size={16} />Documentation</a><button type="button" onClick={openSearch} className="docs-search-trigger"><Search size={15} /><span>Search docs</span><kbd>⌘ K</kbd></button></div></div>
    <div className="docs-layout">
      <aside className="docs-sidebar"><div className="docs-sidebar-version"><span className="size-1.5 rounded-full bg-green-500" />OpenTraffic 1.0.2</div><Navigation slug={slug} /><a className="docs-back" href="/">← Back to website</a></aside>
      <div className="docs-mobile-nav"><details><summary>Browse documentation <ChevronDown size={16} /></summary><Navigation slug={slug} /></details></div>
      <main id="docs-content" className="docs-main">
        {page ? <>
          <div className="docs-breadcrumb"><a href="/docs">Docs</a><span>/</span><span>{page.group}</span></div>
          <header className="docs-article-header"><h1>{page.title}</h1><p>{page.description}</p><div className="docs-article-meta"><span>{Math.max(1, Math.ceil(page.body.split(/\s+/).length / 220))} min read</span><span>Updated October 9, 2026</span><CopyButton text={`# ${page.title}\n\n${page.body}`} label="Copy page as Markdown" /><a href={`/docs/${page.slug}.md`} className="docs-markdown-link">Markdown ↗</a></div></header>
          <div className="docs-mobile-toc"><details><summary>On this page <ChevronDown size={16} /></summary>{toc.map((heading) => <a key={heading.id} href={`#${heading.id}`}>{heading.title}</a>)}</details></div>
          <article className="docs-prose"><Markdown body={page.body} /></article>
          <nav className="docs-pagination" aria-label="Adjacent guides">{index > 0 ? <a href={docPath(docs[index - 1].slug)}><ArrowLeft size={17} /><span><small>Previous</small>{docs[index - 1].title}</span></a> : <span />}{index < docs.length - 1 && <a href={docPath(docs[index + 1].slug)}><span><small>Next</small>{docs[index + 1].title}</span><ArrowRight size={17} /></a>}</nav>
          <footer className="docs-article-footer"><span>OpenTraffic by <a href="https://medda.se">Medda Systems</a></span><a href="/docs/troubleshooting">Need help? Troubleshooting →</a></footer>
        </> : <div className="docs-not-found"><p>404 · Documentation</p><h1>Guide not found</h1><p>This address doesn’t match a guide. Search the docs or return to the introduction.</p><a href="/docs">Browse documentation →</a></div>}
      </main>
      <aside className="docs-toc" aria-label="On this page"><p>On this page</p>{toc.map((heading) => <a key={heading.id} href={`#${heading.id}`} aria-current={activeHeading === heading.id ? 'location' : undefined}>{heading.title}</a>)}<div className="docs-toc-help"><span>Ready to try it?</span><a href="/docs/quickstart">Share your first server <ArrowRight size={14} /></a></div></aside>
    </div><SearchDialog dialogRef={dialog} />
  </div>
}
