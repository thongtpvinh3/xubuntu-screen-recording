#!/usr/bin/env bash
# Launcher run once per XFCE graphical login from screenrec.desktop.
# It does not record; it prepares the user manager environment and starts
# screenrec.service, whose ExecStart owns record.sh and all children.
# Scope: one local XFCE/X11 session per user; run as the desktop user.
set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE='/etc/screenrec/screenrec.conf'
readonly UNIT='screenrec.service'
readonly CHECK="$SCRIPT_DIR/check-env.sh"
readonly CLEANUP="$SCRIPT_DIR/cleanup.sh"
CHECK_ONLY=0

usage() {
  cat <<'HELP'
Usage: session-start.sh [--check-only] [--help]

Called by XFCE Application Autostart after desktop login. The script:
  1. validates the shared root-installed config;
  2. waits until XFCE, X11 and systemd --user are ready;
  3. runs expired-video cleanup (best effort);
  4. verifies FFmpeg/X11/storage with check-env.sh;
  5. imports desktop variables into systemd --user (and D-Bus if available);
  6. starts the existing screenrec.service (does not enable it).

--check-only  Check configuration and full session prerequisites, but do NOT
              delete anything, import environment, or start the service.
Run inside the intended user's local XFCE/X11 session, without sudo.
HELP
}
log() { printf '[screenrec-start] %s %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

(( EUID != 0 )) || fail 'Do not run with sudo/root; use the logged-in desktop account'
[[ -x "$CHECK" ]] || fail "Required helper is missing or not executable: $CHECK"
if (( ! CHECK_ONLY )); then
  [[ -x "$CLEANUP" ]] || fail "Required helper is missing or not executable: $CLEANUP"
fi
for cmd in systemctl xdpyinfo pgrep timeout; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command unavailable: $cmd"
done

# Validate before sourcing: the configuration contains executable Bash syntax.
"$CHECK" --config "$CONFIG_FILE" --config-only || fail 'Configuration validation failed'
# shellcheck source=/dev/null
source "$CONFIG_FILE"
attempts=$((10#$SCREENREC_X11_READY_ATTEMPTS))
interval=$((10#$SCREENREC_X11_READY_INTERVAL_SECONDS))

# Fail early if this is clearly not an X11 session, rather than waiting.
if [[ -n "${XDG_SESSION_TYPE:-}" && "${XDG_SESSION_TYPE,,}" != x11 ]]; then
  fail "Only X11 supported (XDG_SESSION_TYPE=$XDG_SESSION_TYPE)"
fi
[[ -n "${DISPLAY:-}" ]] || fail 'DISPLAY is missing; start from an XFCE graphical session'

log "Waiting for desktop session and systemd user manager (max_attempts=$attempts interval=${interval}s display=$DISPLAY)"
ready=0
for ((try=1; try<=attempts; try++)); do
  if timeout 5s xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 \
     && pgrep -u "$(id -u)" -x xfce4-session >/dev/null 2>&1 \
     && systemctl --user show-environment >/dev/null 2>&1; then
    ready=1
    break
  fi
  if (( try < attempts )); then
    sleep "$interval"
  fi
done
(( ready )) || fail 'XFCE/X11 or systemd --user not ready; inspect DISPLAY, XAUTHORITY and user bus'
log "Desktop ready after attempt=$try"

if (( CHECK_ONLY )); then
  "$CHECK" --config "$CONFIG_FILE" || fail 'Full preflight check failed'
  log 'CHECK_ONLY passed; no cleanup, environment update or service start'
  exit 0
fi

# Catch up when cron at 03:00 was missed while the machine was off.
# A failed cleanup should not prevent new recording; it is logged for ops.
if ! "$CLEANUP" --config "$CONFIG_FILE"; then
  log 'WARN: cleanup failed (recording will still be attempted)'
fi

"$CHECK" --config "$CONFIG_FILE" || fail 'Full preflight check failed'

# Only import graphical-session variables, not the whole shell environment.
# The systemd user manager may have been running before XFCE login.
# Clear stale optional values from a previous session when absent now.
for name in XAUTHORITY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP; do
  if [[ -z "${!name:-}" ]]; then
    systemctl --user unset-environment "$name" || fail "Cannot clear stale $name from user manager"
  fi
done

vars=(DISPLAY)
for name in XAUTHORITY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS; do
  if [[ -n "${!name:-}" ]]; then
    vars+=("$name")
  fi
done
systemctl --user import-environment "${vars[@]}" \
  || fail 'Could not import desktop variables into systemd --user'
log "Imported user-manager environment: ${vars[*]}"

if command -v dbus-update-activation-environment >/dev/null 2>&1; then
  # D-Bus activated processes may use a different activation environment.
  # --systemd updates both when possible; an independent systemctl import
  # above means D-Bus failure need not prevent the recorder.
  if ! dbus-update-activation-environment --systemd "${vars[@]}"; then
    log 'WARN: D-Bus activation environment update failed'
  fi
fi

if systemctl --user is-active --quiet "$UNIT"; then
  log "$UNIT already active; keeping the existing recorder (no duplicate start)"
  exit 0
fi

log "Starting $UNIT"
if ! systemctl --user start "$UNIT"; then
  fail "Cannot start $UNIT; inspect: journalctl --user -u $UNIT -n 80 --no-pager"
fi
if ! systemctl --user is-active --quiet "$UNIT"; then
  fail "$UNIT did not remain active; inspect: journalctl --user -u $UNIT -n 80 --no-pager"
fi
log "$UNIT active; XFCE autostart completed"
