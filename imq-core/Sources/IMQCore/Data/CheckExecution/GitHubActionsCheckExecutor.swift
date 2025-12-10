import Foundation
import Logging

/// Executor for GitHub Actions workflow-based checks
///
/// Triggers GitHub Actions workflows and polls for completion with:
/// - Workflow dispatch triggering
/// - Adaptive polling intervals (increases after initial attempts)
/// - Timeout handling
/// - Status and conclusion interpretation
/// - Structured logging
///
/// Polling strategy:
/// - Initial interval: 10 seconds
/// - After 10 attempts: 20 seconds (adaptive)
/// - Maximum attempts: 60 (configurable)
final class GitHubActionsCheckExecutor: CheckExecutor {
    private let githubGateway: GitHubGateway
    private let logger: Logger

    // Polling configuration
    private let pollingInterval: TimeInterval
    private let maxPollingAttempts: Int

    /// Initialize GitHub Actions executor
    ///
    /// - Parameters:
    ///   - githubGateway: Gateway for GitHub API interactions
    ///   - pollingInterval: Initial interval between polling attempts (default: 10 seconds)
    ///   - maxPollingAttempts: Maximum number of polling attempts (default: 60)
    ///   - logger: Logger for structured logging
    init(
        githubGateway: GitHubGateway,
        pollingInterval: TimeInterval = 10,
        maxPollingAttempts: Int = 60,
        logger: Logger
    ) {
        self.githubGateway = githubGateway
        self.pollingInterval = pollingInterval
        self.maxPollingAttempts = maxPollingAttempts
        self.logger = logger
    }

    func execute(check: Check, for pullRequest: PullRequest) async throws -> CheckResult {
        // Extract GitHub Actions configuration
        guard case .githubActions(let workflowName, let jobName) = check.configuration else {
            throw CheckExecutionError.invalidConfiguration(
                "Expected GitHub Actions configuration, got: \(check.configuration)"
            )
        }

        let startTime = Date()

        logger.info("Triggering GitHub Actions workflow",
                   metadata: [
                       "check": "\(check.name)",
                       "workflow": "\(workflowName)",
                       "job": "\(jobName ?? "all")",
                       "repo": "\(pullRequest.repository.fullName)",
                       "pr": "\(pullRequest.number)",
                       "sha": "\(pullRequest.headSHA.value)"
                   ])

        // Step 1: Trigger workflow
        let workflowRun = try await triggerWorkflow(
            workflowName: workflowName,
            pullRequest: pullRequest
        )

        logger.debug("Workflow triggered",
                    metadata: [
                        "runID": "\(workflowRun.id)",
                        "status": "\(workflowRun.status)"
                    ])

        // Step 2: Poll for completion with timeout
        let finalRun: WorkflowRun
        if let timeout = check.timeout {
            finalRun = try await pollForCompletionWithTimeout(
                runID: workflowRun.id,
                repository: pullRequest.repository,
                timeout: timeout
            )
        } else {
            finalRun = try await pollForCompletion(
                runID: workflowRun.id,
                repository: pullRequest.repository
            )
        }

        let completionTime = Date()
        let duration = completionTime.timeIntervalSince(startTime)

        // Step 3: Interpret result
        let (status, output) = interpretWorkflowResult(
            conclusion: finalRun.conclusion,
            jobName: jobName
        )

        logger.info("GitHub Actions check complete",
                   metadata: [
                       "check": "\(check.name)",
                       "status": "\(status)",
                       "conclusion": "\(finalRun.conclusion ?? "none")",
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

    /// Trigger GitHub Actions workflow
    ///
    /// - Parameters:
    ///   - workflowName: Name of the workflow file
    ///   - pullRequest: Pull request context
    /// - Returns: Triggered workflow run
    /// - Throws: CheckExecutionError if triggering fails
    private func triggerWorkflow(
        workflowName: String,
        pullRequest: PullRequest
    ) async throws -> WorkflowRun {
        do {
            return try await githubGateway.triggerWorkflow(
                owner: pullRequest.repository.owner,
                repo: pullRequest.repository.name,
                workflowName: workflowName,
                ref: pullRequest.headBranch.value,
                inputs: [
                    "pr_number": "\(pullRequest.number)",
                    "sha": pullRequest.headSHA.value
                ]
            )
        } catch {
            logger.error("Failed to trigger workflow",
                        metadata: [
                            "workflow": "\(workflowName)",
                            "error": "\(error.localizedDescription)"
                        ])
            throw CheckExecutionError.githubAPIError(
                "Failed to trigger workflow: \(error.localizedDescription)"
            )
        }
    }

    /// Poll for workflow completion without timeout
    ///
    /// - Parameters:
    ///   - runID: Workflow run ID
    ///   - repository: Repository context
    /// - Returns: Completed workflow run
    /// - Throws: CheckExecutionError if polling fails or times out
    private func pollForCompletion(
        runID: Int,
        repository: Repository
    ) async throws -> WorkflowRun {
        var attempts = 0

        while attempts < maxPollingAttempts {
            attempts += 1

            let run = try await fetchWorkflowRun(
                runID: runID,
                repository: repository,
                attempt: attempts
            )

            // Check if workflow is complete
            if run.status == "completed" {
                return run
            }

            // Adaptive polling: increase interval after 10 attempts
            let interval = attempts > 10 ? pollingInterval * 2 : pollingInterval
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        logger.error("Workflow polling timed out",
                    metadata: [
                        "runID": "\(runID)",
                        "attempts": "\(attempts)"
                    ])
        throw CheckExecutionError.pollingTimeout(
            "Workflow did not complete after \(attempts) attempts"
        )
    }

    /// Poll for workflow completion with timeout
    ///
    /// - Parameters:
    ///   - runID: Workflow run ID
    ///   - repository: Repository context
    ///   - timeout: Maximum time to wait in seconds
    /// - Returns: Completed workflow run
    /// - Throws: CheckExecutionError if polling fails or times out
    private func pollForCompletionWithTimeout(
        runID: Int,
        repository: Repository,
        timeout: TimeInterval
    ) async throws -> WorkflowRun {
        try await withThrowingTaskGroup(of: WorkflowRun.self) { group in
            // Task 1: Poll for completion
            group.addTask {
                try await self.pollForCompletion(runID: runID, repository: repository)
            }

            // Task 2: Timeout
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CheckExecutionError.pollingTimeout(
                    "Workflow polling timed out after \(timeout) seconds"
                )
            }

            // Return first result (either completion or timeout)
            guard let result = try await group.next() else {
                throw CheckExecutionError.pollingTimeout("Polling failed")
            }

            // Cancel remaining tasks
            group.cancelAll()
            return result
        }
    }

    /// Fetch workflow run status from GitHub
    ///
    /// - Parameters:
    ///   - runID: Workflow run ID
    ///   - repository: Repository context
    ///   - attempt: Current polling attempt number
    /// - Returns: Current workflow run state
    /// - Throws: CheckExecutionError if fetching fails
    private func fetchWorkflowRun(
        runID: Int,
        repository: Repository,
        attempt: Int
    ) async throws -> WorkflowRun {
        do {
            let run = try await githubGateway.getWorkflowRun(
                owner: repository.owner,
                repo: repository.name,
                runID: runID
            )

            logger.debug("Polling workflow run",
                        metadata: [
                            "runID": "\(runID)",
                            "status": "\(run.status)",
                            "attempt": "\(attempt)/\(maxPollingAttempts)"
                        ])

            return run
        } catch {
            logger.error("Failed to fetch workflow run",
                        metadata: [
                            "runID": "\(runID)",
                            "error": "\(error.localizedDescription)"
                        ])
            throw CheckExecutionError.githubAPIError(
                "Failed to fetch workflow run: \(error.localizedDescription)"
            )
        }
    }

    /// Interpret workflow run conclusion into check status
    ///
    /// - Parameters:
    ///   - conclusion: Workflow conclusion from GitHub
    ///   - jobName: Optional specific job name to mention
    /// - Returns: Tuple of check status and output message
    private func interpretWorkflowResult(
        conclusion: String?,
        jobName: String?
    ) -> (CheckStatus, String) {
        let jobDescription = jobName.map { " (job: \($0))" } ?? ""

        switch conclusion {
        case "success":
            return (.passed, "Workflow completed successfully\(jobDescription)")

        case "failure":
            return (.failed, "Workflow failed\(jobDescription)")

        case "cancelled":
            return (.cancelled, "Workflow was cancelled\(jobDescription)")

        case "timed_out":
            return (.timedOut, "Workflow timed out\(jobDescription)")

        case "action_required":
            return (.failed, "Workflow requires action\(jobDescription)")

        case "skipped":
            return (.cancelled, "Workflow was skipped\(jobDescription)")

        case "neutral":
            return (.passed, "Workflow completed with neutral status\(jobDescription)")

        default:
            let conclusionText = conclusion ?? "unknown"
            return (.failed, "Workflow completed with conclusion: \(conclusionText)\(jobDescription)")
        }
    }
}
