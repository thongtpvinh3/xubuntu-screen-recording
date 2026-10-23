#!/usr/bin/env bash
# One-command installer for the Xubuntu XFCE/X11 screen recorder.
# Run as the DESKTOP USER: bash install.sh (this program uses sudo where needed).
set -Eeuo pipefail
umask 077

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SYS_CONFIG_DIR='/etc/screenrec'
readonly BIN_DIR='/usr/local/libexec/screenrec'
readonly CONFIG_FILE="$SYS_CONFIG_DIR/screenrec.conf"
readonly CRON_FILE='/etc/cron.d/screenrec-cleanup'
readonly UNIT_NAME='screenrec.service'

SKIP_APT=0
NO_START=0
OVERWRITE_CONFIG=0
DRY_RUN=0
TEMP_CRON=''

info() { printf '[screenrec-install] INFO: %s\n' "$*"; }
warn() { printf '[screenrec-install] WARN: %s\n' "$*" >&2; }
fail() { printf '[screenrec-install] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage: bash install.sh [OPTIONS]

Run as the intended XFCE desktop user (WITHOUT sudo) in the extracted
screenrec-startup project directory. Sudo is requested only when needed.

Options:
  --no-start           Install files/services, start recorder next XFCE login
  --skip-apt           Skip APT; fail if required commands are unavailable
  --overwrite-config   Backup and replace /etc/screenrec/screenrec.conf
  --dry-run            Print installation plan without changing the system
  -h, --help           Show this help

Default: install missing packages, 6 scripts, config (preserving an existing
config), user systemd service, XFCE Autostart and daily Cron. If invoked from
an active local XFCE/X11 terminal, start recording immediately.
HELP
}
cleanup_temp() {
  if [[ -n "$TEMP_CRON" && -f "$TEMP_CRON" ]]; then
    rm -f -- "$TEMP_CRON"
  fi
}
trap cleanup_temp EXIT
trap 'printf "[screenrec-install] ERROR at line %d: command failed (exit %d)\n" "$LINENO" "$?" >&2' ERR

while (($#)); do
  case "$1" in
    --no-start) NO_START=1 ;;
    --skip-apt) SKIP_APT=1 ;;
    --overwrite-config) OVERWRITE_CONFIG=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

(( EUID != 0 )) || fail 'Do not use sudo bash install.sh. Run as the XFCE desktop user.'
command -v sudo >/dev/null 2>&1 || fail 'sudo is required for system directories and packages'
command -v bash >/dev/null 2>&1 || fail 'bash is required'
command -v dpkg-query >/dev/null 2>&1 || fail 'This installer requires Ubuntu/Debian dpkg-query'
command -v systemctl >/dev/null 2>&1 || fail 'systemctl is required'

readonly DESKTOP_USER="$(id -un)"
readonly DESKTOP_GROUP="$(id -gn)"
# /etc/cron.d fields are separated by whitespace: only standard account names.
[[ "$DESKTOP_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] \
  || fail "Unsupported Linux username in Cron configuration: $DESKTOP_USER"
[[ "$(id -u)" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid desktop UID'
[[ -n "${HOME:-}" && -d "$HOME" ]] || fail 'Cannot locate the user home directory'

# Validate the complete, extracted source bundle before mutating the host.
readonly SCRIPT_NAMES=(check-env.sh session-start.sh record.sh session-watch.sh metrics.sh cleanup.sh)
for name in "${SCRIPT_NAMES[@]}"; do
  [[ -f "$PROJECT_DIR/scripts/$name" && ! -L "$PROJECT_DIR/scripts/$name" ]] \
    || fail "Missing or symlinked source: scripts/$name"
  bash -n "$PROJECT_DIR/scripts/$name" || fail "Bash syntax error: scripts/$name"
done
for path in config/screenrec.conf systemd/screenrec.service \
            autostart/screenrec.desktop cron/screenrec-cleanup; do
  [[ -f "$PROJECT_DIR/$path" && ! -L "$PROJECT_DIR/$path" ]] \
    || fail "Missing or symlinked source: $path"
done
if [[ -L "$CONFIG_FILE" || ( -e "$CONFIG_FILE" && ! -f "$CONFIG_FILE" ) ]]; then
  fail "Cannot use a symlink or non-file as configuration: $CONFIG_FILE"
fi

# Preserve the live config on repeat installs unless explicitly replaced.
SELECTED_CONFIG="$PROJECT_DIR/config/screenrec.conf"
if [[ -e "$CONFIG_FILE" && "$OVERWRITE_CONFIG" -eq 0 ]]; then
  SELECTED_CONFIG="$CONFIG_FILE"
  info "Preserving existing config: $CONFIG_FILE"
fi
bash "$PROJECT_DIR/scripts/check-env.sh" --config "$SELECTED_CONFIG" --config-only \
  || fail 'Selected configuration is invalid; nothing installed'
# Source only AFTER validation; do not source untrusted configuration as root.
# shellcheck source=/dev/null
source "$SELECTED_CONFIG"

# Avoid taking ownership of a directory that belongs to someone else.
if [[ -L "$SCREENREC_DIR" ]]; then
  fail "Storage path is a symlink: $SCREENREC_DIR"
fi
if [[ -e "$SCREENREC_DIR" ]]; then
  [[ -d "$SCREENREC_DIR" ]] || fail "Storage path exists but is not a directory: $SCREENREC_DIR"
  [[ "$(stat -c %u -- "$SCREENREC_DIR")" == "$(id -u)" ]] \
    || fail "Storage directory exists but is owned by another user: $SCREENREC_DIR"
fi

readonly USER_UNIT_DIR="$HOME/.config/systemd/user"
readonly USER_AUTOSTART_DIR="$HOME/.config/autostart"
readonly USER_UNIT="$USER_UNIT_DIR/$UNIT_NAME"
readonly USER_DESKTOP="$USER_AUTOSTART_DIR/screenrec.desktop"

info "Project: $PROJECT_DIR"
info "Desktop user: $DESKTOP_USER ($(id -u))"
info "Video directory: $SCREENREC_DIR"
info "System config: $CONFIG_FILE"
info "User service: $USER_UNIT"
info "XFCE autostart: $USER_DESKTOP"
info "Cron job: $CRON_FILE (03:00 daily)"

if (( DRY_RUN )); then
  info 'DRY RUN: No files, packages, units or processes will be changed'
  if [[ "$SELECTED_CONFIG" == "$CONFIG_FILE" ]]; then
    info 'Would preserve existing screenrec.conf'
  elif [[ -e "$CONFIG_FILE" ]]; then
    info 'Would back up and overwrite screenrec.conf'
  else
    info 'Would create screenrec.conf from the package'
  fi
  info 'Would install dependencies, 6 scripts, systemd user unit, XFCE autostart and Cron'
  if (( NO_START )); then info 'Would defer starting the recorder'; else info 'Would start when active XFCE/X11 is detected'; fi
  exit 0
fi

# Sudo is needed for APT, root-owned scripts/config/cron, and /var/log storage.
# sudo -v up front avoids stopping an existing recording without having rights
# to complete the deployment.
sudo -v || fail 'Could not acquire sudo privileges'

readonly PACKAGES=(ffmpeg cron x11-utils x11-xserver-utils procps util-linux findutils coreutils bsdutils dbus)
missing=()
for pkg in "${PACKAGES[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then
    missing+=("$pkg")
  fi
done
if (( ${#missing[@]} > 0 )); then
  if (( SKIP_APT )); then
    fail "Missing packages (--skip-apt requested): ${missing[*]}"
  fi
  info "Installing packages: ${missing[*]}"
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
else
  info 'All required APT packages are already installed'
fi
for cmd in ffmpeg ffprobe xdpyinfo pgrep flock find awk stat df timeout logger getconf; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command missing after APT: $cmd"
done
command -v xfce4-session >/dev/null 2>&1 \
  || fail 'xfce4-session is not installed. This project requires an XFCE desktop.'

USER_MANAGER=0
WAS_ACTIVE=0
if systemctl --user show-environment >/dev/null 2>&1; then
  USER_MANAGER=1
  if systemctl --user is-active --quiet "$UNIT_NAME"; then
    WAS_ACTIVE=1
    info 'Stopping existing recorder gracefully before replacing its files'
    systemctl --user stop "$UNIT_NAME" \
      || fail 'Could not stop existing recorder safely; not replacing files'
  fi
else
  warn 'systemd --user is unavailable in this shell; recording will start at next XFCE login'
fi

sudo install -d -o root -g root -m 0755 "$SYS_CONFIG_DIR" "$BIN_DIR"
if [[ -e "$CONFIG_FILE" ]]; then
  if (( OVERWRITE_CONFIG )); then
    backup="$CONFIG_FILE.bak.$(date +%Y%m%d_%H%M%S_%N)"
    sudo cp -p -- "$CONFIG_FILE" "$backup"
    info "Previous configuration backed up: $backup"
    sudo install -o root -g root -m 0644 \
      "$PROJECT_DIR/config/screenrec.conf" "$CONFIG_FILE"
  fi
else
  sudo install -o root -g root -m 0644 \
    "$PROJECT_DIR/config/screenrec.conf" "$CONFIG_FILE"
fi
for name in "${SCRIPT_NAMES[@]}"; do
  sudo install -o root -g root -m 0755 \
    "$PROJECT_DIR/scripts/$name" "$BIN_DIR/$name"
done

if [[ ! -e "$SCREENREC_DIR" ]]; then
  sudo install -d -o "$DESKTOP_USER" -g "$DESKTOP_GROUP" -m 0700 -- "$SCREENREC_DIR"
else
  # The ownership was checked before installing; do not chown user files.
  chmod 0700 -- "$SCREENREC_DIR"
fi

# Re-validate the installed config and permissions as the intended user.
"$BIN_DIR/check-env.sh" --config "$CONFIG_FILE" --config-only \
  || fail 'Installed screenrec.conf did not pass validation'

mkdir -p -- "$USER_UNIT_DIR" "$USER_AUTOSTART_DIR"
install -m 0644 -- "$PROJECT_DIR/systemd/screenrec.service" "$USER_UNIT"

# System cron syntax includes the user field; preserve the source template.
TEMP_CRON="$(mktemp)"
sed "s/@SCREENREC_USER@/$DESKTOP_USER/g" \
  "$PROJECT_DIR/cron/screenrec-cleanup" > "$TEMP_CRON"
if grep -q '@SCREENREC_USER@' "$TEMP_CRON"; then
  fail 'Cron template contains an unresolved username placeholder'
fi
sudo install -o root -g root -m 0644 -- "$TEMP_CRON" "$CRON_FILE"
sudo systemctl enable --now cron

if (( USER_MANAGER )); then
  systemctl --user daemon-reload
fi

# Install autostart LAST: all dependencies and files must be in place first.
install -m 0644 -- "$PROJECT_DIR/autostart/screenrec.desktop" "$USER_DESKTOP"
info 'Installed: six scripts, config, video directory, systemd user service, autostart and cron'

if (( NO_START )); then
  info 'Recording not started (--no-start); XFCE Autostart will start it at next login'
elif [[ -n "${DISPLAY:-}" && "${XDG_SESSION_TYPE:-}" != wayland \
        && "${XDG_CURRENT_DESKTOP:-}" == *XFCE* ]] && (( USER_MANAGER )); then
  info 'Active XFCE/X11 detected; running full preflight and starting recorder'
  "$BIN_DIR/session-start.sh" --check-only \
    || fail 'Installed, but graphical preflight failed; recorder not started'
  "$BIN_DIR/session-start.sh" \
    || fail 'Installed, but service could not start; inspect journalctl --user -u screenrec.service'
  if systemctl --user is-active --quiet "$UNIT_NAME"; then
    info 'SUCCESS: screenrec.service is active'
  else
    fail 'Service exited immediately after startup; inspect systemd journal'
  fi
elif (( WAS_ACTIVE && USER_MANAGER )); then
  # Preserve a pre-existing active state even if the installer is run from
  # SSH without DISPLAY; manager should already hold the graphical env.
  info 'Restoring previously active recorder through systemd --user'
  systemctl --user start "$UNIT_NAME" \
    || fail 'Previously active recorder did not restart after update'
else
  info 'SUCCESS: Installed; will start automatically on next XFCE login'
fi

info 'Check service: systemctl --user status screenrec.service'
info 'Read logs:     journalctl --user -u screenrec.service -n 80 --no-pager'
info 'Preview cron: /usr/local/libexec/screenrec/cleanup.sh --dry-run'
info 'Stop safely:  systemctl --user stop screenrec.service'
