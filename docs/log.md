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
