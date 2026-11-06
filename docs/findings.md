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
