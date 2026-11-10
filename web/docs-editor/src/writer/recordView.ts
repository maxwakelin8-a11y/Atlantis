import { escapeHtml } from "./compile";
import { durationText, type EventLine, type RecordSummary } from "./record";

/**
 * Atlantis: the writing record as HTML. The same fragment is shown in the Writer (inside
 * `.wr-rec`) and saved as a report (wrapped by `recordReport`). Everything from the record is
 * escaped.
 */

export type RecordViewInfo = {
  /** Project or document name. */
  title: string;
  /** "This document" or "Whole project". */
  scope: string;
  /** Doc path → title, for pastes and sessions in a project view. */
  titleOf: (path: string) => string;
  /** Words in the text now (for the summary line). */
  wordsNow: number;
  /** Versions kept for the doc(s), if known. */
  versions?: number;
  author?: string;
};

const num = (n: number) => n.toLocaleString("en-AU");
const day = (t: number) => new Date(t).toLocaleDateString("en-AU", { weekday: "short", day: "numeric", month: "short", year: "numeric" });
const time = (t: number) => new Date(t).toLocaleTimeString("en-AU", { hour: "numeric", minute: "2-digit" });
const when = (t: number) => `${day(t)}, ${time(t)}`;

const EVENT_TEXT: Record<EventLine["event"], string> = {
  restore: "Restored an older version",
  import: "Imported a file",
  outside: "Changed outside the Writer",
  created: "Created",
};

/** Words over time as a small line chart (x = each minute written, so breaks don't stretch it). */
export function chartSvg(series: RecordSummary["series"]): string {
  if (series.length < 2) return "";
  const W = 640;
  const H = 120;
  const pad = 4;
  const max = Math.max(1, ...series.map((p) => p.words));
  const x = (i: number) => pad + (i / (series.length - 1)) * (W - pad * 2);
  const y = (w: number) => H - pad - (w / max) * (H - pad * 2);
  const pts = series.map((p, i) => `${x(i).toFixed(1)},${y(p.words).toFixed(1)}`).join(" ");
  return `<svg class="rec-chart" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Words over time, from ${num(series[0].words)} to ${num(series[series.length - 1].words)}">
<polyline class="rec-line" points="${pts}" fill="none" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>
<div class="rec-axis"><span>${escapeHtml(day(series[0].t))}</span><span>${num(max)} words at most</span><span>${escapeHtml(day(series[series.length - 1].t))}</span></div>`;
}

export function recordHtml(sum: RecordSummary, info: RecordViewInfo): string {
  if (sum.first === null) {
    return `<p class="rec-empty">Nothing recorded yet. The record fills in as you write in this ${info.scope === "This document" ? "document" : "project"} in Atlantis. Work from before the record started isn't in it.</p>`;
  }
  const added = sum.typed + sum.pastedOutside;
  const typedPct = added ? Math.round((sum.typed / added) * 100) : 100;
  const outsidePastes = sum.pastes.filter((p) => p.from === "outside");
  const movedPastes = sum.pastes.length - outsidePastes.length;
  const stat = (value: string, label: string, sub = "") =>
    `<div class="rec-stat"><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span>${sub ? `<em>${escapeHtml(sub)}</em>` : ""}</div>`;

  const parts: string[] = [];
  parts.push(
    `<p class="rec-lede">${escapeHtml(info.scope)} · recorded from ${escapeHtml(when(sum.first))} to ${escapeHtml(when(sum.last ?? sum.first))} · ${num(info.wordsNow)} words now</p>`,
  );
  parts.push(
    `<div class="rec-stats">${[
      stat(durationText(sum.minutes), "spent writing", "minutes with typing in them"),
      stat(num(sum.sessions.length), sum.sessions.length === 1 ? "session" : "sessions", `on ${num(sum.days)} ${sum.days === 1 ? "day" : "days"}`),
      stat(`${typedPct}%`, "typed by hand", `${num(sum.typed)} characters typed`),
      stat(num(outsidePastes.length), outsidePastes.length === 1 ? "paste from outside" : "pastes from outside", `${num(sum.pastedOutside)} characters`),
      stat(num(sum.deleted), "characters deleted", "rewriting and fixing"),
      info.versions !== undefined ? stat(num(info.versions), info.versions === 1 ? "version kept" : "versions kept", "see History") : "",
    ].join("")}</div>`,
  );
  const chart = chartSvg(sum.series);
  if (chart) parts.push(`<h3>Words over time</h3>${chart}`);

  parts.push(`<h3>Sessions</h3><table class="rec-table"><thead><tr><th>Day</th><th>Time</th><th>Writing</th><th>Typed</th><th>Pasted</th><th>Words</th></tr></thead><tbody>`);
  for (const s of [...sum.sessions].reverse()) {
    const docs = info.scope === "This document" ? "" : `<div class="rec-sub">${escapeHtml(s.docs.map(info.titleOf).join(", "))}</div>`;
    const change = s.wordsEnd - s.wordsStart;
    parts.push(
      `<tr><td>${escapeHtml(day(s.start))}${docs}</td><td>${escapeHtml(`${time(s.start)}–${time(s.end)}`)}</td><td>${escapeHtml(durationText(s.minutes))}</td><td>${num(s.typed)}</td><td>${s.pasted ? num(s.pasted) : "–"}</td><td>${num(s.wordsEnd)} <span class="rec-sub">(${change >= 0 ? "+" : "−"}${num(Math.abs(change))})</span></td></tr>`,
    );
  }
  parts.push(`</tbody></table>`);

  parts.push(`<h3>Pasted text</h3>`);
  if (!outsidePastes.length) parts.push(`<p class="rec-sub">Nothing was pasted in from outside the Writer.</p>`);
  for (const p of [...outsidePastes].reverse()) {
    const doc = info.scope === "This document" ? "" : ` · ${escapeHtml(info.titleOf(p.doc))}`;
    parts.push(
      `<div class="rec-paste"><div class="rec-sub">${escapeHtml(when(Date.parse(p.paste)))}${doc} · ${num(p.words)} words</div><blockquote>${escapeHtml(p.text)}</blockquote></div>`,
    );
  }
  if (movedPastes) parts.push(`<p class="rec-sub">Also ${num(movedPastes)} ${movedPastes === 1 ? "paste" : "pastes"} of text copied inside the Writer (moving your own writing around).</p>`);

  if (sum.events.length) {
    parts.push(`<h3>Other changes</h3><ul class="rec-events">`);
    for (const e of [...sum.events].reverse()) {
      const doc = info.scope === "This document" ? "" : ` · ${escapeHtml(info.titleOf(e.doc))}`;
      parts.push(`<li><span class="rec-sub">${escapeHtml(when(Date.parse(e.at)))}${doc}</span> ${escapeHtml(EVENT_TEXT[e.event] ?? e.event)}${e.detail ? `: ${escapeHtml(e.detail)}` : ""}</li>`);
    }
    parts.push(`</ul>`);
  }
  parts.push(
    `<p class="rec-foot">Kept by Atlantis as you write: characters typed and deleted each minute, every paste, and changes made outside the Writer. Times are in your Mac's time zone. It's a plain file in the project (.writer-record.jsonl), so it shows how the work grew; it isn't tamper-proof.</p>`,
  );
  return parts.join("\n");
}

/** A stand-alone page (for PDF/HTML export). */
export function recordReport(sum: RecordSummary, info: RecordViewInfo): string {
  const made = new Date().toLocaleString("en-AU", { day: "numeric", month: "long", year: "numeric", hour: "numeric", minute: "2-digit" });
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(info.title)}: writing record</title>
<style>
body { font: 11pt/1.45 -apple-system, "Helvetica Neue", Arial, sans-serif; color: #1d1d1f; margin: 0; }
h1 { font-size: 20pt; margin: 0 0 2pt; }
h3 { font-size: 12pt; margin: 18pt 0 6pt; }
.rec-made, .rec-sub, .rec-axis, .rec-lede, .rec-foot { color: #6e6e73; font-size: 9.5pt; }
.rec-stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8pt; margin-top: 10pt; }
.rec-stat { border: 1px solid #d2d2d7; border-radius: 6pt; padding: 8pt; display: flex; flex-direction: column; }
.rec-stat strong { font-size: 16pt; }
.rec-stat em { font-style: normal; color: #6e6e73; font-size: 9pt; }
.rec-chart { width: 100%; height: 110pt; border-bottom: 1px solid #d2d2d7; }
.rec-line { stroke: #2f6fde; }
.rec-axis { display: flex; justify-content: space-between; }
.rec-table { width: 100%; border-collapse: collapse; font-size: 9.5pt; }
.rec-table th, .rec-table td { text-align: left; padding: 4pt 6pt; border-bottom: 1px solid #e5e5ea; vertical-align: top; }
.rec-table tr { break-inside: avoid; }
.rec-paste { break-inside: avoid; margin-bottom: 8pt; }
blockquote { margin: 2pt 0 0; padding: 4pt 8pt; border-left: 3px solid #d2d2d7; white-space: pre-wrap; font-size: 9.5pt; }
.rec-events { padding-left: 14pt; }
.rec-foot { margin-top: 18pt; }
</style></head><body>
<h1>${escapeHtml(info.title)}</h1>
<p class="rec-made">Writing record${info.author ? ` · ${escapeHtml(info.author)}` : ""} · made ${escapeHtml(made)}</p>
${recordHtml(sum, info)}
</body></html>
`;
}
