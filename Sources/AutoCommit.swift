import Foundation
import FoundationModels

// MARK: - Output Types (Codable for JSON parsing)

struct FileSummary: Codable {
    var summary: String
    var category: String
    var scope: String
}

struct CommitGroup: Codable {
    var files: [String]
    var message: String
}

struct CommitPlan: Codable {
    var commits: [CommitGroup]
}

// MARK: - Internal Types

enum FileChange {
    case added(path: String)
    case modified(path: String)
    case deleted(path: String)
    case renamed(old: String, new: String)

    var path: String {
        switch self {
        case .added(let p), .modified(let p), .deleted(let p): return p
        case .renamed(_, let new): return new
        }
    }

    var verb: String {
        switch self {
        case .added: return "add"
        case .modified: return "update"
        case .deleted: return "remove"
        case .renamed: return "rename"
        }
    }
}

// MARK: - Prompts

enum Prompts {
    static let fileSummary = """
        Analyze this git diff and respond with ONLY a JSON object (no markdown, no explanation):
        {
          "summary": "brief description of changes, max 15 words",
          "category": "one of: feat, fix, refactor, docs, test, chore, style",
          "scope": "primary component/module affected, e.g. auth, api, ui"
        }
        """

    static let grouping = """
        Group these file changes into logical commits.

        Rules:
        - PREFER FEWER, LARGER COMMITS over many small ones
        - Aim for 2-3 commits maximum for a typical feature branch
        - Group liberally: combine anything that's part of the same feature or effort
        - Only separate truly unrelated work (e.g., unrelated bugfix mixed with new feature)
        - When in doubt, combine into one commit
        - Use conventional commit format: type(scope): description

        Respond with ONLY a JSON object (no markdown, no explanation):
        {
          "commits": [
            {
              "files": ["path/to/file1", "path/to/file2"],
              "message": "feat(scope): description"
            }
          ]
        }
        """
}

// MARK: - Result Types

struct AutoResult {
    var successful: [CommitGroup] = []
}

// MARK: - Errors

enum AutoError: Error, LocalizedError {
    case noChanges
    case tooManyFiles(count: Int, limit: Int)
    case gitError(String)
    case parseError(String)
    case commitFailed(successful: [CommitGroup], failed: CommitGroup, error: String)
    case alreadyReported  // Error already printed, just exit

    var errorDescription: String? {
        switch self {
        case .noChanges:
            return "Nothing to commit"
        case .tooManyFiles(let count, let limit):
            return "Too many files (\(count)) - limit is \(limit). Please commit in smaller batches."
        case .gitError(let msg):
            return "Git error: \(msg)"
        case .parseError(let msg):
            return "Failed to parse LLM response: \(msg)"
        case .commitFailed(_, let failed, let error):
            return "Commit failed for '\(failed.message)': \(error)"
        case .alreadyReported:
            return nil
        }
    }
}

// MARK: - Git Result

struct GitResult {
    let output: String
    let errorOutput: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

// MARK: - AutoCommit

struct AutoCommit {

    // MARK: - Configuration

    static let maxFiles = 30
    static let maxDiffPerFile = 6000

    // MARK: - Entry Point

    static func run(dryRun: Bool, stagedOnly: Bool, verbose: Bool) async throws {
        // Pass 1: Inventory
        let files = try getChangedFiles(stagedOnly: stagedOnly)

        guard !files.isEmpty else {
            print("Nothing to commit")
            return
        }

        guard files.count <= maxFiles else {
            throw AutoError.tooManyFiles(count: files.count, limit: maxFiles)
        }

        try CommitGen.checkAvailability()

        print("Analyzing \(files.count) file\(files.count == 1 ? "" : "s")...")

        // Pass 2 & 3: Gather diffs + Summarize
        let binaryFiles = detectBinaryFiles(stagedOnly: stagedOnly)
        let summaries = try await analyzeFiles(files, stagedOnly: stagedOnly, binaryFiles: binaryFiles, verbose: verbose)

        // Print verbose summaries
        if verbose && !summaries.isEmpty {
            print("")
            print("File summaries:")
            for (path, summary) in summaries.sorted(by: { $0.key < $1.key }) {
                print("  \(path)")
                print("    \(summary.summary) [\(summary.category)] (\(summary.scope))")
            }
        }

        // Pass 4: Create commit plan
        let plan = try await createCommitPlan(from: summaries, files: files, binaryFiles: binaryFiles)

        // Pass 5: Execute or display
        do {
            let result = try executeCommits(plan, dryRun: dryRun, verbose: verbose)
            printResults(result, dryRun: dryRun, plan: plan)
        } catch AutoError.commitFailed(let successful, let failed, let error) {
            printFailure(successful: successful, failed: failed, error: error, plan: plan)
            throw AutoError.alreadyReported
        }
    }

    // MARK: - Pass 1: Inventory

    static func getChangedFiles(stagedOnly: Bool) throws -> [FileChange] {
        let output = runGit(["status", "--porcelain", "-z"])
        guard !output.isEmpty else { return [] }

        var entries = output.split(separator: "\0", omittingEmptySubsequences: false)
        var changes: [FileChange] = []

        while !entries.isEmpty {
            let status = String(entries.removeFirst())
            guard !status.isEmpty else { continue }
            guard status.count >= 3 else { continue }

            let indexChar = status.first!
            let workTreeChar = status[status.index(after: status.startIndex)]
            let path = String(status.dropFirst(3))

            // Skip untracked files
            guard indexChar != "?" else { continue }

            let hasStaged = indexChar != " " && indexChar != "?"
            let hasUnstaged = workTreeChar != " " && workTreeChar != "?"

            if stagedOnly && !hasStaged { continue }
            if !stagedOnly && !hasStaged && !hasUnstaged { continue }

            // Handle renames
            let isRename = indexChar == "R" || workTreeChar == "R"
            if isRename && !entries.isEmpty {
                let newPath = path
                let oldPath = String(entries.removeFirst())
                changes.append(.renamed(old: oldPath, new: newPath))
            } else if indexChar == "A" {
                changes.append(.added(path: path))
            } else if indexChar == "D" || workTreeChar == "D" {
                changes.append(.deleted(path: path))
            } else {
                changes.append(.modified(path: path))
            }
        }

        return changes
    }

    // MARK: - Binary File Detection

    static func detectBinaryFiles(stagedOnly: Bool) -> Set<String> {
        let args = stagedOnly ? ["diff", "--numstat", "--cached"] : ["diff", "--numstat", "HEAD"]
        let output = runGit(args)

        var binaries: Set<String> = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            if parts[0] == "-" && parts[1] == "-" {
                binaries.insert(String(parts[2]))
            }
        }
        return binaries
    }

    // MARK: - Pass 2 & 3: Analyze Files

    static func analyzeFiles(_ files: [FileChange], stagedOnly: Bool, binaryFiles: Set<String>, verbose: Bool) async throws -> [String: FileSummary] {
        // Filter out binary files for LLM analysis
        let textFiles = files.filter { !binaryFiles.contains($0.path) }

        guard !textFiles.isEmpty else { return [:] }

        // Gather all diffs first
        let fileDiffs = gatherDiffs(for: textFiles, stagedOnly: stagedOnly)

        // Process files sequentially
        var results: [String: FileSummary] = [:]

        for (index, file) in textFiles.enumerated() {
            if verbose {
                print("  [\(index + 1)/\(textFiles.count)] \(file.path)...")
            }

            let diff = fileDiffs[file.path] ?? ""

            // Skip empty diffs
            guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                results[file.path] = fallbackSummary(for: file)
                if verbose {
                    print("    (empty diff, using fallback)")
                }
                continue
            }

            let truncatedDiff = truncateDiff(diff, maxLength: maxDiffPerFile)
            let prompt = "\(Prompts.fileSummary)\n\nFile: \(file.path)\nChange type: \(file.verb)\n\nDiff:\n\(truncatedDiff)"

            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let summary = try parseFileSummary(response.content)
                results[file.path] = summary
            } catch {
                // Retry once
                if verbose {
                    print("    (retrying...)")
                }
                do {
                    let retrySession = LanguageModelSession()
                    let response = try await retrySession.respond(to: prompt)
                    let summary = try parseFileSummary(response.content)
                    results[file.path] = summary
                } catch {
                    // Use fallback
                    results[file.path] = fallbackSummary(for: file)
                    if verbose {
                        print("    (using fallback due to parse error)")
                    }
                }
            }
        }

        return results
    }

    static func gatherDiffs(for files: [FileChange], stagedOnly: Bool) -> [String: String] {
        var diffs: [String: String] = [:]
        for file in files {
            diffs[file.path] = getDiff(for: file.path, stagedOnly: stagedOnly)
        }
        return diffs
    }

    static func getDiff(for path: String, stagedOnly: Bool) -> String {
        let args = stagedOnly ? ["diff", "--cached", "--", path] : ["diff", "HEAD", "--", path]
        return runGit(args)
    }

    static func truncateDiff(_ diff: String, maxLength: Int) -> String {
        guard diff.count > maxLength else { return diff }
        let truncated = String(diff.prefix(maxLength))
        return truncated + "\n\n[... diff truncated ...]"
    }

    static func fallbackSummary(for file: FileChange) -> FileSummary {
        let filename = (file.path as NSString).lastPathComponent
        let directory = (file.path as NSString).deletingLastPathComponent
        let scope = directory.isEmpty ? filename : (directory as NSString).lastPathComponent

        return FileSummary(
            summary: "\(file.verb) \(filename)",
            category: "chore",
            scope: scope
        )
    }

    // MARK: - JSON Parsing

    static func parseFileSummary(_ response: String) throws -> FileSummary {
        let cleaned = cleanJSON(response)
        guard let data = cleaned.data(using: .utf8) else {
            throw AutoError.parseError("Invalid UTF-8")
        }
        return try JSONDecoder().decode(FileSummary.self, from: data)
    }

    static func parseCommitPlan(_ response: String) throws -> CommitPlan {
        let cleaned = cleanJSON(response)
        guard let data = cleaned.data(using: .utf8) else {
            throw AutoError.parseError("Invalid UTF-8")
        }
        return try JSONDecoder().decode(CommitPlan.self, from: data)
    }

    static func cleanJSON(_ response: String) -> String {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks
        if json.hasPrefix("```json") {
            json = String(json.dropFirst(7))
        } else if json.hasPrefix("```") {
            json = String(json.dropFirst(3))
        }
        if json.hasSuffix("```") {
            json = String(json.dropLast(3))
        }

        return json.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pass 4: Create Commit Plan

    static func createCommitPlan(from summaries: [String: FileSummary], files: [FileChange], binaryFiles: Set<String>) async throws -> CommitPlan {
        // Handle binary files separately
        let binaryCommits = createBinaryFileCommits(files: files, binaryFiles: binaryFiles)

        // Single file shortcut
        if summaries.count == 1, let (path, summary) = summaries.first {
            let message = singleFileMessage(from: summary)
            return CommitPlan(commits: [CommitGroup(files: [path], message: message)] + binaryCommits)
        }

        // No text files to group
        if summaries.isEmpty {
            return CommitPlan(commits: binaryCommits)
        }

        // Group files via LLM
        let session = LanguageModelSession()
        let summaryText = formatSummaries(summaries)
        let prompt = "\(Prompts.grouping)\n\nFiles:\n\(summaryText)"

        let response = try await session.respond(to: prompt)
        var plan = try parseCommitPlan(response.content)

        // Validate plan only references files we analyzed
        let validPaths = Set(summaries.keys)
        for i in plan.commits.indices {
            plan.commits[i].files = plan.commits[i].files.filter { validPaths.contains($0) }
        }
        plan.commits.removeAll { $0.files.isEmpty }

        // Add binary file commits
        plan.commits.append(contentsOf: binaryCommits)

        return plan
    }

    static func singleFileMessage(from summary: FileSummary) -> String {
        let scopePart = summary.scope.isEmpty ? "" : "(\(summary.scope))"
        var description = summary.summary
        if let first = description.first, first.isUppercase {
            description = first.lowercased() + description.dropFirst()
        }
        return "\(summary.category)\(scopePart): \(description)"
    }

    static func formatSummaries(_ summaries: [String: FileSummary]) -> String {
        summaries.map { path, summary in
            "\(path): \(summary.summary) [\(summary.category)] (\(summary.scope))"
        }.joined(separator: "\n")
    }

    static func createBinaryFileCommits(files: [FileChange], binaryFiles: Set<String>) -> [CommitGroup] {
        let binaryChanges = files.filter { binaryFiles.contains($0.path) }
        guard !binaryChanges.isEmpty else { return [] }

        // Group by parent directory
        var byDirectory: [String: [String]] = [:]
        for file in binaryChanges {
            let dir = (file.path as NSString).deletingLastPathComponent
            let dirName = dir.isEmpty ? "root" : (dir as NSString).lastPathComponent
            byDirectory[dirName, default: []].append(file.path)
        }

        return byDirectory.map { dir, paths in
            CommitGroup(files: paths, message: "chore(\(dir)): update binary files")
        }
    }

    // MARK: - Pass 5: Execute Commits

    static func executeCommits(_ plan: CommitPlan, dryRun: Bool, verbose: Bool) throws -> AutoResult {
        var result = AutoResult()

        guard !dryRun else {
            return result
        }

        // Reset staging area to ensure clean slate
        // This prevents pre-staged files from being included in the first commit
        let hasHead = runGitWithResult(["rev-parse", "--verify", "HEAD"]).succeeded
        if verbose {
            print("Resetting staging area for clean commit groups...")
        }
        if hasHead {
            let resetResult = runGitWithResult(["reset", "HEAD"])
            if !resetResult.succeeded {
                let msg = resetResult.errorOutput.isEmpty ? "exit code \(resetResult.exitCode)" : resetResult.errorOutput
                throw AutoError.gitError(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            // Initial commit: no HEAD exists, use rm --cached to unstage
            let resetResult = runGitWithResult(["rm", "-r", "--cached", "."])
            if !resetResult.succeeded && resetResult.exitCode != 128 {
                // Exit code 128 means nothing to unstage, which is fine
                let msg = resetResult.errorOutput.isEmpty ? "exit code \(resetResult.exitCode)" : resetResult.errorOutput
                throw AutoError.gitError(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // Fail-fast: stop on first error
        for group in plan.commits {
            do {
                try stageAndCommit(group)
                result.successful.append(group)
            } catch {
                throw AutoError.commitFailed(
                    successful: result.successful,
                    failed: group,
                    error: error.localizedDescription
                )
            }
        }

        return result
    }

    static func stageAndCommit(_ group: CommitGroup) throws {
        // Stage files
        let stageArgs = ["add"] + group.files
        let stageResult = runGitWithResult(stageArgs)
        if !stageResult.succeeded {
            let msg = stageResult.errorOutput.isEmpty ? "exit code \(stageResult.exitCode)" : stageResult.errorOutput
            throw AutoError.gitError(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Commit
        let commitResult = runGitWithResult(["commit", "-m", group.message])
        if !commitResult.succeeded {
            let msg = commitResult.errorOutput.isEmpty ? "exit code \(commitResult.exitCode)" : commitResult.errorOutput
            throw AutoError.gitError(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Output

    static func printResults(_ result: AutoResult, dryRun: Bool, plan: CommitPlan) {
        print("")

        if dryRun {
            print("Planned commits (dry-run):")
            print("")
            for group in plan.commits {
                print("  \u{2022} \(group.message)")
                print("    \(group.files.joined(separator: ", "))")
                print("")
            }
            print("Run without --dry-run to commit.")
        } else {
            print("Creating \(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s"):")
            print("")

            for group in result.successful {
                print("  \u{2713} \(group.message)")
                print("    \(group.files.joined(separator: ", "))")
                print("")
            }

            let successCount = result.successful.count
            print("Done. \(successCount) commit\(successCount == 1 ? "" : "s") created.")
        }
    }

    static func printFailure(successful: [CommitGroup], failed: CommitGroup, error: String, plan: CommitPlan) {
        print("")
        print("Creating \(plan.commits.count) commit\(plan.commits.count == 1 ? "" : "s"):")
        print("")

        for group in successful {
            print("  \u{2713} \(group.message)")
            print("    \(group.files.joined(separator: ", "))")
            print("")
        }

        print("  \u{2717} \(failed.message)")
        print("    \(failed.files.joined(separator: ", "))")
        print("    Error: \(error)")
        print("")

        let remaining = plan.commits.count - successful.count - 1
        if remaining > 0 {
            print("  ... \(remaining) commit\(remaining == 1 ? "" : "s") skipped")
            print("")
        }

        print("Stopped. \(successful.count) commit\(successful.count == 1 ? "" : "s") created, 1 failed.")
    }

    // MARK: - Git Helpers

    static func runGit(_ args: [String]) -> String {
        runGitWithResult(args).output
    }

    static func runGitWithResult(_ args: [String]) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return GitResult(
                output: String(data: outData, encoding: .utf8) ?? "",
                errorOutput: String(data: errData, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        } catch {
            return GitResult(output: "", errorOutput: error.localizedDescription, exitCode: 1)
        }
    }
}
