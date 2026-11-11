// The Writer page end to end in jsdom, with the Swift bridge replaced by in-memory files:
// ⌘⇧F search across projects, opening a result at its match, and pasting an image.
import { afterEach, beforeAll, describe, expect, it } from 'vitest'
import { memoryFS } from '../src/writer/fs'
import { setEnglish } from '../src/locale'
import { WriterPage } from '../src/writer/page'

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
  const page = new WriterPage({ settings: () => ({ folder: '', author: 'Max' }) })
  document.body.append(page.root)
  await page.start()
  return page
}

const key = (target: Element, init: KeyboardEventInit) => target.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, ...init }))

describe('search across projects (⌘⇧F)', () => {
  it('opens from the project list, groups by project and shows the match highlighted', async () => {
    const page = await openPage()
    const home = page.root.querySelector('.wr-home')!
    expect(home).toBeTruthy()
    key(home, { code: 'KeyF', key: 'F', metaKey: true, shiftKey: true })
    const input = page.root.querySelector<HTMLInputElement>('.wr-gsearch-input')!
    expect(input).toBeTruthy()
    input.value = 'ocean'
    input.dispatchEvent(new Event('input'))
    await until(() => page.root.querySelector('.wr-gsearch-hit'), 'results')
    const groups = [...page.root.querySelectorAll('.wr-gsearch-list .wr-palette-group')].map((g) => g.textContent)
    expect(groups).toEqual(['Class speech', 'Ocean essay'])
    const hits = [...page.root.querySelectorAll('.wr-gsearch-hit')]
    expect(hits).toHaveLength(2)
    const marks = [...hits[1].querySelectorAll('.wr-gsearch-snippet mark')].map((m) => m.textContent)
    expect(marks).toEqual(['OCEAN', 'ocean']) // as written in the file
    expect(page.root.querySelector('.wr-gsearch-status')!.textContent).toBe('3 matches in 2 documents · 2 projects')
    expect(hits[1].textContent).toContain('2 matches')
    page.stop()
  })

  it('opens the doc at the clicked match with the find bar on that match', async () => {
    const page = await openPage()
    page.openSearchAll()
    const input = page.root.querySelector<HTMLInputElement>('.wr-gsearch-input')!
    input.value = 'ocean'
    input.dispatchEvent(new Event('input'))
    await until(() => page.root.querySelector('.wr-gsearch-hit'), 'results')
    const second = page.root.querySelectorAll<HTMLElement>('.wr-gsearch-hit')[1].querySelectorAll<HTMLElement>('.wr-gsearch-snippet')[1]
    second.click()
    await until(() => page.root.querySelector('.wr-findbar'), 'the find bar')
    expect(page.root.querySelector('.wr-gsearch-input')).toBeNull() // panel closed
    expect(page.root.querySelector('.wr-proj-btn-title')!.textContent).toBe('Ocean essay')
    await until(() => page.root.querySelector('.wr-find-count')?.textContent === '2 of 2', 'the second match')
    expect(page.root.querySelector<HTMLInputElement>('.wr-find-input')!.value).toBe('ocean')
    expect(page.root.querySelector('.wr-path-here')!.textContent).toContain('Intro')
    page.stop()
  })

  it('Enter opens the highlighted result; Escape closes; nothing is searched until you type', async () => {
    const page = await openPage()
    page.openSearchAll()
    await tick(300)
    expect(calls).not.toContain('fs.search')
    const input = page.root.querySelector<HTMLInputElement>('.wr-gsearch-input')!
    input.value = 'speech'
    input.dispatchEvent(new Event('input'))
    await tick(300)
    expect(page.root.querySelector('.wr-gsearch-hit')).toBeNull() // "speech" is only in a project title, not in any doc
    expect(page.root.querySelector('.wr-gsearch-status')!.textContent).toBe('No matches.')
    input.value = 'good morning'
    input.dispatchEvent(new Event('input'))
    await until(() => page.root.querySelector('.wr-gsearch-hit'), 'results')
    key(input, { key: 'Enter' })
    await until(() => page.root.querySelector('.wr-find-count'), 'the find bar')
    expect(page.root.querySelector('.wr-proj-btn-title')!.textContent).toBe('Class speech')
    page.openSearchAll()
    key(page.root.querySelector('.wr-gsearch-input')!, { key: 'Escape' })
    expect(page.root.querySelector('.wr-gsearch-input')).toBeNull()
    page.stop()
  })

  it('Focus mode moved to ⌘⇧D', async () => {
    const page = await openPage()
    await page.openProject('Essay')
    key(page.root.querySelector('.wr-body')!, { code: 'KeyD', key: 'D', metaKey: true, shiftKey: true })
    expect(page.root.classList.contains('is-compose')).toBe(true)
    page.stop()
  })
})

describe('pasting an image into a doc', () => {
  it('saves it in the project assets folder and puts a relative link in the doc', async () => {
    const page = await openPage()
    await page.openProject('Essay')
    await until(() => page.root.querySelector('.ProseMirror'), 'the editor')
    const pm = page.root.querySelector<HTMLElement>('.ProseMirror')!
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
    const file = new File([bytes], 'screenshot.png', { type: 'image/png' })
    const paste = new Event('paste', { bubbles: true, cancelable: true })
    Object.defineProperty(paste, 'clipboardData', { value: { files: [file], items: [], types: ['Files'], getData: () => '' } })
    pm.dispatchEvent(paste)
    await until(() => [...fs.files.keys()].some((f) => f.startsWith(`${ROOT}/Essay/assets/image-`)), 'the image file')
    const saved = [...fs.files.keys()].find((f) => f.startsWith(`${ROOT}/Essay/assets/image-`))!
    expect(saved).toMatch(/\/assets\/image-\d{8}-\d{6}\.png$/)
    expect(fs.files.get(saved)).toBe(`image:${btoa(String.fromCharCode(...bytes))}`)
    await until(() => pm.querySelector('img[alt="screenshot"]'), 'the image in the editor')
    // Shown through the md-asset scheme (Swift serves it); the doc's own link stays relative.
    expect(pm.querySelector('img[alt="screenshot"]')!.getAttribute('src')).toBe(`md-asset://${ROOT}/Essay/Draft/../assets/${saved.split('/').pop()}`)
    await page.flush()
    await until(() => fs.files.get(`${ROOT}/Essay/Draft/Intro.md`)?.includes('!['), 'the doc to save')
    expect(fs.files.get(`${ROOT}/Essay/Draft/Intro.md`)).toContain(`![screenshot](../assets/${saved.split('/').pop()})`)
    page.stop()
  })
})
