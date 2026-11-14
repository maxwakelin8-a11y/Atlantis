# Project Atlantis: PRD (base v0.1)

Status: base PRD (source of truth for this repo) · 2026-11-03, updated 2026-11-06 · Owner: the user · Written by: Claude

## 1. One line

A native Mac planner that brings school (SEQTA), tasks, the calendar and life into one calm
"Today" screen. Your agents can read it and help run it.

**Goal:** Atlantis is the main app. The only other app you need to switch to is **T3 Code**
(for coding). Everything else lives in Atlantis: planning, SEQTA, and your own mini office
suite, starting with **Docs** (§7a).

## 2. Problem

- School information lives in SEQTA, tasks in `tasks.md`, notes in Obsidian, events in Google
  Calendar and training in your head. No single place answers "what should I do now?"
- Assessments arrive as due dates, not as plans. The work of breaking an assessment down and
  finding time for it is manual and easy to put off.
- Agents (OpenMausBot, Claude in T3 Code) can read SEQTA through seqta-mcp, but they have
  nowhere to put their suggestions where you will see them and approve them.

## 3. Principles

1. **The vault is the database.** All data is plain markdown in LifeOS. Atlantis has no data
   store of its own beyond caches. Obsidian keeps working alongside it.
2. **SEQTA is a source, not a home.** The app reads it through the existing logged-in session.
   Each part of SEQTA lives in a native part of Atlantis (§7d); the SEQTA web tab is temporary.
   SEQTA is never polled: one automatic sync each morning plus manual refreshes.
3. **Agents propose and you approve.** Anything an agent writes lands in the Inbox first,
   unless you have allowed that action.
4. **Calm, not busy.** TickTick's cleanliness and Chris Raroque–style polish. Each feature has
   to earn its place on screen.
5. **Small apps, one system.** Atlantis is the planner. The AI Dock (focus) and Tinycast
   (command bar) stay separate apps connected through a shared layer (§10).

## 4. Inspirations: what we take

| From | Take |
|---|---|
| ClickUp | Agents as teammates: assign or mention an agent, and expose an MCP server |
| Motion | Auto-scheduling tasks (estimate + deadline) into free time, then re-planning when things change |
| TickTick | A clean task model, a Pomodoro timer on each task, habits, a priority matrix |
| Chris Raroque (Ellie, Amy, Luna) | Brain dump plus a day board, strong widgets, polished and deliberate UI |
| Structured | A single-day timeline and a "Replan" button for missed tasks |
| Sunsama | Morning planning and evening shutdown rituals, plus a warning when the day is too full |
| Akiflow | One inbox that everything lands in |

## 5. Decisions taken by default (change any)

| Question | Default |
|---|---|
| Platform | **macOS first** (SwiftUI, macOS 15.4+). iPhone and widgets come later. |
| Codebase | **Grows out of `~/Developer/seqta-app`**, which already has SEQTA + BetterSEQTA+ via WKWebExtension and a LifeOS vault bridge. It builds with SwiftPM and no Xcode. |
| AI | Two paths: **(a)** the Claude API in the app for quick actions (breaking assessments down, planning the day); **(b)** an MCP server so OpenMausBot and T3 Code agents can operate the app |
| Audience | **You only.** No accounts, sync service or onboarding. |
| Scope | Built in the phases of §12: daily driver (Docs, Tasks, SEQTA, Today, Inbox, MCP) → your bot team (§7b) → Docs+ and polish → workspace (browser, whiteboard, Sheets, Slides) → autopilot. |
| Office suite | Inside Atlantis. **Docs first**, then Sheets and Slides later. Docs are plain `.md` files in Writer projects (iCloud Drive/Writer, §7a). Sheets and Slides may use `.xlsx`/`.pptx`. **Every file stays local** on this Mac (no cloud service). No Obsidian needed. |
| Office suite code | Built from **GenOffice** (Apache-2.0, `github.com/genspark-ai/genoffice`). Its **markdown editor becomes Atlantis Docs**, with good ideas from its Word-style `docs` app moved into it. **GenOffice's own AI is removed.** Atlantis uses its own Claude features or no AI. Never copy `ee/` (different licence). |

## 6. Users and core jobs

The only user is a Year 9 student who trains BJJ, builds apps and uses AI agents.

1. "What's on today, and what should I do next?"
2. "Capture this task in two seconds."
3. "Don't let an assessment sneak up on me."
4. "Let my agents help without making a mess."
5. (v2) "Plan my study time around class and training for me."

## 7. Features

### v1: Base

**F1. Today screen (home)**
- Timeline on the left: SEQTA classes (time, room, teacher, lesson topic), calendar events and
  scheduled task blocks.
- On the right: today's tasks (due today or overdue, plus anything you've pulled in), the Top 3
  from the daily note (read-only), and a "Next up" card.
- At the top: assessments due in the next 14 days with countdowns. Notices are collapsed.
- Refresh SEQTA button that shows the last sync time.

**F2. Tasks**
- List views: Today, Upcoming, by Project, by Area/Mode, Done.
- Quick add (⌘N and a global hotkey) with natural-language dates ("Turing draft thu 45m #school").
- Fields: title, due, estimate, priority (1–3), project, area/mode, notes, subtasks, source.
- Stored in `machine/tasks.md` in the existing line format, with new inline fields (§9).
- Edits made in Obsidian show up live (file watcher). Conflicts are handled by re-reading
  before each write.

**F3. SEQTA** (the full plan is §7d)
- For now the full SEQTA + BetterSEQTA+ web view is a sidebar tab, as seqta-app does today.
  It is temporary: features move out of it into Atlantis (§7d) and then the tab is removed.
- A structured sync of today's lessons, homework, assessments (14 days), notices, new marks and
  messages fills the Today screen, Subjects, Messages and the daily note's machine-owned block
  and front matter, following the AGENTS.md rules.
- Homework and new assessments are proposed as tasks in the Inbox with `source:: seqta:…`.
  They are never added silently.

**F4. Inbox (agent and capture)**
- One list of proposals: SEQTA items, agent suggestions ("I broke the Turing assessment into 5
  steps"), quick captures.
- Each item has Accept, Edit, Dismiss, and "always allow this kind".
- Stored in `machine/atlantis/inbox.md` so agents and Obsidian can see it.

**F5. MCP server**
- Lets OpenMausBot, Claude Code and T3 operate Atlantis (tools in §8).
- Read tools work freely. Write tools post to the Inbox unless you have allowed that action.

**F6. Daily rituals (light)**
- Morning: "Plan your day". Pick today's tasks, and get a warning when the planned estimates
  exceed the free time.
- Evening: "Shutdown". Tick off done tasks, move or drop the rest, and add a line to the daily
  note's machine block.

**F7. Look and feel**
- Sidebar: Today · Tasks · Inbox · Messages · Subjects (one sub-item per subject) · Agents · Docs ·
  Whiteboard · Settings (pages appear as their milestone lands). SEQTA is a tab only until
  §7d's phase-out is done. No feature appears twice: the SEQTA web view never gets its own
  task list, agents or sidebar.
- Light and dark mode. Subject colours come from SEQTA.
- Smooth, small animations, and keyboard-first (⌘1–5, J/K, Space to complete).

### v1: Docs (§7a)

### 7a. Docs: office suite part 1

Your own document editor inside Atlantis, replacing Google Docs, Pages and Obsidian for
writing. Each doc is a plain `.md` file you own.

**Decided 2026-11-07: Docs is the Writer.** The user's BetterSEQTA+ Writer tab (a Scrivener-style
studio: project home, binder with Draft/Research/Notes/Trash, corkboard, outliner, inspector,
format bar, find/replace, "/" menu, comments, snapshots, templates, word targets, focus mode,
export to Word/PDF/RTF/ODT/HTML/Markdown) is copied into Atlantis as the Docs page
(`web/docs-editor/src/writer`, MIT). Its text editing runs on GenOffice's lossless editor below,
so unchanged text stays byte-identical. It uses the same folder as the BetterSEQTA+ Writer, so
existing projects open in both. Writer features that need Claude (reading a web page for a
reference) and SEQTA (start from an assessment) are switched off until Atlantis has its Claude
client and SEQTA cache. Spelling & grammar checks (changed 2026-11-14) run on the Mac's own checker
(NSSpellChecker, the Mac's language), always on, Google Docs-style: red/blue squiggles over the whole
doc, fixes on hover. The Docs layout follows Google Docs too: pale canvas, pill toolbar, white page,
no inspector until opened.

**Editor engine:** a copied, fixed snapshot of GenOffice's `apps/markdown` renderer (Tiptap/ProseMirror),
with the upstream commit recorded in `docs/findings.md`. Features worth having from GenOffice's
Word-style `apps/docs` (for example comments, autocorrect, case change and print layout) are
re-built inside this markdown editor, which is called **Docs**. GenOffice's Electron main process
is rewritten in Swift. All of GenOffice's AI code (agent-core, ai-provider, AI panel, edit queue)
is removed.

**Storage**
- The Writer folder (default `~/Library/Mobile Documents/com~apple~CloudDocs/Writer`, set in
  Settings): one folder per project with `.writer.json` (binder order, settings), `Draft/`,
  `Research/`, `Notes/`, `Trash/`, `Exports/` and `.snapshots/`. One doc = one `.md` file.
  Nothing is deleted for real: emptying the Trash moves files into a hidden `.deleted` folder.
- Images go in an `assets/` folder next to the doc and are linked with relative paths, so the
  files still read well in any markdown app.
- Front matter holds the Writer's fields (`title`, `synopsis`, `status`, `label`, `target`,
  `notes`, `comments`, …), edited in the inspector, hidden in the editor. Other keys are kept.
- Edits made outside the app (T3 Code agents, Finder, git) show up live through a file watcher.

**Editor (v1)**
- WYSIWYG-style live markdown: you see headings, bold, lists and tables rendered as you type,
  not raw `#` and `**`. A toggle shows the source (like Typora or Bear).
- Blocks: headings, lists, checklists, quotes, code, tables, images (paste or drag), dividers,
  callouts.
- A "/" menu to insert blocks; ⌘B/⌘I/⌘K etc.; outline sidebar from headings.
- Autosave (no save button), with version history through local snapshots in
  each project's `.snapshots/`: a version is kept by itself every 10 minutes while you write,
  plus named ones (added 2026-11-11, asked for by the user).
- **Writing record** (added 2026-11-11, asked for by the user): for school authentication, the
  Writer logs how the text came to be in `<project>/.writer-record.jsonl` (characters typed and
  deleted per minute, every paste with its text, restores, imports and changes made outside the
  Writer). History → "Open writing record" shows time spent, sessions, typed vs pasted, a
  words-over-time chart and every paste, for a doc or the whole project, and saves it as a PDF
  for a teacher. It's a plain file, not tamper-proof.
- **Notes to self in the text** (added 2026-11-11): a ```` ```note ```` block (⌥⌘J, "/note"),
  shown as a sticky note, never exported and not counted as words. Comments and the inspector's
  document notes are also never exported.
- Word count, focus mode (dims everything but the current paragraph).

**Organising**
- Sidebar: folders, Recent, Pinned. ⌘P quick open, full-text search (⌘⇧F).
- `[[Doc name]]` links between docs, with backlinks.

**AI (Claude API, Atlantis's own; optional, and Docs works fully without it)**
- Select text, then choose Proofread, Shorter, Expand, More formal, Explain, or a custom
  prompt. The suggestion shows as a diff that you accept or reject.
- "Draft from…": start a doc from a SEQTA assessment (task sheet + rubric pulled in), a task,
  or a prompt.

**Connected to the rest of Atlantis**
- Link a doc to a task or SEQTA assessment. The task shows a "📄 open doc" button.
- Export to **PDF** and **.docx** (for SEQTA submissions), then attach it to the SEQTA
  submission from the SEQTA tab.

**Later in Docs:** comments, templates (essay, lab report, notes), Google Docs import,
print layout settings.

**Office suite roadmap:** Docs (v1) → Sheets (`.xlsx`, from GenOffice's Univer-based
`apps/sheets`) → Slides (`.pptx`, from GenOffice's `apps/slides`) → Whiteboard (proposed, see
§16). Storage rule: open file formats in `~/Documents/`, kept on this Mac, never in a cloud
service. GenOffice's AI is stripped from every app.

### 7b. Agents: your own bot team (Phase 2)

ClickUp-style agents as teammates, built natively into Atlantis. Replaces OpenMausBot over time.

- **A bot is a markdown file you own:** `machine/atlantis/agents/<name>.md`. Its front matter
  holds name, avatar, model, tools, autonomy, triggers and budget. The body is its "soul".
- **Team:** Chief (routes requests) plus School, Coach, Builder and Scout.
- **Five ways to start a bot:** chat (T3-style threads on the Agents page), @mention in a doc,
  assign a task, a schedule (e.g. morning plan), and an event (new SEQTA assessment, overdue task).
- **Autonomy per bot:** suggest (Inbox only, the default) · ask (approve before applying) ·
  act (only for actions on the allow list).
- **Runtime:** a separate helper process `atlantis-agentd` behind a provider interface:
  - **Claude via your subscription:** runs the official Claude Code CLI headless (`claude -p`),
    locked to MCP tools only (no shell or file tools). Never extract or reuse the subscription
    token in Atlantis's own code.
  - **"Fusion" mode:** a lead model (Opus, via the subscription) plans and reviews, and a cheap
    API worker (e.g. DeepSeek Flash; confirm the current model name and price) does bulk steps.
  - **Cheap fallback:** the cheap API also covers jobs that need an API. **SEQTA data and
    personal content never go to non-Claude cloud providers.** Bot and T3 coding usage share
    the subscription's limits.
  - Tools: Atlantis stores (including the SEQTA cache), MCP clients (Yab) and the browser panel.
    No shell access.
- **Guardrails:** daily cost cap and max steps per bot. Bots use cached SEQTA data and never
  sync or send messages (they may draft a reply into the Inbox). Content bots read is data, never instructions. Every run is logged
  to `machine/atlantis/threads/`.

### 7c. Workspace (Phase 4)

- **Browser panel per thread/task/doc** (WKWebView, not Chromium). Each context keeps its own
  cookies, hidden panels are snapshotted and unloaded, and bots can drive it. It has no Swift
  bridge (untrusted content). Logged-in or long browsing is handed off to Yab.
- **Whiteboard (built early, 2026-11-11; changed from "native Swift"):** the real Excalidraw
  (MIT, `@excalidraw/excalidraw`, `web/whiteboard`) in a web view with no network, fonts bundled.
  Boards are plain `.excalidraw` files in iCloud Drive/Whiteboards (sub-folders allowed), so they
  also open in excalidraw.com and Obsidian. The board list is native; the page never names files
  (Swift hands it the open board and checks every save, refusing one if the file changed since,
  then the page merges and saves again). Agents (T3 Code, bots) read and draw on boards through
  the MCP tools in §8: they only add, never move or delete. Later: embed a board in a doc as an
  SVG preview, link boards to tasks, Mermaid → board.
- **Sheets** (`.xlsx`, GenOffice/Univer) and **Slides** (`.pptx`, GenOffice), with AI stripped.

### 7d. SEQTA inside Atlantis (phase-out of the SEQTA tab)

Decided 2026-11-06. You shouldn't need "SEQTA the app" inside Atlantis. Each part of SEQTA
moves to where it belongs, and your AI can read all of it.

| SEQTA feature | Home in Atlantis |
|---|---|
| Timetable, lessons | Today timeline (week view later) |
| Lesson content, homework | Class cards on Today; homework → Inbox proposal → Tasks |
| Assessments (details, rubric, due dates) | Tasks (an assessment is a project with steps) + Today countdowns |
| Notices | Today (collapsed) |
| Marks, feedback, course files | **Subjects** page, one sidebar sub-item per subject (files open in Quick Look) |
| Messages | **Messages** page: read, reply and compose (see the rules below) |
| Submitting work | Opens that SEQTA page in a pop-up until a native version exists |
| Anything else (reports, portals) | "Open in SEQTA" link to a pop-up |

- **Sync engine:** a hidden web view with the logged-in session. It loads only for sign-in, the
  morning sync, a manual refresh or a message send, then unloads (idle = zero work).
  BetterSEQTA+ is only needed while the tab exists.
- **Cache:** synced data is saved as JSON in `~/Library/Application Support/Atlantis/seqta/`
  (local, not iCloud; safe to delete and rebuild). Only the parts listed in AGENTS.md go into
  the vault.
- **AI access:** every page reads the same cache, and the MCP server exposes it as read tools
  (§8), so bots and Claude Code see what you see. This takes over from seqta-mcp over time.
- **Messages both ways:** you can reply and compose in Atlantis. Sending needs your explicit
  Send click in the compose view and a short confirm that shows the recipients. Bots and MCP
  tools can draft a reply into the Inbox, but **never send**.
- **Removing the tab:** once Today, Tasks, Subjects and Messages cover a normal school day,
  the tab leaves the sidebar. The "Open in SEQTA" pop-up stays as the fallback.

### v2: Autopilot

- **Assessment breakdown:** an AI-made plan of subtasks with estimates for each new assessment.
- **Auto-scheduling (Motion-style):** places tasks into free slots around class, events and
  training. It respects working hours and no-go times and never overbooks. "Replan" moves
  missed blocks. Plans are shown as proposals until you accept them.
- **Google Calendar:** reads busy times and writes accepted blocks.
- **Pomodoro on tasks:** starts the matching AI Dock mode.
- **Marks:** results and feedback by subject over time.

### v3+: Later

- iPhone app and widgets (home screen, lock screen, watch); App Intents and Shortcuts
- Habits and streaks; priority matrix view; weekly review
- Amy nutrition beside BJJ training; Gmail to tasks; exam revision with spaced repetition
- Docs: a deeper Claude grammar & style pass on top of the Mac's spelling check (macOS grammar
  only catches simple mistakes such as doubled words or "they was")

## 8. MCP tools (v1)

| Tool | Type | What it does |
|---|---|---|
| `atlantis_today` | read | Timeline, tasks, assessments and Next up for a date |
| `atlantis_tasks_list` | read | Filter by status, due date, project or mode |
| `atlantis_task_add` | write* | Add a task (goes to the Inbox unless allowed) |
| `atlantis_task_update` | write* | Change, complete or move a task |
| `atlantis_inbox_post` | write | Post a proposal (always allowed) |
| `atlantis_inbox_list` | read | Proposals still waiting and their states |
| `atlantis_seqta_refresh` | action | Manual SEQTA sync (respects the once-per-morning auto rule) |
| `atlantis_school_timetable` | read | Lessons for a date range, with lesson content and homework |
| `atlantis_school_assessments` | read | Upcoming and past assessments, with details and marks |
| `atlantis_school_subjects` | read | Subjects, teachers, marks, feedback and course files |
| `atlantis_school_notices` | read | Notices for a date |
| `atlantis_school_messages` | read | Message list and full messages |
| `atlantis_message_draft` | write | Draft a reply or new message into the Inbox for you to send (never sends) |
| `atlantis_docs_list` / `atlantis_docs_search` | read | Find docs by folder, name or text |
| `atlantis_doc_read` | read | A doc's markdown |
| `atlantis_doc_write` | write* | Create a doc, or propose edits (shown as a diff to accept in the editor) |
| `atlantis_doc_export` | action | Export to PDF or .docx |
| `atlantis_whiteboards_list` | read | Boards in the Whiteboards folder |
| `atlantis_whiteboard_read` | read | A board's shapes, text, arrows (with what they connect) and bounds, or its raw JSON |
| `atlantis_whiteboard_draw` | write* | Add shapes, text and arrows (creating the board if needed); never moves or deletes |
| `atlantis_whiteboard_open` | action | Show a board on the Whiteboard page |

These replace seqta-mcp's `docs_*` tools once they work.

\* Writes are gated by the allow list in Settings.

Transport: a local MCP server bundled with the app (stdio helper → the app over a local
socket), so it works from Claude Code and OpenMausBot on this Mac. SEQTA reads come from
Atlantis's cache (§7d) and take over from seqta-mcp once they work. No MCP tool sends a message.

## 9. Data (all in the vault)

| File | Owner | Notes |
|---|---|---|
| `machine/tasks.md` | Atlantis, agents, you | Existing format; new optional fields below |
| `machine/atlantis/inbox.md` | Atlantis, agents | One proposal per line with an id and state |
| `machine/atlantis/settings.md` | you via the app | Modes, working hours, allow list (front matter) |
| `daily/YYYY-MM-DD.md` | as in AGENTS.md | Atlantis writes only the machine-owned parts |
| `iCloud Drive/Writer/<project>/**.md` | you (via Docs), agents via MCP | Outside the vault. Writer projects (§7a): plain markdown + `.writer.json` |
| `~/Library/Application Support/Atlantis/seqta/*.json` | SEQTA sync | Local cache only, not in the vault or iCloud; rebuilt by a sync |

New task fields (inline, Dataview style, all optional):

```
- [ ] Turing essay draft [due:: 2026-11-07] [est:: 45m] [pri:: 1] [mode:: school]
      [project:: turing] [scheduled:: 2026-11-04T16:00] [source:: seqta:assessment:1234]
      [added:: 2026-11-03] ^t-ab12cd34
```

Rules: keep unknown fields and the line order, change only the line being edited, and write
the file atomically.

## 10. Connection to the ecosystem

- **Shared modes:** School, Building, BJJ and Social are both task modes in Atlantis and modes
  in the AI Dock.
- **Shared folder:** `~/Library/Application Support/LifeOS/shared/` holds `plan.json` (today's
  blocks, written by Atlantis) and `modes.json` (owned by the Dock).
- **Live events** over a local socket: `block.started`, `mode.changed`, `task.completed`.
  This is a light version of the "LifeOS Core" idea in the AI Dock note.
- **AI Dock:** reads `plan.json` to switch modes and to show Next up. Its time-per-mode data
  feeds Atlantis's evening review.
- **Tinycast:** "add task …" calls Atlantis's quick add.

## 11. Architecture (v1)

```
Atlantis.app (SwiftUI, SwiftPM)
├─ SEQTA tab          WKWebView + BetterSEQTA+ via WKWebExtension   (from seqta-app)
├─ SeqtaSync          JS in the logged-in session → structured JSON → vault
├─ VaultStore         read/parse/write tasks.md, inbox.md, daily notes, file watcher
├─ Planner            Today model, capacity check (v2: scheduler)
├─ AI                 Claude API client (key in Keychain), breakdown + plan + writing prompts
├─ Docs               DocStore (files, watcher, search index, history)
│                     + Editor: WKWebView running GenOffice's markdown editor (Tiptap/
│                       ProseMirror), bundled locally; its Electron main/preload layer
│                       replaced by Swift + a WKScriptMessageHandler bridge
├─ Export             PDF (WebKit print) and .docx (pandoc if installed, else built in)
├─ MCPBridge          local socket ↔ bundled `atlantis-mcp` stdio helper
└─ UI                 Today · Tasks · Docs · SEQTA · Inbox · Settings
```

- Why a web editor for Docs: native SwiftUI text editing is weak for rich markdown. The app
  already uses WebKit heavily, and GenOffice's markdown editor already does most of §7a. Test
  the round trip first: opening and saving without changes must leave the file byte-for-byte
  the same. Also never write a doc the user hasn't edited.

- Credentials are kept in the Keychain only. No secrets go in the vault, logs or repo.
- No background polling of SEQTA.

## 12. Roadmap (build order)

Each milestone leaves a working app. The riskiest things get tested before anything is built on
them. **Every milestone gate:** the tests pass (including the Docs round trip), the §17 budgets
are checked (10-minute idle test in Activity Monitor, and close/reopen 20× with no leak),
and there's an entry in `docs/log.md`.

**Phase 0: Foundations**

| # | Milestone | Done when |
|---|---|---|
| M0 | Shell + design system | SwiftPM app launches with the sidebar and the SEQTA tab from seqta-app working. Design tokens (Swift, plus generated CSS) and a component **Gallery** screen in light and dark. Debug performance HUD and signposts. Security baseline: hardened runtime, Keychain wrapper, web views blocked from the network by default |

**Phase 1: Daily driver**: the point where you open Atlantis first every morning

| # | Milestone | Done when |
|---|---|---|
| M1 | Docs core | **Spike first (1–2 days):** GenOffice's markdown renderer in a WKWebView with a narrow Swift bridge passes the round-trip test on real files. Then: the BetterSEQTA+ Writer as the Docs page on top of it (projects, binder, editor, export), then search across projects and pasting images |
| M2 | Tasks | VaultStore reads and writes `tasks.md`; add, edit and complete tasks; Obsidian edits show live and back again |
| M3 | SEQTA sync + Today | Hidden sync engine + JSON cache (§7d). Today shows real classes, assessments and tasks; the daily note's machine block fills in |
| M4 | Inbox + MCP | `atlantis-mcp` over a locked-down Unix socket; Claude Code adds a task through MCP, it lands in the Inbox, and Accept applies it. SEQTA read tools (§8) work from the cache |
| M4b | Subjects + Messages | Subjects page with a sidebar sub-item per subject (marks, feedback, files); Messages page that reads, replies and composes (you send; bots only draft). **The SEQTA tab leaves the sidebar** (§7d) |

**Phase 2: Your bot team** (§7b)

| # | Milestone | Done when |
|---|---|---|
| M5 | First bot | `atlantis-agentd` runs; the School bot (defined in its `.md` file) chats in threads with read-only tools; budgets enforced |
| M6 | Bots as teammates | Assign a task to a bot or @mention one in a doc; results land in the Inbox; autonomy levels work |
| M7 | Team + triggers | Morning schedule and SEQTA events; Chief routes to the specialists; agent activity shows on Today |

**Phase 3: Docs+ and polish**

| # | Milestone | Done when |
|---|---|---|
| M8 | Docs+ | `[[links]]` and backlinks, history, PDF/.docx export, features ported from GenOffice's docs app, and AI writing actions (reusing the agent runtime, optional) |
| M9 | Rituals + design pass | Morning plan and evening shutdown; full pass over states, keyboard and accessibility; performance and security audit |

**Phase 4: Workspace** (§7c)

| # | Milestone | Done when |
|---|---|---|
| M10 | Browser panel | A browser on threads, tasks and docs; bots can read and drive it; Yab handoff |
| M11 | Whiteboard | **Built 2026-11-11 (ahead of order, user's ask):** Excalidraw in a web view, `.excalidraw` files, agents draw via MCP. Left: embeds in Docs |
| M12 | Sheets | GenOffice Sheets (`.xlsx`) in the app, with AI stripped |
| M13 | Slides | GenOffice Slides (`.pptx`) in the app, with AI stripped |

**Phase 5: Autopilot** (v2): assessment breakdown, Motion-style scheduler, Google Calendar, Pomodoro and AI Dock, marks. Then §7 "v3+".

Why this order: Phase 1 makes Atlantis useful every day as early as possible. Bots come next
because they build on the Inbox and MCP, and Docs+ AI then reuses the bot runtime instead of
building a second one. The office extras come last because they're the biggest pieces of work
that you can do without.

## 13. Success (personal)

- You open Atlantis, not SEQTA or Obsidian, first thing on school days.
- No assessment is started less than 3 days before it's due.
- Agents' suggestions are accepted more often than dismissed.
- Fewer than 2 minutes a day spent re-entering things by hand.

## 14. Non-goals (v1)

Accounts, cloud sync service, multi-user, Windows or web app, real-time collaboration,
Sheets and Slides (later versions), and bots or MCP tools sending SEQTA messages. (Replacing
the SEQTA web UI is now a goal, §7d; you can send messages yourself.)

## 15. Risks

| Risk | Mitigation |
|---|---|
| SEQTA or the fork changes break the sync | Keep the sync isolated; the "Open in SEQTA" pop-up still works if the sync fails |
| A message is sent by mistake | Only from the compose view, with a confirm showing recipients; never from bots or MCP |
| Atlantis and Obsidian write `tasks.md` at the same time | Re-read before each write, write atomically, change only the edited line |
| Scope creep | v1 list is fixed; new ideas go to §7 v3+ |
| GenOffice is large and changes fast | Copy one fixed snapshot of only the apps we use, record the commit, and don't track upstream |
| Auto-scheduling stress (common Motion complaint) | Plans are proposals; no silent reshuffling |

## 16. Open questions

1. Is Mac-only right for v1, or do you need the iPhone sooner?
2. ~~AI provider?~~ Decided 2026-11-04: Claude via the subscription (Claude Code headless), Opus-lead + cheap-worker "fusion" mode, and a cheap API fallback that never sees SEQTA data (§7b).
3. Should the repo be new (`~/Developer/atlantis`) or a rename of seqta-app? (Default: new repo, copying the SEQTA code in.)
4. Which modes, working hours and no-go times should the scheduler use (training nights, etc.)?
5. ~~Whiteboard: when, and Swift or Rust?~~ Decided 2026-11-03: native Swift, built at M11. Changed
   2026-11-11: the real Excalidraw in a web view, built now, so the user gets Excalidraw itself and
   AI tools can draw on it (§7c).
6. Which projects are "openbot" and "Grok bot", so their ideas can be folded into §7b?

## 17. Performance, resources and security

**Speed budgets:** launch to a ready Today < 1 s · page switch < 100 ms · open doc < 300 ms ·
search < 200 ms · no typing lag in a 10k-word doc.

**Resource budgets:**

| State | CPU | GPU | RAM |
|---|---|---|---|
| Background, idle | ~0%, no idle wake-ups | 0 | < 200 MB |
| Foreground, idle | < 1% | ~0 | < 300 MB |
| Typing in Docs | < 15% of one core | minimal | < 500 MB |
| Whiteboard gesture | < 30% | smooth, then idle | < 600 MB |

Rules: **idle means zero work** (no polling or repeating timers; use FSEvents with debounce;
countdowns update once a minute). Keep live web views to the visible ones plus one warm Docs
editor; snapshot and unload hidden ones, and create Sheets and Slides only on demand. Run
heavy work on background actors at `.utility` priority. No looping animations, and blur only
in the chrome. The search index is a cache you can rebuild. Check with Instruments, XCTest
CPU and memory metrics, and the debug HUD.

**Security and privacy:**
- **Narrow bridge:** the Docs page gets only plain file operations (list, read UTF-8, atomic
  text write, mkdir, move, stat, copy folder), export/import conversion, and open-in-Finder, and
  Swift (`WriterFiles`) refuses any path outside the Writer folder, symlinks included. HTML in docs is sanitised, with a
  strict CSP. Browser panels get no bridge.
- **MCP socket:** Unix domain socket with `0600` permissions and a peer-UID check. Never TCP.
- **Network:** no telemetry, and GenOffice's updater and phone-home calls are removed. The only
  outbound connections are to SEQTA and the AI provider. Check with a network monitor.
- **Prompt injection:** content from SEQTA, docs and the web is data, never instructions.
  Writes go through the Inbox or the allow list, and deletes are never auto-allowed.
- **Secrets:** Keychain only, and `os_log` privacy markers so secrets and content stay out of
  logs. SEQTA data (other people's names and messages) goes to AI only when you ask.
- **Supply chain:** fixed lockfile and `npm audit` when updating GenOffice; ship only the built
  bundle. Hardened runtime and code signing.
