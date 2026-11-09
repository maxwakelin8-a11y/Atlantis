// @ts-nocheck — plain JS copied from seqta-mcp; tested in store.test.ts
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "./paths";
import type { WriterFS } from "./fs";

// Copied from seqta-mcp src/writer.mjs (the user's own repo) and changed for Atlantis:
//  - files go through WriterFS (Swift checks every path is inside the Writer folder), not node:fs
//  - saving keeps the file's own front matter bytes when its fields didn't change, and doesn't
//    write at all when nothing changed (the markdown round-trip rule)
//  - Word/RTF/ODT/PDF conversion and opening files happen in Swift

/**
 * Writer (the SEQTA "Writer" tab): Scrivener-style projects kept as plain Markdown so they open in
 * any editor and sync with iCloud Drive.
 *
 *   <writer folder>/<Project>/.writer.json        binder order, project settings, folder metadata
 *   <writer folder>/<Project>/Draft/…/<Doc>.md    front matter (title, synopsis, status, …) + text
 *   <writer folder>/<Project>/Research|Notes|Trash
 *   <writer folder>/<Project>/Exports/            compiled .docx/.pdf/.md/… files
 *   <writer folder>/<Project>/.snapshots/         saved versions of single documents
 *
 * Folders in the binder are real folders on disk. Files added outside the app show up at the end of
 * their folder; files deleted outside the app drop out of the binder. Nothing is ever deleted for
 * real: "Empty trash" and deleting a project move things into a hidden `.deleted` folder.
 */

const PROJECT_FILE = ".writer.json";
const TEXT_EXT = new Set([".md", ".markdown", ".txt"]);
const HIDDEN_DIRS = new Set(["Exports", ".snapshots", ".deleted"]);
const ROLES = ["draft", "research", "notes", "trash"];
const ROLE_NAMES = { draft: "Draft", research: "Research", notes: "Notes", trash: "Trash" };
const DOC_FIELDS = ["title", "synopsis", "status", "label", "compile", "target", "notes", "comments", "created"];
const MAX_DOC = 2_000_000;

/** A title that's safe as a file or folder name on macOS, Windows and iCloud. */
export function safeName(title, fallback = "Untitled") {
  const s = String(title ?? "")
    .normalize("NFC")
    .replace(/[\u0000-\u001f\u007f/\\:*?"<>|]+/g, " ")
    .replace(/\s+/g, " ")
    .replace(/^[.\s]+|[.\s]+$/g, "")
    .slice(0, 80)
    .trim();
  return s || fallback;
}

// ── Front matter ─────────────────────────────────────────────────────────────

function yamlValue(value) {
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  const s = String(value ?? "");
  return /^[\w ./,()'&+-]*$/.test(s) && s.trim() === s && s !== "" && !/^(true|false|null|yes|no|~|\d)/i.test(s)
    ? s
    : JSON.stringify(s);
}

function parseScalar(raw) {
  const v = raw.trim();
  if (v === "true") return true;
  if (v === "false") return false;
  if (/^-?\d+(\.\d+)?$/.test(v)) return Number(v);
  if (v.startsWith('"')) {
    try {
      return JSON.parse(v);
    } catch {
      return v.slice(1, -1);
    }
  }
  if (v.startsWith("'") && v.endsWith("'")) return v.slice(1, -1).replace(/''/g, "'");
  return v;
}

/** Splits a doc into its metadata (known keys only; others are kept in `extra`) and body. */
export function parseDoc(text) {
  const src = String(text ?? "").replace(/^﻿/, "");
  const fm = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(src);
  const meta = {};
  const extra = [];
  if (!fm) return { meta, body: src, extra: "" };
  for (const line of fm[1].split(/\r?\n/)) {
    const m = /^([A-Za-z_][\w-]*):\s?(.*)$/.exec(line);
    if (m && DOC_FIELDS.includes(m[1])) meta[m[1]] = parseScalar(m[2]);
    else extra.push(line);
  }
  return { meta, body: src.slice(fm[0].length).replace(/^\r?\n/, ""), extra: extra.join("\n") };
}

export function serializeDoc(meta, body, extra = "") {
  const lines = [];
  for (const key of DOC_FIELDS) {
    const v = meta?.[key];
    if (v === undefined || v === null || v === "") continue;
    if (key === "compile" && v === true) continue; // the default
    lines.push(`${key}: ${yamlValue(v)}`);
  }
  if (extra.trim()) lines.push(extra.trimEnd());
  const text = String(body ?? "").replace(/\r\n/g, "\n");
  if (!lines.length) return text.endsWith("\n") || !text ? text : `${text}\n`;
  return `---\n${lines.join("\n")}\n---\n\n${text}${text.endsWith("\n") || !text ? "" : "\n"}`;
}

/** The front matter lines serializeDoc would write for these fields (for comparing). */
function metaKey(meta, stem) {
  const out = [];
  for (const key of DOC_FIELDS) {
    const v = meta?.[key];
    if (v === undefined || v === null || v === "") continue;
    if (key === "compile" && v === true) continue;
    if (key === "title" && v === stem) continue;
    out.push(`${key}: ${yamlValue(v)}`);
  }
  return out.join("\n");
}

/**
 * The file's text with a new body. When the fields haven't changed, everything before the body
 * (BOM, front matter, its spacing and unknown keys) is kept byte for byte; only the body is new.
 */
export function withBody(raw, meta, stem, body) {
  const bom = raw.startsWith("﻿") ? "﻿" : "";
  const src = raw.slice(bom.length);
  const old = parseDoc(src);
  if (metaKey(old.meta, stem) === metaKey(meta, stem)) {
    return bom + src.slice(0, src.length - old.body.length) + body;
  }
  const head = serializeDoc(meta, "", old.extra);
  return bom + (head ? `${head}` : "") + body;
}

export function countWords(markdown) {
  const text = String(markdown ?? "")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[#>*_`~=|+-]+/g, " ");
  const m = text.match(/[\p{L}\p{N}][\p{L}\p{N}'’]*/gu);
  return m ? m.length : 0;
}

// ── Store ────────────────────────────────────────────────────────────────────

export function createWriterStore(fs: WriterFS, { log = (_msg: string) => {} } = {}) {
  // node:fs-shaped helpers over WriterFS, so the code below stays as it was in seqta-mcp.
  const readFile = (file, _enc?) => fs.read(file);
  const writeFile = (file, text) => fs.write(file, text);
  const mkdir = (dir, _opts?) => fs.mkdir(dir);
  const rename = (from, to) => fs.move(from, to);
  const exists = async (path) => (await fs.stat(path)) != null; // Swift sends nil as undefined
  const stat = async (path) => {
    const s = await fs.stat(path);
    if (!s) throw new Error(`Not found: ${path}`);
    return { size: s.size, mtimeMs: s.mtime, isDirectory: () => s.kind === "dir" };
  };
  const readdir = async (dir, opts?) => {
    const list = await fs.list(dir);
    return opts?.withFileTypes
      ? list.map((e) => ({ name: e.name, isDirectory: () => e.kind === "dir", isFile: () => e.kind === "file" }))
      : list.map((e) => e.name);
  };

  const locks = new Map();
  /** Serialises changes to one project so the binder file is never written twice at once. */
  const withLock = (project, fn) => {
    const prev = locks.get(project) ?? Promise.resolve();
    const next = prev.then(fn);
    const tail = next.catch(() => {});
    locks.set(project, tail);
    void tail.then(() => locks.get(project) === tail && locks.delete(project));
    return next;
  };

  const root = () => fs.root();

  function projectDir(project) {
    const name = String(project ?? "");
    if (!name || name !== basename(name) || name.startsWith(".")) throw new Error("Unknown project.");
    return join(root(), name);
  }

  /** A path inside the project; refuses anything that climbs out. */
  function inside(dir, rel) {
    const r = String(rel ?? "").replace(/\\/g, "/").replace(/^\/+/, "");
    const full = resolve(dir, r);
    const back = relative(dir, full);
    if (back.startsWith("..") || isAbsolute(back)) throw new Error("That path is outside the project.");
    return full;
  }

  const toRel = (dir, full) => relative(dir, full).split(sep).join("/");

  async function readProjectFile(dir) {
    try {
      const data = JSON.parse(await readFile(join(dir, PROJECT_FILE), "utf8"));
      return data && typeof data === "object" ? data : {};
    } catch {
      return {};
    }
  }

  async function writeProjectFile(dir, data) {
    await writeFile(join(dir, PROJECT_FILE), `${JSON.stringify(data, null, 2)}\n`); // atomic in Swift
  }

  async function writeAtomic(file, text) {
    await writeFile(file, text); // atomic in Swift, and it makes the folders
  }

  async function uniquePath(parentDir, name, ext) {
    for (let i = 1; i < 500; i++) {
      const candidate = join(parentDir, `${name}${i === 1 ? "" : ` ${i}`}${ext}`);
      if (!(await exists(candidate))) return candidate;
    }
    throw new Error("Too many items with that name.");
  }

  /** The binder as saved: [{ path, children? }] (folders have children). */
  function flatPaths(nodes, out = []) {
    for (const n of nodes ?? []) {
      out.push(n.path);
      if (n.children) flatPaths(n.children, out);
    }
    return out;
  }

  /** Reads one folder from disk, ordered by the saved binder, new files at the end. */
  async function scan(dir, relDir, saved, depth = 0) {
    const full = relDir ? inside(dir, relDir) : dir;
    let entries = [];
    try {
      entries = await readdir(full, { withFileTypes: true });
    } catch {
      return [];
    }
    const found = new Map();
    for (const e of entries) {
      if (e.name.startsWith(".") || e.name.endsWith(".icloud")) continue;
      const rel = relDir ? `${relDir}/${e.name}` : e.name;
      if (e.isDirectory()) {
        if (!relDir && HIDDEN_DIRS.has(e.name)) continue;
        if (depth > 12) continue;
        found.set(rel, { kind: "folder", name: e.name });
      } else if (e.isFile() && TEXT_EXT.has(extname(e.name).toLowerCase())) {
        found.set(rel, { kind: "doc", name: e.name });
      }
    }
    const savedHere = (saved ?? []).filter((n) => found.has(n.path));
    const order = [...savedHere.map((n) => n.path)];
    const rest = [...found.keys()].filter((p) => !order.includes(p)).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    const nodes = [];
    for (const path of [...order, ...rest]) {
      const info = found.get(path);
      if (info.kind === "folder") {
        const savedNode = savedHere.find((n) => n.path === path);
        nodes.push({ path, kind: "folder", children: await scan(dir, path, savedNode?.children ?? [], depth + 1) });
      } else {
        nodes.push({ path, kind: "doc" });
      }
    }
    return nodes;
  }

  async function loadTree(dir, data) {
    const saved = Array.isArray(data.binder) ? data.binder : [];
    const tree = await scan(dir, "", saved);
    // The four special folders always exist and come first, in Scrivener's order.
    const top = [];
    for (const role of ROLES) {
      const name = ROLE_NAMES[role];
      let node = tree.find((n) => n.kind === "folder" && n.path === name);
      if (!node) {
        await mkdir(join(dir, name), { recursive: true });
        node = { path: name, kind: "folder", children: [] };
      }
      node.role = role;
      top.push(node);
    }
    for (const n of tree) if (!top.includes(n)) top.splice(top.length - 1, 0, n); // before Trash
    return top;
  }

  const strip = (nodes) => nodes.map((n) => (n.kind === "folder" ? { path: n.path, children: strip(n.children ?? []) } : { path: n.path }));

  async function saveTree(dir, tree) {
    const data = await readProjectFile(dir);
    data.binder = strip(tree);
    data.updated = new Date().toISOString();
    await writeProjectFile(dir, data);
  }

  /** Adds metadata and text to every node (projects are small; the editor wants it all at once). */
  async function hydrate(dir, nodes, folders) {
    for (const n of nodes) {
      const name = basename(n.path);
      if (n.kind === "folder") {
        n.title = name;
        n.meta = folders?.[n.path] ?? {};
        await hydrate(dir, n.children, folders);
      } else {
        const file = inside(dir, n.path);
        let text = "";
        let mtime = 0;
        try {
          const s = await stat(file);
          mtime = s.mtimeMs;
          text = s.size > MAX_DOC ? "" : await readFile(file, "utf8");
        } catch {}
        const { meta, body } = parseDoc(text);
        n.title = String(meta.title || name.replace(/\.(md|markdown|txt)$/i, ""));
        n.meta = meta;
        n.body = body;
        n.mtime = mtime;
      }
    }
    return nodes;
  }

  function findNode(nodes, path, parent = null) {
    for (const [i, n] of nodes.entries()) {
      if (n.path === path) return { node: n, list: nodes, index: i, parent };
      if (n.children) {
        const hit = findNode(n.children, path, n);
        if (hit) return hit;
      }
    }
    return null;
  }

  function rebase(node, from, to) {
    if (node.path === from || node.path.startsWith(`${from}/`)) node.path = to + node.path.slice(from.length);
    node.children?.forEach((c) => rebase(c, from, to));
  }

  function remapKeys(obj, from, to) {
    const out = {};
    for (const [k, v] of Object.entries(obj ?? {})) {
      out[k === from || k.startsWith(`${from}/`) ? to + k.slice(from.length) : k] = v;
    }
    return out;
  }

  async function projectSummary(name) {
    const dir = join(root(), name);
    const data = await readProjectFile(dir);
    let updated = data.updated ?? null;
    if (!updated) {
      try {
        updated = new Date((await stat(dir)).mtimeMs).toISOString();
      } catch {}
    }
    return {
      id: name,
      title: data.title || name,
      settings: data.settings ?? {},
      updated,
      isProject: await exists(join(dir, PROJECT_FILE)),
    };
  }

  const api = {
    dir: async () => {
      await mkdir(root(), { recursive: true });
      return root();
    },

    async projects() {
      await mkdir(root(), { recursive: true });
      const entries = await readdir(root(), { withFileTypes: true });
      const out = [];
      for (const e of entries) {
        if (!e.isDirectory() || e.name.startsWith(".")) continue;
        out.push(await projectSummary(e.name));
      }
      out.sort((a, b) => String(b.updated ?? "").localeCompare(String(a.updated ?? "")));
      return { dir: root(), projects: out };
    },

    /** items: [{ path: "Draft/Introduction", kind: "doc"|"folder", meta?, body? }] in binder order. */
    async create({ title, settings, items }) {
      await mkdir(root(), { recursive: true });
      const dir = await uniquePath(root(), safeName(title, "Untitled Project"), "");
      await mkdir(dir, { recursive: true });
      const name = basename(dir);
      const binder = [];
      const folders = {};
      const placed = new Map([["", binder]]);
      for (const role of ROLES) {
        await mkdir(join(dir, ROLE_NAMES[role]), { recursive: true });
        const node = { path: ROLE_NAMES[role], children: [] };
        binder.push(node);
        placed.set(ROLE_NAMES[role], node.children);
      }
      for (const item of Array.isArray(items) ? items : []) {
        const parts = String(item.path ?? "")
          .split("/")
          .map((p) => safeName(p))
          .filter(Boolean);
        if (!parts.length) continue;
        const parentRel = parts.slice(0, -1).join("/");
        const parentList = placed.get(parentRel) ?? binder;
        if (item.kind === "folder") {
          const rel = parts.join("/");
          await mkdir(inside(dir, rel), { recursive: true });
          const node = { path: rel, children: [] };
          parentList.push(node);
          placed.set(rel, node.children);
          if (item.meta && Object.keys(item.meta).length) folders[rel] = item.meta;
        } else {
          const rel = `${parts.join("/")}.md`;
          const meta = { ...(item.meta ?? {}), title: item.meta?.title ?? String(item.path).split("/").pop() };
          if (meta.title === parts.at(-1)) delete meta.title;
          await writeAtomic(inside(dir, rel), serializeDoc(meta, item.body ?? ""));
          parentList.push({ path: rel });
        }
      }
      const now = new Date().toISOString();
      await writeProjectFile(dir, { version: 1, title: String(title || name), created: now, updated: now, settings: settings ?? {}, folders, binder });
      log(`writer: new project "${name}"`);
      return api.open({ project: name });
    },

    async open({ project }) {
      const dir = projectDir(project);
      if (!(await exists(dir))) throw new Error("That project isn't in the Writer folder any more.");
      const data = await readProjectFile(dir);
      const tree = await loadTree(dir, data);
      await hydrate(dir, tree, data.folders);
      return { id: project, dir, title: data.title || project, settings: data.settings ?? {}, tree };
    },

    async save({ project, path, meta, body }) {
      const dir = projectDir(project);
      const file = inside(dir, path);
      if (!TEXT_EXT.has(extname(file).toLowerCase())) throw new Error("Only .md and .txt files can be saved.");
      let raw = null;
      try {
        raw = await readFile(file, "utf8");
      } catch {}
      const stem = basename(file).replace(/\.(md|markdown|txt)$/i, "");
      const clean = {};
      for (const k of DOC_FIELDS) if (meta && k in meta) clean[k] = meta[k];
      if (clean.title && clean.title === stem) delete clean.title;
      const text = raw === null ? serializeDoc(clean, String(body ?? "")) : withBody(raw, clean, stem, String(body ?? ""));
      if (text.length > MAX_DOC) throw new Error("That document is too big to save (2 MB max).");
      if (text !== raw) await writeAtomic(file, text);
      const s = await stat(file);
      return { path, mtime: s.mtimeMs, words: countWords(body) };
    },

    setFolderMeta: ({ project, path, meta }) =>
      withLock(project, async () => {
        const dir = projectDir(project);
        const data = await readProjectFile(dir);
        data.folders = { ...(data.folders ?? {}), [path]: meta ?? {} };
        await writeProjectFile(dir, data);
        return { path };
      }),

    settings: ({ project, title, settings }) =>
      withLock(project, async () => {
        const dir = projectDir(project);
        const data = await readProjectFile(dir);
        if (typeof title === "string" && title.trim()) data.title = title.trim().slice(0, 120);
        if (settings && typeof settings === "object") data.settings = { ...(data.settings ?? {}), ...settings };
        data.updated = new Date().toISOString();
        await writeProjectFile(dir, data);
        return { title: data.title, settings: data.settings };
      }),

    /** New doc or folder in `parent` ("" = top level) at `index` (default: end). */
    add: ({ project, parent, kind, title, index, meta, body }) =>
      withLock(project, async () => {
        const dir = projectDir(project);
        const data = await readProjectFile(dir);
        const tree = await loadTree(dir, data);
        const parentRel = String(parent ?? "");
        const list = parentRel ? findNode(tree, parentRel)?.node.children : tree;
        if (!list) throw new Error("That folder isn't in the binder.");
        const parentDir = parentRel ? inside(dir, parentRel) : dir;
        const isFolder = kind === "folder";
        const full = await uniquePath(parentDir, safeName(title, isFolder ? "New Folder" : "Untitled"), isFolder ? "" : ".md");
        const rel = toRel(dir, full);
        if (isFolder) await mkdir(full, { recursive: true });
        else {
          const m = { ...(meta ?? {}) };
          if (title && safeName(title) !== String(title)) m.title = String(title);
          await writeAtomic(full, serializeDoc(m, body ?? ""));
        }
        const node = isFolder ? { path: rel, kind: "folder", children: [] } : { path: rel, kind: "doc" };
        const at = Number.isInteger(index) ? Math.max(0, Math.min(index, list.length)) : list.length;
        list.splice(at, 0, node);
        await saveTree(dir, tree);
        return { path: rel };
      }),

    /** Renames the file or folder on disk to match a new title. */
    rename: ({ project, path, title }) =>
      withLock(project, async () => {
        const dir = projectDir(project);
        const data = await readProjectFile(dir);
        const tree = await loadTree(dir, data);
        const hit = findNode(tree, path);
        if (!hit) throw new Error("That item isn't in the binder.");
        if (hit.node.role) throw new Error("Draft, Research, Notes and Trash keep their names.");
        const from = inside(dir, path);
        const isFolder = hit.node.kind === "folder";
        const ext = isFolder ? "" : extname(from);
        const wanted = safeName(title, isFolder ? "New Folder" : "Untitled");
        if (basename(from) === `${wanted}${ext}`) return { path };
        const to = await uniquePath(dirname(from), wanted, ext);
        await rename(from, to);
        const rel = toRel(dir, to);
        rebase(hit.node, path, rel);
        if (!isFolder) {
          const { meta, body, extra } = parseDoc(await readFile(to, "utf8"));
          if (String(title) !== wanted) meta.title = String(title);
          else delete meta.title;
          await writeAtomic(to, serializeDoc(meta, body, extra));
        }
        data.folders = remapKeys(data.folders, path, rel);
        data.binder = strip(tree);
        await writeProjectFile(dir, data);
        await moveSnapshots(dir, path, rel);
        return { path: rel };
      }),

    /** Moves an item into `parent` at `index` (moves the file on disk when the folder changes). */
    move: ({ project, path, parent, index }) =>
      withLock(project, async () => {
        const dir = projectDir(project);
        const data = await readProjectFile(dir);
        const tree = await loadTree(dir, data);
        const hit = findNode(tree, path);
        if (!hit) throw new Error("That item isn't in the binder.");
        if (hit.node.role) throw new Error("Draft, Research, Notes and Trash stay where they are.");
        const parentRel = String(parent ?? "");
        if (parentRel === path || parentRel.startsWith(`${path}/`)) throw new Error("A folder can't go inside itself.");
        const target = parentRel ? findNode(tree, parentRel)?.node : null;
        if (parentRel && (!target || target.kind !== "folder")) throw new Error("Drop it on a folder.");
        const list = target ? target.children : tree;
        hit.list.splice(hit.index, 1);
        let rel = path;
        const sameFolder = dirname(path) === (parentRel || ".");
        if (!sameFolder) {
          const from = inside(dir, path);
          const ext = hit.node.kind === "folder" ? "" : extname(from);
          const stem = basename(from, ext);
          const to = await uniquePath(parentRel ? inside(dir, parentRel) : dir, stem, ext);
          await rename(from, to);
          rel = toRel(dir, to);
          rebase(hit.node, path, rel);
          data.folders = remapKeys(data.folders, path, rel);
          await moveSnapshots(dir, path, rel);
        }
        const at = Number.isInteger(index) ? Math.max(0, Math.min(index, list.length)) : list.length;
        list.splice(at, 0, hit.node);
        data.binder = strip(tree);
        data.updated = new Date().toISOString();
        await writeProjectFile(dir, data);
        return { path: rel };
      }),

    /** Moves an item to the project's Trash (or, from inside the Trash, to .deleted). */
    trash: async ({ project, path }) => {
      const dir = projectDir(project);
      const data = await readProjectFile(dir);
      const tree = await loadTree(dir, data);
      const trash = tree.find((n) => n.role === "trash");
      if (path === trash.path || findNode(tree, path)?.node.role) throw new Error("That folder can't be deleted.");
      if (path.startsWith(`${trash.path}/`)) return api.emptyTrash({ project, paths: [path] });
      return api.move({ project, path, parent: trash.path });
    },

    emptyTrash: ({ project, paths }) =>
      withLock(project, async () => {
        const dir = projectDir(project);
        const data = await readProjectFile(dir);
        const tree = await loadTree(dir, data);
        const trash = tree.find((n) => n.role === "trash");
        const targets = Array.isArray(paths) && paths.length ? paths : trash.children.map((c) => c.path);
        const bin = join(dir, ".deleted", new Date().toISOString().replace(/[:.]/g, "-"));
        let moved = 0;
        for (const p of targets) {
          if (!p.startsWith(`${trash.path}/`)) continue;
          const from = inside(dir, p);
          if (!(await exists(from))) continue;
          await mkdir(bin, { recursive: true });
          await rename(from, join(bin, basename(from)));
          moved++;
        }
        trash.children = trash.children.filter((c) => !targets.includes(c.path));
        data.binder = strip(tree);
        await writeProjectFile(dir, data);
        return { moved };
      }),

    /** Saves a copy of one document as it is now. */
    async snapshot({ project, path, name }) {
      const dir = projectDir(project);
      const file = inside(dir, path);
      const text = await readFile(file, "utf8");
      const at = new Date();
      const folder = snapshotDir(dir, path);
      await mkdir(folder, { recursive: true });
      const stamp = at.toISOString().replace(/[:.]/g, "-");
      const label = safeName(name ?? "", "").slice(0, 60);
      await writeFile(join(folder, `${stamp}${label ? ` ${label}` : ""}.md`), text);
      return { id: `${stamp}${label ? ` ${label}` : ""}.md`, at: at.toISOString(), name: label };
    },

    async snapshots({ project, path }) {
      const dir = projectDir(project);
      inside(dir, path);
      const folder = snapshotDir(dir, path);
      let files = [];
      try {
        files = (await readdir(folder)).filter((f) => f.endsWith(".md"));
      } catch {}
      const out = [];
      for (const f of files.sort().reverse().slice(0, 50)) {
        const m = /^(\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d+Z)(?: (.*))?\.md$/.exec(f);
        const text = await readFile(join(folder, f), "utf8").catch(() => "");
        const { body } = parseDoc(text);
        const iso = m ? m[1].replace(/T(\d\d)-(\d\d)-(\d\d)-(\d+)Z/, "T$1:$2:$3.$4Z") : null;
        out.push({ id: f, at: iso, name: m?.[2] ?? "", body, words: countWords(body) });
      }
      return { snapshots: out };
    },

    async deleteSnapshot({ project, path, id }) {
      const dir = projectDir(project);
      inside(dir, path);
      const name = basename(String(id ?? ""));
      if (!name.endsWith(".md")) throw new Error("Unknown snapshot.");
      const bin = join(dir, ".deleted", "snapshots");
      await mkdir(bin, { recursive: true });
      await rename(join(snapshotDir(dir, path), name), join(bin, `${Date.now()}-${name}`));
      return { removed: true };
    },

    /** Moves a whole project out of the list (into <writer folder>/.deleted). */
    async removeProject({ project }) {
      const dir = projectDir(project);
      const bin = join(root(), ".deleted");
      await mkdir(bin, { recursive: true });
      await rename(dir, join(bin, `${project} ${new Date().toISOString().replace(/[:.]/g, "-")}`));
      return { removed: true };
    },

    async duplicateProject({ project }) {
      const dir = projectDir(project);
      const data = await readProjectFile(dir);
      const to = await uniquePath(root(), `${basename(dir)} copy`, "");
      await fs.copyDir(dir, to, [".deleted", "Exports"]);
      await writeProjectFile(to, { ...data, title: `${data.title || basename(dir)} copy`, updated: new Date().toISOString() });
      return { id: basename(to) };
    },

    /**
     * Writes a compiled export into <project>/Exports. The page sends the finished HTML (and
     * Markdown/plain text); Swift turns HTML into Word, RTF, OpenDocument (textutil) or PDF.
     */
    async export({ project, name, format, html, markdown, text }) {
      const dir = projectDir(project);
      const out = join(dir, "Exports");
      await mkdir(out, { recursive: true });
      const fmt = String(format ?? "");
      const ext = EXPORT_EXT[fmt];
      if (!ext) throw new Error(`Unknown export format: ${fmt}`);
      const file = await uniquePath(out, safeName(name, "Export"), ext);
      if (fmt === "md") await writeFile(file, String(markdown ?? ""));
      else if (fmt === "txt") await writeFile(file, String(text ?? ""));
      else if (fmt === "html") await writeFile(file, String(html ?? ""));
      else await fs.exportHTML(String(html ?? ""), fmt, file);
      log(`writer: exported ${basename(file)}`);
      return { path: file, name: basename(file) };
    },

    /** Shows a file in Finder (`reveal`) or opens it in its app. Only inside the Writer folder. */
    async open_file({ path, reveal }) {
      const full = resolve(String(path ?? ""));
      const rel = relative(root(), full);
      if (rel.startsWith("..") || isAbsolute(rel)) throw new Error("Only files in the Writer folder can be opened.");
      if (!(await exists(full))) throw new Error("That file isn't there any more.");
      await fs.open(full, !!reveal);
      return { opened: true };
    },

    /** Turns an imported file (base64) into Markdown or HTML for the editor to take in. */
    async convert({ name, data }) {
      const ext = extname(String(name ?? "")).toLowerCase();
      const b64 = String(data ?? "");
      if (b64.length > 27_000_000) throw new Error("That file is too big to import (20 MB max).");
      if (![".md", ".markdown", ".txt", ".docx", ".doc", ".rtf", ".rtfd", ".odt", ".html", ".htm", ".webarchive", ".pages"].includes(ext))
        throw new Error("Import works with .md, .txt, .docx, .doc, .rtf, .odt and .html files.");
      if (ext === ".pages") throw new Error("Export it from Pages as Word (.docx) first, then import that.");
      return fs.convert(ext, b64);
    },
  };

  function snapshotDir(dir, path) {
    return join(dir, ".snapshots", String(path).replace(/\.(md|markdown|txt)$/i, ""));
  }

  async function moveSnapshots(dir, from, to) {
    const a = snapshotDir(dir, from);
    if (!(await exists(a))) return;
    const b = snapshotDir(dir, to);
    await mkdir(dirname(b), { recursive: true });
    await rename(a, b).catch(() => {});
  }

  return api;
}

export const EXPORT_EXT = { docx: ".docx", pdf: ".pdf", md: ".md", html: ".html", rtf: ".rtf", odt: ".odt", txt: ".txt" };
