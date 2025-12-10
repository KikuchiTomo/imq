import Foundation
import Logging

/// Implementation of ConflictDetectionUseCase protocol
/// Detects merge conflicts by comparing pull request head with base branch
final class ConflictDetectionUseCaseImpl: ConflictDetectionUseCase, Sendable {
    // MARK: - Properties

    private let githubGateway: GitHubGateway
    private let logger: Logger

    // MARK: - Initialization

    /// Initialize conflict detection use case
    /// - Parameters:
    ///   - githubGateway: Gateway for GitHub API interactions
    ///   - logger: Logger for structured logging
    init(githubGateway: GitHubGateway, logger: Logger) {
        self.githubGateway = githubGateway
        self.logger = logger
    }

    // MARK: - ConflictDetectionUseCase Protocol Implementation

    func detectConflicts(for pullRequest: PullRequest) async throws -> ConflictResult {
        logger.debug(
            "Detecting conflicts for pull request",
            metadata: [
                "pr": .stringConvertible(pullRequest.number),
                "repo": .string(pullRequest.repository.name),
                "baseBranch": .string(pullRequest.baseBranch.value),
                "headSHA": .string(pullRequest.headSHA.value)
            ]
        )

        do {
            // Compare the PR head with base branch to detect conflicts
            let comparison = try await githubGateway.compareCommits(
                owner: pullRequest.repository.owner,
                repo: pullRequest.repository.name,
                base: pullRequest.baseBranch.value,
                head: pullRequest.headSHA.value
            )

            // Determine conflict status based on comparison result
            let hasConflict = comparison.status == "diverged" || pullRequest.isConflicted

            if hasConflict {
                logger.info(
                    "Pull request has conflicts",
                    metadata: [
                        "pr": .stringConvertible(pullRequest.number),
                        "status": .string(comparison.status)
                    ]
                )
                return .hasConflict
            } else {
                logger.info(
                    "Pull request has no conflicts",
                    metadata: [
                        "pr": .stringConvertible(pullRequest.number),
                        "status": .string(comparison.status)
                    ]
                )
                return .noConflict
            }
        } catch {
            logger.error(
                "Failed to detect conflicts",
                metadata: [
                    "pr": .stringConvertible(pullRequest.number),
                    "error": .string(error.localizedDescription)
                ]
            )
            return .unknown(error)
        }
    }
}
