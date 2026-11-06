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

swift build -c $CONFIG --product Atlantis
APP=build/Atlantis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Atlantis" "$APP/Contents/MacOS/Atlantis"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signed with the hardened runtime (PRD §17).
codesign --force --options runtime --sign - "$APP"
echo "Built $APP ($CONFIG)"

if (( INSTALL )); then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Atlantis.app
  cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/Atlantis.app"
fi
