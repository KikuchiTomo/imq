import Foundation

/// Use case for executing checks on pull requests
/// Handles parallel execution of multiple checks with caching and timeout support
protocol CheckExecutionUseCase: Sendable {
    /// Execute all checks for a pull request
    /// - Parameters:
    ///   - pullRequest: The pull request to execute checks on
    ///   - configuration: Check configuration specifying which checks to run
    /// - Returns: Check execution result containing individual check results
    /// - Throws: Error if check execution fails
    func executeChecks(
        for pullRequest: PullRequest,
        configuration: CheckConfiguration
    ) async throws -> CheckExecutionResult
}

// MARK: - Result Types

/// Result of check execution containing all check results
public struct CheckExecutionResult: Sendable {
    /// Individual check results
    public let results: [CheckResult]

    /// Whether all checks passed
    public let allPassed: Bool

    /// Names of checks that failed
    public let failedChecks: [String]

    /// Create a new check execution result
    /// - Parameters:
    ///   - results: Individual check results
    ///   - allPassed: Whether all checks passed
    ///   - failedChecks: Names of checks that failed
    public init(
        results: [CheckResult],
        allPassed: Bool,
        failedChecks: [String]
    ) {
        self.results = results
        self.allPassed = allPassed
        self.failedChecks = failedChecks
    }

    /// Total number of checks executed
    public var totalChecks: Int {
        results.count
    }

    /// Number of checks that passed
    public var passedCount: Int {
        results.filter { $0.status == .passed }.count
    }

    /// Number of checks that failed
    public var failedCount: Int {
        failedChecks.count
    }
}

/// Result of a single check execution
public struct CheckResult: Sendable {
    /// The check that was executed
    public let check: Check

    /// Final status of the check
    public let status: CheckStatus

    /// Output from the check execution (optional)
    public let output: String?

    /// When the check started
    public let startedAt: Date

    /// When the check completed
    public let completedAt: Date

    /// Duration of check execution in seconds
    public let duration: TimeInterval

    /// Create a new check result
    /// - Parameters:
    ///   - check: The check that was executed
    ///   - status: Final status of the check
    ///   - output: Output from the check execution
    ///   - startedAt: When the check started
    ///   - completedAt: When the check completed
    ///   - duration: Duration of check execution in seconds
    public init(
        check: Check,
        status: CheckStatus,
        output: String?,
        startedAt: Date,
        completedAt: Date,
        duration: TimeInterval
    ) {
        self.check = check
        self.status = status
        self.output = output
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.duration = duration
    }

    /// Whether the check passed
    public var success: Bool {
        status == .passed
    }
}

// MARK: - Additional Configuration Types
//
// Note: Check, CheckConfiguration, CheckType, and CheckTypeConfiguration
// are now defined in Domain/Entities/Check.swift

/// Configuration for GitHub Actions checks
public struct GitHubActionsConfig: Sendable {
    /// Name of the workflow file (e.g., "ci.yml")
    public let workflowName: String

    /// Optional specific job name to check
    public let jobName: String?

    /// Git reference to run the workflow on (optional, defaults to PR head)
    public let ref: String?

    /// Create a new GitHub Actions configuration
    /// - Parameters:
    ///   - workflowName: Name of the workflow file
    ///   - jobName: Optional specific job name to check
    ///   - ref: Git reference to run the workflow on
    public init(
        workflowName: String,
        jobName: String? = nil,
        ref: String? = nil
    ) {
        self.workflowName = workflowName
        self.jobName = jobName
        self.ref = ref
    }
}

/// Configuration for local script checks
public struct LocalScriptConfig: Sendable {
    /// Path to the script executable
    public let scriptPath: String

    /// Command line arguments for the script
    public let arguments: [String]

    /// Environment variables for the script
    public let environment: [String: String]

    /// Create a new local script configuration
    /// - Parameters:
    ///   - scriptPath: Path to the script executable
    ///   - arguments: Command line arguments for the script
    ///   - environment: Environment variables for the script
    public init(
        scriptPath: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.scriptPath = scriptPath
        self.arguments = arguments
        self.environment = environment
    }
}
