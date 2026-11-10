import type { Transaction } from "@tiptap/pm/state";

/**
 * Atlantis: the writing record. A plain log of how a project's text came to be, so the user can
 * show (to themselves or a teacher) that the work is their own: when they wrote, how much they
 * typed versus pasted, what was pasted, and when text changed outside the Writer.
 *
 * Kept in `<project>/.writer-record.jsonl`, one JSON object per line, appended as you write:
 *   {"minute":"2026-11-11T05:42","doc":"Draft/Intro.md","typed":312,"deleted":40,"pasted":0,"words":1204}
 *   {"paste":"2026-11-11T05:42:13.120Z","doc":"Draft/Intro.md","chars":523,"words":88,"from":"outside","text":"…"}
 *   {"event":"restore","at":"2026-11-11T06:00:00.000Z","doc":"Draft/Intro.md","detail":"…"}
 * Edits are added up per minute, so the file stays small. Times are UTC.
 * It's a plain file you can read, not proof against tampering.
 */

export const RECORD_FILE = ".writer-record.jsonl";
/** A break longer than this starts a new writing session. */
export const SESSION_GAP_MIN = 20;
/** How much pasted text is kept in the record. */
const PASTE_KEEP = 400;

export type MinuteLine = { minute: string; doc: string; typed: number; deleted: number; pasted: number; words: number };
export type PasteLine = { paste: string; doc: string; chars: number; words: number; from: "outside" | "writer"; text: string };
export type EventKind = "restore" | "import" | "outside" | "created";
export type EventLine = { event: EventKind; at: string; doc: string; detail?: string };
export type RecordLine = MinuteLine | PasteLine | EventLine;

// ── Measuring one edit ──────────────────────────────────────────────────────

export type Measure = { typed: number; deleted: number; pasted: number; pasteText: string };

type StepLike = { from?: number; to?: number; slice?: { content: { size: number; textBetween(a: number, b: number, block?: string, leaf?: string): string } } };

/**
 * Characters a transaction added and removed, split into typed and pasted (paste or drop).
 * Undo/redo isn't counted as typing.
 */
export function measure(tr: Transaction): Measure {
  const out: Measure = { typed: 0, deleted: 0, pasted: 0, pasteText: "" };
  if (!tr.docChanged || tr.getMeta("history$")) return out;
  const ui = tr.getMeta("uiEvent");
  const pasted = ui === "paste" || ui === "drop" || tr.getMeta("paste") === true;
  let inserted = "";
  tr.steps.forEach((raw, i) => {
    const step = raw as unknown as StepLike;
    if (!step.slice || step.from === undefined || step.to === undefined) return;
    const before = tr.docs[i];
    if (step.to > step.from) out.deleted += before.textBetween(step.from, step.to, "\n", " ").length;
    const c = step.slice.content;
    if (c.size) inserted += c.textBetween(0, c.size, "\n", " ");
  });
  if (pasted) {
    out.pasted = inserted.length;
    out.pasteText = inserted;
  } else {
    out.typed = inserted.length;
  }
  return out;
}

export function wordCount(text: string): number {
  const m = text.match(/[\p{L}\p{N}][\p{L}\p{N}'’]*/gu);
  return m ? m.length : 0;
}

const norm = (s: string) => s.replace(/\s+/g, " ").trim();

// ── Keeping the record while you write ──────────────────────────────────────

export type RecordKeeperOptions = {
  /** Appends lines to the project's record file. */
  append: (lines: RecordLine[]) => Promise<void>;
  /** Words in a doc right now (asked when a minute closes). */
  words: (doc: string) => number;
  now?: () => Date;
  /** How long to wait before writing what's collected. */
  delayMs?: number;
};

export class RecordKeeper {
  private open = new Map<string, MinuteLine>();
  private queue: RecordLine[] = [];
  private timer: ReturnType<typeof setTimeout> | null = null;
  private writing: Promise<void> = Promise.resolve();
  /** Text last copied or cut inside the Writer, to tell moving text apart from pasting it in. */
  private copied = new Set<string>();

  constructor(private readonly opts: RecordKeeperOptions) {}

  private now(): Date {
    return this.opts.now?.() ?? new Date();
  }

  /** Remember text copied or cut in the Writer (so pasting it back counts as moving text). */
  copiedText(text: string): void {
    const t = norm(text);
    if (!t) return;
    this.copied.add(t);
    if (this.copied.size > 20) this.copied.delete(this.copied.values().next().value as string);
  }

  edit(doc: string, m: Measure): void {
    if (!m.typed && !m.deleted && !m.pasted) return;
    const at = this.now();
    const minute = at.toISOString().slice(0, 16);
    let line = this.open.get(doc);
    if (line && line.minute !== minute) {
      this.close(doc);
      line = undefined;
    }
    if (!line) {
      line = { minute, doc, typed: 0, deleted: 0, pasted: 0, words: 0 };
      this.open.set(doc, line);
    }
    line.typed += m.typed;
    line.deleted += m.deleted;
    line.pasted += m.pasted;
    if (m.pasted && norm(m.pasteText)) {
      const text = m.pasteText;
      const fromWriter = this.copied.has(norm(text));
      this.queue.push({
        paste: at.toISOString(),
        doc,
        chars: text.length,
        words: wordCount(text),
        from: fromWriter ? "writer" : "outside",
        text: text.length > PASTE_KEEP ? `${text.slice(0, PASTE_KEEP)}…` : text,
      });
    }
    this.flushSoon();
  }

  event(doc: string, event: EventKind, detail?: string): void {
    this.queue.push({ event, at: this.now().toISOString(), doc, ...(detail ? { detail } : {}) });
    this.flushSoon();
  }

  private close(doc: string): void {
    const line = this.open.get(doc);
    if (!line) return;
    this.open.delete(doc);
    try {
      line.words = this.opts.words(doc);
    } catch {}
    this.queue.push(line);
  }

  /** Writes within a minute or so; one timer, only while there's something to write. */
  flushSoon(): void {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.flush();
    }, this.opts.delayMs ?? 60_000);
  }

  /** Writes everything collected so far, including the minute still open. */
  flush(): Promise<void> {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    for (const doc of [...this.open.keys()]) this.close(doc);
    const lines = this.queue.splice(0);
    if (!lines.length) return this.writing;
    this.writing = this.writing.then(() => this.opts.append(lines)).catch(() => {
      // Keep them for the next try rather than lose them.
      this.queue.unshift(...lines);
    });
    return this.writing;
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }
}

// ── Reading it back ─────────────────────────────────────────────────────────

export function parseRecord(text: string): RecordLine[] {
  const out: RecordLine[] = [];
  for (const raw of text.split("\n")) {
    const s = raw.trim();
    if (!s) continue;
    try {
      const v = JSON.parse(s);
      if (v && typeof v === "object" && typeof v.doc === "string" && (typeof v.minute === "string" || typeof v.paste === "string" || typeof v.event === "string")) out.push(v);
    } catch {
      // A half-written line (e.g. iCloud mid-sync): skip it.
    }
  }
  return out;
}

export const isMinute = (l: RecordLine): l is MinuteLine => "minute" in l;
export const isPaste = (l: RecordLine): l is PasteLine => "paste" in l;
export const isEvent = (l: RecordLine): l is EventLine => "event" in l;

const minuteTime = (m: string) => Date.parse(`${m}:00Z`);
const lineTime = (l: RecordLine) => (isMinute(l) ? minuteTime(l.minute) : Date.parse(isPaste(l) ? l.paste : l.at));

export type Session = {
  start: number;
  /** End of the last minute with writing in it. */
  end: number;
  minutes: number;
  typed: number;
  deleted: number;
  pasted: number;
  pastes: number;
  wordsStart: number;
  wordsEnd: number;
  docs: string[];
};

export type RecordSummary = {
  first: number | null;
  last: number | null;
  /** Minutes in which something was written (a fair "time spent writing"). */
  minutes: number;
  days: number;
  typed: number;
  deleted: number;
  pasted: number;
  /** Pasted from outside the Writer (moving your own text around doesn't count). */
  pastedOutside: number;
  sessions: Session[];
  pastes: PasteLine[];
  events: EventLine[];
  /** Words over time (all the chosen docs together). */
  series: Array<{ t: number; words: number }>;
};

/** Adds the record up, for one doc or (no `docs`) every doc in it. */
export function summarise(lines: RecordLine[], docs?: Set<string>): RecordSummary {
  const pick = lines.filter((l) => !docs || docs.has(l.doc)).sort((a, b) => lineTime(a) - lineTime(b));
  const sum: RecordSummary = { first: null, last: null, minutes: 0, days: 0, typed: 0, deleted: 0, pasted: 0, pastedOutside: 0, sessions: [], pastes: [], events: [], series: [] };
  const minutesSeen = new Set<string>();
  const days = new Set<string>();
  const wordsNow = new Map<string, number>();
  const total = () => [...wordsNow.values()].reduce((a, b) => a + b, 0);
  let cur: Session | null = null;
  let sessionMinutes = new Set<string>();

  for (const l of pick) {
    const t = lineTime(l);
    if (Number.isNaN(t)) continue;
    sum.first ??= t;
    sum.last = Math.max(sum.last ?? t, isMinute(l) ? t + 60_000 : t);
    if (isPaste(l)) {
      sum.pastes.push(l);
      if (l.from === "outside") sum.pastedOutside += l.chars;
      continue;
    }
    if (isEvent(l)) {
      sum.events.push(l);
      continue;
    }
    if (!minutesSeen.has(l.minute)) {
      minutesSeen.add(l.minute);
      sum.minutes++;
    }
    days.add(new Date(t).toLocaleDateString("en-CA"));
    sum.typed += l.typed;
    sum.deleted += l.deleted;
    sum.pasted += l.pasted;
    const before = total();
    wordsNow.set(l.doc, l.words);
    const after = total();
    if (!cur || t - cur.end > SESSION_GAP_MIN * 60_000) {
      cur = { start: t, end: t + 60_000, minutes: 0, typed: 0, deleted: 0, pasted: 0, pastes: 0, wordsStart: before, wordsEnd: after, docs: [] };
      sum.sessions.push(cur);
      sessionMinutes = new Set();
    }
    if (!sessionMinutes.has(l.minute)) {
      sessionMinutes.add(l.minute);
      cur.minutes++;
    }
    cur.end = Math.max(cur.end, t + 60_000);
    cur.typed += l.typed;
    cur.deleted += l.deleted;
    cur.pasted += l.pasted;
    cur.wordsEnd = after;
    if (!cur.docs.includes(l.doc)) cur.docs.push(l.doc);
    sum.series.push({ t, words: after });
  }
  // Pastes that came before their minute line was written belong to that session too.
  for (const s of sum.sessions) {
    s.pastes = sum.pastes.filter((p) => {
      const t = Date.parse(p.paste);
      return t >= s.start && t < s.end;
    }).length;
  }
  sum.days = days.size;
  return sum;
}

export function durationText(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m ? `${h} h ${m} min` : `${h} h`;
}
