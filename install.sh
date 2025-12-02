#!/bin/sh
set -e

# carl installer
# Usage: curl -fsSL https://raw.githubusercontent.com/MARLENELASSEINPHOTOMACHEN/carl/main/install.sh | sh

REPO="MARLENELASSEINPHOTOMACHEN/carl"
INSTALL_DIR="/usr/local/bin"
TEMP_DIR=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

info() {
    printf "${GREEN}==>${NC} %s\n" "$1"
}

warn() {
    printf "${YELLOW}Warning:${NC} %s\n" "$1"
}

error() {
    printf "${RED}Error:${NC} %s\n" "$1" >&2
    exit 1
}

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Check for required tools
check_requirements() {
    if ! command -v git >/dev/null 2>&1; then
        error "git is not installed"
    fi

    if ! command -v swift >/dev/null 2>&1; then
        error "Swift toolchain not found. Install Xcode Command Line Tools: xcode-select --install"
    fi
}

# Check macOS version (26 = Tahoe)
check_macos_version() {
    macos_version=$(sw_vers -productVersion | cut -d. -f1)
    if [ "$macos_version" -lt 26 ]; then
        error "macOS 26 (Tahoe) or later required. You have macOS $(sw_vers -productVersion)."
    fi
}

# Check for Apple Silicon
check_architecture() {
    arch=$(uname -m)
    if [ "$arch" != "arm64" ]; then
        error "Apple Silicon (M1/M2/M3/M4) required. Detected: $arch"
    fi
}

# Main installation
main() {
    echo ""
    echo "  carl installer"
    echo "  =============="
    echo ""

    # Check if carl is already installed (for messaging)
    IS_UPDATE=false
    if command -v carl >/dev/null 2>&1; then
        IS_UPDATE=true
    fi

    info "Checking requirements..."
    check_requirements
    check_macos_version
    check_architecture

    # Create temp directory
    TEMP_DIR=$(mktemp -d)

    info "Downloading source..."
    if ! git clone --depth 1 --quiet "https://github.com/$REPO.git" "$TEMP_DIR/carl"; then
        error "Failed to clone repository"
    fi

    info "Building (this takes ~30 seconds)..."
    cd "$TEMP_DIR/carl"
    if ! swift build -c release --quiet 2>/dev/null; then
        # Retry without --quiet to show errors
        swift build -c release || error "Build failed"
    fi

    info "Installing to $INSTALL_DIR..."
    if [ -w "$INSTALL_DIR" ]; then
        cp ".build/release/carl" "$INSTALL_DIR/"
    else
        sudo cp ".build/release/carl" "$INSTALL_DIR/"
    fi

    # Verify installation
    if ! command -v carl >/dev/null 2>&1; then
        warn "$INSTALL_DIR may not be in your PATH"
    fi

    echo ""
    if [ "$IS_UPDATE" = true ]; then
        printf "${GREEN}✓ carl updated successfully!${NC}\n"
    else
        printf "${GREEN}✓ carl installed successfully!${NC}\n"
    fi
    echo ""
    echo "Usage:"
    echo "  git diff --cached | carl"
    echo ""
    printf "${YELLOW}Lazygit integration${NC} (run):\n"
    echo "  carl lazygit"
    echo ""
}

main "$@"
