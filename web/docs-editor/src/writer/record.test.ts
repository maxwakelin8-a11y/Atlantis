import { describe, expect, it } from "vitest";
import { Slice, Fragment } from "@tiptap/pm/model";
import { createEditor } from "./editor";
import { measure, parseRecord, RecordKeeper, summarise, type RecordLine } from "./record";
import { recordHtml, recordReport } from "./recordView";

const mount = (markdown: string) => createEditor({ element: document.createElement("div"), markdown, onChange: () => {} });

describe("measure", () => {
  it("counts typing and deleting", () => {
    const ed = mount("Hello world\n");
    const tr = ed.state.tr.insertText("big ", 7);
    expect(measure(tr)).toMatchObject({ typed: 4, deleted: 0, pasted: 0 });
    const del = ed.state.tr.delete(1, 6);
    expect(measure(del)).toMatchObject({ typed: 0, deleted: 5 });
  });

  it("counts pastes separately and keeps the text", () => {
    const ed = mount("Hello\n");
    const text = ed.state.schema.text("pasted words here");
    const tr = ed.state.tr.replace(6, 6, new Slice(Fragment.from(text), 0, 0)).setMeta("uiEvent", "paste");
    expect(measure(tr)).toMatchObject({ typed: 0, pasted: 17, pasteText: "pasted words here" });
  });

  it("doesn't count undo as typing", () => {
    const ed = mount("Hello\n");
    const tr = ed.state.tr.insertText("x", 2).setMeta("history$", { redo: false });
    expect(measure(tr)).toMatchObject({ typed: 0, pasted: 0 });
  });
});

describe("RecordKeeper", () => {
  const setup = () => {
    let now = new Date("2026-11-11T05:42:10Z");
    const written: RecordLine[] = [];
    const keeper = new RecordKeeper({
      append: async (lines) => void written.push(...lines),
      words: () => 120,
      now: () => now,
      delayMs: 10_000_000,
    });
    return { keeper, written, at: (iso: string) => (now = new Date(iso)) };
  };

  it("adds edits up per minute and per doc", async () => {
    const { keeper, written, at } = setup();
    keeper.edit("Draft/A.md", { typed: 5, deleted: 1, pasted: 0, pasteText: "" });
    keeper.edit("Draft/A.md", { typed: 3, deleted: 0, pasted: 0, pasteText: "" });
    at("2026-11-11T05:43:01Z");
    keeper.edit("Draft/A.md", { typed: 2, deleted: 0, pasted: 0, pasteText: "" });
    await keeper.flush();
    expect(written).toEqual([
      { minute: "2026-11-11T05:42", doc: "Draft/A.md", typed: 8, deleted: 1, pasted: 0, words: 120 },
      { minute: "2026-11-11T05:43", doc: "Draft/A.md", typed: 2, deleted: 0, pasted: 0, words: 120 },
    ]);
  });

  it("logs pastes, telling text copied inside the Writer apart", async () => {
    const { keeper, written } = setup();
    keeper.copiedText("my own  sentence");
    keeper.edit("Draft/A.md", { typed: 0, deleted: 0, pasted: 15, pasteText: "my own sentence" });
    keeper.edit("Draft/A.md", { typed: 0, deleted: 0, pasted: 9, pasteText: "from web!" });
    await keeper.flush();
    const pastes = written.filter((l) => "paste" in l);
    expect(pastes).toMatchObject([
      { from: "writer", chars: 15, words: 3 },
      { from: "outside", chars: 9, words: 2, text: "from web!" },
    ]);
  });

  it("keeps lines when writing fails and tries again", async () => {
    let fail = true;
    const written: RecordLine[] = [];
    const keeper = new RecordKeeper({
      append: async (lines) => {
        if (fail) throw new Error("disk");
        written.push(...lines);
      },
      words: () => 1,
      delayMs: 10_000_000,
    });
    keeper.event("Draft/A.md", "restore");
    await keeper.flush();
    fail = false;
    await keeper.flush();
    expect(written).toHaveLength(1);
  });
});

describe("summarise", () => {
  const lines = parseRecord(
    [
      '{"minute":"2026-11-10T07:00","doc":"Draft/A.md","typed":100,"deleted":10,"pasted":0,"words":20}',
      '{"minute":"2026-11-10T07:01","doc":"Draft/A.md","typed":50,"deleted":0,"pasted":40,"words":35}',
      '{"paste":"2026-11-10T07:01:30.000Z","doc":"Draft/A.md","chars":40,"words":7,"from":"outside","text":"a quote <b>from</b> a site"}',
      '{"minute":"2026-11-10T09:00","doc":"Draft/B.md","typed":30,"deleted":0,"pasted":0,"words":6}',
      '{"event":"outside","at":"2026-11-10T09:30:00.000Z","doc":"Draft/B.md","detail":"6 → 9 words"}',
      "not json",
      "",
    ].join("\n"),
  );

  it("skips broken lines", () => expect(lines).toHaveLength(5));

  it("finds sessions, time, typed and pasted for the project", () => {
    const s = summarise(lines);
    expect(s.minutes).toBe(3);
    expect(s.sessions).toHaveLength(2);
    expect(s.sessions[0]).toMatchObject({ minutes: 2, typed: 150, pasted: 40, pastes: 1, wordsStart: 0, wordsEnd: 35 });
    expect(s.sessions[1]).toMatchObject({ minutes: 1, wordsStart: 35, wordsEnd: 41 });
    expect(s.typed).toBe(180);
    expect(s.pastedOutside).toBe(40);
    expect(s.events).toHaveLength(1);
    expect(s.series.map((p) => p.words)).toEqual([20, 35, 41]);
  });

  it("can look at one doc", () => {
    const s = summarise(lines, new Set(["Draft/B.md"]));
    expect(s.typed).toBe(30);
    expect(s.pastes).toHaveLength(0);
    expect(s.events).toHaveLength(1);
  });

  it("renders escaped HTML and a report", () => {
    const info = { title: "Essay <1>", scope: "Whole project", titleOf: (p: string) => p, wordsNow: 41 };
    const html = recordHtml(summarise(lines), info);
    expect(html).toContain("a quote &lt;b&gt;from&lt;/b&gt; a site");
    expect(html).not.toContain("<b>from</b>");
    expect(html).toContain("<strong>2</strong><span>sessions</span>");
    const report = recordReport(summarise(lines), info);
    expect(report).toContain("<title>Essay &lt;1&gt;: writing record</title>");
    expect(recordHtml(summarise([]), info)).toContain("Nothing recorded yet");
  });
});
