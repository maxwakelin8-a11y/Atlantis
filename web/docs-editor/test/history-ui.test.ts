// Atlantis: the writing record, versions kept as you save, and notes to self in the text.
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { memoryFS } from '../src/writer/fs'
import { setEnglish } from '../src/locale'
import { WriterPage } from '../src/writer/page'
import type { Editor } from '@tiptap/core'

const ROOT = '/Users/x/Writer'
const INTRO = '---\ntitle: Intro\n---\n\nThe sea is wide and the ocean is deep.\n'
const files = {
  [`${ROOT}/Essay/.writer.json`]: '{"title":"Ocean essay"}\n',
  [`${ROOT}/Essay/Draft/Intro.md`]: INTRO,
}
let fs = memoryFS(ROOT, files)

beforeAll(() => {
  setEnglish()
  Element.prototype.scrollIntoView = () => {}
  Element.prototype.scrollBy = () => {}
  // jsdom has no layout and no Blob.arrayBuffer; ProseMirror and the paste code need these.
  const noRects = () => [] as unknown as DOMRectList
  Element.prototype.getClientRects ??= noRects
  Range.prototype.getClientRects ??= noRects
  Range.prototype.getBoundingClientRect ??= () => new DOMRect()
  Blob.prototype.arrayBuffer ??= function (this: Blob) {
    return new Promise<ArrayBuffer>((resolve, reject) => {
      const r = new FileReader()
      r.onload = () => resolve(r.result as ArrayBuffer)
      r.onerror = () => reject(r.error)
      r.readAsArrayBuffer(this)
    })
  }
  window.matchMedia ??= ((q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {}, onchange: null, dispatchEvent: () => false })) as typeof window.matchMedia
  ;(window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      writer: {
        async postMessage(m: { op: string } & Record<string, any>) {
          switch (m.op) {
            case 'writer.dir': return { dir: ROOT }
            case 'writer.host': return { author: 'Max' }
            case 'fs.list': return fs.list(m.path)
            case 'fs.read': return fs.read(m.path)
            case 'fs.write': return fs.write(m.path, m.text)
            case 'fs.mkdir': return fs.mkdir(m.path)
            case 'fs.move': return fs.move(m.from, m.to)
            case 'fs.stat': return (await fs.stat(m.path)) ?? undefined
            case 'fs.copyDir': return fs.copyDir(m.from, m.to, m.skip)
            case 'fs.writeImage': return fs.writeImage(m.path, m.data)
            case 'fs.search': return fs.search(m.query, m.limit)
            case 'agents.list': return []
            default: throw new Error(`Unexpected op ${m.op}`)
          }
        },
      },
    },
  }
})

afterEach(() => {
  document.body.replaceChildren()
  localStorage.clear()
})

const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms))
async function until(fn: () => unknown, what: string) {
  for (let i = 0; i < 100; i++) {
    if (fn()) return
    await tick(20)
  }
  throw new Error(`Timed out waiting for ${what}`)
}

async function openDoc() {
  fs = memoryFS(ROOT, files)
  const page = new WriterPage({ settings: () => ({ folder: '', author: 'Max' }) })
  document.body.append(page.root)
  await page.start()
  await page.openProject('Essay')
  await until(() => page.root.querySelector('.ProseMirror'), 'the editor')
  await tick(50)
  const ed = (page as unknown as { activeEditor: Editor }).activeEditor
  return { page, ed, pm: page.root.querySelector<HTMLElement>('.ProseMirror')! }
}

const key = (target: Element, init: KeyboardEventInit) => target.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init }))
const record = () => (fs.files.get(`${ROOT}/Essay/.writer-record.jsonl`) ?? '').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l))

describe('writing record', () => {
  it('logs typing and pastes, keeps a version on save, and shows it all', async () => {
    const { page, ed } = await openDoc()
    ed.chain().focus('end').splitBlock().insertContent('Waves shape the coast.').run()
    ed.view.dispatch(ed.state.tr.insertText(' Copied from a website.').setMeta('uiEvent', 'paste'))
    await page.flush()

    const lines = record()
    const minute = lines.find((l) => 'minute' in l)
    expect(minute).toMatchObject({ doc: 'Draft/Intro.md', pasted: 23 })
    expect(minute.typed).toBeGreaterThanOrEqual(22)
    expect(minute.words).toBe(17)
    expect(lines.find((l) => 'paste' in l)).toMatchObject({ from: 'outside', text: ' Copied from a website.', words: 4 })

    // The version from before this save was kept (the first save in a while).
    const versions = [...fs.files.keys()].filter((f) => f.includes('/.snapshots/Draft/Intro/'))
    expect(versions).toHaveLength(1)
    expect(fs.files.get(versions[0])).toBe(INTRO)

    // History tab: the record button and the version list.
    ;(page as unknown as { prefs: { inspectorTab: string } }).prefs.inspectorTab = 'history'
    ;(page as unknown as { renderInspector(): void }).renderInspector()
    await until(() => page.root.querySelector('.wr-snap'), 'the version list')
    expect(page.root.querySelector('.wr-snap')!.textContent).toContain('Auto')

    // The record window.
    ;[...page.root.querySelectorAll<HTMLButtonElement>('.wr-btn')].find((b) => b.textContent?.includes('Open writing record'))!.click()
    await until(() => page.root.querySelector('.wr-rec .rec-stats'), 'the record')
    const text = page.root.querySelector('.wr-rec')!.textContent!
    expect(text).toContain('typed by hand')
    expect(text).toContain('Copied from a website.')
    expect(text).toContain('This document')
    page.stop()
  })

  it("counts pasting text you copied in the Writer as moving it, not pasting", async () => {
    const { page, ed, pm } = await openDoc()
    ed.commands.setTextSelection({ from: 1, to: 13 })
    pm.dispatchEvent(new Event('copy', { bubbles: true }))
    ed.view.dispatch(ed.state.tr.insertText('The sea is w', ed.state.doc.content.size - 1).setMeta('uiEvent', 'paste'))
    await page.flush()
    expect(record().find((l) => 'paste' in l)).toMatchObject({ from: 'writer' })
    page.stop()
  })
})

describe('notes to self', () => {
  it('⌥⌘J adds a note block that is saved as a ```note fence', async () => {
    const { page, ed, pm } = await openDoc()
    ed.chain().focus('end').splitBlock().run()
    key(pm, { code: 'KeyJ', key: '∆', metaKey: true, altKey: true })
    ed.commands.insertContent('Check the word limit')
    await page.flush()
    expect(fs.files.get(`${ROOT}/Essay/Draft/Intro.md`)).toBe(`${INTRO}\n\`\`\`note\nCheck the word limit\n\`\`\`\n`)
    await until(() => page.root.querySelector('.md-note .md-note-label'), 'the note label')
    expect(page.root.querySelector('.md-note-label')!.textContent).toContain('not exported')
    page.stop()
  })
})
