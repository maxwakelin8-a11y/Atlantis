/**
 * @jest-environment jsdom
 */
import { describe, expect, it } from "vitest";
import { createEditor, htmlToMarkdown, markdownToHtml } from "./editor";

const SAMPLE = `# Causes of WWI

The war began in **1914** with *Militarism*, ++Alliances++, ==Imperialism== and ~~luck~~.

## Evidence

- One point
- Two with a [link](https://example.com)
  - nested

1. First
2. Second

- [ ] to do
- [x] done

> A quote from a source.

| Cause | Effect |
| --- | --- |
| Alliances | Chain reaction |

\`code\` and a rule:

---
`;

describe("Writer editor", () => {
  it("renders Markdown to HTML with every supported style", () => {
    const html = markdownToHtml(SAMPLE);
    for (const tag of ["<h1>", "<strong>", "<em>", "<u>", "<mark>", "<s>", "<ul>", "<ol>", 'data-type="taskList"', "<blockquote>", "<table", "<code>", "<hr>", 'href="https://example.com"']) {
      expect(html).toContain(tag);
    }
  });

  it("round-trips Markdown through the editor without losing anything", () => {
    const el = document.createElement("div");
    document.body.append(el);
    const ed = createEditor({ element: el, markdown: SAMPLE, onChange: () => {} });
    const out = ed.getMarkdown();
    ed.destroy();
    // Second pass must be stable (what we save is what we load).
    const el2 = document.createElement("div");
    const ed2 = createEditor({ element: el2, markdown: out, onChange: () => {} });
    expect(ed2.getMarkdown()).toBe(out);
    ed2.destroy();
    for (const bit of ["# Causes of WWI", "**1914**", "++Alliances++", "==Imperialism==", "~~luck~~", "[link](https://example.com)", "- [ ] to do", "- [x] done", "> A quote", "| Alliances", "`code`", "---"]) {
      expect(out).toContain(bit);
    }
  });

  it("turns imported Word HTML into Markdown", () => {
    const md = htmlToMarkdown("<h1>Title</h1><p>Some <b>bold</b> and <i>italic</i>.</p><ul><li>a</li><li>b</li></ul>");
    expect(md).toContain("# Title");
    expect(md).toContain("**bold**");
    expect(md).toContain("*italic*");
    expect(md).toMatch(/- a\n- b/);
  });
});
