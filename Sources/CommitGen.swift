import Foundation
import FoundationModels

// MARK: - Options

struct Options {
    var command: Command = .generate
    var edit: Bool = false
    var staged: Bool = false
    var dryRun: Bool = false
    var verbose: Bool = false

    enum Command {
        case version
        case help
        case lazygit
        case commit
        case auto
        case generate
    }
}

@main
struct CommitGen {

    // MARK: - Configuration

    static let version = "1.4.3"
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
        "༼  つ-_- ༽ つ",
        "༼  つ◕_◕ ༽ つ",
        "༼ つ ◕_◕ ༽つ ",
        "༼ つ ◕_◕ ༽つ ",
    ]
    static let doneFrame = "( づ ◕‿◕ )づ ✦"

    // MARK: - Argument Parsing

    static func parseArguments() -> Options {
        var opts = Options()
        var args = Array(CommandLine.arguments.dropFirst())

        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--version", "-v":
                opts.command = .version
            case "--help", "-h":
                opts.command = .help
            case "--staged":
                opts.staged = true
            case "--edit", "-e":
                opts.edit = true
            case "--dry-run":
                opts.dryRun = true
            case "--verbose":
                opts.verbose = true
            case "lazygit":
                opts.command = .lazygit
            case "commit":
                opts.command = .commit
            case "auto":
                opts.command = .auto
            default:
                if arg.hasPrefix("-") {
                    printError("Unknown option: \(arg)")
                    printUsage()
                    exit(1)
                }
            }
        }
        return opts
    }

    static func printUsage() {
        print("""
        carl - AI-powered git commit message generator

        USAGE:
            git diff --cached | carl    Generate message from piped diff
            carl --staged               Generate message from staged changes
            carl commit [-e]            Generate and commit (optionally edit)
            carl auto [--dry-run]       Auto-analyze and create multiple commits
            carl lazygit                Install lazygit integration

        OPTIONS:
            -v, --version    Show version
            -h, --help       Show this help
            -e, --edit       Edit message before committing (with 'commit')
            --staged         Read staged changes directly (or only staged for 'auto')
            --dry-run        Show planned commits without executing (with 'auto')
            --verbose        Show detailed analysis output (with 'auto')
        """)
    }

    // MARK: - Entry Point

    static func main() async {
        let opts = parseArguments()

        do {
            switch opts.command {
            case .version:
                print("carl \(version)")
            case .help:
                printUsage()
            case .lazygit:
                installLazygitIntegration()
            case .commit:
                try await runCommit(edit: opts.edit)
            case .auto:
                try await AutoCommit.run(dryRun: opts.dryRun, stagedOnly: opts.staged, verbose: opts.verbose)
            case .generate:
                try await run(useStaged: opts.staged)
            }
        } catch let error as LanguageModelSession.GenerationError {
            clearLine()
            printError("Generation error: \(error.localizedDescription)")
            exit(1)
        } catch AutoError.alreadyReported {
            exit(1)
        } catch {
            clearLine()
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
