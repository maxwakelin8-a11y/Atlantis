import DOMPurify from "dompurify";
import { countWords, type BinderNode, type ExportFormat } from "./api";
import { stripNotes } from "./notes";

/**
 * Compile, after Scrivener: stitches the documents under Draft (or any folder) into one paper.
 * Binder titles become headings by depth (a folder's documents sit one level below it), so the
 * documents themselves only hold text. Documents with "Include in export" off are left out, with
 * everything inside them. The layout comes from a preset (fonts, spacing, title page, headings).
 */

export type PresetId = "school" | "apa" | "mla" | "clean" | "manuscript";

export type TitlePage = {
  title: string;
  author: string;
  subject: string;
  teacher: string;
  school: string;
  date: string;
};

export type CompileOptions = {
  format: ExportFormat;
  preset: PresetId;
  titlePage: boolean;
  /** Binder titles as headings. */
  sectionTitles: boolean;
  pageNumbers: boolean;
  /** "Word count: N" at the end. */
  wordCount: boolean;
  info: TitlePage;
};

export const PRESETS: Array<{ id: PresetId; name: string; description: string }> = [
  { id: "school", name: "School assignment", description: "Arial 12, 1.5 spacing, title page" },
  { id: "apa", name: "APA 7th", description: "Times 12, double spaced, APA headings and references" },
  { id: "mla", name: "MLA 9th", description: "Times 12, double spaced, heading block, Works Cited" },
  { id: "clean", name: "Clean", description: "Modern sans, comfortable spacing" },
  { id: "manuscript", name: "Manuscript", description: "Courier 12, double spaced, chapters on new pages" },
];

export const FORMATS: Array<{ id: ExportFormat; name: string; ext: string }> = [
  { id: "docx", name: "Word", ext: ".docx" },
  { id: "pdf", name: "PDF", ext: ".pdf" },
  { id: "md", name: "Markdown", ext: ".md" },
  { id: "html", name: "Web page", ext: ".html" },
  { id: "odt", name: "OpenDocument", ext: ".odt" },
  { id: "rtf", name: "Rich Text", ext: ".rtf" },
  { id: "txt", name: "Plain text", ext: ".txt" },
];

const REFERENCES = /^(references?|reference list|bibliography|works cited|sources)$/i;

export function escapeHtml(s: string): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Pushes a document's own headings down so they sit under its binder heading. */
export function shiftHeadings(markdown: string, by: number): string {
  if (by <= 0) return markdown;
  let fence = false;
  return markdown
    .split("\n")
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) fence = !fence;
      if (fence) return line;
      const m = /^(#{1,6})(\s+.*)$/.exec(line);
      return m ? `${"#".repeat(Math.min(6, m[1].length + by))}${m[2]}` : line;
    })
    .join("\n");
}

type Section = { level: number; title: string; body: string; kind: "doc" | "folder"; topLevel: boolean };

/** Flattens what will be exported, in binder order. */
export function collectSections(roots: BinderNode[], sectionTitles: boolean): Section[] {
  const out: Section[] = [];
  const visit = (n: BinderNode, level: number) => {
    if (n.meta?.compile === false) return;
    // Atlantis: notes to self (```note blocks) never leave the Writer.
    const body = n.kind === "doc" ? stripNotes(String(n.body ?? "")).trim() : "";
    out.push({
      level,
      title: n.title,
      body: sectionTitles ? shiftHeadings(body, Math.min(level, 5)) : body,
      kind: n.kind,
      topLevel: level === 1,
    });
    n.children?.forEach((c) => visit(c, level + 1));
  };
  roots.forEach((r) => visit(r, 1));
  return out;
}

export function formatDate(iso?: string): string {
  const d = iso ? new Date(`${iso}T12:00:00`) : new Date();
  if (Number.isNaN(d.getTime())) return iso ?? "";
  return d.toLocaleDateString("en-AU", { day: "numeric", month: "long", year: "numeric" });
}

function css(preset: PresetId, opts: CompileOptions): string {
  const page = (extra = "") =>
    `@page { size: A4; margin: 2.54cm; ${opts.pageNumbers ? `@top-right { content: counter(page); font-size: 10pt; }` : ""} ${extra} }` +
    (opts.titlePage && preset !== "mla" ? "@page:first { @top-right { content: none; } }" : "");
  const base = `
    body { margin: 0; color: #000; background: #fff; -webkit-print-color-adjust: exact; }
    .page-break { break-before: page; page-break-before: always; }
    h1, h2, h3, h4, h5, h6 { break-after: avoid; page-break-after: avoid; }
    img { max-width: 100%; }
    table { border-collapse: collapse; margin: 0.6em 0; }
    td, th { border: 1px solid #888; padding: 4px 8px; vertical-align: top; }
    blockquote { margin: 0.6em 0 0.6em 1.27cm; }
    pre, code { font-family: "Courier New", monospace; font-size: 0.92em; }
    mark { background: #fff59d; }
    ul[data-type="taskList"] { list-style: none; padding-left: 0.4em; }
    ul[data-type="taskList"] li { display: flex; gap: 0.5em; }
    ul[data-type="taskList"] li > label { flex: 0 0 auto; }
    .title-page { text-align: center; }
    .title-page .tp-title { font-weight: bold; }
    .refs p { padding-left: 1.27cm; text-indent: -1.27cm; }
    .word-count { margin-top: 2em; font-style: italic; }
  `;
  switch (preset) {
    case "apa":
      return `${page()}${base}
        body { font-family: "Times New Roman", Times, serif; font-size: 12pt; line-height: 2; }
        p { margin: 0; text-indent: 1.27cm; }
        li p, td p, th p, blockquote p, .title-page p, .abstract p { text-indent: 0; }
        .refs p { text-indent: -1.27cm; }
        h1, h2, h3, h4, h5 { font-size: 12pt; margin: 0; line-height: 2; }
        h1 { text-align: center; font-weight: bold; }
        h2 { text-align: left; font-weight: bold; }
        h3 { text-align: left; font-weight: bold; font-style: italic; }
        h4 { font-weight: bold; margin-left: 1.27cm; }
        h5 { font-weight: bold; font-style: italic; margin-left: 1.27cm; }
        .title-page { padding-top: 6em; }
        .title-page .tp-title { margin-bottom: 2em; }
        .title-page p { margin: 0; }
        .doc-title { text-align: center; }
        .refs h1, .refs h2 { text-align: center; }`;
    case "mla":
      return `${page()}${base}
        body { font-family: "Times New Roman", Times, serif; font-size: 12pt; line-height: 2; }
        p { margin: 0; text-indent: 1.27cm; }
        li p, td p, th p, blockquote p, .mla-head p { text-indent: 0; }
        .refs p { text-indent: -1.27cm; }
        h1, h2, h3, h4, h5 { font-size: 12pt; margin: 0; font-weight: bold; line-height: 2; }
        .mla-head p { margin: 0; }
        .doc-title { text-align: center; font-weight: normal; }
        .refs h1, .refs h2 { text-align: center; font-weight: normal; }`;
    case "clean":
      return `${page()}${base}
        body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; font-size: 11pt; line-height: 1.5; }
        p { margin: 0 0 0.75em; }
        h1 { font-size: 20pt; margin: 1.2em 0 0.4em; }
        h2 { font-size: 15pt; margin: 1.1em 0 0.35em; }
        h3 { font-size: 12.5pt; margin: 1em 0 0.3em; }
        h4, h5, h6 { font-size: 11pt; margin: 0.9em 0 0.3em; }
        .title-page { padding-top: 30vh; }
        .title-page .tp-title { font-size: 28pt; margin-bottom: 0.6em; }
        .title-page p { margin: 0.2em 0; color: #444; }`;
    case "manuscript":
      return `${page()}${base}
        body { font-family: "Courier New", Courier, monospace; font-size: 12pt; line-height: 2; }
        p { margin: 0; text-indent: 1.27cm; }
        li p, td p, th p, blockquote p, .title-page p { text-indent: 0; }
        h1 { font-size: 12pt; text-align: center; font-weight: normal; text-transform: uppercase; margin: 8em 0 2em; }
        h2, h3, h4 { font-size: 12pt; text-align: center; font-weight: normal; margin: 1em 0; }
        hr { border: 0; text-align: center; } hr::after { content: "#"; }
        .title-page { padding-top: 35vh; }
        .title-page p { margin: 0; }`;
    default:
      return `${page()}${base}
        body { font-family: Arial, Helvetica, sans-serif; font-size: 12pt; line-height: 1.5; }
        p { margin: 0 0 0.8em; }
        h1 { font-size: 16pt; margin: 1em 0 0.4em; }
        h2 { font-size: 14pt; margin: 1em 0 0.35em; }
        h3 { font-size: 12pt; margin: 0.9em 0 0.3em; }
        h4, h5, h6 { font-size: 12pt; font-style: italic; margin: 0.8em 0 0.3em; }
        .title-page { padding-top: 28vh; }
        .title-page .tp-title { font-size: 24pt; margin-bottom: 1em; }
        .title-page p { margin: 0.3em 0; }`;
  }
}

function titlePageHtml(preset: PresetId, info: TitlePage, words: number): string {
  const line = (s: string) => (s ? `<p>${escapeHtml(s)}</p>` : "");
  const date = escapeHtml(info.date);
  if (preset === "mla") {
    return `<div class="mla-head">${line(info.author)}${line(info.teacher)}${line(info.subject)}<p>${date}</p></div><h1 class="doc-title">${escapeHtml(info.title)}</h1>`;
  }
  if (preset === "manuscript") {
    return `<div class="title-page"><p class="tp-title">${escapeHtml(info.title.toUpperCase())}</p><p>by ${escapeHtml(info.author || "…")}</p><p>&nbsp;</p><p>About ${Math.round(words / 100) * 100 || words} words</p></div><div class="page-break"></div>`;
  }
  if (preset === "apa") {
    return `<div class="title-page"><p class="tp-title">${escapeHtml(info.title)}</p>${line(info.author)}${line(info.school)}${line(info.subject)}${line(info.teacher)}<p>${date}</p></div><div class="page-break"></div>`;
  }
  return `<div class="title-page"><p class="tp-title">${escapeHtml(info.title)}</p>${line(info.author)}${line(info.subject)}${line(info.teacher)}${line(info.school)}<p>${date}</p></div><div class="page-break"></div>`;
}

export type CompileResult = { html: string; markdown: string; text: string; words: number; sections: number };

/**
 * Builds the export. `toHtml` turns one document's Markdown into HTML (the editor's own renderer
 * in the app; injected so this stays testable).
 */
export function compile(roots: BinderNode[], opts: CompileOptions, toHtml: (md: string) => string): CompileResult {
  const sections = collectSections(roots, opts.sectionTitles);
  const words = sections.reduce((n, s) => n + countWords(s.body), 0);
  const info = opts.info;
  const htmlParts: string[] = [];
  const mdParts: string[] = [];

  if (opts.titlePage) {
    htmlParts.push(titlePageHtml(opts.preset, info, words));
    if (opts.preset === "apa") htmlParts.push(`<h1 class="doc-title">${escapeHtml(info.title)}</h1>`);
    mdParts.push(`# ${info.title}`, [info.author, info.subject, info.teacher, info.school, info.date].filter(Boolean).join(" · "));
  }

  let first = true;
  let inRefs = false;
  let refsLevel = 0;
  for (const s of sections) {
    if (inRefs && s.level <= refsLevel) {
      htmlParts.push("</div>");
      inRefs = false;
    }
    const isRefs = REFERENCES.test(s.title.trim());
    const isAbstract = opts.preset === "apa" && /^abstract$/i.test(s.title.trim());
    const chapterBreak = opts.preset === "manuscript" && s.topLevel && s.kind === "folder" && !first;
    const refsBreak = isRefs && (opts.preset === "apa" || opts.preset === "mla") && !first;
    if (chapterBreak || refsBreak) htmlParts.push(`<div class="page-break"></div>`);
    if (isRefs && !inRefs) {
      htmlParts.push(`<div class="refs">`);
      inRefs = true;
      refsLevel = s.level;
    }
    if (opts.sectionTitles) {
      const level = Math.min(6, s.level);
      const title = opts.preset === "mla" && isRefs ? "Works Cited" : s.title;
      htmlParts.push(`<h${level}>${escapeHtml(title)}</h${level}>`);
      mdParts.push(`${"#".repeat(Math.min(6, level + (opts.titlePage ? 1 : 0)))} ${title}`);
    }
    if (s.body) {
      const body = DOMPurify.sanitize(toHtml(s.body), { USE_PROFILES: { html: true } });
      htmlParts.push(isAbstract ? `<div class="abstract">${body}</div>` : body);
      mdParts.push(opts.titlePage && opts.sectionTitles ? shiftHeadings(s.body, 1) : s.body);
    }
    if (isAbstract) htmlParts.push(`<div class="page-break"></div>`);
    first = false;
  }
  if (inRefs) htmlParts.push("</div>");
  if (opts.wordCount) {
    htmlParts.push(`<p class="word-count">Word count: ${words.toLocaleString("en-AU")}</p>`);
    mdParts.push(`_Word count: ${words.toLocaleString("en-AU")}_`);
  }

  const bodyHtml = htmlParts.join("\n");
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(info.title)}</title>
<style>${css(opts.preset, opts)}</style></head>
<body>
${bodyHtml}
</body></html>
`;
  const markdown = mdParts.filter((p) => p.trim()).join("\n\n") + "\n";
  return { html, markdown, text: htmlToText(bodyHtml), words, sections: sections.length };
}

/** Plain text with blank lines between blocks and "•" bullets. */
export function htmlToText(html: string): string {
  if (typeof DOMParser === "undefined") return html.replace(/<[^>]+>/g, "");
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, "text/html");
  doc.querySelectorAll("li").forEach((li) => li.prepend("• "));
  doc.querySelectorAll("br").forEach((br) => br.replaceWith("\n"));
  doc.querySelectorAll("p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,tr,.page-break").forEach((n) => n.append("\n\n"));
  doc.querySelectorAll("td,th").forEach((n) => n.append("\t"));
  return (doc.body.textContent ?? "")
    .replace(/ /g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
    .concat("\n");
}
