// Atlantis: pasting and dropping images. GenOffice's editor (vendor/.../localImage.ts) turns a
// pasted image into `window.markdownApi.saveImage({ base64, ext })` and inserts the relative path
// it returns. Here that saves the file in the project's `assets/` folder (through Swift, which only
// writes images there) and returns the path relative to the open doc, e.g. `../assets/image-….png`.
import { setImageBaseDir } from "../../vendor/genoffice/renderer/editor/localImage";
import type { WriterFS } from "./fs";
import { dirname, join, relative } from "./paths";

/** Fired on `window` when an image couldn't be saved (the page shows it as a toast). */
export const IMAGE_ERROR_EVENT = "writer-image-error";

export const IMAGE_EXTS = ["png", "jpg", "jpeg", "gif", "webp"] as const;

/** The doc images are being added to: its project folder and its own absolute path. */
export type ImageTarget = { projectDir: string; docFile: string };

let target: ImageTarget | null = null;
let fs: WriterFS | null = null;

/** Tells the bridge which doc is open (also where relative image links are resolved from). */
export function setImageTarget(next: ImageTarget | null): void {
  target = next;
  setImageBaseDir(next ? dirname(next.docFile) : null);
}

const two = (n: number) => String(n).padStart(2, "0");

/** `image-YYYYMMDD-HHMMSS.png` in local time. */
export function imageName(ext: string, at = new Date()): string {
  const day = `${at.getFullYear()}${two(at.getMonth() + 1)}${two(at.getDate())}`;
  const time = `${two(at.getHours())}${two(at.getMinutes())}${two(at.getSeconds())}`;
  return `image-${day}-${time}.${ext}`;
}

/** The link to put in the doc: the image's path relative to the doc's folder. */
export function imageLink(docFile: string, imageFile: string): string {
  return relative(dirname(docFile), imageFile);
}

/** Saves `base64` as a new image in the open doc's project; returns the markdown link (doc-relative). */
export async function saveImage(files: WriterFS, to: ImageTarget, base64: string, ext: string, at = new Date()): Promise<string> {
  const e = ext.toLowerCase().replace(/^\./, "");
  if (!(IMAGE_EXTS as readonly string[]).includes(e)) throw new Error(`Docs can't save .${e} images.`);
  const assets = join(to.projectDir, "assets");
  const base = imageName(e, at).slice(0, -(e.length + 1));
  let file = join(assets, `${base}.${e}`);
  for (let i = 2; await files.stat(file); i++) {
    if (i > 99) throw new Error("Too many images saved this second.");
    file = join(assets, `${base}-${i}.${e}`);
  }
  await files.writeImage(file, base64);
  return imageLink(to.docFile, file);
}

/** Makes `window.markdownApi.saveImage` (what GenOffice's paste/drop code calls) save through `files`. */
export function installImageBridge(files: WriterFS): void {
  fs = files;
  const w = window as unknown as { markdownApi?: Record<string, unknown> };
  w.markdownApi ??= {};
  w.markdownApi.saveImage = async ({ base64, ext }: { base64: string; ext: string }) => {
    if (!fs || !target) return null; // GenOffice then asks the user to save the document first
    try {
      return await saveImage(fs, target, base64, ext);
    } catch (err) {
      window.dispatchEvent(new CustomEvent(IMAGE_ERROR_EVENT, { detail: err instanceof Error ? err.message : String(err) }));
      return null;
    }
  };
  // No image host: pasted images always stay next to the doc, on this Mac.
  w.markdownApi.getImageHost = async () => null;
}
