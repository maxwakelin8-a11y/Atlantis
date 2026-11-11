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

## 2026-11-10
- Claude Code CLI 2.1.x headless lockdown: `--tools ""` removes every built-in tool, and
  `--setting-sources ""` is needed too, or the user's plugins still run SessionStart hooks that
  inject context (the Vercel plugin did). `--strict-mcp-config` keeps other MCP servers out.
  Check the lockdown at runtime: the `system/init` line lists the tools the model will get.
- `claude -p` with a stream-json input and stdin at EOF exits without calling the API, so flags
  can be checked for typos for free (an unknown flag errors at once). `--max-turns` works though
  `--help` doesn't list it.
- A killed child's grandchildren can keep its stdout pipe open, so a blocking read never sees
  EOF. Read with `poll()` on the pipe plus a wake pipe written by `terminationHandler`.
- `-debugSnapshot` falls back to `cacheDisplay` when the display is asleep (screencapture gives
  black). That draws no window background (dark mode looked white) and no sidebar materials; the
  fallback now fills the window background first. The main sidebar still comes out blank.
- Inbox items carry proposal-only fields (`origin`, `thread`, `run`); `InboxTaskActions` copies
  every non-reserved field onto the task, so new link fields must go in its reserved list.
- Writer page tests in jsdom: the page focuses the doc's start in a `setTimeout` after opening a
  project; wait a tick before moving the selection, or it jumps back to position 1.
- Bash heredocs: a Python script in `<<'EOF'` that itself contains `<<'EOF'` lines (shell
  fixtures) ends early. Write such scripts to a file first.
- Live bot checks next to another running Atlantis (the installed app, or a debug build someone
  left open): set `ATLANTIS_MCP_SOCKET` and `ATLANTIS_AGENTD_SOCKET` to a fresh `mktemp -d`
  folder. Otherwise the CLI's helper reaches the other app's socket, sees the wrong tool list and
  the lockdown check stops the run ("offered more than Coach's own tools").
- An `ask` bot started by a trigger would wait on an approval card no one sees and hold the
  one-at-a-time queue; unattended runs use `suggest` instead (`Autonomy.unattended`).
- `-debugSnapshot` with a sheet open: capture `window.attachedSheet` (its own window), and end the
  sheet before `NSApp.terminate`, or the app never quits.
- 2026-11-10: In a selectable SwiftUI `List` on macOS, put `.tag` **last** on a row. `.badge` after
  `.tag` drops the tag, so the row can't be selected (clicks do nothing, the binding's setter never
  runs). To test sidebar selection without the mouse, set `selected of row n of outline 1 …` to
  true through System Events and read the window title; it fails the same way a click does. A
  window on another Space has no accessibility windows until the app is frontmost.
- 2026-11-11: ProseMirror tags pastes and drops with `tr.getMeta("uiEvent")` ("paste"/"drop") and
  undo/redo with the `"history$"` meta, so a transaction's typed vs pasted text can be measured
  from its steps (`record.ts measure`). Don't launch a second Atlantis copy to test while the
  user's app is running: both use the same MCP socket path and the copy removes it at quit.
- 2026-11-11 (Whiteboard): `npm` here fails with UNABLE_TO_GET_ISSUER_CERT_LOCALLY; run it with
  `NODE_OPTIONS=--use-system-ca` (and outside the sandbox). Excalidraw 0.18 ships ES modules with
  lazy chunks and `import.meta.url`: bundle it with esbuild `format: 'esm', splitting: true`, load
  `board.js` as `type="module"`, and set `window.EXCALIDRAW_ASSET_PATH` to the bundle's own origin
  before Excalidraw loads, or fonts come from a CDN (blocked: the web view has no network).
- In a WKWebView whose window is covered, `requestAnimationFrame` never fires: don't gate startup
  work on it (use a timer). Don't wrap Excalidraw in React `StrictMode`: the double mount hands
  `excalidrawAPI` an instance that's thrown away, so `updateScene` and reads do nothing.
- Excalidraw's `onChange` fires for scrolls, zoom and selection too. Decide "needs saving" from
  element versions + background + file ids (`sceneKey`), taken from the restored file on open, so
  opening a board never rewrites it.
- Unix socket paths max out at 104 bytes: the scratchpad path is too long for `ATLANTIS_MCP_SOCKET`;
  use a short one. A test copy with its own socket and `-whiteboardsPath <dir>` runs fine next to
  the user's app. Two calls in one `atlantis-mcp` stdin batch run in parallel (order isn't kept).
