import { Extension } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet, type EditorView } from "@tiptap/pm/view";
import type { Node as PMNode } from "@tiptap/pm/model";
import { diffWords, type DiffPart } from "./stats";

/**
 * Spelling & grammar checks, Grammarly-style. Paragraphs you've changed go (in small batches,
 * after you pause) to seqta-mcp's `writer.proofread`, which asks Claude Haiku on your own Claude
 * login. Results are cached by paragraph text — in memory and in localStorage — so a paragraph is
 * only ever sent again after it changes. Editing a paragraph hides its marks until it's re-checked.
 */

export type ProofKind = "spelling" | "grammar" | "punctuation" | "word" | "clarity" | "flow";
export type ProofIssue = { kind: ProofKind; quote: string; fix: string | null; note: string };
export type ProofHit = ProofIssue & { from: number; to: number; text: string };

export const KIND_LABEL: Record<ProofKind, string> = {
  spelling: "Spelling",
  grammar: "Grammar",
  punctuation: "Punctuation",
  word: "Word choice",
  clarity: "Clarity",
  flow: "Flow",
};
export const isSoft = (k: ProofKind) => k === "clarity" || k === "flow";

type Block = { text: string; pos: number[]; node: PMNode; start: number };

/** Paragraph-like blocks (not code) with a map from each character back to document positions. */
export function proofBlocks(doc: PMNode): Block[] {
  const out: Block[] = [];
  doc.descendants((node, start) => {
    if (node.type.name === "codeBlock") return false;
    if (!node.isTextblock) return true;
    let text = "";
    const pos: number[] = [];
    node.forEach((child, offset) => {
      if (child.isText) {
        const t = child.text ?? "";
        for (let i = 0; i < t.length; i++) pos.push(start + 1 + offset + i);
        text += t;
      } else {
        pos.push(start + 1 + offset);
        text += " ";
      }
    });
    out.push({ text, pos, node, start });
    return false;
  });
  return out;
}

/** Worth sending: a few real words, not a URL or a stray line. */
export function worthChecking(text: string): boolean {
  const t = text.trim();
  if (t.length < 12 || t.length > 2500) return false;
  if (/^https?:\/\/\S+$/.test(t)) return false;
  return (t.match(/\p{L}{2,}/gu) ?? []).length >= 3;
}

/** Small stable hash for cache keys (cyrb53). */
export function textKey(text: string): string {
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let i = 0; i < text.length; i++) {
    const ch = text.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36);
}

/** Where each issue sits in a document (first occurrence of its quote within its paragraph). */
export function locateIssues(doc: PMNode, lookup: (text: string) => ProofIssue[] | undefined): ProofHit[] {
  const hits: ProofHit[] = [];
  for (const b of proofBlocks(doc)) {
    const issues = lookup(b.text);
    if (!issues?.length) continue;
    for (const is of issues) {
      const i = b.text.indexOf(is.quote);
      if (i < 0 || !is.quote) continue;
      hits.push({ ...is, from: b.pos[i], to: b.pos[i + is.quote.length - 1] + 1, text: b.text });
    }
  }
  return hits;
}

/** The paragraph's text after replacing one issue's quote with its fix. */
export function applyToText(text: string, issue: ProofIssue): string {
  const i = text.indexOf(issue.quote);
  return i < 0 || issue.fix === null ? text : text.slice(0, i) + issue.fix + text.slice(i + issue.quote.length);
}

/**
 * The sentence around an issue as it would read after the fix, as diff parts ("add" = the new
 * words, shown in green; removed words are left out). Long sentences are trimmed with "…".
 */
export function previewParts(text: string, issue: ProofIssue, room = 60): { parts: DiffPart[]; lead: boolean; tail: boolean } | null {
  const i = text.indexOf(issue.quote);
  if (i < 0 || issue.fix === null) return null;
  const end = i + issue.quote.length;
  // Sentence bounds: after the last . ! ? before the quote, up to the next one after it.
  let start = 0;
  const before = text.slice(0, i);
  const m = /.*[.!?…]["'”’)]*\s+/s.exec(before);
  if (m) start = m[0].length;
  let stop = text.length;
  const next = /[.!?…]["'”’)]*(\s|$)/.exec(text.slice(end));
  if (/[.!?…]["'”’)]*$/.test(issue.quote)) stop = end;
  else if (next) stop = end + next.index + next[0].trimEnd().length;
  let lead = false;
  let tail = false;
  if (i - start > room) {
    start = text.lastIndexOf(" ", i - room) + 1 || i - room;
    lead = true;
  }
  if (stop - end > room) {
    const cut = text.indexOf(" ", end + room);
    stop = cut < 0 ? stop : cut;
    tail = stop < text.length;
  }
  const head = text.slice(start, i);
  const rest = text.slice(end, stop);
  const parts = diffWords(head + issue.quote + rest, head + issue.fix + rest).filter((p) => p.kind !== "del");
  return { parts, lead, tail };
}

// ── Store + scheduler ──────────────────────────────────────────────────────

const STORE_KEY = "bsplus-writer-proof";
const MAX_CACHE = 800;
const IDLE_MS = 2200;
const BATCH_CHARS = 5000;
const BATCH_PARAS = 12;

export type ProofStatus = "idle" | "waiting" | "checking" | "error" | "off";
type Call = (paragraphs: Array<{ id: string; text: string }>) => Promise<{ results: Record<string, ProofIssue[]> }>;

export class Proofreader {
  private cache = new Map<string, ProofIssue[]>();
  private dismissed = new Set<string>();
  private dictionary = new Set<string>();
  private queue = new Map<string, string>(); // key → text
  private timer: ReturnType<typeof setTimeout> | null = null;
  private busy = false;
  private retryAt = 0;
  status: ProofStatus = "idle";
  error = "";

  constructor(
    private call: Call,
    private onChange: (what: "issues" | "status") => void,
  ) {
    this.load();
  }

  // ── persistence ──
  private load(): void {
    try {
      const raw = JSON.parse(localStorage.getItem(STORE_KEY) ?? "{}");
      for (const [k, v] of raw.cache ?? []) if (Array.isArray(v)) this.cache.set(k, v);
      for (const d of raw.dismissed ?? []) this.dismissed.add(String(d));
      for (const w of raw.dictionary ?? []) this.dictionary.add(String(w));
    } catch {}
  }

  private saveSoon: ReturnType<typeof setTimeout> | null = null;
  private persist(): void {
    if (this.saveSoon) return;
    this.saveSoon = setTimeout(() => {
      this.saveSoon = null;
      while (this.cache.size > MAX_CACHE) this.cache.delete(this.cache.keys().next().value!);
      try {
        localStorage.setItem(
          STORE_KEY,
          JSON.stringify({ cache: [...this.cache], dismissed: [...this.dismissed].slice(-600), dictionary: [...this.dictionary] }),
        );
      } catch {}
    }, 500);
  }

  // ── lookups ──
  private dismissKey(i: ProofIssue): string {
    return `${i.kind}|${i.quote}|${i.fix ?? ""}`;
  }

  /** Issues for a paragraph's text (undefined = not checked yet), minus dismissed ones. */
  lookup = (text: string): ProofIssue[] | undefined => {
    const list = this.cache.get(textKey(text));
    if (!list) return undefined;
    return list.filter(
      (i) => !this.dismissed.has(this.dismissKey(i)) && !(i.kind === "spelling" && this.dictionary.has(i.quote.trim().toLowerCase())),
    );
  };

  isChecked(text: string): boolean {
    return this.cache.has(textKey(text));
  }

  dismiss(issue: ProofIssue): void {
    this.dismissed.add(this.dismissKey(issue));
    this.persist();
    this.onChange("issues");
  }

  addToDictionary(word: string): void {
    this.dictionary.add(word.trim().toLowerCase());
    this.persist();
    this.onChange("issues");
  }

  /** Before a fix is applied: the new paragraph text keeps the other issues, so no re-check. */
  accepted(text: string, issue: ProofIssue): void {
    const rest = (this.cache.get(textKey(text)) ?? []).filter((i) => i !== issue && i.quote !== issue.quote);
    const next = applyToText(text, issue);
    const still = rest.filter((i) => next.includes(i.quote));
    this.cache.set(textKey(next), still);
    this.persist();
  }

  /** Forget results for these paragraphs so they're checked again. */
  forget(texts: string[]): void {
    for (const t of texts) this.cache.delete(textKey(t));
    this.persist();
  }

  // ── scheduling ──
  /**
   * Queue every unchecked paragraph in these docs. `typing` is the paragraph under the caret:
   * it waits until it ends a sentence, so half-typed words aren't flagged (and sent) each pause.
   */
  scan(docs: PMNode[], typing: string | null, now = false): void {
    for (const doc of docs) {
      for (const b of proofBlocks(doc)) {
        if (!worthChecking(b.text)) continue;
        if (b.text === typing && !/[.!?…:;]["'”’)\]]*\s*$/.test(b.text)) continue;
        const k = textKey(b.text);
        if (!this.cache.has(k)) this.queue.set(k, b.text);
      }
    }
    // Drop queued paragraphs that no longer exist (edited since).
    const live = new Set<string>();
    for (const doc of docs) for (const b of proofBlocks(doc)) live.add(textKey(b.text));
    for (const k of [...this.queue.keys()]) if (!live.has(k)) this.queue.delete(k);
    if (!this.queue.size) {
      if (this.status === "waiting") this.setStatus("idle");
      return;
    }
    if (this.timer) clearTimeout(this.timer);
    const wait = Math.max(now ? 0 : IDLE_MS, this.retryAt - Date.now());
    if (!this.busy && this.status !== "error") this.setStatus("waiting");
    this.timer = setTimeout(() => void this.run(), wait);
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.queue.clear();
  }

  private setStatus(s: ProofStatus, error = ""): void {
    this.status = s;
    this.error = error;
    this.onChange("status");
  }

  get pending(): number {
    return this.queue.size;
  }

  private async run(): Promise<void> {
    this.timer = null;
    if (this.busy || !this.queue.size) return;
    const batch: Array<{ id: string; text: string; key: string }> = [];
    let chars = 0;
    for (const [key, text] of this.queue) {
      if (batch.length >= BATCH_PARAS || (chars + text.length > BATCH_CHARS && batch.length)) break;
      batch.push({ id: String(batch.length), text, key });
      chars += text.length;
    }
    this.busy = true;
    this.setStatus("checking");
    try {
      const { results } = await this.call(batch.map(({ id, text }) => ({ id, text })));
      for (const b of batch) {
        this.queue.delete(b.key);
        const list = results?.[b.id];
        if (Array.isArray(list)) this.cache.set(b.key, list);
      }
      this.retryAt = 0;
      this.persist();
      this.busy = false;
      this.setStatus(this.queue.size ? "waiting" : "idle");
      this.onChange("issues");
      if (this.queue.size) this.timer = setTimeout(() => void this.run(), 300);
    } catch (err) {
      this.busy = false;
      this.retryAt = Date.now() + 60_000;
      this.setStatus("error", err instanceof Error ? err.message : String(err));
    }
  }
}

// ── Editor decorations ─────────────────────────────────────────────────────

export const proofKey = new PluginKey<DecorationSet>("wr-proof");

export const ProofMarks = Extension.create<{ enabled: () => boolean; lookup: (text: string) => ProofIssue[] | undefined }>({
  name: "wrProof",
  addOptions() {
    return { enabled: () => false, lookup: () => undefined };
  },
  addProseMirrorPlugins() {
    const build = (doc: PMNode) =>
      this.options.enabled()
        ? DecorationSet.create(
            doc,
            locateIssues(doc, this.options.lookup).map((hit) =>
              Decoration.inline(hit.from, hit.to, { class: `wr-pf wr-pf-${isSoft(hit.kind) ? "soft" : "fix"}`, "data-proof": hit.kind }, { hit }),
            ),
          )
        : DecorationSet.empty;
    return [
      new Plugin<DecorationSet>({
        key: proofKey,
        state: {
          init: (_c, state) => build(state.doc),
          apply: (tr, old) => (tr.getMeta(proofKey) || tr.docChanged ? build(tr.doc) : old),
        },
        props: { decorations: (state) => proofKey.getState(state) },
      }),
    ];
  },
});

/** The issue under a document position, if any. */
export function hitAt(view: EditorView, pos: number): ProofHit | null {
  const set = proofKey.getState(view.state);
  const found = set?.find(pos, pos) ?? [];
  const d = found.find((x) => x.from <= pos && pos <= x.to);
  const hit = (d?.spec as { hit?: ProofHit } | undefined)?.hit;
  return d && hit ? { ...hit, from: d.from, to: d.to } : null;
}

/** Every issue currently marked in an editor, in document order. */
export function hitsIn(view: EditorView): ProofHit[] {
  const set = proofKey.getState(view.state);
  return (set?.find() ?? []).map((d) => ({ ...(d.spec as { hit: ProofHit }).hit, from: d.from, to: d.to })).sort((a, b) => a.from - b.from);
}
