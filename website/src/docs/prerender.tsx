import { renderToString } from 'react-dom/server'
import Docs from './Docs'
export { docs, docPath, searchDocs, headings } from './data'
export const renderDoc = (slug: string) => renderToString(<Docs slug={slug} />)
