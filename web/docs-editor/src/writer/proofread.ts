import { Extension } from "@tiptap/core";
import { Plugin, PluginKey, type Transaction } from "@tiptap/pm/state";
import { Decoration, DecorationSet, type EditorView } from "@tiptap/pm/view";
import type { Node as PMNode } from "@tiptap/pm/model";
import { diffWords, type DiffPart } from "./stats";

/**
 * Spelling & grammar checks, as in Google Docs: misspelt words get a red squiggle, grammar a blue
 * one, and hovering (or clicking) one shows the fix. Atlantis checks paragraphs on this Mac with
 * macOS's own spelling and grammar checker (Swift `spell.check`, NSSpellChecker): fast, offline and
 * in the Mac's language (e.g. Australian English). Results are cached by paragraph text, in memory
 * and in localStorage, so a paragraph is only checked again after it changes. While you edit a
 * paragraph its other marks stay put; only the word you're changing loses its mark until re-checked.
 */

export type ProofKind = "spelling" | "grammar" | "punctuation" | "word" | "clarity" | "flow";
export type ProofIssue = {
  kind: ProofKind;
  quote: string;
  fix: string | null;
  note: string;
  /** Where the quote starts in the paragraph (UTF-16 offset); without it the first match is used. */
  at?: number;
  /** Other suggestions after `fix`. */
  alts?: string[];
};
export type ProofHit = ProofIssue & { from: number; to: number; text: string; at: number };

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

/**
 * One paragraph-like block's text, with a map from each character back to document positions.
 * Inline code and non-text nodes (maths, images, mentions) become spaces so they aren't checked.
 */
export function blockOf(node: PMNode, start: number): Block {
  let text = "";
  const pos: number[] = [];
  node.forEach((child, offset) => {
    if (child.isText) {
      const t = child.text ?? "";
      for (let i = 0; i < t.length; i++) pos.push(start + 1 + offset + i);
      text += child.marks.some((m) => m.type.name === "code") ? " ".repeat(t.length) : t;
    } else {
      pos.push(start + 1 + offset);
      text += " ";
    }
  });
  return { text, pos, node, start };
}

/** Paragraph-like blocks (not code blocks). */
export function proofBlocks(doc: PMNode): Block[] {
  const out: Block[] = [];
  doc.descendants((node, start) => {
    if (node.type.name === "codeBlock") return false;
    if (!node.isTextblock) return true;
    out.push(blockOf(node, start));
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

/** Where an issue's quote starts in its paragraph: its `at` when that still matches, else the first match. */
export function issueIndex(text: string, issue: ProofIssue): number {
  if (!issue.quote) return -1;
  if (typeof issue.at === "number" && issue.at >= 0 && text.startsWith(issue.quote, issue.at)) return issue.at;
  return text.indexOf(issue.quote);
}

/** One block's issues, placed in the document. */
export function blockHits(b: Block, lookup: (text: string) => ProofIssue[] | undefined): ProofHit[] {
  const hits: ProofHit[] = [];
  for (const is of lookup(b.text) ?? []) {
    const i = issueIndex(b.text, is);
    if (i < 0) continue;
    hits.push({ ...is, at: i, from: b.pos[i], to: b.pos[i + is.quote.length - 1] + 1, text: b.text });
  }
  return hits;
}

/** Where each issue sits in a document. */
export function locateIssues(doc: PMNode, lookup: (text: string) => ProofIssue[] | undefined): ProofHit[] {
  return proofBlocks(doc).flatMap((b) => blockHits(b, lookup));
}

/** The paragraph's text after replacing one issue's quote with `fix` (default: its own fix). */
export function applyToText(text: string, issue: ProofIssue, fix = issue.fix): string {
  const i = issueIndex(text, issue);
  return i < 0 || fix === null ? text : text.slice(0, i) + fix + text.slice(i + issue.quote.length);
}

/**
 * The sentence around an issue as it would read after the fix, as diff parts ("add" = the new
 * words, shown in green; removed words are left out). Long sentences are trimmed with "…".
 */
export function previewParts(text: string, issue: ProofIssue, room = 60): { parts: DiffPart[]; lead: boolean; tail: boolean } | null {
  const i = issueIndex(text, issue);
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
    // Trim at a word break (never mid-word); if there's none, keep the whole sentence start.
    const space = text.lastIndexOf(" ", i - room);
    if (space > start) {
      start = space + 1;
      lead = true;
    }
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

// The Claude-era key ("bsplus-writer-proof") is left alone; results from another checker don't mix.
const STORE_KEY = "atlantis-docs-spell";
const MAX_CACHE = 3000;
/** The Mac's checker answers in milliseconds, so a short pause is enough. */
const IDLE_MS = 300;
const BATCH_CHARS = 100_000;
const BATCH_PARAS = 200;
const RETRY_MS = 15_000;
/** A character that belongs to a word. */
const WORD_CHAR = /[\p{L}\p{M}\p{N}'’]/u;
/** The caret sits right after a letter: a word is still being typed. */
const MID_WORD = /[\p{L}\p{M}'’-]$/u;

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

  /** Not dismissed, and (for spelling) not in your dictionary. */
  shown = (i: ProofIssue): boolean =>
    !this.dismissed.has(this.dismissKey(i)) && !(i.kind === "spelling" && this.dictionary.has(i.quote.trim().toLowerCase()));

  /** Issues for a paragraph's text (undefined = not checked yet), minus dismissed ones. */
  lookup = (text: string): ProofIssue[] | undefined => {
    const list = this.cache.get(textKey(text));
    return list?.filter(this.shown);
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

  /**
   * Before a fix is applied: the new paragraph text keeps the other issues (moved along), so it
   * isn't checked again. `fix` is the suggestion picked (an alternative, or the issue's own fix).
   */
  accepted(text: string, issue: ProofIssue, fix = issue.fix): void {
    const at = issueIndex(text, issue);
    if (at < 0 || fix === null) return;
    const end = at + issue.quote.length;
    const delta = fix.length - issue.quote.length;
    const still: ProofIssue[] = [];
    for (const other of this.cache.get(textKey(text)) ?? []) {
      const i = issueIndex(text, other);
      if (i < 0 || (i === at && other.quote === issue.quote)) continue;
      if (i + other.quote.length <= at) still.push({ ...other, at: i });
      else if (i >= end) still.push({ ...other, at: i + delta });
    }
    this.cache.set(textKey(applyToText(text, issue, fix)), still);
    this.persist();
  }

  /** Forget results for these paragraphs so they're checked again. */
  forget(texts: string[]): void {
    for (const t of texts) this.cache.delete(textKey(t));
    this.persist();
  }

  // ── scheduling ──
  /**
   * Queue every unchecked paragraph in these docs. `typing` is the paragraph under the caret and
   * how much of it is before the caret: while a word is half typed it waits, so the word isn't
   * flagged before it's finished. Returns true when it held that paragraph back (check again once
   * the caret moves on).
   */
  scan(docs: PMNode[], typing: { text: string; before: number } | null, now = false): boolean {
    let held = false;
    for (const doc of docs) {
      for (const b of proofBlocks(doc)) {
        if (!worthChecking(b.text)) continue;
        const k = textKey(b.text);
        if (this.cache.has(k)) continue;
        if (typing && b.text === typing.text && MID_WORD.test(b.text.slice(0, typing.before))) {
          held = true;
          continue;
        }
        this.queue.set(k, b.text);
      }
    }
    // Drop queued paragraphs that no longer exist (edited since).
    const live = new Set<string>();
    for (const doc of docs) for (const b of proofBlocks(doc)) live.add(textKey(b.text));
    for (const k of [...this.queue.keys()]) if (!live.has(k)) this.queue.delete(k);
    if (!this.queue.size) {
      if (this.status === "waiting") this.setStatus("idle");
      return held;
    }
    if (this.timer) clearTimeout(this.timer);
    const wait = Math.max(now ? 0 : IDLE_MS, this.retryAt - Date.now());
    if (!this.busy && this.status !== "error") this.setStatus("waiting");
    this.timer = setTimeout(() => void this.run(), wait);
    return held;
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
      if (this.queue.size) this.timer = setTimeout(() => void this.run(), 0);
    } catch (err) {
      this.busy = false;
      this.retryAt = Date.now() + RETRY_MS;
      this.setStatus("error", err instanceof Error ? err.message : String(err));
    }
  }
}

// ── Editor decorations ─────────────────────────────────────────────────────

export const proofKey = new PluginKey<DecorationSet>("wr-proof");

const hitDeco = (hit: ProofHit) =>
  Decoration.inline(hit.from, hit.to, { class: `wr-pf wr-pf-${isSoft(hit.kind) ? "soft" : hit.kind === "spelling" ? "spell" : "fix"}`, "data-proof": hit.kind }, { hit });

/** The ranges a transaction changed, in the new document's positions. */
function changedRanges(tr: Transaction): Array<[number, number]> {
  const out: Array<[number, number]> = [];
  tr.mapping.maps.forEach((map, i) => {
    const rest = tr.mapping.slice(i + 1);
    map.forEach((_oldFrom, _oldTo, from, to) => out.push([rest.map(from, -1), rest.map(to, 1)]));
  });
  return out;
}

type MarkOptions = {
  enabled: () => boolean;
  lookup: (text: string) => ProofIssue[] | undefined;
  /** False for an issue that's been dismissed or added to the dictionary since it was marked. */
  shown: (issue: ProofIssue) => boolean;
};

export const ProofMarks = Extension.create<MarkOptions>({
  name: "wrProof",
  addOptions() {
    return { enabled: () => false, lookup: () => undefined, shown: () => true };
  },
  addProseMirrorPlugins() {
    const opts = this.options;
    /**
     * Redo one paragraph's marks: checked text gets them from the cache; text not checked yet
     * (being edited) keeps its old ones, except any an edit touched or that are no longer shown.
     */
    const redo = (set: DecorationSet, doc: PMNode, node: PMNode, start: number, touched: (d: Decoration) => boolean) => {
      const b = blockOf(node, start);
      const stale = set.find(start, start + node.nodeSize);
      set = set.remove(stale.slice()); // remove() nulls out the array it's given
      if (opts.lookup(b.text)) return set.add(doc, blockHits(b, opts.lookup).map(hitDeco));
      const keep = stale.filter((d) => {
        const hit = (d.spec as { hit: ProofHit }).hit;
        return opts.shown(hit) && !touched(d) && doc.textBetween(d.from, d.to, " ", " ") === hit.quote;
      });
      return set.add(doc, keep);
    };
    /** New results (or a dismissal): every paragraph again. */
    const all = (doc: PMNode, old: DecorationSet) => {
      let set = old;
      doc.descendants((node, start) => {
        if (node.type.name === "codeBlock") return false;
        if (!node.isTextblock) return true;
        set = redo(set, doc, node, start, () => false);
        return false;
      });
      return set;
    };
    /** After an edit only the paragraphs it touched are redone. */
    const update = (tr: Transaction, old: DecorationSet): DecorationSet => {
      let set = old.map(tr.mapping, tr.doc);
      const doc = tr.doc;
      const seen = new Set<number>();
      const ranges = changedRanges(tr);
      // An edit inside a marked word, or one that makes it longer (a letter right before or after
      // it), changes the word. A space or full stop typed after it doesn't.
      const letterAt = (pos: number) => pos >= 0 && pos < doc.content.size && WORD_CHAR.test(doc.textBetween(pos, pos + 1, "\n", "\n"));
      const touched = (d: Decoration) =>
        ranges.some(([a, z]) => (d.from < z && d.to > a) || (a <= d.to && d.to <= z && letterAt(d.to)) || (a <= d.from && d.from <= z && letterAt(d.from - 1)));
      for (const [from, to] of ranges) {
        doc.nodesBetween(Math.max(0, from - 1), Math.min(doc.content.size, to + 1), (node, start) => {
          if (node.type.name === "codeBlock") return false;
          if (!node.isTextblock) return true;
          if (!seen.has(start)) set = redo(set, doc, node, start, touched);
          seen.add(start);
          return false;
        });
      }
      return set;
    };
    return [
      new Plugin<DecorationSet>({
        key: proofKey,
        state: {
          init: (_c, state) => (opts.enabled() ? all(state.doc, DecorationSet.empty) : DecorationSet.empty),
          apply: (tr, old) => {
            if (!opts.enabled()) return DecorationSet.empty;
            if (tr.getMeta(proofKey)) return all(tr.doc, tr.docChanged ? old.map(tr.mapping, tr.doc) : old);
            return tr.docChanged ? update(tr, old) : old;
          },
        },
        props: { decorations: (state) => proofKey.getState(state) },
      }),
    ];
  },
});

/** A decoration's issue, with its paragraph's current text and offset (marks can outlive a check). */
function hitOf(view: EditorView, d: Decoration): ProofHit | null {
  const hit = (d.spec as { hit?: ProofHit } | undefined)?.hit;
  if (!hit) return null;
  const $p = view.state.doc.resolve(d.from);
  if (!$p.parent.isTextblock) return { ...hit, from: d.from, to: d.to };
  const b = blockOf($p.parent, $p.before($p.depth));
  const at = b.pos.indexOf(d.from);
  return { ...hit, from: d.from, to: d.to, text: b.text, at: at >= 0 ? at : hit.at };
}

/** The issue under a document position, if any. */
export function hitAt(view: EditorView, pos: number): ProofHit | null {
  const set = proofKey.getState(view.state);
  const d = (set?.find(pos, pos) ?? []).find((x) => x.from <= pos && pos <= x.to);
  return d ? hitOf(view, d) : null;
}

/** Every issue currently marked in an editor, in document order. */
export function hitsIn(view: EditorView): ProofHit[] {
  const set = proofKey.getState(view.state);
  return (set?.find() ?? [])
    .map((d) => hitOf(view, d))
    .filter((x): x is ProofHit => !!x)
    .sort((a, b) => a.from - b.from);
}
