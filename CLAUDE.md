# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

carl is a Swift CLI tool that generates git commit messages using Apple's on-device Foundation Models (FoundationModels framework). It requires macOS 26 (Tahoe)+, Apple Silicon, and Apple Intelligence enabled.

## Build Commands

```bash
# Build release binary
swift build -c release

# Build for development
swift build
```

Installation requires sudo (user must run manually):
```bash
sudo cp .build/release/carl /usr/local/bin/
```

## Usage

```bash
# Via stdin
git diff --cached | carl

# Via --staged flag (runs git diff --cached internally)
carl --staged

# Generate and commit in one step
carl commit

# Generate, edit inline, then commit
carl commit -e

# Auto-analyze and create multiple logical commits
carl auto

# Preview auto commits without executing
carl auto --dry-run

# Version
carl --version

# Lazygit integration
carl lazygit
```

## Architecture

Three-file implementation in `Sources/`:

**CommitGen.swift** - Main entry point and core logic:
- `@main struct CommitGen` with async main
- **Input**: Reads diff from stdin or runs `git diff --cached` directly via `--staged` flag
- **Processing**: Sends diff to `LanguageModelSession` with system instructions for conventional commit format
- **Output**: Cleans LLM response (removes markdown/quotes) and prints to stdout
- **Errors**: Written to stderr with descriptive messages for Apple Intelligence availability issues

Key components:
- `checkAvailability()` - Validates Apple Intelligence/model readiness
- `generateCommitMessage()` - Creates LanguageModelSession and prompts the model
- `cleanResponse()` - Strips markdown formatting, quotes, and extra explanations from model output
- `truncateDiff()` - Limits diff to 8000 chars to stay within context limits
- `runCommit(edit:)` - Generate and commit workflow with optional inline editing
- `withAnimation()` - Animated spinner for interactive terminal sessions

**AutoCommit.swift** - Multi-commit auto-analysis:
- `run()` - Entry point for `carl auto` command
- **Pass 1**: Inventory changed files via `git status --porcelain -z`
- **Pass 2-3**: Gather diffs and summarize each file via LLM (category, scope, description)
- **Pass 4**: Group related files into logical commits via LLM
- **Pass 5**: Execute commits sequentially (fail-fast on first error)
- Validates LLM-generated plans against actual file list
- Uses exit codes (not string matching) for git error detection

**LineEditor.swift** - Terminal line editing:
- `editablePrompt()` - Readline-style inline editor with cursor movement, supporting multi-byte UTF-8
- `visualWidth()` - Calculates terminal column width for proper cursor positioning
- `getTerminalWidth()` - Gets terminal dimensions via ioctl

## Dependencies

System frameworks only (no third-party packages):
- Foundation
- FoundationModels (macOS 26+)

## Reminders

- Always upgrade the version (in `Sources/CommitGen.swift:28`) depending on the change
- After changes, run `swift build -c release` then prompt the user to install manually