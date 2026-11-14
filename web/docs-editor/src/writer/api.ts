import { call, swiftFS, type SearchResult, type WriterFS } from "./fs";
import { installImageBridge } from "./images"; // Atlantis
import { createWriterStore } from "./store";
import type { CiteStyle, Reference } from "./cite";
import type { ProofIssue } from "./proofread";

/**
 * Writer's file operations. Projects are folders of Markdown files on this Mac (default iCloud
 * Drive/Writer). In BetterSEQTA+ these went to seqta-mcp; in Atlantis the same store code
 * (store.ts) runs in the page and reaches the files through Swift (fs.ts).
 */

export type Role = "draft" | "research" | "notes" | "trash";

export type DocMeta = {
  title?: string;
  synopsis?: string;
  status?: string;
  label?: string;
  /** false = left out of exports. */
  compile?: boolean;
  target?: number;
  notes?: string;
  /** JSON list of comments (see plugins.ts Comment), kept out of the body and out of exports. */
  comments?: string;
  created?: string;
};

export type BinderNode = {
  path: string;
  kind: "doc" | "folder";
  role?: Role;
  title: string;
  meta: DocMeta;
  body?: string;
  mtime?: number;
  children?: BinderNode[];
};

export type ProjectSettings = {
  /** Words for the whole Draft. */
  target?: number;
  deadline?: string;
  author?: string;
  subject?: string;
  teacher?: string;
  school?: string;
  template?: string;
  /** Words to write each day (shown as "+N today" in the footer). */
  daily?: number;
  /** Reference maker: chosen style and every reference added (so the list can be re-styled). */
  citeStyle?: CiteStyle;
  references?: Reference[];
  /** Last export choices. */
  export?: Partial<ExportOptionsStored>;
};

export type ExportOptionsStored = {
  format: ExportFormat;
  preset: string;
  titlePage: boolean;
  sectionTitles: boolean;
  pageNumbers: boolean;
  wordCount: boolean;
};

export type ExportFormat = "docx" | "pdf" | "md" | "html" | "rtf" | "odt" | "txt";

export type Project = {
  id: string;
  dir: string;
  title: string;
  settings: ProjectSettings;
  tree: BinderNode[];
};

export type ProjectSummary = {
  id: string;
  title: string;
  settings: ProjectSettings;
  updated: string | null;
  isProject: boolean;
};

export type NewItem = { path: string; kind: "doc" | "folder"; meta?: DocMeta; body?: string };

export type Snapshot = { id: string; at: string | null; name: string; body: string; words: number };

type Store = ReturnType<typeof createWriterStore>;
let store: Store | null = null;
const st = (): Store => {
  if (!store) throw new Error("The Writer folder isn't open yet.");
  return store;
};

/** For tests: run the Writer against other files. */
export function useWriterFS(fs: WriterFS): void {
  store = createWriterStore(fs);
}

const LATER = "This needs Claude, which comes to Atlantis in a later step.";

export const writerApi = {
  setDir: async (_dir: string) => {
    const { dir } = await call<{ dir: string }>("writer.dir");
    const files = swiftFS(dir);
    store = createWriterStore(files);
    installImageBridge(files); // Atlantis: pasted images are saved through Swift too
    return { dir };
  },
  projects: () => st().projects() as Promise<{ dir: string; projects: ProjectSummary[] }>,
  create: (title: string, items: NewItem[], settings: ProjectSettings) => st().create({ title, items, settings }) as Promise<Project>,
  open: (project: string) => st().open({ project }) as Promise<Project>,
  save: (project: string, path: string, meta: DocMeta, body: string) =>
    st().save({ project, path, meta, body }) as Promise<{ path: string; mtime: number; words: number }>,
  add: (
    project: string,
    input: { parent: string; kind: "doc" | "folder"; title: string; index?: number; meta?: DocMeta; body?: string },
  ) => st().add({ project, ...input }) as Promise<{ path: string }>,
  rename: (project: string, path: string, title: string) => st().rename({ project, path, title }) as Promise<{ path: string }>,
  move: (project: string, path: string, parent: string, index: number) =>
    st().move({ project, path, parent, index }) as Promise<{ path: string }>,
  trash: (project: string, path: string) => st().trash({ project, path }) as Promise<{ path?: string }>,
  emptyTrash: (project: string) => st().emptyTrash({ project }) as Promise<{ moved: number }>,
  folderMeta: (project: string, path: string, meta: DocMeta) => st().setFolderMeta({ project, path, meta }) as Promise<{ path: string }>,
  settings: (project: string, patch: { title?: string; settings?: ProjectSettings }) =>
    st().settings({ project, ...patch }) as Promise<{ title: string; settings: ProjectSettings }>,
  snapshot: (project: string, path: string, name: string, auto = false) =>
    st().snapshot({ project, path, name, auto }) as Promise<{ id: string; at: string; skipped?: boolean }>,
  snapshots: (project: string, path: string) =>
    (st().snapshots({ project, path }) as Promise<{ snapshots: Snapshot[] }>).then((r) => r.snapshots),
  deleteSnapshot: (project: string, path: string, id: string) => st().deleteSnapshot({ project, path, id }) as Promise<{ removed: true }>,
  /** Atlantis: the writing record (record.ts). */
  recordRead: (project: string) => (st().recordRead({ project }) as Promise<{ text: string }>).then((r) => r.text),
  recordAppend: (project: string, lines: unknown[]) => st().recordAppend({ project, lines }) as Promise<{ written: number }>,
  removeProject: (project: string) => st().removeProject({ project }) as Promise<{ removed: true }>,
  duplicateProject: (project: string) => st().duplicateProject({ project }) as Promise<{ id: string }>,
  export: (
    project: string,
    input: { name: string; format: ExportFormat; html?: string; markdown?: string; text?: string },
  ) => st().export({ project, ...input }) as Promise<{ path: string; name: string }>,
  openFile: (path: string, reveal = false) => st().open_file({ path, reveal }) as Promise<{ opened: true }>,
  cite: async (_url: string, _ai = true): Promise<Reference & { aiFields?: string[]; via?: string }> => {
    throw new Error(`Reading a web page for a reference: ${LATER} For now, fill in the fields yourself.`);
  },
  /** Atlantis: spelling & grammar by the Mac's own checker (Swift, NSSpellChecker); nothing leaves the Mac. */
  proofread: (paragraphs: Array<{ id: string; text: string }>) =>
    call<{ results: Record<string, ProofIssue[]> }>("spell.check", { paragraphs }),
  /** Atlantis: search every project's documents (Swift reads the files; nothing is indexed). */
  search: (query: string, limit = 200) => call<SearchResult>("fs.search", { query, limit }),
  convert: (name: string, data: string) => st().convert({ name, data }) as Promise<{ markdown?: string; html?: string }>,
};

// ── Tree helpers (pure) ─────────────────────────────────────────────────────

export function walk(nodes: BinderNode[], fn: (n: BinderNode, depth: number, parent: BinderNode | null) => void, depth = 0, parent: BinderNode | null = null): void {
  for (const n of nodes) {
    fn(n, depth, parent);
    if (n.children) walk(n.children, fn, depth + 1, n);
  }
}

export function findNode(nodes: BinderNode[], path: string): BinderNode | null {
  let hit: BinderNode | null = null;
  walk(nodes, (n) => {
    if (!hit && n.path === path) hit = n;
  });
  return hit;
}

export function parentOf(nodes: BinderNode[], path: string): BinderNode | null {
  let hit: BinderNode | null = null;
  walk(nodes, (n, _d, parent) => {
    if (!hit && n.path === path) hit = parent;
  });
  return hit;
}

/** Docs under a node in binder order (the node itself first when it's a doc). */
export function docsUnder(node: BinderNode): BinderNode[] {
  const out: BinderNode[] = [];
  const visit = (n: BinderNode) => {
    if (n.kind === "doc") out.push(n);
    n.children?.forEach(visit);
  };
  visit(node);
  return out;
}

export function isInTrash(nodes: BinderNode[], path: string): boolean {
  const trash = nodes.find((n) => n.role === "trash");
  return !!trash && (path === trash.path || path.startsWith(`${trash.path}/`));
}

export function countWords(markdown: string | undefined): number {
  const text = String(markdown ?? "")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[#>*_`~=|+-]+/g, " ");
  const m = text.match(/[\p{L}\p{N}][\p{L}\p{N}'’]*/gu);
  return m ? m.length : 0;
}

export function wordsUnder(node: BinderNode, onlyCompiled = false): number {
  let total = 0;
  const visit = (n: BinderNode) => {
    if (onlyCompiled && n.meta?.compile === false) return;
    if (n.kind === "doc") total += countWords(n.body);
    n.children?.forEach(visit);
  };
  visit(node);
  return total;
}

/** Plain-text preview of a doc for cards (Scrivener's automatic synopsis). */
export function excerpt(markdown: string | undefined, max = 180): string {
  const text = String(markdown ?? "")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*_`~=+>|-]{1,3}/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text;
}
