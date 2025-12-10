import Foundation
import Logging

/// Implementation of PRUpdateUseCase protocol
/// Updates pull request branches with the latest base branch changes
final class PRUpdateUseCaseImpl: PRUpdateUseCase, Sendable {
    // MARK: - Properties

    private let githubGateway: GitHubGateway
    private let logger: Logger

    // MARK: - Initialization

    /// Initialize PR update use case
    /// - Parameters:
    ///   - githubGateway: Gateway for GitHub API interactions
    ///   - logger: Logger for structured logging
    init(githubGateway: GitHubGateway, logger: Logger) {
        self.githubGateway = githubGateway
        self.logger = logger
    }

    // MARK: - PRUpdateUseCase Protocol Implementation

    func updatePR(_ pullRequest: PullRequest) async throws -> PRUpdateResult {
        logger.info(
            "Updating pull request branch",
            metadata: [
                "pr": .stringConvertible(pullRequest.number),
                "repo": .string(pullRequest.repository.name),
                "baseBranch": .string(pullRequest.baseBranch.value),
                "headBranch": .string(pullRequest.headBranch.value)
            ]
        )

        // Check if PR is already up to date
        if pullRequest.isUpToDate && !pullRequest.isConflicted {
            logger.info(
                "Pull request is already up to date",
                metadata: ["pr": .stringConvertible(pullRequest.number)]
            )
            return .alreadyUpToDate
        }

        do {
            // Update the PR branch with the latest base branch
            let updateResult = try await githubGateway.updatePullRequestBranch(
                owner: pullRequest.repository.owner,
                repo: pullRequest.repository.name,
                number: pullRequest.number
            )

            logger.info(
                "Successfully updated pull request branch",
                metadata: [
                    "pr": .stringConvertible(pullRequest.number),
                    "message": .string(updateResult.message),
                    "newHeadSHA": .string(updateResult.headSHA)
                ]
            )

            // Return success with the new HEAD SHA
            return .updated(newHeadSHA: updateResult.headSHA)
        } catch let error as GitHubAPIError {
            logger.error(
                "GitHub API error while updating pull request",
                metadata: [
                    "pr": .stringConvertible(pullRequest.number),
                    "error": .string(error.localizedDescription)
                ]
            )
            return .failed(error)
        } catch {
            logger.error(
                "Failed to update pull request branch",
                metadata: [
                    "pr": .stringConvertible(pullRequest.number),
                    "error": .string(error.localizedDescription)
                ]
            )
            return .failed(error)
        }
    }
}
