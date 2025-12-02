import Foundation
import FoundationModels

@main
struct CommitGen {

    // MARK: - Configuration

    static let version = "1.1.1"
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
