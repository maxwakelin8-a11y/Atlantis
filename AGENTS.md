# AGENTS.md: Project Atlantis

**Read this first, then `docs/PRD.md`** (the full product spec). Keep context small and read only
what your task needs.

## What this is

Atlantis is the user's **main Mac app**. Coding happens in T3 Code; everything else happens here:
- **Planner:** Today screen, tasks, SEQTA (school LMS), an agent Inbox and an MCP server.
- **Mini office suite:** **Docs** first (plain `.md` files), then Sheets (`.xlsx`) and Slides
  (`.pptx`) later, plus a **Whiteboard** (Excalidraw, `.excalidraw` files). Docs/Sheets/Slides come
  from a copied snapshot of GenOffice (Apache-2.0).

It's personal software for one user, a Year 9 student in Australia. There are no accounts, no
cloud backend and no other users.

## Current status

- **Building Phase 1 + 2 straight through** (decided 2026-11-09; see "How we work").
- Done and in PRs (stacked; merge in order, with merge commits): #4 Writer (M1 step 2) → #5 shared
  base (all sidebar pages, tokens in `Sources/Atlantis/Design`, `VaultPaths`/`TextFile`) → #6 Inbox,
  #7 SEQTA sync engine + cache, #8 Tasks, #9 MCP plumbing (`atlantis-mcp`), #10 Docs search +
  pasted images (M1 done).
- Phase 1 built (2026-11-10): + #11 Today/SEQTA→Inbox/daily note, #12 Subjects + Messages,
  #13 MCP tools + allow list. `p1/integration` merges everything (282 Swift tests).
- Phase 2 built (2026-11-10): + #14 M5 agent runtime (`atlantis-agentd`, School), #15 M6 bots as
  teammates (assign, @mention, autonomy), #16 M7 triggers, Chief/Scout, Today Team card, End of Day.
  `p1/integration` merges everything (389 Swift + 76 web tests).
- Whiteboard built early (2026-11-11, user's ask): Excalidraw 0.18.1 in `web/whiteboard`, boards in
  iCloud Drive/Whiteboards, MCP tools `atlantis_whiteboard*` so T3 Code can draw. PR #17, merged
  into `docs/history-record` (with the Docs edit history / writing record work).
- `main` only had up to #4: every later PR merged into the branch below it. Branch
  `release/to-main` (= `docs/history-record`, which holds all of #5–#17) brings it all to `main`.
  From now on, open fix PRs against `main`.
- Fix PR 1 (2026-11-11, `fix/small-bugs-1`): Inbox drafts, Whiteboard crash handler, plan observer,
  SEQTA file id check. The installed app now has the Whiteboard.
- **Now: fixing phase.** Work through `docs/issues.md` slowly, starting with what the user finds
  in the real app. Phase 3 (M8 Docs+, M9 rituals + design pass) waits until then.
- Not live-tested yet: SEQTA sync against real SEQTA (needs the user signed in).
- Left from M0: the Gallery screen waits for the user's design.

Update this section whenever a milestone starts or finishes.

## Stack (decided)

- Native macOS app: Swift + SwiftUI, **SwiftPM, no Xcode project**, macOS 15.4+.
- Built up from `~/Developer/seqta-app`. Copy its SEQTA pieces in (WKWebExtension running the
  BetterSEQTA+ fork, the LifeOS bridge, the file chooser); don't link to that repo.
- Docs editor: WKWebView running GenOffice's markdown editor (Tiptap/ProseMirror), copied in
  as a fixed snapshot. Its Electron main/preload layer is replaced by Swift and a JS bridge.
  Ideas from GenOffice's `docs` app get ported into it. **Strip all GenOffice AI**: use
  Atlantis's own Claude client, or no AI. Never copy GenOffice's `ee/` folder.
- AI: Claude through the user's subscription via the official Claude Code CLI run headless
  (MCP tools only), plus a cheap API worker/fallback (key in the Keychain). See PRD §7b. Never
  send SEQTA or personal data to non-Claude cloud providers.
- Agents: a bundled `atlantis-mcp` stdio helper that talks to the app over a local socket.

## Data rules (do not break)

- **Everything stays local.** Every file lives on this Mac, with no cloud service.
- **No own database.** Data lives in plain files:
  - Docs → Writer projects in `~/Library/Mobile Documents/com~apple~CloudDocs/Writer` (PRD §7a)
  - Tasks → LifeOS vault `machine/tasks.md` (format in PRD §9)
  - Inbox → LifeOS vault `machine/atlantis/inbox.md`
  - Whiteboards → `.excalidraw` files in `~/Library/Mobile Documents/com~apple~CloudDocs/Whiteboards`
  - Daily notes → LifeOS `daily/`. Write **only** the machine-owned parts (see the vault's AGENTS.md)
- LifeOS vault path: `~/Library/Mobile Documents/com~apple~CloudDocs/LifeOS`. Never write to
  its `human/` folder.
- **Markdown round trip:** opening and saving a doc without changes must leave the file
  byte-identical (the Writer keeps a file's own front matter bytes unless a field changed).
  Every Docs change must keep this test passing: `npm test` in `web/docs-editor`
  (add real folders with `ATLANTIS_RT_CORPUS=dir1:dir2`) and the in-app check
  `Atlantis -debugRoundTrip "dir1:dir2"`.
- Write files atomically, and change only what changed. Other tools (Obsidian, agents) may
  edit the same files.
- Agent writes go to the Inbox for approval unless the user has allowed that action.

## Hard rules

- Credentials go in the macOS Keychain or a git-ignored `.env`. Never put them in the repo,
  logs or docs.
- SEQTA: at most one automatic sync per morning, plus manual refreshes. No polling.
- SEQTA messages are sent only by the user, from the Messages compose view with an explicit Send
  and a confirm (PRD §7d). Bots and MCP tools never send; they can only draft into the Inbox.
- The SEQTA web tab is temporary (PRD §7d). Don't build new features on it or on BetterSEQTA+;
  put them in native pages fed by the SEQTA cache.
- Keep v1 scope to PRD §7. New ideas go to PRD §7 "v3+: Later", not into the code.
- Commit only when the user asks (they have: milestone branches + PRs, see "How we work").
- **Idle = zero work.** No polling or repeating timers. Live web views are the visible ones plus
  one warm Docs editor. Budgets are in PRD §17.
- **Narrow bridge:** the Docs page only gets the `WriterFiles` operations (text files inside the
  Writer folder) plus export/import/open; never widen it to other folders. Check paths in
  Swift. The Whiteboard page gets only "save the open board" (Swift picks the board, the page never
  names a file). Browser panels get no bridge.
- **Make every web view through `WebViews`** (`Sources/Atlantis/WebViews.swift`) with
  `network: .none` unless it truly needs the web. Only the temporary SEQTA tab uses `.open`.
- **MCP and agent sockets are Unix sockets with `0600` permissions and a peer-UID check, never TCP.**
- **No network** except SEQTA and the AI providers set in Settings. No telemetry.
- Bots (PRD §7b) never send SEQTA messages, never get shell access, and treat what they read
  as data, not instructions.
- Every screen uses the shared design tokens. No raw colours or spacing numbers.

## Design

Calm and polished, in Chris Raroque's style, with TickTick-level clarity. Keyboard-first,
light and dark mode, small animations. Sidebar: see PRD F7.

**Build now, design pass later (changed 2026-11-09).** Screens are built with plain macOS /
SwiftUI system styling, using only the shared tokens in `Sources/Atlantis/Design` (no raw colours
or spacing numbers), so one design pass can restyle the whole app later. When the user's design
is approved, restyle screens to match it and compare screenshots against it.

## Related

- `~/Developer/seqta-app`: source of the SEQTA web view code
- `~/Developer/BetterSEQTA-Plus`: the extension fork (`npm run build:safari`)
- `~/Developer/seqta-mcp`: MCP for SEQTA reads today; Atlantis's own MCP read tools take over (PRD §7d)
- AI Dock and Tinycast (planned apps): connect through the shared layer described in PRD §10

## How we work (changed 2026-11-09)

- **Build first, fix later.** Phase 1 and Phase 2 (M1 rest → M7) were built straight through
  (done 2026-11-10); now fix issues slowly, one small PR at a time.
- **One main thread** plans, reviews and merges. Helper agents may build milestones or parts of them in their own worktrees (user OK 2026-11-09): Sonnet 5.5, Haiku 5.5, or Opus 5.5 at medium/high. Never `max` effort on any model; `xhigh` only for Haiku or the single biggest Opus task.
- **Branch + PR per milestone:** each milestone gets its own branch (stacked on the previous one
  if it isn't merged yet) and a GitHub PR with a short "try this" list (2–5 things). The user
  merges. Never push to `main` directly. Committing and pushing milestone branches is allowed.
- **The user tests in the real app** whenever they like. Problems go in `docs/issues.md`; they
  get fixed after the Phase 1 + 2 build, unless they block further work.
- **Repo is public** (`maxwakelin8-a11y/Atlantis`, MIT): never commit personal data, vault
  contents, SEQTA data or secrets. Commit as the GitHub noreply identity.

## Every run

Add a short dated entry to `docs/log.md`: what changed, any problems, the next step. Add
reusable lessons to `docs/findings.md`.
