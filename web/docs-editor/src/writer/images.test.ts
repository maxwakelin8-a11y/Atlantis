// Pasting and dropping images: where they're saved, the link that goes in the doc, and the
// Swift-side rules mirrored by the in-memory file system.
import { afterEach, describe, expect, it } from 'vitest'
import { memoryFS } from './fs'
import { IMAGE_ERROR_EVENT, imageLink, imageName, installImageBridge, saveImage, setImageTarget } from './images'
import { createWriterStore } from './store'

const ROOT = '/Users/x/Writer'
const PROJECT = `${ROOT}/Essay`
const AT = new Date(2026, 10, 9, 14, 5, 7) // 9 Nov 2026, 14:05:07 local

afterEach(() => setImageTarget(null))

describe('image names and links', () => {
  it('names images by local date and time', () => {
    expect(imageName('png', AT)).toBe('image-20261109-140507.png')
  })

  it('links relative to the doc, whatever its depth', () => {
    expect(imageLink(`${PROJECT}/Intro.md`, `${PROJECT}/assets/a.png`)).toBe('assets/a.png')
    expect(imageLink(`${PROJECT}/Draft/Intro.md`, `${PROJECT}/assets/a.png`)).toBe('../assets/a.png')
    expect(imageLink(`${PROJECT}/Draft/Part 1/Intro.md`, `${PROJECT}/assets/a.png`)).toBe('../../assets/a.png')
  })
})

describe('saving a pasted image', () => {
  const target = { projectDir: PROJECT, docFile: `${PROJECT}/Draft/Intro.md` }

  it('writes into the project assets folder and returns the doc-relative link', async () => {
    const fs = memoryFS(ROOT, { [`${PROJECT}/Draft/Intro.md`]: 'Hi\n' })
    const link = await saveImage(fs, target, 'AAAA', 'png', AT)
    expect(link).toBe('../assets/image-20261109-140507.png')
    expect(fs.files.get(`${PROJECT}/assets/image-20261109-140507.png`)).toBe('image:AAAA')
  })

  it('never overwrites: a second image in the same second gets a number', async () => {
    const fs = memoryFS(ROOT)
    const a = await saveImage(fs, target, 'AAAA', 'png', AT)
    const b = await saveImage(fs, target, 'BBBB', 'png', AT)
    const c = await saveImage(fs, target, 'CCCC', 'jpg', AT)
    expect([a, b, c]).toEqual(['../assets/image-20261109-140507.png', '../assets/image-20261109-140507-2.png', '../assets/image-20261109-140507.jpg'])
    expect(fs.files.get(`${PROJECT}/assets/image-20261109-140507.png`)).toBe('image:AAAA')
  })

  it('refuses other types before anything is written', async () => {
    const fs = memoryFS(ROOT)
    await expect(saveImage(fs, target, 'AAAA', 'heic', AT)).rejects.toThrow(/\.heic/)
    await expect(saveImage(fs, target, 'AAAA', 'svg', AT)).rejects.toThrow(/\.svg/)
    expect(fs.writes).toEqual([])
  })

  it('the file system only takes images inside <project>/assets (as Swift does)', async () => {
    const fs = memoryFS(ROOT)
    await expect(fs.writeImage(`${PROJECT}/Draft/a.png`, 'AAAA')).rejects.toThrow(/assets/)
    await expect(fs.writeImage(`${ROOT}/assets/a.png`, 'AAAA')).rejects.toThrow(/assets/)
    await expect(fs.writeImage(`${PROJECT}/assets/a.sh`, 'AAAA')).rejects.toThrow(/assets/)
    await expect(fs.writeImage(`/tmp/Essay/assets/a.png`, 'AAAA')).rejects.toThrow(/assets/)
    await fs.writeImage(`${PROJECT}/assets/a.png`, 'AAAA')
    await expect(fs.writeImage(`${PROJECT}/assets/a.png`, 'BBBB')).rejects.toThrow(/already/)
  })
})

describe('window.markdownApi.saveImage (what GenOffice calls on paste and drop)', () => {
  const api = () => (window as unknown as { markdownApi: { saveImage: (a: { base64: string; ext: string }) => Promise<string | null>; getImageHost: () => Promise<unknown> } }).markdownApi

  it('saves for the open doc, and has no image host', async () => {
    const fs = memoryFS(ROOT)
    installImageBridge(fs)
    setImageTarget({ projectDir: PROJECT, docFile: `${PROJECT}/Draft/Intro.md` })
    const link = await api().saveImage({ base64: 'AAAA', ext: 'png' })
    expect(link).toMatch(/^\.\.\/assets\/image-\d{8}-\d{6}\.png$/)
    expect(await api().getImageHost()).toBeNull()
  })

  it('returns null with no open doc, and reports errors instead of throwing', async () => {
    const fs = memoryFS(ROOT)
    installImageBridge(fs)
    expect(await api().saveImage({ base64: 'AAAA', ext: 'png' })).toBeNull()
    setImageTarget({ projectDir: PROJECT, docFile: `${PROJECT}/Draft/Intro.md` })
    const seen: string[] = []
    const on = (e: Event) => seen.push((e as CustomEvent<string>).detail)
    window.addEventListener(IMAGE_ERROR_EVENT, on)
    expect(await api().saveImage({ base64: 'AAAA', ext: 'tiff' })).toBeNull()
    window.removeEventListener(IMAGE_ERROR_EVENT, on)
    expect(seen).toEqual(["Docs can't save .tiff images."])
  })
})

describe('the assets folder in a project', () => {
  it("isn't a binder folder, and its images aren't docs", async () => {
    const fs = memoryFS(ROOT, {
      [`${PROJECT}/Draft/Intro.md`]: 'Hi\n![](../assets/a.png)\n',
      [`${PROJECT}/assets/a.png`]: 'image:AAAA',
      [`${PROJECT}/assets/notes.md`]: 'not a doc',
    })
    const p = await createWriterStore(fs).open({ project: 'Essay' })
    expect(p.tree.map((n: { path: string }) => n.path)).toEqual(['Draft', 'Research', 'Notes', 'Trash'])
  })
})
