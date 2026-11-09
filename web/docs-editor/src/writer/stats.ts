/**
 * Writing numbers for the word-count popover and the snapshot compare view. Pure functions so
 * they can be tested without an editor.
 */

/** Markdown → readable plain text (one paragraph per line). */
export function plainText(markdown: string): string {
  return String(markdown ?? "")
    .replace(/```[\s\S]*?```/g, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^[ \t]{0,3}#{1,6}\s+/gm, "")
    .replace(/^[ \t]{0,3}>\s?/gm, "")
    .replace(/^[ \t]*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/gm, "")
    .replace(/^[ \t]*\|?[ \t]*:?-{3,}.*$/gm, "")
    .replace(/\|/g, " ")
    .replace(/(\*\*|__|\+\+|==|~~|[*_`])/g, "")
    .replace(/^-{3,}$/gm, "")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

const WORD = /[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu;

function syllables(word: string): number {
  const w = word.toLowerCase().replace(/[^a-z]/g, "");
  if (!w) return 0;
  if (w.length <= 3) return 1;
  const trimmed = w.replace(/(?:[^laeiouy]es|ed|[^laeiouy]e)$/, "").replace(/^y/, "");
  const groups = trimmed.match(/[aeiouy]{1,2}/g);
  return Math.max(1, groups ? groups.length : 1);
}

export type TextStats = {
  words: number;
  characters: number;
  charactersNoSpaces: number;
  sentences: number;
  paragraphs: number;
  avgSentence: number;
  longSentences: number;
  readingMinutes: number;
  speakingMinutes: number;
  /** Flesch reading ease, 0 (hard) – 100 (easy); null when there's too little text. */
  readingEase: number | null;
  readingLabel: string;
};

export function textStats(markdown: string): TextStats {
  const text = plainText(markdown);
  const words = text.match(WORD) ?? [];
  const paragraphs = text.split(/\n\s*\n|\n/).filter((p) => p.trim()).length;
  const sentenceList = text
    .split(/(?<=[.!?…])["'”’)\]]*\s+|\n+/)
    .map((s) => s.trim())
    .filter((s) => (s.match(WORD) ?? []).length > 0);
  const sentences = sentenceList.length;
  const longSentences = sentenceList.filter((s) => (s.match(WORD) ?? []).length > 30).length;
  const syl = words.reduce((n, w) => n + syllables(w), 0);
  const ease =
    words.length >= 30 && sentences
      ? Math.max(0, Math.min(100, Math.round(206.835 - 1.015 * (words.length / sentences) - 84.6 * (syl / words.length))))
      : null;
  return {
    words: words.length,
    characters: text.replace(/\n/g, "").length,
    charactersNoSpaces: text.replace(/\s/g, "").length,
    sentences,
    paragraphs,
    avgSentence: sentences ? Math.round((words.length / sentences) * 10) / 10 : 0,
    longSentences,
    readingMinutes: words.length / 230,
    speakingMinutes: words.length / 130,
    readingEase: ease,
    readingLabel:
      ease === null
        ? "Write a little more"
        : ease >= 80
          ? "Very easy to read"
          : ease >= 60
            ? "Easy to read"
            : ease >= 50
              ? "Fairly clear"
              : ease >= 30
                ? "Academic"
                : "Dense — try shorter sentences",
  };
}

export function minutesLabel(min: number): string {
  if (min < 1) return `${Math.max(1, Math.round(min * 60))} sec`;
  const m = Math.floor(min);
  const s = Math.round((min - m) * 60);
  return s >= 30 && m < 10 ? `${m} min ${s} s` : `${Math.round(min)} min`;
}

// ── Word diff (snapshot compare) ──────────────────────────────────────────

export type DiffPart = { kind: "same" | "add" | "del"; text: string };

function tokens(text: string): string[] {
  return text.match(/\s+|[\p{L}\p{N}'’-]+|[^\s\p{L}\p{N}]/gu) ?? [];
}

/**
 * Word-level diff of two plain texts. Common start/end are trimmed first; the middle uses an LCS
 * table, and very long changes fall back to "all removed / all added" so it never hangs.
 */
export function diffWords(before: string, after: string): DiffPart[] {
  const a = tokens(before);
  const b = tokens(after);
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA--;
    endB--;
  }
  const out: DiffPart[] = [];
  const push = (kind: DiffPart["kind"], text: string) => {
    if (!text) return;
    const last = out[out.length - 1];
    if (last && last.kind === kind) last.text += text;
    else out.push({ kind, text });
  };
  push("same", a.slice(0, start).join(""));
  const midA = a.slice(start, endA);
  const midB = b.slice(start, endB);
  if (midA.length * midB.length > 4_000_000) {
    push("del", midA.join(""));
    push("add", midB.join(""));
  } else {
    const n = midA.length;
    const m = midB.length;
    const table: Uint32Array[] = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
    for (let i = n - 1; i >= 0; i--) {
      for (let j = m - 1; j >= 0; j--) {
        table[i][j] = midA[i] === midB[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
      }
    }
    let i = 0;
    let j = 0;
    while (i < n && j < m) {
      if (midA[i] === midB[j]) {
        push("same", midA[i]);
        i++;
        j++;
      } else if (table[i + 1][j] >= table[i][j + 1]) push("del", midA[i++]);
      else push("add", midB[j++]);
    }
    while (i < n) push("del", midA[i++]);
    while (j < m) push("add", midB[j++]);
  }
  push("same", a.slice(endA).join(""));
  return out;
}

export function diffSummary(parts: DiffPart[]): { added: number; removed: number } {
  const count = (t: string) => (t.match(WORD) ?? []).length;
  let added = 0;
  let removed = 0;
  for (const p of parts) {
    if (p.kind === "add") added += count(p.text);
    else if (p.kind === "del") removed += count(p.text);
  }
  return { added, removed };
}
