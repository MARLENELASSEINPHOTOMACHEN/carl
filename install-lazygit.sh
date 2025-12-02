#!/bin/sh
set -e

# carl lazygit integration installer

REPO="MARLENELASSEINPHOTOMACHEN/carl"
CONFIG="$HOME/Library/Application Support/lazygit/config.yml"
CONFIG_URL="https://raw.githubusercontent.com/$REPO/main/lazygit/config.example.yml"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Already installed?
if [ -f "$CONFIG" ] && grep -q "carl --staged" "$CONFIG"; then
    printf "${GREEN}✓${NC} carl lazygit integration already installed\n"
    exit 0
fi

# Download carl config
CARL_CONFIG=$(curl -fsSL "$CONFIG_URL" 2>/dev/null) || {
    printf "${RED}Error:${NC} Failed to download config (network error)\n"
    exit 1
}

# Validate downloaded config
if ! echo "$CARL_CONFIG" | grep -q "customCommands:"; then
    printf "${RED}Error:${NC} Downloaded config appears invalid\n"
    exit 1
fi

# Extract command entries (without customCommands: header)
CARL_ENTRIES=$(echo "$CARL_CONFIG" | sed -n '/^customCommands:/,$ { /^customCommands:/d; p; }')

if [ -f "$CONFIG" ] && [ -s "$CONFIG" ]; then
    # Backup before modifying
    cp "$CONFIG" "$CONFIG.bak"

    if grep -q "^customCommands:" "$CONFIG"; then
        # Insert right after existing customCommands: line
        ed -s "$CONFIG" <<EOF
/^customCommands:/a
$CARL_ENTRIES
.
w
q
EOF
        printf "${GREEN}✓${NC} carl commands added to existing lazygit config\n"
    else
        # No customCommands - append whole block
        { echo ""; echo "$CARL_CONFIG" | sed -n '/^customCommands:/,$p'; } >> "$CONFIG"
        printf "${GREEN}✓${NC} carl commands added to lazygit config\n"
    fi

    printf "  Backup: ${YELLOW}%s.bak${NC}\n" "$CONFIG"
    echo ""
    printf "  rm \"%s.bak\"\n" "$CONFIG"
else
    # Create new config
    mkdir -p "$(dirname "$CONFIG")"
    echo "$CARL_CONFIG" > "$CONFIG"
    printf "${GREEN}✓${NC} Lazygit config created with carl integration\n"
fi

echo ""
echo "Keybindings in lazygit files panel:"
printf "  ${YELLOW}Ctrl+G${NC}  Generate and commit immediately\n"
printf "  ${YELLOW}Ctrl+A${NC}  Generate, edit, then commit\n"
echo ""
