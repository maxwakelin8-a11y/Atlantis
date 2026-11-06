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
