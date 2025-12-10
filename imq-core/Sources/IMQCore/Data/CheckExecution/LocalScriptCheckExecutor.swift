import Foundation
import Logging

/// Executor for local script-based checks
///
/// Executes local scripts with:
/// - Script validation (existence and executability)
/// - Environment variable injection (PR context)
/// - Timeout handling
/// - Exit code interpretation
/// - Output capture (stdout/stderr)
///
/// Environment variables provided to scripts:
/// - IMQ_PR_NUMBER: Pull request number
/// - IMQ_PR_SHA: Head commit SHA
/// - IMQ_PR_BASE_BRANCH: Base branch name
/// - IMQ_PR_HEAD_BRANCH: Head branch name
/// - IMQ_REPO_OWNER: Repository owner
/// - IMQ_REPO_NAME: Repository name
final class LocalScriptCheckExecutor: CheckExecutor {
    private let processExecutor: ProcessExecutor
    private let logger: Logger

    /// Initialize local script executor
    ///
    /// - Parameters:
    ///   - processExecutor: Process executor for running scripts (defaults to new instance)
    ///   - logger: Logger for structured logging
    init(
        processExecutor: ProcessExecutor = ProcessExecutor(),
        logger: Logger
    ) {
        self.processExecutor = processExecutor
        self.logger = logger
    }

    func execute(check: Check, for pullRequest: PullRequest) async throws -> CheckResult {
        // Extract local script configuration
        guard case .localScript(let scriptPath, let arguments) = check.configuration else {
            throw CheckExecutionError.invalidConfiguration(
                "Expected local script configuration, got: \(check.configuration)"
            )
        }

        let startTime = Date()

        logger.info("Executing local script",
                   metadata: [
                       "check": "\(check.name)",
                       "script": "\(scriptPath)",
                       "args": "\(arguments.joined(separator: " "))",
                       "pr": "\(pullRequest.number)",
                       "repo": "\(pullRequest.repository.fullName)"
                   ])

        // Validate script exists and is executable
        try validateScript(path: scriptPath)

        // Prepare environment with PR context
        let environment = prepareEnvironment(
            for: pullRequest,
            baseEnvironment: [:]
        )

        // Execute script with timeout
        let timeout = check.timeout ?? 600 // Default 10 minutes
        let result = try await processExecutor.execute(
            path: scriptPath,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )

        let completionTime = Date()
        let duration = completionTime.timeIntervalSince(startTime)

        // Determine status from exit code
        let status: CheckStatus = result.exitCode == 0 ? .passed : .failed

        // Format output with exit code and streams
        let output = formatOutput(result: result)

        logger.info("Local script execution complete",
                   metadata: [
                       "check": "\(check.name)",
                       "status": "\(status)",
                       "exitCode": "\(result.exitCode)",
                       "duration": "\(String(format: "%.2f", duration))s"
                   ])

        return CheckResult(
            check: check,
            status: status,
            output: output,
            startedAt: startTime,
            completedAt: completionTime,
            duration: duration
        )
    }

    // MARK: - Private Methods

    /// Validate that script exists and is executable
    ///
    /// - Parameter path: Path to the script
    /// - Throws: CheckExecutionError if validation fails
    private func validateScript(path: String) throws {
        let fileManager = FileManager.default

        // Check if script exists
        guard fileManager.fileExists(atPath: path) else {
            logger.error("Script not found", metadata: ["path": "\(path)"])
            throw CheckExecutionError.scriptNotFound(path)
        }

        // Check if script is executable
        guard fileManager.isExecutableFile(atPath: path) else {
            logger.error("Script is not executable", metadata: ["path": "\(path)"])
            throw CheckExecutionError.scriptNotExecutable(path)
        }

        logger.debug("Script validated successfully", metadata: ["path": "\(path)"])
    }

    /// Prepare environment variables for script execution
    ///
    /// Injects IMQ-specific variables with pull request context:
    /// - IMQ_PR_NUMBER: Pull request number
    /// - IMQ_PR_SHA: Head commit SHA
    /// - IMQ_PR_BASE_BRANCH: Base branch name
    /// - IMQ_PR_HEAD_BRANCH: Head branch name
    /// - IMQ_REPO_OWNER: Repository owner
    /// - IMQ_REPO_NAME: Repository name
    ///
    /// - Parameters:
    ///   - pullRequest: Pull request context
    ///   - baseEnvironment: Additional environment variables from configuration
    /// - Returns: Complete environment dictionary
    private func prepareEnvironment(
        for pullRequest: PullRequest,
        baseEnvironment: [String: String]
    ) -> [String: String] {
        var environment = baseEnvironment

        // Inject PR context
        environment["IMQ_PR_NUMBER"] = "\(pullRequest.number)"
        environment["IMQ_PR_SHA"] = pullRequest.headSHA.value
        environment["IMQ_PR_BASE_BRANCH"] = pullRequest.baseBranch.value
        environment["IMQ_PR_HEAD_BRANCH"] = pullRequest.headBranch.value
        environment["IMQ_REPO_OWNER"] = pullRequest.repository.owner
        environment["IMQ_REPO_NAME"] = pullRequest.repository.name

        return environment
    }

    /// Format process result into human-readable output
    ///
    /// - Parameter result: Process execution result
    /// - Returns: Formatted output string
    private func formatOutput(result: ProcessResult) -> String {
        var output = "Exit Code: \(result.exitCode)\n"

        if !result.stdout.isEmpty {
            output += "\nSTDOUT:\n\(result.stdout)"
        }

        if !result.stderr.isEmpty {
            output += "\nSTDERR:\n\(result.stderr)"
        }

        return output
    }
}
