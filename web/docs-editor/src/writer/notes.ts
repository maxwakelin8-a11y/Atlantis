/**
 * Atlantis: notes to self inside the text. A note is a fenced block with the info string `note`:
 *
 *   ```note
 *   Ask Ms K whether the intro can be 200 words.
 *   ```
 *
 * The Writer shows it as a sticky note; exports leave it out and it doesn't count as words.
 * Other Markdown apps show it as a small code block, so it stays readable and obviously separate.
 */

export const NOTE_LANG = "note";

const OPEN = /^(\s*)(`{3,}|~{3,})[ \t]*note(?:[ \t].*)?$/i;

/** The Markdown without any note blocks (for exports). */
export function stripNotes(markdown: string): string {
  if (!/note/i.test(markdown)) return markdown;
  const lines = markdown.split("\n");
  const out: string[] = [];
  let removed = false;
  for (let i = 0; i < lines.length; i++) {
    const m = OPEN.exec(lines[i].replace(/\r$/, ""));
    if (!m) {
      out.push(lines[i]);
      continue;
    }
    const fence = m[2];
    const close = new RegExp(`^\\s*${fence[0] === "`" ? "`" : "~"}{${fence.length},}\\s*$`);
    let j = i + 1;
    while (j < lines.length && !close.test(lines[j].replace(/\r$/, ""))) j++;
    // An unclosed fence runs to the end of the text (as in CommonMark).
    i = j;
    removed = true;
    // Don't leave two blank lines where the note was.
    if (out.length && out[out.length - 1].trim() === "" && lines[i + 1]?.trim() === "") i++;
  }
  if (!removed) return markdown;
  return out.join("\n").replace(/^\s*\n/, "");
}

/** How many notes a doc has. */
export function countNotes(markdown: string | undefined): number {
  let n = 0;
  for (const line of String(markdown ?? "").split("\n")) if (OPEN.test(line.replace(/\r$/, ""))) n++;
  return n;
}
