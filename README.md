# Atlantis

The main Mac app: planner (Today, tasks, SEQTA, agent inbox) + a mini office suite (Docs first).

- Spec: [docs/PRD.md](docs/PRD.md)
- Agent guide: [AGENTS.md](AGENTS.md)

## Build and run

Needs macOS 15.4+ and the Command Line Tools (no Xcode project).

    scripts/build-app.sh            # → build/Atlantis.app (release, hardened runtime)
    scripts/build-app.sh --install  # also copies it to ~/Applications
    scripts/test.sh                 # runs the tests

Screenshots for design checks (the app quits after saving):

    build/Atlantis.app/Contents/MacOS/Atlantis -debugAppearance dark -debugPage today -debugSnapshot /tmp/today-dark.png
