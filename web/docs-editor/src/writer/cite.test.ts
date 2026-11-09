import { describe, expect, it, test } from "vitest";
import { addToReferenceList, formatReference, inTextCitation, textToAuthors, type Reference } from "./cite";

const web: Reference = {
  kind: "webpage",
  authors: [{ given: "Jane Anne", family: "Smith" }],
  title: "Why the war began",
  container: "Example Times",
  year: "2024",
  month: 4,
  day: 25,
  url: "https://example.com/why",
  accessed: "2026-11-05",
};
const article: Reference = {
  kind: "article",
  authors: [{ given: "Yann", family: "LeCun" }, { given: "Yoshua", family: "Bengio" }, { given: "Geoffrey", family: "Hinton" }],
  title: "Deep learning",
  container: "Nature",
  year: "2015",
  volume: "521",
  issue: "7553",
  pages: "436–444",
  doi: "10.1038/nature14539",
};
const noAuthor: Reference = { kind: "webpage", authors: [], title: "Gallipoli", container: "Australian War Memorial", year: "2023", url: "https://www.awm.gov.au/g", accessed: "2026-11-05" };

describe("reference maker", () => {
  it("formats Harvard", () => {
    expect(formatReference(web, "harvard")).toBe("Smith, J.A. (2024) *Why the war began*. Example Times. Available at: https://example.com/why (Accessed: 5 November 2026).");
    expect(formatReference(article, "harvard")).toBe("LeCun, Y., Bengio, Y. and Hinton, G. (2015) 'Deep learning', *Nature*, 521(7553), pp. 436–444. Available at: https://doi.org/10.1038/nature14539.");
    expect(formatReference(noAuthor, "harvard")).toBe("Australian War Memorial (2023) *Gallipoli*. Available at: https://www.awm.gov.au/g (Accessed: 5 November 2026).");
    expect(inTextCitation(article, "harvard", "437")).toBe("(LeCun et al., 2015, p. 437)");
  });

  it("formats APA 7", () => {
    expect(formatReference(web, "apa")).toBe("Smith, J. A. (2024, April 25). *Why the war began*. Example Times. https://example.com/why");
    expect(formatReference(article, "apa")).toBe("LeCun, Y., Bengio, Y., & Hinton, G. (2015). Deep learning. *Nature*, *521*(7553), 436–444. https://doi.org/10.1038/nature14539");
    expect(inTextCitation({ ...web, authors: [...web.authors, { family: "Lee", given: "Tom" }] }, "apa")).toBe("(Smith & Lee, 2024)");
  });

  it("formats MLA 9 and Chicago", () => {
    expect(formatReference(web, "mla")).toBe('Smith, Jane Anne. "Why the war began." *Example Times*, 25 Apr. 2024, example.com/why. Accessed 5 Nov. 2026.');
    expect(inTextCitation(web, "mla", "4")).toBe("(Smith 4)");
    expect(formatReference(article, "chicago")).toBe('LeCun, Yann, Yoshua Bengio, and Geoffrey Hinton. 2015. "Deep learning." *Nature* 521, no. 7553: 436–444. https://doi.org/10.1038/nature14539.');
    expect(inTextCitation(noAuthor, "chicago")).toBe('("Gallipoli" 2023)');
  });

  it("keeps the list A–Z without duplicates", () => {
    let body = "";
    body = addToReferenceList(body, "Smith, J. (2024) *B*.").body;
    body = addToReferenceList(body, "Adams, K. (2020) *A*.").body;
    body = addToReferenceList(body, "*The Zebra* (2001).").body;
    expect(body).toBe("Adams, K. (2020) *A*.\n\nSmith, J. (2024) *B*.\n\n*The Zebra* (2001).\n");
    expect(addToReferenceList(body, "Adams, K. (2020) *A*.").added).toBe(false);
    expect(addToReferenceList("# References\n\nZed (1).", "Abe (2).").body).toBe("# References\n\nAbe (2).\n\nZed (1).\n");
  });

  it("reads typed authors", () => {
    expect(textToAuthors("Clark, Christopher\nMargaret MacMillan\nAustralian War Memorial")).toEqual([
      { family: "Clark", given: "Christopher" },
      { given: "Margaret", family: "MacMillan" },
      { literal: "Australian War Memorial" },
    ]);
  });
});
