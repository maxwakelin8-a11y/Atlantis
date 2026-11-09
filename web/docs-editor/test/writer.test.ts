// The Writer running on Atlantis's pieces: the store keeps files byte-identical, every Writer
// command works on GenOffice's editor, and the UI strings are English.
import { describe, expect, it } from 'vitest'
import { memoryFS } from '../src/writer/fs'
import { createWriterStore, withBody } from '../src/writer/store'
import { createEditor, setBlockStyle, BLOCK_STYLES, SLASH_ITEMS, type Editor } from '../src/writer/editor'
import { setEnglish } from '../src/locale'
import { t } from '../vendor/genoffice/renderer/i18n/locale'

const ROOT = '/Users/x/Writer'

function project(files: Record<string, string>) {
  const fs = memoryFS(ROOT, Object.fromEntries(Object.entries(files).map(([k, v]) => [`${ROOT}/Essay/${k}`, v])))
  return { fs, store: createWriterStore(fs) }
}

const ODD_FRONT_MATTER = '﻿---\r\ntitle:   "Intro: why"\r\nsynopsis: Hook\r\ntags: [a, b]\r\n---\r\n\r\n\r\nFirst *line*.\r\n'

describe('Writer store (byte-identical saves)', () => {
  it('opens a project and writes nothing when a doc is saved unchanged', async () => {
    const { fs, store } = project({ 'Draft/Intro.md': ODD_FRONT_MATTER, '.writer.json': '{"title":"Essay"}\n' })
    const p = await store.open({ project: 'Essay' })
    const intro = p.tree[0].children[0]
    expect(intro.title).toBe('Intro: why')
    fs.writes.length = 0
    await store.save({ project: 'Essay', path: intro.path, meta: intro.meta, body: intro.body })
    expect(fs.writes).toEqual([])
    expect(fs.files.get(`${ROOT}/Essay/Draft/Intro.md`)).toBe(ODD_FRONT_MATTER)
  })

  it('keeps the front matter bytes when only the text changes', async () => {
    const { fs, store } = project({ 'Draft/Intro.md': ODD_FRONT_MATTER })
    const p = await store.open({ project: 'Essay' })
    const intro = p.tree[0].children[0]
    await store.save({ project: 'Essay', path: intro.path, meta: intro.meta, body: intro.body.replace('First', 'Second') })
    expect(fs.files.get(`${ROOT}/Essay/Draft/Intro.md`)).toBe(ODD_FRONT_MATTER.replace('First', 'Second'))
  })

  it('rewrites the front matter (keeping unknown keys) when a field changes', () => {
    const out = withBody(ODD_FRONT_MATTER, { title: 'Intro: why', synopsis: 'New hook' }, 'Intro', '\r\nFirst *line*.\r\n')
    expect(out).toBe('﻿---\ntitle: "Intro: why"\nsynopsis: New hook\ntags: [a, b]\n---\n\n\r\nFirst *line*.\r\n')
  })

  it('does a whole project lifecycle on plain files', async () => {
    const fs = memoryFS(ROOT)
    const store = createWriterStore(fs)
    const p = await store.create({ title: 'Speech', settings: {}, items: [{ path: 'Draft/Opening', kind: 'doc', body: 'Hi.\n' }] })
    expect(p.tree.map((n: { path: string }) => n.path)).toEqual(['Draft', 'Research', 'Notes', 'Trash'])
    const { path } = await store.add({ project: 'Speech', parent: 'Draft', kind: 'doc', title: 'Middle' })
    const renamed = await store.rename({ project: 'Speech', path, title: 'Body' })
    expect(renamed.path).toBe('Draft/Body.md')
    await store.snapshot({ project: 'Speech', path: 'Draft/Opening.md', name: 'first' })
    expect((await store.snapshots({ project: 'Speech', path: 'Draft/Opening.md' })).snapshots).toHaveLength(1)
    await store.trash({ project: 'Speech', path: 'Draft/Body.md' })
    expect(fs.files.has(`${ROOT}/Speech/Trash/Body.md`)).toBe(true)
    await store.emptyTrash({ project: 'Speech' })
    expect(fs.files.has(`${ROOT}/Speech/Trash/Body.md`)).toBe(false)
    expect([...fs.files.keys()].some((f) => f.includes('/.deleted/'))).toBe(true)
    await expect(store.save({ project: 'Speech', path: '../../escape.md', meta: {}, body: 'x' })).rejects.toThrow(/outside/)
  })
})

describe('Writer commands on the GenOffice editor', () => {
  const make = (markdown: string) => createEditor({ element: document.createElement('div'), markdown, onChange: () => {} })

  it('gives back the exact body when nothing was edited', () => {
    const body = '# Title\n\n* star bullet\n\n1) paren list\n\nText with ==mark== and ~~strike~~.\n'
    const ed = make(body)
    expect(ed.getMarkdown()).toBe(body)
    ed.destroy()
  })

  it('runs every format bar, bubble, table and slash command', () => {
    const ed = make('Hello world\n')
    const select = () => ed.commands.setTextSelection({ from: 1, to: 6 })
    const run = (name: string, fn: (e: Editor) => unknown) => {
      select()
      expect(() => fn(ed), name).not.toThrow()
    }
    run('bold', (e) => e.chain().focus().toggleBold().run())
    expect(ed.isActive('bold')).toBe(true)
    run('italic', (e) => e.chain().focus().toggleItalic().run())
    run('strike', (e) => e.chain().focus().toggleStrike().run())
    run('highlight', (e) => e.chain().focus().toggleHighlight().run())
    run('code', (e) => e.chain().focus().toggleCode().run())
    run('link', (e) => e.chain().focus().extendMarkRange('link').setLink({ href: 'https://example.com' }).run())
    expect(ed.isActive('link')).toBe(true)
    run('unlink', (e) => e.chain().focus().extendMarkRange('link').unsetLink().run())
    run('clear', (e) => e.chain().focus().unsetAllMarks().clearNodes().run())
    for (const [name, check] of [
      ['toggleBulletList', 'bulletList'],
      ['toggleOrderedList', 'orderedList'],
      ['toggleTaskList', 'taskList'],
      ['toggleBlockquote', 'blockquote'],
    ] as const) {
      run(name, (e) => (e.chain().focus() as unknown as Record<string, () => { run(): boolean }>)[name]().run())
      expect(ed.isActive(check), check).toBe(true)
      run(`${name} off`, (e) => (e.chain().focus() as unknown as Record<string, () => { run(): boolean }>)[name]().run())
    }
    for (const s of BLOCK_STYLES) run(`style ${s.id}`, (e) => setBlockStyle(e, s.id))
    run('paragraph again', (e) => setBlockStyle(e, 'p'))
    run('table', (e) => e.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run())
    expect(ed.isActive('table')).toBe(true)
    for (const cmd of ['addRowAfter', 'addColumnAfter', 'deleteRow', 'deleteColumn', 'toggleHeaderRow', 'deleteTable'] as const) {
      expect(() => (ed.chain().focus() as unknown as Record<string, () => { run(): boolean }>)[cmd]().run(), cmd).not.toThrow()
    }
    run('rule', (e) => e.chain().focus().setHorizontalRule().run())
    for (const item of SLASH_ITEMS) run(`slash ${item.id}`, (e) => item.run(e))
    run('undo', (e) => e.chain().focus().undo().run())
    run('redo', (e) => e.chain().focus().redo().run())
    expect(typeof ed.getMarkdown()).toBe('string')
    ed.destroy()
  })
})

describe('language', () => {
  it('shows GenOffice strings in English', () => {
    setEnglish()
    expect(t('placeholder')).not.toMatch(/[一-鿿]/)
    expect(t('styleH1')).toMatch(/Heading/i)
  })
})

// The Writer's save path on real files: split off the front matter (store), edit nothing in the
// editor, put the file back together (withBody) — it must be the same bytes. Add folders with
// ATLANTIS_RT_CORPUS=dir1:dir2 (read-only).
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join as pjoin, basename as pbase } from 'node:path'
import { parseDoc } from '../src/writer/store'

function corpusFiles(): string[] {
  const out: string[] = []
  const walk = (dir: string) => {
    for (const name of readdirSync(dir)) {
      if (name.startsWith('.') || name === 'node_modules' || name === 'build') continue
      const p = pjoin(dir, name)
      const s = statSync(p)
      if (s.isDirectory()) walk(p)
      else if (name.endsWith('.md') && s.size < 2_000_000) out.push(p)
    }
  }
  for (const d of (process.env.ATLANTIS_RT_CORPUS ?? '').split(':').filter(Boolean)) walk(d)
  return out
}

describe('Writer save path on real files', () => {
  const files = corpusFiles()
  it.skipIf(!files.length)(`is byte-identical on ${files.length} files`, () => {
    const failed: string[] = []
    for (const file of files) {
      const raw = readFileSync(file, 'utf8')
      if (Buffer.from(raw, 'utf8').compare(readFileSync(file)) !== 0) continue // not UTF-8: Docs won't open it
      const { meta, body } = parseDoc(raw)
      const ed = createEditor({ element: document.createElement('div'), markdown: body, onChange: () => {} })
      const out = withBody(raw, meta, pbase(file).replace(/\.(md|markdown|txt)$/i, ''), ed.getMarkdown())
      ed.destroy()
      if (out !== raw) failed.push(file)
    }
    console.log(`Writer save path: ${files.length - failed.length}/${files.length} byte-identical`)
    expect(failed).toEqual([])
  })
})
