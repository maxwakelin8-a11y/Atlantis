import { describe, expect, it, test } from "vitest";
import { diffSummary, diffWords, plainText, textStats } from "./stats";

describe("writer stats", () => {
  it("strips Markdown to text", () => {
    expect(plainText("## Title\n\n- **Bold** item\n> quote ==hi==")).toBe("Title\n\nBold item\nquote hi");
  });

  it("counts words, sentences and paragraphs", () => {
    const s = textStats("The war began in 1914. It ended in 1918!\n\nA second paragraph here.");
    expect(s.words).toBe(13);
    expect(s.sentences).toBe(3);
    expect(s.paragraphs).toBe(2);
    expect(s.readingEase).toBeNull(); // too short to judge
  });

  it("rates easy text above dense text", () => {
    const easy = textStats("The cat sat on the mat. ".repeat(10)).readingEase ?? 0;
    const dense = textStats("Notwithstanding considerable historiographical disagreement, interpretations emphasising militarisation predominate. ".repeat(5)).readingEase ?? 100;
    expect(easy).toBeGreaterThan(dense);
  });

  it("diffs words", () => {
    const parts = diffWords("the alliance system caused the war", "the alliance system turned a crisis into the war");
    expect(parts.map((p) => p.kind)).toEqual(["same", "del", "add", "same"]);
    expect(diffSummary(parts)).toEqual({ added: 4, removed: 1 });
    expect(diffWords("same", "same")).toEqual([{ kind: "same", text: "same" }]);
  });
});
