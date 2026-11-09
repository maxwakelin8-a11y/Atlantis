// File access for the Writer. In the app every call goes to Swift (WriterBridge.swift), which
// refuses any path outside the Writer folder. Tests use the in-memory version below.

export type Entry = { name: string; kind: "dir" | "file" };
export type Stat = { kind: "dir" | "file"; size: number; mtime: number };

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
    async exportHTML(_html, _format, file) {
      fileMap.set(file, "(binary)");
    },
    async convert(_ext, base64) {
      return { markdown: atob(base64) };
    },
    async open() {},
  };
}
