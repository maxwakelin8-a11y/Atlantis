// Atlantis Docs: the Writer from BetterSEQTA+ (src/writer) on top of GenOffice's lossless markdown
// editor (vendor/genoffice). Files are reached only through Swift (src/writer/fs.ts); no network.
import '../vendor/genoffice/packages/ui/tokens.css'
import '../vendor/genoffice/packages/ui/dropdown.css'
import '../vendor/genoffice/renderer/styles.css'
import 'katex/dist/katex.min.css'
import './atlantis.css'
import { WriterPage } from './writer/page'
import { createEditor, sessionOf } from './writer/editor'
import { call } from './writer/fs'
import { setEnglish } from './locale'

declare global {
  interface Window {
    atlantis?: Record<string, unknown>
  }
}

setEnglish()

let author = ''
const page = new WriterPage({ settings: () => ({ folder: '', author, citeAi: false }) })
document.getElementById('root')?.append(page.root)

window.atlantis = {
  /** Saves every open document now (Swift calls this before quitting). */
  flush: () => page.flush(),
  /** Read-only round-trip check: what a save would write for `raw`, with and without the shortcut. */
  roundTrip: (raw: string) => {
    const host = document.createElement('div')
    const editor = createEditor({ element: host, markdown: raw, onChange: () => {} })
    try {
      const session = sessionOf(editor)!
      return {
        serialize: session.serialize(),
        serializeWithoutShortcut: session.serializeWithoutShortcut(),
        hasSourceMap: session.hasSourceMap,
      }
    } finally {
      editor.destroy()
    }
  },
}

void call<{ author?: string }>('writer.host')
  .then((h) => {
    author = h.author ?? ''
  })
  .catch(() => {})
  .finally(() => void page.start())
