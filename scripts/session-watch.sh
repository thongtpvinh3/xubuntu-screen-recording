#!/usr/bin/env bash
# Monitor one exact xfce4-session instance. Ask record.sh to stop when it ends.
# Invoked by record.sh; this helper NEVER directly sends signals to FFmpeg.
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE='/etc/screenrec/screenrec.conf'
XFCE_PID='' XFCE_START='' RECORD_PID='' RECORD_START='' FFMPEG_PID='' FFMPEG_START=''
SLEEP_PID=''

usage() {
  cat <<'HELP'
Usage: session-watch.sh --config PATH \
  --xfce-pid PID --xfce-start TICKS \
  --record-pid PID --record-start TICKS \
  --ffmpeg-pid PID --ffmpeg-start TICKS

Only record.sh should launch this helper. Tracks /proc/PID/stat starttime
(field 22) in addition to PID to reduce PID-reuse mistakes.
HELP
}
log() { printf '[screenrec-session] %s %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --config|--xfce-pid|--xfce-start|--record-pid|--record-start|--ffmpeg-pid|--ffmpeg-start)
      (($# >= 2)) || fail "$1 requires a value"
      case "$1" in
        --config) CONFIG_FILE=$2 ;;
        --xfce-pid) XFCE_PID=$2 ;;
        --xfce-start) XFCE_START=$2 ;;
        --record-pid) RECORD_PID=$2 ;;
        --record-start) RECORD_START=$2 ;;
        --ffmpeg-pid) FFMPEG_PID=$2 ;;
        --ffmpeg-start) FFMPEG_START=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

for v in XFCE_PID XFCE_START RECORD_PID RECORD_START FFMPEG_PID FFMPEG_START; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || fail "Invalid or missing $v"
done
"$SCRIPT_DIR/check-env.sh" --config "$CONFIG_FILE" --config-only >/dev/null \
  || fail 'Configuration validation failed'
# shellcheck source=/dev/null
source "$CONFIG_FILE"
poll=$((10#$SCREENREC_SESSION_POLL_SECONDS))

# Output the kernel starttime (clock ticks since boot) from field 22 of stat.
# Strip the pid and parenthesized comm first; fields are now indexed from 3.
proc_identity() {
  local pid=$1
  [[ -r "/proc/$pid/stat" ]] || return 1
  LC_ALL=C awk '{sub(/^.*\) /, ""); print $20, $1}' "/proc/$pid/stat" 2>/dev/null
}
same_process() {
  local actual state
  read -r actual state < <(proc_identity "$1") || return 1
  [[ -n "$actual" && "$actual" == "$2" && "$state" != Z && "$state" != X ]]
}

on_term() {
  trap - TERM INT HUP
  if [[ -n "$SLEEP_PID" ]]; then
    kill -TERM "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  log 'STOP requested; watcher exiting'
  exit 0
}
trap on_term TERM INT HUP

# A missing session at startup is treated as a session end: notify recorder.
# A mismatched recorder PID at startup instead indicates stale/bad arguments.
same_process "$RECORD_PID" "$RECORD_START" \
  || fail 'record.sh PID no longer matches the expected instance'
log "START xfce_pid=$XFCE_PID record_pid=$RECORD_PID ffmpeg_pid=$FFMPEG_PID poll=${poll}s"
while :; do
  # If our parent or FFmpeg finished, do not signal any other process.
  same_process "$RECORD_PID" "$RECORD_START" || exit 0
  same_process "$FFMPEG_PID" "$FFMPEG_START" || exit 0
  if ! same_process "$XFCE_PID" "$XFCE_START"; then
    log "SESSION_ENDED xfce_pid=$XFCE_PID; sending SIGTERM to record_pid=$RECORD_PID"
    # Narrow PID-reuse race remains between checking identity and kill().
    same_process "$RECORD_PID" "$RECORD_START" && \
      kill -TERM "$RECORD_PID" 2>/dev/null || true
    exit 0
  fi
  sleep "$poll" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" || true
  SLEEP_PID=''
done
