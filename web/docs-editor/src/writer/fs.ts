// File access for the Writer. In the app every call goes to Swift (WriterBridge.swift), which
// refuses any path outside the Writer folder. Tests use the in-memory version below.

export type Entry = { name: string; kind: "dir" | "file" };
export type Stat = { kind: "dir" | "file"; size: number; mtime: number };

// Atlantis: search across projects (runs in Swift, which reads the files) and image writes.
export type SearchSnippet = { before: string; match: string; after: string; occurrence: number };
export type SearchHit = {
  /** The project's folder name. */
  project: string;
  /** Absolute path of the document. */
  path: string;
  /** Path inside the project, e.g. "Draft/Intro.md" (the binder's path for it). */
  relPath: string;
  title: string;
  titleMatches: boolean;
  count: number;
  snippets: SearchSnippet[];
};
export type SearchResult = { hits: SearchHit[]; truncated: boolean; scanned: number };

export interface WriterFS {
  /** The Writer folder (absolute). */
  root(): string;
  list(dir: string): Promise<Entry[]>;
  /** UTF-8 text; fails for anything else. */
  read(file: string): Promise<string>;
  /** Atomic; makes missing folders. */
  write(file: string, text: string): Promise<void>;
  mkdir(dir: string): Promise<void>;
  /** Fails if `to` exists. */
  move(from: string, to: string): Promise<void>;
  stat(path: string): Promise<Stat | null>;
  copyDir(from: string, to: string, skip: string[]): Promise<void>;
  /** Atlantis: saves an image (base64) at `<project>/assets/<name>`; Swift refuses any other place or type. */
  writeImage(file: string, base64: string): Promise<void>;
  /** Atlantis: text search over every project's documents (title + body). */
  search(query: string, limit?: number): Promise<SearchResult>;
  /** HTML → docx/rtf/odt/pdf at `file`. */
  exportHTML(html: string, format: string, file: string): Promise<void>;
  /** An imported file (base64) → Markdown or HTML. */
  convert(ext: string, base64: string): Promise<{ markdown?: string; html?: string }>;
  open(path: string, reveal: boolean): Promise<void>;
}

type Handler = { postMessage(message: unknown): Promise<unknown> };

function handler(): Handler {
  const h = (window as unknown as { webkit?: { messageHandlers?: { writer?: Handler } } }).webkit?.messageHandlers?.writer;
  if (!h) throw new Error("Atlantis isn't connected.");
  return h;
}

/** Calls Swift; errors come back as rejected promises with Swift's message. */
export async function call<T>(op: string, args: Record<string, unknown> = {}): Promise<T> {
  try {
    return (await handler().postMessage({ op, ...args })) as T;
  } catch (e) {
    throw new Error(e instanceof Error ? e.message : String(e));
  }
}

export function swiftFS(rootDir: string): WriterFS {
  return {
    root: () => rootDir,
    list: (dir) => call("fs.list", { path: dir }),
    read: (file) => call("fs.read", { path: file }),
    write: (file, text) => call("fs.write", { path: file, text }),
    mkdir: (dir) => call("fs.mkdir", { path: dir }),
    move: (from, to) => call("fs.move", { from, to }),
    stat: (path) => call("fs.stat", { path }),
    copyDir: (from, to, skip) => call("fs.copyDir", { from, to, skip }),
    writeImage: (file, base64) => call("fs.writeImage", { path: file, data: base64 }),
    search: (query, limit = 200) => call("fs.search", { query, limit }),
    exportHTML: (html, format, file) => call("export", { html, format, path: file }),
    convert: (ext, base64) => call("convert", { ext, data: base64 }),
    open: (path, reveal) => call("open", { path, reveal }),
  };
}

/** In-memory files for tests. */
export function memoryFS(rootDir: string, files: Record<string, string> = {}): WriterFS & { files: Map<string, string>; dirs: Set<string>; writes: string[] } {
  const fileMap = new Map(Object.entries(files));
  const dirs = new Set<string>([rootDir]);
  const writes: string[] = [];
  let clock = 1;
  const mtimes = new Map<string, number>();
  const parentDirs = (p: string) => {
    const parts = p.split("/");
    for (let i = 2; i < parts.length; i++) dirs.add(parts.slice(0, i).join("/"));
  };
  for (const f of fileMap.keys()) parentDirs(f);
  const under = (p: string, dir: string) => p === dir || p.startsWith(`${dir}/`);
  return {
    files: fileMap,
    dirs,
    writes,
    root: () => rootDir,
    async list(dir) {
      if (!dirs.has(dir)) throw new Error(`No folder ${dir}`);
      const out = new Map<string, Entry>();
      for (const d of dirs) if (d.startsWith(`${dir}/`) && !d.slice(dir.length + 1).includes("/")) out.set(d, { name: d.slice(dir.length + 1), kind: "dir" });
      for (const f of fileMap.keys()) if (f.startsWith(`${dir}/`) && !f.slice(dir.length + 1).includes("/")) out.set(f, { name: f.slice(dir.length + 1), kind: "file" });
      return [...out.values()];
    },
    async read(file) {
      const t = fileMap.get(file);
      if (t === undefined) throw new Error(`No file ${file}`);
      return t;
    },
    async write(file, text) {
      parentDirs(file);
      fileMap.set(file, text);
      mtimes.set(file, clock++);
      writes.push(file);
    },
    async mkdir(dir) {
      parentDirs(`${dir}/x`);
    },
    async move(from, to) {
      if (fileMap.has(to) || dirs.has(to)) throw new Error("exists");
      if (fileMap.has(from)) {
        parentDirs(to);
        fileMap.set(to, fileMap.get(from)!);
        fileMap.delete(from);
        return;
      }
      if (!dirs.has(from)) throw new Error(`No ${from}`);
      parentDirs(`${to}/x`);
      for (const d of [...dirs]) if (under(d, from)) { dirs.delete(d); dirs.add(to + d.slice(from.length)); }
      for (const [f, t] of [...fileMap]) if (under(f, from)) { fileMap.delete(f); fileMap.set(to + f.slice(from.length), t); }
    },
    async stat(path) {
      if (fileMap.has(path)) return { kind: "file", size: fileMap.get(path)!.length, mtime: mtimes.get(path) ?? 0 };
      if (dirs.has(path)) return { kind: "dir", size: 0, mtime: 0 };
      return null;
    },
    async copyDir(from, to, skip) {
      const skipped = (p: string) => skip.some((s) => p.slice(from.length + 1).split("/")[0] === s);
      parentDirs(`${to}/x`);
      for (const d of [...dirs]) if (d.startsWith(`${from}/`) && !skipped(d)) dirs.add(to + d.slice(from.length));
      for (const [f, t] of [...fileMap]) if (f.startsWith(`${from}/`) && !skipped(f)) fileMap.set(to + f.slice(from.length), t);
    },
    async writeImage(file, base64) {
      // Same rules as Swift: <root>/<project>/assets/<name>.<png|jpg|jpeg|gif|webp>, never overwritten.
      const m = /^(.*)\/([^/]+)\/assets\/([^/.][^/]*)\.(png|jpe?g|gif|webp)$/i.exec(file);
      if (!m || m[1] !== rootDir) throw new Error("Images can only go in a project's assets folder.");
      if (fileMap.has(file)) throw new Error("Something with that name is already there.");
      parentDirs(file);
      fileMap.set(file, `image:${base64}`);
      writes.push(file);
    },
    async search(query, limit = 200) {
      // A plain version of Swift's search, enough for the page tests.
      const q = query.trim().toLowerCase();
      const hits: SearchHit[] = [];
      if (!q) return { hits, truncated: false, scanned: 0 };
      let scanned = 0;
      for (const [file, text] of [...fileMap].sort(([a], [b]) => a.localeCompare(b))) {
        const rel = file.slice(rootDir.length + 1).split("/");
        if (rel.length < 2 || rel[0].startsWith(".") || !/\.(md|markdown|txt)$/i.test(file) || ["Exports", "assets", "Trash"].includes(rel[1]) || rel.some((x) => x.startsWith("."))) continue;
        scanned++;
        const fm = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
        const body = fm ? text.slice(fm[0].length) : text;
        const stem = rel[rel.length - 1].replace(/\.[^.]+$/, "");
        const title = /^title:\s*"?(.*?)"?\s*$/m.exec(fm?.[1] ?? "")?.[1] || stem;
        const lower = body.toLowerCase();
        const snippets: SearchSnippet[] = [];
        let count = 0;
        for (let at = lower.indexOf(q); at !== -1 && count < 1000; at = lower.indexOf(q, at + q.length)) {
          if (snippets.length < 3) snippets.push({ before: body.slice(Math.max(0, at - 40), at).replace(/\s+/g, " "), match: body.slice(at, at + q.length), after: body.slice(at + q.length, at + q.length + 60).replace(/\s+/g, " "), occurrence: count });
          count++;
        }
        const titleMatches = title.toLowerCase().includes(q);
        if (!count && !titleMatches) continue;
        if (hits.length >= limit) return { hits, truncated: true, scanned };
        hits.push({ project: rel[0], path: file, relPath: rel.slice(1).join("/"), title, titleMatches, count, snippets });
      }
      return { hits, truncated: false, scanned };
    },
    async exportHTML(_html, _format, file) {
      fileMap.set(file, "(binary)");
    },
    async convert(_ext, base64) {
      return { markdown: atob(base64) };
    },
    async open() {},
  };
}
