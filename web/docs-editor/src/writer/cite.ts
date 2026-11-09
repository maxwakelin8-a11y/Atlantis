/**
 * Reference maker: turns the details seqta-mcp reads off a link (or that the student types) into a
 * reference-list entry and an in-text citation in Harvard, APA 7, MLA 9 or Chicago (author-date).
 * Output is Markdown (titles in *italics*) so it drops straight into a document.
 */

export type Person = { family?: string; given?: string; literal?: string };
export type RefKind = "webpage" | "article" | "book" | "video" | "report";

export type Reference = {
  id?: string;
  kind: RefKind;
  authors: Person[];
  title: string;
  /** Website name, or the journal for an article. */
  container?: string;
  publisher?: string;
  year?: string;
  month?: number;
  day?: number;
  volume?: string;
  issue?: string;
  pages?: string;
  doi?: string;
  url?: string;
  /** ISO date the page was read (YYYY-MM-DD). */
  accessed?: string;
  /** Set by the lookup when the site blocked it and only the link was used. */
  partial?: boolean;
  note?: string;
};

export type CiteStyle = "harvard" | "apa" | "mla" | "chicago";

export const CITE_STYLES: Array<{ id: CiteStyle; name: string; hint: string }> = [
  { id: "harvard", name: "Harvard", hint: "Most Australian schools" },
  { id: "apa", name: "APA 7", hint: "Science & social science" },
  { id: "mla", name: "MLA 9", hint: "English & humanities" },
  { id: "chicago", name: "Chicago", hint: "History (author-date)" },
];

export const REF_KINDS: Array<{ id: RefKind; name: string }> = [
  { id: "webpage", name: "Web page" },
  { id: "article", name: "Journal article" },
  { id: "book", name: "Book" },
  { id: "video", name: "Video" },
  { id: "report", name: "Report / PDF" },
];

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const MLA_MONTHS = ["Jan.", "Feb.", "Mar.", "Apr.", "May", "June", "July", "Aug.", "Sept.", "Oct.", "Nov.", "Dec."];

/** Escapes characters that would turn into Markdown formatting. */
const esc = (s: string) => s.replace(/([\\*_`[\]<>])/g, "\\$1");
const it = (s: string) => (s ? `*${esc(s)}*` : "");
const end = (s: string) => (/[.?!]$/.test(s) ? s : `${s}.`);
const clean = (s?: string) => (s ?? "").replace(/\s+/g, " ").trim();

function initials(given = "", spaced: boolean): string {
  const parts = given.split(/[\s.]+/).filter(Boolean).map((p) => (p.includes("-") ? p.split("-").map((x) => `${x[0]}.`).join("-") : `${p[0].toUpperCase()}.`));
  return parts.join(spaced ? " " : "");
}

const isOrg = (p: Person) => !!p.literal || !p.family;
const familyOf = (p: Person) => clean(p.literal || p.family || p.given);

/** No named author: a web page is credited to its site (an organisation), Wikipedia to nobody. */
function creditedAuthors(r: Reference): Person[] {
  const named = r.authors.filter((p) => clean(p.literal || p.family || p.given));
  if (named.length) return named;
  if ((r.kind === "webpage" || r.kind === "report") && r.container && !/wikipedia/i.test(r.container)) return [{ literal: r.container }];
  return [];
}

function joinNames(names: string[], and: string, oxford: boolean): string {
  if (names.length <= 1) return names[0] ?? "";
  if (names.length === 2) return `${names[0]}${oxford ? "," : ""} ${and} ${names[1]}`;
  return `${names.slice(0, -1).join(", ")}${oxford ? "," : ""} ${and} ${names[names.length - 1]}`;
}

function listAuthors(people: Person[], style: CiteStyle): string {
  if (!people.length) return "";
  if (style === "harvard") return joinNames(people.map((p) => (isOrg(p) ? familyOf(p) : `${clean(p.family)}, ${initials(p.given, false)}`.replace(/, $/, ""))), "and", false);
  if (style === "apa") {
    const names = people.map((p) => (isOrg(p) ? familyOf(p) : `${clean(p.family)}, ${initials(p.given, true)}`.replace(/, $/, "")));
    if (names.length > 20) return `${names.slice(0, 19).join(", ")}, . . . ${names[names.length - 1]}`;
    return names.length === 2 ? `${names[0]}, & ${names[1]}` : names.length > 2 ? `${names.slice(0, -1).join(", ")}, & ${names[names.length - 1]}` : names[0];
  }
  // MLA and Chicago: first author inverted, the rest First Last.
  const first = people[0];
  const firstName = isOrg(first) ? familyOf(first) : [clean(first.family), clean(first.given)].filter(Boolean).join(", ");
  const rest = people.slice(1).map((p) => (isOrg(p) ? familyOf(p) : [clean(p.given), clean(p.family)].filter(Boolean).join(" ")));
  if (style === "mla") {
    if (people.length >= 3) return `${firstName}, et al`;
    return rest.length ? `${firstName}, and ${rest[0]}` : firstName;
  }
  if (people.length > 10) return `${firstName}, ${rest.slice(0, 6).join(", ")}, et al`;
  return joinNames([firstName, ...rest], "and", true);
}

function prettyDate(r: Reference, style: CiteStyle): string {
  if (!r.year) return "";
  const m = r.month ? r.month - 1 : -1;
  if (style === "apa") return m >= 0 ? `${r.year}, ${MONTHS[m]}${r.day ? ` ${r.day}` : ""}` : r.year;
  if (style === "mla") return m >= 0 ? `${r.day ? `${r.day} ` : ""}${MLA_MONTHS[m]} ${r.year}` : r.year;
  if (style === "chicago") return m >= 0 ? `${MONTHS[m]}${r.day ? ` ${r.day},` : ""} ${r.year}` : r.year;
  return r.year;
}

function accessedDate(r: Reference, style: CiteStyle): string {
  const iso = r.accessed || new Date().toISOString().slice(0, 10);
  const [y, mo, d] = iso.split("-").map(Number);
  if (style === "mla") return `${d} ${MLA_MONTHS[mo - 1]} ${y}`;
  if (style === "harvard") return `${d} ${MONTHS[mo - 1]} ${y}`;
  return `${MONTHS[mo - 1]} ${d}, ${y}`;
}

const doiUrl = (r: Reference) => (r.doi ? `https://doi.org/${r.doi.replace(/^https?:\/\/(dx\.)?doi\.org\//i, "")}` : "");
const link = (r: Reference) => doiUrl(r) || clean(r.url);

/** One reference-list entry, as Markdown. */
export function formatReference(r: Reference, style: CiteStyle): string {
  const people = creditedAuthors(r);
  const authors = listAuthors(people, style);
  const title = clean(r.title) || "Untitled";
  const site = clean(r.container);
  const siteIfDifferent = site && !people.some((p) => familyOf(p).toLowerCase() === site.toLowerCase()) ? site : "";
  const url = link(r);
  const isArticle = r.kind === "article";
  const isBook = r.kind === "book";
  const videoTag = r.kind === "video" ? " [Video]" : "";

  if (style === "harvard") {
    const year = r.year || "no date";
    const lead = authors ? `${authors} (${year})` : `${it(title)}${videoTag} (${year})`;
    if (isArticle) {
      const vol = [r.volume, r.issue ? `(${r.issue})` : ""].join("");
      const bits = [`${authors || it(title)} (${year}) '${esc(title)}'`, it(site), vol, r.pages ? `pp. ${r.pages}` : ""].filter(Boolean).join(", ");
      return `${end(bits)}${r.doi ? ` Available at: ${doiUrl(r)}.` : url ? ` Available at: ${url} (Accessed: ${accessedDate(r, style)}).` : ""}`;
    }
    if (isBook) return `${authors ? `${lead} ${it(title)}.` : `${lead}.`}${r.publisher ? ` ${end(esc(clean(r.publisher)))}` : ""}`;
    const head = authors ? `${lead} ${it(title)}${videoTag}.` : `${lead}.`;
    return `${head}${siteIfDifferent ? ` ${end(esc(siteIfDifferent))}` : ""}${url ? ` Available at: ${url} (Accessed: ${accessedDate(r, style)}).` : ""}`;
  }

  if (style === "apa") {
    // Journal articles and books take the year only; web pages and videos the full date.
    const date = `(${(isArticle || isBook ? r.year : prettyDate(r, "apa")) || "n.d."})`;
    const titlePart = isArticle ? end(esc(title)) : `${it(title)}${videoTag}.`;
    const lead = authors ? `${end(authors)} ${date}. ${titlePart}` : `${titlePart} ${date}.`;
    if (isArticle) {
      const vol = r.volume ? `, ${it(r.volume)}${r.issue ? `(${r.issue})` : ""}` : "";
      return `${lead} ${it(site)}${vol}${r.pages ? `, ${r.pages}` : ""}.${url ? ` ${url}` : ""}`;
    }
    if (isBook) return `${lead}${r.publisher ? ` ${end(esc(clean(r.publisher)))}` : ""}${url && r.doi ? ` ${url}` : ""}`;
    const retrieved = !r.year || /wikipedia/i.test(site) ? `Retrieved ${accessedDate(r, "apa")}, from ${url}` : url;
    return `${lead}${siteIfDifferent ? ` ${end(esc(siteIfDifferent))}` : ""}${url ? ` ${retrieved}` : ""}`;
  }

  const realAuthors = r.authors.filter((p) => clean(p.literal || p.family || p.given));
  const mlaAuthors = listAuthors(realAuthors, style);
  if (style === "mla") {
    const parts: string[] = [];
    if (mlaAuthors) parts.push(end(mlaAuthors));
    if (isBook) {
      parts.push(`${it(title)}.`);
      parts.push(end([r.publisher && esc(clean(r.publisher)), r.year].filter(Boolean).join(", ")));
      return parts.filter((p) => p !== ".").join(" ");
    }
    parts.push(`"${end(esc(title))}"`);
    const where = isArticle
      ? [it(site), r.volume ? `vol. ${r.volume}` : "", r.issue ? `no. ${r.issue}` : "", r.year, r.pages ? `pp. ${r.pages}` : ""]
      : [it(site), prettyDate(r, "mla")];
    const tail = [...where, url.replace(/^https?:\/\//, "")].filter(Boolean).join(", ");
    if (tail) parts.push(end(tail));
    if (!isArticle && url) parts.push(`Accessed ${end(accessedDate(r, "mla"))}`);
    return parts.join(" ");
  }

  // Chicago author-date.
  const year = r.year || "n.d.";
  const head = mlaAuthors ? `${end(mlaAuthors)} ${year}.` : "";
  if (isArticle) {
    const vol = [r.volume, r.issue ? `no. ${r.issue}` : ""].filter(Boolean).join(", ");
    return `${head ? `${head} ` : ""}"${end(esc(title))}"${head ? "" : ` ${year}.`} ${it(site)}${vol ? ` ${vol}` : ""}${r.pages ? `: ${r.pages}` : ""}.${url ? ` ${url}.` : ""}`;
  }
  if (isBook) return `${head ? `${head} ` : ""}${it(title)}.${head ? "" : ` ${year}.`}${r.publisher ? ` ${end(esc(clean(r.publisher)))}` : ""}`;
  const date = prettyDate(r, "chicago");
  return [
    head,
    `"${end(esc(title))}"`,
    head ? "" : `${year}.`,
    r.kind === "video" ? "Video." : "",
    siteIfDifferent ? end(esc(siteIfDifferent)) : "",
    date && r.month ? end(date) : !r.year ? `Accessed ${end(accessedDate(r, "chicago"))}` : "",
    url ? end(url) : "",
  ]
    .filter(Boolean)
    .join(" ");
}

/** The in-text citation, e.g. (Clark, 2012, p. 4) — `where` is an optional page or paragraph. */
export function inTextCitation(r: Reference, style: CiteStyle, where = ""): string {
  const people = style === "mla" || style === "chicago" ? r.authors.filter((p) => clean(p.literal || p.family || p.given)) : creditedAuthors(r);
  const fam = people.map(familyOf);
  const and = style === "apa" ? "&" : "and";
  let who = fam.length === 0 ? "" : fam.length === 1 ? fam[0] : fam.length === 2 ? `${fam[0]} ${and} ${fam[1]}` : `${fam[0]} et al.`;
  if (!who) {
    const words = clean(r.title).split(" ");
    const short = words.length > 6 ? `${words.slice(0, 5).join(" ")}…` : clean(r.title);
    who = style === "mla" || style === "chicago" ? `"${short}"` : it(short);
  }
  const page = clean(where);
  const pageText = page ? (/^\d+(\s*[-–]\s*\d+)?$/.test(page) ? (/[-–]/.test(page) ? `pp. ${page}` : `p. ${page}`) : page) : "";
  if (style === "mla") return `(${[who, page].filter(Boolean).join(" ")})`;
  const year = r.year || (style === "apa" ? "n.d." : style === "chicago" ? "n.d." : "no date");
  if (style === "chicago") return `(${who} ${year}${page ? `, ${page}` : ""})`;
  return `(${who}, ${year}${pageText ? `, ${pageText}` : ""})`;
}

/** Sort key for an A–Z reference list. */
export function sortKey(entry: string): string {
  return entry
    .replace(/^[#>\s*_"'‘“]+/, "")
    .replace(/^(the|a|an)\s+/i, "")
    .toLowerCase();
}

/** Adds an entry to a reference-list body in A–Z order (paragraph per entry); skips duplicates. */
export function addToReferenceList(body: string, entry: string): { body: string; added: boolean } {
  const text = String(body ?? "").replace(/\r\n/g, "\n").trim();
  const blocks = text ? text.split(/\n\s*\n/) : [];
  const norm = (s: string) => s.replace(/\s+/g, " ").trim().toLowerCase();
  if (blocks.some((b) => norm(b) === norm(entry))) return { body: text ? `${text}\n` : "", added: false };
  const headIdx = blocks.findIndex((b) => !/^#{1,6}\s/.test(b));
  const start = headIdx === -1 ? blocks.length : headIdx;
  let at = start;
  while (at < blocks.length && sortKey(blocks[at]) <= sortKey(entry)) at++;
  blocks.splice(at, 0, entry);
  return { body: `${blocks.join("\n\n")}\n`, added: true };
}

/** Authors textarea ⇄ list: one per line, "Surname, First names" or an organisation. */
export function authorsToText(people: Person[]): string {
  return people.map((p) => (p.literal ? p.literal : [p.family, p.given].filter(Boolean).join(", "))).join("\n");
}

export function textToAuthors(text: string): Person[] {
  return text
    .split(/\n|;/)
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => {
      if (l.includes(",")) {
        const [family, given] = l.split(",", 2).map((x) => x.trim());
        return given ? { family, given } : { literal: family };
      }
      // "Christopher Clark" → a person; "Australian War Memorial" → an organisation.
      const words = l.split(/\s+/);
      if (words.length >= 2 && words.length <= 3 && !ORG.test(l) && words.every((w) => /^\p{Lu}[\p{L}'’-]*\.?$/u.test(w)))
        return { given: words.slice(0, -1).join(" "), family: words[words.length - 1] };
      return { literal: l };
    });
}

const ORG = /\b(news|university|college|school|department|government|council|museum|library|archives?|society|institute|foundation|organi[sz]ation|association|agency|cent(re|er)|commission|press|media|war|memorial|national|world|bureau|office|trust|service|group|team|club)\b/i;
