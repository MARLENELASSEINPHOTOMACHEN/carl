# carl

Generate git commit messages using Apple's on-device Foundation Models.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon Mac (M1/M2/M3/M4)
- Apple Intelligence enabled in System Settings

## Installation

### Quick Install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/MARLENELASSEINPHOTOMACHEN/carl/main/install.sh | sh
```

This downloads the source, builds locally (~30 seconds), and installs to `/usr/local/bin`.

**Update:** Run the same command to update to the latest version.

**Note:** Requires Xcode Command Line Tools. If not installed, run:
```bash
xcode-select --install
```

### Manual Install

```bash
git clone https://github.com/MARLENELASSEINPHOTOMACHEN/carl
cd carl
swift build -c release
sudo cp .build/release/carl /usr/local/bin/
```

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/MARLENELASSEINPHOTOMACHEN/carl/main/uninstall.sh | sh
```

Or manually:
```bash
sudo rm /usr/local/bin/carl
```

## Usage

### Standalone

```bash
git diff --cached | carl
```

### With lazygit

```bash
carl lazygit
```

This adds keybindings to lazygit's files panel:
- `Ctrl+G` — generate and commit immediately
- `Ctrl+A` — generate, edit the message, then commit

Works with existing lazygit configs (merges automatically).

## How It Works

1. Reads staged diff (via `--staged` flag or stdin)
2. Sends to Apple's on-device ~3B parameter language model
3. Returns a conventional commit message

All processing happens locally—no API keys, no network requests, complete privacy.

## Troubleshooting

**"Apple Intelligence is not enabled"**
→ Open System Settings > Apple Intelligence & Siri > Enable Apple Intelligence

**"Model is still downloading"**
→ Wait a few minutes for initial model download after enabling Apple Intelligence

**"This device doesn't support Apple Intelligence"**
→ Requires Apple Silicon (M1 or later)

**"Swift toolchain not found"**
→ Install Xcode Command Line Tools: `xcode-select --install`

## License

MIT

## Roadmap

- [ ] Homebrew tap for `brew install` support
- [ ] Pre-built notarized binaries (requires Apple Developer Program, $99/year) for zero-dependency installs
- [ ] Additional commit message styles (simple, detailed, semantic-release)
- [ ] Multi-line commit body support with `--body` flag
