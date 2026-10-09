import { Children, isValidElement, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeHighlight from 'rehype-highlight'
import { Check, Copy, Link as LinkIcon } from 'lucide-react'
import { headingId } from './data'

function textOf(children: ReactNode): string {
  return Children.toArray(children).map((child): string => typeof child === 'string' || typeof child === 'number' ? String(child) : isValidElement<{ children?: ReactNode }>(child) ? textOf(child.props.children) : '').join('')
}

export function CopyButton({ text, label = 'Copy code' }: { text: string; label?: string }) {
  const [status, setStatus] = useState('')
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text)
      setStatus('Copied')
    } catch { setStatus('Select text to copy') }
  }
  return <button type="button" onClick={copy} className="docs-copy" aria-label={status || label} title={status || label}>
    {status === 'Copied' ? <Check size={14} /> : <Copy size={14} />}<span aria-live="polite">{status || 'Copy'}</span>
  </button>
}

function CodeBlock({ children }: { children?: ReactNode }) {
  const ref = useRef<HTMLPreElement>(null)
  const child = Children.toArray(children)[0]
  const language = isValidElement<{ className?: string }>(child) ? child.props.className?.match(/language-(\S+)/)?.[1] : undefined
  return <div className="docs-code"><div className="docs-code-bar"><span>{language || 'text'}</span><CopyButton text={textOf(children).replace(/\n$/, '')} /></div><pre ref={ref} tabIndex={0}>{children}</pre></div>
}

export function Markdown({ body }: { body: string }) {
  return <ReactMarkdown remarkPlugins={[remarkGfm]} rehypePlugins={[[rehypeHighlight, { detect: false }]]} components={{
    h2: ({ children }) => { const id = headingId(textOf(children)); return <h2 id={id}><a href={`#${id}`} className="docs-heading-link">{children}<LinkIcon size={16} aria-hidden="true" /></a></h2> },
    h3: ({ children }) => { const id = headingId(textOf(children)); return <h3 id={id}>{children}</h3> },
    pre: ({ children }) => <CodeBlock>{children}</CodeBlock>,
    table: ({ children }) => <div className="docs-table" tabIndex={0} role="region" aria-label="Reference table"><table>{children}</table></div>,
    a: ({ href, children }) => <a href={href} {...(href?.startsWith('https://') ? { rel: 'noreferrer', target: '_blank' } : {})}>{children}</a>,
  }}>{body}</ReactMarkdown>
}
