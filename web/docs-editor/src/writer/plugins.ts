import { Extension } from "@tiptap/core";
import { Plugin, PluginKey, type EditorState, type Transaction } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import type { Node as PMNode } from "@tiptap/pm/model";

/**
 * Editor add-ons that only decorate the text (nothing here changes the saved Markdown):
 *  - find: highlights every match of the find bar's query, the current one stronger
 *  - comments: highlights the text each comment is anchored to (comments live in the doc's
 *    front matter as quote + a little context before it, so the .md body stays clean)
 *  - focus: marks the block the caret is in, so focus mode can dim the rest
 */

export type Range = { from: number; to: number };

/** Text of every textblock with a map back to document positions (matches can cross marks). */
function textIndex(doc: PMNode): Array<{ text: string; pos: number[] }> {
  const out: Array<{ text: string; pos: number[] }> = [];
  doc.descendants((node, start) => {
    if (!node.isTextblock) return true;
    let text = "";
    const pos: number[] = [];
    node.forEach((child, offset) => {
      if (child.isText) {
        const t = child.text ?? "";
        for (let i = 0; i < t.length; i++) pos.push(start + 1 + offset + i);
        text += t;
      } else {
        // Hard breaks and inline images count as a space so words don't run together.
        pos.push(start + 1 + offset);
        text += " ";
      }
    });
    out.push({ text, pos });
    return false;
  });
  return out;
}

export function findMatches(doc: PMNode, query: string, caseSensitive = false): Range[] {
  if (!query) return [];
  const q = caseSensitive ? query : query.toLowerCase();
  const hits: Range[] = [];
  for (const block of textIndex(doc)) {
    const hay = caseSensitive ? block.text : block.text.toLowerCase();
    let i = hay.indexOf(q);
    while (i !== -1 && hits.length < 2000) {
      hits.push({ from: block.pos[i], to: block.pos[i + q.length - 1] + 1 });
      i = hay.indexOf(q, i + Math.max(1, q.length));
    }
  }
  return hits;
}

/** Where a quote sits, preferring the occurrence whose preceding text ends with `before`. */
export function locateQuote(doc: PMNode, quote: string, before = ""): Range | null {
  if (!quote) return null;
  let first: Range | null = null;
  for (const block of textIndex(doc)) {
    let i = block.text.indexOf(quote);
    while (i !== -1) {
      const r = { from: block.pos[i], to: block.pos[i + quote.length - 1] + 1 };
      if (!before || block.text.slice(0, i).endsWith(before)) return r;
      first ??= r;
      i = block.text.indexOf(quote, i + 1);
    }
  }
  return first;
}

/** Up to `n` characters of the text just before a position (same textblock). */
export function contextBefore(state: EditorState, pos: number, n = 24): string {
  const $pos = state.doc.resolve(pos);
  const start = $pos.start();
  return state.doc.textBetween(Math.max(start, pos - n), pos, " ", " ");
}

// ── Find ──────────────────────────────────────────────────────────────────

type FindState = { query: string; caseSensitive: boolean; current: number; matches: Range[]; deco: DecorationSet };
export const findKey = new PluginKey<FindState>("wr-find");

function buildFind(doc: PMNode, query: string, caseSensitive: boolean, current: number): FindState {
  const matches = findMatches(doc, query, caseSensitive);
  const cur = matches.length ? Math.min(Math.max(current, -1), matches.length - 1) : -1;
  const deco = DecorationSet.create(
    doc,
    matches.map((m, i) => Decoration.inline(m.from, m.to, { class: i === cur ? "wr-find-hit is-current" : "wr-find-hit" })),
  );
  return { query, caseSensitive, current: cur, matches, deco };
}

export type FindMeta = { query?: string; caseSensitive?: boolean; current?: number };

export const FindHighlight = Extension.create({
  name: "wrFind",
  addProseMirrorPlugins() {
    return [
      new Plugin<FindState>({
        key: findKey,
        state: {
          init: (_c, state) => buildFind(state.doc, "", false, -1),
          apply: (tr: Transaction, old: FindState) => {
            const meta = tr.getMeta(findKey) as FindMeta | undefined;
            if (!meta && !tr.docChanged) return old;
            const query = meta?.query ?? old.query;
            const cs = meta?.caseSensitive ?? old.caseSensitive;
            const cur = meta?.current ?? old.current;
            if (!query) return buildFind(tr.doc, "", cs, -1);
            return buildFind(tr.doc, query, cs, cur);
          },
        },
        props: { decorations: (state) => findKey.getState(state)?.deco },
      }),
    ];
  },
});

// ── Comments ──────────────────────────────────────────────────────────────

export type Comment = { id: string; quote: string; before?: string; text: string; at: string; done?: boolean };
export const commentKey = new PluginKey<DecorationSet>("wr-comments");

export const CommentHighlight = Extension.create<{ get: () => Comment[]; active: () => string | null }>({
  name: "wrComments",
  addOptions() {
    return { get: () => [], active: () => null };
  },
  addProseMirrorPlugins() {
    const build = (doc: PMNode) => {
      const decos: Decoration[] = [];
      const active = this.options.active();
      for (const c of this.options.get()) {
        if (c.done) continue;
        const r = locateQuote(doc, c.quote, c.before);
        if (r) decos.push(Decoration.inline(r.from, r.to, { class: `wr-cmt${c.id === active ? " is-active" : ""}`, "data-comment": c.id }));
      }
      return DecorationSet.create(doc, decos);
    };
    return [
      new Plugin<DecorationSet>({
        key: commentKey,
        state: {
          init: (_c, state) => build(state.doc),
          apply: (tr, old) => (tr.getMeta(commentKey) || tr.docChanged ? build(tr.doc) : old),
        },
        props: { decorations: (state) => commentKey.getState(state) },
      }),
    ];
  },
});

// ── Focus (current block) ─────────────────────────────────────────────────

export const FocusBlock = Extension.create({
  name: "wrFocus",
  addProseMirrorPlugins() {
    return [
      new Plugin({
        props: {
          decorations: (state) => {
            const { $head } = state.selection;
            if ($head.depth < 1) return null;
            const from = $head.before(1);
            const node = state.doc.nodeAt(from);
            if (!node) return null;
            return DecorationSet.create(state.doc, [Decoration.node(from, from + node.nodeSize, { class: "wr-focus-block" })]);
          },
        },
      }),
    ];
  },
});

// ── Review (long sentences, filler words) ─────────────────────────────────

/** Words that usually weaken school writing; flagged gently, never changed. */
export const FILLER = ["very", "really", "basically", "actually", "things", "stuff", "a lot", "lots of", "got", "just", "kind of", "sort of", "in my opinion", "i think", "obviously", "literally"];

export function reviewRanges(doc: PMNode): Array<Range & { kind: "long" | "filler" }> {
  const out: Array<Range & { kind: "long" | "filler" }> = [];
  const filler = new RegExp(`\\b(${FILLER.map((f) => f.replace(/ /g, "\\s+")).join("|")})\\b`, "gi");
  for (const block of textIndex(doc)) {
    const { text, pos } = block;
    if (!text.trim()) continue;
    const sentence = /[^.!?…]+[.!?…]*["'”’)]*/g;
    let m: RegExpExecArray | null;
    while ((m = sentence.exec(text))) {
      const words = m[0].match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu) ?? [];
      if (words.length > 30) {
        const lead = m[0].length - m[0].trimStart().length;
        const start = m.index + lead;
        const end = m.index + m[0].trimEnd().length;
        if (end > start) out.push({ from: pos[start], to: pos[end - 1] + 1, kind: "long" });
      }
      if (!m[0]) sentence.lastIndex++;
    }
    filler.lastIndex = 0;
    while ((m = filler.exec(text))) out.push({ from: pos[m.index], to: pos[m.index + m[0].length - 1] + 1, kind: "filler" });
  }
  return out;
}

export const reviewKey = new PluginKey<DecorationSet>("wr-review");

export const ReviewMarks = Extension.create<{ enabled: () => boolean }>({
  name: "wrReview",
  addOptions() {
    return { enabled: () => false };
  },
  addProseMirrorPlugins() {
    const build = (doc: PMNode) =>
      this.options.enabled()
        ? DecorationSet.create(
            doc,
            reviewRanges(doc).map((r) =>
              Decoration.inline(r.from, r.to, {
                class: r.kind === "long" ? "wr-rv-long" : "wr-rv-filler",
                title: r.kind === "long" ? "Long sentence (over 30 words): try splitting it" : "Filler word: cut it or be more precise",
              }),
            ),
          )
        : DecorationSet.empty;
    return [
      new Plugin<DecorationSet>({
        key: reviewKey,
        state: {
          init: (_c, state) => build(state.doc),
          apply: (tr, old) => (tr.getMeta(reviewKey) || tr.docChanged ? build(tr.doc) : old),
        },
        props: { decorations: (state) => reviewKey.getState(state) },
      }),
    ];
  },
});
