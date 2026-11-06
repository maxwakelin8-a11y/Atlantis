// The Docs round-trip rule (AGENTS.md): opening and saving a doc without changes must leave the
// file byte-identical. Runs on test/fixtures and on any folders in ATLANTIS_RT_CORPUS
// (colon-separated). Real files are only read, never written.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { Editor } from '@tiptap/core'
import { atlantisExtensions } from '../src/extensions'
import { DocSession } from '../src/session'

const editor = new Editor({ extensions: atlantisExtensions(), content: '' })
afterAll(() => editor.destroy())

function markdownFiles(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name.startsWith('.') || name === 'node_modules' || name === 'vendor' || name === '.build') continue
    const path = join(dir, name)
    const info = statSync(path)
    if (info.isDirectory()) markdownFiles(path, out)
    else if (name.endsWith('.md') && info.size < 2_000_000) out.push(path)
  }
  return out
}

const fixtures = markdownFiles(join(__dirname, 'fixtures'))
const corpus = (process.env.ATLANTIS_RT_CORPUS ?? '').split(':').filter(Boolean).flatMap((d) => markdownFiles(d))

function changedLines(a: string, b: string): number {
  const x = a.split('\n'), y = b.split('\n')
  let start = 0
  while (start < x.length && start < y.length && x[start] === y[start]) start++
  let endX = x.length - 1, endY = y.length - 1
  while (endX >= start && endY >= start && x[endX] === y[endY]) { endX--; endY-- }
  return Math.max(endX - start + 1, endY - start + 1)
}

describe('no-edit save is byte-identical', () => {
  it.each(fixtures)('%s', (path) => {
    const raw = readFileSync(path, 'utf8')
    const session = new DocSession(editor)
    session.load(raw)
    expect(session.serialize()).toBe(raw)
  })
})

describe('block splice without the shortcut (fixtures)', () => {
  it.each(fixtures)('%s', (path) => {
    const raw = readFileSync(path, 'utf8')
    const session = new DocSession(editor)
    session.load(raw)
    expect(session.serializeWithoutShortcut()).toBe(raw)
  })
})

describe('a one-word edit changes only its block', () => {
  it.each(fixtures)('%s', (path) => {
    const raw = readFileSync(path, 'utf8')
    const session = new DocSession(editor)
    session.load(raw)
    let edited = false
    editor.state.doc.descendants((node, pos) => {
      if (edited || node.type.name !== 'paragraph' || node.content.size === 0) return !edited
      editor.chain().insertContentAt(pos + 1 + node.content.size, ' EDIT').run()
      edited = true
      return false
    })
    if (!edited) return
    const out = session.serialize()
    expect(out).toContain('EDIT')
    expect(changedLines(raw.replace(/\r\n/g, '\n'), out.replace(/\r\n/g, '\n'))).toBeLessThanOrEqual(3)
  })
})

describe.runIf(corpus.length > 0)('real files', () => {
  const slow: [number, string, number][] = []
  const saves: [number, number][] = []
  afterAll(() => {
    const max = (i: 0 | 1) => Math.max(...saves.map((s) => s[i])).toFixed(0)
    const sum = (i: 0 | 1) => saves.reduce((a, s) => a + s[i], 0).toFixed(0)
    console.log(`save (shortcut) max ${max(0)} ms, total ${sum(0)} ms; splice max ${max(1)} ms, total ${sum(1)} ms; ` +
      `loads total ${slow.reduce((a, s) => a + s[0], 0).toFixed(0)} ms`)
    slow.sort((a, b) => b[0] - a[0])
    console.log('slowest loads (ms, bytes, file):\n' +
      slow.slice(0, 8).map(([ms, path, size]) => `  ${ms.toFixed(0)}  ${size}  ${path.replace(process.env.HOME ?? '', '~')}`).join('\n'))
  })
  it.each(corpus)('%s', (path) => {
    const raw = readFileSync(path, 'utf8')
    const session = new DocSession(editor)
    const start = performance.now()
    session.load(raw)
    const loaded = performance.now()
    expect(session.serialize()).toBe(raw)
    const saved = performance.now()
    expect(session.serializeWithoutShortcut()).toBe(raw)
    const spliced = performance.now()
    slow.push([loaded - start, path, raw.length])
    saves.push([saved - loaded, spliced - saved])
  })
})
