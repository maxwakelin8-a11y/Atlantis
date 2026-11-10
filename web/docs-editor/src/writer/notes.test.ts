import { describe, expect, it } from "vitest";
import { countNotes, stripNotes } from "./notes";
import { compile } from "./compile";
import { countWords, type BinderNode } from "./api";
import { createEditor } from "./editor";

const DOC = "Intro paragraph.\n\n```note\nAsk Ms K about the word limit.\n```\n\nBody paragraph.\n";

describe("notes to self", () => {
  it("are left out of the text", () => {
    expect(stripNotes(DOC)).toBe("Intro paragraph.\n\nBody paragraph.\n");
    expect(stripNotes("~~~~ note\na\n~~~~\nafter")).toBe("after");
    expect(stripNotes("```Note\nunclosed note runs to the end")).toBe("");
  });

  it("leave other code blocks and text alone", () => {
    const md = "```js\nnote = 1\n```\n\nA note about notes.\n";
    expect(stripNotes(md)).toBe(md);
    expect(stripNotes("````note\n```\nstill inside\n````\nend")).toBe("end");
  });

  it("are counted and don't count as words", () => {
    expect(countNotes(DOC)).toBe(1);
    expect(countWords(DOC)).toBe(4);
  });

  it("never reach an export", () => {
    const doc: BinderNode = { path: "Draft/A.md", kind: "doc", title: "A", meta: {}, body: DOC };
    const r = compile([doc], {
      format: "md", preset: "clean", titlePage: false, sectionTitles: false, pageNumbers: false, wordCount: true,
      info: { title: "T", author: "", subject: "", teacher: "", school: "", date: "" },
    }, (md) => `<p>${md}</p>`);
    expect(r.markdown).not.toContain("Ms K");
    expect(r.html).not.toContain("Ms K");
    expect(r.words).toBe(4);
  });

  it("round-trip byte for byte in the editor", () => {
    const ed = createEditor({ element: document.createElement("div"), markdown: DOC, onChange: () => {} });
    expect(ed.getMarkdown()).toBe(DOC);
    let found = false;
    ed.state.doc.descendants((n) => {
      if (n.type.name === "codeBlock" && n.attrs.language === "note") found = true;
    });
    expect(found).toBe(true);
  });

  it("can be added with the note command and saved as a ```note fence", () => {
    const ed = createEditor({ element: document.createElement("div"), markdown: "First.\n", onChange: () => {} });
    ed.commands.setTextSelection(ed.state.doc.content.size - 1);
    ed.chain().focus().insertContent({ type: "paragraph" }).setCodeBlock({ language: "note" }).insertContent("check this").run();
    expect(ed.getMarkdown()).toContain("```note\ncheck this\n```");
  });
});
