# Atlantis

The main Mac app: planner (Today, tasks, SEQTA, agent inbox) + a mini office suite (Docs first).

- Spec: [docs/PRD.md](docs/PRD.md)
- Agent guide: [AGENTS.md](AGENTS.md)

## Build and run

Needs macOS 15.4+, the Command Line Tools (no Xcode project) and Node 22 (for the Docs editor
bundle, which `build-app.sh` builds from `web/docs-editor` when its sources change).

    scripts/build-app.sh            # → build/Atlantis.app (release, hardened runtime)
    scripts/build-app.sh --install  # also copies it to ~/Applications
    scripts/test.sh                 # runs the Swift tests
    (cd web/docs-editor && npm test) # runs the editor round-trip tests

Screenshots for design checks (the app quits after saving):

    build/Atlantis.app/Contents/MacOS/Atlantis -debugAppearance dark -debugPage today -debugSnapshot /tmp/today-dark.png

Other debug flags: `-debugSnapshotDelay 8`, `-debugHUD YES`, `-debugNetworkCheck YES` (prints
whether locked-down web views are really offline), `-debugPageSequence "seqta:15,today:10"`,
`-debugSeqtaUnloadAfter 5`, `-debugRoundTrip "dir1:dir2"` (Docs round trip in real WebKit,
read-only), `-docsPath <dir>` with `-debugOpenDoc <file>` (open a doc from another folder). The performance HUD is also in View ▸ Show Performance HUD (⌥⌘P), and
launch and page-switch intervals show in Instruments under Points of Interest.
