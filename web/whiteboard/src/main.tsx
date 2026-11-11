// The Whiteboard page: Excalidraw (MIT) showing one board at a time.
//
// The page never names files. Swift decides which board is open, hands its text in with
// `window.atlantisBoard.open`, and saves whatever the page sends back to that same board only
// (the "board" message handler, WhiteboardController.swift). A save is refused if the file changed
// on disk since the page last saw it; the page then merges the newer file in and saves again.
import './assets'
import '@excalidraw/excalidraw/index.css'
import { CaptureUpdateAction, Excalidraw, FONT_FAMILY, MainMenu, reconcileElements, restore, serializeAsJSON } from '@excalidraw/excalidraw'
import { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { type El, LAYOUT_MARK, layoutMarked, parseBoard, sceneKey } from './scene'

type Board = { token: string; name: string; text: string }
type Reply = { ok?: boolean; conflict?: boolean; text?: string } | null | undefined
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type API = any

const handler = (window as unknown as { webkit?: { messageHandlers?: { board?: { postMessage(m: unknown): Promise<unknown> } } } })
  .webkit?.messageHandlers?.board
const post = async (message: Record<string, unknown>): Promise<Reply> => (handler ? (await handler.postMessage(message)) as Reply : null)

/** Page problems go to the app's log (Console.app, subsystem au.lifeos.atlantis). */
const report = (where: string, error: unknown) => {
  void post({ op: 'log', message: `${where}: ${error instanceof Error ? `${error.message}\n${error.stack ?? ''}` : String(error)}` }).catch(() => {})
}
window.addEventListener('error', (e) => report('error', e.error ?? e.message))
window.addEventListener('unhandledrejection', (e) => report('promise', e.reason))

// MARK: Session (one open board)

const session = {
  token: '',
  api: null as API,
  savedKey: '',
  timer: 0 as ReturnType<typeof setTimeout> | 0,
  chain: Promise.resolve() as Promise<void>,
  ready: false,
}

const current = () => {
  const api = session.api
  return { elements: api.getSceneElementsIncludingDeleted() as El[], appState: api.getAppState(), files: api.getFiles() }
}
const keyNow = () => {
  const { elements, appState, files } = current()
  return sceneKey(elements, appState, files)
}

function scheduleSave(delay = 700) {
  if (session.timer) clearTimeout(session.timer)
  session.timer = setTimeout(() => { session.timer = 0; void enqueueSave() }, delay)
}

/** Saves run one at a time, in order. */
function enqueueSave(): Promise<void> {
  session.chain = session.chain.then(saveNow, saveNow)
  return session.chain
}

async function saveNow(): Promise<void> {
  const token = session.token
  for (let attempt = 0; attempt < 3; attempt++) {
    if (!session.api || !session.ready || session.token !== token) return
    const key = keyNow()
    if (key === session.savedKey) return
    const { elements, appState, files } = current()
    const text = serializeAsJSON(elements, appState, files, 'local')
    let reply: Reply
    try {
      reply = await post({ op: 'save', token, text })
    } catch (error) {
      session.api?.setToast({ message: `Couldn't save: ${(error as Error).message}`, closable: true, duration: 6000 })
      return
    }
    if (reply?.conflict && typeof reply.text === 'string') {
      // Someone else (an agent, another app) changed the file: take their changes, then try again.
      mergeText(reply.text)
      continue
    }
    session.savedKey = key
    return
  }
}

/** Waits for Excalidraw's own font, so measured text matches what's drawn. */
async function fontsReady() {
  try {
    await Promise.race([document.fonts.load('20px Excalifont'), new Promise((r) => setTimeout(r, 2000))])
  } catch { /* measure with whatever font is there */ }
}

const fontNames = Object.fromEntries(Object.entries(FONT_FAMILY).map(([name, id]) => [id, name])) as Record<number, string>
const canvas = document.createElement('canvas').getContext('2d')
function measure(text: string, fontSize: number, fontFamily: number) {
  if (!canvas) return text.length * fontSize * 0.55
  canvas.font = `${fontSize}px ${fontNames[fontFamily] ?? 'Excalifont'}, Xiaolai, Segoe UI Emoji`
  return canvas.measureText(text).width
}

/** Lays out anything an agent added (marked by Swift), which then saves. */
async function layoutAgentElements() {
  try { await layoutNow() } catch (error) { report('layout', error) }
}

async function layoutNow() {
  if (!session.api) return
  if (!current().elements.some((el) => el.customData?.[LAYOUT_MARK])) return
  await fontsReady()
  const next = layoutMarked(current().elements, measure)
  if (!next) return
  session.api.updateScene({ elements: next, captureUpdate: CaptureUpdateAction.NEVER })
  scheduleSave(100)
}

/** Brings a newer copy of the file into the open board, keeping local edits (newest version wins per element). */
function mergeText(text: string) {
  const api = session.api
  if (!api) return
  const wasDirty = keyNow() !== session.savedKey
  const remote = restore(parseBoard(text) as never, null, null)
  const files = Object.values(remote.files ?? {})
  if (files.length) api.addFiles(files)
  const merged = reconcileElements(api.getSceneElementsIncludingDeleted(), remote.elements as never, api.getAppState())
  api.updateScene({ elements: merged, captureUpdate: CaptureUpdateAction.NEVER })
  if (!wasDirty) session.savedKey = keyNow()
  else scheduleSave()
  void layoutAgentElements()
}

// MARK: Swift → page

let setBoard: (board: { token: string; name: string; initial: unknown } | null, error?: string) => void = () => {}

const atlantisBoard = {
  /** Shows a board. Saves the open one first. */
  async open(board: Board | null) {
    await atlantisBoard.flush()
    session.ready = false
    session.api = null
    session.token = board?.token ?? ''
    if (!board) { setBoard(null); return }
    try {
      const restored = restore(parseBoard(board.text) as never, null, null)
      session.savedKey = sceneKey(restored.elements as unknown as El[], restored.appState as never, restored.files ?? {})
      setBoard({ token: board.token, name: board.name,
                 initial: { ...restored, appState: { ...restored.appState, name: board.name }, scrollToContent: true } })
    } catch (error) {
      setBoard(null, `${board.name} couldn't be opened: ${(error as Error).message}`)
    }
  },
  /** The file changed on disk (an agent drew on it, or another app saved it). */
  merge(update: Board) {
    if (update.token !== session.token || !session.api) return
    try { mergeText(update.text) } catch { /* a half-written file: the next save conflict brings it in */ }
  },
  /** Saves now (before switching board or quitting). */
  async flush() {
    if (session.timer) { clearTimeout(session.timer); session.timer = 0 }
    if (session.api && session.ready) await enqueueSave()
    else await session.chain
  },
}
;(window as unknown as { atlantisBoard: typeof atlantisBoard }).atlantisBoard = atlantisBoard

// MARK: Page

const prefersDark = window.matchMedia('(prefers-color-scheme: dark)')

function App() {
  const [board, setState] = useState<{ token: string; name: string; initial: unknown } | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [dark, setDark] = useState(prefersDark.matches)

  useEffect(() => {
    setBoard = (next, error) => { setState(next); setProblem(error ?? null) }
    const onScheme = (e: MediaQueryListEvent) => setDark(e.matches)
    prefersDark.addEventListener('change', onScheme)
    void post({ op: 'ready' })
    return () => prefersDark.removeEventListener('change', onScheme)
  }, [])

  if (!board) {
    return <div className={`empty${dark ? ' dark' : ''}`}>{problem ?? ''}</div>
  }
  return (
    <Excalidraw
      key={board.token}
      initialData={board.initial as never}
      excalidrawAPI={(api: API) => {
        if (session.token !== board.token) return
        session.api = api
        // savedKey was taken from the restored file in open(), so a board that's only looked at
        // is never written. Anything that really changes it (including Excalidraw's own font
        // fixes, or laying out an agent's drawing) gets saved.
        // A timer, not requestAnimationFrame: WebKit pauses frames while the window is covered.
        // Excalidraw loads initialData asynchronously: wait (briefly) until it's in.
        let tries = 0
        const start = () => {
          if (session.token !== board.token) return
          if (api.getAppState().isLoading && tries++ < 60) { setTimeout(start, 50); return }
          session.ready = true
          // Show the whole board, never zoomed in past 100%.
          if (api.getSceneElements().length) api.scrollToContent(undefined, { fitToContent: true, animate: false })
          void layoutAgentElements()
        }
        setTimeout(start, 0)
      }}
      onChange={(elements: readonly El[], appState: Record<string, unknown>, files: Record<string, unknown>) => {
        if (!session.ready || session.token !== board.token) return
        if (sceneKey(elements, appState, files) !== session.savedKey) scheduleSave()
      }}
      onLinkOpen={(element: { link?: string | null }, event: { preventDefault(): void }) => {
        event.preventDefault()
        if (element.link) void post({ op: 'openLink', url: element.link })
      }}
      theme={dark ? 'dark' : 'light'}
      name={board.name}
      langCode="en"
      aiEnabled={false}
      autoFocus
      UIOptions={{
        canvasActions: { loadScene: false, saveToActiveFile: false, export: false, toggleTheme: null, saveAsImage: true },
        tools: { image: true },
      }}
    >
      <MainMenu>
        <MainMenu.DefaultItems.SaveAsImage />
        <MainMenu.DefaultItems.SearchMenu />
        <MainMenu.DefaultItems.CommandPalette />
        <MainMenu.DefaultItems.Help />
        <MainMenu.DefaultItems.ClearCanvas />
        <MainMenu.Separator />
        <MainMenu.DefaultItems.ChangeCanvasBackground />
      </MainMenu>
    </Excalidraw>
  )
}

const style = document.createElement('style')
style.textContent = `.empty{height:100%;display:flex;align-items:center;justify-content:center;font:13px -apple-system,system-ui;color:#6b6b6b;background:#fff}
.empty.dark{background:#121212;color:#9a9a9a}`
document.head.append(style)
// No StrictMode: its double mount hands `excalidrawAPI` an instance that's thrown away.
createRoot(document.getElementById('root')!).render(<App />)
