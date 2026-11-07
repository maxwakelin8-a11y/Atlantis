// One open document: load raw text, and produce the exact text a save would write.
// Mirrors GenOffice's App.tsx load/save path, without the Electron and AI parts.
import type { Editor } from '@tiptap/core'
import { parseDocText, stripLegacyFencedDivs, type DocEnvelope } from '../vendor/genoffice/renderer/markdown/docText'
import { buildSourceMap, spliceMarkdown, type SourceMap } from '../vendor/genoffice/renderer/markdown/sourceSplice'
import {
  captureMarkdownSource,
  serializeMarkdown,
  type MarkdownSourceSnapshot,
} from '../vendor/genoffice/renderer/markdown/roundtripSerializer'

export class DocSession {
  private envelope: DocEnvelope | null = null
  private map: SourceMap | null = null
  private original: MarkdownSourceSnapshot | undefined

  constructor(private readonly editor: Editor) {}

  /** Puts `raw` (the file's exact text) in the editor. Not undoable. */
  load(raw: string): void {
    const envelope = parseDocText(raw)
    const body = stripLegacyFencedDivs(envelope.body)
    this.editor
      .chain()
      .setMeta('addToHistory', false)
      .setContent(body, { contentType: 'markdown' })
      .setTextSelection(1)
      .run()
    this.envelope = envelope
    this.map = buildSourceMap(this.editor, this.editor.state.doc, body)
    this.original = captureMarkdownSource(raw, envelope, this.editor.state.doc)
  }

  /** The exact text a save would write now. Unchanged docs return the original bytes. */
  serialize(): string {
    if (!this.envelope) throw new Error('no document loaded')
    return serializeMarkdown(this.envelope, this.editor.state.doc, () => this.body(), this.original)
  }

  /** Like serialize(), but without the "unchanged → original" shortcut: tests the block splice. */
  serializeWithoutShortcut(): string {
    if (!this.envelope) throw new Error('no document loaded')
    return serializeMarkdown(this.envelope, this.editor.state.doc, () => this.body(), undefined)
  }

  get hasSourceMap(): boolean {
    return this.map !== null
  }

  private body(): string {
    return this.map ? spliceMarkdown(this.editor, this.editor.state.doc, this.map) : this.editor.getMarkdown()
  }
}
