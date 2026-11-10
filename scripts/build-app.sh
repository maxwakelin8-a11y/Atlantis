#!/bin/zsh
# Builds build/Atlantis.app. Usage: scripts/build-app.sh [--install] [--debug]
#   --install  also copies it to ~/Applications
#   --debug    debug build (faster to build, slower to run)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case $arg in
    --install) INSTALL=1 ;;
    --debug) CONFIG=debug ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Docs editor bundle (web/docs-editor → Resources/DocsEditor), rebuilt when its sources change.
EDITOR=web/docs-editor
if [[ ! -f Resources/DocsEditor/editor.js ]] || [[ -n "$(find $EDITOR/src $EDITOR/vendor $EDITOR/build.mjs $EDITOR/package-lock.json -newer Resources/DocsEditor/editor.js 2>/dev/null | head -1)" ]]; then
  (cd $EDITOR && { [[ -d node_modules ]] || npm ci --no-audit --no-fund; } && npm run build --silent)
fi

# One product per call: swift build only keeps the last --product flag.
for product in Atlantis atlantis-mcp atlantis-agentd; do
  swift build -c $CONFIG --product $product
done
APP=build/Atlantis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Atlantis" "$APP/Contents/MacOS/Atlantis"
# MCP stdio helper: agents run this; it forwards to the app's local socket (PRD §8).
cp ".build/$CONFIG/atlantis-mcp" "$APP/Contents/MacOS/atlantis-mcp"
# Agent daemon: the app starts it on the first bot chat; it exits when idle (PRD §7b).
cp ".build/$CONFIG/atlantis-agentd" "$APP/Contents/MacOS/atlantis-agentd"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/DocsEditor "$APP/Contents/Resources/DocsEditor"

# Ad-hoc signed with the hardened runtime (PRD §17).
codesign --force --options runtime --sign - "$APP/Contents/MacOS/atlantis-mcp"
codesign --force --options runtime --sign - "$APP/Contents/MacOS/atlantis-agentd"
codesign --force --options runtime --sign - "$APP"
echo "Built $APP ($CONFIG)"

if (( INSTALL )); then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Atlantis.app
  cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/Atlantis.app"
fi
