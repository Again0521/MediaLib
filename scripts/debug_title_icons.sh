#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

node scripts/debug_title_icons.mjs
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift run MediaLib \
  --debug-title-icons \
  --debug-title-icons-output Build/TitleIconDebug
