#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <verified-temp-dmg> <candidate-dmg> <public-dmg>" >&2
  exit 2
fi

TEMP_DMG_PATH="$1"
CANDIDATE_DMG_PATH="$2"
DMG_PATH="$3"
HDIUTIL="${MEDIALIB_HDIUTIL:-/usr/bin/hdiutil}"
DITTO="${MEDIALIB_DITTO:-/usr/bin/ditto}"

cleanup_candidate() {
  rm -f "$CANDIDATE_DMG_PATH"
}
trap cleanup_candidate EXIT

# Revalidate the exact source bytes immediately before crossing into dist.
"$HDIUTIL" verify "$TEMP_DMG_PATH"
"$DITTO" --noextattr --noqtn "$TEMP_DMG_PATH" "$CANDIDATE_DMG_PATH"
"$HDIUTIL" verify "$CANDIDATE_DMG_PATH"

# candidate and public paths share a filesystem, so readers see either the
# previous verified image or the complete new image, never a partial copy.
mv -f "$CANDIDATE_DMG_PATH" "$DMG_PATH"
trap - EXIT
