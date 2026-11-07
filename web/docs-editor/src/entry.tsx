// Atlantis Docs editor entry. Mounts GenOffice's markdown editor (vendored snapshot) and talks
// to Swift over the narrow bridge in bridge.ts. No network, no AI, no file access from here.
import '../vendor/genoffice/packages/ui/tokens.css'
import '../vendor/genoffice/packages/ui/dropdown.css'
import '../vendor/genoffice/packages/ui/markdown.css'
import '../vendor/genoffice/renderer/styles.css'
import '../vendor/genoffice/renderer/markdown-themes.css'
import 'katex/dist/katex.min.css'
import './atlantis.css'
import { createRoot } from 'react-dom/client'
import { DocsEditor } from './DocsEditor'

const root = document.getElementById('root')
if (root) createRoot(root).render(<DocsEditor />)
