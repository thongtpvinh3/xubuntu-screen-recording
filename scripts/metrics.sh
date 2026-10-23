#!/usr/bin/env bash
# Sample interval CPU%, resident RAM and filesystem capacity for one FFmpeg PID.
# Independent of X11; stdout/stderr go to the parent service's journal.
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE='/etc/screenrec/screenrec.conf'
FFMPEG_PID='' FFMPEG_START=''
SLEEP_PID=''

usage() {
  cat <<'HELP'
Usage: metrics.sh [--config PATH] --ffmpeg-pid PID --ffmpeg-start TICKS
CPU interval percentage is relative to one logical CPU (may exceed 100%).
Collected via Linux /proc/PID/stat; RSS from ps; disk via df -Pk.
HELP
}
log() { printf '[screenrec-metrics] %s %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --config|--ffmpeg-pid|--ffmpeg-start)
      (($# >= 2)) || fail "$1 requires a value"
      case "$1" in
        --config) CONFIG_FILE=$2 ;;
        --ffmpeg-pid) FFMPEG_PID=$2 ;;
        --ffmpeg-start) FFMPEG_START=$2 ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
for v in FFMPEG_PID FFMPEG_START; do
  [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || fail "Invalid or missing $v"
done
"$SCRIPT_DIR/check-env.sh" --config "$CONFIG_FILE" --config-only >/dev/null \
  || fail 'Configuration validation failed'
# shellcheck source=/dev/null
source "$CONFIG_FILE"
interval=$((10#$SCREENREC_METRICS_INTERVAL_SECONDS))
clk_tck=$(getconf CLK_TCK) || fail 'getconf CLK_TCK failed'
[[ "$clk_tck" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid clock tick rate'

# Linux /proc/PID/stat fields 14, 15, 22 = utime, stime, starttime.
# After removing pid + (comm), these are fields 12, 13, 20.
proc_sample() {
  [[ -r "/proc/$FFMPEG_PID/stat" ]] || return 1
  LC_ALL=C awk '{sub(/^.*\) /, ""); print $12, $13, $20}' \
    "/proc/$FFMPEG_PID/stat" 2>/dev/null
}

on_term() {
  trap - TERM INT HUP
  if [[ -n "$SLEEP_PID" ]]; then
    kill -TERM "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  log 'STOP requested; metrics exiting'
  exit 0
}
trap on_term TERM INT HUP

read -r user_ticks system_ticks actual_start < <(proc_sample) \
  || fail 'Could not read FFmpeg initial CPU counters'
[[ "${actual_start:-}" == "$FFMPEG_START" ]] || fail 'FFmpeg PID does not match expected instance'
prev_total=$((user_ticks + system_ticks))
prev_ns=$(date +%s%N)
log "START ffmpeg_pid=$FFMPEG_PID interval=${interval}s clk_tck=$clk_tck"
while :; do
  sleep "$interval" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" || true
  SLEEP_PID=''

  sample=$(proc_sample) || { log 'STOP ffmpeg process exited'; exit 0; }
  read -r user_ticks system_ticks actual_start <<< "$sample"
  if [[ "$actual_start" != "$FFMPEG_START" ]]; then
    log 'STOP original ffmpeg PID exited (PID reuse detected)'
    exit 0
  fi
  now_ns=$(date +%s%N)
  total=$((user_ticks + system_ticks))
  delta_ticks=$((total - prev_total))
  delta_ns=$((now_ns - prev_ns))
  (( delta_ticks >= 0 && delta_ns > 0 )) || { log 'WARN invalid CPU sampling interval'; exit 1; }
  cpu_pct=$(LC_ALL=C awk -v t="$delta_ticks" -v clk="$clk_tck" -v ns="$delta_ns" \
    'BEGIN {printf "%.1f", 100 * (t / clk) / (ns / 1000000000)}')
  # RSS is KiB; 'ps %CPU' is deliberately NOT used (lifetime average).
  rss_kib=$(LC_ALL=C ps -p "$FFMPEG_PID" -o rss= 2>/dev/null | awk '{print $1}') || rss_kib=''
  disk_free_kib=$(LC_ALL=C df -Pk -- "$SCREENREC_DIR" 2>/dev/null | awk 'NR==2 {print $4}') || disk_free_kib=''
  log "PERF ffmpeg_pid=$FFMPEG_PID cpu_interval_pct=$cpu_pct rss_kib=${rss_kib:-unknown} disk_free_kib=${disk_free_kib:-unknown} interval_seconds=$interval"
  prev_total=$total
  prev_ns=$now_ns
done
