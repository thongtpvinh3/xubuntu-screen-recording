#!/usr/bin/env bash
# Remove completed, expired screen recordings; suitable for cron and login.
# Usage: cleanup.sh [--config PATH] [--dry-run]. No deletion by default in --dry-run.
set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE='/etc/screenrec/screenrec.conf'
DRY_RUN=0

usage() {
  printf 'Usage: %s [--config PATH] [--dry-run] [--help]\n' "${0##*/}"
  printf 'Delete expired screen_*.mp4 files using mtime and configured retention.\n'
}
log() {
  local message="[screenrec-cleanup] $(date --iso-8601=seconds) $*"
  printf '%s\n' "$message"
  if command -v logger >/dev/null 2>&1; then
    logger -t screenrec-cleanup -- "$message" || true
  fi
}
fail() { log "ERROR: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || fail '--config requires PATH'
      CONFIG_FILE=$2
      shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

(( EUID != 0 )) || fail 'Run as the recording user, not root'
"$SCRIPT_DIR/check-env.sh" --config "$CONFIG_FILE" --config-only \
  || fail 'Configuration validation failed'
# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ -d "$SCREENREC_DIR" && ! -L "$SCREENREC_DIR" ]] \
  || fail "Directory not found or symlink: $SCREENREC_DIR"
[[ -r "$SCREENREC_DIR" && -w "$SCREENREC_DIR" && -x "$SCREENREC_DIR" ]] \
  || fail "No read/write/traverse permission: $SCREENREC_DIR"
[[ "$(stat -c %u -- "$SCREENREC_DIR")" == "$EUID" ]] \
  || fail 'Recording directory must belong to the current user'
mode=$(stat -c %a -- "$SCREENREC_DIR")
[[ "$mode" =~ ^[0-7]{3,4}$ ]] || fail 'Invalid directory permissions'
(( (8#$mode & 0077) == 0 )) || fail 'Recording directory must not be open to group/others'

command -v flock >/dev/null 2>&1 || fail 'flock is required (util-linux)'
command -v find >/dev/null 2>&1 || fail 'GNU find is required'

exec {CLEANUP_LOCK_FD}> "$SCREENREC_DIR/.screenrec-cleanup.lock"
if ! flock -n "$CLEANUP_LOCK_FD"; then
  log 'SKIP: another cleanup is still running'
  exit 0
fi

retention_days=$((10#$SCREENREC_RETENTION_DAYS))
# GNU find rounds -mmin age DOWN to a whole minute: +14399 selects files
# whose mtime is >= 14400 complete minutes ago (10 * 24 h).
threshold_minutes=$((retention_days * 24 * 60 - 1))
log "START dry_run=$DRY_RUN retention_days=$retention_days dir=$SCREENREC_DIR"

# Only immediate regular files with our naming prefix, never subdirectories,
# symlinks, log files or dotfiles. Log a path AFTER -delete succeeds.
if (( DRY_RUN )); then
  find "$SCREENREC_DIR" -maxdepth 1 -type f -name 'screen_*.mp4' \
    -mmin "+$threshold_minutes" -print0 | \
    while IFS= read -r -d '' file; do log "WOULD_DELETE $(printf '%q' "$file")"; done
else
  find "$SCREENREC_DIR" -maxdepth 1 -type f -name 'screen_*.mp4' \
    -mmin "+$threshold_minutes" -delete -print0 | \
    while IFS= read -r -d '' file; do log "DELETED $(printf '%q' "$file")"; done
fi
log 'DONE'
