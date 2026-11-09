/**
 * @jest-environment jsdom
 */
import { describe, expect, it } from "vitest";
import type { BinderNode } from "./api";
import { countWords, docsUnder, excerpt, findNode, parentOf, wordsUnder } from "./api";
import { collectSections, compile, htmlToText, shiftHeadings, type CompileOptions } from "./compile";
import { guessTemplate, itemsForAssessment, taskSheetMarkdown, templateById, TEMPLATES } from "./templates";

const doc = (path: string, body: string, meta: BinderNode["meta"] = {}): BinderNode => ({
  path,
  kind: "doc",
  title: path.split("/").pop()!.replace(/\.md$/, ""),
  meta,
  body,
});
const folder = (path: string, children: BinderNode[], meta: BinderNode["meta"] = {}): BinderNode => ({
  path,
  kind: "folder",
  title: path.split("/").pop()!,
  meta,
  children,
});

const draft = folder("Draft", [
  doc("Draft/Introduction.md", "The war began in **1914**."),
  folder("Draft/Method", [doc("Draft/Method/Participants.md", "## Who\n\nTwenty students."), doc("Draft/Method/Skipped.md", "secret", { compile: false })]),
  doc("Draft/References.md", "Smith, J. (2020). *Causes*. Press."),
]);
const tree: BinderNode[] = [{ ...draft, role: "draft" }, { ...folder("Research", [doc("Research/Notes.md", "x")]), role: "research" }];

// A stand-in for the editor's Markdown renderer.
const toHtml = (md: string) =>
  md
    .split(/\n\n+/)
    .map((b) => (/^#+ /.test(b) ? b.replace(/^(#+) (.*)$/, (_m, h: string, t: string) => `<h${h.length}>${t}</h${h.length}>`) : `<p>${b.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")}</p>`))
    .join("");

const opts = (over: Partial<CompileOptions> = {}): CompileOptions => ({
  format: "docx",
  preset: "apa",
  titlePage: true,
  sectionTitles: true,
  pageNumbers: true,
  wordCount: true,
  info: { title: "Causes of WWI", author: "Max", subject: "History", teacher: "Mr Smith", school: "Samaritan", date: "10 November 2026" },
  ...over,
});

describe("tree helpers", () => {
  it("finds nodes, parents, docs and words", () => {
    expect(findNode(tree, "Draft/Method/Participants.md")?.title).toBe("Participants");
    expect(parentOf(tree, "Draft/Method/Participants.md")?.path).toBe("Draft/Method");
    expect(docsUnder(tree[0]).map((d) => d.title)).toEqual(["Introduction", "Participants", "Skipped", "References"]);
    expect(wordsUnder(tree[0])).toBe(5 + 3 + 1 + 5);
    expect(wordsUnder(tree[0], true)).toBe(13);
    expect(countWords("It's **bold** — [a link](http://x.y)")).toBe(4);
    expect(excerpt("# Head\n\nSome *text* here", 12)).toBe("Head Some t…");
  });
});

describe("compile", () => {
  it("shifts a document's own headings under its binder heading", () => {
    expect(shiftHeadings("# A\n```\n# not\n```\n## B", 2)).toBe("### A\n```\n# not\n```\n#### B");
  });

  it("skips excluded docs and nests headings by depth", () => {
    const s = collectSections(tree[0].children!, true);
    expect(s.map((x) => [x.title, x.level])).toEqual([
      ["Introduction", 1],
      ["Method", 1],
      ["Participants", 2],
      ["References", 1],
    ]);
    expect(s[2].body).toBe("#### Who\n\nTwenty students.");
  });

  it("builds an APA paper with title page, references and word count", () => {
    const r = compile(tree[0].children!, opts(), toHtml);
    expect(r.words).toBe(13);
    expect(r.html).toContain('<p class="tp-title">Causes of WWI</p>');
    expect(r.html).toContain("<h1>Method</h1>");
    expect(r.html).toContain("<h2>Participants</h2>");
    expect(r.html).toContain('<div class="refs">');
    expect(r.html).toContain("line-height: 2");
    expect(r.html).toContain("@top-right");
    expect(r.html).not.toContain("secret");
    expect(r.html).toContain("Word count: 13");
    expect(r.markdown.startsWith("# Causes of WWI\n\nMax · History · Mr Smith · Samaritan · 10 November 2026")).toBe(true);
    expect(r.markdown).toContain("## Method");
    expect(r.markdown).toContain("### Participants");
    expect(r.text).toContain("The war began in 1914.");
  });

  it("escapes titles and strips scripts from bodies", () => {
    const evil: BinderNode[] = [{ ...doc("Draft/x.md", "<script>alert(1)</script>hello"), title: "<b>x</b>" }];
    const r = compile(evil, opts({ titlePage: false, info: { ...opts().info, title: "<i>T</i>" } }), (md) => md);
    expect(r.html).toContain("&lt;b&gt;x&lt;/b&gt;");
    expect(r.html).not.toContain("<script>");
    expect(r.html).toContain("<title>&lt;i&gt;T&lt;/i&gt;</title>");
  });

  it("MLA puts the heading block on page one and calls references Works Cited", () => {
    const r = compile(tree[0].children!, opts({ preset: "mla" }), toHtml);
    expect(r.html).toContain('<div class="mla-head">');
    expect(r.html).not.toContain('class="title-page"');
    expect(r.html).toContain("Works Cited");
  });

  it("plain text keeps bullets and paragraphs", () => {
    expect(htmlToText("<p>One</p><ul><li>a</li><li>b</li></ul><p>Two</p>")).toBe("One\n\n• a\n\n• b\n\nTwo\n");
  });
});

describe("templates", () => {
  it("every template has items under Draft, Research or Notes", () => {
    for (const t of TEMPLATES) {
      expect(t.items.length).toBeGreaterThan(0);
      for (const i of t.items) expect(i.path).toMatch(/^(Draft|Research|Notes)\//);
    }
    expect(templateById("nope").id).toBe("blank");
  });

  it("guesses a template from an assessment title", () => {
    expect(guessTemplate("Persuasive Speeches Unit")).toBe("speech");
    expect(guessTemplate("Acid and Bases practical")).toBe("report");
    expect(guessTemplate("Mid-Year BrightPath Narrative")).toBe("story");
    expect(guessTemplate("Causes of WWI Essay")).toBe("essay");
  });

  it("turns SEQTA assessment details into a task sheet", () => {
    const details = {
      description: "<p>Write an essay on the <b>MAIN</b> causes.</p>",
      criteria: [
        {
          rubric: {
            lines: [
              { title: "Knowledge", content: "Explain", descriptors: [{ content: "Explain, analyse and evaluate" }, { content: "Explain" }] },
              { title: "Old", deleted: true, descriptors: [{ content: "gone" }] },
            ],
          },
        },
      ],
      resources: [{ name: "Essay plan.pdf" }, { userfile: { filename: "Harvard.pptx" } }],
    };
    const a = { id: 1, title: "Causes of WWI Essay", subject: "History", due: "2026-11-10", metaclass: 2 };
    const md = taskSheetMarkdown(a, details);
    expect(md).toContain("**History** · due **2026-11-10**");
    expect(md).toContain("Write an essay on the MAIN causes.");
    expect(md).toContain("- **Knowledge:** Explain, analyse and evaluate");
    expect(md).not.toContain("gone");
    expect(md).toContain("- Essay plan.pdf");
    expect(md).toContain("- Harvard.pptx");

    const { items, settings } = itemsForAssessment(templateById("essay"), a, details);
    const sheets = items.filter((i) => i.path === "Research/Task sheet");
    expect(sheets).toHaveLength(1);
    expect(sheets[0].body).toBe(md);
    expect(settings).toMatchObject({ subject: "History", deadline: "2026-11-10", template: "essay" });
  });
});
