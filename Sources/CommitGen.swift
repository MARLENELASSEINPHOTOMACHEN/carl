import Foundation
import FoundationModels

@main
struct CommitGen {

    // MARK: - Configuration

    static let version = "1.2.0"
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
        - Output ONLY the raw commit message, nothing else
        - NO markdown: no backticks, no asterisks, no quotes, no formatting
        """

    // MARK: - Configuration (lazygit)

    static let lazygitScriptURL = "https://raw.githubusercontent.com/MARLENELASSEINPHOTOMACHEN/carl/main/install-lazygit.sh"

    // MARK: - Animation

    static let thinkingFrames = [
        "༼ つ ◕_◕ ༽ つ",
        "༼  つ◕_◕ ༽ つ",
        "༼  つ◕_◕ ༽ つ",
        "༼ つ ◕_◕ ༽ つ",
        "༼つ  ◕_◕ ༽つ ",
        "༼ つ ◕_◕ ༽つ ",
        "༼ つ -_- ༽つ ",
        "༼  つ-_- ༽つ ",
        "༼  つ-_- ༽ つ ",
        "༼  つ◕_◕ ༽ つ",
        "༼ つ ◕_◕ ༽つ ",
        "༼ つ ◕_◕ ༽つ ",
    ]
    static let doneFrame = "( づ ◕‿◕ )づ ✦"

    // MARK: - Entry Point

    static func main() async {
        // Handle --version flag
        if CommandLine.arguments.contains("--version") || CommandLine.arguments.contains("-v") {
            print("carl \(version)")
            return
        }

        // Handle lazygit subcommand
        if CommandLine.arguments.contains("lazygit") {
            installLazygitIntegration()
            return
        }

        // Handle commit subcommand
        if CommandLine.arguments.contains("commit") {
            let useEdit = CommandLine.arguments.contains("--edit") ||
                          CommandLine.arguments.contains("-e")
            do {
                try await runCommit(edit: useEdit)
            } catch let error as LanguageModelSession.GenerationError {
                clearLine()
                printError("Generation error: \(error.localizedDescription)")
                exit(1)
            } catch {
                clearLine()
                printError("Error: \(error.localizedDescription)")
                exit(1)
            }
            return
        }

        // Handle --staged flag (reads git diff --cached directly)
        let useStaged = CommandLine.arguments.contains("--staged")

        do {
            try await run(useStaged: useStaged)
        } catch let error as LanguageModelSession.GenerationError {
            printError("Generation error: \(error.localizedDescription)")
            exit(1)
        } catch {
            printError("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(useStaged: Bool) async throws {
        let diff: String
        if useStaged {
            diff = runGitDiffCached()
        } else {
            diff = readStdin()
        }

        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            printError("Usage: git diff --cached | carl")
            printError("   or: carl --staged")
            printError("No diff provided")
            exit(1)
        }

        try checkAvailability()

        let truncatedDiff = truncateDiff(diff)
        let message = try await generateCommitMessage(for: truncatedDiff)
        print(message)
    }

    // MARK: - Commit Command

    static func runCommit(edit: Bool) async throws {
        let diff = runGitDiffCached()

        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            printError("No staged changes to commit")
            printError("Stage files with: git add <files>")
            exit(1)
        }

        try checkAvailability()

        let truncatedDiff = truncateDiff(diff)
        let message = try await withAnimation {
            try await generateCommitMessage(for: truncatedDiff)
        }

        let finalMessage: String
        if edit {
            clearLine()
            guard let edited = editablePrompt(prefill: message, prompt: "\(doneFrame) ") else {
                printError("Commit aborted")
                exit(1)
            }
            finalMessage = edited
        } else {
            clearLine()
            print("\(doneFrame) \(message)")
            finalMessage = message
        }

        runGitCommit(message: finalMessage)
    }

    static func withAnimation<T>(_ work: () async throws -> T) async throws -> T {
        let isInteractive = isatty(STDERR_FILENO) != 0

        guard isInteractive else {
            fputs("Generating commit message...\n", stderr)
            return try await work()
        }

        let animationTask = Task {
            var frameIndex = 0
            while !Task.isCancelled {
                let frame = thinkingFrames[frameIndex % thinkingFrames.count]
                fputs("\r\u{1B}[K\(frame)", stderr)
                fflush(stderr)
                frameIndex += 1
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        do {
            let result = try await work()
            animationTask.cancel()
            return result
        } catch {
            animationTask.cancel()
            throw error
        }
    }

    static func clearLine() {
        if isatty(STDERR_FILENO) != 0 {
            fputs("\r\u{1B}[K", stderr)
            fflush(stderr)
        }
    }

    static func runGitCommit(message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "commit", "-m", message]

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.standardOutput
        process.standardError = stderrPipe

        do {
            try process.run()

            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                printError("git commit failed: \(errorMsg.isEmpty ? "exit code \(process.terminationStatus)" : errorMsg)")
                exit(1)
            }
        } catch {
            printError("Failed to run git commit: \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Line Editor

    static func getTerminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80  // fallback
    }

    static func editablePrompt(prefill: String, prompt: String) -> String? {
        guard isatty(STDIN_FILENO) != 0 else {
            return prefill
        }

        // Save original terminal settings
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)

        // Set up raw mode
        var raw = originalTermios
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Restore terminal on exit
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        }

        var buffer = Array(prefill.utf8)
        var cursorPos = buffer.count
        let promptLen = prompt.count

        // Save cursor position at start
        fputs("\u{1B}7", stdout)  // DECSC - save cursor

        func redraw() {
            let termWidth = getTerminalWidth()
            let text = String(bytes: buffer, encoding: .utf8) ?? ""

            // Restore to saved position and clear to end of screen
            fputs("\u{1B}8\u{1B}[J\(prompt)\(text)", stdout)

            // Position cursor correctly
            let cursorOffset = buffer.count - cursorPos
            if cursorOffset > 0 {
                let cursorTotalPos = promptLen + cursorPos
                let endTotalPos = promptLen + buffer.count
                let targetLine = cursorTotalPos / termWidth
                let endLine = endTotalPos / termWidth
                let targetCol = cursorTotalPos % termWidth

                // Move up if needed
                let linesToMoveUp = endLine - targetLine
                if linesToMoveUp > 0 {
                    fputs("\u{1B}[\(linesToMoveUp)A", stdout)
                }

                // Move to correct column
                fputs("\r", stdout)
                if targetCol > 0 {
                    fputs("\u{1B}[\(targetCol)C", stdout)
                }
            }

            fflush(stdout)
        }

        redraw()

        while true {
            var c: UInt8 = 0
            let bytesRead = read(STDIN_FILENO, &c, 1)

            guard bytesRead == 1 else { continue }

            switch c {
            case 3:  // Ctrl+C
                fputs("\n", stdout)
                fflush(stdout)
                return nil

            case 13, 10:  // Enter
                // Move to end and newline
                let termWidth = getTerminalWidth()
                let cursorTotalPos = promptLen + cursorPos
                let endTotalPos = promptLen + buffer.count
                let linesToEnd = (endTotalPos / termWidth) - (cursorTotalPos / termWidth)
                if linesToEnd > 0 {
                    fputs("\u{1B}[\(linesToEnd)B", stdout)
                }
                fputs("\n", stdout)
                fflush(stdout)
                let result = String(bytes: buffer, encoding: .utf8) ?? ""
                return result.isEmpty ? nil : result

            case 127, 8:  // Backspace / Delete
                if cursorPos > 0 {
                    buffer.remove(at: cursorPos - 1)
                    cursorPos -= 1
                    redraw()
                }

            case 27:  // Escape sequence (arrow keys)
                var seq: [UInt8] = [0, 0]
                if read(STDIN_FILENO, &seq[0], 1) == 1 && read(STDIN_FILENO, &seq[1], 1) == 1 {
                    if seq[0] == 91 {  // [
                        switch seq[1] {
                        case 68:  // Left arrow
                            if cursorPos > 0 {
                                cursorPos -= 1
                                redraw()
                            }
                        case 67:  // Right arrow
                            if cursorPos < buffer.count {
                                cursorPos += 1
                                redraw()
                            }
                        case 72:  // Home
                            cursorPos = 0
                            redraw()
                        case 70:  // End
                            cursorPos = buffer.count
                            redraw()
                        default:
                            break
                        }
                    }
                }

            case 1:  // Ctrl+A (Home)
                cursorPos = 0
                redraw()

            case 5:  // Ctrl+E (End)
                cursorPos = buffer.count
                redraw()

            case 21:  // Ctrl+U (Clear line)
                buffer.removeAll()
                cursorPos = 0
                redraw()

            case 32...126:  // Printable ASCII
                buffer.insert(c, at: cursorPos)
                cursorPos += 1
                redraw()

            default:
                break
            }
        }
    }

    // MARK: - Input Handling

    static func readStdin() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func runGitDiffCached() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "diff", "--cached"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()

            // Read pipes before waiting to avoid deadlock on large diffs
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                printError("git error: \(errorMsg.isEmpty ? "exit code \(process.terminationStatus)" : errorMsg)")
                exit(1)
            }

            return String(data: outData, encoding: .utf8) ?? ""
        } catch {
            printError("Failed to run git: \(error.localizedDescription)")
            exit(1)
        }
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

    // MARK: - Lazygit Integration

    static func installLazygitIntegration() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "curl -fsSL '\(lazygitScriptURL)' | sh"]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                printError("Failed to install lazygit integration")
                exit(1)
            }
        } catch {
            printError("Failed to run installer: \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Utilities

    static func printError(_ message: String) {
        fputs(message + "\n", stderr)
    }
}
