#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  swift run MediaLib \
  --debug-title-icons \
  --debug-title-icons-output "${1:-/private/tmp/MediaLib-title-icons}"
