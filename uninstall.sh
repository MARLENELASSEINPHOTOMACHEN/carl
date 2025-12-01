#!/bin/sh
set -e

# carl uninstaller

INSTALL_DIR="/usr/local/bin"
BINARY="$INSTALL_DIR/carl"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ ! -f "$BINARY" ]; then
    printf "${RED}carl not found in $INSTALL_DIR${NC}\n"
    exit 1
fi

echo "Removing carl..."

if [ -w "$INSTALL_DIR" ]; then
    rm "$BINARY"
else
    sudo rm "$BINARY"
fi

printf "${GREEN}✓ carl uninstalled${NC}\n"
echo ""
echo "Note: lazygit configuration was not modified."
echo "Remove custom commands manually if needed:"
echo "  ~/Library/Application Support/lazygit/config.yml"
