import { StrictMode } from 'react'
import { createRoot, hydrateRoot } from 'react-dom/client'
import './index.css'
const root = document.getElementById('root')!
const path = window.location.pathname.replace(/\/+$/, '')
if (root.dataset.docsSlug || path === '/docs' || path.startsWith('/docs/')) {
  // Keep the statically rendered article visible while its interactive controls load.
  import('./docs/Docs').then(({ default: Docs }) => {
    const view = <StrictMode><Docs slug={root.dataset.docsSlug || (path === '/docs' ? 'introduction' : path.slice(6))} /></StrictMode>
    if (root.hasChildNodes()) hydrateRoot(root, view)
    else createRoot(root).render(view)
  })
} else {
  import('./App').then(({ default: App }) => createRoot(root).render(<StrictMode><App /></StrictMode>))
}
