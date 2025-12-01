# carl: AI Commit Message Generator

## Project Overview

A Swift CLI tool that generates git commit messages using Apple's on-device Foundation Models (macOS 26+). Designed for integration with lazygit custom commands.

### Goals

- Generate conventional commit messages from staged git diffs
- Run entirely on-device using Apple Intelligence (no API keys, no network)
- Single binary distribution, no dependencies for end users
- Seamless lazygit integration via custom keybinding
- One-command installation via curl

### Non-Goals

- GUI application
- Support for macOS versions before 26 (Tahoe)
- Support for non-Apple Silicon Macs
- Integration with other git clients (lazygit only for now)

---

## Technical Requirements

### System Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon (M1, M2, M3, M4 series)
- Apple Intelligence enabled in System Settings
- Xcode Command Line Tools (install only, not for end users after binary is built)

### Dependencies

- Foundation (system)
- FoundationModels (system, macOS 26+)
- No third-party dependencies

---

## Architecture

```
┌─────────────┐    stdin     ┌─────────────┐    API call    ┌──────────────────┐
│   lazygit   │ ──────────▶  │ carl  │ ────────────▶  │ Foundation Models│
│ (git diff)  │              │   (Swift)   │                │   (on-device)    │
└─────────────┘              └─────────────┘                └──────────────────┘
                                   │
                                   ▼ stdout
                            commit message
```

### Data Flow

1. lazygit executes: `git diff --cached | carl`
2. carl reads diff from stdin
3. carl checks Foundation Models availability
4. carl sends diff to on-device LLM with system prompt
5. carl prints generated message to stdout
6. lazygit uses output as commit message

---

## File Structure

```
carl/
├── Package.swift              # Swift package manifest
├── Sources/
│   └── CommitGen.swift        # Main entry point and logic
├── install.sh                 # One-command installer
├── uninstall.sh               # Uninstaller
├── README.md                  # User documentation
├── LICENSE                    # MIT license
├── .gitignore
└── lazygit/
    └── config.example.yml     # Example lazygit configuration
```

---

## Implementation Plan

### Phase 1: Project Setup

#### Step 1.1: Initialize Swift Package

Create the project directory and initialize with Swift Package Manager.

```bash
mkdir carl && cd carl
swift package init --type executable --name carl
```

#### Step 1.2: Configure Package.swift

Replace the generated Package.swift with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "carl",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "carl",
            path: "Sources"
        )
    ]
)
```

#### Step 1.3: Rename Main File

Rename `Sources/main.swift` to `Sources/CommitGen.swift` (required for @main attribute with async).

---

### Phase 2: Core Implementation

#### Step 2.1: Basic Structure

Create the main entry point with async support:

```swift
import Foundation
import FoundationModels

@main
struct CommitGen {
    static func main() async {
        do {
            try await run()
        } catch {
            printError("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
    
    static func run() async throws {
        // Implementation goes here
    }
    
    static func printError(_ message: String) {
        fputs(message + "\n", stderr)
    }
}
```

#### Step 2.2: Stdin Reading

Implement efficient stdin reading using FileHandle:

```swift
static func readStdin() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}
```

#### Step 2.3: Availability Checking

Implement detailed availability checking with user-friendly errors:

```swift
enum AvailabilityError: Error, LocalizedError {
    case notEnabled
    case notEligible
    case modelNotReady
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Apple Intelligence is not enabled. Enable it in System Settings > Apple Intelligence & Siri"
        case .notEligible:
            return "This device doesn't support Apple Intelligence (requires Apple Silicon)"
        case .modelNotReady:
            return "The language model is still downloading. Please try again in a few minutes"
        case .unknown(let reason):
            return "Foundation Models unavailable: \(reason)"
        }
    }
}

static func checkAvailability() throws {
    switch SystemLanguageModel.default.availability {
    case .available:
        return
    case .unavailable(let reason):
        switch reason {
        case .appleIntelligenceNotEnabled:
            throw AvailabilityError.notEnabled
        case .deviceNotEligible:
            throw AvailabilityError.notEligible
        case .modelNotReady:
            throw AvailabilityError.modelNotReady
        @unknown default:
            throw AvailabilityError.unknown("\(reason)")
        }
    }
}
```

#### Step 2.4: Commit Message Generation

Implement the core generation logic using the FoundationModels API:

```swift
static let instructions = """
    You are a git commit message generator. Analyze the provided diff and generate
    a conventional commit message.

    FORMAT:
    type(scope): description

    TYPES:
    - feat: new feature
    - fix: bug fix
    - docs: documentation changes
    - style: formatting, missing semicolons, etc.
    - refactor: code restructuring without behavior change
    - test: adding or updating tests
    - chore: maintenance tasks, dependency updates

    RULES:
    - Use imperative mood ("Add" not "Added" or "Adds")
    - First line MUST be under 72 characters
    - Be specific but concise
    - Scope is optional, use when change is focused on specific area
    - Output ONLY the commit message, no explanations or markdown

    EXAMPLES:
    feat(auth): add OAuth2 login support
    fix: resolve null pointer in user service
    docs: update API documentation for v2 endpoints
    refactor(db): simplify query builder logic
    """

static func generateCommitMessage(for diff: String) async throws -> String {
    let session = LanguageModelSession(instructions: instructions)

    let prompt = "Generate a commit message for the following git diff:\n\n\(diff)"

    let response = try await session.respond(to: prompt)
    return cleanResponse(response.content)
}

static func cleanResponse(_ response: String) -> String {
    var message = response.trimmingCharacters(in: .whitespacesAndNewlines)

    // Remove markdown code blocks if present (handles ```commit, ```text, etc.)
    if message.hasPrefix("```") {
        let lines = message.components(separatedBy: "\n")
        if let endIndex = lines.dropFirst().firstIndex(where: { $0.hasPrefix("```") }) {
            message = lines[1..<endIndex].joined(separator: "\n")
        } else {
            message = lines.dropFirst().joined(separator: "\n")
        }
    }

    // Remove quotes if model wrapped the message
    if message.hasPrefix("\"") && message.hasSuffix("\"") && message.count > 2 {
        message = String(message.dropFirst().dropLast())
    }

    // Take only the first line if model added explanations
    if let firstLine = message.components(separatedBy: "\n").first,
       message.contains("\n\n") {
        message = firstLine
    }

    return message.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

#### Step 2.5: Main Run Function

Combine all components:

```swift
static func run() async throws {
    let diff = readStdin()
    
    guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        printError("Usage: git diff --cached | carl")
        printError("No diff provided on stdin")
        exit(1)
    }
    
    try checkAvailability()
    
    let message = try await generateCommitMessage(for: diff)
    print(message)
}
```

---

### Phase 3: Enhanced Features

#### Step 3.1: Diff Truncation

Handle very large diffs that might exceed context limits:

```swift
static let maxDiffLength = 8000 // characters, adjust based on testing

static func truncateDiff(_ diff: String) -> String {
    guard diff.count > maxDiffLength else { return diff }
    
    let truncated = String(diff.prefix(maxDiffLength))
    return truncated + "\n\n[... diff truncated for length ...]"
}
```

#### Step 3.2: Version Flag

Add basic --version support:

```swift
static let version = "1.0.0"

// In main(), before do block:
if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
    print("carl \(version)")
    return
}
```

---

### Phase 4: lazygit Integration

#### Step 4.1: Create Example Configuration

Create `lazygit/config.example.yml`:

```yaml
# lazygit configuration for carl integration
# Copy relevant sections to: ~/Library/Application Support/lazygit/config.yml

customCommands:
  # Simple: Generate and commit immediately
  - key: '<c-g>'
    context: 'files'
    description: 'AI: Generate commit message'
    loadingText: 'Generating commit message...'
    command: 'bash -c ''git commit -m "$(git diff --cached | carl)"'''

  # Edit first: Generate, edit in $EDITOR, then commit
  - key: '<c-e>'
    context: 'files'
    description: 'AI: Generate commit (edit first)'
    subprocess: true
    command: |
      bash -c '
        MSG=$(git diff --cached | carl)
        if [ -z "$MSG" ]; then
          echo "Failed to generate message" >&2
          exit 1
        fi
        TMPFILE=$(mktemp)
        printf "%s\n" "$MSG" > "$TMPFILE"
        ${EDITOR:-vim} "$TMPFILE"
        if [ -s "$TMPFILE" ]; then
          git commit -F "$TMPFILE"
        fi
        rm -f "$TMPFILE"
      '
```

---

### Phase 5: Distribution Scripts

> **Note:** Replace `USERNAME/carl` with your actual GitHub username/repo path in both scripts before committing.

#### Step 5.1: Create install.sh

Create `install.sh` in the repository root:

```bash
#!/bin/sh
set -e

# carl installer
# Usage: curl -fsSL https://raw.githubusercontent.com/USERNAME/carl/main/install.sh | sh

REPO="USERNAME/carl"
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
    echo "  ===================="
    echo ""

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
    printf "${GREEN}✓ carl installed successfully!${NC}\n"
    echo ""
    echo "Usage:"
    echo "  git diff --cached | carl"
    echo ""
    echo "For lazygit integration, see:"
    echo "  https://github.com/$REPO#with-lazygit"
    echo ""
}

main "$@"
```

#### Step 5.2: Create uninstall.sh

Create `uninstall.sh` in the repository root:

```bash
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
```

---

### Phase 6: Documentation

#### Step 6.1: Create README.md

```markdown
# carl

Generate git commit messages using Apple's on-device Foundation Models.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon Mac (M1/M2/M3/M4)
- Apple Intelligence enabled in System Settings

## Installation

### Quick Install (Recommended)

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/USERNAME/carl/main/install.sh | sh
\`\`\`

This downloads the source, builds locally (~30 seconds), and installs to `/usr/local/bin`.

**Note:** Requires Xcode Command Line Tools. If not installed, run:
\`\`\`bash
xcode-select --install
\`\`\`

### Manual Install

\`\`\`bash
git clone https://github.com/USERNAME/carl
cd carl
swift build -c release
sudo cp .build/release/carl /usr/local/bin/
\`\`\`

### Uninstall

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/USERNAME/carl/main/uninstall.sh | sh
\`\`\`

Or manually:
\`\`\`bash
sudo rm /usr/local/bin/carl
\`\`\`

## Usage

### Standalone

\`\`\`bash
git diff --cached | carl
\`\`\`

### With lazygit

Add to `~/Library/Application Support/lazygit/config.yml`:

\`\`\`yaml
customCommands:
  # Generate and commit immediately (Ctrl+G)
  - key: '<c-g>'
    context: 'files'
    description: 'AI commit message'
    loadingText: 'Generating commit message...'
    command: 'bash -c ''git commit -m "$(git diff --cached | carl)"'''

  # Generate, edit, then commit (Ctrl+E)
  - key: '<c-e>'
    context: 'files'
    description: 'AI commit (edit first)'
    subprocess: true
    command: |
      bash -c '
        MSG=$(git diff --cached | carl)
        if [ -z "$MSG" ]; then echo "Failed to generate" >&2; exit 1; fi
        TMPFILE=$(mktemp)
        printf "%s\n" "$MSG" > "$TMPFILE"
        ${EDITOR:-vim} "$TMPFILE"
        if [ -s "$TMPFILE" ]; then git commit -F "$TMPFILE"; fi
        rm -f "$TMPFILE"
      '
\`\`\`

Then in lazygit's files panel:
- Press `Ctrl+G` to generate and commit immediately
- Press `Ctrl+E` to generate, edit the message, then commit

## How It Works

1. Reads staged diff from stdin
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
```

#### Step 6.2: Create .gitignore

```
.DS_Store
.build/
.swiftpm/
*.xcodeproj
xcuserdata/
```

#### Step 6.3: Create LICENSE

```
MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

### Phase 7: Testing

#### Step 7.1: Manual Testing Checklist

- [ ] Empty stdin shows usage message
- [ ] Invalid/unavailable model shows helpful error
- [ ] Small diff generates appropriate message
- [ ] Large diff is handled (truncated if needed)
- [ ] Output has no extra formatting/quotes
- [ ] Works when piped from `git diff --cached`
- [ ] lazygit integration works with both keybindings (Ctrl+G and Ctrl+E)
- [ ] install.sh works on fresh system with Xcode CLT
- [ ] uninstall.sh removes binary correctly

#### Step 7.2: Test Cases

```bash
# Test 1: Version flag
carl --version
# Expected: carl 1.0.0

# Test 2: No input
echo "" | carl
# Expected: Error message about no diff

# Test 3: Simple diff
echo "diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1 +1 @@
-old
+new" | carl
# Expected: Something like "fix: update file.txt content"

# Test 4: Real staged changes
git add -A && git diff --cached | carl
# Expected: Contextually appropriate commit message
```

---

### Phase 8: Future Enhancements (Optional)

#### Homebrew Distribution

For wider distribution, create a Homebrew tap later:

```ruby
# Formula/carl.rb in a homebrew-tap repository
class CommitGen < Formula
  desc "Generate commit messages using Apple's on-device Foundation Models"
  homepage "https://github.com/USERNAME/carl"
  url "https://github.com/USERNAME/carl/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "CHECKSUM_HERE"
  license "MIT"

  depends_on macos: :tahoe
  depends_on :xcode => ["26.0", :build]

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/carl"
  end

  test do
    assert_match "carl", shell_output("#{bin}/carl --version")
  end
end
```

Users would then install with:
```bash
brew install USERNAME/tap/carl
```

---

## Complete Source Code Reference

### Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "carl",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "carl",
            path: "Sources"
        )
    ]
)
```

### Sources/CommitGen.swift

```swift
import Foundation
import FoundationModels

@main
struct CommitGen {

    // MARK: - Configuration

    static let version = "1.0.0"
    static let maxDiffLength = 8000

    static let instructions = """
        You are a git commit message generator. Analyze the provided diff and generate
        a conventional commit message.

        FORMAT:
        type(scope): description

        TYPES:
        - feat: new feature
        - fix: bug fix
        - docs: documentation changes
        - style: formatting, missing semicolons, etc.
        - refactor: code restructuring without behavior change
        - test: adding or updating tests
        - chore: maintenance tasks, dependency updates

        RULES:
        - Use imperative mood ("Add" not "Added" or "Adds")
        - First line MUST be under 72 characters
        - Be specific but concise
        - Scope is optional, use when change is focused on specific area
        - Output ONLY the commit message, no explanations or markdown
        """

    // MARK: - Entry Point

    static func main() async {
        // Handle --version flag
        if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
            print("carl \(version)")
            return
        }

        do {
            try await run()
        } catch let error as LanguageModelSession.GenerationError {
            printError("Generation error: \(error.localizedDescription)")
            exit(1)
        } catch {
            printError("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() async throws {
        let diff = readStdin()

        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            printError("Usage: git diff --cached | carl")
            printError("No diff provided on stdin")
            exit(1)
        }

        try checkAvailability()

        let truncatedDiff = truncateDiff(diff)
        let message = try await generateCommitMessage(for: truncatedDiff)
        print(message)
    }

    // MARK: - Input Handling

    static func readStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func truncateDiff(_ diff: String) -> String {
        guard diff.count > maxDiffLength else { return diff }
        let truncated = String(diff.prefix(maxDiffLength))
        return truncated + "\n\n[... diff truncated ...]"
    }

    // MARK: - Availability

    enum AvailabilityError: Error, LocalizedError {
        case notEnabled
        case notEligible
        case modelNotReady
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .notEnabled:
                return "Apple Intelligence is not enabled. Enable it in System Settings > Apple Intelligence & Siri"
            case .notEligible:
                return "This device doesn't support Apple Intelligence (requires Apple Silicon)"
            case .modelNotReady:
                return "The language model is still downloading. Please try again in a few minutes"
            case .unknown(let reason):
                return "Foundation Models unavailable: \(reason)"
            }
        }
    }

    static func checkAvailability() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                throw AvailabilityError.notEnabled
            case .deviceNotEligible:
                throw AvailabilityError.notEligible
            case .modelNotReady:
                throw AvailabilityError.modelNotReady
            @unknown default:
                throw AvailabilityError.unknown("\(reason)")
            }
        }
    }

    // MARK: - Generation

    static func generateCommitMessage(for diff: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)

        let prompt = "Generate a commit message for:\n\n\(diff)"
        let response = try await session.respond(to: prompt)
        return cleanResponse(response.content)
    }

    static func cleanResponse(_ response: String) -> String {
        var message = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks if present
        if message.hasPrefix("```") {
            let lines = message.components(separatedBy: "\n")
            if let endIndex = lines.dropFirst().firstIndex(where: { $0.hasPrefix("```") }) {
                message = lines[1..<endIndex].joined(separator: "\n")
            } else {
                message = lines.dropFirst().joined(separator: "\n")
            }
        }

        // Remove quotes if model wrapped the message
        if message.hasPrefix("\"") && message.hasSuffix("\"") && message.count > 2 {
            message = String(message.dropFirst().dropLast())
        }

        // Take only the first line if model added explanations
        if let firstLine = message.components(separatedBy: "\n").first,
           message.contains("\n\n") {
            message = firstLine
        }

        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Utilities

    static func printError(_ message: String) {
        fputs(message + "\n", stderr)
    }
}
```

---

## Success Criteria

- [ ] `swift build` completes without errors
- [ ] `carl --version` prints version string
- [ ] `git diff --cached | carl` produces a valid commit message
- [ ] Appropriate error messages for all failure modes
- [ ] lazygit keybindings work as documented
- [ ] `install.sh` works on a fresh system with Xcode CLT
- [ ] `uninstall.sh` cleanly removes the binary
- [ ] README provides complete setup instructions
