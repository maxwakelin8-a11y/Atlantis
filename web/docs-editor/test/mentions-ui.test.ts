// Atlantis M6: @mentioning a bot in a doc. Typing @ lists the bots, the mention stays plain
// Markdown text, and ⌘↩ (or the chip) sends the request through the narrow `agents.ask` op.
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { memoryFS } from '../src/writer/fs'
import { setEnglish } from '../src/locale'
import { WriterPage } from '../src/writer/page'
import type { Editor } from '@tiptap/core'

const ROOT = '/Users/x/Writer'
const files = {
  [`${ROOT}/Essay/.writer.json`]: '{"title":"Ocean essay"}\n',
  [`${ROOT}/Essay/Draft/Intro.md`]: '---\ntitle: Intro\n---\n\nThe sea is wide. The OCEAN is deep.\n\nAn ocean again.\n',
  [`${ROOT}/Essay/Draft/Plain.md`]: 'Nothing here.\n',
  [`${ROOT}/Speech/.writer.json`]: '{"title":"Class speech"}\n',
  [`${ROOT}/Speech/Draft/Opening.md`]: 'Good morning. The ocean calls us.\n',
}
let fs = memoryFS(ROOT, files)
const calls: string[] = []
const asks: { bot: string; path: string; request: string }[] = []

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
          calls.push(m.op)
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
            case 'agents.list': return [{ id: 'school', name: 'School', avatar: '🎓' }, { id: 'builder', name: 'Builder', avatar: '🛠️' }]
            case 'agents.ask': asks.push({ bot: m.bot, path: m.path, request: m.request }); return { message: 'Asked School. The answer will land in your Inbox.' }
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

async function openPage() {
  fs = memoryFS(ROOT, files)
  calls.length = 0
  asks.length = 0
  const page = new WriterPage({ settings: () => ({ folder: '', author: 'Max' }) })
  document.body.append(page.root)
  await page.start()
  return page
}

const key = (target: Element, init: KeyboardEventInit) => target.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init }))

describe('@mentions', () => {
  it('lists bots on @, writes a plain @mention and asks with ⌘↩', async () => {
    const page = await openPage()
    await page.openProject('Essay')
    await until(() => page.root.querySelector('.ProseMirror'), 'the editor')
    await tick(50) // the page focuses the doc's start once it opens
    const pm = page.root.querySelector<HTMLElement>('.ProseMirror')!
    const ed = (page as unknown as { activeEditor: Editor }).activeEditor
    ed.chain().focus('end').splitBlock().run()
    key(pm, { key: '@' })
    ed.commands.insertContent('@')
    await until(() => page.root.querySelector('.wr-mention'), 'the mention popup')
    expect([...page.root.querySelectorAll('.wr-mention .wr-menu-label')].map((e) => e.textContent)).toEqual(['School', 'Builder'])
    ed.commands.insertContent('sc')
    await until(() => page.root.querySelectorAll('.wr-mention .wr-menu-item').length === 1, 'the filtered list')
    key(pm, { key: 'Enter' })
    expect(page.root.querySelector('.wr-mention')).toBeNull()
    ed.commands.insertContent('tighten the intro')
    await until(() => page.root.querySelector('.wr-ask-chip'), 'the ask chip')
    expect(page.root.querySelector('.wr-ask-chip')!.textContent).toContain('Ask School')
    key(pm, { key: 'Enter', metaKey: true })
    await until(() => asks.length === 1, 'the ask')
    expect(asks[0]).toEqual({ bot: 'school', path: `${ROOT}/Essay/Draft/Intro.md`, request: 'tighten the intro' })
    // Saved first, as plain text: the mention is just Markdown.
    expect(fs.files.get(`${ROOT}/Essay/Draft/Intro.md`)).toContain('\n\n@school tighten the intro')
    await until(() => page.root.querySelector('.wr-toast')?.textContent?.includes('Inbox'), 'the toast')
    page.stop()
  })

  it('shows no chip for unknown bots or emails, and asks nothing without ⌘↩', async () => {
    const page = await openPage()
    await page.openProject('Essay')
    await until(() => page.root.querySelector('.ProseMirror'), 'the editor')
    await tick(50)
    const ed = (page as unknown as { activeEditor: Editor }).activeEditor
    ed.chain().focus('end').splitBlock().insertContent('mail me@school about @scout things').run()
    await tick(100)
    expect(page.root.querySelector('.wr-ask-chip')).toBeNull()
    expect(asks).toHaveLength(0)
    page.stop()
  })
})
