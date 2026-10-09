# Documentation maintenance

- `catalog.json` controls guide order, sidebar groups, titles, and descriptions.
- `content/*.md` is the canonical website documentation. Use absolute `/docs/...` links.
- Start with H2 headings: the page title is supplied by the layout. Heading text must be unique within a page.
- Use fenced code blocks with language labels. Raw HTML is intentionally not enabled.
- Validate product behavior against `README.md`, `Integrations/README.md`, and the implementation, especially
  `Sources/OpenTrafficCore/API/` and `Sources/OpenTraffic/Resources/opentraffic`.
- Mark post-release features as unreleased until the downloadable app ships them. Update the version label
  and review date in `Docs.tsx` and the scope note in `introduction.md` when publishing a release.
- `npm run build` writes HTML for every guide, Markdown exports, sitemap, robots.txt, and llms.txt.
- `npm run docs:check` validates static output, page links, anchors, fenced examples, and search behavior.
- Verify search (⌘K/Ctrl+K, arrows, Enter, Escape), copying, mobile navigation, light/dark themes, and direct
  page URLs before deploying. Search is local; it does not send queries to a third-party service.
- `npm run deploy` builds and publishes the site with the documentation to Cloudflare.

The documentation content is included only in the documentation JavaScript chunk. Static article HTML
is kept visible until React hydrates it; static readers do not need JavaScript to read a guide.
