# Findings

Reusable lessons (dated bullets).

- 2026-11-06: Command Line Tools only (no Xcode): `swift test` builds Swift Testing suites but
  never runs them and exits 0, even with a failing test. Fix: tests as an executable target that
  calls `Testing.__swiftPMEntryPoint()`, with `-F` and rpaths to
  `/Library/Developer/CommandLineTools/Library/Developer/{Frameworks,usr/lib}` (see Package.swift).
  Always check that a deliberately failing test fails.
- 2026-11-06: `NSView.cacheDisplay` doesn't draw sidebar materials or glass, so screenshots look
  wrong. Use `screencapture -x -o -l <windowNumber>` for real window captures.
- 2026-11-06: `NSHostingController` shrinks its window to the SwiftUI ideal size by default; set
  `sizingOptions = []` when the window should keep its own size.
- 2026-11-06: WebKit content-blocker `url-filter` regexes don't support `|` ("Disjunctions are
  not supported yet"). Use one rule per pattern. The JSON compiles only at runtime, so check it
  in the real app (`-debugNetworkCheck YES`), not just in unit tests.
- 2026-11-06: In SwiftUI, `.onAppear` placed after `.id(x)` doesn't run again when `x` changes;
  put it before `.id` to run per identity.
- 2026-11-06: The first one or two launches after re-signing the app are 1–2.6 s slower (macOS
  checks the new binary). Judge launch time on warm launches.
- 2026-11-06: WKWebView doesn't paint while its window is covered (document.visibilityState is
  "hidden"), so `screencapture` shows it blank. Debug screenshots draw each web view's
  `takeSnapshot` on top. Draw into a `CGContext`; an `NSBitmapImageRep` made from a PNG
  silently isn't drawable.
- 2026-11-06: GenOffice's markdown save is block-level (`sourceSplice.ts`): unchanged blocks are
  copied verbatim from the source and only edited runs are re-serialized, plus an "unchanged doc
  → original bytes" shortcut. Keep both when touching the editor.
- 2026-11-06: Reading iCloud vault files the first time can take a minute (downloads); time
  editor work on a second run.
- 2026-11-07: GenOffice's UI language is a module variable that starts as `'zh'` (set by its
  Electron shell). Render its `LocaleProvider` with `'en'` (also around every `EditorContent`,
  since its React node views read the context), with a stub `window.markdownApi`.
- 2026-11-07: GenOffice's `Highlight` mark has no commands; tiptap toolbars expecting
  `toggleHighlight` need a tiny extension. Underline is off in GenOffice (not GFM).
- 2026-11-07: A core tiptap `Editor` can be shown through `@tiptap/react`'s `EditorContent`
  (render with `flushSync` before loading content) so React node views work in non-React UI.
- 2026-11-07: Don't use `.terminateLater` and then wait on `callAsyncJavaScript`: WebKit's reply
  never arrives in that run-loop mode. Return `.terminateCancel`, save, then terminate again.
- 2026-11-07: `WKScriptMessageHandlerWithReply` sends Swift `nil` to JS as `undefined`, not
  `null`; compare with `!= null`.
- 2026-11-07: `WKWebsiteDataStore(forIdentifier:)` gives a web view its own persistent store
  (localStorage survives relaunch) without sharing cookies with the SEQTA tab.

## 2026-11-09
- Helper agents in fresh T3 worktrees can't `npm ci` (certificate error / hang). Copy the main
  checkout's git-ignored `Resources/DocsEditor` (or `web/docs-editor/node_modules`) instead.
- Hidden-window `-debugSnapshot` doesn't paint late DOM changes in WebKit (page reports `hidden`,
  0×0 viewport); screenshot web UI in headless Chromium with sample data instead.
- Stacked PRs: merge with merge commits (not squash) so later PRs' diffs shrink by themselves.
