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
