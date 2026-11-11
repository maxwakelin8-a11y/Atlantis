# Atlantis

The main Mac app: planner (Today, tasks, SEQTA, agent inbox) + a mini office suite (Docs first) and
a Whiteboard (Excalidraw).

- Spec: [docs/PRD.md](docs/PRD.md)
- Agent guide: [AGENTS.md](AGENTS.md)

## Build and run

Needs macOS 15.4+, the Command Line Tools (no Xcode project) and Node 22 (for the Docs editor
and Whiteboard bundles, which `build-app.sh` builds from `web/docs-editor` and `web/whiteboard`
when their sources change).

    scripts/build-app.sh            # → build/Atlantis.app (release, hardened runtime)
    scripts/build-app.sh --install  # also copies it to ~/Applications
    scripts/test.sh                 # runs the Swift tests
    (cd web/docs-editor && npm test) # runs the editor round-trip tests
    (cd web/whiteboard && npm test)  # runs the whiteboard page tests

Screenshots for design checks (the app quits after saving):

    build/Atlantis.app/Contents/MacOS/Atlantis -debugAppearance dark -debugPage today -debugSnapshot /tmp/today-dark.png

Other debug flags: `-debugSnapshotDelay 8`, `-debugHUD YES`, `-debugNetworkCheck YES` (prints
whether locked-down web views are really offline), `-debugPageSequence "seqta:15,today:10"`,
`-debugSeqtaUnloadAfter 5`, `-debugPage docs -debugRoundTrip "dir1:dir2"` (Docs round trip in real WebKit,
read-only), `-writerPath <dir>` / `-whiteboardsPath <dir>` (use another Writer or Whiteboards folder for testing), and the
`ATLANTIS_DOCS_PROBE='<js>'` environment variable (runs JS in the Docs page and prints the result). The performance HUD is also in View ▸ Show Performance HUD (⌥⌘P), and
launch and page-switch intervals show in Instruments under Points of Interest.

## Agents and T3 Code

Atlantis's MCP server (docs, tasks, school data, whiteboards) works from Claude Code once added:

    claude mcp add --scope user atlantis -- ~/Applications/Atlantis.app/Contents/MacOS/atlantis-mcp

Atlantis must be open. Writes wait in the Inbox unless allowed in Settings ▸ Agents & MCP.

## Third-party code

- Docs editor: a snapshot of GenOffice (Apache-2.0), see `web/docs-editor/vendor/genoffice/SNAPSHOT.md`.
- Whiteboard: [Excalidraw](https://github.com/excalidraw/excalidraw) (MIT), from npm, bundled with its fonts.
