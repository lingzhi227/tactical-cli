#!/usr/bin/env bash
# Kimi CLI installer
# Usage: curl -fsSL https://raw.githubusercontent.com/lingzhi227/tactical-cli/main/install.sh | bash
set -euo pipefail

REPO="lingzhi227/tactical-cli"
PKG="kimi-cli"
BIN="kimi"

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

info()  { echo -e "${BOLD}${GREEN}==>${RESET} $*"; }
warn()  { echo -e "${BOLD}${YELLOW}warning:${RESET} $*"; }
error() { echo -e "${BOLD}${RED}error:${RESET} $*" >&2; }
die()   { error "$@"; exit 1; }

# --- detect OS & arch ---
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *)       die "Unsupported OS: $OS" ;;
esac
case "$ARCH" in
    x86_64|amd64)  ARCH="x86_64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *)             die "Unsupported architecture: $ARCH" ;;
esac

# --- installers ---
install_with_uv() {
    info "Installing ${PKG} with uv..."
    uv tool install --force "${PKG} @ git+https://github.com/${REPO}.git"
}

install_with_pipx() {
    info "Installing ${PKG} with pipx..."
    pipx install --force "${PKG} @ git+https://github.com/${REPO}.git"
}

install_with_pip() {
    info "Installing ${PKG} with pip..."
    pip install --user "${PKG} @ git+https://github.com/${REPO}.git"
}

install_uv() {
    info "Installing uv package manager..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
}

# --- main ---
main() {
    echo ""
    echo -e "${BOLD}Kimi CLI Installer${RESET}"
    echo -e "Platform: ${PLATFORM}/${ARCH}"
    echo ""

    # Check Python
    if ! command -v python3 &>/dev/null; then
        die "Python 3 is required. Install Python 3.12+ first."
    fi
    PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    PY_MAJOR="${PY_VER%%.*}"
    PY_MINOR="${PY_VER#*.}"
    if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 12 ]; }; then
        die "Python 3.12+ required, found ${PY_VER}"
    fi
    info "Found Python ${PY_VER}"

    # Install with best available tool
    if command -v uv &>/dev/null; then
        install_with_uv
    elif command -v pipx &>/dev/null; then
        install_with_pipx
    else
        warn "uv not found. Installing uv first (recommended)..."
        install_uv
        install_with_uv
    fi

    echo ""
    if command -v "${BIN}" &>/dev/null; then
        INSTALLED_VERSION="$("${BIN}" --version 2>/dev/null || echo 'unknown')"
        info "Installed successfully! (${INSTALLED_VERSION})"
    else
        warn "'${BIN}' not found in PATH."
        warn "Add ~/.local/bin to your PATH:"
        echo '  export PATH="$HOME/.local/bin:$PATH"'
        warn "Then restart your shell."
    fi

    echo ""
    echo -e "${BOLD}Get started:${RESET}"
    echo "  ${BIN}              # start interactive session"
    echo "  ${BIN} --help       # see all options"
    echo "  /login            # connect to an LLM backend"
    echo ""
}

main "$@"
