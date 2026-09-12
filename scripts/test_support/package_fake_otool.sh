#!/bin/sh
if [ "$1" = "-L" ]; then
  printf '%s:\n' "$2"
  if [ -n "${FAKE_DEPENDENCY:-}" ]; then
    printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$FAKE_DEPENDENCY"
  fi
  exit 0
fi
if [ "$1" = "-l" ]; then
  if [ -n "${FAKE_RPATH:-}" ]; then
    printf 'Load command 0\n'
    printf '          cmd LC_RPATH\n'
    printf '      cmdsize 48\n'
    printf '         path %s (offset 12)\n' "$FAKE_RPATH"
  fi
  exit 0
fi
if [ "$1" = "-D" ]; then
  printf '%s:\n' "$2"
  exit 0
fi
exit 1
