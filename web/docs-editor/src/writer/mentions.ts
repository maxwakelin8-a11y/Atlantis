// Atlantis M6: @mentioning a bot in a doc. The mention is plain text in the Markdown
// (`@school tighten this paragraph`), so files round-trip unchanged; asking is an explicit action
// (the "Ask School ⌘↩" chip) that sends the request to Swift (`agents.ask`), never on its own.

export type MentionBot = { id: string; name: string; avatar: string };
export type MentionRequest = { bot: string; request: string };

/** Longest request sent (Swift checks the same limit). */
export const MAX_REQUEST = 2000;

const ID_CHAR = /[a-z0-9-]/;

/**
 * The partial bot id being typed right before the cursor (`"sch"` for `… @sch|`), or null.
 * The `@` must start the text or follow a space or "(".
 */
export function mentionQuery(before: string): string | null {
  const m = /(?:^|[\s(])@([a-z0-9-]{0,40})$/.exec(before);
  return m ? m[1] : null;
}

/** Bots whose id or name starts with (then contains) the query, best first. */
export function filterBots(bots: MentionBot[], query: string): MentionBot[] {
  const q = query.toLowerCase();
  if (!q) return bots;
  const rank = (b: MentionBot) => {
    const id = b.id.toLowerCase();
    const name = b.name.toLowerCase();
    if (id.startsWith(q) || name.startsWith(q)) return 2;
    return id.includes(q) || name.includes(q) ? 1 : 0;
  };
  return bots.map((b) => ({ b, r: rank(b) })).filter((x) => x.r > 0).sort((a, b) => b.r - a.r).map((x) => x.b);
}

/**
 * The first `@<bot> <request>` in a paragraph's text where `<bot>` is a known id (same rules as
 * Swift's `AgentMention.parse`). The request runs to the end of the paragraph.
 */
export function findMention(text: string, botIds: string[]): MentionRequest | null {
  const known = new Set(botIds);
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "@") continue;
    if (i > 0 && !/[\s(]/.test(text[i - 1])) continue;
    let j = i + 1;
    let id = "";
    while (j < text.length && ID_CHAR.test(text[j])) id += text[j++];
    if (!known.has(id) || j >= text.length || !/\s/.test(text[j])) continue;
    const request = text.slice(j).trim();
    if (!request) continue;
    return { bot: id, request: request.slice(0, MAX_REQUEST) };
  }
  return null;
}
