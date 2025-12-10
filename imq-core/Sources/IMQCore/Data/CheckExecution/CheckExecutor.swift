import Foundation

/// Protocol for executing checks on pull requests
///
/// Different executor implementations handle different check types:
/// - GitHubActionsCheckExecutor: Triggers GitHub Actions workflows
/// - LocalScriptCheckExecutor: Executes local scripts
///
/// All executors support timeout handling, cancellation, and structured error reporting.
protocol CheckExecutor: Sendable {
    /// Execute a check for a pull request
    ///
    /// - Parameters:
    ///   - check: The check to execute
    ///   - pullRequest: The pull request context
    /// - Returns: Result of the check execution including status, output, and timing
    /// - Throws: CheckExecutionError if execution fails
    func execute(check: Check, for pullRequest: PullRequest) async throws -> CheckResult
}

// MARK: - Error Types

/// Errors that can occur during check execution
enum CheckExecutionError: Error, LocalizedError {
    /// Check configuration is invalid or incompatible with executor
    case invalidConfiguration(String)

    /// Script file not found at the specified path
    case scriptNotFound(String)

    /// Script exists but is not executable
    case scriptNotExecutable(String)

    /// Polling for workflow completion timed out
    case pollingTimeout(String)

    /// Process execution failed
    case processExecutionFailed(String)

    /// GitHub API error during workflow execution
    case githubAPIError(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid check configuration: \(message)"
        case .scriptNotFound(let path):
            return "Script not found: \(path)"
        case .scriptNotExecutable(let path):
            return "Script is not executable: \(path)"
        case .pollingTimeout(let message):
            return "Polling timeout: \(message)"
        case .processExecutionFailed(let message):
            return "Process execution failed: \(message)"
        case .githubAPIError(let message):
            return "GitHub API error: \(message)"
        }
    }
}
