/**
 * @jest-environment jsdom
 */
import { describe, expect, it, vi as jest } from "vitest";
import { createEditor } from "./editor";
import { applyToText, previewParts, hitAt, hitsIn, Proofreader, proofKey, textKey, worthChecking, type ProofIssue } from "./proofread";

const PARA = "Imperialism was a big cause becuase the countrys wanted land.";
const ISSUES: ProofIssue[] = [
  { kind: "spelling", quote: "becuase", fix: "because", note: "Spelling." },
  { kind: "spelling", quote: "countrys", fix: "countries", note: "Plural of country." },
];

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("proofread helpers", () => {
  it("skips tiny lines and URLs", () => {
    expect(worthChecking("Hi there")).toBe(false);
    expect(worthChecking("https://example.com/a-long-page")).toBe(false);
    expect(worthChecking(PARA)).toBe(true);
  });
  it("applies a fix to the paragraph text", () => {
    expect(applyToText(PARA, ISSUES[0])).toContain("big cause because the");
  });
});

describe("previewParts", () => {
  const join = (r: ReturnType<typeof previewParts>) => (r ? `${r.lead ? "…" : ""}${r.parts.map((p) => (p.kind === "add" ? `[${p.text}]` : p.text)).join("")}${r.tail ? "…" : ""}` : null);
  it("shows the fixed sentence with only the new words marked", () => {
    const text = "The war began in 1914. Imperialism was a big cause becuase the countrys wanted land. Then it spread.";
    expect(join(previewParts(text, ISSUES[0]))).toBe("Imperialism was a big cause [because] the countrys wanted land.");
  });
  it("marks just the changed words in a rewrite", () => {
    const text = "Germany was angry. Germany wanted colonies. Germany built a navy.";
    const r = previewParts(text, { kind: "flow", quote: "Germany was angry. Germany wanted colonies.", fix: "Germany was angry and wanted colonies.", note: "" });
    expect(join(r)).toBe("Germany was angry [and] wanted colonies.");
  });
  it("trims long sentences and skips advice-only tips", () => {
    const long = `${"word ".repeat(40)}becuase ${"more ".repeat(40)}end.`;
    const r = join(previewParts(long, ISSUES[0]));
    expect(r!.startsWith("…")).toBe(true);
    expect(r!.endsWith("…")).toBe(true);
    expect(previewParts(PARA, { ...ISSUES[0], fix: null })).toBeNull();
  });
});

describe("Proofreader", () => {
  it("checks unchecked paragraphs once, marks them in the editor, and accepts a fix without a re-check", async () => {
    jest.useFakeTimers();
    const call = jest.fn(async (paras: Array<{ id: string; text: string }>) => ({
      results: Object.fromEntries(paras.map((p) => [p.id, p.text === PARA ? ISSUES : []])),
    }));
    const pr = new Proofreader(call, () => {});
    const el = document.createElement("div");
    const ed = createEditor({ element: el, markdown: `${PARA}\n\nThis second paragraph has nothing wrong with it.`, onChange: () => {}, proof: () => true, proofLookup: pr.lookup });

    pr.scan([ed.state.doc], null);
    jest.advanceTimersByTime(3000);
    jest.useRealTimers();
    await flush();
    await flush();
    expect(call).toHaveBeenCalledTimes(1);
    expect(call.mock.calls[0][0]).toHaveLength(2);

    ed.view.dispatch(ed.state.tr.setMeta(proofKey, true));
    const hits = hitsIn(ed.view);
    expect(hits.map((x) => x.quote)).toEqual(["becuase", "countrys"]);
    expect(ed.state.doc.textBetween(hits[0].from, hits[0].to)).toBe("becuase");
    expect(hitAt(ed.view, hits[1].from + 2)?.fix).toBe("countries");

    // Accept the first fix: the new paragraph keeps the other issue and isn't sent again.
    pr.accepted(hits[0].text, hits[0]);
    ed.view.dispatch(ed.state.tr.insertText("because", hits[0].from, hits[0].to));
    expect(hitsIn(ed.view).map((x) => x.quote)).toEqual(["countrys"]);
    expect(pr.isChecked(ed.state.doc.firstChild!.textContent)).toBe(true);

    pr.scan([ed.state.doc], null, true);
    expect(pr.pending).toBe(0);

    // Dismiss hides it.
    pr.dismiss(hitsIn(ed.view)[0]);
    ed.view.dispatch(ed.state.tr.setMeta(proofKey, true));
    expect(hitsIn(ed.view)).toHaveLength(0);
    ed.destroy();
  });

  it("waits for the paragraph being typed to finish its sentence", () => {
    const pr = new Proofreader(async () => ({ results: {} }), () => {});
    const el = document.createElement("div");
    const ed = createEditor({ element: el, markdown: "The causes of the war were many and complicated and", onChange: () => {} });
    pr.scan([ed.state.doc], ed.state.doc.firstChild!.textContent);
    expect(pr.pending).toBe(0);
    pr.scan([ed.state.doc], null);
    expect(pr.pending).toBe(1);
    pr.stop();
    ed.destroy();
  });

  it("keys are stable", () => {
    expect(textKey(PARA)).toBe(textKey(PARA));
    expect(textKey(PARA)).not.toBe(textKey(`${PARA} `));
  });
});
