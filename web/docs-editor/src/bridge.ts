// The narrow bridge (PRD §17).
//   JS → Swift: ready, dirty, save(text). Swift decides which file the text goes to.
//   Swift → JS: load(raw), takeForSave(), and read-only test hooks.
// The page has no other way to reach files or the network.

interface Handlers {
  load(raw: string): void
  serialize(): string
  serializeWithoutShortcut(): string
  hasSourceMap(): boolean
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { docs?: { postMessage(message: unknown): unknown } } }
    atlantis?: Record<string, unknown>
  }
}

/** Autosave this long after the last edit (a one-shot timer, so idle stays idle). */
const AUTOSAVE_MS = 1500

function post(message: Record<string, unknown>): void {
  window.webkit?.messageHandlers?.docs?.postMessage(message)
}

let handlers: Handlers | null = null
let dirty = false
let autosave: ReturnType<typeof setTimeout> | null = null

function clearAutosave() {
  if (autosave) clearTimeout(autosave)
  autosave = null
}

/** The text to save now; resets the edited state. */
function takeForSave(): string {
  if (!handlers) throw new Error('editor not ready')
  clearAutosave()
  dirty = false
  return handlers.serialize()
}

export const bridge = {
  attach(next: Handlers) {
    handlers = next
    window.atlantis = {
      load: (raw: string) => {
        clearAutosave()
        dirty = false
        next.load(raw)
      },
      takeForSave,
      // Read-only hooks for the round-trip check.
      serialize: () => next.serialize(),
      serializeWithoutShortcut: () => next.serializeWithoutShortcut(),
      hasSourceMap: () => next.hasSourceMap(),
      isDirty: () => dirty,
    }
    post({ type: 'ready' })
  },
  /** Called on every user edit. */
  changed() {
    if (!handlers) return
    if (!dirty) {
      dirty = true
      post({ type: 'dirty' })
    }
    clearAutosave()
    autosave = setTimeout(() => post({ type: 'save', text: takeForSave() }), AUTOSAVE_MS)
  },
}
