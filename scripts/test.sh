#!/bin/zsh
# Runs all tests. Usage: scripts/test.sh [--filter <name>]
# (`swift test` builds but doesn't run Swift Testing suites with only the Command Line Tools.)
set -euo pipefail
cd "$(dirname "$0")/.."
swift run AtlantisTests "$@"
