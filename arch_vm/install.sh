#!/bin/bash
# ==============================================================================
# Arch Linux VM Waydroid Installer
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKGS_FILE="${SCRIPT_DIR}/arch_packages"

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
  -p, --install-pkgs        Install packages listed in arch_packages (pacman + AUR helper)
  -u, --user <USERNAME>     Target user for user-level service and script (default: DOAS_USER, SUDO_USER or current user)
  --system-only             Install only system-level files and services (/etc, /usr/local/sbin)
  --user-only               Install only user-level files and services (~/.config, ~/.local/bin)
  --enable-linger           Enable loginctl linger for the user (runs user services without active login)
  --no-service              Skip enabling systemd services
  --uninstall               Remove installed files and disable services
  -h, --help                Show this help message

Description:
  Installs Waydroid headless sway session and preparation service for Arch Linux:
  [System]
    - /usr/local/sbin/waydroid-prepare
    - /etc/systemd/system/waydroid-prepare.service
    - /etc/systemd/system/waydroid-container.service.d/override.conf
  [User]
    - ~/.local/bin/waydroid-sway
    - ~/.config/systemd/user/waydroid-sway.service
EOF
    exit 0
}

INSTALL_PKGS=0
ENABLE_SERVICE=1
INSTALL_SYSTEM=1
INSTALL_USER=1
ENABLE_LINGER=0
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
        --system-only)
            INSTALL_SYSTEM=1
            INSTALL_USER=0
            shift
            ;;
        --user-only)
            INSTALL_SYSTEM=0
            INSTALL_USER=1
            shift
            ;;
        --enable-linger)
            ENABLE_LINGER=1
            shift
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

# ------------------------------------------------------------------------------
# Determine Target User & Home
# ------------------------------------------------------------------------------
if [ -z "$TARGET_USER" ]; then
    if [ -n "${DOAS_USER:-}" ] && [ "$DOAS_USER" != "root" ]; then
        TARGET_USER="$DOAS_USER"
    elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        TARGET_USER="$SUDO_USER"
    elif [ "$(id -u)" -ne 0 ]; then
        TARGET_USER="$(id -un)"
    elif id forumi0721 >/dev/null 2>&1; then
        TARGET_USER="forumi0721"
    else
        FIRST_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd 2>/dev/null || true)
        if [ -n "$FIRST_USER" ]; then
            TARGET_USER="$FIRST_USER"
        else
            TARGET_USER="root"
        fi
    fi
fi

if id "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    TARGET_GROUP=$(id -gn "$TARGET_USER")
else
    log_err "Target user '${TARGET_USER}' does not exist!"
    exit 1
fi

# ------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    log_info "Uninstalling Arch Waydroid components..."

    if [ "$INSTALL_SYSTEM" -eq 1 ]; then
        if [ "$(id -u)" -ne 0 ]; then
            log_err "Root privileges required to uninstall system components."
            exit 1
        fi
        log_info "Removing system-level units and scripts..."
        systemctl disable --now waydroid-prepare.service 2>/dev/null || true
        rm -f /usr/local/sbin/waydroid-prepare
        rm -f /etc/systemd/system/waydroid-prepare.service
        rm -f /etc/systemd/system/waydroid-container.service.d/override.conf
        [ -d /etc/systemd/system/waydroid-container.service.d ] && rmdir --ignore-fail-on-non-empty /etc/systemd/system/waydroid-container.service.d
        systemctl daemon-reload 2>/dev/null || true
    fi

    if [ "$INSTALL_USER" -eq 1 ]; then
        log_info "Removing user-level units and scripts for user: ${TARGET_USER}..."
        USER_UNIT="${TARGET_HOME}/.config/systemd/user/waydroid-sway.service"
        USER_BIN="${TARGET_HOME}/.local/bin/waydroid-sway"

        if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
            su - "$TARGET_USER" -c "systemctl --user disable --now waydroid-sway.service" 2>/dev/null || true
        elif [ "$(id -un)" = "$TARGET_USER" ]; then
            systemctl --user disable --now waydroid-sway.service 2>/dev/null || true
        fi

        rm -f "$USER_UNIT"
        rm -f "$USER_BIN"
    fi

    log_ok "Uninstallation complete."
    exit 0
fi

# ------------------------------------------------------------------------------
# Check Privileges
# ------------------------------------------------------------------------------
if [ "$INSTALL_SYSTEM" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    log_err "System files installation requires root privileges. Please run with sudo or doas."
    exit 1
fi

log_info "Target user: ${TARGET_USER} (Home: ${TARGET_HOME})"

# ------------------------------------------------------------------------------
# 1. Package Installation
# ------------------------------------------------------------------------------
if [ "$INSTALL_PKGS" -eq 1 ]; then
    if ! command -v pacman >/dev/null 2>&1; then
        log_warn "pacman not found. Skipping package installation."
    elif [ -f "$PKGS_FILE" ]; then
        log_info "Reading packages from ${PKGS_FILE}..."
        ALL_PKGS=()
        while IFS= read -r pkg || [ -n "$pkg" ]; do
            pkg=$(echo "$pkg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            [ -z "$pkg" ] && continue
            [[ "$pkg" =~ ^# ]] && continue
            ALL_PKGS+=("$pkg")
        done < "$PKGS_FILE"

        REPO_PKGS=()
        AUR_PKGS=()

        for pkg in "${ALL_PKGS[@]}"; do
            if pacman -Si "$pkg" >/dev/null 2>&1; then
                REPO_PKGS+=("$pkg")
            else
                AUR_PKGS+=("$pkg")
            fi
        done

        if [ ${#REPO_PKGS[@]} -gt 0 ]; then
            log_info "Installing official repository packages via pacman..."
            pacman -S --needed --noconfirm "${REPO_PKGS[@]}"
            log_ok "Official repository packages installed."
        fi

        if [ ${#AUR_PKGS[@]} -gt 0 ]; then
            log_info "Found AUR/custom packages: ${AUR_PKGS[*]}"
            AUR_HELPER=""
            for helper in paru yay; do
                if command -v "$helper" >/dev/null 2>&1; then
                    AUR_HELPER="$helper"
                    break
                fi
            done

            if [ -n "$AUR_HELPER" ]; then
                log_info "Installing AUR packages using ${AUR_HELPER}..."
                if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
                    su - "$TARGET_USER" -c "$AUR_HELPER -S --needed --noconfirm ${AUR_PKGS[*]}"
                else
                    "$AUR_HELPER" -S --needed --noconfirm "${AUR_PKGS[@]}"
                fi
                log_ok "AUR packages installed."
            else
                log_warn "No AUR helper (paru/yay) found. Please install the following packages manually:"
                for p in "${AUR_PKGS[@]}"; do
                    printf "  - %s\n" "$p"
                done
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 2. Install System Components
# ------------------------------------------------------------------------------
if [ "$INSTALL_SYSTEM" -eq 1 ]; then
    log_info "Installing system components..."

    # 2-1. /usr/local/sbin/waydroid-prepare
    install -d /usr/local/sbin
    install -m 755 "${SCRIPT_DIR}/system/waydroid-prepare" /usr/local/sbin/waydroid-prepare
    log_ok "Installed /usr/local/sbin/waydroid-prepare"

    # 2-2. /etc/systemd/system/waydroid-prepare.service
    install -d /etc/systemd/system
    install -m 644 "${SCRIPT_DIR}/system/waydroid-prepare.service" /etc/systemd/system/waydroid-prepare.service
    log_ok "Installed /etc/systemd/system/waydroid-prepare.service"

    # 2-3. /etc/systemd/system/waydroid-container.service.d/override.conf
    install -d /etc/systemd/system/waydroid-container.service.d
    if [ -f "${SCRIPT_DIR}/system/waydroid-container.service.d/override.conf" ]; then
        install -m 644 "${SCRIPT_DIR}/system/waydroid-container.service.d/override.conf" \
            /etc/systemd/system/waydroid-container.service.d/override.conf
    elif [ -f "${SCRIPT_DIR}/system/waydroid-container.service.d_override.conf" ]; then
        install -m 644 "${SCRIPT_DIR}/system/waydroid-container.service.d_override.conf" \
            /etc/systemd/system/waydroid-container.service.d/override.conf
    fi
    log_ok "Installed /etc/systemd/system/waydroid-container.service.d/override.conf"

    # Systemd reload & enable
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        if [ "$ENABLE_SERVICE" -eq 1 ]; then
            systemctl enable waydroid-prepare.service
            log_ok "Enabled waydroid-prepare.service"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 3. Install User Components
# ------------------------------------------------------------------------------
if [ "$INSTALL_USER" -eq 1 ]; then
    log_info "Installing user components for ${TARGET_USER}..."

    USER_BIN_DIR="${TARGET_HOME}/.local/bin"
    USER_SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"

    # Create directories with proper user ownership
    mkdir -p "$USER_BIN_DIR" "$USER_SYSTEMD_DIR"

    # 3-1. ~/.local/bin/waydroid-sway
    cp -f "${SCRIPT_DIR}/user/waydroid-sway" "${USER_BIN_DIR}/waydroid-sway"
    chmod 755 "${USER_BIN_DIR}/waydroid-sway"
    log_ok "Installed ${USER_BIN_DIR}/waydroid-sway"

    # 3-2. ~/.config/systemd/user/waydroid-sway.service
    cp -f "${SCRIPT_DIR}/user/waydroid-sway.service" "${USER_SYSTEMD_DIR}/waydroid-sway.service"
    chmod 644 "${USER_SYSTEMD_DIR}/waydroid-sway.service"
    log_ok "Installed ${USER_SYSTEMD_DIR}/waydroid-sway.service"

    # Fix ownership if run as root
    if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
        chown -R "${TARGET_USER}:${TARGET_GROUP}" "${USER_BIN_DIR}/waydroid-sway"
        chown -R "${TARGET_USER}:${TARGET_GROUP}" "${USER_SYSTEMD_DIR}/waydroid-sway.service"
    fi

    # Linger option
    if [ "$ENABLE_LINGER" -eq 1 ]; then
        if command -v loginctl >/dev/null 2>&1; then
            loginctl enable-linger "$TARGET_USER"
            log_ok "Enabled linger for user '${TARGET_USER}'."
        else
            log_warn "loginctl not found. Cannot enable linger automatically."
        fi
    fi

    # Enable user service if requested
    if [ "$ENABLE_SERVICE" -eq 1 ]; then
        if [ "$(id -un)" = "$TARGET_USER" ]; then
            systemctl --user daemon-reload
            systemctl --user enable waydroid-sway.service
            log_ok "Enabled waydroid-sway.service (user)"
        else
            log_info "To enable the user service, run as '${TARGET_USER}':"
            printf "  ${BLUE}systemctl --user daemon-reload${NC}\n"
            printf "  ${BLUE}systemctl --user enable --now waydroid-sway.service${NC}\n"
        fi
    fi
fi

printf "\n"
log_ok "Arch Linux Waydroid installation completed successfully!"
if [ "$ENABLE_LINGER" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    printf "\n${YELLOW}[TIP]${NC} To keep the headless Sway session running without logging in:\n"
    printf "  ${BLUE}doas loginctl enable-linger %s${NC}  # or sudo\n\n" "$TARGET_USER"
fi
