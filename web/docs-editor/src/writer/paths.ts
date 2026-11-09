// The few node:path functions the Writer store uses, for absolute POSIX paths only.

export const sep = "/";

function normalize(path: string): string {
  const abs = path.startsWith("/");
  const out: string[] = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") {
      if (out.length && out[out.length - 1] !== "..") out.pop();
      else if (!abs) out.push("..");
      continue;
    }
    out.push(part);
  }
  const joined = out.join("/");
  return abs ? `/${joined}` : joined || ".";
}

export const isAbsolute = (path: string): boolean => path.startsWith("/");

export function join(...parts: string[]): string {
  return normalize(parts.filter((p) => p !== "").join("/"));
}

export function resolve(...parts: string[]): string {
  let out = "";
  for (const p of parts) out = p.startsWith("/") ? p : out ? `${out}/${p}` : p;
  if (!out.startsWith("/")) out = `/${out}`;
  return normalize(out);
}

export function relative(from: string, to: string): string {
  const a = resolve(from).split("/").filter(Boolean);
  const b = resolve(to).split("/").filter(Boolean);
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  return [...Array(a.length - i).fill(".."), ...b.slice(i)].join("/");
}

export function basename(path: string, ext?: string): string {
  const base = path.replace(/\/+$/, "").split("/").pop() ?? "";
  return ext && base.endsWith(ext) && base !== ext ? base.slice(0, -ext.length) : base;
}

export function dirname(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  const i = trimmed.lastIndexOf("/");
  if (i < 0) return ".";
  return i === 0 ? "/" : trimmed.slice(0, i);
}

export function extname(path: string): string {
  const base = basename(path);
  const i = base.lastIndexOf(".");
  return i <= 0 ? "" : base.slice(i);
}
