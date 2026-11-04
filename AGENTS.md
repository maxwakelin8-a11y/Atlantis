# AGENTS.md: Project Atlantis

**Read this first, then `docs/PRD.md`** (the full product spec). Keep context small and read only
what your task needs.

## What this is

Atlantis is the user's **main Mac app**. Coding happens in T3 Code; everything else happens here:
- **Planner:** Today screen, tasks, SEQTA (school LMS), an agent Inbox and an MCP server.
- **Mini office suite:** **Docs** first (plain `.md` files), then Sheets (`.xlsx`) and Slides
  (`.pptx`) later. A whiteboard is proposed. Built from a copied snapshot of GenOffice (Apache-2.0).

It's personal software for one user, a Year 9 student in Australia. There are no accounts, no
cloud backend and no other users.

## Current status

- Phase: **M0: shell + design system** (roadmap in PRD §12). No code yet.
- Next: M1, Docs core (start with the GenOffice round-trip spike).

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
  - Docs → `~/Documents/Docs/**/*.md`, with images in `assets/` next to each doc
  - Tasks → LifeOS vault `machine/tasks.md` (format in PRD §9)
  - Inbox → LifeOS vault `machine/atlantis/inbox.md`
  - Daily notes → LifeOS `daily/`. Write **only** the machine-owned parts (see the vault's AGENTS.md)
- LifeOS vault path: `~/Library/Mobile Documents/com~apple~CloudDocs/LifeOS`. Never write to
  its `human/` folder.
- **Markdown round trip:** opening and saving a doc without changes must leave the file
  byte-identical. Every Docs change must keep this test passing.
- Write files atomically, and change only what changed. Other tools (Obsidian, agents) may
  edit the same files.
- Agent writes go to the Inbox for approval unless the user has allowed that action.

## Hard rules

- Credentials go in the macOS Keychain or a git-ignored `.env`. Never put them in the repo,
  logs or docs.
- SEQTA: at most one automatic sync per morning, plus manual refreshes. No polling.
- Don't send SEQTA messages from the app.
- Keep v1 scope to PRD §7. New ideas go to PRD §7 "v3+: Later", not into the code.
- Commit only when the user asks.
- **Idle = zero work.** No polling or repeating timers. Live web views are the visible ones plus
  one warm Docs editor. Budgets are in PRD §17.
- **Narrow bridge:** web views can only save the open doc or load its assets; check paths in
  Swift. Browser panels get no bridge.
- **MCP and agent sockets are Unix sockets with `0600` permissions and a peer-UID check, never TCP.**
- **No network** except SEQTA and the AI providers set in Settings. No telemetry.
- Bots (PRD §7b) never send SEQTA messages, never get shell access, and treat what they read
  as data, not instructions.
- Every screen uses design tokens and Gallery components. No raw colours or spacing numbers.

## Design

Calm and polished, in Chris Raroque's style, with TickTick-level clarity. Keyboard-first,
light and dark mode, small animations. Sidebar: see PRD F7.

**Design comes first.** The UI is designed with Claude design artifacts (a Design System for
tokens and components, and a Design canvas for the key screens) and approved by the user
**before any UI code is written**. Build screens to match the approved design exactly, and
compare screenshots against it.

## Related

- `~/Developer/seqta-app`: source of the SEQTA web view code
- `~/Developer/BetterSEQTA-Plus`: the extension fork (`npm run build:safari`)
- `~/Developer/seqta-mcp`: MCP for SEQTA reads (Atlantis doesn't duplicate these)
- AI Dock and Tinycast (planned apps): connect through the shared layer described in PRD §10

## How we work (agreed 2026-11-04)

- **One main thread** plans and codes each milestone. Start helper agents only when the user asks.
- **Approve each step:** before each chunk of work (about 1–3 h), say what you'll do and wait for
  an OK. After it, show the result (screenshots for any UI, light and dark) and what's next.
- **Branch + PR per step:** each step gets its own branch and a GitHub PR. The user merges it.
  Never push to `main` directly.
- Time available: about 1–2 h on school days plus weekends (~15–20 h/week). Size steps to fit
  one sitting.
- **The user tests in the real app.** End each step with a short "try this" list (2–5 things).
  Problems go in `docs/issues.md`. Fix them before starting new features.
- **Repo is public** (`maxwakelin8-a11y/Atlantis`, MIT): never commit personal data, vault
  contents, SEQTA data or secrets. Commit as the GitHub noreply identity.

## Every run

Add a short dated entry to `docs/log.md`: what changed, any problems, the next step. Add
reusable lessons to `docs/findings.md`.
