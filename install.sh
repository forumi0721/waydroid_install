#!/bin/bash
# ==============================================================================
# Unified Waydroid Installer for Alpine LXC and Arch VM
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [TARGET] [OPTIONS]

TARGET:
  alpine        Install Waydroid components for Alpine LXC (OpenRC)
  arch          Install Waydroid components for Arch Linux VM (systemd)
  (If omitted, the target is automatically detected from /etc/os-release)

OPTIONS:
  -p, --install-pkgs    Install required packages (apk / pacman + AUR)
  -u, --user <NAME>     Specify user for session / user service
  --uninstall           Uninstall the components
  -h, --help            Show this help message

Examples:
  sudo ./install.sh                        # Auto-detect OS and install
  sudo ./install.sh -p                     # Auto-detect OS, install packages & files
  sudo ./install.sh alpine -p -u myuser    # Explicitly install on Alpine with packages
  sudo ./install.sh arch -p --enable-linger # Install on Arch with packages & linger
  sudo ./install.sh --uninstall            # Uninstall components
EOF
    exit 0
}

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            alpine)
                echo "alpine"
                return 0
                ;;
            arch|archarm|cachyos|endeavouros|manjaro|artix)
                echo "arch"
                return 0
                ;;
            *)
                # Check ID_LIKE
                case "${ID_LIKE:-}" in
                    *alpine*)
                        echo "alpine"
                        return 0
                        ;;
                    *arch*)
                        echo "arch"
                        return 0
                        ;;
                esac
                ;;
        esac
    fi
    echo "unknown"
}

TARGET=""
FORWARD_ARGS=()

# Parse first argument if it explicitly specifies the target
if [ $# -gt 0 ]; then
    case "$1" in
        alpine)
            TARGET="alpine"
            shift
            ;;
        arch)
            TARGET="arch"
            shift
            ;;
        -h|--help)
            usage
            ;;
    esac
fi

# Pass remaining arguments to the sub-installer
FORWARD_ARGS=("$@")

# If TARGET is not explicitly given, try auto-detection
if [ -z "$TARGET" ]; then
    DETECTED=$(detect_os)
    if [ "$DETECTED" != "unknown" ]; then
        TARGET="$DETECTED"
        printf "${CYAN}[INFO] Auto-detected OS:${NC} %s\n" "$TARGET"
    else
        printf "${YELLOW}[WARN] Could not automatically determine target environment from /etc/os-release.${NC}\n"
        printf "Please select target:\n"
        printf "  1) Alpine LXC (OpenRC)\n"
        printf "  2) Arch Linux VM (systemd)\n"
        printf "  q) Quit\n"
        read -r -p "Enter choice [1-2]: " choice
        case "$choice" in
            1) TARGET="alpine" ;;
            2) TARGET="arch" ;;
            *) echo "Cancelled."; exit 1 ;;
        esac
    fi
fi

case "$TARGET" in
    alpine)
        printf "${GREEN}==> Launching Alpine LXC Installer...${NC}\n"
        exec "${SCRIPT_DIR}/alpine_lxc/install.sh" "${FORWARD_ARGS[@]}"
        ;;
    arch)
        printf "${GREEN}==> Launching Arch Linux VM Installer...${NC}\n"
        exec "${SCRIPT_DIR}/arch_vm/install.sh" "${FORWARD_ARGS[@]}"
        ;;
    *)
        printf "${RED}[ERROR] Invalid target: %s${NC}\n" "$TARGET" >&2
        usage
        ;;
esac
