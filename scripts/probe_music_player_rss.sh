#!/usr/bin/env bash
set -euo pipefail

duration="${1:-300}"
interval="${2:-30}"

if ! [[ "$duration" =~ ^[0-9]+$ ]] || ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -eq 0 ]]; then
  echo "Usage: scripts/probe_music_player_rss.sh [duration_seconds] [interval_seconds]" >&2
  exit 64
fi

samples=$((duration / interval))
if [[ "$samples" -lt 1 ]]; then
  samples=1
fi

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

sample_rss() {
  ps -axo pid=,rss=,comm= | awk '
    /\/WindowServer$/ { window_pid=$1; window_rss=$2 }
    /\/MediaLib$/ || /\/MediaLIB$/ { media_pid=$1; media_rss=$2 }
    END {
      printf "%s %s %s %s\n",
        (window_pid == "" ? "-" : window_pid),
        (window_rss == "" ? "0" : window_rss),
        (media_pid == "" ? "-" : media_pid),
        (media_rss == "" ? "0" : media_rss)
    }
  '
}

read -r initial_window_pid initial_window_rss initial_media_pid initial_media_rss < <(sample_rss)

echo "timestamp,windowserver_pid,windowserver_rss_kb,windowserver_delta_mb,medialib_pid,medialib_rss_kb,medialib_delta_mb"

for index in $(seq 0 "$samples"); do
  if [[ "$index" -gt 0 ]]; then
    sleep "$interval"
  fi
  read -r window_pid window_rss media_pid media_rss < <(sample_rss)
  window_delta_mb=$(awk -v current="$window_rss" -v initial="$initial_window_rss" 'BEGIN { printf "%.1f", (current - initial) / 1024 }')
  media_delta_mb=$(awk -v current="$media_rss" -v initial="$initial_media_rss" 'BEGIN { printf "%.1f", (current - initial) / 1024 }')
  echo "$(timestamp),$window_pid,$window_rss,$window_delta_mb,$media_pid,$media_rss,$media_delta_mb"
done
