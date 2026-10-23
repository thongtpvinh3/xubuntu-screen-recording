#!/usr/bin/env bash
# check-env.sh -- preflight checks for one XFCE/X11 screen recording session.
# Read-only: does NOT create directories, install packages or start FFmpeg.
# Exit codes: 0 OK, 10 config, 20 commands/FFmpeg, 30 X11/XFCE,
#             40 storage/permissions, 50 wrong execution context.
set -Eeuo pipefail

CONFIG_FILE='/etc/screenrec/screenrec.conf'
CONFIG_ONLY=0

usage() {
  cat <<'HELP'
Usage: check-env.sh [--config PATH] [--config-only] [--help]
  --config PATH   Read a trusted Bash config at PATH (default: /etc/screenrec/screenrec.conf)
  --config-only   Validate configuration values without requiring X11/FFmpeg/storage
  --help          Show this help

Run the full check from a local XFCE/X11 user session, without sudo.
This script sources its config as Bash code: only use trusted config files.
HELP
}

info() { printf '[check-env] OK: %s\n' "$*"; }
warn() { printf '[check-env] WARN: %s\n' "$*" >&2; }
fail() { local code=$1; shift; printf '[check-env] ERROR [%s]: %s\n' "$code" "$*" >&2; exit "$code"; }

while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || fail 10 '--config requires a path'
      CONFIG_FILE=$2
      shift 2
      ;;
    --config-only) CONFIG_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail 10 "Unknown argument: $1 (use --help)" ;;
  esac
done

# Check trust before sourcing: a config file is executable Bash content.
[[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] \
  || fail 10 "Config must be an existing, readable, regular non-symlink file: $CONFIG_FILE"

config_uid=$(stat -c '%u' -- "$CONFIG_FILE") || fail 10 'Cannot read config owner'
config_mode=$(stat -c '%a' -- "$CONFIG_FILE") || fail 10 'Cannot read config permissions'
[[ "$config_uid" =~ ^[0-9]+$ && "$config_mode" =~ ^[0-7]{3,4}$ ]] \
  || fail 10 'Unexpected owner/mode on config'
config_perms=$((8#$config_mode))
(( (config_perms & 0022) == 0 )) \
  || fail 10 "Config cannot be group/other writable (mode=$config_mode)"
if (( EUID == 0 )); then
  [[ "$config_uid" == 0 ]] || fail 10 'Root must not source non-root-owned config'
else
  [[ "$config_uid" == 0 || "$config_uid" == "$EUID" ]] \
    || fail 10 'Config must belong to root or the current user'
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Decimal-only integer with maximum length, avoiding shell arithmetic surprises
# (e.g. 08 is not interpreted as octal).
require_integer() {
  local key=$1 low=$2 high=$3 raw=${!1-} num
  [[ "$raw" =~ ^[0-9]{1,8}$ ]] \
    || fail 10 "$key must be an integer in [$low, $high] (got: ${raw:-unset})"
  num=$((10#$raw))
  (( num >= low && num <= high )) \
    || fail 10 "$key must be in [$low, $high] (got: $raw)"
}

# Accept only e.g. 3000k / 3M / 4m. Convert to bits per second.
bitrate_to_bps() {
  local key=$1 raw=${!1-} quantity multiplier
  [[ "$raw" =~ ^([1-9][0-9]{0,7})([kKmM])$ ]] \
    || fail 10 "$key must look like 3000k or 3M (got: ${raw:-unset})"
  quantity=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
    k|K) multiplier=1000 ;;
    m|M) multiplier=1000000 ;;
  esac
  printf '%s\n' "$((quantity * multiplier))"
}

[[ -n "${SCREENREC_DIR:-}" && "$SCREENREC_DIR" == /* && "$SCREENREC_DIR" != / \
   && "$SCREENREC_DIR" != *$'\n'* && "$SCREENREC_DIR" != *$'\r'* \
   && "$SCREENREC_DIR" != *'/../'* && "$SCREENREC_DIR" != *'/./'* \
   && "$SCREENREC_DIR" != */.. && "$SCREENREC_DIR" != */. ]] \
  || fail 10 'SCREENREC_DIR must be a safe, absolute, non-root directory path'

require_integer SCREENREC_FPS 1 60
require_integer SCREENREC_GOP_SECONDS 1 10
require_integer SCREENREC_SEGMENT_SECONDS 10 86400
require_integer SCREENREC_RETENTION_DAYS 1 365
require_integer SCREENREC_METRICS_INTERVAL_SECONDS 5 3600
require_integer SCREENREC_SESSION_POLL_SECONDS 1 60
require_integer SCREENREC_X11_READY_ATTEMPTS 1 120
require_integer SCREENREC_X11_READY_INTERVAL_SECONDS 1 30

case "${SCREENREC_PRESET:-}" in
  ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|placebo) ;;
  *) fail 10 'SCREENREC_PRESET is not a recognized x264 preset' ;;
esac

bitrate_bps=$(bitrate_to_bps SCREENREC_BITRATE)
maxrate_bps=$(bitrate_to_bps SCREENREC_MAXRATE)
bufsize_bits=$(bitrate_to_bps SCREENREC_BUFSIZE)
(( bitrate_bps >= 100000 && bitrate_bps <= 50000000 )) \
  || fail 10 'SCREENREC_BITRATE must be between 100k and 50M'
(( maxrate_bps >= bitrate_bps && maxrate_bps <= 50000000 )) \
  || fail 10 'SCREENREC_MAXRATE must be >= BITRATE and <= 50M'
(( bufsize_bits >= maxrate_bps && bufsize_bits <= 200000000 )) \
  || fail 10 'SCREENREC_BUFSIZE must be >= MAXRATE and <= 200M'
(( SCREENREC_GOP_SECONDS <= SCREENREC_SEGMENT_SECONDS )) \
  || fail 10 'GOP interval cannot exceed segment duration'
if (( SCREENREC_SEGMENT_SECONDS % SCREENREC_GOP_SECONDS != 0 )); then
  warn 'Segment duration is not a multiple of GOP seconds; boundaries may drift'
fi

info "Config validated: $CONFIG_FILE"
info "Video: fps=$SCREENREC_FPS preset=$SCREENREC_PRESET bitrate=$SCREENREC_BITRATE maxrate=$SCREENREC_MAXRATE segment=${SCREENREC_SEGMENT_SECONDS}s"
info "Retention=${SCREENREC_RETENTION_DAYS}d output=$SCREENREC_DIR"

if (( CONFIG_ONLY == 1 )); then
  info 'Configuration-only check completed (system, X11 and storage not tested)'
  exit 0
fi

# Recording must run in the logged-in user's desktop session, never as root.
(( EUID != 0 )) || fail 50 'Do not run the full check with sudo or as root'

for cmd in ffmpeg ffprobe xdpyinfo pgrep id df awk stat timeout; do
  command -v "$cmd" >/dev/null 2>&1 || fail 20 "Missing command: $cmd"
done
info 'Required commands available'

# The first flag column identifies usable input devices / video encoders.
if ! ffmpeg -hide_banner -devices 2>/dev/null | \
     awk '$2 == "x11grab" && substr($1, 1, 1) == "D" {found=1} END {exit !found}'; then
  fail 20 'FFmpeg does not expose the x11grab input device'
fi
if ! ffmpeg -hide_banner -encoders 2>/dev/null | \
     awk '$2 == "libx264" && substr($1, 1, 1) == "V" {found=1} END {exit !found}'; then
  fail 20 'FFmpeg does not expose the libx264 video encoder'
fi
info 'FFmpeg supports x11grab and libx264'

# A systemd --user service may not have XDG_SESSION_TYPE set; in that case,
# working DISPLAY + xdpyinfo still constitute the authoritative X11 test.
if [[ -n "${XDG_SESSION_TYPE:-}" && "${XDG_SESSION_TYPE,,}" != x11 ]]; then
  fail 30 "Requires X11 session; got XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
fi
[[ -n "${DISPLAY:-}" ]] || fail 30 'DISPLAY is empty (not in a graphical X11 session?)'
if [[ -n "${XDG_CURRENT_DESKTOP:-}" ]]; then
  desktops=":${XDG_CURRENT_DESKTOP^^}:"
  [[ "$desktops" == *':XFCE:'* ]] \
    || fail 30 "Not an XFCE desktop (XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP)"
fi
if [[ -n "${XAUTHORITY:-}" && ! -r "$XAUTHORITY" ]]; then
  fail 30 "XAUTHORITY is not readable: $XAUTHORITY"
fi
if ! timeout 5s xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  fail 30 "Cannot connect to X11 display $DISPLAY (check DISPLAY/XAUTHORITY)"
fi
if ! pgrep -u "$(id -u)" -x xfce4-session >/dev/null 2>&1; then
  fail 30 'No xfce4-session process for the current user'
fi
info "XFCE/X11 verified: DISPLAY=$DISPLAY"

[[ -d "$SCREENREC_DIR" && ! -L "$SCREENREC_DIR" ]] \
  || fail 40 "Recording directory missing or symlink: $SCREENREC_DIR"
[[ -r "$SCREENREC_DIR" && -w "$SCREENREC_DIR" && -x "$SCREENREC_DIR" ]] \
  || fail 40 "Current user needs read/write/traverse permission: $SCREENREC_DIR"

record_uid=$(stat -c '%u' -- "$SCREENREC_DIR") || fail 40 'Cannot stat recording directory owner'
[[ "$record_uid" == "$EUID" ]] \
  || fail 40 "Recording directory must belong to user UID=$EUID (got UID=$record_uid)"
record_mode=$(stat -c '%a' -- "$SCREENREC_DIR") || fail 40 'Cannot stat recording directory mode'
[[ "$record_mode" =~ ^[0-7]{3,4}$ ]] || fail 40 "Invalid directory mode: $record_mode"
record_perms=$((8#$record_mode))
(( (record_perms & 0077) == 0 )) \
  || fail 40 "Recording directory exposes group/other permissions (mode=$record_mode; use 0700)"

free_kib=$(LC_ALL=C df -Pk -- "$SCREENREC_DIR" | awk 'NR==2 {print $4}') \
  || fail 40 'Cannot determine free disk space'
[[ "$free_kib" =~ ^[0-9]+$ ]] || fail 40 'Invalid free space reading from df'
(( free_kib > 0 )) || fail 40 'Recording filesystem has no available space'
if (( free_kib < 1048576 )); then
  warn "Less than 1 GiB free in recording filesystem ($((free_kib / 1024)) MiB); recording may fill the disk"
fi
info "Recording directory writable and private: $SCREENREC_DIR (mode=$record_mode, available=$((free_kib / 1024)) MiB)"
info 'ALL CHECKS PASSED: recording may start'
exit 0
