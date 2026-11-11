import { Editor, generateHTML, generateJSON, resolveExtensions, type Extensions } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { Markdown, MarkdownManager } from "@tiptap/markdown";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableKit } from "@tiptap/extension-table";
import Highlight from "@tiptap/extension-highlight";
import Image from "@tiptap/extension-image";
import { EditorContent } from "@tiptap/react";
import { createElement } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { atlantisExtensions } from "../extensions";
import { DocSession } from "../session";
import { installLocaleShim } from "../locale";
import { LocaleProvider } from "../../vendor/genoffice/renderer/i18n/locale";
import type { EditorView } from "@tiptap/pm/view";
import type { Transaction } from "@tiptap/pm/state";
import { CommentHighlight, FindHighlight, FocusBlock, ReviewMarks, type Comment } from "./plugins";
import { ProofMarks, type ProofIssue } from "./proofread";

/**
 * The Writer's editor (from BetterSEQTA+). In Atlantis the editing itself is GenOffice's lossless
 * Markdown editor; markdownToHtml/htmlToMarkdown below are only for exports, previews and imports.
 *
 * Originally: tiptap (ProseMirror) with Markdown in and out, so documents look like a
 * word processor while the files stay plain .md. Only things Markdown can hold are offered:
 * headings, bold/italic/underline/strike/highlight, links, lists, checklists, quotes, code,
 * tables, images and rules. (Underline is saved as ++text++ and highlight as ==text==.)
 */

function baseExtensions(): Extensions {
  return [
    StarterKit.configure({
      heading: { levels: [1, 2, 3, 4] },
      link: { openOnClick: false, autolink: true, defaultProtocol: "https" },
    }),
    TaskList,
    TaskItem.configure({ nested: true }),
    TableKit.configure({ table: { resizable: false } }),
    Highlight,
    Image.configure({ inline: false, allowBase64: true }),
  ];
}

let manager: MarkdownManager | null = null;
function markdownManager(): MarkdownManager {
  manager ??= new MarkdownManager({ extensions: resolveExtensions(baseExtensions()) });
  return manager;
}

/** Markdown → HTML using the editor's own schema (so exports match what's on screen). */
export function markdownToHtml(markdown: string): string {
  const json = markdownManager().parse(markdown);
  return generateHTML(json, baseExtensions());
}

/** HTML (e.g. an imported Word file) → Markdown. */
export function htmlToMarkdown(html: string): string {
  const json = generateJSON(html, baseExtensions());
  return markdownManager().serialize(json);
}

export type WriterEditorOptions = {
  element: HTMLElement;
  markdown: string;
  placeholder?: string;
  editable?: boolean;
  onChange: (editor: Editor) => void;
  /** Atlantis: every change to the text (for the writing record). */
  onEdit?: (tr: Transaction) => void;
  onFocus?: (editor: Editor) => void;
  onSelection?: (editor: Editor) => void;
  onBlur?: (editor: Editor) => void;
  /** Runs before the editor handles a key; return true to swallow it (slash menu). */
  onKeyDown?: (view: EditorView, event: KeyboardEvent) => boolean;
  comments?: () => Comment[];
  activeComment?: () => string | null;
  review?: () => boolean;
  /** Spelling & grammar marks: on/off and the cached issues for a paragraph's text. */
  proof?: () => boolean;
  proofLookup?: (text: string) => ProofIssue[] | undefined;
};

const sessions = new WeakMap<Editor, DocSession>();
/** The lossless session behind an editor (for the round-trip check). */
export const sessionOf = (editor: Editor): DocSession | undefined => sessions.get(editor);

export function createEditor(opts: WriterEditorOptions): Editor {
  // GenOffice's editor (atlantisExtensions) keeps unchanged Markdown byte for byte; the Writer's
  // own add-ons below only draw on top of the text.
  let loading = false;
  const editor = new Editor({
    editable: opts.editable !== false,
    extensions: [
      ...atlantisExtensions(),
      FindHighlight,
      FocusBlock,
      CommentHighlight.configure({ get: opts.comments ?? (() => []), active: opts.activeComment ?? (() => null) }),
      ReviewMarks.configure({ enabled: opts.review ?? (() => false) }),
      ProofMarks.configure({ enabled: opts.proof ?? (() => false), lookup: opts.proofLookup ?? (() => undefined) }),
    ],
    content: "",
    editorProps: {
      attributes: { class: "wr-prose", spellcheck: opts.proof?.() ? "false" : "true" },
      handleKeyDown: (view, event) => opts.onKeyDown?.(view, event) ?? false,
    },
    onUpdate: ({ editor, transaction }) => {
      if (!loading && transaction.docChanged && !transaction.getMeta("uiOnly")) {
        opts.onEdit?.(transaction);
        opts.onChange(editor);
      }
    },
    onFocus: ({ editor }) => opts.onFocus?.(editor),
    onBlur: ({ editor }) => opts.onBlur?.(editor),
    onSelectionUpdate: ({ editor }) => opts.onSelection?.(editor),
    onTransaction: ({ editor }) => opts.onSelection?.(editor),
  });
  installLocaleShim();
  // Mounted through React so GenOffice's code-block view (a React node view) can render.
  const root = createRoot(opts.element);
  // LocaleProvider: GenOffice's React pieces default to Chinese without it.
  flushSync(() => root.render(createElement(LocaleProvider, { initial: "en", children: createElement(EditorContent, { editor }) })));
  const session = new DocSession(editor);
  loading = true;
  try {
    session.load(opts.markdown);
  } finally {
    loading = false;
  }
  // The Writer reads the text back with getMarkdown(): give it the lossless version.
  editor.getMarkdown = () => session.serialize();
  sessions.set(editor, session);
  const destroy = editor.destroy.bind(editor);
  editor.destroy = () => {
    root.unmount();
    destroy();
  };
  return editor;
}

export type { Editor };

/** Text styles for the style menu, like a word processor's "Normal / Heading 1 / …". */
export const BLOCK_STYLES = [
  { id: "p", label: "Body" },
  { id: "h1", label: "Title" },
  { id: "h2", label: "Heading" },
  { id: "h3", label: "Subheading" },
  { id: "h4", label: "Heading 4" },
  { id: "quote", label: "Block quote" },
  { id: "code", label: "Code" },
] as const;

export type BlockStyle = (typeof BLOCK_STYLES)[number]["id"];

export function currentBlockStyle(editor: Editor): BlockStyle {
  for (const level of [1, 2, 3, 4] as const) if (editor.isActive("heading", { level })) return `h${level}` as BlockStyle;
  if (editor.isActive("codeBlock")) return "code";
  if (editor.isActive("blockquote")) return "quote";
  return "p";
}

export function setBlockStyle(editor: Editor, style: BlockStyle): void {
  const chain = editor.chain().focus();
  if (editor.isActive("blockquote") && style !== "quote") chain.lift("blockquote");
  switch (style) {
    case "p":
      chain.setParagraph().run();
      break;
    case "quote":
      chain.setParagraph().setBlockquote().run();
      break;
    case "code":
      chain.setCodeBlock().run();
      break;
    default:
      chain.setHeading({ level: Number(style.slice(1)) as 1 | 2 | 3 | 4 }).run();
  }
}

/** The "/" menu: blocks you can drop in without the toolbar. `keys` are extra words to match. */
export const SLASH_ITEMS: Array<{ id: string; label: string; hint: string; keys: string; run: (e: Editor) => void }> = [
  { id: "h1", label: "Title", hint: "#", keys: "heading title h1", run: (e) => e.chain().focus().setHeading({ level: 1 }).run() },
  { id: "h2", label: "Heading", hint: "##", keys: "heading h2 section", run: (e) => e.chain().focus().setHeading({ level: 2 }).run() },
  { id: "h3", label: "Subheading", hint: "###", keys: "heading h3 subheading", run: (e) => e.chain().focus().setHeading({ level: 3 }).run() },
  { id: "ul", label: "Bulleted list", hint: "-", keys: "bullet list unordered dot points", run: (e) => e.chain().focus().toggleBulletList().run() },
  { id: "ol", label: "Numbered list", hint: "1.", keys: "numbered ordered list steps", run: (e) => e.chain().focus().toggleOrderedList().run() },
  { id: "todo", label: "Checklist", hint: "[ ]", keys: "todo task checklist checkbox", run: (e) => e.chain().focus().toggleTaskList().run() },
  { id: "quote", label: "Quote", hint: ">", keys: "quote blockquote citation", run: (e) => e.chain().focus().setBlockquote().run() },
  { id: "table", label: "Table", hint: "3×3", keys: "table grid columns", run: (e) => e.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() },
  { id: "hr", label: "Divider", hint: "---", keys: "divider line rule separator break", run: (e) => e.chain().focus().setHorizontalRule().run() },
  { id: "ref", label: "Reference", hint: "⌥⌘R", keys: "reference cite citation source bibliography link harvard apa", run: () => {} },
  { id: "note", label: "Note to self", hint: "not exported", keys: "note comment remind private annotation sticky todo self", run: (e) => e.chain().focus().setCodeBlock({ language: "note" }).run() },
  { id: "code", label: "Code block", hint: "```", keys: "code program", run: (e) => e.chain().focus().setCodeBlock().run() },
];
