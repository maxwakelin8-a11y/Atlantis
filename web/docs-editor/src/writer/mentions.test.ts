import { describe, expect, it } from "vitest";
import { filterBots, findMention, mentionQuery, MAX_REQUEST } from "./mentions";

const bots = [
  { id: "school", name: "School", avatar: "🎓" },
  { id: "builder", name: "Builder", avatar: "🛠️" },
  { id: "coach", name: "Coach", avatar: "🧭" },
];

describe("mentionQuery", () => {
  it("finds the id being typed after @", () => {
    expect(mentionQuery("@")).toBe("");
    expect(mentionQuery("Hi @sch")).toBe("sch");
    expect(mentionQuery("(@b")).toBe("b");
  });
  it("ignores emails and finished mentions", () => {
    expect(mentionQuery("me@school")).toBeNull();
    expect(mentionQuery("@school ")).toBeNull();
    expect(mentionQuery("no at here")).toBeNull();
  });
});

describe("filterBots", () => {
  it("ranks prefix matches first", () => {
    expect(filterBots(bots, "").map((b) => b.id)).toEqual(["school", "builder", "coach"]);
    expect(filterBots(bots, "c").map((b) => b.id)).toEqual(["coach", "school"]);
    expect(filterBots(bots, "zzz")).toEqual([]);
  });
});

describe("findMention", () => {
  const ids = bots.map((b) => b.id);
  it("reads the bot and the rest of the paragraph", () => {
    expect(findMention("@school what's due for this essay?", ids)).toEqual({ bot: "school", request: "what's due for this essay?" });
    expect(findMention("Note to self. @builder  tighten the intro ", ids)).toEqual({ bot: "builder", request: "tighten the intro" });
  });
  it("needs a known bot, a space before the @ and a request", () => {
    expect(findMention("@scout find sources", ids)).toBeNull();
    expect(findMention("email me@school about it", ids)).toBeNull();
    expect(findMention("@school", ids)).toBeNull();
    expect(findMention("@school   ", ids)).toBeNull();
    expect(findMention("@schoolwork is hard", ids)).toBeNull();
  });
  it("takes the first known mention and caps the request", () => {
    expect(findMention("@nobody hi @coach plan my week", ids)).toEqual({ bot: "coach", request: "plan my week" });
    expect(findMention("@coach " + "x".repeat(MAX_REQUEST + 50), ids)?.request.length).toBe(MAX_REQUEST);
  });
});
