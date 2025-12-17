import Foundation
import Vapor
import IMQCore
import Logging

/// Service for executing checks on pull requests
public actor CheckExecutionService {
    // MARK: - Properties

    private let githubGateway: IMQCore.GitHubGateway
    private let logger: Logger

    // MARK: - Initialization

    init(githubGateway: IMQCore.GitHubGateway, logger: Logger) {
        self.githubGateway = githubGateway
        self.logger = logger
    }

    // MARK: - Public Methods

    /// Execute all configured checks for a pull request
    /// - Parameters:
    ///   - owner: Repository owner
    ///   - repo: Repository name
    ///   - prNumber: Pull request number
    ///   - headSHA: Head commit SHA
    ///   - checkConfigurations: JSON string of check configurations
    /// - Returns: True if all checks pass, false otherwise
    public func executeChecks(
        owner: String,
        repo: String,
        prNumber: Int,
        headSHA: String,
        checkConfigurations: String
    ) async throws -> Bool {
        logger.info("Executing checks for PR", metadata: [
            "owner": .string(owner),
            "repo": .string(repo),
            "prNumber": .stringConvertible(prNumber),
            "headSHA": .string(headSHA)
        ])

        // Parse check configurations
        guard let data = checkConfigurations.data(using: .utf8),
              let checksArray = try? JSONDecoder().decode([CheckConfiguration].self, from: data) else {
            logger.warning("Invalid or empty check configurations, skipping checks")
            return true // No checks configured, pass by default
        }

        guard !checksArray.isEmpty else {
            logger.info("No checks configured, passing by default")
            return true
        }

        // Execute each check
        var allPassed = true

        for checkConfig in checksArray {
            let passed = try await executeCheck(
                config: checkConfig,
                owner: owner,
                repo: repo,
                prNumber: prNumber,
                headSHA: headSHA
            )

            if !passed {
                allPassed = false
                logger.warning("Check failed", metadata: [
                    "checkName": .string(checkConfig.name),
                    "checkType": .string(checkConfig.type)
                ])
            }
        }

        logger.info("All checks completed", metadata: [
            "passed": .stringConvertible(allPassed)
        ])

        return allPassed
    }

    // MARK: - Private Methods

    /// Execute a single check
    private func executeCheck(
        config: CheckConfiguration,
        owner: String,
        repo: String,
        prNumber: Int,
        headSHA: String
    ) async throws -> Bool {
        logger.info("Executing check", metadata: [
            "name": .string(config.name),
            "type": .string(config.type)
        ])

        switch config.type.lowercased() {
        case "github_actions":
            return try await executeGitHubActionsCheck(
                config: config,
                owner: owner,
                repo: repo,
                prNumber: prNumber,
                headSHA: headSHA
            )

        case "github_status":
            return try await checkGitHubStatus(
                config: config,
                owner: owner,
                repo: repo,
                prNumber: prNumber,
                headSHA: headSHA
            )

        case "mergeable":
            return try await checkMergeable(
                owner: owner,
                repo: repo,
                prNumber: prNumber
            )

        default:
            logger.warning("Unknown check type", metadata: ["type": .string(config.type)])
            return true // Unknown check type, pass by default
        }
    }

    /// Execute GitHub Actions workflow check
    private func executeGitHubActionsCheck(
        config: CheckConfiguration,
        owner: String,
        repo: String,
        prNumber: Int,
        headSHA: String
    ) async throws -> Bool {
        guard let workflowName = config.workflowName else {
            logger.error("GitHub Actions check missing workflowName")
            return false
        }

        logger.info("Triggering GitHub Actions workflow", metadata: [
            "workflow": .string(workflowName),
            "ref": .string(headSHA)
        ])

        // Trigger workflow
        let workflowRun = try await githubGateway.triggerWorkflow(
            owner: owner,
            repo: repo,
            workflowName: workflowName,
            ref: headSHA,
            inputs: [:]
        )

        // Poll for workflow completion
        let maxAttempts = 60 // 10 minutes max (10 seconds * 60)
        var attempts = 0

        while attempts < maxAttempts {
            let run = try await githubGateway.getWorkflowRun(
                owner: owner,
                repo: repo,
                runID: workflowRun.id
            )

            logger.debug("Workflow status", metadata: [
                "runID": .stringConvertible(run.id),
                "status": .string(run.status),
                "conclusion": .string(run.conclusion ?? "null")
            ])

            // Check if completed
            if run.status == "completed" {
                if let conclusion = run.conclusion {
                    let success = conclusion == "success"
                    logger.info("Workflow completed", metadata: [
                        "conclusion": .string(conclusion),
                        "passed": .stringConvertible(success)
                    ])
                    return success
                }
            }

            // Wait before next poll
            try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            attempts += 1
        }

        logger.error("Workflow did not complete within timeout")
        return false
    }

    /// Check GitHub status checks
    private func checkGitHubStatus(
        config: CheckConfiguration,
        owner: String,
        repo: String,
        prNumber: Int,
        headSHA: String
    ) async throws -> Bool {
        // Get PR details which includes status checks
        let pr = try await githubGateway.getPullRequest(
            owner: owner,
            repo: repo,
            number: prNumber
        )

        // Check mergeable state
        let mergeableState = pr.mergeableState.lowercased()

        logger.info("PR mergeable state", metadata: [
            "state": .string(mergeableState)
        ])

        // Consider these states as passing
        let passingStates = ["clean", "unstable", "has_hooks"]

        return passingStates.contains(mergeableState)
    }

    /// Check if PR is mergeable
    private func checkMergeable(
        owner: String,
        repo: String,
        prNumber: Int
    ) async throws -> Bool {
        let pr = try await githubGateway.getPullRequest(
            owner: owner,
            repo: repo,
            number: prNumber
        )

        let mergeable = pr.mergeable ?? false
        let mergeableState = pr.mergeableState.lowercased()

        logger.info("Mergeable check", metadata: [
            "mergeable": .stringConvertible(mergeable),
            "mergeableState": .string(mergeableState)
        ])

        // PR must be mergeable and not in a blocking state
        let blockingStates = ["dirty", "blocked"]

        return mergeable && !blockingStates.contains(mergeableState)
    }
}

// MARK: - Check Configuration Models

/// Configuration for a single check
struct CheckConfiguration: Codable {
    let name: String
    let type: String
    let workflowName: String?
    let timeout: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case type
        case workflowName = "workflow_name"
        case timeout
    }
}
