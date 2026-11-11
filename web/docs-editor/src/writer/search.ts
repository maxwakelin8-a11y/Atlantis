// Atlantis: search across projects. Swift does the searching (fs.search); this groups what comes
// back for the panel in page.ts.
import type { SearchHit, SearchResult } from "./fs";

export type SearchGroup = {
  /** The project's folder name. */
  project: string;
  /** Its title (the folder name when it has none). */
  title: string;
  hits: Array<SearchHit & { folder: string }>;
};

/** Hits grouped by project (A–Z by title); inside a project, title matches first, then binder order. */
export function groupHits(hits: SearchHit[], projects: Array<{ id: string; title: string }>): SearchGroup[] {
  const titles = new Map(projects.map((p) => [p.id, p.title]));
  const groups = new Map<string, SearchGroup>();
  for (const hit of hits) {
    let g = groups.get(hit.project);
    if (!g) groups.set(hit.project, (g = { project: hit.project, title: titles.get(hit.project) || hit.project, hits: [] }));
    const parts = hit.relPath.split("/");
    g.hits.push({ ...hit, folder: parts.length > 1 ? parts.slice(0, -1).join(" / ") : "" });
  }
  const out = [...groups.values()].sort((a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: "base" }));
  for (const g of out) g.hits.sort((a, b) => Number(b.titleMatches) - Number(a.titleMatches));
  return out;
}

/** "14 matches in 6 documents · 2 projects" (and a note when the list was cut short). */
export function hitSummary(result: SearchResult, groups: SearchGroup[]): string {
  const matches = result.hits.reduce((n, h) => n + Math.max(h.count, h.titleMatches ? 1 : 0), 0);
  const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
  const text = `${plural(matches, "match", "matches")} in ${plural(result.hits.length, "document", "documents")}${groups.length > 1 ? ` · ${groups.length} projects` : ""}`;
  return result.truncated ? `${text} · showing the first ${plural(result.hits.length, "document", "documents")}` : text;
}
