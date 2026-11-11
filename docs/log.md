# Log

## 2026-11-03
- Project folder created with PRD, AGENTS.md. Next: M0 repo setup from seqta-app.

## 2026-11-03 (later)
- Decided: build the office suite from GenOffice (Apache-2.0). Its markdown editor becomes
  Atlantis **Docs**, with ideas ported from its Word-style docs app. Replaces Milkdown. GenOffice
  AI is removed (Atlantis's own Claude or none). Sheets/Slides may use .xlsx/.pptx as long as the
  files stay local. Updated PRD §5, §7a, §11, §12 (M1 spike), §15, §16 and AGENTS.md.
- Proposed: an Excalidraw-style whiteboard in native Swift (PRD §16 Q5). Not scheduled yet.
- Next: the M1 spike (GenOffice markdown renderer in a WKWebView + the round-trip test).

## 2026-11-03 (roadmap)
- Set the build order in PRD §12: Phase 0 foundations (M0) → 1 daily driver (M1–M4) → 2 bot
  team (M5–M7) → 3 Docs+ and polish (M8–M9) → 4 workspace: browser, whiteboard, Sheets, Slides
  (M10–M13) → 5 autopilot. Added §7b Agents, §7c Workspace, §17 performance/resources/security,
  and new hard rules in AGENTS.md.
- Open: which projects "openbot" and "Grok bot" are (PRD §16 Q6).
- Next: M0, the SwiftPM shell, SEQTA tab from seqta-app, tokens + Gallery.

## 2026-11-04
- Agreed how we work (AGENTS.md "How we work"): one main thread, approve each step,
  branch + PR per step, the user tests in the real app, issues in `docs/issues.md`.
- AI: Claude via the subscription (Claude Code headless), Opus-lead + cheap-worker fusion mode,
  and a cheap fallback that never sees SEQTA data (PRD §7b).
- Design: done first with Claude design artifacts, before any code.
- Repo: using the existing public GitHub repo `maxwakelin8-a11y/Atlantis`; planning docs go in
  as the first PR, built fresh on GitHub's first commit (repo-local noreply identity).
- Next: the design step (mood board → Design System → 4 key screens).

## 2026-11-06
- M0 step 1, app base: SwiftPM package (`Atlantis` app, `AtlantisCore` logic, `AtlantisTests`),
  AppKit-hosted SwiftUI window with a system-styled sidebar (Today · SEQTA, Settings at the
  bottom), placeholder pages, Go menu (⌘1–2) and ⌘, for Settings, remembered page and window
  frame. `scripts/build-app.sh` (hardened runtime, ad-hoc signed) and `scripts/test.sh`.
  Debug launch flags `-debugAppearance`, `-debugPage`, `-debugSnapshot` for screenshots.
- Problem: with only the Command Line Tools, `swift test` builds Swift Testing suites but runs
  none (silently passes). Tests are now an executable target run by `scripts/test.sh`.
- Next: M0 step 2, move the SEQTA tab (WKWebExtension + BetterSEQTA+) in from seqta-app.
- M0 step 2, SEQTA tab: copied from seqta-app the web-extension host (BetterSEQTA+, staged as an
  MV3 background page), pop-up login windows, downloads and the file chooser. SEQTA loads only
  the first time its page is opened. Link rules moved to `AtlantisCore/SeqtaLinks` with tests.
  Settings page (system form): SEQTA address, BetterSEQTA+ folder, version. View menu: Reload ⌘R,
  Back ⌘[, Forward ⌘], SEQTA Home ⇧⌘H, BetterSEQTA+ Settings ⌥⌘,.
- Left out on purpose: the LifeOS bridge (lets the page write anywhere in the vault, which breaks
  the narrow-bridge rule) and the Google Drive/Docs panes and Google export (extra network).
- The school's SEQTA address isn't in the code (public repo); it lives in local defaults.
- Checked: BetterSEQTA+ loads and SEQTA reaches the Microsoft sign-in. Idle on Today: 0% CPU,
  ~68 MB. Atlantis has its own website data, so you sign in to SEQTA once again.
- Next: M0 step 3, performance HUD + signposts and the security baseline.
- Decided: phase out the SEQTA tab (PRD §7d). Each SEQTA feature moves to a native page
  (Today, Tasks, Inbox, Subjects with per-subject sidebar sub-items, Messages), fed by a hidden
  sync engine and a local JSON cache that MCP also reads. Messages work both ways: you can
  send (explicit Send + confirm); bots and MCP only draft. Updated PRD §3, F3, F7, §7b, §7d,
  §8, §9, §12 (new M4b), §14, §15 and the AGENTS.md hard rules.
- M0 step 3, performance + security baseline: performance HUD (View ▸ ⌥⌘P: CPU, memory,
  wake-ups, live web views, launch, page switch; measures only while showing), signposts for
  launch and page switches, `Keychain` wrapper, `ContentRules` + `WebViews` factory (network
  blocked by default; checked live with `-debugNetworkCheck`: PASS), hidden SEQTA page unloads
  after 10 min (checked: 1 live web view → 0).
- Measured: warm launch ~470 ms (first launch after a rebuild 1.1–2.6 s, likely macOS checking
  the new signature), page switch 20 ms, idle on Today 0% CPU.
- Problem: WebKit content-rule regexes reject `|`; rules are now one pattern each, with a test.
- M0 is done except tokens + Gallery, which wait for the approved design.
- Next: M1 spike (GenOffice markdown editor in a WKWebView + the round-trip test).

## 2026-11-06 (M1 spike)
- GenOffice snapshot (commit 39374eb) trimmed to the 54 files the editor uses, in
  `web/docs-editor/vendor/genoffice` (no AI, no Electron, no `ee/`; see SNAPSHOT.md). Atlantis
  entry, session and narrow bridge in `web/docs-editor/src`, bundled with esbuild into
  `Resources/DocsEditor` (~1.8 MB; diagrams stubbed).
- Swift: `DocFolder` (paths stay in ~/Documents/Docs, UTF-8 only, atomic writes, no write when
  unchanged, refuses to overwrite outside edits), Docs page with file list + editor, autosave
  1.5 s after the last edit, ⌘S, New Doc ⌥⌘N, save on quit. Editor web view: network `.none`,
  served from a custom scheme, one warm view.
- **Spike result: pass.** No-edit save byte-identical on fixtures and 93/93 real files (vault +
  ~/Developer) in real WebKit, and 97/97 in Node. GenOffice's block splice was exact on all of
  them even without the "unchanged" shortcut. A one-word edit changes only its line (checked in
  the app with a diff). Slowest open+serialize 177 ms (budget 300). Idle with a doc open: 0% CPU.
- Problems: WebKit doesn't paint covered windows, so debug screenshots now paste each web view's
  own snapshot in. Pinned KaTeX had a CVE; now 0.18.2 (npm audit clean).
- Next: rest of M1 (search, image paste, folders, front matter panel, slash/table menus).

## 2026-11-07: M1 step 2, Docs becomes the Writer

- User: the editor was in Chinese and missing everything they need; copy the BetterSEQTA+ Writer.
- Fixed the Chinese (GenOffice's language defaults to zh).
- Copied the Writer (page, editor, binder, corkboard, outliner, inspector, find, "/" menu,
  comments, snapshots, templates, compile/export) into `web/docs-editor/src/writer`, and the
  Writer store from seqta-mcp (`store.ts`). Its editing runs on GenOffice's lossless editor; the
  store keeps front matter bytes unless a field changes and skips no-op writes. Files go through
  `DocsController` → `WriterFiles` (paths confined to the Writer folder, tested). Export via
  textutil / headless Chromium, import via textutil. Docs uses the same Writer folder, so the
  user's two projects open. `DocFolder` and the single-doc page are gone; no File menu.
- Results: 138 web tests and 23 Swift tests pass. Writer save path byte-identical on 88/88 real
  files (Node) and the in-app check 88/88 in real WebKit. An in-app edit changed only its line,
  front matter untouched. Idle with a project open: 0.03 s CPU in 30 s.
- Problems: quit hung (fixed); Claude/SEQTA Writer features are stubbed; outside edits can be
  overwritten (logged).
- Next: user tries it; then search across projects and pasting images.

## 2026-11-09: new way of working
- User: build the full app first (Phase 1 + 2), fix things slowly after. PR per milestone instead of
  approving each step; plain macOS styling via shared tokens until their design is ready; helper
  subagents (Sonnet 5.5 / Haiku 5.5) may build parts. AGENTS.md "How we work" and "Design" updated.
- Committed M1 step 2 (the Writer) as its own PR. Tests: 23 Swift, 49 web (round trip on fixtures).
- Next: M1 rest (search across projects, paste images), then M2 Tasks.

## 2026-11-09: Phase 1 build with helpers
- Shared base (#5), then helpers built in parallel worktrees: M1 search + pasted images (#10),
  Tasks (#8), SEQTA sync engine + cache (#7), MCP plumbing (#9), Inbox (#6). All merged on
  `p1/integration`: 208 Swift + 68 web tests pass; real `tasks.md` round-trips byte-identical
  (checked read-only); real Writer docs 18/18 byte-identical.
- Problems: Haiku helpers stop before doing any work here (context fills at startup), so Sonnet/Opus
  are used. Two helpers hit the API rate limit mid-task; their partial work was committed and
  resumed. `npm ci` hangs/fails in fresh worktrees (certificate error), so helpers copy
  `Resources/DocsEditor`/`node_modules` from the main checkout.
- Next: Today page, MCP tools, Subjects + Messages; then Phase 2 bots.

## 2026-11-10: Phase 1 built
- Landed: Today + SEQTA→Inbox + daily-note machine block + plan.json (#11), Subjects + Messages
  with user-only send behind a confirm (#12), all PRD §8 MCP tools + write allow list (#13).
  `p1/integration`: 282 Swift tests pass, app builds.
- Problems: API rate limits / errors stopped helpers 4 times; partial work was committed as WIP
  and resumed. Merge conflicts were only in AppModel/AppDelegate/DebugOptions wiring and one
  duplicated token, all resolved by hand.
- Needs a live check by the user: SEQTA sync, message bodies, file downloads, sending, dark mode
  of Subjects/Messages headers.
- Next: Phase 2 (M5 agent runtime + School bot).

## 2026-11-10: Phase 2 built, build phase done
- Landed: M5 agent runtime + School bot (#14), M6 assign/@mention/autonomy + Coach/Builder (#15),
  M7 triggers, Chief/Scout, Today Team card, End of Day (#16). `p1/integration`: 389 Swift +
  76 web tests pass. Live bot runs (haiku, made-up vault) all worked; total cost under $0.01.
- Problems: helpers stopped on API limits and when the Mac slept; resumed from WIP commits.
  All known gaps are now in docs/issues.md.
- Next: the user tries the real app (build from `p1/integration`); fix issues slowly.

## 2026-11-10: "can't click anything"
- User couldn't click properly. Found three Atlantis copies running with windows stacked at the
  same spot: the installed app (an old 7 Nov build) plus two leftover helper test copies on
  `/tmp` fixtures. Closed the test copies.
- `scripts/build-app.sh` was broken: `swift build` keeps only the last `--product`, so the app
  itself was never rebuilt. Fixed (one product per call), built and installed the current app.
- Next: user confirms clicking works in the new build; if not, get the exact page and control.

## 2026-11-10: sidebar rows couldn't be clicked
- User could only click Subjects in the sidebar. Reproduced in the installed app with real clicks:
  Today, Tasks, Inbox, Messages, Agents and Docs did nothing; SEQTA and Settings worked.
- Cause: in `RootView` the main rows had `.badge` after `.tag`, which drops the row's tag, so the
  list never reported a selection. Fixed by putting `.tag` last. Built, installed, relaunched.
- Checked: every sidebar row (and the subject rows on made-up data) opens its page; no test
  copies left running. Unit tests not rerun (one-line view change).
- Next: user keeps trying the app; this fix still needs its own small PR.

## 2026-11-10: model benchmark (Fable 5.2 vs Opus 5.5, both medium)
- Same brief, separate worktrees: shorten Chief hand-off Inbox titles. Both fixed it, added a
  test, 390 tests pass; nothing committed (worktrees t3-b993f271 Fable, t3-8f768a8d Opus).
- Fable: ~3.8 min, 13 tool calls, 6.9k output, 1.15M cache read, ~$1.6 at API rates.
  Opus: ~3.8 min, 18 tool calls, 6.0k output, 1.32M cache read, ~$0.7. Fable ≈ 2.3× the cost.
- Fable titled notes from the bot's answer; Opus trimmed the request. Pick one to ship as a PR.

## 2026-11-11: Docs edit history, writing record, notes to self
- User asked for an edit history from saves, a way to check everything they did in the Writer (for
  school authentication), and notes in the text that never export.
- Versions: the Writer now keeps the on-disk version before a save every 10 minutes (was once per
  6 h), skipping empty docs and copies equal to the newest one. History tab lists them by day with
  word changes; up to 300 shown.
- Writing record (`record.ts`, `recordView.ts`): typed/deleted/pasted characters per minute, every
  paste (first 400 characters; text copied inside the Writer counts as moving), restores, imports
  and outside changes, appended to `<project>/.writer-record.jsonl` within a minute and on flush.
  History → "Open writing record" (also the binder and project menus, the palette): stats, chart,
  sessions, pastes; "Save as PDF" into Exports. Swift's writable types gain `jsonl`.
- Notes to self: ```` ```note ```` blocks (⌥⌘J, "/note", toolbar), drawn as sticky notes by a small
  change to GenOffice's CodeBlockView; stripped from every export; already not counted as words.
- Tests: 95 web (new: record, notes, history-ui page test) + 389 Swift pass; round trip still
  byte-identical. Not tried by hand in the app: a second copy would share the MCP socket with
  the user's running app. Branch `docs/history-record`.
- Next: user tries it (quit and reopen Atlantis); PR after they're happy.

## 2026-11-11: Whiteboard (Excalidraw) + AI drawing over MCP
- User asked for a whiteboard using Excalidraw itself, usable by their AI in T3 Code. Looked at
  Excalidraw's "CLI" and MCP: there's no official CLI (only community ones), and the official MCP
  draws in a chat widget, not into files on this Mac. So Atlantis's own MCP gets the board tools.
- Built: `web/whiteboard` (Excalidraw 0.18.1, MIT; esbuild ESM bundle, fonts copied in, no
  network), Whiteboard page (native board list + canvas; new/rename/move to Bin/show in Finder),
  boards as `.excalidraw` files in iCloud Drive/Whiteboards. Saves are checked against the file's
  hash; on a conflict the page merges (Excalidraw's `reconcileElements`) and saves again.
- MCP: `atlantis_whiteboards_list`, `atlantis_whiteboard_read`, `atlantis_whiteboard_draw`
  (gated: Settings allow list "Draw on whiteboards", else an Inbox `whiteboard.draw` proposal),
  `atlantis_whiteboard_open`. Swift builds real elements (bound labels, arrows bound to shapes);
  the page measures their text in Excalifont on open and saves.
- Registered the `atlantis` MCP server in Claude Code (user scope) so T3 Code chats can use it.
- Committed the pending Docs history/record work on `docs/history-record`; whiteboard is on
  `m11/whiteboard` on top of it.
- Checked live in a test copy (own socket, scratch folder): drew a diagram over MCP, opened it,
  drew more while open; the page laid out and merged both. Tests: 404 Swift, 9 whiteboard web,
  95 Docs web pass. Found and fixed: StrictMode stale API, rAF paused in covered windows,
  `read` refusing names without `.excalidraw`.
- Next: user installs the new build (quit Atlantis, `scripts/build-app.sh --install`), turns on
  "Draw on whiteboards" in Settings if they want AI drawing without approval, and tries it.

## 2026-11-11: Landing everything on main
- Found `main` stops at PR #4: PRs #5–#17 were each merged into the branch below them (stack
  bases), ending in `docs/history-record`. Checked that branch has every change from all of them
  (the only commits missing are empty merge commits) and that merging it into `main` gives exactly
  the tested tree (404 Swift, 9 whiteboard web, 95 Docs web tests).
- Opened one PR, `release/to-main` → `main`, for the user to merge (merge commit).
- Next: after it's merged, fix PRs branch off `main` and target `main`; delete old stack branches
  if the user wants.
