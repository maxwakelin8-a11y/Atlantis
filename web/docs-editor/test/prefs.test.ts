// @vitest-environment jsdom
// Saved Writer prefs from before 2026-11-14 get the new defaults once: spelling & grammar on,
// inspector hidden (Google Docs-like). After that the user's own choices stick.
import { afterEach, describe, expect, it } from 'vitest'
import { loadPrefs } from '../src/writer/page'

const KEY = 'bsplus-writer-prefs'

describe('Writer prefs', () => {
  afterEach(() => localStorage.clear())

  it('starts with checks on and the inspector hidden', () => {
    const p = loadPrefs()
    expect(p.proof).toBe(true)
    expect(p.inspector).toBe(false)
  })

  it('turns checks on and hides the inspector once for older saved prefs, keeping the rest', () => {
    localStorage.setItem(KEY, JSON.stringify({ proof: false, inspector: true, zoom: 1.2 }))
    const p = loadPrefs()
    expect(p.proof).toBe(true)
    expect(p.inspector).toBe(false)
    expect(p.zoom).toBe(1.2)
  })

  it("keeps the user's choices after that", () => {
    localStorage.setItem(KEY, JSON.stringify({ proof: false, inspector: true, atlantisPrefs: 2 }))
    const p = loadPrefs()
    expect(p.proof).toBe(false)
    expect(p.inspector).toBe(true)
  })
})
