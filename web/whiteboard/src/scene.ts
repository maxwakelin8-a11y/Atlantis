// Pure helpers for the whiteboard page: no React, no Excalidraw runtime, so they can be tested.
//
// A board is a standard `.excalidraw` file (JSON). Agents add elements through Atlantis's MCP
// tools (Swift builds them, see WhiteboardScene.swift). Swift can't measure text in Excalidraw's
// fonts, so it marks what it adds with `customData.atlantisLayout`; this page measures those
// once, centres their labels, clears the mark and saves.

export type El = {
  id: string
  type: string
  x: number
  y: number
  width: number
  height: number
  version: number
  versionNonce: number
  updated?: number
  isDeleted?: boolean
  text?: string
  originalText?: string
  fontSize?: number
  fontFamily?: number
  lineHeight?: number
  containerId?: string | null
  points?: [number, number][]
  customData?: Record<string, unknown>
  [key: string]: unknown
}

export const LAYOUT_MARK = 'atlantisLayout'

/** An empty board in the format Excalidraw writes. */
export const EMPTY_BOARD = {
  type: 'excalidraw',
  version: 2,
  source: 'https://excalidraw.com',
  elements: [],
  appState: { gridSize: 20, viewBackgroundColor: '#ffffff' },
  files: {},
}

/** Parses a board file. Empty or whitespace-only text is a new board. */
export function parseBoard(text: string): { elements: El[]; appState: Record<string, unknown>; files: Record<string, unknown> } {
  if (!text.trim()) return { elements: [], appState: { ...EMPTY_BOARD.appState }, files: {} }
  const data = JSON.parse(text)
  if (!data || typeof data !== 'object' || (data.type && data.type !== 'excalidraw')) {
    throw new Error('This file isn\'t an Excalidraw board.')
  }
  return {
    elements: Array.isArray(data.elements) ? data.elements : [],
    appState: data.appState && typeof data.appState === 'object' ? data.appState : {},
    files: data.files && typeof data.files === 'object' ? data.files : {},
  }
}

/**
 * What decides "this board has changed and needs saving": element versions, the background
 * and the attached files. Scrolling, zooming and selecting don't count, so opening a board and
 * looking around never rewrites the file.
 */
export function sceneKey(elements: readonly El[], appState: Record<string, unknown>, files: Record<string, unknown>): string {
  let hash = 5381
  for (const el of elements) {
    hash = ((hash << 5) + hash + el.versionNonce) | 0
    hash = ((hash << 5) + hash + el.version) | 0
  }
  return [elements.length, hash, String(appState.viewBackgroundColor ?? ''), String(appState.gridModeEnabled ?? ''),
    Object.keys(files).sort().join(',')].join('|')
}

export type Measure = (text: string, fontSize: number, fontFamily: number) => number

/** Width and height of a text block, Excalidraw-style (lines × fontSize × lineHeight). */
export function textSize(text: string, fontSize: number, fontFamily: number, lineHeight: number, measure: Measure) {
  const lines = text.split('\n')
  const width = Math.max(1, ...lines.map((line) => measure(line, fontSize, fontFamily)))
  return { width: Math.ceil(width), height: Math.ceil(lines.length * fontSize * lineHeight) }
}

function bump(el: El, changes: Partial<El>, now: number, nonce: () => number): El {
  const customData = { ...(el.customData ?? {}) }
  delete customData[LAYOUT_MARK]
  const next: El = { ...el, ...changes, version: el.version + 1, versionNonce: nonce(), updated: now }
  if (Object.keys(customData).length) next.customData = customData
  else delete next.customData
  return next
}

/**
 * Measures the text of elements marked by Swift and centres labels in their shape (or on their
 * arrow's midpoint). Returns the new element list, or null when nothing was marked.
 */
export function layoutMarked(elements: readonly El[], measure: Measure, now = Date.now(),
                             nonce: () => number = () => Math.floor(Math.random() * 2 ** 31)): El[] | null {
  if (!elements.some((el) => el.customData?.[LAYOUT_MARK])) return null
  const byId = new Map(elements.map((el) => [el.id, el]))
  return elements.map((el) => {
    if (!el.customData?.[LAYOUT_MARK]) return el
    if (el.type !== 'text' || typeof el.text !== 'string') return bump(el, {}, now, nonce)
    const fontSize = el.fontSize ?? 20
    const size = textSize(el.text, fontSize, el.fontFamily ?? 5, el.lineHeight ?? 1.25, measure)
    const container = el.containerId ? byId.get(el.containerId) : undefined
    if (!container) return bump(el, size, now, nonce)
    let cx = container.x + container.width / 2
    let cy = container.y + container.height / 2
    if ((container.type === 'arrow' || container.type === 'line') && container.points?.length) {
      // Excalidraw puts an arrow's label on the middle of its path.
      const pts = container.points
      const mid = pts.length % 2 === 1
        ? pts[(pts.length - 1) / 2]
        : [(pts[pts.length / 2 - 1][0] + pts[pts.length / 2][0]) / 2, (pts[pts.length / 2 - 1][1] + pts[pts.length / 2][1]) / 2]
      cx = container.x + mid[0]
      cy = container.y + mid[1]
    }
    return bump(el, { ...size, x: cx - size.width / 2, y: cy - size.height / 2 }, now, nonce)
  })
}
