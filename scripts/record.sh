#!/usr/bin/env bash
# Main recorder: one XFCE/X11 session -> FFmpeg -> segmented MP4.
# Designed for systemd --user (KillMode=mixed, KillSignal=SIGTERM).
# Delegates desktop/session tracking and CPU/RAM/disk measurements to helpers.
# Exit: 0 for requested graceful stop, non-zero if FFmpeg fails.
set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE='/etc/screenrec/screenrec.conf'

usage() {
  printf 'Usage: %s [--config PATH] [--help]\n' "${0##*/}"
  printf 'Run from a logged-in XFCE/X11 session, without sudo.\n'
}
log() { printf '[screenrec-record] %s %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || fail '--config requires PATH'
      CONFIG_FILE=$2
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

# Validation is performed BEFORE sourcing executable Bash configuration.
# Install check-env.sh alongside record.sh.
"$SCRIPT_DIR/check-env.sh" --config "$CONFIG_FILE" || fail 'Preflight check failed'
# shellcheck source=/dev/null
source "$CONFIG_FILE"

command -v flock >/dev/null 2>&1 || fail 'flock is required (util-linux)'
for helper in session-watch.sh metrics.sh; do
  [[ -f "$SCRIPT_DIR/$helper" && -x "$SCRIPT_DIR/$helper" ]] \
    || fail "Missing or not executable helper: $SCRIPT_DIR/$helper"
done

# Bash treats numbers beginning with 0 as octal. Force decimal values.
fps=$((10#$SCREENREC_FPS))
gop_seconds=$((10#$SCREENREC_GOP_SECONDS))
segment_seconds=$((10#$SCREENREC_SEGMENT_SECONDS))
gop_frames=$((fps * gop_seconds))

# Prevent two manual invocations writing the same filenames. Separate from
# cleanup lock because cleanup must still run while recording is active.
exec {RECORD_LOCK_FD}> "$SCREENREC_DIR/.screenrec-record.lock"
flock -n "$RECORD_LOCK_FD" || fail 'Another recorder already holds the lock'

screen_size=$(LC_ALL=C xdpyinfo -display "$DISPLAY" | awk '/dimensions:/ {print $2; exit}')
[[ "$screen_size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || fail 'Cannot detect desktop dimensions'

# This design assumes exactly one XFCE session for this user.
xfce_pid=$(pgrep -u "$(id -u)" -xo xfce4-session) || fail 'XFCE session disappeared'

# Use -nostats; long -stats_period values can delay FFmpeg's stdin 'q'
# handling on some FFmpeg builds. A separate loop logs periodic metrics.
ffmpeg_stats=(-nostats)

FFMPEG_PID=''
FFMPEG_STDIN_FD=''
WATCHER_PID=''
METRICS_PID=''

# /proc/PID/stat field 22: process creation tick after system boot.
# Helpers receive both PID and starttime to reduce PID-reuse mistakes.
proc_start() {
  local pid=$1
  [[ -r "/proc/$pid/stat" ]] || return 1
  LC_ALL=C awk '{sub(/^.*\) /, ""); print $20}' "/proc/$pid/stat" 2>/dev/null
}

stop_helpers() {
  local child
  for child in "$WATCHER_PID" "$METRICS_PID"; do
    [[ -n "$child" ]] || continue
    kill -TERM "$child" 2>/dev/null || true
  done
  for child in "$WATCHER_PID" "$METRICS_PID"; do
    [[ -n "$child" ]] || continue
    wait "$child" 2>/dev/null || true
  done
  WATCHER_PID=''
  METRICS_PID=''
}

stop_recorder() {
  local final_exit=${1:-0}
  # 'wait' in Bash may return early when a trapped signal arrives;
  # this handler calls wait AGAIN to give FFmpeg time to finalize its MP4.
  trap '' TERM INT HUP
  log "STOP requested; ffmpeg_pid=${FFMPEG_PID:-none}"
  # FFmpeg exits reliably and finalizes MP4 on its interactive q command.
  # An OS signal to the wrapper is converted to a write on FFmpeg stdin.
  local requested=0
  if [[ -n "$FFMPEG_STDIN_FD" ]]; then
    if printf 'q\n' >&"$FFMPEG_STDIN_FD" 2>/dev/null; then
      requested=1
      log "Graceful q command sent to ffmpeg_pid=$FFMPEG_PID"
    fi
    exec {FFMPEG_STDIN_FD}>&- || true
    FFMPEG_STDIN_FD=''
  fi
  if ((requested == 0)) && [[ -n "$FFMPEG_PID" ]]; then
    log "WARNING: q unavailable; falling back to SIGTERM on ffmpeg_pid=$FFMPEG_PID"
    kill -TERM "$FFMPEG_PID" 2>/dev/null || true
  fi
  local rc=0
  if [[ -n "$FFMPEG_PID" ]]; then
    wait "$FFMPEG_PID" || rc=$?
  fi
  stop_helpers
  log "STOP completed; ffmpeg_exit_status=$rc"
  # A requested, completed shutdown is not a restart-worthy service failure.
  # Check the last MP4 with ffprobe in acceptance tests.
  exit "$final_exit"
}
trap stop_recorder TERM INT HUP

log "START display=$DISPLAY size=$screen_size xfce_pid=$xfce_pid fps=$fps gop_frames=$gop_frames segment=${segment_seconds}s output=$SCREENREC_DIR"

# The segment muxer may OVERWRITE existing files even with FFmpeg's '-n'.
# A per-invocation suffix prevents collisions across separate recorder runs.
# Caveat: a backward wall-clock jump within ONE run can still repeat a name.
# Segment boundaries depend on keyframes; they are not frame-exact.
run_id="$(date +%s%N)_$$"
coproc FFMPEG_PROC { exec ffmpeg -hide_banner -loglevel info "${ffmpeg_stats[@]}" \
  -f x11grab -framerate "$fps" -video_size "$screen_size" -i "$DISPLAY" \
  -an -vf 'pad=ceil(iw/2)*2:ceil(ih/2)*2' \
  -c:v libx264 -preset "$SCREENREC_PRESET" -pix_fmt yuv420p \
  -b:v "$SCREENREC_BITRATE" -maxrate "$SCREENREC_MAXRATE" \
  -bufsize "$SCREENREC_BUFSIZE" -g "$gop_frames" -sc_threshold 0 \
  -flags +cgop -force_key_frames "expr:gte(t,n_forced*${segment_seconds})" \
  -f segment -segment_format mp4 -segment_time "$segment_seconds" \
  -segment_time_delta "$(LC_ALL=C awk -v fps="$fps" 'BEGIN {printf "%.6f", 1/(2*fps)}')" \
  -segment_format_options 'movflags=+faststart' \
  -strftime 1 -reset_timestamps 1 \
  "$SCREENREC_DIR/screen_%Y-%m-%d_%H-%M-%S_${run_id}.mp4" 1>&2; }
FFMPEG_PID=$FFMPEG_PROC_PID
FFMPEG_STDIN_FD=${FFMPEG_PROC[1]}
# No output is expected on stdout (it was redirected to stderr/journald).
FFMPEG_OUTPUT_FD=${FFMPEG_PROC[0]}
exec {FFMPEG_OUTPUT_FD}<&-

# Spawn single-purpose helpers. The parent remains the only FFmpeg owner.
# The watcher signals THIS process, never FFmpeg, so all stops use one path.
record_start=$(proc_start "$$") || { log 'ERROR: Cannot obtain recorder starttime'; stop_recorder 1; }
xfce_start=$(proc_start "$xfce_pid") || { log 'ERROR: Cannot obtain XFCE starttime'; stop_recorder 1; }
ffmpeg_start=$(proc_start "$FFMPEG_PID") || { log 'ERROR: Cannot obtain FFmpeg starttime'; stop_recorder 1; }

"$SCRIPT_DIR/session-watch.sh" \
  --config "$CONFIG_FILE" \
  --xfce-pid "$xfce_pid" --xfce-start "$xfce_start" \
  --record-pid "$$" --record-start "$record_start" \
  --ffmpeg-pid "$FFMPEG_PID" --ffmpeg-start "$ffmpeg_start" &
WATCHER_PID=$!

"$SCRIPT_DIR/metrics.sh" \
  --config "$CONFIG_FILE" \
  --ffmpeg-pid "$FFMPEG_PID" --ffmpeg-start "$ffmpeg_start" &
METRICS_PID=$!
log "HELPERS watcher_pid=$WATCHER_PID metrics_pid=$METRICS_PID ffmpeg_pid=$FFMPEG_PID"

ffmpeg_status=0
wait "$FFMPEG_PID" || ffmpeg_status=$?
trap - TERM INT HUP
if [[ -n "$FFMPEG_STDIN_FD" ]]; then
  exec {FFMPEG_STDIN_FD}>&- || true
fi
stop_helpers
log "FFmpeg exited; status=$ffmpeg_status"
exit "$ffmpeg_status"
