#!/bin/sh
# ==============================================================================
# Alpine VM Waydroid Installer
# ==============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKGS_FILE="${SCRIPT_DIR}/alpine_pkgs"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$*"
}

log_ok() {
    printf "${GREEN}[OK]${NC} %s\n" "$*"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$*"
}

log_err() {
    printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -p, --install-pkgs        Install required packages listed in alpine_pkgs
  -u, --user <USERNAME>     User to run waydroid sway session (default: DOAS_USER, SUDO_USER or forumi0721)
  --no-service              Install files only without adding to OpenRC default runlevel
  --uninstall               Remove installed files and unregister services
  -h, --help                Show this help message

Description:
  Installs Waydroid headless sway session and cgroup helper for Alpine VM:
    - /etc/init.d/waydroid-prepare           (OpenRC init script)
    - /usr/local/sbin/waydroid-prepare       (Waydroid config/RRO preparation)
    - /etc/init.d/waydroid-sway              (OpenRC init script)
    - /usr/local/bin/waydroid-sway-session   (Sway & Waydroid runtime session)
EOF
    exit 0
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "This script must be run as root (or via sudo/doas)."
        exit 1
    fi
}

INSTALL_PKGS=0
ENABLE_SERVICE=1
UNINSTALL=0
TARGET_USER=""

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--install-pkgs)
            INSTALL_PKGS=1
            shift
            ;;
        -u|--user)
            [ -n "${2:-}" ] || { log_err "Option $1 requires an argument"; exit 1; }
            TARGET_USER="$2"
            shift 2
            ;;
        --no-service)
            ENABLE_SERVICE=0
            shift
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_err "Unknown option: $1"
            usage
            ;;
    esac
done

check_root

# ------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    log_info "Uninstalling Alpine Waydroid components..."

    if command -v rc-service >/dev/null 2>&1; then
        rc-service waydroid-sway stop 2>/dev/null || true
    fi

    if command -v rc-update >/dev/null 2>&1; then
        rc-update del waydroid-sway default 2>/dev/null || true
        rc-update del waydroid-prepare default 2>/dev/null || true
    fi

    rm -f /etc/init.d/waydroid-prepare
    rm -f /usr/local/sbin/waydroid-prepare
    rm -f /etc/init.d/waydroid-sway
    rm -f /usr/local/bin/waydroid-sway-session

    log_ok "Uninstallation complete."
    exit 0
fi

# ------------------------------------------------------------------------------
# Determine Target User
# ------------------------------------------------------------------------------
if [ -z "$TARGET_USER" ]; then
    if [ -n "${DOAS_USER:-}" ] && [ "$DOAS_USER" != "root" ]; then
        TARGET_USER="$DOAS_USER"
    elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_USER="$SUDO_USER"
    elif id forumi0721 >/dev/null 2>&1; then
        TARGET_USER="forumi0721"
    else
        # Fallback to the first non-system user (UID >= 1000) or root
        FIRST_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd 2>/dev/null || true)
        if [ -n "$FIRST_USER" ]; then
            TARGET_USER="$FIRST_USER"
        else
            TARGET_USER="forumi0721"
        fi
    fi
fi

log_info "Target user for Waydroid session: ${TARGET_USER}"

# Ensure target user exists or warn
if ! id "$TARGET_USER" >/dev/null 2>&1; then
    log_warn "User '${TARGET_USER}' does not exist on this system! Creating user or specifying existing user with -u is recommended."
    TARGET_UID=1000
    TARGET_GID=1000
    TARGET_GROUP="users"
    TARGET_HOME="/home/${TARGET_USER}"
else
    TARGET_UID=$(id -u "$TARGET_USER")
    TARGET_GID=$(id -g "$TARGET_USER")
    TARGET_GROUP=$(id -gn "$TARGET_USER")
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    [ -n "$TARGET_HOME" ] || TARGET_HOME="/home/${TARGET_USER}"
fi

# ------------------------------------------------------------------------------
# 1. Install Packages (Optional)
# ------------------------------------------------------------------------------
if [ "$INSTALL_PKGS" -eq 1 ]; then
    if ! command -v apk >/dev/null 2>&1; then
        log_warn "apk command not found. Skipping package installation."
    elif [ -f "$PKGS_FILE" ]; then
        log_info "Installing packages from ${PKGS_FILE}..."
        # Filter comments and empty lines
        PKGS_TO_INSTALL=$(grep -vE '^\s*(#|$)' "$PKGS_FILE" | tr '\n' ' ')
        if [ -n "$PKGS_TO_INSTALL" ]; then
            apk update
            # shellcheck disable=SC2086
            apk add --no-cache $PKGS_TO_INSTALL
            log_ok "Packages installed successfully."
        fi
    else
        log_warn "Package file ${PKGS_FILE} not found. Skipping."
    fi
fi

# ------------------------------------------------------------------------------
# 2. Install Files
# ------------------------------------------------------------------------------
log_info "Installing system binaries and OpenRC init scripts..."

# 2-1. /usr/local/sbin/waydroid-prepare + OpenRC service
install -d /usr/local/sbin
install -m 755 "${SCRIPT_DIR}/system/waydroid-prepare" /usr/local/sbin/waydroid-prepare
install -m 755 "${SCRIPT_DIR}/system/waydroid-prepare.initd" /etc/init.d/waydroid-prepare
log_ok "Installed Waydroid prepare service"

# 2-2. /usr/local/bin/waydroid-sway-session
install -d /usr/local/bin
install -m 755 "${SCRIPT_DIR}/system/waydroid-sway-session" /usr/local/bin/waydroid-sway-session
log_ok "Installed /usr/local/bin/waydroid-sway-session"

# 2-3. /etc/init.d/waydroid-sway (with user template substitution)
TMP_INIT=$(mktemp)
sed \
    -e "s|command_user=\".*\"|command_user=\"${TARGET_USER}:${TARGET_GROUP}\"|g" \
    -e "s|export HOME=\".*\"|export HOME=\"${TARGET_HOME}\"|g" \
    -e "s|export USER=\".*\"|export USER=\"${TARGET_USER}\"|g" \
    -e "s|export LOGNAME=\".*\"|export LOGNAME=\"${TARGET_USER}\"|g" \
    -e "s|--owner [^ ]*|--owner ${TARGET_USER}:${TARGET_GROUP}|g" \
    -e "s|/run/user/[0-9]*|/run/user/${TARGET_UID}|g" \
    "${SCRIPT_DIR}/system/waydroid-sway" > "$TMP_INIT"

install -m 755 "$TMP_INIT" /etc/init.d/waydroid-sway
rm -f "$TMP_INIT"
log_ok "Installed /etc/init.d/waydroid-sway (configured for user: ${TARGET_USER})"

# ------------------------------------------------------------------------------
# 3. Register Services to Runlevel
# ------------------------------------------------------------------------------
if [ "$ENABLE_SERVICE" -eq 1 ]; then
    if command -v rc-update >/dev/null 2>&1; then
        log_info "Adding services to default runlevel..."
        rc-update add waydroid-prepare default
        rc-update add waydroid-sway default
        log_ok "Registered waydroid-prepare and waydroid-sway in default runlevel."
    else
        log_warn "rc-update not found. Skipping runlevel registration."
    fi
fi

printf "\n"
log_ok "Alpine VM Waydroid installation completed successfully!"
printf "You can start the service now using:\n"
printf "  ${BLUE}rc-service waydroid-prepare start${NC}\n"
printf "  ${BLUE}rc-service waydroid-sway start${NC}\n\n"
