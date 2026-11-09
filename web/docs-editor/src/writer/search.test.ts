// Search across projects: grouping what Swift returns, and the same rules on the in-memory files.
import { describe, expect, it } from 'vitest'
import { memoryFS, type SearchHit } from './fs'
import { groupHits, hitSummary } from './search'

const ROOT = '/Users/x/Writer'
const doc = (project: string, rel: string, text: string) => [`${ROOT}/${project}/${rel}`, text] as const

const hit = (project: string, relPath: string, over: Partial<SearchHit> = {}): SearchHit => ({
  project, path: `${ROOT}/${project}/${relPath}`, relPath, title: relPath, titleMatches: false, count: 1, snippets: [], ...over,
})

describe('groupHits', () => {
  it('groups by project, A–Z by title, title matches first', () => {
    const groups = groupHits(
      [hit('b', 'Draft/One.md'), hit('a', 'Draft/Two.md'), hit('b', 'Notes/Three.md', { titleMatches: true }), hit('c', 'Draft/Four.md')],
      [{ id: 'a', title: 'Zebra essay' }, { id: 'b', title: 'Alpha report' }],
    )
    expect(groups.map((g) => g.title)).toEqual(['Alpha report', 'c', 'Zebra essay']) // 'c' has no title: folder name
    expect(groups[0].hits.map((h) => h.relPath)).toEqual(['Notes/Three.md', 'Draft/One.md'])
    expect(groups[0].hits[0].folder).toBe('Notes')
  })

  it('summarises matches, documents and projects, and says when the list was cut', () => {
    const hits = [hit('a', 'Draft/One.md', { count: 3 }), hit('b', 'Draft/Two.md', { count: 0, titleMatches: true })]
    const result = { hits, truncated: false, scanned: 9 }
    expect(hitSummary(result, groupHits(hits, []))).toBe('4 matches in 2 documents · 2 projects')
    expect(hitSummary({ hits: [hits[0]], truncated: true, scanned: 9 }, groupHits([hits[0]], []))).toBe('3 matches in 1 document · showing the first 1 document')
  })
})

describe('search over files (in-memory version of Swift)', () => {
  const fs = memoryFS(ROOT, Object.fromEntries([
    doc('Essay', 'Draft/Intro.md', '---\ntitle: "Why oceans matter"\nsynopsis: Hook\ncomments: [{"text":"ocean"}]\n---\n\nThe ocean is big.\n\nAn Ocean again.\n'),
    doc('Essay', 'Draft/Plain.md', 'Nothing here.\n'),
    doc('Essay', 'Trash/Old.md', 'ocean in the bin'),
    doc('Essay', 'assets/readme.md', 'ocean in assets'),
    doc('Essay', '.snapshots/x.md', 'ocean snapshot'),
    doc('Speech', 'Notes/Ocean facts.md', 'Salt.\n'),
  ]))

  it('finds title and body text, ignores front matter, trash, assets and snapshots', async () => {
    const r = await fs.search('ocean')
    expect(r.hits.map((h) => [h.project, h.relPath, h.count, h.titleMatches])).toEqual([
      ['Essay', 'Draft/Intro.md', 2, true], // "oceans" in the title; 2 in the body, none from the front matter
      ['Speech', 'Notes/Ocean facts.md', 0, true],
    ])
    expect(r.hits[0].snippets[1]).toMatchObject({ occurrence: 1, match: 'Ocean' })
  })

  it('returns nothing for an empty query', async () => {
    expect(await fs.search('  ')).toEqual({ hits: [], truncated: false, scanned: 0 })
  })

  it('caps the number of documents', async () => {
    const r = await fs.search('o', 1)
    expect(r.hits).toHaveLength(1)
    expect(r.truncated).toBe(true)
  })
})
