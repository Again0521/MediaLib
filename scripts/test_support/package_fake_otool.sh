#!/bin/sh
if [ "$1" = "-L" ]; then
  printf '%s:\n' "$2"
  if [ -n "${FAKE_DEPENDENCY:-}" ]; then
    printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$FAKE_DEPENDENCY"
  fi
  exit 0
fi
exit 1
