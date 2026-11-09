import type { NewItem, ProjectSettings } from "./api";

/**
 * Project templates, after Scrivener's template chooser but for school work. Each one is a list
 * of binder items (folders and docs, in order) under Draft / Research / Notes. Docs start empty;
 * their synopsis says what goes in them and shows as the editor's placeholder.
 */

export type Template = {
  id: string;
  name: string;
  icon: string;
  description: string;
  /** Export style it starts with. */
  preset: string;
  items: NewItem[];
};

const doc = (path: string, synopsis = "", body = "", extra: Partial<NewItem["meta"]> = {}): NewItem => ({
  path,
  kind: "doc",
  meta: { ...(synopsis ? { synopsis } : {}), ...extra },
  body,
});
const folder = (path: string, synopsis = ""): NewItem => ({
  path,
  kind: "folder",
  meta: synopsis ? { synopsis } : undefined,
});

export const TEMPLATES: Template[] = [
  {
    id: "blank",
    name: "Blank",
    icon: "📄",
    description: "One empty document. Add more as you go.",
    preset: "school",
    items: [doc("Draft/Untitled")],
  },
  {
    id: "essay",
    name: "Essay",
    icon: "✍️",
    description: "Introduction, TEEL body paragraphs, conclusion and references.",
    preset: "school",
    items: [
      doc("Draft/Introduction", "Hook, background, then your thesis (your answer to the question) and the points you'll argue."),
      folder("Draft/Body", "One document per paragraph. Drag to reorder your argument."),
      doc("Draft/Body/Paragraph 1", "Topic sentence · Evidence (quote or fact + source) · Explanation · Link back to the question."),
      doc("Draft/Body/Paragraph 2", "Topic sentence · Evidence · Explanation · Link."),
      doc("Draft/Body/Paragraph 3", "Topic sentence · Evidence · Explanation · Link."),
      doc("Draft/Conclusion", "Restate the thesis in new words, sum up each point, finish with a final thought. No new evidence."),
      doc("Draft/References", "Every source you used, in your school's referencing style (e.g. Harvard), A–Z by author.", "", { label: "References" }),
      doc("Research/Task sheet", "The question, criteria and due date."),
      doc("Research/Sources", "Links, quotes and page numbers as you find them."),
      doc("Notes/Plan", "Thesis in one sentence, then a dot point per paragraph."),
    ],
  },
  {
    id: "apa",
    name: "APA paper",
    icon: "🎓",
    description: "APA 7th edition: title page, abstract, method, results, discussion.",
    preset: "apa",
    items: [
      doc("Draft/Abstract", "150–250 words: the question, what you did, what you found and why it matters."),
      doc("Draft/Introduction", "The problem, what's already known, and your hypothesis."),
      folder("Draft/Method"),
      doc("Draft/Method/Participants", "Who or what was studied, and how they were chosen."),
      doc("Draft/Method/Research Design", "The type of study and the variables."),
      doc("Draft/Method/Measures", "What was measured and how."),
      doc("Draft/Method/Procedure", "Step by step, so someone else could repeat it."),
      doc("Draft/Results", "What you found. Tables and numbers, no interpretation yet."),
      doc("Draft/Discussion", "What the results mean, limits of the study, and what next."),
      doc("Draft/References", "APA 7th: Author, A. A. (Year). Title. Source. — A–Z, hanging indent.", "", { label: "References" }),
      folder("Draft/Appendices"),
      doc("Draft/Appendices/Title of First Appendix"),
      doc("Research/Example paper", "Paste or import an example to follow."),
      doc(
        "Notes/About this template",
        "How the template works.",
        "## How to use this template\n\n- Write each section in its own document in the **Draft** folder. Don't type the section titles: they're added when you export.\n- Documents inside a folder become lower-level APA headings (Level 1 centred bold, Level 2 left bold, Level 3 bold italic).\n- Fill in your title page details under **Export → Title page**.\n- Anything in Research and Notes is never exported.\n",
      ),
    ],
  },
  {
    id: "report",
    name: "Science report",
    icon: "🧪",
    description: "Aim, hypothesis, materials, method, results, discussion, conclusion.",
    preset: "clean",
    items: [
      doc("Draft/Aim", "One sentence: what are you trying to find out?"),
      doc("Draft/Hypothesis", "If … then … because …"),
      doc("Draft/Variables", "Independent, dependent and controlled variables."),
      doc("Draft/Materials", "A list of equipment with amounts."),
      doc("Draft/Method", "Numbered steps, past tense, passive voice."),
      doc("Draft/Risk assessment", "Hazards, risks and how you controlled them."),
      doc("Draft/Results", "Table of results, then a graph. Units in headings."),
      doc("Draft/Discussion", "Trends, explain with science ideas, errors and improvements."),
      doc("Draft/Conclusion", "Answer the aim. Was the hypothesis supported?"),
      doc("Draft/References", "", "", { label: "References" }),
      doc("Research/Task sheet", "The task and marking criteria."),
      doc("Notes/Raw data", "Readings as you take them."),
    ],
  },
  {
    id: "notes",
    name: "Class notes",
    icon: "🗒️",
    description: "A notebook for one subject: a page per lesson, Cornell-style.",
    preset: "clean",
    items: [
      folder("Draft/Term 4"),
      doc(
        "Draft/Term 4/Lesson 1",
        "Key ideas, questions, summary.",
        "## Key ideas\n\n- \n\n## Questions\n\n- \n\n## Summary\n\n",
      ),
      doc("Research/Glossary", "Key terms and what they mean."),
      doc("Notes/Revision list", "What to go over before the test."),
    ],
  },
  {
    id: "story",
    name: "Story",
    icon: "📚",
    description: "Chapters and scenes, character and setting sheets, plot outline.",
    preset: "manuscript",
    items: [
      folder("Draft/Chapter 1"),
      doc("Draft/Chapter 1/Scene 1", "Who, where, what changes."),
      doc("Draft/Chapter 1/Scene 2"),
      folder("Draft/Chapter 2"),
      doc("Draft/Chapter 2/Scene 1"),
      folder("Research/Characters"),
      doc(
        "Research/Characters/Main character",
        "Name, age, wants, fears, flaw.",
        "**Name:** \n\n**Wants:** \n\n**Fears:** \n\n**Flaw:** \n",
      ),
      folder("Research/Places"),
      doc("Research/Places/Setting", "What it looks, sounds and smells like."),
      doc("Notes/Plot outline", "Beginning · rising action · climax · resolution."),
    ],
  },
  {
    id: "speech",
    name: "Speech",
    icon: "🎤",
    description: "Opening, points, closing, plus cue cards.",
    preset: "clean",
    items: [
      doc("Draft/Opening", "Grab attention: question, story, statistic. Then your contention."),
      doc("Draft/Point 1", "Claim, evidence, persuasive technique."),
      doc("Draft/Point 2", "Claim, evidence, persuasive technique."),
      doc("Draft/Point 3", "Claim, evidence, persuasive technique."),
      doc("Draft/Rebuttal", "The other side's best argument, and why it's wrong."),
      doc("Draft/Closing", "Restate, call to action, memorable last line."),
      doc("Notes/Cue cards", "One dot point per card."),
    ],
  },
];

export function templateById(id: string): Template {
  return TEMPLATES.find((t) => t.id === id) ?? TEMPLATES[0];
}

export type AssessmentInfo = {
  id: number;
  title: string;
  subject: string;
  due?: string;
  metaclass?: number;
  status?: string;
};

type Json = any; // eslint-disable-line @typescript-eslint/no-explicit-any

function text(value: unknown): string {
  if (typeof value !== "string") return "";
  if (!/<[a-z][\s\S]*>/i.test(value)) return value.trim();
  if (typeof DOMParser === "undefined") return value.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  const doc = new DOMParser().parseFromString(value, "text/html");
  doc.querySelectorAll("style,script").forEach((n) => n.remove());
  doc.querySelectorAll("br").forEach((n) => n.replaceWith("\n"));
  doc.querySelectorAll("p,div,li,h1,h2,h3,h4,tr").forEach((n) => n.append("\n"));
  return (doc.body.textContent ?? "").replace(/ /g, " ").replace(/\n{3,}/g, "\n\n").trim();
}

/** The Research/Task sheet doc for a SEQTA assessment: due date, task, criteria (top band) and files. */
export function taskSheetMarkdown(a: AssessmentInfo, details: Json): string {
  const lines: string[] = [`**${a.subject}** · due **${a.due ?? "?"}**`, ""];
  const description = text(details?.description) || text(details?.customText);
  if (description) lines.push("## Task", "", description, "");
  const criteria: string[] = [];
  for (const c of Array.isArray(details?.criteria) ? details.criteria : []) {
    for (const line of Array.isArray(c?.rubric?.lines) ? c.rubric.lines : []) {
      if (line?.deleted) continue;
      const top = text(line?.descriptors?.[0]?.content) || text(line?.content);
      if (top) criteria.push(`- **${text(line?.title) || "Criterion"}:** ${top}`);
    }
    if (!c?.rubric && text(c?.description)) criteria.push(`- ${text(c.description)}`);
  }
  if (criteria.length) lines.push("## To get the top grade", "", ...criteria, "");
  const files = (Array.isArray(details?.resources) ? details.resources : [])
    .map((r: Json) => text(r?.name) || text(r?.userfile?.filename))
    .filter(Boolean);
  if (files.length) lines.push("## Files from your teacher", "", ...files.map((f: string) => `- ${f}`), "", "_Open them from the assessment in SEQTA._", "");
  return lines.join("\n").trim() + "\n";
}

/** Picks a template from the assessment's title ("essay", "report", "speech", …). */
export function guessTemplate(title: string): string {
  const t = title.toLowerCase();
  if (/speech|presentation|oral|debate/.test(t)) return "speech";
  if (/practical|prac|experiment|investigation|lab|report/.test(t)) return "report";
  if (/narrative|story|creative|fiction/.test(t)) return "story";
  if (/essay|analysis|inquiry|source|response|argument/.test(t)) return "essay";
  return "essay";
}

/** Items for a new project from an assessment: the chosen template plus its filled-in task sheet. */
export function itemsForAssessment(template: Template, a: AssessmentInfo, details: Json): { items: NewItem[]; settings: ProjectSettings } {
  const sheet = taskSheetMarkdown(a, details);
  const items = template.items.filter((i) => i.path !== "Research/Task sheet");
  items.push(doc("Research/Task sheet", `${a.title} (${a.subject}), due ${a.due ?? "?"}.`, sheet, { compile: false }));
  return {
    items,
    settings: { subject: a.subject, deadline: a.due, template: template.id, export: { preset: template.preset } },
  };
}

export const LABELS: Array<{ name: string; colour: string }> = [
  { name: "Idea", colour: "#f5b041" },
  { name: "Evidence", colour: "#2ecc71" },
  { name: "Quote", colour: "#3498db" },
  { name: "Needs work", colour: "#e74c3c" },
  { name: "Section", colour: "#9b59b6" },
  { name: "References", colour: "#7f8c8d" },
];

export const STATUSES = ["To Do", "In Progress", "First Draft", "Revised Draft", "Final Draft", "Done"];

export function labelColour(name: string | undefined): string | null {
  return LABELS.find((l) => l.name === name)?.colour ?? null;
}
