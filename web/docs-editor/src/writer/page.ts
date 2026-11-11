import {
  countWords,
  docsUnder,
  excerpt,
  findNode,
  isInTrash,
  parentOf,
  walk,
  wordsUnder,
  writerApi,
  type BinderNode,
  type DocMeta,
  type ExportFormat,
  type Project,
  type ProjectSettings,
  type ProjectSummary,
  type Snapshot,
} from "./api";
import {
  BLOCK_STYLES,
  createEditor,
  currentBlockStyle,
  htmlToMarkdown,
  markdownToHtml,
  setBlockStyle,
  SLASH_ITEMS,
  type BlockStyle,
  type Editor,
} from "./editor";
import { call } from "./fs";
import { filterBots, findMention, mentionQuery, type MentionBot, type MentionRequest } from "./mentions";
import { commentKey, contextBefore, findKey, locateQuote, reviewKey, reviewRanges, type Comment, type FindMeta, type Range } from "./plugins";
import { diffSummary, diffWords, minutesLabel, plainText, textStats } from "./stats";
import { hitAt, hitsIn, isSoft, KIND_LABEL, previewParts, proofBlocks, proofKey, Proofreader, type ProofHit } from "./proofread";
import {
  addToReferenceList,
  authorsToText,
  CITE_STYLES,
  formatReference,
  inTextCitation,
  REF_KINDS,
  sortKey,
  textToAuthors,
  type CiteStyle,
  type Reference,
  type RefKind,
} from "./cite";
import type { EditorView } from "@tiptap/pm/view";
import { compile, formatDate, FORMATS, PRESETS, type CompileOptions, type PresetId } from "./compile";
import {
  guessTemplate,
  itemsForAssessment,
  labelColour,
  LABELS,
  STATUSES,
  templateById,
  TEMPLATES,
  type AssessmentInfo,
} from "./templates";
import { ICONS, type IconName } from "./icons";
import { IMAGE_ERROR_EVENT, setImageTarget } from "./images";
import { groupHits, hitSummary, type SearchGroup } from "./search";
import type { SearchHit, SearchResult, SearchSnippet } from "./fs";
import { followTheme } from "./theme";
import { measure, parseRecord, RecordKeeper, summarise, type RecordLine } from "./record";
import { recordHtml, recordReport, type RecordViewInfo } from "./recordView";
import "./page.css";

/**
 * The Writer: a Scrivener-style writing studio. Copied from BetterSEQTA+ (src/plugins/built-in/
 * writer, MIT) into Atlantis Docs; changes are marked "Atlantis:".
 *
 *   binder (Draft / Research / Notes / Trash)  │  editor · corkboard · outliner  │  inspector
 *
 * Projects are folders of Markdown files on this Mac, read and written through seqta-mcp. The
 * editor is a word processor (tiptap) that saves plain Markdown; exports go through "compile".
 */

export const ROOT_ID = "bsplus-writer";
const PREFS_KEY = "bsplus-writer-prefs";
const SAVE_DELAY = 700;
/** Atlantis: how often a version is kept while you write (see autoSnapshot). */
const AUTO_VERSION_MS = 10 * 60_000;

type ViewMode = "doc" | "cork" | "outline";
type InspectorTab = "info" | "contents" | "comments" | "history";

type Prefs = {
  binder: boolean;
  inspector: boolean;
  zoom: number;
  font: "serif" | "sans" | "mono";
  paper: "page" | "theme";
  spacing: number;
  width: number;
  typewriter: boolean;
  inspectorTab: InspectorTab;
  focusLine: boolean;
  review: boolean;
  /** Spelling & grammar checks as you write (Claude Haiku via seqta-mcp). */
  proof: boolean;
  tipsSeen: boolean;
  /** Words in the Draft at the start of each day, per project (for "+N today"). */
  today: Record<string, { date: string; start: number }>;
  autoSnap: Record<string, number>;
  lastProject?: string;
  selected: Record<string, string>;
  views: Record<string, ViewMode>;
  expanded: Record<string, string[]>;
};

const DEFAULT_PREFS: Prefs = {
  binder: true,
  inspector: true,
  zoom: 1,
  font: "sans",
  paper: "page",
  spacing: 1.6,
  width: 740,
  typewriter: false,
  inspectorTab: "info",
  focusLine: true,
  review: false,
  proof: false,
  tipsSeen: false,
  today: {},
  autoSnap: {},
  selected: {},
  views: {},
  expanded: {},
};

function loadPrefs(): Prefs {
  try {
    const raw = JSON.parse(localStorage.getItem(PREFS_KEY) ?? "{}");
    return { ...DEFAULT_PREFS, ...(raw && typeof raw === "object" ? raw : {}) };
  } catch {
    return { ...DEFAULT_PREFS };
  }
}

export type WriterHost = {
  settings: () => { folder: string; author: string; citeAi?: boolean };
};

// ── DOM helper ──────────────────────────────────────────────────────────────

type Child = Node | string | null | undefined | false;
type Props = {
  class?: string;
  text?: string;
  /** Only for the static icons in icons.ts. */
  icon?: IconName;
  title?: string;
  attrs?: Record<string, string>;
  on?: { [K in keyof HTMLElementEventMap]?: (e: HTMLElementEventMap[K]) => void };
};

function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Props = {}, children: Child[] = []): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (props.class) node.className = props.class;
  if (props.icon) node.innerHTML = ICONS[props.icon];
  if (props.text !== undefined) node.append(props.text);
  if (props.title) {
    node.title = props.title;
    if (tag === "button" && !props.text) node.setAttribute("aria-label", props.title);
  }
  for (const [k, v] of Object.entries(props.attrs ?? {})) node.setAttribute(k, v);
  for (const [k, fn] of Object.entries(props.on ?? {})) node.addEventListener(k, fn as EventListener);
  if (tag === "button" && !node.hasAttribute("type")) node.setAttribute("type", "button");
  for (const c of children) if (c !== null && c !== undefined && c !== false) node.append(c);
  return node;
}

const iconBtn = (icon: IconName, title: string, onClick: (e: MouseEvent) => void, cls = "") =>
  h("button", { class: `wr-icon-btn ${cls}`.trim(), icon, title, on: { click: onClick } });

const fmt = (n: number) => n.toLocaleString("en-AU");

/** `text` with the first (case-insensitive) match of `query` in a <mark>. */
function highlight(text: string, query: string): Child[] {
  const at = text.toLowerCase().indexOf(query.toLowerCase());
  if (at < 0 || !query) return [text];
  return [text.slice(0, at), h("mark", { text: text.slice(at, at + query.length) }), text.slice(at + query.length)];
}

function daysUntil(iso?: string): number | null {
  if (!iso || !/^\d{4}-\d\d-\d\d/.test(iso)) return null;
  const due = new Date(`${iso.slice(0, 10)}T00:00:00`);
  const now = new Date();
  now.setHours(0, 0, 0, 0);
  return Math.round((due.getTime() - now.getTime()) / 86_400_000);
}

function dueLabel(iso?: string): string {
  const d = daysUntil(iso);
  if (d === null) return "";
  if (d < 0) return `${-d} day${d === -1 ? "" : "s"} overdue`;
  if (d === 0) return "due today";
  if (d === 1) return "due tomorrow";
  return `due in ${d} days`;
}

function nodeIcon(n: BinderNode, open = false): IconName {
  if (n.role) return n.role as IconName;
  if (n.kind === "folder") return "folder";
  void open;
  return n.body && n.body.trim() ? "docText" : "doc";
}

/** The References doc: formatted citations, so the spelling & grammar check skips it. */
function isRefList(n: BinderNode): boolean {
  return n.meta.label === "References" || /^(references?|reference list|bibliography|works cited)$/i.test(n.title.trim());
}

function readAsBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).replace(/^data:[^,]*,/, ""));
    r.onerror = () => reject(r.error ?? new Error("Couldn't read the file."));
    r.readAsDataURL(file);
  });
}

// ── Page ────────────────────────────────────────────────────────────────────

export class WriterPage {
  readonly root: HTMLElement;
  private prefs = loadPrefs();
  private dir = "";
  private projects: ProjectSummary[] = [];
  private project: Project | null = null;
  private selected: string | null = null;
  private history: string[] = [];
  private future: string[] = [];
  private editors = new Map<string, Editor>();
  private activeEditor: Editor | null = null;
  private timers = new Map<string, ReturnType<typeof setTimeout>>();
  private saving = 0;
  private saveError = "";
  private search = "";
  private stopTheme: (() => void) | null = null;
  private els: Record<string, HTMLElement> = {};
  private menu: HTMLElement | null = null;
  private modal: HTMLElement | null = null;
  private dragPath: string | null = null;
  private stopped = false;
  private find = { open: false, replace: false, query: "", caseSensitive: false, index: 0 };
  private slash: { editor: Editor; from: number; index: number; el: HTMLElement } | null = null;
  // Atlantis M6: @mentions. The popup lists bots that can be mentioned; the chip asks one.
  private mention: { editor: Editor; from: number; index: number; el: HTMLElement } | null = null;
  private mentionBots: MentionBot[] | null = null;
  private mentionBotsLoad: Promise<void> | null = null;
  private askChip: { el: HTMLElement; editor: Editor; req: MentionRequest } | null = null;
  private asking = false;
  private bubble: HTMLElement | null = null;
  private activeComment: string | null = null;
  private editingComment: string | null = null;
  private proof = new Proofreader(
    (paragraphs) => writerApi.proofread(paragraphs),
    (what) => this.onProof(what),
  );

  constructor(private host: WriterHost) {
    this.root = h("div", { attrs: { id: ROOT_ID } });
    this.root.className = "wr";
    this.root.addEventListener("keydown", (e) => this.onKey(e));
    document.addEventListener("pointerdown", this.onOutside, true);
    document.addEventListener("keydown", this.onDocKey, true);
    document.addEventListener("visibilitychange", this.onVisible);
    window.addEventListener("beforeunload", this.flushOnUnload);
    window.addEventListener(IMAGE_ERROR_EVENT, this.onImageError);
  }

  async start(): Promise<void> {
    this.stopTheme = followTheme(this.root);
    this.applyPrefs();
    this.renderLoading("Opening your projects…");
    try {
      const folder = this.host.settings().folder;
      const { dir } = await writerApi.setDir(folder);
      this.dir = dir;
      await this.refreshProjects();
      const last = this.prefs.lastProject;
      if (last && this.projects.some((p) => p.id === last)) await this.openProject(last);
      else this.renderHome();
    } catch (err) {
      this.renderOffline(err);
    }
  }

  stop(): void {
    this.stopped = true;
    this.proof.stop();
    void this.flushAll();
    this.destroyEditors();
    this.stopTheme?.();
    document.removeEventListener("pointerdown", this.onOutside, true);
    document.removeEventListener("keydown", this.onDocKey, true);
    document.removeEventListener("visibilitychange", this.onVisible);
    window.removeEventListener("beforeunload", this.flushOnUnload);
    window.removeEventListener(IMAGE_ERROR_EVENT, this.onImageError);
    this.root.remove();
  }

  // ── prefs ──
  private savePrefs(): void {
    try {
      localStorage.setItem(PREFS_KEY, JSON.stringify(this.prefs));
    } catch {}
  }

  private applyPrefs(): void {
    const p = this.prefs;
    this.root.classList.toggle("no-binder", !p.binder);
    this.root.classList.toggle("no-inspector", !p.inspector);
    this.root.classList.toggle("paper-page", p.paper === "page");
    this.root.dataset.font = p.font;
    this.root.classList.toggle("focus-line", p.focusLine);
    this.root.style.setProperty("--wr-zoom", String(p.zoom));
    this.root.style.setProperty("--wr-spacing", String(p.spacing));
    this.root.style.setProperty("--wr-width", `${p.width}px`);
  }

  // ── simple screens ──
  private renderLoading(text: string): void {
    this.root.replaceChildren(h("div", { class: "wr-empty" }, [h("div", { class: "wr-spinner" }), h("p", { text })]));
  }

  private renderOffline(err: unknown): void {
    const msg = err instanceof Error ? err.message : String(err);
    this.root.replaceChildren(
      h("div", { class: "wr-empty" }, [
        h("div", { class: "wr-empty-icon", icon: "page" }),
        h("h2", { text: "Writer can't reach your files" }),
        h("p", {
          text: "Writer keeps projects as Markdown files on this Mac through seqta-mcp. Make sure it's running, then try again.",
        }),
        h("p", { class: "wr-muted", text: msg }),
        h("button", { class: "wr-btn wr-btn-primary", text: "Try again", on: { click: () => void this.start() } }),
      ]),
    );
  }

  private async refreshProjects(): Promise<void> {
    const r = await writerApi.projects();
    this.dir = r.dir;
    this.projects = r.projects;
  }

  // ── Home: project list ───────────────────────────────────────────────────
  private renderHome(): void {
    this.destroyEditors();
    this.project = null;
    this.prefs.lastProject = undefined;
    this.savePrefs();
    const grid = h("div", { class: "wr-proj-grid" });
    grid.append(
      h("button", { class: "wr-proj-card wr-proj-new", on: { click: () => this.openTemplatePicker() } }, [
        h("span", { class: "wr-proj-new-plus", icon: "plus" }),
        h("strong", { text: "New project" }),
        h("span", { class: "wr-muted", text: "Essay, report, APA paper, story…" }),
      ]),
      h("button", { class: "wr-proj-card wr-proj-new", on: { click: () => void this.openAssessmentPicker() } }, [
        h("span", { class: "wr-proj-new-plus", icon: "school" }),
        h("strong", { text: "From a SEQTA assessment" }),
        h("span", { class: "wr-muted", text: "Task sheet, criteria and due date filled in" }),
      ]),
    );
    // Due soonest first (overdue at the top), then the rest by last edit.
    const sorted = [...this.projects].sort((a, b) => {
      const da = daysUntil(a.settings.deadline);
      const db = daysUntil(b.settings.deadline);
      const ka = da === null || da < -14 ? 1e6 : da;
      const kb = db === null || db < -14 ? 1e6 : db;
      return ka - kb || String(b.updated ?? "").localeCompare(String(a.updated ?? ""));
    });
    for (const p of sorted) {
      const due = dueLabel(p.settings.deadline);
      const days = daysUntil(p.settings.deadline);
      const card = h("button", { class: "wr-proj-card", on: { click: () => void this.openProject(p.id) } }, [
        h("div", { class: "wr-proj-top" }, [
          h("span", { class: "wr-proj-icon", text: templateById(p.settings.template ?? "blank").icon }),
          due ? h("span", { class: `wr-due ${days !== null && days <= 2 ? "is-soon" : ""} ${days !== null && days < 0 ? "is-late" : ""}`, text: due }) : null,
        ]),
        h("strong", { text: p.title }),
        h("span", { class: "wr-muted", text: [p.settings.subject, p.settings.target ? `${fmt(p.settings.target)} words` : ""].filter(Boolean).join(" · ") || "Project" }),
        p.updated ? h("span", { class: "wr-faint", text: `Edited ${new Date(p.updated).toLocaleDateString("en-AU", { day: "numeric", month: "short" })}` }) : null,
      ]);
      card.addEventListener("contextmenu", (e) => {
        e.preventDefault();
        this.showMenu(e, [
          { label: "Open", run: () => void this.openProject(p.id) },
          { label: "Duplicate", run: () => void this.duplicateProject(p.id) },
          { label: "Show in Finder", run: () => void writerApi.openFile(`${this.dir}/${p.id}`, true).catch((er) => this.toast(er)) },
          "-",
          { label: "Delete project…", danger: true, run: () => void this.deleteProject(p.id, p.title) },
        ]);
      });
      grid.append(card);
    }
    const home = h("div", { class: "wr-home" }, [
      h("header", { class: "wr-home-head" }, [
        h("div", {}, [
          h("h1", { text: "Writer" }),
          h("p", { class: "wr-muted", text: "Plan, draft and export your assignments. Everything is saved as Markdown files on your Mac." }),
        ]),
        h("div", { class: "wr-home-actions" }, [
          h("button", { class: "wr-btn", title: "Search every project (⌘⇧F)", on: { click: () => this.openSearchAll() } }, [h("span", { icon: "find" }), "Search"]), // Atlantis
          h("button", {
            class: "wr-btn",
            title: this.dir,
            on: { click: () => void writerApi.openFile(this.dir, false).catch((e) => this.toast(e)) },
          }, [h("span", { icon: "finder" }), "Open folder"]),
        ]),
      ]),
      grid,
      this.projects.length ? null : h("p", { class: "wr-muted wr-home-hint", text: "No projects yet. Start one above, or put a folder of .md files in the Writer folder." }),
    ]);
    this.root.replaceChildren(home);
  }

  private openTemplatePicker(preset?: { assessment: AssessmentInfo; details: unknown }): void {
    let chosen = preset ? guessTemplate(preset.assessment.title) : "essay";
    const title = h("input", {
      class: "wr-input",
      attrs: { placeholder: "Project name", value: preset?.assessment.title.trim() ?? "" },
    });
    const list = h("div", { class: "wr-tpl-grid" });
    const draw = () => {
      list.replaceChildren(
        ...TEMPLATES.map((t) =>
          h("button", {
            class: `wr-tpl ${t.id === chosen ? "is-on" : ""}`,
            on: {
              click: () => {
                chosen = t.id;
                draw();
              },
              dblclick: () => void go(),
            },
          }, [h("span", { class: "wr-tpl-icon", text: t.icon }), h("strong", { text: t.name }), h("span", { class: "wr-muted", text: t.description })]),
        ),
      );
    };
    draw();
    const go = async () => {
      const t = templateById(chosen);
      const name = title.value.trim() || (chosen === "blank" ? "Untitled Project" : t.name);
      this.closeModal();
      this.renderLoading("Setting up your project…");
      try {
        const { items, settings } = preset
          ? itemsForAssessment(t, preset.assessment, preset.details)
          : { items: t.items, settings: { template: t.id, export: { preset: t.preset } } as ProjectSettings };
        const p = await writerApi.create(name, items, { author: this.host.settings().author || undefined, ...settings });
        await this.refreshProjects();
        await this.openProject(p.id, p);
      } catch (err) {
        this.toast(err);
        this.renderHome();
      }
    };
    title.addEventListener("keydown", (e) => {
      if (e.key === "Enter") void go();
    });
    this.openModal(preset ? `New project: ${preset.assessment.title.trim()}` : "Choose a template", [title, list], [
      h("button", { class: "wr-btn", text: "Cancel", on: { click: () => this.closeModal() } }),
      h("button", { class: "wr-btn wr-btn-primary", text: "Create", on: { click: () => void go() } }),
    ], "wide");
    setTimeout(() => title.focus(), 30);
  }

  private async openAssessmentPicker(): Promise<void> {
    const body = h("div", { class: "wr-assess-list" }, [h("div", { class: "wr-spinner" })]);
    this.openModal("Start from an assessment", [body], [h("button", { class: "wr-btn", text: "Cancel", on: { click: () => this.closeModal() } })]);
    try {
      const tools = await import("./seqtaTools");
      const all = (await tools.upcomingAssessments()) as AssessmentInfo[];
      const today = new Date().toISOString().slice(0, 10);
      const open = all.filter((a) => !a.due || a.due >= today || a.status === "OVERDUE" || a.status === "UPCOMING");
      open.sort((a, b) => Number(b.status === "UPCOMING") - Number(a.status === "UPCOMING") || String(a.due).localeCompare(String(b.due)));
      if (!open.length) {
        body.replaceChildren(h("p", { class: "wr-muted", text: "No upcoming assessments in SEQTA." }));
        return;
      }
      body.replaceChildren(
        ...open.map((a) =>
          h("button", {
            class: "wr-assess",
            on: {
              click: async () => {
                body.replaceChildren(h("div", { class: "wr-spinner" }));
                let details: unknown = {};
                try {
                  if (a.metaclass) details = await tools.assessmentDetails(Number(a.id), Number(a.metaclass));
                } catch {}
                this.closeModal();
                this.openTemplatePicker({ assessment: a, details });
              },
            },
          }, [
            h("strong", { text: a.title.trim() }),
            h("span", { class: "wr-muted", text: `${a.subject} · ${a.due ? formatDate(a.due) : "no due date"}${a.status === "OVERDUE" ? " · overdue" : ""}` }),
          ]),
        ),
      );
    } catch (err) {
      body.replaceChildren(h("p", { class: "wr-muted", text: `Couldn't load assessments: ${err instanceof Error ? err.message : String(err)}` }));
    }
  }

  private async duplicateProject(id: string): Promise<void> {
    try {
      await writerApi.duplicateProject(id);
      await this.refreshProjects();
      this.renderHome();
    } catch (err) {
      this.toast(err);
    }
  }

  private async deleteProject(id: string, title: string): Promise<void> {
    if (!(await this.confirm(`Delete “${title}”?`, "It's moved to a hidden .deleted folder inside your Writer folder, so you can get it back from Finder.", "Delete"))) return;
    try {
      await writerApi.removeProject(id);
      await this.refreshProjects();
      this.renderHome();
    } catch (err) {
      this.toast(err);
    }
  }

  // ── Project ──────────────────────────────────────────────────────────────
  async openProject(id: string, loaded?: Project): Promise<void> {
    await this.flushAll();
    this.destroyEditors();
    if (!loaded) this.renderLoading("Opening…");
    try {
      this.project = loaded ?? (await writerApi.open(id));
    } catch (err) {
      this.toast(err);
      await this.refreshProjects().catch(() => {});
      this.renderHome();
      return;
    }
    this.prefs.lastProject = id;
    this.savePrefs();
    this.history = [];
    this.future = [];
    const p = this.project;
    const remembered = this.prefs.selected[id];
    const firstDoc = docsUnder(p.tree[0])[0]?.path ?? p.tree[0].path;
    this.selected = remembered && findNode(p.tree, remembered) ? remembered : firstDoc;
    if (!this.prefs.expanded[id]) {
      const open: string[] = [];
      walk(p.tree, (n, depth) => {
        if (n.kind === "folder" && depth < 2 && n.role !== "trash") open.push(n.path);
      });
      this.prefs.expanded[id] = open;
    }
    this.renderShell();
  }

  /** Reloads the tree from disk (after a move/rename) and keeps the selection when it still exists. */
  private async reload(select?: string | null): Promise<void> {
    if (!this.project) return;
    await this.flushAll();
    try {
      this.project = await writerApi.open(this.project.id);
    } catch (err) {
      this.toast(err);
      return;
    }
    const want = select === undefined ? this.selected : select;
    this.selected = want && findNode(this.project.tree, want) ? want : (docsUnder(this.project.tree[0])[0]?.path ?? this.project.tree[0].path);
    this.renderBinder();
    this.renderMain();
    this.renderInspector();
    this.renderFooter();
  }

  private get expanded(): Set<string> {
    const id = this.project?.id ?? "";
    return new Set(this.prefs.expanded[id] ?? []);
  }

  private setExpanded(path: string, open: boolean): void {
    if (!this.project) return;
    const set = this.expanded;
    if (open) set.add(path);
    else set.delete(path);
    this.prefs.expanded[this.project.id] = [...set];
    this.savePrefs();
  }

  private get node(): BinderNode | null {
    return this.project && this.selected ? findNode(this.project.tree, this.selected) : null;
  }

  private viewFor(n: BinderNode | null): ViewMode {
    if (!n || n.kind === "doc") return "doc";
    return this.prefs.views[`${this.project?.id}:${n.path}`] ?? (n.role ? "cork" : "doc");
  }

  private renderShell(): void {
    const p = this.project!;
    const top = h("div", { class: "wr-top" });
    const format = h("div", { class: "wr-format" });
    const binder = h("aside", { class: "wr-binder" });
    const main = h("section", { class: "wr-main" });
    const inspector = h("aside", { class: "wr-inspector" });
    const foot = h("footer", { class: "wr-foot" });
    this.els = { top, format, binder, main, inspector, foot };
    this.root.replaceChildren(top, format, h("div", { class: "wr-body" }, [binder, main, inspector]), foot);

    // Top toolbar, after Scrivener's: binder · project · add/trash · title · views · compose/export · inspector.
    const addBtn = iconBtn("plus", "Add", (e) =>
      this.showMenu(e, [
        { label: "New document", hint: "⌥⌘N", run: () => void this.addItem("doc") },
        { label: "New folder", run: () => void this.addItem("folder") },
        "-",
        { label: "Import file… (.docx, .md, .rtf, .odt)", run: () => this.importFile() },
      ]),
    );
    const projectBtn = h("button", { class: "wr-proj-btn", title: "Project", on: { click: (e) => this.projectMenu(e) } }, [
      h("span", { class: "wr-proj-btn-title", text: p.title }),
      h("span", { icon: "chevronDown" }),
    ]);
    const viewBtn = (id: ViewMode, icon: IconName, label: string, title: string) =>
      h("button", { class: `wr-view-btn seg-${id}`, title, on: { click: () => this.setView(id) } }, [h("span", { icon }), h("span", { class: "wr-view-label", text: label })]);
    const views = h("div", { class: "wr-seg", attrs: { role: "group", "aria-label": "View" } }, [
      viewBtn("doc", "page", "Write", "Write: the text (a folder shows all its documents in one page) · ⌃1"),
      viewBtn("cork", "cork", "Cards", "Cards: one index card per document, drag to reorder · ⌃2"),
      viewBtn("outline", "outline", "Outline", "Outline: titles, synopses, status and word counts · ⌃3"),
    ]);
    top.append(
      h("div", { class: "wr-top-group" }, [
        iconBtn("binder", "Show/hide binder (⌥⌘1)", () => this.togglePanel("binder")),
        h("button", { class: "wr-icon-btn", icon: "back", title: "All projects", on: { click: () => void this.goHome() } }),
        projectBtn,
      ]),
      h("div", { class: "wr-top-group" }, [
        addBtn,
        iconBtn("trash", "Move to Trash", () => this.selected && void this.trashItem(this.selected)),
        iconBtn("search", "Go to… (⌘O)", () => this.openPalette()),
        iconBtn("find", "Search all projects (⌘⇧F)", () => this.openSearchAll()), // Atlantis
      ]),
      h("nav", { class: "wr-top-title", attrs: { "data-title": "", "aria-label": "Location" } }),
      h("div", { class: "wr-top-group" }, [views]),
      h("div", { class: "wr-top-group" }, [
        iconBtn("aa", "Editor appearance", (e) => this.appearanceMenu(e)),
        iconBtn("compose", "Focus mode (⌘⇧D)", () => this.toggleCompose()), // Atlantis: ⌘⇧F is search across projects now
        h("button", { class: "wr-btn wr-btn-primary wr-export-btn", on: { click: () => this.openExport() } }, [h("span", { icon: "export" }), "Export"]),
        iconBtn("inspector", "Show/hide inspector (⌥⌘I)", () => this.togglePanel("inspector")),
      ]),
    );

    this.renderFormatBar();
    this.renderBinder();
    this.renderMain();
    this.renderInspector();
    this.renderFooter();
    setTimeout(() => this.showTips(), 600);
  }

  private async goHome(): Promise<void> {
    await this.flushAll();
    this.root.classList.remove("is-compose");
    await this.refreshProjects().catch(() => {});
    this.renderHome();
  }

  private togglePref(key: "binder" | "inspector"): void {
    this.prefs[key] = !this.prefs[key];
    this.savePrefs();
    this.applyPrefs();
  }

  private setView(view: ViewMode): void {
    const n = this.node;
    if (!n || !this.project) return;
    if (n.kind === "doc") {
      if (view === "doc") return;
      // Scrivener shows a document's folder on the corkboard/outliner.
      const parent = parentOf(this.project.tree, n.path);
      if (!parent) return;
      this.prefs.views[`${this.project.id}:${parent.path}`] = view;
      this.savePrefs();
      this.select(parent.path);
      return;
    }
    this.prefs.views[`${this.project.id}:${n.path}`] = view;
    this.savePrefs();
    this.renderMain();
  }

  select(path: string, opts: { history?: boolean } = {}): void {
    if (!this.project || path === this.selected) return;
    if (opts.history !== false && this.selected) {
      this.history.push(this.selected);
      this.future = [];
    }
    this.selected = path;
    this.root.classList.remove("drawer-binder");
    this.prefs.selected[this.project.id] = path;
    this.savePrefs();
    // Open the folders above it.
    let parent = parentOf(this.project.tree, path);
    while (parent) {
      this.setExpanded(parent.path, true);
      parent = parentOf(this.project.tree, parent.path);
    }
    this.renderBinder();
    this.renderMain();
    this.renderInspector();
    this.renderFooter();
  }

  private goBack(): void {
    const prev = this.history.pop();
    if (!prev || !this.project || !findNode(this.project.tree, prev)) return;
    if (this.selected) this.future.push(this.selected);
    this.select(prev, { history: false });
  }

  private goForward(): void {
    const next = this.future.pop();
    if (!next || !this.project || !findNode(this.project.tree, next)) return;
    if (this.selected) this.history.push(this.selected);
    this.select(next, { history: false });
  }

  // ── Binder ───────────────────────────────────────────────────────────────
  private renderBinder(): void {
    const box = this.els.binder;
    if (!box || !this.project) return;
    const p = this.project;
    const searchInput = h("input", {
      class: "wr-input wr-search",
      attrs: { placeholder: "Search project", type: "search", value: this.search },
    });
    searchInput.addEventListener("input", () => {
      this.search = searchInput.value;
      this.renderBinderList();
    });
    searchInput.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        this.search = "";
        searchInput.value = "";
        this.renderBinderList();
      }
    });
    const list = h("div", { class: "wr-tree", attrs: { role: "tree" } });
    this.els.tree = list;
    box.replaceChildren(searchInput, list);
    this.renderBinderList();
    void p;
  }

  private renderBinderList(): void {
    const list = this.els.tree;
    if (!list || !this.project) return;
    list.replaceChildren();
    const q = this.search.trim().toLowerCase();
    if (q) {
      const hits: BinderNode[] = [];
      walk(this.project.tree, (n) => {
        if (n.role) return;
        if (n.title.toLowerCase().includes(q) || (n.body ?? "").toLowerCase().includes(q) || (n.meta.synopsis ?? "").toLowerCase().includes(q)) hits.push(n);
      });
      if (!hits.length) list.append(h("p", { class: "wr-muted wr-pad", text: "Nothing matches." }));
      for (const n of hits) {
        const row = this.binderRow(n, 0, false);
        if (n.kind === "doc") {
          const snippet = this.searchSnippet(n.body ?? "", q);
          if (snippet) row.append(h("span", { class: "wr-row-snippet", text: snippet }));
          row.classList.add("has-snippet");
          row.addEventListener("click", () => setTimeout(() => this.openFind(false, this.search.trim()), 0));
        }
        list.append(row);
      }
      return;
    }
    const open = this.expanded;
    const add = (nodes: BinderNode[], depth: number) => {
      for (const n of nodes) {
        list.append(this.binderRow(n, depth, true, open.has(n.path)));
        if (n.children && open.has(n.path)) add(n.children, depth + 1);
      }
    };
    add(this.project.tree, 0);
  }

  private binderRow(n: BinderNode, depth: number, tree: boolean, isOpen = false): HTMLElement {
    const hasKids = n.kind === "folder" && (n.children?.length ?? 0) > 0;
    const twisty = h("span", {
      class: `wr-twisty ${hasKids && tree ? "" : "is-empty"} ${isOpen ? "is-open" : ""}`,
      icon: "chevron",
      on: {
        click: (e) => {
          e.stopPropagation();
          if (!hasKids) return;
          this.setExpanded(n.path, !isOpen);
          this.renderBinderList();
        },
      },
    });
    const colour = labelColour(n.meta.label);
    const row = h("div", {
      class: `wr-row ${n.path === this.selected ? "is-selected" : ""} ${n.role ? `is-role role-${n.role}` : ""} ${n.meta.compile === false ? "is-excluded" : ""}`,
      attrs: {
        role: "treeitem",
        tabindex: n.path === this.selected ? "0" : "-1",
        draggable: n.role ? "false" : "true",
        "data-path": n.path,
        ...(hasKids ? { "aria-expanded": String(isOpen) } : {}),
      },
      on: {
        click: () => this.select(n.path),
        dblclick: (e) => {
          if ((e.target as HTMLElement).closest(".wr-twisty")) return;
          if (!n.role) this.startRename(row, n);
        },
        contextmenu: (e) => {
          e.preventDefault();
          this.binderMenu(e, n);
        },
      },
    }, [
      twisty,
      h("span", { class: "wr-row-icon", icon: nodeIcon(n, isOpen) }),
      h("span", { class: "wr-row-title", text: n.title }),
      colour ? h("span", { class: "wr-dot", attrs: { style: `background:${colour}` }, title: n.meta.label }) : null,
      n.role === "trash" && (n.children?.length ?? 0) > 0 ? h("span", { class: "wr-count", text: String(n.children!.length) }) : null,
    ]);
    row.style.setProperty("--depth", String(depth));
    if (tree) this.wireDrag(row, n);
    return row;
  }

  private wireDrag(row: HTMLElement, n: BinderNode): void {
    row.addEventListener("dragstart", (e) => {
      this.dragPath = n.path;
      e.dataTransfer?.setData("text/plain", n.title);
      if (e.dataTransfer) e.dataTransfer.effectAllowed = "move";
      row.classList.add("is-dragging");
    });
    row.addEventListener("dragend", () => {
      this.dragPath = null;
      row.classList.remove("is-dragging");
      this.root.querySelectorAll(".drop-before,.drop-after,.drop-inside").forEach((x) => x.classList.remove("drop-before", "drop-after", "drop-inside"));
    });
    const zone = (e: DragEvent): "before" | "after" | "inside" => {
      const r = row.getBoundingClientRect();
      const y = (e.clientY - r.top) / r.height;
      if (n.kind === "folder" && (n.role || (y > 0.25 && y < 0.75))) return "inside";
      return y < 0.5 ? "before" : "after";
    };
    row.addEventListener("dragover", (e) => {
      if (!this.dragPath || this.dragPath === n.path || n.path.startsWith(`${this.dragPath}/`)) return;
      e.preventDefault();
      const z = zone(e);
      row.classList.toggle("drop-before", z === "before");
      row.classList.toggle("drop-after", z === "after");
      row.classList.toggle("drop-inside", z === "inside");
    });
    row.addEventListener("dragleave", () => row.classList.remove("drop-before", "drop-after", "drop-inside"));
    row.addEventListener("drop", (e) => {
      e.preventDefault();
      const from = this.dragPath;
      row.classList.remove("drop-before", "drop-after", "drop-inside");
      if (!from || from === n.path) return;
      const z = zone(e);
      void this.dropOn(from, n, z);
    });
  }

  /** Moves `from` before/after/inside `target` (shared by the binder and the corkboard). */
  private async dropOn(from: string, target: BinderNode, where: "before" | "after" | "inside"): Promise<void> {
    if (!this.project) return;
    let parentPath = "";
    let index = 0;
    if (where === "inside") {
      parentPath = target.path;
      index = target.children?.length ?? 0;
      this.setExpanded(target.path, true);
    } else {
      const parent = parentOf(this.project.tree, target.path);
      const list = parent ? parent.children! : this.project.tree;
      parentPath = parent?.path ?? "";
      index = list.findIndex((x) => x.path === target.path) + (where === "after" ? 1 : 0);
      const fromIndex = list.findIndex((x) => x.path === from);
      if (fromIndex !== -1 && fromIndex < index) index -= 1;
    }
    try {
      const wasSelected = this.selected === from || this.selected?.startsWith(`${from}/`);
      const { path } = await writerApi.move(this.project.id, from, parentPath, index);
      await this.reload(wasSelected ? (this.selected === from ? path : this.selected!.replace(from, path)) : this.selected);
    } catch (err) {
      this.toast(err);
    }
  }

  private startRename(row: HTMLElement, n: BinderNode): void {
    const title = row.querySelector(".wr-row-title") as HTMLElement;
    const input = h("input", { class: "wr-input wr-rename", attrs: { value: n.title } });
    title.replaceWith(input);
    input.focus();
    input.select();
    let done = false;
    const finish = async (save: boolean) => {
      if (done) return;
      done = true;
      const value = input.value.trim();
      if (!save || !value || value === n.title) {
        input.replaceWith(title);
        return;
      }
      await this.renameItem(n, value);
    };
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") void finish(true);
      if (e.key === "Escape") void finish(false);
    });
    input.addEventListener("blur", () => void finish(true));
    input.addEventListener("click", (e) => e.stopPropagation());
  }

  private async renameItem(n: BinderNode, title: string): Promise<void> {
    if (!this.project) return;
    try {
      await this.flushAll();
      const { path } = await writerApi.rename(this.project.id, n.path, title);
      const sel = this.selected === n.path ? path : this.selected?.startsWith(`${n.path}/`) ? this.selected.replace(n.path, path) : this.selected;
      await this.reload(sel);
    } catch (err) {
      this.toast(err);
      this.renderBinderList();
    }
  }

  private binderMenu(e: MouseEvent, n: BinderNode): void {
    if (!this.project) return;
    const inTrash = isInTrash(this.project.tree, n.path);
    const items: MenuItem[] = [];
    if (n.role === "trash") {
      items.push({ label: "Empty Trash…", danger: true, disabled: !(n.children?.length), run: () => void this.emptyTrash() });
    } else {
      if (n.kind === "folder") {
        items.push({ label: "New document here", run: () => void this.addItem("doc", n.path) });
        items.push({ label: "New folder here", run: () => void this.addItem("folder", n.path) });
        items.push("-");
      }
      if (!n.role) items.push({ label: "Rename", run: () => {
        const row = this.root.querySelector(`.wr-row[data-path="${CSS.escape(n.path)}"]`) as HTMLElement | null;
        if (row) this.startRename(row, n);
      } });
      if (!n.role) items.push({ label: n.meta.compile === false ? "Include in export" : "Leave out of export", run: () => this.setMeta(n, { compile: n.meta.compile === false }) });
      if (n.kind === "doc") items.push({ label: "Take snapshot", run: () => void this.takeSnapshot(n) });
      if (n.kind === "doc") items.push({ label: "Writing record…", run: () => void this.openRecord(n.path) });
      if (!n.role) {
        items.push("-");
        items.push({ label: inTrash ? "Delete forever…" : "Move to Trash", danger: true, run: () => void this.trashItem(n.path) });
      }
    }
    this.showMenu(e, items);
  }

  private async addItem(kind: "doc" | "folder", parent?: string): Promise<void> {
    if (!this.project) return;
    const sel = this.node;
    let parentPath = parent;
    let index: number | undefined;
    if (parentPath === undefined) {
      if (!sel || isInTrash(this.project.tree, sel.path)) parentPath = this.project.tree[0].path;
      else if (sel.kind === "folder") parentPath = sel.path;
      else {
        const par = parentOf(this.project.tree, sel.path);
        parentPath = par?.path ?? this.project.tree[0].path;
        const list = par?.children ?? this.project.tree;
        index = list.findIndex((x) => x.path === sel.path) + 1;
      }
    }
    try {
      const { path } = await writerApi.add(this.project.id, { parent: parentPath, kind, title: kind === "folder" ? "New Folder" : "Untitled", index });
      this.setExpanded(parentPath, true);
      await this.reload(path);
      const row = this.root.querySelector(`.wr-row[data-path="${CSS.escape(path)}"]`) as HTMLElement | null;
      const node = findNode(this.project.tree, path);
      if (row && node) this.startRename(row, node);
    } catch (err) {
      this.toast(err);
    }
  }

  private async trashItem(path: string): Promise<void> {
    if (!this.project) return;
    const n = findNode(this.project.tree, path);
    if (!n || n.role) return;
    if (isInTrash(this.project.tree, path)) {
      if (!(await this.confirm(`Delete “${n.title}” for good?`, "It's moved to the project's hidden .deleted folder.", "Delete"))) return;
    }
    try {
      await this.flushAll();
      const next = this.selected === path || this.selected?.startsWith(`${path}/`) ? (parentOf(this.project.tree, path)?.path ?? null) : this.selected;
      await writerApi.trash(this.project.id, path);
      await this.reload(next);
    } catch (err) {
      this.toast(err);
    }
  }

  private async emptyTrash(): Promise<void> {
    if (!this.project) return;
    if (!(await this.confirm("Empty the Trash?", "Everything in it is moved to the project's hidden .deleted folder.", "Empty Trash"))) return;
    try {
      await writerApi.emptyTrash(this.project.id);
      await this.reload();
    } catch (err) {
      this.toast(err);
    }
  }

  private focusSearch(): void {
    if (!this.prefs.binder) this.togglePref("binder");
    (this.root.querySelector(".wr-search") as HTMLInputElement | null)?.focus();
  }

  // ── Main area ────────────────────────────────────────────────────────────
  private renderMain(): void {
    const main = this.els.main;
    if (!main || !this.project) return;
    this.destroyEditors();
    const n = this.node;
    const view = this.viewFor(n);
    this.root.querySelectorAll(".wr-seg .wr-view-btn").forEach((b) => b.classList.remove("is-on"));
    this.root.querySelector(`.seg-${view}`)?.classList.add("is-on");
    const titleSlot = this.root.querySelector("[data-title]");
    if (titleSlot && n && this.project) {
      const chain: BinderNode[] = [n];
      let up = parentOf(this.project.tree, n.path);
      while (up) {
        chain.unshift(up);
        up = parentOf(this.project.tree, up.path);
      }
      const path = h("div", { class: "wr-path" });
      chain.forEach((c, i) => {
        if (i) path.append(h("span", { class: "wr-path-sep", icon: "chevron" }));
        path.append(
          i === chain.length - 1
            ? h("span", { class: "wr-path-here" }, [h("span", { class: "wr-path-icon", icon: nodeIcon(c) }), h("span", { class: "wr-path-text", text: c.title })])
            : h("button", { class: "wr-path-link", text: c.title, on: { click: () => this.select(c.path) } }),
        );
      });
      titleSlot.replaceChildren(
        iconBtn("back", "Back (⌘[)", () => this.goBack(), this.history.length ? "" : "is-disabled"),
        iconBtn("forward", "Forward (⌘])", () => this.goForward(), this.future.length ? "" : "is-disabled"),
        path,
      );
    } else titleSlot?.replaceChildren();

    const scroll = h("div", { class: `wr-scroll view-${view}` });
    scroll.addEventListener("scroll", () => this.hideBubble(), { passive: true });
    this.els.scroll = scroll;
    main.replaceChildren(scroll);
    if (!n) return;
    if (view === "cork") this.renderCorkboard(scroll, n);
    else if (view === "outline") this.renderOutline(scroll, n);
    else if (n.kind === "doc") this.renderDocEditor(scroll, n);
    else this.renderScrivenings(scroll, n);
    this.updateFormatBar();
    if (this.find.open) {
      if (view === "doc") this.renderFindBar();
      else this.find.open = false;
    }
    if (this.prefs.inspectorTab === "contents" || this.prefs.inspectorTab === "comments") this.renderInspector();
  }

  private renderDocEditor(scroll: HTMLElement, n: BinderNode): void {
    const paper = h("div", { class: `wr-paper ${isRefList(n) ? "is-reflist" : ""}` });
    scroll.append(paper);
    this.mountEditor(paper, n, true);
  }

  /** Scrivenings: every document in a folder, one after another, each editable. */
  private renderScrivenings(scroll: HTMLElement, folder: BinderNode): void {
    const docs = docsUnder(folder).slice(0, 60);
    const paper = h("div", { class: "wr-paper is-scrivenings" });
    scroll.append(paper);
    if (!docs.length) {
      paper.append(
        h("div", { class: "wr-empty-inline" }, [
          h("p", { class: "wr-muted", text: "This folder has no documents yet." }),
          h("button", { class: "wr-btn", text: "New document", on: { click: () => void this.addItem("doc", folder.path) } }),
        ]),
      );
      return;
    }
    docs.forEach((d, i) => {
      if (i > 0) paper.append(h("div", { class: "wr-scriv-sep" }));
      paper.append(
        h("button", { class: "wr-scriv-title", text: d.title, title: "Open on its own", on: { click: () => this.select(d.path) } }),
      );
      const slot = h("div", { class: "wr-scriv-doc" });
      paper.append(slot);
      this.mountEditor(slot, d, i === 0);
    });
  }

  private mountEditor(slot: HTMLElement, n: BinderNode, focus: boolean): void {
    this.pointImagesAt(n.path); // Atlantis: images in this doc resolve from its folder
    const editor = createEditor({
      element: slot,
      markdown: n.body ?? "",
      placeholder: n.meta.synopsis ? `${n.meta.synopsis}` : "Start writing…",
      editable: !isInTrash(this.project!.tree, n.path),
      onChange: () => {
        this.scheduleSave(n.path);
        this.proofSoon();
      },
      onEdit: (tr) => this.keeper()?.edit(n.path, measure(tr)), // Atlantis: writing record
      onFocus: (ed) => {
        this.activeEditor = ed;
        this.pointImagesAt(n.path); // Atlantis: pasted images go in this doc's project
        this.updateFormatBar();
      },
      onSelection: (ed) => {
        if (ed !== this.activeEditor) return;
        this.updateFormatBar();
        this.updateSelectionCount();
        this.updateSlash();
        this.updateMention();
        this.updateBubble();
        this.updateAskChip();
        if (this.prefs.typewriter) this.typewriterScroll(ed);
      },
      onBlur: () => setTimeout(() => {
        this.updateBubble();
        this.updateAskChip();
      }, 0),
      onKeyDown: (view, event) => this.onEditorKey(n.path, view, event),
      comments: () => this.commentsOf(n.path),
      activeComment: () => this.activeComment,
      review: () => this.prefs.review,
      proof: () => this.prefs.proof && !isRefList(n),
      proofLookup: this.proof.lookup,
    });
    editor.view.dom.addEventListener("click", (e) => {
      const mark = (e.target as HTMLElement).closest?.("[data-proof]") as HTMLElement | null;
      if (mark && editor.view.state.selection.empty) {
        const issue = hitAt(editor.view, editor.view.posAtDOM(mark, 0));
        if (issue) return this.openProofCard(editor, issue);
      }
      const hit = (e.target as HTMLElement).closest?.("[data-comment]") as HTMLElement | null;
      if (hit?.dataset.comment) this.showComment(hit.dataset.comment);
    });
    // Atlantis: text copied or cut here and pasted back is moving your own writing, not pasting.
    const remember = () => {
      const { from, to } = editor.state.selection;
      if (to > from) this.keeper()?.copiedText(editor.state.doc.textBetween(from, to, "\n", " "));
    };
    editor.view.dom.addEventListener("copy", remember);
    editor.view.dom.addEventListener("cut", remember);
    this.editors.set(n.path, editor);
    if (!this.activeEditor) this.activeEditor = editor;
    if (focus && !this.root.querySelector(".wr-search:focus")) setTimeout(() => editor.isDestroyed || editor.commands.focus("start"), 0);
    this.proofSoon();
  }

  private destroyEditors(): void {
    void this.recordKeeper?.keeper.flush(); // Atlantis: counts words while the editors still exist
    for (const [path, ed] of this.editors) {
      if (this.timers.has(path)) this.saveNow(path); // fire and forget, uses current content
      ed.destroy();
    }
    this.editors.clear();
    this.activeEditor = null;
    this.closeSlash();
    this.closeMention();
    this.hideAskChip();
    this.hideBubble();
  }

  private typewriterScroll(ed: Editor): void {
    const scroll = this.els.scroll;
    if (!scroll) return;
    try {
      const c = ed.view.coordsAtPos(ed.state.selection.head);
      const r = scroll.getBoundingClientRect();
      const target = r.top + r.height * 0.45;
      scroll.scrollBy({ top: c.top - target, behavior: "auto" });
    } catch {}
  }

  private renderCorkboard(scroll: HTMLElement, folder: BinderNode): void {
    const board = h("div", { class: "wr-cork" });
    scroll.append(board);
    const kids = folder.children ?? [];
    for (const c of kids) {
      const colour = labelColour(c.meta.label);
      const synopsis = h("textarea", {
        class: "wr-card-syn",
        attrs: { rows: "5", placeholder: c.kind === "doc" ? excerpt(c.body) || "Synopsis…" : "Synopsis…" },
      });
      synopsis.value = c.meta.synopsis ?? "";
      synopsis.addEventListener("input", () => this.setMeta(c, { synopsis: synopsis.value }, false));
      const titleInput = h("input", { class: "wr-card-title", attrs: { value: c.title, "aria-label": "Title" } });
      titleInput.addEventListener("keydown", (e) => {
        e.stopPropagation();
        if (e.key === "Enter") titleInput.blur();
      });
      titleInput.addEventListener("change", () => {
        const v = titleInput.value.trim();
        if (v && v !== c.title) void this.renameItem(c, v);
      });
      const card = h("div", {
        class: `wr-card ${c.meta.compile === false ? "is-excluded" : ""}`,
        attrs: { draggable: "true", "data-path": c.path },
        on: {
          dblclick: (e) => {
            if ((e.target as HTMLElement).closest("textarea,input")) return;
            this.select(c.path);
          },
          contextmenu: (e) => {
            e.preventDefault();
            this.binderMenu(e, c);
          },
        },
      }, [
        h("div", { class: "wr-card-head" }, [
          h("span", { class: "wr-row-icon", icon: nodeIcon(c) }),
          titleInput,
          h("button", { class: "wr-icon-btn wr-card-open", icon: "forward", title: "Open", on: { click: () => this.select(c.path) } }),
        ]),
        synopsis,
        h("div", { class: "wr-card-foot" }, [
          c.meta.status ? h("span", { class: "wr-stamp", text: c.meta.status }) : null,
          h("span", { class: "wr-faint", text: c.kind === "doc" ? `${fmt(countWords(c.body))} words` : `${(c.children ?? []).length} items` }),
        ]),
      ]);
      if (colour) card.style.setProperty("--label", colour);
      card.addEventListener("dragstart", (e) => {
        if ((e.target as HTMLElement).closest("textarea,input")) return;
        this.dragPath = c.path;
        e.dataTransfer?.setData("text/plain", c.title);
        card.classList.add("is-dragging");
      });
      card.addEventListener("dragend", () => {
        this.dragPath = null;
        card.classList.remove("is-dragging");
        board.querySelectorAll(".drop-before,.drop-after").forEach((x) => x.classList.remove("drop-before", "drop-after"));
      });
      card.addEventListener("dragover", (e) => {
        if (!this.dragPath || this.dragPath === c.path) return;
        e.preventDefault();
        const r = card.getBoundingClientRect();
        const after = e.clientX > r.left + r.width / 2;
        card.classList.toggle("drop-after", after);
        card.classList.toggle("drop-before", !after);
      });
      card.addEventListener("dragleave", () => card.classList.remove("drop-before", "drop-after"));
      card.addEventListener("drop", (e) => {
        e.preventDefault();
        const from = this.dragPath;
        const after = card.classList.contains("drop-after");
        card.classList.remove("drop-before", "drop-after");
        if (from && from !== c.path) void this.dropOn(from, c, after ? "after" : "before");
      });
      board.append(card);
    }
    if (!isInTrash(this.project!.tree, folder.path)) {
      board.append(
        h("button", { class: "wr-card wr-card-add", on: { click: () => void this.addItem("doc", folder.path) } }, [
          h("span", { icon: "plus" }),
          h("span", { text: "New card" }),
        ]),
      );
    }
  }

  private renderOutline(scroll: HTMLElement, folder: BinderNode): void {
    const table = h("table", { class: "wr-outline" });
    table.append(
      h("thead", {}, [
        h("tr", {}, ["Title", "Synopsis", "Label", "Status", "Words", "Target", "Export"].map((t) => h("th", { text: t }))),
      ]),
    );
    const body = h("tbody");
    const rows = (nodes: BinderNode[], depth: number) => {
      for (const n of nodes) {
        const words = n.kind === "doc" ? countWords(n.body) : wordsUnder(n);
        const label = this.dropdown(["", ...LABELS.map((l) => l.name)], n.meta.label ?? "", (v) => this.setMeta(n, { label: v || undefined }));
        const status = this.dropdown(["", ...STATUSES], n.meta.status ?? "", (v) => this.setMeta(n, { status: v || undefined }));
        const include = h("input", { attrs: { type: "checkbox", "aria-label": "Include in export" } });
        include.checked = n.meta.compile !== false;
        include.addEventListener("change", () => this.setMeta(n, { compile: include.checked }));
        const target = n.meta.target ? Math.min(100, Math.round((words / n.meta.target) * 100)) : null;
        body.append(
          h("tr", { class: n.kind === "folder" ? "is-folder" : "", on: { dblclick: () => this.select(n.path) } }, [
            h("td", { class: "wr-ol-title" }, [
              h("div", {}, [
                h("span", { class: "wr-ol-indent", attrs: { style: `width:${depth * 16}px` } }),
                h("span", { class: "wr-row-icon", icon: nodeIcon(n) }),
                h("button", { class: "wr-link", text: n.title, on: { click: () => this.select(n.path) } }),
              ]),
            ]),
            h("td", { class: "wr-ol-syn", text: n.meta.synopsis || (n.kind === "doc" ? excerpt(n.body, 90) : "") }),
            h("td", {}, [label]),
            h("td", {}, [status]),
            h("td", { class: "wr-num", text: fmt(words) }),
            h("td", { class: "wr-num" }, [
              n.meta.target ? h("span", { class: "wr-mini-bar", attrs: { style: `--p:${target}%` }, title: `${target}% of ${fmt(n.meta.target)}` }) : h("span", { class: "wr-faint", text: "—" }),
            ]),
            h("td", { class: "wr-center" }, [include]),
          ]),
        );
        if (n.children) rows(n.children, depth + 1);
      }
    };
    rows(folder.children ?? [], 0);
    table.append(body);
    scroll.append(h("div", { class: "wr-outline-wrap" }, [table]));
  }

  private dropdown(options: string[], value: string, onChange: (v: string) => void): HTMLSelectElement {
    const s = h("select", { class: "wr-select" });
    for (const o of options) {
      const opt = h("option", { text: o || "—" });
      opt.value = o;
      s.append(opt);
    }
    if (value && !options.includes(value)) {
      const opt = h("option", { text: value });
      opt.value = value;
      s.append(opt);
    }
    s.value = value;
    s.addEventListener("change", () => onChange(s.value));
    return s;
  }

  // ── Format bar ───────────────────────────────────────────────────────────
  private renderFormatBar(): void {
    const bar = this.els.format;
    if (!bar) return;
    const ed = () => this.activeEditor;
    const run = (fn: (e: Editor) => void) => () => {
      const e = ed();
      if (e && !e.isDestroyed) fn(e);
    };
    const style = h("select", { class: "wr-select wr-style", attrs: { "aria-label": "Text style" } });
    for (const s of BLOCK_STYLES) {
      const o = h("option", { text: s.label });
      o.value = s.id;
      style.append(o);
    }
    style.addEventListener("change", () => {
      const e = ed();
      if (e) setBlockStyle(e, style.value as BlockStyle);
    });
    const btn = (icon: IconName, title: string, fn: (e: Editor) => void, mark?: string, attrs?: Record<string, unknown>) => {
      const b = iconBtn(icon, title, run(fn), "wr-fmt");
      b.addEventListener("mousedown", (e) => e.preventDefault()); // keep the selection
      if (mark) {
        b.dataset.mark = mark;
        if (attrs) b.dataset.attrs = JSON.stringify(attrs);
      }
      return b;
    };
    const sep = () => h("span", { class: "wr-sep" });
    bar.replaceChildren(
      style,
      sep(),
      btn("bold", "Bold (⌘B)", (e) => e.chain().focus().toggleBold().run(), "bold"),
      btn("italic", "Italic (⌘I)", (e) => e.chain().focus().toggleItalic().run(), "italic"),
      btn("strike", "Strikethrough (⌘⇧S)", (e) => e.chain().focus().toggleStrike().run(), "strike"),
      btn("highlight", "Highlight (⌘⇧H)", (e) => e.chain().focus().toggleHighlight().run(), "highlight"),
      btn("code", "Inline code (⌘E)", (e) => e.chain().focus().toggleCode().run(), "code"),
      btn("link", "Link", (e) => this.editLink(e), "link"),
      sep(),
      btn("bullets", "Bulleted list (⌘⇧8)", (e) => e.chain().focus().toggleBulletList().run(), "bulletList"),
      btn("numbers", "Numbered list (⌘⇧7)", (e) => e.chain().focus().toggleOrderedList().run(), "orderedList"),
      btn("checklist", "Checklist (⌘⇧9)", (e) => e.chain().focus().toggleTaskList().run(), "taskList"),
      btn("quote", "Block quote", (e) => e.chain().focus().toggleBlockquote().run(), "blockquote"),
      sep(),
      btn("table", "Insert table", (e) =>
        e.isActive("table")
          ? this.tableMenu(e)
          : e.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run(),
      ),
      btn("rule", "Divider", (e) => e.chain().focus().setHorizontalRule().run()),
      btn("clear", "Clear formatting", (e) => e.chain().focus().unsetAllMarks().clearNodes().run()),
      sep(),
      btn("undo", "Undo (⌘Z)", (e) => e.chain().focus().undo().run()),
      btn("redo", "Redo (⇧⌘Z)", (e) => e.chain().focus().redo().run()),
      sep(),
      btn("cite", "Reference maker: paste a link (⌥⌘R)", () => this.openReferences()),
      btn("comment", "Comment on selection (⌥⌘M)", () => this.addComment()),
      btn("note", "Note to self, not exported (⌥⌘J)", () => this.addNote()),
      btn("find", "Find and replace (⌘F)", () => this.openFind(false)),
      h("span", { class: "wr-grow" }),
      h("span", { class: "wr-format-hint wr-faint", text: "Type / for headings, lists, tables…" }),
      iconBtn("keyboard", "Keyboard shortcuts (⌘/)", () => this.openShortcuts(), "wr-fmt-help"),
    );
    this.els.style = style;
  }

  private updateFormatBar(): void {
    const bar = this.els.format;
    const e = this.activeEditor;
    if (!bar) return;
    bar.classList.toggle("is-disabled", !e || e.isDestroyed || !e.isEditable);
    if (!e || e.isDestroyed) {
      (this.els.style as HTMLSelectElement).value = "p";
      bar.querySelectorAll<HTMLElement>("[data-mark]").forEach((b) => b.classList.remove("is-on"));
      return;
    }
    (this.els.style as HTMLSelectElement).value = currentBlockStyle(e);
    bar.querySelectorAll<HTMLElement>("[data-mark]").forEach((b) => {
      const attrs = b.dataset.attrs ? JSON.parse(b.dataset.attrs) : undefined;
      b.classList.toggle("is-on", e.isActive(b.dataset.mark!, attrs));
    });
  }

  private async editLink(e: Editor): Promise<void> {
    const current = (e.getAttributes("link").href as string | undefined) ?? "";
    const url = await this.prompt("Link", "Paste a web address. Leave it blank to remove the link.", current, "https://");
    if (url === null) return;
    const chain = e.chain().focus().extendMarkRange("link");
    if (!url.trim()) chain.unsetLink().run();
    else chain.setLink({ href: /^[a-z]+:/i.test(url.trim()) ? url.trim() : `https://${url.trim()}` }).run();
  }

  private tableMenu(e: Editor): void {
    const anchor = this.root.querySelector(".wr-format [title='Insert table']") as HTMLElement;
    const r = anchor?.getBoundingClientRect();
    const fake = { clientX: r?.left ?? 200, clientY: (r?.bottom ?? 120) + 4, preventDefault() {} } as MouseEvent;
    const c = () => e.chain().focus();
    this.showMenu(fake, [
      { label: "Add row below", run: () => c().addRowAfter().run() },
      { label: "Add column right", run: () => c().addColumnAfter().run() },
      { label: "Delete row", run: () => c().deleteRow().run() },
      { label: "Delete column", run: () => c().deleteColumn().run() },
      { label: "Header row on/off", run: () => c().toggleHeaderRow().run() },
      "-",
      { label: "Delete table", danger: true, run: () => c().deleteTable().run() },
    ]);
  }

  // ── Saving ───────────────────────────────────────────────────────────────
  private scheduleSave(path: string): void {
    const old = this.timers.get(path);
    if (old) clearTimeout(old);
    this.timers.set(path, setTimeout(() => void this.saveNow(path), SAVE_DELAY));
    this.renderSaveState();
    this.updateCountsSoon();
  }

  private countTimer: ReturnType<typeof setTimeout> | null = null;
  private updateCountsSoon(): void {
    if (this.countTimer) return;
    this.countTimer = setTimeout(() => {
      this.countTimer = null;
      for (const [path, ed] of this.editors) {
        const n = this.project && findNode(this.project.tree, path);
        if (n && !ed.isDestroyed) n.body = ed.getMarkdown();
      }
      this.renderFooter();
      this.updateInspectorProgress();
      if (this.find.open) this.refreshFind(false);
      if (this.prefs.inspectorTab === "contents") this.renderContents();
      this.updateComposeWords();
    }, 400);
  }

  private async saveNow(path: string): Promise<void> {
    const t = this.timers.get(path);
    if (t) clearTimeout(t);
    this.timers.delete(path);
    const p = this.project;
    const n = p && findNode(p.tree, path);
    if (!p || !n || n.kind !== "doc") return;
    const ed = this.editors.get(path);
    if (ed && !ed.isDestroyed) n.body = ed.getMarkdown();
    this.saving++;
    this.renderSaveState();
    try {
      await this.autoSnapshot(p.id, n);
      const r = await writerApi.save(p.id, path, n.meta, n.body ?? "");
      n.mtime = r.mtime;
      this.saveError = "";
    } catch (err) {
      this.saveError = err instanceof Error ? err.message : String(err);
      // Try again shortly; the text is still in memory.
      if (!this.stopped) this.timers.set(path, setTimeout(() => void this.saveNow(path), 4000));
    } finally {
      this.saving--;
      this.renderSaveState();
    }
  }

  /** Atlantis: saves everything now (the app calls this before it quits). */
  flush(): Promise<void> {
    return this.flushAll();
  }

  private async flushAll(): Promise<void> {
    await Promise.all([...this.timers.keys()].map((p) => this.saveNow(p)));
    await this.recordKeeper?.keeper.flush();
  }

  private flushOnUnload = () => {
    void this.flushAll();
  };

  private onVisible = () => {
    if (document.visibilityState !== "visible" || !this.project || this.timers.size || this.saving) return;
    // Pick up edits made in another app (Obsidian, TextEdit) while SEQTA was in the background.
    const id = this.project.id;
    void writerApi.open(id).then((fresh) => {
      if (!this.project || this.project.id !== id || this.timers.size || this.saving) return;
      let changed = false;
      walk(fresh.tree, (n) => {
        const old = findNode(this.project!.tree, n.path);
        if (!old || (n.kind === "doc" && old.mtime !== n.mtime)) changed = true;
      });
      let count = 0;
      walk(fresh.tree, () => count++);
      let oldCount = 0;
      walk(this.project.tree, () => oldCount++);
      if (!changed && count === oldCount) return;
      // Atlantis: note text that changed outside the Writer in the writing record.
      walk(fresh.tree, (n) => {
        const old = findNode(this.project!.tree, n.path);
        if (n.kind === "doc" && old && old.mtime !== n.mtime && (old.body ?? "") !== (n.body ?? "")) {
          this.keeper()?.event(n.path, "outside", `${fmt(countWords(old.body))} → ${fmt(countWords(n.body))} words`);
        }
      });
      this.project = fresh;
      if (this.selected && !findNode(fresh.tree, this.selected)) this.selected = fresh.tree[0].path;
      this.renderBinder();
      this.renderMain();
      this.renderInspector();
      this.renderFooter();
    }).catch(() => {});
  };

  /** Saves a metadata change (synopsis, label, status, …) for a doc or folder. */
  private setMeta(n: BinderNode, patch: DocMeta, rerender = true): void {
    if (!this.project) return;
    n.meta = { ...n.meta, ...patch };
    for (const [k, v] of Object.entries(patch)) if (v === undefined || v === "") delete (n.meta as Record<string, unknown>)[k];
    if (n.kind === "doc") this.scheduleSave(n.path);
    else {
      const id = this.project.id;
      const key = `folder:${n.path}`;
      const old = this.timers.get(key);
      if (old) clearTimeout(old);
      this.timers.set(key, setTimeout(() => {
        this.timers.delete(key);
        void writerApi.folderMeta(id, n.path, n.meta).catch((e) => this.toast(e));
      }, SAVE_DELAY));
    }
    if (rerender) {
      this.renderBinderList();
      if (this.viewFor(this.node) !== "doc") this.renderMain();
      this.renderInspector();
    }
  }

  // ── Inspector ────────────────────────────────────────────────────────────
  private renderInspector(): void {
    const box = this.els.inspector;
    if (!box || !this.project) return;
    const n = this.node;
    box.replaceChildren();
    if (!n) return;
    const section = (title: string, ...children: Child[]) =>
      h("section", { class: "wr-ins-sec" }, [h("h3", { text: title }), ...children]);
    const tabs: Array<[InspectorTab, IconName, string]> = [
      ["info", "info", "Info"],
      ["contents", "contents", "Contents"],
      ["comments", "comment", "Comments"],
      ["history", "history", "History"],
    ];
    const openComments = this.visibleDocs().reduce((sum, d) => sum + this.commentsOf(d.path).filter((c) => !c.done).length, 0);
    let tab = this.prefs.inspectorTab;
    if (tab === "history" && n.kind !== "doc") tab = "info";
    box.append(
      h("div", { class: "wr-ins-tabs", attrs: { role: "tablist" } }, tabs.map(([id, icon, label]) =>
        h("button", {
          class: `wr-ins-tab ${tab === id ? "is-on" : ""}`,
          attrs: { role: "tab", "aria-selected": String(tab === id), ...(id === "history" && n.kind !== "doc" ? { disabled: "" } : {}) },
          title: id === "history" && n.kind !== "doc" ? "Snapshots are kept for documents" : label,
          on: { click: () => { this.prefs.inspectorTab = id; this.savePrefs(); this.renderInspector(); } },
        }, [
          h("span", { icon }),
          h("span", { class: "wr-ins-tab-label", text: label }),
          id === "comments" && openComments ? h("span", { class: "wr-badge", text: String(openComments) }) : null,
        ]),
      )),
    );
    if (tab === "comments") {
      box.append(this.renderComments());
      return;
    }
    if (tab === "contents") {
      const list = h("div", { class: "wr-contents", attrs: { "data-contents": "" } });
      box.append(list);
      this.renderContents();
      return;
    }
    if (tab === "history") {
      const snaps = h("div", { class: "wr-snaps" }, [h("p", { class: "wr-faint wr-small", text: "Loading…" })]);
      box.append(
        // Atlantis: the writing record (what you did, for school) and versions kept as you save.
        section(
          "Writing record",
          h("p", { class: "wr-faint wr-small", text: "When you wrote, how much you typed or pasted, and what changed. Handy to show the work is yours." }),
          h("button", { class: "wr-btn wr-btn-full", on: { click: () => void this.openRecord() } }, [h("span", { icon: "record" }), "Open writing record"]),
        ),
        section(
          "Versions",
          h("p", { class: "wr-faint wr-small", text: "Kept by themselves every 10 minutes while you write. Name your own before big changes; restoring keeps what you had." }),
          h("button", { class: "wr-btn wr-btn-full", on: { click: () => void this.takeSnapshot(n) } }, [h("span", { icon: "snapshot" }), "Save a named version"]),
          snaps,
        ),
      );
      void this.loadSnapshots(n, snaps);
      return;
    }

    // Synopsis: an index card, like Scrivener's.
    const syn = h("textarea", { class: "wr-ins-card", attrs: { rows: "6", placeholder: "Synopsis: what this part is for…" } });
    syn.value = n.meta.synopsis ?? "";
    syn.addEventListener("input", () => this.setMeta(n, { synopsis: syn.value }, false));
    syn.addEventListener("change", () => {
      this.renderBinderList();
      if (this.viewFor(this.node) !== "doc") this.renderMain();
    });
    box.append(section("Synopsis", syn));

    if (!n.role || n.role === "draft") {
      const include = h("input", { attrs: { type: "checkbox", id: "wr-ins-include" } });
      include.checked = n.meta.compile !== false;
      include.addEventListener("change", () => this.setMeta(n, { compile: include.checked }));
      box.append(
        section(
          "Metadata",
          h("label", { class: "wr-field" }, [h("span", { text: "Label" }), this.dropdown(["", ...LABELS.map((l) => l.name)], n.meta.label ?? "", (v) => this.setMeta(n, { label: v || undefined }))]),
          h("label", { class: "wr-field" }, [h("span", { text: "Status" }), this.dropdown(["", ...STATUSES], n.meta.status ?? "", (v) => this.setMeta(n, { status: v || undefined }))]),
          n.role ? null : h("label", { class: "wr-check" }, [include, h("span", { text: "Include in export" })]),
        ),
      );
    }

    // Word target.
    const words = n.kind === "doc" ? countWords(n.body) : wordsUnder(n);
    const target = h("input", { class: "wr-input wr-num-input", attrs: { type: "number", min: "0", step: "50", placeholder: "none", value: n.meta.target ? String(n.meta.target) : "" } });
    target.addEventListener("change", () => {
      const v = Math.max(0, Math.round(Number(target.value) || 0));
      this.setMeta(n, { target: v || undefined }, false);
      this.updateInspectorProgress();
      this.renderFooter();
    });
    box.append(
      section(
        "Target",
        h("div", { class: "wr-field" }, [h("span", { text: "Words" }), target]),
        h("div", { class: "wr-progress", attrs: { "data-progress": "" } }, [h("span")]),
        h("p", { class: "wr-faint wr-small", attrs: { "data-progress-text": "" }, text: `${fmt(words)} words` }),
      ),
    );

    if (n.kind === "doc") {
      const notes = h("textarea", { class: "wr-input wr-ins-notes", attrs: { rows: "6", placeholder: "Notes about this document (not exported)" } });
      notes.value = n.meta.notes ?? "";
      notes.addEventListener("input", () => this.setMeta(n, { notes: notes.value }, false));
      box.append(section("Document notes", notes));
    }
    this.updateInspectorProgress();
  }

  private updateInspectorProgress(): void {
    const n = this.node;
    const bar = this.root.querySelector<HTMLElement>("[data-progress]");
    const text = this.root.querySelector<HTMLElement>("[data-progress-text]");
    if (!n || !bar || !text) return;
    const words = n.kind === "doc" ? countWords(n.body) : wordsUnder(n);
    const goal = n.meta.target ?? 0;
    const pct = goal ? Math.min(100, Math.round((words / goal) * 100)) : 0;
    bar.style.setProperty("--p", `${pct}%`);
    bar.classList.toggle("is-done", goal > 0 && words >= goal);
    bar.hidden = !goal;
    text.textContent = goal ? `${fmt(words)} of ${fmt(goal)} words (${pct}%)` : `${fmt(words)} words`;
  }

  private async loadSnapshots(n: BinderNode, box: HTMLElement): Promise<void> {
    if (!this.project) return;
    let list: Snapshot[] = [];
    try {
      list = await writerApi.snapshots(this.project.id, n.path);
    } catch (err) {
      box.replaceChildren(h("p", { class: "wr-faint wr-small", text: err instanceof Error ? err.message : String(err) }));
      return;
    }
    if (!box.isConnected) return;
    if (!list.length) {
      box.replaceChildren(h("p", { class: "wr-faint wr-small", text: "No versions yet. One is kept when you start writing, then every 10 minutes." }));
      return;
    }
    // Atlantis: grouped by day, newest first, with the change in words since the version before.
    const rows: HTMLElement[] = [];
    let lastDay = "";
    list.forEach((s, i) => {
      const at = s.at ? new Date(s.at) : null;
      const dayLabel = at ? at.toLocaleDateString("en-AU", { weekday: "short", day: "numeric", month: "short" }) : "";
      if (dayLabel && dayLabel !== lastDay) {
        rows.push(h("div", { class: "wr-snap-day", text: dayLabel }));
        lastDay = dayLabel;
      }
      const clock = at ? at.toLocaleTimeString("en-AU", { hour: "numeric", minute: "2-digit" }) : s.id;
      const auto = !s.name || s.name === "Auto";
      const older = list[i + 1];
      const delta = older ? s.words - older.words : 0;
      rows.push(
        h("div", { class: "wr-snap" }, [
          h("div", {}, [
            h("strong", { text: auto ? clock : s.name }),
            h("span", { class: "wr-faint wr-small", text: `${auto ? "Auto" : clock} · ${fmt(s.words)} words${older && delta ? ` (${delta > 0 ? "+" : "−"}${fmt(Math.abs(delta))})` : ""}` }),
          ]),
          h("button", { class: "wr-btn wr-btn-small", text: "View", on: { click: () => this.viewSnapshot(n, s) } }),
        ]),
      );
    });
    box.replaceChildren(...rows);
  }

  private async takeSnapshot(n: BinderNode): Promise<void> {
    if (!this.project) return;
    const name = await this.prompt("Take snapshot", "Give it a name (optional), like “before feedback”.", "", "Snapshot name");
    if (name === null) return;
    try {
      await this.saveNow(n.path);
      await writerApi.snapshot(this.project.id, n.path, name);
      this.toast("Snapshot saved");
      if (this.selected === n.path) {
        this.prefs.inspectorTab = "history";
        this.renderInspector();
      }
    } catch (err) {
      this.toast(err);
    }
  }

  private viewSnapshot(n: BinderNode, s: Snapshot): void {
    const preview = h("div", { class: "wr-snap-preview wr-prose" });
    preview.innerHTML = markdownToHtml(s.body);
    // Strip anything active the HTML might carry; this is only a preview.
    preview.querySelectorAll("script,style,iframe,object,embed").forEach((x) => x.remove());
    const now = countWords(n.body);
    const parts = diffWords(plainText(s.body), plainText(n.body ?? ""));
    const sum = diffSummary(parts);
    const diff = h("div", { class: "wr-snap-preview wr-diff", attrs: { hidden: "" } });
    for (const part of parts) diff.append(part.kind === "same" ? document.createTextNode(part.text) : h(part.kind === "add" ? "ins" : "del", { text: part.text }));
    const seg = h("div", { class: "wr-seg-text" });
    const show = (which: "snap" | "diff") => {
      preview.hidden = which !== "snap";
      diff.hidden = which !== "diff";
      seg.querySelectorAll("button").forEach((b) => b.classList.toggle("is-on", b.dataset.v === which));
    };
    seg.append(
      h("button", { text: "This version", attrs: { "data-v": "snap" }, on: { click: () => show("snap") } }),
      h("button", { text: `Changes since (+${fmt(sum.added)} −${fmt(sum.removed)})`, attrs: { "data-v": "diff" }, on: { click: () => show("diff") } }),
    );
    this.openModal(`Snapshot · ${s.name || (s.at ? new Date(s.at).toLocaleString("en-AU") : "")}`, [
      h("div", { class: "wr-snap-bar" }, [seg, h("span", { class: "wr-muted wr-small", text: `${fmt(s.words)} words then · ${fmt(now)} now` })]),
      preview,
      diff,
    ], [
      h("button", { class: "wr-btn wr-btn-danger-ghost", text: "Delete snapshot", on: { click: async () => {
        if (!this.project) return;
        try {
          await writerApi.deleteSnapshot(this.project.id, n.path, s.id);
          this.closeModal();
          this.renderInspector();
        } catch (err) {
          this.toast(err);
        }
      } } }),
      h("span", { class: "wr-grow" }),
      h("button", { class: "wr-btn", text: "Close", on: { click: () => this.closeModal() } }),
      h("button", { class: "wr-btn wr-btn-primary", text: "Restore this version", on: { click: () => void this.restoreSnapshot(n, s) } }),
    ], "wide");
    show("snap");
  }

  private async restoreSnapshot(n: BinderNode, s: Snapshot): Promise<void> {
    if (!this.project) return;
    try {
      await this.saveNow(n.path);
      await writerApi.snapshot(this.project.id, n.path, "before restore");
      n.body = s.body;
      await writerApi.save(this.project.id, n.path, n.meta, s.body);
      this.closeModal();
      this.renderMain();
      this.renderInspector();
      this.renderFooter();
      this.keeper()?.event(n.path, "restore", `the version from ${s.at ? new Date(s.at).toLocaleString("en-AU", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" }) : s.id}${s.name && s.name !== "Auto" ? ` (“${s.name}”)` : ""}`);
      this.toast("Restored. What you had is kept as a snapshot.");
    } catch (err) {
      this.toast(err);
    }
  }

  // ── Writing record (Atlantis) ────────────────────────────────────────────
  private recordKeeper: { id: string; keeper: RecordKeeper } | null = null;

  /** The open project's writing record keeper (record.ts), made on first use. */
  private keeper(): RecordKeeper | null {
    const p = this.project;
    if (!p || this.stopped) return null;
    if (this.recordKeeper?.id !== p.id) {
      void this.recordKeeper?.keeper.flush();
      const id = p.id;
      this.recordKeeper = {
        id,
        keeper: new RecordKeeper({
          append: (lines) => writerApi.recordAppend(id, lines).then(() => undefined),
          words: (doc) => {
            const ed = this.editors.get(doc);
            if (ed && !ed.isDestroyed) return countWords(ed.getMarkdown());
            return countWords(this.project?.id === id ? findNode(this.project.tree, doc)?.body : "");
          },
        }),
      };
    }
    return this.recordKeeper.keeper;
  }

  /** Shows the writing record for one doc (`path`) or, with null, the whole project. */
  private async openRecord(path: string | null = this.node?.kind === "doc" ? this.node.path : null): Promise<void> {
    const p = this.project;
    if (!p) return;
    await this.flushAll();
    let lines: RecordLine[];
    try {
      lines = parseRecord(await writerApi.recordRead(p.id));
    } catch (err) {
      this.toast(err);
      return;
    }
    const doc = path ? findNode(p.tree, path) : null;
    const versions = doc ? await writerApi.snapshots(p.id, doc.path).then((l) => l.length).catch(() => undefined) : undefined;
    let scope: "doc" | "project" = doc ? "doc" : "project";
    const titleOf = (d: string) => findNode(p.tree, d)?.title ?? d.replace(/^.*\//, "").replace(/\.(md|markdown|txt)$/i, "");
    const build = () => {
      const one = scope === "doc" && doc ? doc : null;
      const sum = summarise(lines, one ? new Set([one.path]) : undefined);
      const info: RecordViewInfo = {
        title: one ? one.title : p.title,
        scope: one ? "This document" : "Whole project",
        titleOf,
        wordsNow: one ? countWords(one.body) : p.tree.filter((r) => r.role !== "trash").reduce((t, r) => t + wordsUnder(r), 0),
        versions: one ? versions : undefined,
        author: p.settings.author || this.host.settings().author || undefined,
      };
      return { sum, info };
    };
    const body = h("div", { class: "wr-rec" });
    const status = h("span", { class: "wr-muted wr-small" });
    const draw = () => {
      const { sum, info } = build();
      body.innerHTML = recordHtml(sum, info); // built from escaped text only (recordView.ts)
    };
    let seg: HTMLElement | null = null;
    if (doc) {
      seg = h("div", { class: "wr-seg-text wr-rec-scope" });
      const pick = (v: "doc" | "project") => {
        scope = v;
        seg!.querySelectorAll("button").forEach((b) => b.classList.toggle("is-on", b.dataset.v === v));
        draw();
      };
      seg.append(
        h("button", { text: "This document", attrs: { "data-v": "doc" }, on: { click: () => pick("doc") } }),
        h("button", { text: "Whole project", attrs: { "data-v": "project" }, on: { click: () => pick("project") } }),
      );
      seg.querySelector(`[data-v="${scope}"]`)?.classList.add("is-on");
    }
    const save = async () => {
      const { sum, info } = build();
      status.textContent = "Making the PDF…";
      try {
        const r = await writerApi.export(p.id, { name: `${info.title} writing record`, format: "pdf", html: recordReport(sum, info) });
        status.replaceChildren(
          `Saved ${r.name} in Exports. `,
          h("button", { class: "wr-link", text: "Show", on: { click: () => void writerApi.openFile(r.path, true).catch((e) => this.toast(e)) } }),
        );
      } catch (err) {
        status.textContent = err instanceof Error ? err.message : String(err);
      }
    };
    this.openModal("Writing record", [seg, body], [
      h("button", { class: "wr-btn", on: { click: () => void save() } }, [h("span", { icon: "record" }), "Save as PDF"]),
      status,
      h("span", { class: "wr-grow" }),
      h("button", { class: "wr-btn wr-btn-primary", text: "Close", on: { click: () => this.closeModal() } }),
    ], "wide");
    draw();
  }

  /** Atlantis: a note to self at the caret (a ```note block: shown here, never exported). */
  private addNote(): void {
    const e = this.activeEditor;
    if (!e || e.isDestroyed || !e.isEditable) {
      this.toast("Click into a document first.");
      return;
    }
    e.chain().focus().setCodeBlock({ language: "note" }).run();
  }

  // ── Footer ───────────────────────────────────────────────────────────────
  private renderFooter(): void {
    const foot = this.els.foot;
    if (!foot || !this.project) return;
    const n = this.node;
    const draft = this.project.tree[0];
    const draftWords = wordsUnder(draft, true);
    const goal = this.project.settings.target ?? 0;
    const zoom = this.dropdown(["0.8", "0.9", "1", "1.1", "1.25", "1.5", "1.75", "2"], String(this.prefs.zoom), (v) => {
      this.prefs.zoom = Number(v);
      this.savePrefs();
      this.applyPrefs();
    });
    zoom.querySelectorAll("option").forEach((o) => (o.textContent = `${Math.round(Number(o.value) * 100)}%`));
    zoom.classList.add("wr-zoom");
    zoom.setAttribute("aria-label", "Zoom");
    const viewWords = n ? (n.kind === "doc" ? countWords(n.body) : wordsUnder(n)) : 0;
    const due = dueLabel(this.project.settings.deadline);
    foot.replaceChildren(
      h("div", { class: "wr-foot-group" }, [zoom]),
      h("div", { class: "wr-foot-mid" }, [
        h("button", { class: "wr-words", title: "Writing stats", attrs: { "data-words": String(viewWords) }, text: `${fmt(viewWords)} words`, on: { click: (e) => this.openStats(e) } }),
        this.editors.size ? h("button", { class: "wr-pf-chip", attrs: { "data-proof-chip": "" }, on: { click: (e) => this.openProofPanel(e) } }) : null,
      ]),
      h("div", { class: "wr-foot-group wr-foot-right" }, [
        h("button", {
          class: "wr-link wr-small",
          title: "Project targets",
          on: { click: () => this.openProjectSettings() },
          text: goal ? `Draft ${fmt(draftWords)} / ${fmt(goal)}` : `Draft ${fmt(draftWords)} words`,
        }),
        goal ? h("span", { class: "wr-mini-bar", attrs: { style: `--p:${Math.min(100, Math.round((draftWords / goal) * 100))}%` } }) : null,
        this.todayChip(draftWords),
        due ? h("span", { class: `wr-due ${(daysUntil(this.project.settings.deadline) ?? 9) <= 2 ? "is-soon" : ""}`, text: due }) : null,
        h("span", { class: "wr-save", attrs: { "data-save": "" } }),
      ]),
    );
    this.renderSaveState();
    this.updateProofChip();
  }

  private updateSelectionCount(): void {
    const e = this.activeEditor;
    const span = this.root.querySelector<HTMLElement>(".wr-words");
    if (!e || !span) return;
    const { from, to } = e.state.selection;
    const total = Number(span.dataset.words ?? 0);
    if (from === to) span.textContent = `${fmt(total)} words`;
    else span.textContent = `${fmt(countWords(e.state.doc.textBetween(from, to, " ")))} of ${fmt(total)} words`;
  }

  private renderSaveState(): void {
    const el = this.root.querySelector<HTMLElement>("[data-save]");
    if (!el) return;
    const pending = [...this.timers.keys()].some((k) => !k.startsWith("folder:")) || this.saving > 0;
    el.className = `wr-save ${this.saveError ? "is-error" : pending ? "is-pending" : "is-saved"}`;
    el.textContent = this.saveError ? "Not saved, retrying" : pending ? "Saving…" : "Saved";
    el.title = this.saveError || (pending ? "" : `Saved to ${this.project?.dir ?? ""}`);
  }

  // ── Project menu & settings ──────────────────────────────────────────────
  private projectMenu(e: MouseEvent): void {
    const p = this.project;
    if (!p) return;
    const switchItems: MenuItem[] = this.projects
      .filter((x) => x.id !== p.id)
      .slice(0, 8)
      .map((x) => ({ label: x.title, run: () => void this.openProject(x.id) }));
    this.showMenu(e, [
      { label: "Project settings & targets…", run: () => this.openProjectSettings() },
      { label: "Show in Finder", run: () => void writerApi.openFile(p.dir, true).catch((er) => this.toast(er)) },
      { label: "Open Exports folder", run: () => void writerApi.openFile(`${p.dir}/Exports`, false).catch(() => this.toast("Nothing exported yet.")) },
      { label: "Reload from disk", run: () => void this.reload() },
      { label: "Writing record…", run: () => void this.openRecord(null) },
      "-",
      ...(switchItems.length ? [...switchItems, "-" as const] : []),
      { label: "All projects", run: () => void this.goHome() },
    ]);
  }

  private openProjectSettings(): void {
    const p = this.project;
    if (!p) return;
    const s = p.settings;
    const field = (label: string, value: string, attrs: Record<string, string> = {}) => {
      const input = h("input", { class: "wr-input", attrs: { value, ...attrs } });
      return { input, row: h("label", { class: "wr-field wr-field-col" }, [h("span", { text: label }), input]) };
    };
    const title = field("Project title", p.title);
    const author = field("Your name", s.author ?? this.host.settings().author ?? "");
    const subject = field("Subject", s.subject ?? "");
    const teacher = field("Teacher", s.teacher ?? "");
    const school = field("School", s.school ?? "");
    const deadline = field("Due date", s.deadline ?? "", { type: "date" });
    const target = field("Draft word target", s.target ? String(s.target) : "", { type: "number", min: "0", step: "100" });
    const daily = field("Words per day", s.daily ? String(s.daily) : "", { type: "number", min: "0", step: "50", placeholder: "e.g. 250" });
    this.openModal("Project settings", [
      h("div", { class: "wr-form-grid" }, [title.row, author.row, subject.row, teacher.row, school.row, deadline.row, target.row, daily.row]),
      h("p", { class: "wr-faint wr-small", text: "Your name, subject, teacher and school fill in the title page when you export." }),
    ], [
      h("button", { class: "wr-btn", text: "Cancel", on: { click: () => this.closeModal() } }),
      h("button", { class: "wr-btn wr-btn-primary", text: "Save", on: { click: async () => {
        const settings: ProjectSettings = {
          author: author.input.value.trim() || undefined,
          subject: subject.input.value.trim() || undefined,
          teacher: teacher.input.value.trim() || undefined,
          school: school.input.value.trim() || undefined,
          deadline: deadline.input.value || undefined,
          target: Math.max(0, Math.round(Number(target.input.value) || 0)) || undefined,
          daily: Math.max(0, Math.round(Number(daily.input.value) || 0)) || undefined,
        };
        try {
          const r = await writerApi.settings(p.id, { title: title.input.value.trim() || p.title, settings });
          p.title = r.title;
          p.settings = r.settings;
          this.closeModal();
          const t = this.root.querySelector(".wr-proj-btn-title");
          if (t) t.textContent = p.title;
          this.renderFooter();
        } catch (err) {
          this.toast(err);
        }
      } } }),
    ]);
  }

  private appearanceMenu(e: MouseEvent): void {
    const p = this.prefs;
    const set = <K extends keyof Prefs>(k: K, v: Prefs[K]) => () => {
      this.prefs[k] = v;
      this.savePrefs();
      this.applyPrefs();
    };
    this.showMenu(e, [
      { label: "Font: Sans", checked: p.font === "sans", run: set("font", "sans") },
      { label: "Font: Serif", checked: p.font === "serif", run: set("font", "serif") },
      { label: "Font: Mono", checked: p.font === "mono", run: set("font", "mono") },
      "-",
      { label: "Line spacing 1.15", checked: p.spacing === 1.3, run: set("spacing", 1.3) },
      { label: "Line spacing 1.5", checked: p.spacing === 1.6, run: set("spacing", 1.6) },
      { label: "Line spacing 2.0", checked: p.spacing === 2.1, run: set("spacing", 2.1) },
      "-",
      { label: "White page", checked: p.paper === "page", run: set("paper", "page") },
      { label: "Match theme", checked: p.paper === "theme", run: set("paper", "theme") },
      "-",
      { label: "Narrow page", checked: p.width === 620, run: set("width", 620) },
      { label: "Normal page", checked: p.width === 740, run: set("width", 740) },
      { label: "Wide page", checked: p.width === 920, run: set("width", 920) },
      "-",
      { label: "Typewriter scrolling", checked: p.typewriter, run: set("typewriter", !p.typewriter) },
    ]);
  }

  // ── Compose (focus) mode ─────────────────────────────────────────────────
  private toggleCompose(): void {
    const on = !this.root.classList.contains("is-compose");
    this.root.classList.toggle("is-compose", on);
    this.root.querySelector(".wr-compose-bar")?.remove();
    if (on) {
      const n = this.node;
      if (n && this.viewFor(n) !== "doc") {
        // Compose always shows text: open the folder as Scrivenings.
        this.prefs.views[`${this.project!.id}:${n.path}`] = "doc";
        this.renderMain();
      }
      this.root.append(
        h("div", { class: "wr-compose-bar" }, [
          h("span", { class: "wr-small wr-compose-words", attrs: { "data-compose-words": "" } }),
          h("span", { class: "wr-faint wr-small", text: "Esc to leave" }),
          iconBtn("focus", "Dim other paragraphs", (e) => {
            this.prefs.focusLine = !this.prefs.focusLine;
            this.savePrefs();
            this.applyPrefs();
            (e.currentTarget as HTMLElement).classList.toggle("is-on", this.prefs.focusLine);
            this.activeEditor?.commands.focus();
          }, this.prefs.focusLine ? "is-on" : ""),
          iconBtn("typewriter", "Typewriter scrolling", (e) => {
            this.prefs.typewriter = !this.prefs.typewriter;
            this.savePrefs();
            (e.currentTarget as HTMLElement).classList.toggle("is-on", this.prefs.typewriter);
            this.activeEditor?.commands.focus();
          }, this.prefs.typewriter ? "is-on" : ""),
          iconBtn("close", "Leave compose", () => this.toggleCompose()),
        ]),
      );
      this.updateComposeWords();
      this.activeEditor?.commands.focus();
    }
  }

  private updateComposeWords(): void {
    const el = this.root.querySelector<HTMLElement>("[data-compose-words]");
    if (!el || !this.project) return;
    const words = this.visibleDocs().reduce((n, d) => n + countWords(d.body), 0);
    const draft = wordsUnder(this.project.tree[0], true);
    const rec = this.prefs.today[this.project.id];
    const today = rec ? Math.max(0, draft - rec.start) : 0;
    el.textContent = `${fmt(words)} words${today ? ` · +${fmt(today)} today` : ""}`;
  }

  // ── Import ───────────────────────────────────────────────────────────────
  private importFile(): void {
    const input = h("input", { attrs: { type: "file", accept: ".md,.markdown,.txt,.docx,.doc,.rtf,.odt,.html,.htm", multiple: "" } });
    input.style.display = "none";
    this.root.append(input);
    input.addEventListener("change", async () => {
      const files = [...(input.files ?? [])];
      input.remove();
      if (!files.length || !this.project) return;
      const sel = this.node;
      const parent = sel && sel.kind === "folder" && !isInTrash(this.project.tree, sel.path)
        ? sel.path
        : this.project.tree.find((n) => n.role === "research")!.path;
      let last = "";
      for (const f of files) {
        try {
          const r = await writerApi.convert(f.name, await readAsBase64(f));
          const body = r.markdown ?? htmlToMarkdown(r.html ?? "");
          const { path } = await writerApi.add(this.project.id, { parent, kind: "doc", title: f.name.replace(/\.[^.]+$/, ""), body });
          this.keeper()?.event(path, "import", `${f.name} (${fmt(countWords(body))} words)`);
          last = path;
        } catch (err) {
          this.toast(err);
        }
      }
      if (last) {
        this.setExpanded(parent, true);
        await this.reload(last);
        this.toast(files.length > 1 ? `Imported ${files.length} files` : "Imported");
      }
    });
    input.click();
  }

  // ── Export (compile) ─────────────────────────────────────────────────────
  private openExport(): void {
    const p = this.project;
    if (!p) return;
    void this.flushAll();
    const saved = p.settings.export ?? {};
    const preset0 = (saved.preset as PresetId) || (templateById(p.settings.template ?? "").preset as PresetId) || "school";
    const state = {
      format: (saved.format as ExportFormat) || "docx",
      preset: PRESETS.some((x) => x.id === preset0) ? preset0 : ("school" as PresetId),
      titlePage: saved.titlePage ?? true,
      sectionTitles: saved.sectionTitles ?? p.settings.template !== "notes",
      pageNumbers: saved.pageNumbers ?? true,
      wordCount: saved.wordCount ?? false,
      scope: "draft" as "draft" | "selection",
    };
    const sel = this.node;
    const formats = h("div", { class: "wr-chips" });
    const drawFormats = () =>
      formats.replaceChildren(
        ...FORMATS.map((f) =>
          h("button", {
            class: `wr-chip ${state.format === f.id ? "is-on" : ""}`,
            on: { click: () => { state.format = f.id; drawFormats(); syncOptions(); } },
          }, [h("strong", { text: f.name }), h("span", { class: "wr-faint", text: f.ext })]),
        ),
      );
    const preset = this.dropdown(PRESETS.map((x) => x.id), state.preset, (v) => {
      state.preset = v as PresetId;
      presetHint.textContent = PRESETS.find((x) => x.id === v)?.description ?? "";
    });
    preset.querySelectorAll("option").forEach((o) => (o.textContent = PRESETS.find((x) => x.id === o.value)?.name ?? o.value));
    const presetHint = h("span", { class: "wr-faint wr-small", text: PRESETS.find((x) => x.id === state.preset)?.description ?? "" });
    const check = (label: string, key: "titlePage" | "sectionTitles" | "pageNumbers" | "wordCount") => {
      const input = h("input", { attrs: { type: "checkbox" } });
      input.checked = state[key];
      input.addEventListener("change", () => {
        state[key] = input.checked;
        syncOptions();
      });
      return h("label", { class: "wr-check", attrs: { "data-opt": key } }, [input, h("span", { text: label })]);
    };
    const scope = this.dropdown(["draft", "selection"], state.scope, (v) => (state.scope = v as "draft" | "selection"));
    scope.querySelectorAll("option").forEach((o) => (o.textContent = o.value === "draft" ? "The whole Draft" : `Just “${sel?.title ?? "selection"}”`));
    if (!sel || sel.role === "draft") scope.disabled = true;
    const s = p.settings;
    const info = {
      title: h("input", { class: "wr-input", attrs: { value: p.title } }),
      author: h("input", { class: "wr-input", attrs: { value: s.author ?? this.host.settings().author ?? "", placeholder: "Your name" } }),
      subject: h("input", { class: "wr-input", attrs: { value: s.subject ?? "", placeholder: "Subject" } }),
      teacher: h("input", { class: "wr-input", attrs: { value: s.teacher ?? "", placeholder: "Teacher" } }),
      school: h("input", { class: "wr-input", attrs: { value: s.school ?? "", placeholder: "School" } }),
      date: h("input", { class: "wr-input", attrs: { value: formatDate() } }),
    };
    const titleBox = h("div", { class: "wr-form-grid wr-tp" }, Object.entries(info).map(([k, input]) =>
      h("label", { class: "wr-field wr-field-col" }, [h("span", { text: k[0].toUpperCase() + k.slice(1) }), input]),
    ));
    const fileName = h("input", { class: "wr-input", attrs: { value: p.title } });
    const status = h("div", { class: "wr-export-status" });
    const syncOptions = () => {
      const tp = titleBox.closest<HTMLElement>(".wr-export-tp");
      if (tp) tp.hidden = !state.titlePage;
      const extEl = formats.closest(".wr-modal")?.querySelector<HTMLElement>(".wr-ext");
      if (extEl) extEl.textContent = FORMATS.find((f) => f.id === state.format)?.ext ?? "";
      const pn = formats.closest(".wr-modal")?.querySelector<HTMLElement>('[data-opt="pageNumbers"]');
      if (pn) pn.hidden = state.format !== "pdf";
    };
    drawFormats();

    const build = () => {
      const roots = state.scope === "selection" && sel && sel.role !== "draft" ? [sel] : (p.tree[0].children ?? []);
      const opts: CompileOptions = {
        format: state.format,
        preset: state.preset,
        titlePage: state.titlePage,
        sectionTitles: state.sectionTitles,
        pageNumbers: state.pageNumbers,
        wordCount: state.wordCount,
        info: {
          title: info.title.value.trim() || p.title,
          author: info.author.value.trim(),
          subject: info.subject.value.trim(),
          teacher: info.teacher.value.trim(),
          school: info.school.value.trim(),
          date: info.date.value.trim(),
        },
      };
      return { result: compile(roots, opts, markdownToHtml), opts };
    };

    const remember = (opts: CompileOptions) => {
      const settings: ProjectSettings = {
        export: { format: opts.format, preset: opts.preset, titlePage: opts.titlePage, sectionTitles: opts.sectionTitles, pageNumbers: opts.pageNumbers, wordCount: opts.wordCount },
        author: opts.info.author || undefined,
        subject: opts.info.subject || undefined,
        teacher: opts.info.teacher || undefined,
        school: opts.info.school || undefined,
      };
      p.settings = { ...p.settings, ...settings };
      void writerApi.settings(p.id, { settings }).catch(() => {});
    };

    const doExport = async () => {
      await this.flushAll();
      const { result, opts } = build();
      if (!result.sections) {
        status.replaceChildren(h("p", { class: "wr-error", text: "There's nothing to export: the Draft is empty or everything is left out." }));
        return;
      }
      remember(opts);
      status.replaceChildren(h("div", { class: "wr-spinner wr-spinner-small" }), h("span", { text: state.format === "pdf" ? "Making the PDF…" : "Exporting…" }));
      try {
        const r = await writerApi.export(p.id, {
          name: fileName.value.trim() || p.title,
          format: state.format,
          html: result.html,
          markdown: result.markdown,
          text: result.text,
        });
        status.replaceChildren(
          h("p", { class: "wr-ok", text: `Saved ${r.name} (${fmt(result.words)} words) in the project's Exports folder.` }),
          h("div", { class: "wr-row-btns" }, [
            h("button", { class: "wr-btn wr-btn-primary", text: "Open", on: { click: () => void writerApi.openFile(r.path).catch((e) => this.toast(e)) } }),
            h("button", { class: "wr-btn", text: "Show in Finder", on: { click: () => void writerApi.openFile(r.path, true).catch((e) => this.toast(e)) } }),
          ]),
        );
      } catch (err) {
        status.replaceChildren(h("p", { class: "wr-error", text: err instanceof Error ? err.message : String(err) }));
      }
    };

    const preview = () => {
      const { result, opts } = build();
      remember(opts);
      const frame = h("iframe", { class: "wr-preview-frame", attrs: { title: "Preview", sandbox: "allow-same-origin allow-modals" } });
      frame.srcdoc = result.html;
      this.openModal(`Preview · ${fmt(result.words)} words`, [frame], [
        h("button", { class: "wr-btn", text: "Back", on: { click: () => { this.closeModal(); this.openExport(); } } }),
        h("button", { class: "wr-btn wr-btn-primary", text: "Print…", on: { click: () => frame.contentWindow?.print() } }),
      ], "wide");
    };

    const ext = h("span", { class: "wr-ext" });
    const section = (title: string, kids: Child[], cls = "") =>
      h("section", { class: `wr-export-sec ${cls}` }, [h("h3", { class: "wr-export-h", text: title }), ...kids]);
    this.openModal("Export", [
      h("div", { class: "wr-export" }, [
        section("Format", [formats]),
        section("Layout", [
          h("div", { class: "wr-form-grid" }, [
            h("label", { class: "wr-field wr-field-col" }, [h("span", { text: "Style" }), preset, presetHint]),
            h("label", { class: "wr-field wr-field-col" }, [h("span", { text: "What to export" }), scope]),
          ]),
          h("div", { class: "wr-checks" }, [
            check("Title page", "titlePage"),
            check("Binder titles as headings", "sectionTitles"),
            check("Page numbers", "pageNumbers"),
            check("Word count at the end", "wordCount"),
          ]),
        ]),
        section("Title page", [titleBox], "wr-export-tp"),
        section("Save as", [
          h("div", { class: "wr-file-row" }, [fileName, ext]),
          h("p", { class: "wr-faint wr-small", text: "Saved in the project's Exports folder. Documents with “Include in export” off are skipped; Research and Notes are never exported." }),
        ]),
        status,
      ]),
    ], [
      h("button", { class: "wr-btn", text: "Preview & print", on: { click: preview } }),
      h("span", { class: "wr-grow" }),
      h("button", { class: "wr-btn", text: "Close", on: { click: () => this.closeModal() } }),
      h("button", { class: "wr-btn wr-btn-primary", text: "Export", on: { click: () => void doExport() } }),
    ], "export");
    syncOptions();
  }

  // ── Menus, modals, toasts ────────────────────────────────────────────────
  private showMenu(e: MouseEvent, items: MenuItem[]): void {
    e.preventDefault?.();
    this.closeMenu();
    const menu = h("div", { class: "wr-menu", attrs: { role: "menu" } });
    for (const item of items) {
      if (item === "-") {
        menu.append(h("div", { class: "wr-menu-sep" }));
        continue;
      }
      const b = h("button", {
        class: `wr-menu-item ${item.danger ? "is-danger" : ""}`,
        attrs: { role: "menuitem", ...(item.disabled ? { disabled: "" } : {}) },
        on: { click: () => { this.closeMenu(); item.run(); } },
      }, [
        h("span", { class: "wr-menu-check", text: item.checked ? "✓" : "" }),
        h("span", { class: "wr-menu-label", text: item.label }),
        item.hint ? h("span", { class: "wr-faint", text: item.hint }) : null,
      ]);
      menu.append(b);
    }
    this.root.append(menu);
    const w = menu.offsetWidth;
    const hgt = menu.offsetHeight;
    const target = (e.currentTarget as HTMLElement | null) ?? null;
    let x = e.clientX;
    let y = e.clientY;
    if (target && target instanceof HTMLElement && (e.type === "click" || !e.clientX)) {
      const r = target.getBoundingClientRect();
      x = r.left;
      y = r.bottom + 4;
    }
    menu.style.left = `${Math.max(8, Math.min(x, window.innerWidth - w - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - hgt - 8))}px`;
    this.menu = menu;
    (menu.querySelector("button:not([disabled])") as HTMLElement | null)?.focus();
  }

  private closeMenu(): void {
    this.menu?.remove();
    this.menu = null;
  }

  /** Escape when focus isn't inside the Writer (Safari doesn't focus buttons you click). */
  private onDocKey = (e: KeyboardEvent) => {
    if (e.key !== "Escape" || this.root.contains(e.target as Node)) return;
    if (this.menu) this.closeMenu();
    else if (this.modal) this.closeModal();
    else if (this.find.open) this.closeFind();
    else if (this.root.classList.contains("is-compose")) this.toggleCompose();
    else return;
    e.preventDefault();
  };

  private onOutside = (e: PointerEvent) => {
    if (this.menu && !this.menu.contains(e.target as Node)) this.closeMenu();
  };

  private openModal(title: string, body: Child[], actions: Child[], size = ""): void {
    this.closeModal();
    const close = iconBtn("close", "Close", () => this.closeModal(), "wr-modal-x");
    const modal = h("div", { class: "wr-modal-back", on: { mousedown: (e) => { if (e.target === modal) this.closeModal(); } } }, [
      h("div", { class: `wr-modal ${size ? `is-${size}` : ""}`, attrs: { role: "dialog", "aria-modal": "true", "aria-label": title || "Dialog" } }, [
        title ? h("header", { class: "wr-modal-head" }, [h("h2", { text: title }), close]) : null,
        h("div", { class: "wr-modal-body" }, body),
        actions.length ? h("footer", { class: "wr-modal-foot" }, actions) : null,
      ]),
    ]);
    this.root.append(modal);
    this.modal = modal;
  }

  private closeModal(): void {
    this.modal?.remove();
    this.modal = null;
  }

  private confirm(title: string, text: string, ok: string): Promise<boolean> {
    return new Promise((resolve) => {
      const done = (v: boolean) => {
        this.closeModal();
        resolve(v);
      };
      this.openModal(title, [h("p", { class: "wr-muted", text })], [
        h("button", { class: "wr-btn", text: "Cancel", on: { click: () => done(false) } }),
        h("button", { class: "wr-btn wr-btn-danger", text: ok, on: { click: () => done(true) } }),
      ]);
      (this.modal?.querySelector(".wr-btn-danger") as HTMLElement | null)?.focus();
    });
  }

  private prompt(title: string, text: string, value: string, placeholder = ""): Promise<string | null> {
    return new Promise((resolve) => {
      const input = h("input", { class: "wr-input", attrs: { value, placeholder } });
      let settled = false;
      const done = (v: string | null) => {
        if (settled) return;
        settled = true;
        this.closeModal();
        resolve(v);
      };
      input.addEventListener("keydown", (e) => {
        e.stopPropagation();
        if (e.key === "Enter") done(input.value);
        if (e.key === "Escape") done(null);
      });
      this.openModal(title, [h("p", { class: "wr-muted wr-small", text }), input], [
        h("button", { class: "wr-btn", text: "Cancel", on: { click: () => done(null) } }),
        h("button", { class: "wr-btn wr-btn-primary", text: "OK", on: { click: () => done(input.value) } }),
      ]);
      setTimeout(() => {
        input.focus();
        input.select();
      }, 20);
    });
  }

  private toast(msg: unknown): void {
    const text = msg instanceof Error ? msg.message : String(msg);
    const t = h("div", { class: `wr-toast ${msg instanceof Error ? "is-error" : ""}`, text, attrs: { role: "status" } });
    this.root.append(t);
    setTimeout(() => t.classList.add("is-out"), 2600);
    setTimeout(() => t.remove(), 3000);
  }

  // ── Comments ─────────────────────────────────────────────────────────────
  private visibleDocs(): BinderNode[] {
    const n = this.node;
    if (!n || !this.project) return [];
    if (n.kind === "doc") return [n];
    return this.viewFor(n) === "doc" ? docsUnder(n).slice(0, 60) : [];
  }

  private commentsOf(path: string): Comment[] {
    const n = this.project && findNode(this.project.tree, path);
    if (!n?.meta.comments) return [];
    try {
      const list = JSON.parse(n.meta.comments);
      return Array.isArray(list) ? (list as Comment[]).filter((c) => c && typeof c.id === "string") : [];
    } catch {
      return [];
    }
  }

  private saveComments(path: string, list: Comment[]): void {
    const n = this.project && findNode(this.project.tree, path);
    if (!n) return;
    this.setMeta(n, { comments: list.length ? JSON.stringify(list) : undefined }, false);
    this.refreshCommentMarks();
  }

  private refreshCommentMarks(): void {
    for (const ed of this.editors.values()) if (!ed.isDestroyed) ed.view.dispatch(ed.state.tr.setMeta(commentKey, true));
  }

  private pathOfEditor(ed: Editor | null): string | null {
    for (const [path, e] of this.editors) if (e === ed) return path;
    return null;
  }

  private addComment(): void {
    const ed = this.activeEditor;
    const path = this.pathOfEditor(ed);
    if (!ed || !path || ed.isDestroyed) return;
    const { from, to, empty } = ed.state.selection;
    if (empty) {
      this.toast("Select the words you want to comment on first.");
      return;
    }
    const end = Math.min(to, ed.state.doc.resolve(from).end());
    const quote = ed.state.doc.textBetween(from, end, " ", " ").slice(0, 300);
    if (!quote.trim()) return;
    const c: Comment = {
      id: `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
      quote,
      before: contextBefore(ed.state, from),
      text: "",
      at: new Date().toISOString(),
    };
    this.saveComments(path, [...this.commentsOf(path), c]);
    this.activeComment = c.id;
    this.editingComment = c.id;
    this.prefs.inspectorTab = "comments";
    if (!this.prefs.inspector) this.togglePref("inspector");
    this.savePrefs();
    this.hideBubble();
    this.renderInspector();
    this.refreshCommentMarks();
  }

  private showComment(id: string): void {
    this.activeComment = id;
    this.prefs.inspectorTab = "comments";
    if (!this.prefs.inspector) this.togglePref("inspector");
    this.renderInspector();
    this.refreshCommentMarks();
    this.root.querySelector(`.wr-cmt-card[data-id="${CSS.escape(id)}"]`)?.scrollIntoView({ block: "nearest" });
  }

  private jumpToComment(path: string, c: Comment): void {
    const ed = this.editors.get(path);
    if (!ed || ed.isDestroyed) return;
    const r = locateQuote(ed.state.doc, c.quote, c.before);
    this.activeComment = c.id;
    this.refreshCommentMarks();
    this.root.querySelectorAll(".wr-cmt-card").forEach((x) => x.classList.toggle("is-active", (x as HTMLElement).dataset.id === c.id));
    if (!r) return;
    ed.chain().setTextSelection(r).run();
    this.scrollToPos(ed, r.from);
  }

  private renderComments(): HTMLElement {
    const box = h("div", { class: "wr-cmts" });
    const docs = this.visibleDocs();
    const many = docs.length > 1;
    const ago = (iso: string) => {
      const mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
      if (!Number.isFinite(mins)) return "";
      if (mins < 1) return "just now";
      if (mins < 60) return `${mins} min ago`;
      if (mins < 60 * 24) return `${Math.round(mins / 60)} h ago`;
      return new Date(iso).toLocaleDateString("en-AU", { day: "numeric", month: "short" });
    };
    const ed0 = this.activeEditor;
    box.append(
      h("button", { class: "wr-btn wr-btn-full", title: "Comment on the selected words (⌥⌘M)", on: { mousedown: (e) => e.preventDefault(), click: () => this.addComment() } }, [h("span", { icon: "comment" }), "Comment on selection"]),
    );
    if (!ed0) box.lastElementChild?.setAttribute("disabled", "");
    let total = 0;
    const resolved: Array<[string, Comment]> = [];
    for (const d of docs) {
      const list = this.commentsOf(d.path);
      const ed = this.editors.get(d.path);
      const pos = (c: Comment) => (ed && !ed.isDestroyed ? (locateQuote(ed.state.doc, c.quote, c.before)?.from ?? 1e9) : 1e9);
      const open = list.filter((c) => !c.done).sort((a, b) => pos(a) - pos(b));
      resolved.push(...list.filter((c) => c.done).map((c) => [d.path, c] as [string, Comment]));
      if (!open.length) continue;
      if (many) box.append(h("div", { class: "wr-cmt-doc", text: d.title }));
      for (const c of open) {
        total++;
        box.append(this.commentCard(d.path, c, list, ago, pos(c) === 1e9));
      }
    }
    if (!total) {
      box.append(
        h("div", { class: "wr-cmt-empty" }, [
          h("span", { icon: "comment" }),
          h("p", { text: "Leave yourself notes on the text: “check this date”, “needs a quote”, “teacher said…”." }),
          h("p", { class: "wr-faint", text: "Select words, then press ⌥⌘M or the comment button. Comments are never exported." }),
        ]),
      );
    }
    if (resolved.length) {
      const det = h("details", { class: "wr-cmt-resolved" }, [h("summary", { text: `Resolved (${resolved.length})` })]);
      for (const [path, c] of resolved) {
        det.append(
          h("div", { class: "wr-cmt-card is-done", attrs: { "data-id": c.id } }, [
            h("div", { class: "wr-cmt-quote", text: `“${c.quote}”` }),
            c.text ? h("p", { class: "wr-cmt-text", text: c.text }) : null,
            h("div", { class: "wr-cmt-foot" }, [
              h("span", { class: "wr-faint", text: ago(c.at) }),
              h("span", { class: "wr-grow" }),
              h("button", { class: "wr-link wr-small", text: "Reopen", on: { click: () => {
                this.saveComments(path, this.commentsOf(path).map((x) => (x.id === c.id ? { ...x, done: false } : x)));
                this.renderInspector();
              } } }),
              h("button", { class: "wr-link wr-small wr-danger-link", text: "Delete", on: { click: () => {
                this.saveComments(path, this.commentsOf(path).filter((x) => x.id !== c.id));
                this.renderInspector();
              } } }),
            ]),
          ]),
        );
      }
      box.append(det);
    }
    return box;
  }

  private commentCard(path: string, c: Comment, _list: Comment[], ago: (iso: string) => string, detached: boolean): HTMLElement {
    const update = (patch: Partial<Comment> | null) => {
      const list = this.commentsOf(path);
      this.saveComments(path, patch === null ? list.filter((x) => x.id !== c.id) : list.map((x) => (x.id === c.id ? { ...x, ...patch } : x)));
    };
    const editing = this.editingComment === c.id;
    const card = h("div", {
      class: `wr-cmt-card ${this.activeComment === c.id ? "is-active" : ""} ${detached ? "is-detached" : ""}`,
      attrs: { "data-id": c.id },
      on: { click: (e) => { if (!(e.target as HTMLElement).closest("button,textarea")) this.jumpToComment(path, c); } },
    });
    card.append(
      h("div", { class: "wr-cmt-quote", title: detached ? "The text this was on has changed" : "Show in the text", text: `“${c.quote}”` }),
    );
    if (detached) card.append(h("p", { class: "wr-faint wr-small", text: "The text this was on has changed." }));
    if (editing) {
      const ta = h("textarea", { class: "wr-input wr-cmt-input", attrs: { rows: "3", placeholder: "Your comment…" } });
      ta.value = c.text;
      const save = () => {
        const text = ta.value.trim();
        this.editingComment = null;
        if (!text && !c.text) update(null);
        else update({ text });
        this.renderInspector();
      };
      ta.addEventListener("keydown", (e) => {
        e.stopPropagation();
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey || !e.shiftKey)) {
          e.preventDefault();
          save();
        }
        if (e.key === "Escape") {
          this.editingComment = null;
          if (!c.text) update(null);
          this.renderInspector();
        }
      });
      card.append(
        ta,
        h("div", { class: "wr-cmt-foot" }, [
          h("span", { class: "wr-faint wr-small", text: "↵ to save · ⇧↵ new line" }),
          h("span", { class: "wr-grow" }),
          h("button", { class: "wr-btn wr-btn-small wr-btn-primary", text: "Save", on: { click: save } }),
        ]),
      );
      setTimeout(() => ta.focus(), 20);
    } else {
      card.append(
        h("p", { class: "wr-cmt-text", text: c.text }),
        h("div", { class: "wr-cmt-foot" }, [
          h("span", { class: "wr-faint", text: ago(c.at) }),
          h("span", { class: "wr-grow" }),
          iconBtn("check", "Resolve", () => { update({ done: true }); if (this.activeComment === c.id) this.activeComment = null; this.renderInspector(); }, "wr-cmt-act"),
          h("button", { class: "wr-link wr-small", text: "Edit", on: { click: () => { this.editingComment = c.id; this.renderInspector(); } } }),
          h("button", { class: "wr-link wr-small wr-danger-link", text: "Delete", on: { click: () => { update(null); this.renderInspector(); } } }),
        ]),
      );
    }
    return card;
  }

  // ── Safety & numbers ─────────────────────────────────────────────────────

  /**
   * Keeps an automatic version of a document before a save overwrites it, at most every
   * AUTO_VERSION_MS (Atlantis: was once per 6 hours). Together these are the doc's edit history;
   * the store skips empty docs and copies that match the newest one.
   */
  private async autoSnapshot(projectId: string, n: BinderNode): Promise<void> {
    const key = `${projectId}:${n.path}`;
    const last = this.prefs.autoSnap[key] ?? 0;
    if (Date.now() - last < AUTO_VERSION_MS) return;
    this.prefs.autoSnap[key] = Date.now();
    this.savePrefs();
    await writerApi.snapshot(projectId, n.path, "Auto", true).catch(() => {});
  }

  private todayChip(draftWords: number): HTMLElement | null {
    const p = this.project;
    if (!p) return null;
    const d = new Date();
    const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    let rec = this.prefs.today[p.id];
    if (!rec || rec.date !== today) {
      rec = { date: today, start: draftWords };
      this.prefs.today[p.id] = rec;
      this.savePrefs();
    }
    const delta = Math.max(0, draftWords - rec.start);
    const goal = p.settings.daily ?? 0;
    if (!goal && !delta) return null;
    const pct = goal ? Math.min(100, Math.round((delta / goal) * 100)) : 0;
    return h("button", {
      class: `wr-today ${goal && delta >= goal ? "is-done" : ""}`,
      title: goal ? `${fmt(delta)} of ${fmt(goal)} words today` : "Words added to the Draft today. Set a daily goal in project settings.",
      attrs: goal ? { style: `--p:${pct}%` } : {},
      on: { click: () => this.openProjectSettings() },
    }, [goal ? h("span", { class: "wr-ring" }) : null, `+${fmt(delta)} today`]);
  }

  private openStats(e: MouseEvent): void {
    const p = this.project;
    if (!p) return;
    const ed = this.activeEditor;
    const sel = ed && !ed.isDestroyed && !ed.state.selection.empty ? ed.state.doc.textBetween(ed.state.selection.from, ed.state.selection.to, "\n\n") : "";
    const docs = this.visibleDocs();
    const viewText = docs.map((d) => d.body ?? "").join("\n\n");
    const draftText = docsUnder(p.tree[0]).filter((d) => d.meta.compile !== false).map((d) => d.body ?? "").join("\n\n");
    const scopes: Array<[string, string]> = [];
    if (sel) scopes.push(["Selection", sel]);
    if (docs.length) scopes.push([docs.length > 1 ? "This folder" : "This document", viewText]);
    scopes.push(["Whole draft", draftText]);
    let at = 0;
    const panel = h("div", { class: "wr-menu wr-stats", attrs: { role: "dialog", "aria-label": "Writing stats" } });
    const draw = () => {
      const st = textStats(scopes[at][1]);
      const row = (label: string, value: string, hint = "") => h("div", { class: "wr-stat-row", title: hint }, [h("span", { class: "wr-muted", text: label }), h("strong", { text: value })]);
      const ease = st.readingEase;
      panel.replaceChildren(
        scopes.length > 1
          ? h("div", { class: "wr-seg-text" }, scopes.map(([label], i) => h("button", { class: i === at ? "is-on" : "", text: label, on: { click: () => { at = i; draw(); } } })))
          : h("div", { class: "wr-stat-title", text: scopes[0][0] }),
        h("div", { class: "wr-stat-big" }, [h("strong", { text: fmt(st.words) }), h("span", { class: "wr-muted", text: " words" })]),
        row("Characters", `${fmt(st.characters)} (${fmt(st.charactersNoSpaces)} without spaces)`),
        row("Sentences · paragraphs", `${fmt(st.sentences)} · ${fmt(st.paragraphs)}`),
        row("Average sentence", `${st.avgSentence} words`, "Most school writing reads best at 15–22 words per sentence."),
        row("Reading time", minutesLabel(st.readingMinutes)),
        row("Speaking time", minutesLabel(st.speakingMinutes), "At a calm speech pace (130 words a minute)."),
        h("div", { class: "wr-stat-ease" }, [
          h("div", { class: "wr-stat-row" }, [h("span", { class: "wr-muted", text: "Readability" }), h("strong", { text: st.readingLabel })]),
          ease === null ? null : h("div", { class: "wr-ease-bar", attrs: { style: `--p:${ease}%` }, title: `Flesch reading ease ${ease}/100` }),
          st.longSentences ? h("p", { class: "wr-faint wr-small", text: `${st.longSentences} sentence${st.longSentences === 1 ? " is" : "s are"} over 30 words — worth splitting.` }) : null,
          this.editors.size
            ? h("label", { class: "wr-check wr-small" }, [
                (() => {
                  const cb = h("input", { attrs: { type: "checkbox" } });
                  cb.checked = this.prefs.review;
                  cb.addEventListener("change", () => this.toggleReview(cb.checked));
                  return cb;
                })(),
                h("span", { text: "Highlight long sentences and filler words" }),
              ])
            : null,
        ]),
      );
    };
    draw();
    this.closeMenu();
    this.root.append(panel);
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    panel.style.left = `${Math.max(8, Math.min(r.left + r.width / 2 - panel.offsetWidth / 2, window.innerWidth - panel.offsetWidth - 8))}px`;
    panel.style.top = `${Math.max(8, r.top - panel.offsetHeight - 8)}px`;
    this.menu = panel;
  }

  private toggleReview(on = !this.prefs.review): void {
    this.prefs.review = on;
    this.savePrefs();
    for (const ed of this.editors.values()) if (!ed.isDestroyed) ed.view.dispatch(ed.state.tr.setMeta(reviewKey, true));
    if (on) {
      let long = 0;
      let filler = 0;
      for (const ed of this.editors.values()) {
        if (ed.isDestroyed) continue;
        for (const r of reviewRanges(ed.state.doc)) r.kind === "long" ? long++ : filler++;
      }
      this.toast(long || filler ? `Check: ${long} long sentence${long === 1 ? "" : "s"}, ${filler} filler word${filler === 1 ? "" : "s"} highlighted` : "Check: nothing to flag here");
    }
  }

  /** One-time tips for the first project someone opens. */
  private showTips(): void {
    if (this.prefs.tipsSeen || this.root.querySelector(".wr-tips")) return;
    const close = () => {
      this.prefs.tipsSeen = true;
      this.savePrefs();
      card.remove();
    };
    const tip = (k: string, t: string) => h("li", {}, [h("kbd", { text: k }), h("span", { text: t })]);
    const card = h("div", { class: "wr-tips", attrs: { role: "note" } }, [
      h("div", { class: "wr-tips-head" }, [h("span", { icon: "sparkle" }), h("strong", { text: "Quick tips" }), iconBtn("close", "Got it", close)]),
      h("ul", {}, [
        tip("/", "on a new line inserts headings, lists, tables"),
        tip("Select", "text to format it or leave a comment"),
        tip("⌘O", "jumps to any document or command"),
        tip("Cards", "plan with index cards, then drag to reorder"),
      ]),
      h("button", { class: "wr-link wr-small", text: "All shortcuts", on: { click: () => { close(); this.openShortcuts(); } } }),
    ]);
    this.root.append(card);
  }

  private get narrow(): number {
    return this.root.clientWidth || window.innerWidth;
  }

  /** Below 1100px the inspector (and below 760px the binder) slide over the page instead. */
  private togglePanel(key: "binder" | "inspector"): void {
    const limit = key === "inspector" ? 1100 : 760;
    if (this.narrow < limit) {
      const cls = `drawer-${key}`;
      const on = !this.root.classList.contains(cls);
      this.root.classList.remove("drawer-binder", "drawer-inspector");
      this.root.classList.toggle(cls, on);
      return;
    }
    this.togglePref(key);
  }

  // ── Reference maker ──────────────────────────────────────────────────────
  private get citeStyle(): CiteStyle {
    const st = this.project?.settings.citeStyle;
    return st && CITE_STYLES.some((x) => x.id === st) ? st : "harvard";
  }

  /** The Draft's reference list: a doc labelled References or called References/Bibliography/Works Cited. */
  private findReferencesDoc(): BinderNode | null {
    const p = this.project;
    if (!p) return null;
    const docs = docsUnder(p.tree[0]);
    return (
      docs.find((d) => d.meta.label === "References") ??
      docs.find((d) => /^(references?|reference list|bibliography|works cited|sources)$/i.test(d.title.trim())) ??
      null
    );
  }

  private async ensureReferencesDoc(): Promise<BinderNode | null> {
    const p = this.project;
    if (!p) return null;
    const found = this.findReferencesDoc();
    if (found) return found;
    const title = this.citeStyle === "mla" ? "Works Cited" : "References";
    const { path } = await writerApi.add(p.id, { parent: p.tree[0].path, kind: "doc", title, meta: { label: "References" }, body: "" });
    await this.reload(this.selected);
    return findNode(this.project!.tree, path);
  }

  /** Puts an entry into the reference list doc (through its editor when it's open). */
  private async addToReferences(entry: string): Promise<{ added: boolean; doc: BinderNode | null }> {
    const doc = await this.ensureReferencesDoc();
    if (!doc) return { added: false, doc: null };
    const ed = this.editors.get(doc.path);
    const current = ed && !ed.isDestroyed ? ed.getMarkdown() : (doc.body ?? "");
    const { body, added } = addToReferenceList(current, entry);
    if (!added) return { added, doc };
    if (ed && !ed.isDestroyed) {
      ed.commands.setContent(body, { contentType: "markdown", emitUpdate: true });
    } else {
      doc.body = body;
      this.scheduleSave(doc.path);
    }
    return { added, doc };
  }

  private rememberReference(ref: Reference): void {
    const p = this.project;
    if (!p) return;
    const same = (a: Reference) => (ref.doi && a.doi === ref.doi) || (ref.url && a.url === ref.url) || (a.id && a.id === ref.id);
    const list = (p.settings.references ?? []).filter((a) => !same(a));
    const saved: Reference = { ...ref, id: ref.id ?? `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}` };
    delete saved.partial;
    delete saved.note;
    list.push(saved);
    p.settings.references = list;
    void writerApi.settings(p.id, { settings: { references: list } }).catch((e) => this.toast(e));
  }

  private setCiteStyle(style: CiteStyle): void {
    const p = this.project;
    if (!p || p.settings.citeStyle === style) return;
    p.settings.citeStyle = style;
    void writerApi.settings(p.id, { settings: { citeStyle: style } }).catch(() => {});
  }

  private insertCitationAt(target: { editor: Editor; pos: number } | null, text: string): boolean {
    if (!target || target.editor.isDestroyed || !target.editor.isEditable) return false;
    const { editor } = target;
    let pos = Math.min(target.pos, editor.state.doc.content.size);
    // Right after a sentence's full stop? The citation belongs before it: "…a possibility (Clark, 2012)."
    const $pos = editor.state.doc.resolve(pos);
    const prev = editor.state.doc.textBetween(Math.max($pos.start(), pos - 1), pos, " ", " ");
    const next = editor.state.doc.textBetween(pos, Math.min($pos.end(), pos + 1), " ", " ");
    if (/[.!?]/.test(prev) && (!next || next === " ") && !/\b(?:e\.g|i\.e|etc|al)\.$/i.test(editor.state.doc.textBetween(Math.max($pos.start(), pos - 6), pos, " ", " "))) pos -= 1;
    const before = editor.state.doc.textBetween(Math.max(0, pos - 1), pos, " ", " ");
    const lead = before && !/[\s(\[“"‘]/.test(before) ? " " : "";
    // "(*Title*, 2024)" → text nodes with an italic mark, so no stray asterisks.
    const nodes = `${lead}${text}`
      .split(/(\*[^*]+\*)/)
      .filter(Boolean)
      .map((part) => (/^\*[^*]+\*$/.test(part) ? { type: "text", text: part.slice(1, -1), marks: [{ type: "italic" }] } : { type: "text", text: part }));
    editor.chain().focus().insertContentAt(pos, nodes).run();
    return true;
  }

  private openReferences(prefill = ""): void {
    const p = this.project;
    if (!p) return;
    const ed = this.activeEditor && !this.activeEditor.isDestroyed ? this.activeEditor : null;
    const target = ed ? { editor: ed, pos: ed.state.selection.to } : null;
    this.hideBubble();
    let style = this.citeStyle;
    let ref: Reference | null = null;

    // ── link box
    const linkInput = h("input", { class: "wr-input wr-ref-link", attrs: { placeholder: "Paste a link or DOI, e.g. https://www.awm.gov.au/… or 10.1038/…", value: prefill, "aria-label": "Link" } });
    const lookBtn = h("button", { class: "wr-btn wr-btn-primary", text: "Look up" });
    const status = h("p", { class: "wr-ref-status wr-small" });

    // ── style chips
    const styles = h("div", { class: "wr-seg-text wr-ref-styles", attrs: { role: "radiogroup", "aria-label": "Referencing style" } });
    const drawStyles = () =>
      styles.replaceChildren(
        ...CITE_STYLES.map((st) =>
          h("button", { class: st.id === style ? "is-on" : "", title: st.hint, text: st.name, attrs: { role: "radio", "aria-checked": String(st.id === style) }, on: { click: () => { style = st.id; this.setCiteStyle(style); drawStyles(); preview(); drawSaved(); } } }),
        ),
      );

    // ── form
    const field = (label: string, input: HTMLElement, cls = "") => h("label", { class: `wr-field wr-field-col ${cls}` }, [h("span", { text: label }), input]);
    const kind = this.dropdown(REF_KINDS.map((k) => k.id), "webpage", () => { syncKind(); preview(); });
    kind.querySelectorAll("option").forEach((o) => (o.textContent = REF_KINDS.find((k) => k.id === o.value)?.name ?? o.value));
    const inp = (ph = "", type = "text") => h("input", { class: "wr-input", attrs: { placeholder: ph, type } });
    const date = inp("2024-04-25, or just 2024");
    const authors = h("textarea", { class: "wr-input", attrs: { rows: "3", placeholder: "One per line: Surname, First names — or an organisation" } });
    const title = inp("Title of the page, article or book");
    const container = inp("e.g. ABC News");
    const publisher = inp("e.g. Penguin");
    const volume = inp("12");
    const issue = inp("3");
    const pages = inp("4–9");
    const url = inp("https://…");
    const accessed = inp("", "date");
    accessed.value = new Date().toISOString().slice(0, 10);
    const where = h("input", { class: "wr-input wr-ref-page", attrs: { placeholder: "Page (optional)", "aria-label": "Page or paragraph for the in-text citation" } });
    const authorsField = field("Authors", authors);
    const dateField = field("Published", date);
    const titleField = field("Title", title);
    const containerField = field("Website", container);
    const markAi = (fields: string[] = []) => {
      const map: Record<string, HTMLElement> = { authors: authorsField, date: dateField, title: titleField, site: containerField };
      for (const [k, el] of Object.entries(map)) {
        el.classList.toggle("is-ai", fields.includes(k));
        el.title = fields.includes(k) ? "Claude read this off the page — check it" : "";
      }
    };
    // Editing a field Claude filled means it's been checked.
    for (const [el, f] of [[authors, authorsField], [date, dateField], [title, titleField], [container, containerField]] as const)
      el.addEventListener("input", () => f.classList.remove("is-ai"));
    const articleRow = h("div", { class: "wr-ref-grid3" }, [field("Volume", volume), field("Issue", issue), field("Pages", pages)]);
    const publisherField = field("Publisher", publisher);
    const form = h("div", { class: "wr-ref-form", attrs: { hidden: "" } }, [
      h("div", { class: "wr-ref-grid2" }, [field("Type", kind), dateField]),
      authorsField,
      titleField,
      containerField,
      articleRow,
      publisherField,
      h("div", { class: "wr-ref-grid2" }, [field("Link", url), field("Accessed", accessed)]),
    ]);
    const syncKind = () => {
      const k = kind.value as RefKind;
      (containerField.firstChild as HTMLElement).textContent = k === "article" ? "Journal" : k === "video" ? "Platform" : k === "book" ? "Series (optional)" : "Website";
      articleRow.hidden = k !== "article";
      publisherField.hidden = !(k === "book" || k === "report");
    };

    const read = (): Reference => {
      const d = date.value.trim();
      let year: string | undefined;
      let month: number | undefined;
      let day: number | undefined;
      const iso = /^(\d{4})(?:-(\d{1,2}))?(?:-(\d{1,2}))?$/.exec(d);
      if (iso) {
        year = iso[1];
        month = iso[2] ? Number(iso[2]) : undefined;
        day = iso[3] ? Number(iso[3]) : undefined;
      } else if (d && !Number.isNaN(Date.parse(d))) {
        const x = new Date(d);
        year = String(x.getFullYear());
        month = /[a-z]/i.test(d) || /\d+\D+\d+/.test(d) ? x.getMonth() + 1 : undefined;
        day = /\d{1,2}\D+\w+\D+\d{4}|\w+\s+\d{1,2},/.test(d) ? x.getDate() : undefined;
      } else if (/\b\d{4}\b/.test(d)) year = /\b\d{4}\b/.exec(d)![0];
      return {
        ...(ref ?? {}),
        kind: kind.value as RefKind,
        authors: textToAuthors(authors.value),
        title: title.value.trim(),
        container: container.value.trim() || undefined,
        publisher: publisher.value.trim() || undefined,
        year,
        month,
        day,
        volume: volume.value.trim() || undefined,
        issue: issue.value.trim() || undefined,
        pages: pages.value.trim() || undefined,
        url: url.value.trim() || undefined,
        accessed: accessed.value || undefined,
      };
    };
    const fill = (r: Reference) => {
      ref = r;
      kind.value = r.kind;
      authors.value = authorsToText(r.authors ?? []);
      title.value = r.title ?? "";
      container.value = r.container ?? "";
      publisher.value = r.publisher ?? "";
      date.value = r.year ? [r.year, r.month && String(r.month).padStart(2, "0"), r.day && String(r.day).padStart(2, "0")].filter(Boolean).join("-") : "";
      volume.value = r.volume ?? "";
      issue.value = r.issue ?? "";
      pages.value = r.pages ?? "";
      url.value = r.doi ? `https://doi.org/${r.doi}` : (r.url ?? "");
      if (r.accessed) accessed.value = r.accessed;
      syncKind();
      markAi([]);
      form.hidden = false;
      out.hidden = false;
      preview();
    };

    // ── preview
    const listOut = h("div", { class: "wr-ref-entry wr-prose" });
    const textOut = h("code", { class: "wr-ref-intext" });
    const missing = h("p", { class: "wr-ref-missing wr-small" });
    const out = h("div", { class: "wr-ref-out", attrs: { hidden: "" } }, [
      h("div", { class: "wr-ref-out-head" }, [h("span", { text: "Reference list" }), iconBtn("copy", "Copy", () => void copy(formatReference(read(), style)))]),
      listOut,
      h("div", { class: "wr-ref-out-head" }, [h("span", { text: "In the text" }), where]),
      h("div", { class: "wr-ref-intext-row" }, [textOut, iconBtn("copy", "Copy", () => void copy(inTextCitation(read(), style, where.value)))]),
      missing,
    ]);
    const preview = () => {
      const r = read();
      listOut.innerHTML = markdownToHtml(formatReference(r, style));
      textOut.textContent = inTextCitation(r, style, where.value).replace(/\*/g, "");
      const gaps = [!r.title && "title", !r.year && "date", !r.authors.length && r.kind !== "webpage" && "author", !r.url && !r.doi && r.kind !== "book" && "link"].filter(Boolean);
      missing.textContent = gaps.length
        ? `No ${gaps.join(" or ")} on the page${gaps.includes("date") ? ` — the reference says “${style === "apa" ? "n.d." : style === "harvard" ? "no date" : "n.d."}”, which is correct when a page has none` : ""}.`
        : !r.authors.length && r.kind === "webpage" && r.container
          ? `No person is named, so ${r.container} is credited as the author (the usual rule).`
          : "";
      addBtn.disabled = !r.title;
      citeBtn.disabled = !r.title || !target;
    };
    for (const el of [date, authors, title, container, publisher, volume, issue, pages, url, accessed, where]) el.addEventListener("input", preview);
    const copy = async (md: string) => {
      try {
        await navigator.clipboard.writeText(md.replace(/\*/g, "").replace(/\\([\\*_`[\]<>])/g, "$1"));
        this.toast("Copied");
      } catch {
        this.toast("Couldn't copy — select the text instead.");
      }
    };

    // ── lookup
    const lookup = async () => {
      const link = linkInput.value.trim();
      if (!link) {
        linkInput.focus();
        return;
      }
      lookBtn.disabled = true;
      status.className = "wr-ref-status wr-small";
      const say = (text: string) => status.replaceChildren(h("span", { class: "wr-spinner wr-spinner-small" }), text);
      say("Reading the page…");
      const steps = [
        setTimeout(() => say("Looking for the author and date…"), 3500),
        setTimeout(() => say("This site is slow or hides its details — opening it properly…"), 9000),
        setTimeout(() => say("Nearly there…"), 20000),
      ];
      try {
        const ai = this.host.settings().citeAi !== false;
        const r = await writerApi.cite(link, ai);
        const aiFields = r.aiFields ?? [];
        delete r.aiFields;
        delete r.via;
        fill({ ...r, accessed: accessed.value });
        markAi(aiFields);
        if (r.partial) {
          status.className = "wr-ref-status wr-small is-warn";
          status.textContent = `This site wouldn't open for Writer (${r.note ?? "blocked"}), so only the link was used. Fill in the author, date and title from the page.`;
        } else if (aiFields.length) {
          const names: Record<string, string> = { authors: "author", date: "date", title: "title", site: "website name" };
          status.className = "wr-ref-status wr-small is-ok";
          status.textContent = `Found it. Claude read the ${aiFields.map((f) => names[f] ?? f).join(" and ")} off the page (marked AI) — give ${aiFields.length > 1 ? "them" : "it"} a quick check.`;
        } else {
          status.className = "wr-ref-status wr-small is-ok";
          status.textContent = "Found it. Everything came from the page itself.";
        }
      } catch (err) {
        status.className = "wr-ref-status wr-small is-warn";
        status.textContent = `${err instanceof Error ? err.message : String(err)} You can type the details in instead.`;
        fill({ kind: "webpage", authors: [], title: "", url: /^https?:/i.test(link) ? link : undefined, accessed: accessed.value });
      } finally {
        steps.forEach(clearTimeout);
        lookBtn.disabled = false;
      }
    };
    lookBtn.addEventListener("click", () => void lookup());
    linkInput.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") void lookup();
      if (e.key === "Escape") this.closeModal();
    });
    linkInput.addEventListener("paste", () => setTimeout(() => { if (/^(https?:\/\/|doi:|10\.\d)/i.test(linkInput.value.trim())) void lookup(); }, 0));
    const manual = h("button", { class: "wr-link wr-small", text: "No link? Type the details in", on: { click: () => fill({ kind: "book", authors: [], title: "", accessed: accessed.value }) } });

    // ── saved references in this project
    const saved = h("div", { class: "wr-ref-saved" });
    const drawSaved = () => {
      const list = [...(p.settings.references ?? [])].sort((a, b) => sortKey(formatReference(a, style)).localeCompare(sortKey(formatReference(b, style))));
      if (!list.length) {
        saved.replaceChildren();
        return;
      }
      const rows = list.map((r) => {
        const entry = h("div", { class: "wr-ref-saved-text wr-prose" });
        entry.innerHTML = markdownToHtml(formatReference(r, style));
        return h("div", { class: "wr-ref-saved-row" }, [
          entry,
          h("div", { class: "wr-ref-saved-btns" }, [
            h("button", { class: "wr-btn wr-btn-small", text: "Cite", title: target ? `Insert ${inTextCitation(r, style).replace(/\*/g, "")} where you were typing` : "Click in your writing first", attrs: target ? {} : { disabled: "" }, on: { click: () => {
              this.closeModal();
              if (this.insertCitationAt(target, inTextCitation(r, style))) this.toast("Citation added");
            } } }),
            h("button", { class: "wr-btn wr-btn-small", text: "Edit", on: { click: () => { fill(r); linkInput.value = r.url ?? ""; } } }),
            iconBtn("close", "Forget this reference (it stays in your reference list)", () => {
              p.settings.references = (p.settings.references ?? []).filter((x) => x !== r);
              void writerApi.settings(p.id, { settings: { references: p.settings.references } }).catch(() => {});
              drawSaved();
            }),
          ]),
        ]);
      });
      saved.replaceChildren(
        h("div", { class: "wr-ref-saved-head" }, [
          h("strong", { text: `Your references (${list.length})` }),
          h("button", { class: "wr-link wr-small", text: `Rebuild reference list in ${CITE_STYLES.find((x) => x.id === style)?.name}`, on: { click: () => void rebuild(list) } }),
        ]),
        ...rows,
      );
    };
    const rebuild = async (list: Reference[]) => {
      const doc = this.findReferencesDoc();
      const ok = await this.confirm(
        "Rebuild the reference list?",
        `Every reference made here is rewritten in ${CITE_STYLES.find((x) => x.id === style)?.name}, A–Z${doc ? ` in “${doc.title}”` : ""}. Entries you typed in by hand are replaced too — a snapshot of the list is kept first.`,
        "Rebuild",
      );
      if (!ok) return this.openReferences();
      const target2 = doc ?? (await this.ensureReferencesDoc());
      if (!target2 || !this.project) return;
      await this.saveNow(target2.path).catch(() => {});
      await writerApi.snapshot(this.project.id, target2.path, "before rebuilding references").catch(() => {});
      const heading = (target2.body ?? "").split(/\n\s*\n/).filter((b) => /^#{1,6}\s/.test(b));
      let body = heading.join("\n\n");
      for (const r of list) body = addToReferenceList(body, formatReference(r, style)).body;
      const ed = this.editors.get(target2.path);
      if (ed && !ed.isDestroyed) ed.commands.setContent(body, { contentType: "markdown", emitUpdate: true });
      else {
        target2.body = body;
        this.scheduleSave(target2.path);
      }
      this.toast(`Reference list rebuilt in ${CITE_STYLES.find((x) => x.id === style)?.name}`);
    };

    // ── actions
    const add = async (cite: boolean) => {
      const r = read();
      if (!r.title) return;
      this.closeModal();
      const entry = formatReference(r, style);
      this.rememberReference(r);
      const { added, doc } = await this.addToReferences(entry);
      const cited = cite && this.insertCitationAt(target, inTextCitation(r, style, where.value));
      this.toast(
        `${added ? `Added to ${doc?.title ?? "References"}` : `Already in ${doc?.title ?? "References"}`}${cited ? " and cited in your text" : ""}`,
      );
      this.renderBinderList();
    };
    const addBtn = h("button", { class: "wr-btn", text: "Add to reference list", on: { click: () => void add(false) } });
    const citeBtn = h("button", { class: "wr-btn wr-btn-primary", text: "Add & cite here", title: target ? "Adds it to your reference list and puts the in-text citation where you were typing" : "Click in your writing first to cite there", on: { click: () => void add(true) } });

    drawStyles();
    drawSaved();
    syncKind();
    preview();
    this.openModal("Reference maker", [
      h("div", { class: "wr-ref-top" }, [linkInput, lookBtn]),
      h("div", { class: "wr-ref-meta" }, [styles, manual]),
      status,
      form,
      out,
      saved,
    ], [
      h("span", { class: "wr-faint wr-small wr-grow", text: this.findReferencesDoc() ? `Goes into “${this.findReferencesDoc()!.title}”, A–Z.` : "A References page is added to your Draft." }),
      addBtn,
      citeBtn,
    ], "wide");
    setTimeout(() => {
      linkInput.focus();
      if (prefill) void lookup();
    }, 30);
  }

  // ── Contents (headings) ──────────────────────────────────────────────────
  private contentsSig = "";
  private renderContents(): void {
    const box = this.root.querySelector<HTMLElement>("[data-contents]");
    if (!box || !this.project) return;
    type Entry = { level: number; text: string; editor: Editor; pos: number; doc?: string };
    const entries: Entry[] = [];
    const many = this.editors.size > 1;
    for (const [path, ed] of this.editors) {
      if (ed.isDestroyed) continue;
      if (many) entries.push({ level: 0, text: findNode(this.project.tree, path)?.title ?? path, editor: ed, pos: 0, doc: path });
      ed.state.doc.descendants((node, pos) => {
        if (node.type.name === "heading") entries.push({ level: Number(node.attrs.level) || 1, text: node.textContent, editor: ed, pos: pos + 1 });
        return node.isBlock && node.type.name !== "heading";
      });
    }
    const sig = entries.map((e) => `${e.level}:${e.text}:${e.pos}`).join("|");
    if (sig === this.contentsSig && box.childElementCount) return;
    this.contentsSig = sig;
    if (!entries.some((e) => e.level > 0)) {
      box.replaceChildren(
        h("p", { class: "wr-faint wr-small wr-pad-y", text: this.editors.size ? "Headings you add show up here, so you can jump around a long document. Type ## and a space to start one." : "Open a document to see its headings." }),
      );
      if (!many) return;
    } else box.replaceChildren();
    const minLevel = Math.min(...entries.filter((e) => e.level > 0).map((e) => e.level), 9);
    for (const e of entries) {
      box.append(
        h("button", {
          class: `wr-toc ${e.level === 0 ? "is-doc" : ""}`,
          attrs: { style: `--lvl:${e.level === 0 ? 0 : e.level - minLevel + (many ? 1 : 0)}` },
          text: e.text || "Untitled heading",
          on: {
            click: () => {
              if (e.editor.isDestroyed) return;
              e.editor.chain().focus().setTextSelection(e.pos).run();
              this.scrollToPos(e.editor, e.pos);
            },
          },
        }),
      );
    }
  }

  private scrollToPos(ed: Editor, pos: number): void {
    const scroll = this.els.scroll;
    if (!scroll || ed.isDestroyed) return;
    try {
      const c = ed.view.coordsAtPos(Math.min(pos, ed.state.doc.content.size));
      const r = scroll.getBoundingClientRect();
      if (c.top < r.top + 60 || c.bottom > r.bottom - 60) scroll.scrollBy({ top: c.top - (r.top + r.height * 0.35), behavior: "smooth" });
    } catch {}
  }

  private searchSnippet(body: string, q: string): string {
    const text = excerpt(body, 100000);
    const i = text.toLowerCase().indexOf(q);
    if (i === -1) return "";
    const start = Math.max(0, i - 24);
    return `${start ? "…" : ""}${text.slice(start, i + q.length + 40).trim()}…`;
  }

  // ── Atlantis: images and search across projects ─────────────────────────────
  /** Where pasted images go and where relative image links resolve from: the doc at `path`. */
  private pointImagesAt(path: string): void {
    const p = this.project;
    setImageTarget(p && this.dir ? { projectDir: `${this.dir}/${p.id}`, docFile: `${this.dir}/${p.id}/${path}` } : null);
  }

  private onImageError = (e: Event) => this.toast(new Error((e as CustomEvent<string>).detail));

  /** ⌘⇧F: find text in every project's documents (title and body). Swift reads the files on demand. */
  openSearchAll(): void {
    if (this.modal?.classList.contains("is-search-modal")) return void this.modal.querySelector<HTMLInputElement>(".wr-gsearch-input")?.select();
    const input = h("input", { class: "wr-input wr-palette-input wr-gsearch-input", attrs: { placeholder: "Search all projects…", "aria-label": "Search all projects", type: "search" } });
    const status = h("div", { class: "wr-gsearch-status wr-faint wr-small", attrs: { role: "status" } });
    const list = h("div", { class: "wr-palette-list wr-gsearch-list", attrs: { role: "listbox" } });
    let rows: Array<{ el: HTMLElement; open: () => void }> = [];
    let index = 0;
    let seq = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let dirty = false; // typed since the last search
    const mark = () => {
      rows.forEach((r, i) => {
        r.el.classList.toggle("is-active", i === index);
        r.el.setAttribute("aria-selected", String(i === index));
      });
      rows[index]?.el.scrollIntoView({ block: "nearest" });
    };
    const show = (query: string, result: SearchResult) => {
      list.replaceChildren();
      rows = [];
      index = 0;
      const groups = groupHits(result.hits, this.projects);
      status.textContent = !result.hits.length ? "No matches." : hitSummary(result, groups);
      for (const g of groups) list.append(...this.searchGroup(g, query, rows, () => this.closeModal()));
      mark();
    };
    const run = async () => {
      dirty = false;
      const query = input.value.trim();
      const mine = ++seq;
      if (!query) {
        list.replaceChildren();
        rows = [];
        status.textContent = "Searches titles and text in every project.";
        return;
      }
      try {
        await this.flushAll(); // so what you just typed is found too
        const result = await writerApi.search(query);
        if (mine === seq && this.modal?.contains(input)) show(query, result);
      } catch (err) {
        if (mine === seq) status.textContent = err instanceof Error ? err.message : String(err);
      }
    };
    input.addEventListener("input", () => {
      dirty = true;
      clearTimeout(timer);
      timer = setTimeout(() => void run(), 150); // runs only when you type; nothing in the background
    });
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (rows.length) index = (index + (e.key === "ArrowDown" ? 1 : -1) + rows.length) % rows.length;
        mark();
      } else if (e.key === "Enter") {
        e.preventDefault();
        if (dirty) {
          clearTimeout(timer);
          void run();
        } else rows[index]?.open();
      } else if (e.key === "Escape") this.closeModal();
      else if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.code === "KeyF") e.preventDefault();
    });
    status.textContent = "Searches titles and text in every project.";
    this.openModal("", [input, status, list], [], "search");
    this.modal?.classList.add("is-search-modal");
    setTimeout(() => input.focus(), 10);
  }

  private searchGroup(g: SearchGroup, query: string, rows: Array<{ el: HTMLElement; open: () => void }>, close: () => void): HTMLElement[] {
    const out: HTMLElement[] = [h("div", { class: "wr-palette-group", text: g.title })];
    for (const hit of g.hits) {
      const open = (snippet?: SearchSnippet) => {
        close();
        void this.openSearchHit(hit, query, snippet);
      };
      const el = h("button", { class: "wr-gsearch-hit", attrs: { role: "option", "aria-selected": "false" }, on: { click: () => open(hit.snippets[0]) } }, [
        h("span", { class: "wr-gsearch-title" }, [
          h("span", { class: "wr-palette-icon", icon: "docText" }),
          h("span", { class: "wr-menu-label" }, hit.titleMatches ? highlight(hit.title, query) : [hit.title]),
          h("span", { class: "wr-faint wr-small", text: hit.count > 1 ? `${hit.count} matches` : hit.folder }),
        ]),
        ...hit.snippets.map((s) =>
          h("span", { class: "wr-gsearch-snippet", on: { click: (ev) => { ev.stopPropagation(); open(s); } } }, [s.before, h("mark", { text: s.match }), s.after]),
        ),
      ]);
      el.addEventListener("mousemove", () => {
        const at = rows.findIndex((r) => r.el === el);
        if (at >= 0 && !el.classList.contains("is-active")) {
          rows.forEach((r) => r.el.classList.toggle("is-active", r.el === el));
        }
      });
      rows.push({ el, open: () => open(hit.snippets[0]) });
      out.push(el);
    }
    return out;
  }

  /** Opens the project and doc a search result is in and jumps to the match with the find bar. */
  private async openSearchHit(hit: SearchHit, query: string, snippet?: SearchSnippet): Promise<void> {
    if (this.project?.id !== hit.project) await this.openProject(hit.project);
    const p = this.project;
    if (!p || p.id !== hit.project) return;
    if (!findNode(p.tree, hit.relPath)) return this.toast(new Error("That document isn't in the project any more."));
    this.select(hit.relPath);
    if (this.viewFor(this.node) !== "doc") this.setView("doc");
    if (!hit.count || !snippet) return; // matched the title only
    this.openFind(false, query);
    this.find.index = snippet.occurrence;
    this.refreshFind(true);
  }

  // ── Find & replace ───────────────────────────────────────────────────────
  private openFind(replace = false, query?: string): void {
    if (this.viewFor(this.node) !== "doc") {
      const n = this.node;
      if (n && n.kind === "folder" && this.project) {
        this.prefs.views[`${this.project.id}:${n.path}`] = "doc";
        this.renderMain();
      }
    }
    const ed = this.activeEditor;
    if (query === undefined && ed && !ed.state.selection.empty) {
      const { from, to } = ed.state.selection;
      const sel = ed.state.doc.textBetween(from, to, " ");
      if (sel.length < 80 && !sel.includes("\n")) query = sel;
    }
    this.find.open = true;
    this.find.replace = this.find.replace || replace;
    if (query !== undefined) {
      this.find.query = query;
      this.find.index = 0;
    }
    this.renderFindBar();
    const input = this.root.querySelector<HTMLInputElement>(".wr-find-input");
    input?.focus();
    input?.select();
  }

  private closeFind(): void {
    this.find.open = false;
    this.root.querySelector(".wr-findbar")?.remove();
    for (const ed of this.editors.values()) if (!ed.isDestroyed) ed.view.dispatch(ed.state.tr.setMeta(findKey, { query: "" } as FindMeta));
    this.activeEditor?.commands.focus();
  }

  private renderFindBar(): void {
    const main = this.els.main;
    if (!main) return;
    main.querySelector(".wr-findbar")?.remove();
    const f = this.find;
    const input = h("input", { class: "wr-input wr-find-input", attrs: { placeholder: "Find in document", value: f.query, "aria-label": "Find" } });
    const count = h("span", { class: "wr-find-count wr-faint" });
    const replaceInput = h("input", { class: "wr-input wr-replace-input", attrs: { placeholder: "Replace with", "aria-label": "Replace with" } });
    const caseBtn = h("button", { class: `wr-icon-btn wr-find-case ${f.caseSensitive ? "is-on" : ""}`, text: "Aa", title: "Match case" });
    caseBtn.addEventListener("click", () => {
      f.caseSensitive = !f.caseSensitive;
      caseBtn.classList.toggle("is-on", f.caseSensitive);
      this.refreshFind(true);
    });
    input.addEventListener("input", () => {
      f.query = input.value;
      f.index = 0;
      this.refreshFind(true);
    });
    const keys = (e: KeyboardEvent) => {
      e.stopPropagation();
      if (e.key === "Escape") return this.closeFind();
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "f") {
        e.preventDefault();
        input.focus();
        input.select();
      }
    };
    input.addEventListener("keydown", (e) => {
      keys(e);
      if (e.key === "Enter") {
        e.preventDefault();
        this.stepFind(e.shiftKey ? -1 : 1);
      }
    });
    replaceInput.addEventListener("keydown", (e) => {
      keys(e);
      if (e.key === "Enter") {
        e.preventDefault();
        this.replaceCurrent(replaceInput.value);
      }
    });
    const toggle = h("button", { class: `wr-icon-btn wr-find-toggle ${f.replace ? "is-open" : ""}`, icon: "chevron", title: "Replace" });
    const bar = h("div", { class: `wr-findbar ${f.replace ? "has-replace" : ""}`, attrs: { role: "search" } }, [
      h("div", { class: "wr-find-row" }, [
        toggle,
        input,
        count,
        caseBtn,
        iconBtn("up", "Previous (⇧↵)", () => this.stepFind(-1)),
        iconBtn("down", "Next (↵)", () => this.stepFind(1)),
        iconBtn("close", "Close (Esc)", () => this.closeFind()),
      ]),
      h("div", { class: "wr-find-row wr-replace-row" }, [
        replaceInput,
        h("button", { class: "wr-btn wr-btn-small", text: "Replace", on: { click: () => this.replaceCurrent(replaceInput.value) } }),
        h("button", { class: "wr-btn wr-btn-small", text: "All", title: "Replace all", on: { click: () => this.replaceAll(replaceInput.value) } }),
      ]),
    ]);
    toggle.addEventListener("click", () => {
      f.replace = !f.replace;
      bar.classList.toggle("has-replace", f.replace);
      toggle.classList.toggle("is-open", f.replace);
      if (f.replace) replaceInput.focus();
    });
    main.append(bar);
    this.refreshFind(true);
  }

  /** Every match across the open editors, in reading order. */
  private findHits(): Array<{ editor: Editor; range: Range }> {
    const out: Array<{ editor: Editor; range: Range }> = [];
    for (const ed of this.editors.values()) {
      if (ed.isDestroyed) continue;
      for (const range of findKey.getState(ed.state)?.matches ?? []) out.push({ editor: ed, range });
    }
    return out;
  }

  private refreshFind(scroll: boolean): void {
    const f = this.find;
    for (const ed of this.editors.values()) if (!ed.isDestroyed) ed.view.dispatch(ed.state.tr.setMeta(findKey, { query: f.query, caseSensitive: f.caseSensitive, current: -1 } as FindMeta));
    const hits = this.findHits();
    if (f.index >= hits.length) f.index = 0;
    const cur = hits[f.index];
    if (cur) {
      let local = 0;
      for (const hit of hits.slice(0, f.index)) if (hit.editor === cur.editor) local++;
      cur.editor.view.dispatch(cur.editor.state.tr.setMeta(findKey, { current: local } as FindMeta));
      if (scroll) this.scrollToPos(cur.editor, cur.range.from);
    }
    const count = this.root.querySelector(".wr-find-count");
    if (count) count.textContent = !f.query ? "" : hits.length ? `${f.index + 1} of ${hits.length}` : "No results";
    this.root.querySelector(".wr-find-input")?.classList.toggle("is-miss", !!f.query && !hits.length);
  }

  private stepFind(dir: 1 | -1): void {
    const total = this.findHits().length;
    if (!total) return;
    this.find.index = (this.find.index + dir + total) % total;
    this.refreshFind(true);
  }

  private replaceCurrent(text: string): void {
    const hit = this.findHits()[this.find.index];
    if (!hit || !hit.editor.isEditable) return;
    hit.editor.view.dispatch(hit.editor.state.tr.insertText(text, hit.range.from, hit.range.to));
    this.refreshFind(true);
  }

  private replaceAll(text: string): void {
    let n = 0;
    for (const ed of this.editors.values()) {
      if (ed.isDestroyed || !ed.isEditable) continue;
      const matches = [...(findKey.getState(ed.state)?.matches ?? [])].reverse();
      if (!matches.length) continue;
      const tr = ed.state.tr;
      for (const m of matches) tr.insertText(text, m.from, m.to);
      ed.view.dispatch(tr);
      n += matches.length;
    }
    this.find.index = 0;
    this.refreshFind(false);
    this.toast(n ? `Replaced ${n} match${n === 1 ? "" : "es"}` : "Nothing to replace");
  }

  // ── Slash menu ───────────────────────────────────────────────────────────
  private onEditorKey(_path: string, view: EditorView, e: KeyboardEvent): boolean {
    const ed = this.activeEditor;
    if (this.mention) {
      const items = this.mentionItems();
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        this.mention.index = (this.mention.index + (e.key === "ArrowDown" ? 1 : -1) + items.length) % Math.max(1, items.length);
        this.drawMention();
        return true;
      }
      if ((e.key === "Enter" || e.key === "Tab") && items.length && !e.metaKey && !e.ctrlKey) {
        this.runMention(items[this.mention.index]);
        return true;
      }
      if (e.key === "Escape") {
        this.closeMention();
        return true;
      }
    }
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey && this.askChip && ed?.view === view) {
      void this.askBot();
      return true;
    }
    if (e.key === "@" && !e.metaKey && !e.ctrlKey && ed && ed.view === view) {
      const { $from, empty } = view.state.selection;
      if (empty && $from.parent.type.name !== "codeBlock") {
        const before = $from.parent.textBetween(0, $from.parentOffset, " ", " ");
        if (!before || /[\s(]$/.test(before)) {
          const from = $from.pos;
          setTimeout(() => void this.openMention(ed, from), 0);
        }
      }
    }
    if (this.slash) {
      const items = this.slashItems();
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        this.slash.index = (this.slash.index + (e.key === "ArrowDown" ? 1 : -1) + items.length) % Math.max(1, items.length);
        this.drawSlash();
        return true;
      }
      if ((e.key === "Enter" || e.key === "Tab") && items.length) {
        this.runSlash(items[this.slash.index]);
        return true;
      }
      if (e.key === "Escape") {
        this.closeSlash();
        return true;
      }
    }
    if (e.key === "/" && !e.metaKey && !e.ctrlKey && ed && ed.view === view) {
      const { $from, empty } = view.state.selection;
      if (!empty || $from.parent.type.name === "codeBlock") return false;
      const before = $from.parent.textBetween(0, $from.parentOffset, " ", " ");
      if (before && !/\s$/.test(before)) return false;
      const from = $from.pos;
      setTimeout(() => this.openSlash(ed, from), 0);
    }
    if (e.key === "Escape" && this.find.open) {
      this.closeFind();
      return true;
    }
    return false;
  }

  private slashItems() {
    if (!this.slash) return [];
    const { editor, from } = this.slash;
    const head = editor.state.selection.head;
    const q = editor.state.doc.textBetween(Math.min(from + 1, head), head, " ").toLowerCase().trim();
    if (!q) return SLASH_ITEMS;
    const rank = (i: (typeof SLASH_ITEMS)[number]) => {
      const l = i.label.toLowerCase();
      if (l.startsWith(q)) return 3;
      if (l.includes(q)) return 2;
      return i.keys.split(" ").some((k) => k.startsWith(q)) ? 1 : 0;
    };
    return SLASH_ITEMS.map((i) => ({ i, r: rank(i) })).filter((x) => x.r > 0).sort((a, b) => b.r - a.r).map((x) => x.i);
  }

  private openSlash(editor: Editor, from: number): void {
    if (editor.isDestroyed || editor.state.doc.textBetween(from, Math.min(from + 1, editor.state.doc.content.size), " ") !== "/") return;
    this.closeSlash();
    const el = h("div", { class: "wr-menu wr-slash", attrs: { role: "listbox", "aria-label": "Insert" } });
    this.root.append(el);
    this.slash = { editor, from, index: 0, el };
    this.drawSlash();
  }

  private drawSlash(): void {
    const s = this.slash;
    if (!s) return;
    const items = this.slashItems();
    if (s.index >= items.length) s.index = 0;
    s.el.replaceChildren(
      h("div", { class: "wr-slash-head wr-faint", text: items.length ? "Insert" : "No matches · Esc" }),
      ...items.map((item, i) =>
        h("button", {
          class: `wr-menu-item ${i === s.index ? "is-active" : ""}`,
          attrs: { role: "option", "aria-selected": String(i === s.index) },
          on: { mousedown: (e) => e.preventDefault(), click: () => this.runSlash(item) },
        }, [h("span", { class: "wr-menu-label", text: item.label }), h("span", { class: "wr-faint wr-kbd", text: item.hint })]),
      ),
    );
    try {
      const c = s.editor.view.coordsAtPos(s.from);
      const w = s.el.offsetWidth;
      const ht = s.el.offsetHeight;
      const below = c.bottom + 6 + ht < window.innerHeight;
      s.el.style.left = `${Math.min(c.left, window.innerWidth - w - 8)}px`;
      s.el.style.top = `${below ? c.bottom + 6 : c.top - ht - 6}px`;
    } catch {}
  }

  private updateSlash(): void {
    const s = this.slash;
    if (!s) return;
    const { state } = s.editor;
    const head = state.selection.head;
    const stillThere = s.from < state.doc.content.size && state.doc.textBetween(s.from, s.from + 1, " ") === "/";
    const q = stillThere && head > s.from ? state.doc.textBetween(s.from + 1, head, " ") : "";
    if (!stillThere || head <= s.from || q.length > 20 || /\s\s/.test(q) || state.doc.resolve(head).parent !== state.doc.resolve(s.from).parent) {
      this.closeSlash();
      return;
    }
    this.drawSlash();
  }

  private runSlash(item: (typeof SLASH_ITEMS)[number]): void {
    const s = this.slash;
    if (!s) return;
    this.closeSlash();
    const head = s.editor.state.selection.head;
    s.editor.chain().focus().deleteRange({ from: s.from, to: head }).run();
    if (item.id === "ref") this.openReferences();
    else item.run(s.editor);
  }

  private closeSlash(): void {
    this.slash?.el.remove();
    this.slash = null;
  }

  // ── @mentions (Atlantis M6) ──────────────────────────────────────────────
  /** Bots that can be @mentioned (names only), from Swift. Fresh each time the popup opens. */
  private loadMentionBots(fresh = false): Promise<void> {
    if (fresh || !this.mentionBotsLoad) {
      this.mentionBotsLoad = call<MentionBot[]>("agents.list")
        .then((bots) => {
          this.mentionBots = Array.isArray(bots) ? bots : [];
        })
        .catch(() => {
          this.mentionBots = [];
        });
    }
    return this.mentionBotsLoad;
  }

  private async openMention(editor: Editor, from: number): Promise<void> {
    await this.loadMentionBots(true);
    if (editor.isDestroyed || !this.mentionBots?.length) return;
    if (editor.state.doc.textBetween(from, Math.min(from + 1, editor.state.doc.content.size), " ") !== "@") return;
    this.closeMention();
    const el = h("div", { class: "wr-menu wr-slash wr-mention", attrs: { role: "listbox", "aria-label": "Mention a bot" } });
    this.root.append(el);
    this.mention = { editor, from, index: 0, el };
    this.hideAskChip();
    this.updateMention();
  }

  private mentionQueryText(): string | null {
    const m = this.mention;
    if (!m) return null;
    const { state } = m.editor;
    const head = state.selection.head;
    if (head <= m.from || m.from >= state.doc.content.size) return null;
    if (state.doc.textBetween(m.from, m.from + 1, " ") !== "@") return null;
    if (state.doc.resolve(head).parent !== state.doc.resolve(m.from).parent) return null;
    return mentionQuery(state.doc.textBetween(m.from, head, " "));
  }

  private mentionItems(): MentionBot[] {
    const q = this.mentionQueryText();
    return q === null ? [] : filterBots(this.mentionBots ?? [], q);
  }

  private updateMention(): void {
    if (!this.mention) return;
    if (this.mentionQueryText() === null || !this.mentionItems().length) return this.closeMention();
    this.drawMention();
  }

  private drawMention(): void {
    const m = this.mention;
    if (!m) return;
    const items = this.mentionItems();
    if (m.index >= items.length) m.index = 0;
    m.el.replaceChildren(
      h("div", { class: "wr-slash-head wr-faint", text: "Ask a bot" }),
      ...items.map((bot, i) =>
        h("button", {
          class: `wr-menu-item ${i === m.index ? "is-active" : ""}`,
          attrs: { role: "option", "aria-selected": String(i === m.index) },
          on: { mousedown: (e) => e.preventDefault(), click: () => this.runMention(bot) },
        }, [h("span", { class: "wr-menu-check", text: bot.avatar }), h("span", { class: "wr-menu-label", text: bot.name }), h("span", { class: "wr-faint wr-kbd", text: `@${bot.id}` })]),
      ),
    );
    try {
      const c = m.editor.view.coordsAtPos(m.from);
      const w = m.el.offsetWidth;
      const ht = m.el.offsetHeight;
      const below = c.bottom + 6 + ht < window.innerHeight;
      m.el.style.left = `${Math.min(c.left, window.innerWidth - w - 8)}px`;
      m.el.style.top = `${below ? c.bottom + 6 : c.top - ht - 6}px`;
    } catch {}
  }

  /** Writes `@<id> ` in place of what was typed; the request follows as plain text. */
  private runMention(bot: MentionBot): void {
    const m = this.mention;
    if (!m) return;
    this.closeMention();
    const head = m.editor.state.selection.head;
    m.editor.chain().focus().insertContentAt({ from: m.from, to: head }, `@${bot.id} `).run();
  }

  private closeMention(): void {
    this.mention?.el.remove();
    this.mention = null;
  }

  /** Shows "Ask School ⌘↩" at the end of a paragraph holding `@school <request>`. */
  private updateAskChip(): void {
    const ed = this.activeEditor;
    if (!ed || ed.isDestroyed || !ed.isFocused || !ed.isEditable || this.mention || this.slash) return this.hideAskChip();
    const { $from } = ed.state.selection;
    const text = $from.parent.textContent;
    if ($from.parent.type.name === "codeBlock" || !text.includes("@")) return this.hideAskChip();
    if (this.mentionBots === null) {
      void this.loadMentionBots().then(() => this.updateAskChip());
      return;
    }
    const bots = this.mentionBots;
    const req = findMention(text, bots.map((b) => b.id));
    const bot = req && bots.find((b) => b.id === req.bot);
    if (!req || !bot) return this.hideAskChip();
    let el = this.askChip?.el;
    if (!el) {
      el = h("button", {
        class: "wr-ask-chip",
        attrs: { type: "button", title: "Send this request and the doc to the bot. Its answer goes to your Inbox." },
        on: { mousedown: (e) => e.preventDefault(), click: () => void this.askBot() },
      });
      this.root.append(el);
    }
    this.askChip = { el, editor: ed, req };
    el.replaceChildren(
      h("span", { text: this.asking ? `Asking ${bot.name}…` : `${bot.avatar} Ask ${bot.name}` }),
      h("span", { class: "wr-faint wr-kbd", text: "⌘↩" }),
    );
    el.toggleAttribute("disabled", this.asking);
    try {
      const c = ed.view.coordsAtPos($from.end());
      const w = el.offsetWidth;
      el.style.left = `${Math.max(8, Math.min(c.right + 10, window.innerWidth - w - 8))}px`;
      el.style.top = `${c.top - 3}px`;
    } catch {}
  }

  private hideAskChip(): void {
    this.askChip?.el.remove();
    this.askChip = null;
  }

  /** Saves the doc, then sends the request (Swift reads the saved doc and checks the path). */
  private async askBot(): Promise<void> {
    const chip = this.askChip;
    const p = this.project;
    if (!chip || !p || this.asking) return;
    const path = [...this.editors].find(([, ed]) => ed === chip.editor)?.[0];
    if (!path) return;
    this.asking = true;
    this.updateAskChip();
    try {
      await this.saveNow(path);
      const r = await call<{ message?: string }>("agents.ask", { bot: chip.req.bot, path: `${this.dir}/${p.id}/${path}`, request: chip.req.request });
      this.toast(r?.message ?? "Asked. The answer will land in your Inbox.");
    } catch (err) {
      this.toast(err instanceof Error ? err : new Error(String(err)));
    } finally {
      this.asking = false;
      this.updateAskChip();
    }
  }

  // ── Selection toolbar ────────────────────────────────────────────────────
  private updateBubble(): void {
    const ed = this.activeEditor;
    const sel = ed && !ed.isDestroyed ? ed.state.selection : null;
    const show = !!ed && !!sel && !sel.empty && ed.isFocused && ed.isEditable && !ed.isActive("codeBlock") && !("node" in sel && (sel as { node?: unknown }).node) && !this.slash;
    if (!show) return this.hideBubble();
    if (!this.bubble) {
      const b = (icon: IconName, title: string, fn: (e: Editor) => void, mark?: string) => {
        const btn = iconBtn(icon, title, () => {
          const e = this.activeEditor;
          if (e && !e.isDestroyed) fn(e);
          this.updateBubble();
        }, "wr-fmt");
        btn.addEventListener("mousedown", (e) => e.preventDefault());
        if (mark) btn.dataset.mark = mark;
        return btn;
      };
      this.bubble = h("div", { class: "wr-bubble", attrs: { role: "toolbar", "aria-label": "Format selection" } }, [
        b("bold", "Bold (⌘B)", (e) => e.chain().focus().toggleBold().run(), "bold"),
        b("italic", "Italic (⌘I)", (e) => e.chain().focus().toggleItalic().run(), "italic"),
        b("highlight", "Highlight (⌘⇧H)", (e) => e.chain().focus().toggleHighlight().run(), "highlight"),
        b("link", "Link (⌘K)", (e) => void this.editLink(e), "link"),
        h("span", { class: "wr-sep" }),
        b("comment", "Comment (⌥⌘M)", () => this.addComment()),
        b("cite", "Make a reference from this link", (e) => this.openReferences(String(e.getAttributes("link").href ?? "")), "link"),
        b("find", "Find this (⌘F)", () => this.openFind(false)),
      ]);
      this.root.append(this.bubble);
    }
    const bubble = this.bubble;
    bubble.querySelectorAll<HTMLElement>("[data-mark]").forEach((x) => x.classList.toggle("is-on", ed!.isActive(x.dataset.mark!)));
    try {
      const a = ed!.view.coordsAtPos(sel!.from);
      const z = ed!.view.coordsAtPos(sel!.to);
      const w = bubble.offsetWidth;
      const mid = a.top === z.top ? (a.left + z.left) / 2 : a.left + 40;
      const top = a.top - bubble.offsetHeight - 8;
      bubble.style.left = `${Math.max(8, Math.min(mid - w / 2, window.innerWidth - w - 8))}px`;
      bubble.style.top = `${top < 8 ? z.bottom + 8 : top}px`;
      bubble.classList.add("is-on");
    } catch {
      this.hideBubble();
    }
  }

  private hideBubble(): void {
    this.bubble?.classList.remove("is-on");
  }

  // ── Spelling & grammar (Grammarly-style) ───────────────────────────────────
  /** Editors whose paragraphs get checked (not the References doc, not Trash). */
  private proofEditors(): Editor[] {
    if (!this.prefs.proof || !this.project) return [];
    const out: Editor[] = [];
    for (const [path, ed] of this.editors) {
      const n = findNode(this.project.tree, path);
      if (!ed.isDestroyed && ed.isEditable && n && !isRefList(n)) out.push(ed);
    }
    return out;
  }

  private proofTimer: ReturnType<typeof setTimeout> | null = null;
  /** Queue changed paragraphs for a check (cheap; the Proofreader waits for a pause). */
  private proofSoon(now = false): void {
    if (!this.prefs.proof) return;
    if (this.proofTimer) clearTimeout(this.proofTimer);
    this.proofTimer = setTimeout(() => {
      this.proofTimer = null;
      const eds = this.proofEditors();
      const ed = this.activeEditor;
      let typing: string | null = null;
      if (ed && !ed.isDestroyed && ed.isFocused) {
        const head = ed.state.selection.head;
        typing = proofBlocks(ed.state.doc).find((b) => b.start < head && head <= b.start + b.node.nodeSize)?.text ?? null;
      }
      this.proof.scan(eds.map((e) => e.state.doc), typing, now);
    }, now ? 0 : 150);
  }

  private onProof(what: "issues" | "status"): void {
    if (what === "issues") for (const ed of this.editors.values()) if (!ed.isDestroyed) ed.view.dispatch(ed.state.tr.setMeta(proofKey, true));
    this.updateProofChip();
    if (this.menu?.classList.contains("wr-pf-panel")) this.drawProofPanel?.();
  }

  private proofHits(): Array<{ ed: Editor; hit: ProofHit }> {
    const out: Array<{ ed: Editor; hit: ProofHit }> = [];
    for (const ed of this.proofEditors()) for (const hit of hitsIn(ed.view)) out.push({ ed, hit });
    return out;
  }

  private updateProofChip(): void {
    const chip = this.root.querySelector<HTMLElement>("[data-proof-chip]");
    if (!chip) return;
    const st = this.proof.status;
    const n = this.prefs.proof ? this.proofHits().length : 0;
    let text: string;
    let cls = "";
    let title = "Spelling & grammar suggestions";
    if (!this.prefs.proof) {
      text = "Checks off";
      cls = "is-off";
    } else if (st === "error") {
      text = "Checks paused";
      cls = "is-error";
      title = `${this.proof.error} Writer will try again in a minute.`;
    } else if (st === "checking" || st === "waiting") {
      text = n ? `${n} · checking…` : "Checking…";
      cls = "is-busy";
    } else {
      text = n ? `${n} suggestion${n === 1 ? "" : "s"}` : "No issues";
      cls = n ? "has-issues" : "is-clear";
    }
    chip.className = `wr-pf-chip ${cls}`;
    chip.title = title;
    chip.textContent = text;
  }

  private toggleProof(on = !this.prefs.proof): void {
    this.prefs.proof = on;
    this.savePrefs();
    if (!on) this.proof.stop();
    for (const ed of this.editors.values()) {
      if (ed.isDestroyed) continue;
      ed.view.dom.setAttribute("spellcheck", on ? "false" : "true");
      ed.view.dispatch(ed.state.tr.setMeta(proofKey, true));
    }
    this.proofSoon(true);
    this.updateProofChip();
  }

  /** Replace the flagged text with Claude's fix (keeps formatting, and the rest of the paragraph's marks). */
  private acceptProof(ed: Editor, hit: ProofHit): boolean {
    if (hit.fix === null || ed.isDestroyed) return false;
    if (ed.state.doc.textBetween(hit.from, hit.to, " ", " ") !== hit.quote) {
      this.toast("That text has changed since it was checked.");
      return false;
    }
    this.proof.accepted(hit.text, hit);
    ed.view.dispatch(ed.state.tr.insertText(hit.fix, hit.from, hit.to));
    return true;
  }

  private proofCardBody(ed: Editor, hit: ProofHit, after: () => void): HTMLElement {
    const soft = isSoft(hit.kind);
    const fixBtn = hit.fix !== null
      ? h("button", {
          class: `wr-pf-fixbtn ${soft ? "is-long" : ""}`,
          title: "Use this",
          on: { click: () => { this.acceptProof(ed, hit); after(); } },
        }, [hit.fix === "" ? h("em", { text: "(remove it)" }) : hit.fix])
      : null;
    return h("div", { class: "wr-pf-body" }, [
      h("div", { class: "wr-pf-kind" }, [h("span", { class: `wr-pf-dot ${soft ? "is-soft" : ""}` }), h("span", { text: KIND_LABEL[hit.kind] })]),
      soft || !fixBtn
        ? h("p", { class: "wr-pf-note", text: hit.note })
        : h("div", { class: "wr-pf-swap" }, [h("s", { class: "wr-pf-old", text: hit.quote }), h("span", { class: "wr-faint", text: "→" }), fixBtn]),
      soft && fixBtn ? h("div", { class: "wr-pf-try" }, [h("span", { class: "wr-faint wr-small", text: "Try:" }), fixBtn]) : null,
      !soft && fixBtn && hit.note ? h("p", { class: "wr-pf-note wr-muted", text: hit.note }) : null,
      (() => {
        const pv = previewParts(hit.text, hit);
        if (!pv || !pv.parts.some((p) => p.kind === "add")) return null;
        return h("p", { class: "wr-pf-preview", title: "How it will read" }, [
          pv.lead ? "…" : null,
          ...pv.parts.map((p) => (p.kind === "add" ? h("span", { class: "wr-pf-add", text: p.text }) : p.text)),
          pv.tail ? "…" : null,
        ]);
      })(),
      h("div", { class: "wr-pf-acts" }, [
        h("button", { class: "wr-link wr-small", text: "Dismiss", on: { click: () => { this.proof.dismiss(hit); after(); } } }),
        hit.kind === "spelling" && !/\s/.test(hit.quote.trim())
          ? h("button", { class: "wr-link wr-small", text: "Add to dictionary", on: { click: () => { this.proof.addToDictionary(hit.quote); after(); } } })
          : null,
      ]),
    ]);
  }

  private openProofCard(ed: Editor, hit: ProofHit): void {
    this.closeMenu();
    const card = h("div", { class: "wr-menu wr-pf-card", attrs: { role: "dialog", "aria-label": `${KIND_LABEL[hit.kind]} suggestion` } });
    card.append(this.proofCardBody(ed, hit, () => { this.closeMenu(); if (!ed.isDestroyed) ed.commands.focus(); }));
    this.root.append(card);
    try {
      const a = ed.view.coordsAtPos(hit.from);
      const w = card.offsetWidth;
      const below = a.bottom + 8;
      card.style.left = `${Math.max(8, Math.min(a.left - 12, window.innerWidth - w - 8))}px`;
      card.style.top = `${below + card.offsetHeight > window.innerHeight - 8 ? Math.max(8, a.top - card.offsetHeight - 8) : below}px`;
    } catch {}
    this.menu = card;
    (card.querySelector(".wr-pf-fixbtn") as HTMLElement | null)?.focus();
  }

  private drawProofPanel: (() => void) | null = null;

  private openProofPanel(e: MouseEvent): void {
    const anchor = e.currentTarget as HTMLElement;
    this.closeMenu();
    const panel = h("div", { class: "wr-menu wr-pf-panel", attrs: { role: "dialog", "aria-label": "Spelling & grammar" } });
    const place = () => {
      const r = anchor.getBoundingClientRect();
      panel.style.left = `${Math.max(8, Math.min(r.left + r.width / 2 - panel.offsetWidth / 2, window.innerWidth - panel.offsetWidth - 8))}px`;
      panel.style.top = `${Math.max(8, r.top - panel.offsetHeight - 8)}px`;
    };
    const draw = () => {
      if (!panel.isConnected && this.menu !== panel) return;
      const hits = this.prefs.proof ? this.proofHits() : [];
      const st = this.proof.status;
      const fixes = hits.filter(({ hit }) => !isSoft(hit.kind));
      const status = !this.prefs.proof
        ? "Checks are off."
        : st === "error"
          ? `Paused: ${this.proof.error}`
          : st === "checking" || st === "waiting"
            ? `Checking ${this.proof.pending || ""} paragraph${this.proof.pending === 1 ? "" : "s"}…`.replace("  ", " ")
            : hits.length
              ? `${fixes.length} to fix · ${hits.length - fixes.length} to improve`
              : "Nothing to fix. Nice.";
      const toggle = h("input", { attrs: { type: "checkbox" } });
      toggle.checked = this.prefs.proof;
      toggle.addEventListener("change", () => { this.toggleProof(toggle.checked); draw(); });
      const list = h("div", { class: "wr-pf-list" });
      for (const { ed, hit } of hits.slice(0, 80)) {
        const row = h("div", { class: "wr-pf-row", attrs: { tabindex: "0" } }, [this.proofCardBody(ed, hit, draw)]);
        row.addEventListener("click", (ev) => {
          if ((ev.target as HTMLElement).closest("button")) return;
          ed.chain().focus().setTextSelection(hit.from).scrollIntoView().run();
          setTimeout(() => this.openProofCard(ed, { ...hit }), 60);
        });
        list.append(row);
      }
      const spelling = hits.filter(({ hit }) => (hit.kind === "spelling" || hit.kind === "punctuation") && hit.fix !== null);
      panel.replaceChildren(
        ...([
        h("div", { class: "wr-pf-head" }, [
          h("strong", { text: "Spelling & grammar" }),
          h("label", { class: "wr-check wr-small" }, [toggle, h("span", { text: "Check as I write" })]),
        ]),
        h("p", { class: `wr-small ${st === "error" ? "wr-error" : "wr-muted"}`, text: status }),
        hits.length ? list : null,
        h("div", { class: "wr-pf-foot" }, [
          spelling.length > 1
            ? h("button", {
                class: "wr-btn wr-btn-primary wr-small",
                text: `Fix ${spelling.length} spelling & punctuation`,
                on: {
                  click: () => {
                    // Back to front so earlier positions stay valid.
                    for (const { ed, hit } of [...spelling].sort((a, b) => b.hit.from - a.hit.from)) this.acceptProof(ed, hit);
                    draw();
                  },
                },
              })
            : null,
          this.prefs.proof
            ? h("button", {
                class: "wr-btn wr-small",
                text: "Check again",
                title: "Forget the results for what's open and check it fresh",
                on: {
                  click: () => {
                    this.proof.forget(this.proofEditors().flatMap((ed) => proofBlocks(ed.state.doc).map((b) => b.text)));
                    this.onProof("issues");
                    this.proofSoon(true);
                    draw();
                  },
                },
              })
            : null,
        ]),
        h("p", { class: "wr-faint wr-small wr-pf-fine", text: "Checked by Claude Haiku on your Claude account, so it's free. Only paragraphs you change are sent, after you pause." }),
        ] as Child[]).filter((c): c is HTMLElement => !!c),
      );
      place();
    };
    this.drawProofPanel = draw;
    this.root.append(panel);
    this.menu = panel;
    draw();
  }

  // ── Palette (⌘O) & shortcuts (⌘/) ─────────────────────────────────────────
  private openPalette(): void {
    const p = this.project;
    if (!p) return;
    type Entry = { label: string; sub: string; icon: IconName; run: () => void; kind: "doc" | "cmd" };
    const docs: Entry[] = [];
    walk(p.tree, (n, _d, parent) => {
      if (n.role || isInTrash(p.tree, n.path)) return;
      docs.push({ label: n.title, sub: parent?.title ?? "", icon: nodeIcon(n), kind: "doc", run: () => this.select(n.path) });
    });
    const cmds: Entry[] = [
      { label: "New document", sub: "⌥⌘N", icon: "plus", kind: "cmd", run: () => void this.addItem("doc") },
      { label: "Find in document", sub: "⌘F", icon: "find", kind: "cmd", run: () => this.openFind(false) },
      { label: "Find and replace", sub: "⌥⌘F", icon: "find", kind: "cmd", run: () => this.openFind(true) },
      { label: "Export…", sub: "⌘⇧E", icon: "export", kind: "cmd", run: () => this.openExport() },
      { label: "Search all projects", sub: "⌘⇧F", icon: "find", kind: "cmd", run: () => this.openSearchAll() },
      { label: "Focus mode", sub: "⌘⇧D", icon: "compose", kind: "cmd", run: () => this.toggleCompose() },
      { label: "Make a reference from a link", sub: "⌥⌘R", icon: "cite", kind: "cmd", run: () => this.openReferences() },
      { label: "Comment on selection", sub: "⌥⌘M", icon: "comment", kind: "cmd", run: () => this.addComment() },
      { label: "Note to self (not exported)", sub: "⌥⌘J", icon: "note", kind: "cmd", run: () => this.addNote() },
      { label: "Writing record", icon: "record", kind: "cmd", run: () => void this.openRecord() },
      { label: this.prefs.review ? "Stop highlighting long sentences & filler" : "Check writing: long sentences & filler words", sub: "", icon: "sparkle", kind: "cmd", run: () => this.toggleReview() },
      { label: "Spelling & grammar suggestions", sub: "", icon: "check", kind: "cmd", run: () => (this.root.querySelector("[data-proof-chip]") as HTMLElement | null)?.click() },
      { label: this.prefs.proof ? "Turn off spelling & grammar checks" : "Turn on spelling & grammar checks", sub: "", icon: "check", kind: "cmd", run: () => this.toggleProof() },
      { label: "Writing stats", sub: "", icon: "info", kind: "cmd", run: () => (this.root.querySelector(".wr-words") as HTMLElement | null)?.click() },
      { label: "Take snapshot", sub: "", icon: "snapshot", kind: "cmd", run: () => { const n = this.node; if (n?.kind === "doc") void this.takeSnapshot(n); } },
      { label: "Write view", sub: "⌃1", icon: "page", kind: "cmd", run: () => this.setView("doc") },
      { label: "Cards view", sub: "⌃2", icon: "cork", kind: "cmd", run: () => this.setView("cork") },
      { label: "Outline view", sub: "⌃3", icon: "outline", kind: "cmd", run: () => this.setView("outline") },
      { label: "Show/hide binder", sub: "⌥⌘1", icon: "binder", kind: "cmd", run: () => this.togglePanel("binder") },
      { label: "Show/hide inspector", sub: "⌥⌘I", icon: "inspector", kind: "cmd", run: () => this.togglePanel("inspector") },
      { label: "Project settings & targets", sub: "", icon: "info", kind: "cmd", run: () => this.openProjectSettings() },
      { label: "Import a file", sub: ".docx .md .rtf", icon: "import", kind: "cmd", run: () => this.importFile() },
      { label: "Keyboard shortcuts", sub: "⌘/", icon: "keyboard", kind: "cmd", run: () => this.openShortcuts() },
      { label: "All projects", sub: "", icon: "back", kind: "cmd", run: () => void this.goHome() },
    ];
    const score = (text: string, q: string): number => {
      const t = text.toLowerCase();
      if (!q) return 1;
      const i = t.indexOf(q);
      if (i === 0) return 100;
      if (i > 0) return 80 - Math.min(i, 40);
      let at = 0;
      for (const ch of q) {
        at = t.indexOf(ch, at);
        if (at === -1) return 0;
        at++;
      }
      return 20;
    };
    const input = h("input", { class: "wr-input wr-palette-input", attrs: { placeholder: "Go to a document or run a command…", "aria-label": "Search" } });
    const list = h("div", { class: "wr-palette-list", attrs: { role: "listbox" } });
    let shown: Entry[] = [];
    let index = 0;
    const draw = () => {
      const q = input.value.trim().toLowerCase();
      const rank = (es: Entry[]) => es.map((e) => ({ e, s: score(e.label, q) })).filter((x) => x.s > 0).sort((a, b) => b.s - a.s).map((x) => x.e);
      const d = rank(docs).slice(0, q ? 8 : 6);
      const c = rank(cmds).slice(0, q ? 8 : 15);
      shown = [...d, ...c];
      if (index >= shown.length) index = 0;
      list.replaceChildren();
      const group = (title: string, es: Entry[], offset: number) => {
        if (!es.length) return;
        list.append(h("div", { class: "wr-palette-group", text: title }));
        es.forEach((e, i) => {
          const at = offset + i;
          list.append(
            h("button", {
              class: `wr-palette-item ${at === index ? "is-active" : ""}`,
              attrs: { role: "option", "aria-selected": String(at === index) },
              on: { click: () => { this.closeModal(); e.run(); }, mousemove: () => { if (index !== at) { index = at; draw(); } } },
            }, [h("span", { class: "wr-palette-icon", icon: e.icon }), h("span", { class: "wr-menu-label", text: e.label }), h("span", { class: "wr-faint wr-kbd", text: e.sub })]),
          );
        });
      };
      group("Documents", d, 0);
      group("Commands", c, d.length);
      if (!shown.length) list.append(h("p", { class: "wr-faint wr-pad", text: "Nothing matches." }));
      list.querySelector(".is-active")?.scrollIntoView({ block: "nearest" });
    };
    input.addEventListener("input", () => { index = 0; draw(); });
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        index = (index + (e.key === "ArrowDown" ? 1 : -1) + shown.length) % Math.max(1, shown.length);
        draw();
      } else if (e.key === "Enter" && shown[index]) {
        e.preventDefault();
        const run = shown[index].run;
        this.closeModal();
        run();
      } else if (e.key === "Escape") this.closeModal();
    });
    this.openModal("", [input, list], [], "palette");
    draw();
    setTimeout(() => input.focus(), 10);
  }

  private openShortcuts(): void {
    const groups: Array<[string, Array<[string, string]>]> = [
      ["Writing", [["Bold · Italic", "⌘B · ⌘I"], ["Highlight", "⌘⇧H"], ["Link", "⌘K"], ["Comment on selection", "⌥⌘M"], ["Note to self (not exported)", "⌥⌘J or /note"], ["Reference from a link", "⌥⌘R or /ref"], ["Insert anything", "/ on a new line"], ["Heading", "## then space"], ["Bulleted · numbered list", "- · 1. then space"], ["Checklist", "[ ] then space"], ["Quote", "> then space"], ["Undo · Redo", "⌘Z · ⇧⌘Z"]]],
      ["Finding", [["Go to anything", "⌘O"], ["Find", "⌘F"], ["Find and replace", "⌥⌘F"], ["Next · previous match", "↵ · ⇧↵"], ["Search the project", "⌘⇧O"], ["Search all projects", "⌘⇧F"]]],
      ["Project", [["New document", "⌥⌘N"], ["Write · Cards · Outline", "⌃1 · ⌃2 · ⌃3"], ["Back · Forward", "⌘[ · ⌘]"], ["Binder · Inspector", "⌥⌘1 · ⌥⌘I"], ["Focus mode", "⌘⇧D"], ["Export", "⌘⇧E"], ["Save now", "⌘S"], ["Rename in binder", "↵"]]],
    ];
    this.openModal("Keyboard shortcuts", [
      h("div", { class: "wr-keys" }, groups.map(([title, rows]) =>
        h("section", {}, [
          h("h3", { text: title }),
          ...rows.map(([label, keys]) => h("div", { class: "wr-key-row" }, [h("span", { text: label }), h("kbd", { text: keys })])),
        ]),
      )),
    ], [h("button", { class: "wr-btn wr-btn-primary", text: "Done", on: { click: () => this.closeModal() } })], "wide");
  }

  // ── Keys ─────────────────────────────────────────────────────────────────
  private onKey(e: KeyboardEvent): void {
    const mod = e.metaKey || e.ctrlKey;
    if (e.key === "Escape") {
      if (this.menu) return this.closeMenu();
      if (this.modal) return this.closeModal();
      if (this.find.open) return this.closeFind();
      if (this.root.classList.contains("is-compose")) return this.toggleCompose();
      if (this.root.matches(".drawer-binder, .drawer-inspector")) return this.root.classList.remove("drawer-binder", "drawer-inspector");
    }
    const k = e.key.toLowerCase();
    const run = (fn: () => void) => {
      e.preventDefault();
      e.stopPropagation();
      fn();
    };
    // Atlantis: search across all projects (⌘⇧F), also from the project list; Focus mode moved to ⌘⇧D.
    if (mod && e.shiftKey && !e.altKey && e.code === "KeyF") return run(() => this.openSearchAll());
    if (!this.project) return;
    if (mod && !e.altKey && !e.shiftKey && k === "f") return run(() => this.openFind(false));
    if (mod && e.altKey && e.code === "KeyF") return run(() => this.openFind(true));
    if (mod && e.shiftKey && !e.altKey && e.code === "KeyD") return run(() => this.toggleCompose());
    if (mod && !e.shiftKey && k === "o") return run(() => this.openPalette());
    if (mod && e.shiftKey && e.code === "KeyO") return run(() => this.focusSearch());
    if (mod && e.shiftKey && e.code === "KeyP") return run(() => this.openPalette());
    if (mod && (k === "/" || e.code === "Slash")) return run(() => this.openShortcuts());
    if (mod && e.shiftKey && e.code === "KeyE") return run(() => this.openExport());
    if (mod && e.altKey && e.code === "KeyM") return run(() => this.addComment());
    if (mod && e.altKey && e.code === "KeyJ") return run(() => this.addNote());
    if (mod && e.altKey && e.code === "KeyR") return run(() => this.openReferences());
    if (e.ctrlKey && !e.metaKey && !e.altKey && ["1", "2", "3"].includes(e.key)) return run(() => this.setView((["doc", "cork", "outline"] as const)[Number(e.key) - 1]));
    if (mod && e.altKey && e.code === "Digit1") return run(() => this.togglePanel("binder"));
    if (mod && e.altKey && e.code === "KeyI") return run(() => this.togglePanel("inspector"));
    if (mod && e.key === "[") return run(() => this.goBack());
    if (mod && e.key === "]") return run(() => this.goForward());
    if (mod && !e.shiftKey && k === "k" && this.activeEditor && (e.target as HTMLElement).closest?.(".ProseMirror")) return run(() => void this.editLink(this.activeEditor!));
    if (mod && e.key.toLowerCase() === "s") {
      e.preventDefault();
      void this.flushAll().then(() => this.toast("Saved"));
      return;
    }
    if (mod && e.altKey && e.code === "KeyN") {
      e.preventDefault();
      void this.addItem("doc");
      return;
    }
    if (mod && e.shiftKey && e.code === "KeyH") {
      e.preventDefault();
      this.activeEditor?.chain().focus().toggleHighlight().run();
      return;
    }
    // Arrow keys move through the binder when it has focus.
    const row = (e.target as HTMLElement).closest?.(".wr-row") as HTMLElement | null;
    if (row && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
      e.preventDefault();
      const rows = [...this.root.querySelectorAll<HTMLElement>(".wr-tree .wr-row")];
      const i = rows.indexOf(row);
      const next = rows[e.key === "ArrowDown" ? i + 1 : i - 1];
      if (next?.dataset.path) {
        this.select(next.dataset.path);
        (this.root.querySelector(`.wr-row[data-path="${CSS.escape(next.dataset.path)}"]`) as HTMLElement | null)?.focus();
      }
    } else if (row && e.key === "Enter" && !e.repeat) {
      const n = this.project && findNode(this.project.tree, row.dataset.path ?? "");
      if (n && !n.role) {
        e.preventDefault();
        this.startRename(row, n);
      }
    }
  }
}

type MenuItem =
  | { label: string; run: () => void; danger?: boolean; disabled?: boolean; checked?: boolean; hint?: string }
  | "-";
