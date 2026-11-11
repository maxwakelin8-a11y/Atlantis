import { describe, expect, it } from 'vitest'
import { type El, LAYOUT_MARK, layoutMarked, parseBoard, sceneKey, textSize } from '../src/scene'

const base = (over: Partial<El>): El => ({ id: 'a', type: 'rectangle', x: 0, y: 0, width: 100, height: 50, version: 1, versionNonce: 1, ...over })
const measure = (text: string, fontSize: number) => text.length * fontSize * 0.5

describe('parseBoard', () => {
  it('treats empty text as a new board', () => {
    expect(parseBoard('  ').elements).toEqual([])
  })
  it('refuses other JSON', () => {
    expect(() => parseBoard('{"type":"excalidrawlib"}')).toThrow()
  })
  it('reads elements, appState and files', () => {
    const board = parseBoard(JSON.stringify({ type: 'excalidraw', elements: [base({})], appState: { viewBackgroundColor: '#000' }, files: {} }))
    expect(board.elements).toHaveLength(1)
    expect(board.appState.viewBackgroundColor).toBe('#000')
  })
})

describe('sceneKey', () => {
  it('ignores viewport changes but sees edits', () => {
    const els = [base({})]
    const a = sceneKey(els, { viewBackgroundColor: '#fff', scrollX: 0, zoom: 1 }, {})
    expect(sceneKey(els, { viewBackgroundColor: '#fff', scrollX: 500, zoom: 2 }, {})).toBe(a)
    expect(sceneKey([base({ version: 2, versionNonce: 9 })], { viewBackgroundColor: '#fff' }, {})).not.toBe(a)
    expect(sceneKey(els, { viewBackgroundColor: '#000' }, {})).not.toBe(a)
    expect(sceneKey(els, { viewBackgroundColor: '#fff' }, { f1: {} })).not.toBe(a)
  })
})

describe('layoutMarked', () => {
  it('returns null when nothing is marked', () => {
    expect(layoutMarked([base({})], measure)).toBeNull()
  })

  it('measures marked text and centres a label in its shape', () => {
    const box = base({ id: 'box', x: 100, y: 100, width: 200, height: 100, customData: { [LAYOUT_MARK]: true } })
    const label = base({ id: 'label', type: 'text', text: 'Hello', fontSize: 20, lineHeight: 1.25, containerId: 'box', x: 0, y: 0, width: 1, height: 1, customData: { [LAYOUT_MARK]: true, keep: 1 } })
    const out = layoutMarked([box, label], measure, 42, () => 7)!
    const text = out.find((e) => e.id === 'label')!
    expect(text.width).toBe(50)
    expect(text.height).toBe(25)
    expect(text.x).toBe(175)
    expect(text.y).toBe(137.5)
    expect(text.version).toBe(2)
    expect(text.versionNonce).toBe(7)
    expect(text.customData).toEqual({ keep: 1 })
    expect(out.find((e) => e.id === 'box')!.customData).toBeUndefined()
  })

  it('puts an arrow label on the middle of the arrow', () => {
    const arrow = base({ id: 'ar', type: 'arrow', x: 10, y: 10, points: [[0, 0], [100, 0]], customData: { [LAYOUT_MARK]: true } })
    const label = base({ id: 't', type: 'text', text: 'go', fontSize: 20, containerId: 'ar', customData: { [LAYOUT_MARK]: true } })
    const text = layoutMarked([arrow, label], measure)!.find((e) => e.id === 't')!
    expect(text.x + text.width / 2).toBe(60)
    expect(text.y + text.height / 2).toBe(10)
  })

  it('leaves unmarked elements untouched', () => {
    const mine = base({ id: 'mine' })
    const out = layoutMarked([mine, base({ id: 'x', customData: { [LAYOUT_MARK]: true } })], measure)!
    expect(out[0]).toBe(mine)
  })

  it('sizes multi-line text by its longest line', () => {
    expect(textSize('ab\nabcd', 20, 5, 1.25, measure)).toEqual({ width: 40, height: 50 })
  })
})
