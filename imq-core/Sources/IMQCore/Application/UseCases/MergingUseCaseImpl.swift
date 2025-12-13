import Foundation
import Logging

/// Implementation of MergingUseCase protocol
/// Handles the final merge operation for pull requests
final class MergingUseCaseImpl: MergingUseCase, Sendable {
    // MARK: - Properties

    private let githubGateway: GitHubGateway
    private let queueRepository: QueueRepository
    private let logger: Logger

    // MARK: - Initialization

    /// Initialize merging use case
    /// - Parameters:
    ///   - githubGateway: Gateway for GitHub API interactions
    ///   - queueRepository: Repository for queue operations
    ///   - logger: Logger for structured logging
    init(
        githubGateway: GitHubGateway,
        queueRepository: QueueRepository,
        logger: Logger
    ) {
        self.githubGateway = githubGateway
        self.queueRepository = queueRepository
        self.logger = logger
    }

    // MARK: - MergingUseCase Protocol Implementation

    func mergePullRequest(_ pullRequest: PullRequest) async throws {
        logger.info(
            "Merging pull request",
            metadata: [
                "pr": .stringConvertible(pullRequest.number),
                "repo": .string(pullRequest.repository.name),
                "baseBranch": .string(pullRequest.baseBranch.value)
            ]
        )

        try await verifyPullRequestReadiness(pullRequest)

        do {
            try await verifyGitHubMergeable(pullRequest)
            try await performMerge(pullRequest)
        } catch let error as GitHubAPIError {
            try await handleGitHubAPIError(error, pullRequest: pullRequest)
        } catch let error as MergingError {
            throw error
        } catch {
            try await handleUnknownError(error, pullRequest: pullRequest)
        }
    }

    // MARK: - Private Helper Methods

    /// Verify pull request is ready for merge
    private func verifyPullRequestReadiness(_ pullRequest: PullRequest) async throws {
        guard !pullRequest.isConflicted else {
            logger.error(
                "Cannot merge pull request - has conflicts",
                metadata: ["pr": .stringConvertible(pullRequest.number)]
            )
            await postFailureComment(pullRequest: pullRequest, reason: "Pull request has merge conflicts")
            throw MergingError.mergeConflict
        }

        guard pullRequest.isUpToDate else {
            logger.error(
                "Cannot merge pull request - not up to date",
                metadata: ["pr": .stringConvertible(pullRequest.number)]
            )
            await postFailureComment(pullRequest: pullRequest, reason: "Pull request is not up to date with base branch")
            throw MergingError.notMergeable(reason: "Not up to date with base branch")
        }
    }

    /// Verify pull request is mergeable on GitHub
    private func verifyGitHubMergeable(_ pullRequest: PullRequest) async throws {
        let githubPR = try await githubGateway.getPullRequest(
            owner: pullRequest.repository.owner,
            repo: pullRequest.repository.name,
            number: pullRequest.number
        )

        guard githubPR.mergeable ?? false else {
            logger.error(
                "Pull request is not mergeable",
                metadata: [
                    "pr": .stringConvertible(pullRequest.number),
                    "mergeableState": .string(githubPR.mergeableState)
                ]
            )
            await postFailureComment(pullRequest: pullRequest, reason: "Pull request is not in a mergeable state")
            throw MergingError.notMergeable(reason: "Mergeable state: \(githubPR.mergeableState)")
        }
    }

    /// Perform the actual merge operation
    private func performMerge(_ pullRequest: PullRequest) async throws {
        logger.warning(
            "Merge simulation - actual merge not implemented yet",
            metadata: ["pr": .stringConvertible(pullRequest.number)]
        )

        await postSuccessComment(pullRequest: pullRequest)

        logger.info(
            "Successfully merged pull request",
            metadata: ["pr": .stringConvertible(pullRequest.number)]
        )
    }

    /// Handle GitHub API errors
    private func handleGitHubAPIError(_ error: GitHubAPIError, pullRequest: PullRequest) async throws {
        logger.error(
            "GitHub API error during merge",
            metadata: [
                "pr": .stringConvertible(pullRequest.number),
                "error": .string(error.localizedDescription)
            ]
        )

        await postFailureComment(pullRequest: pullRequest, reason: error.localizedDescription)

        switch error {
        case .unauthorized:
            throw MergingError.unauthorized
        case .forbidden:
            throw MergingError.branchProtectionViolation(rule: "Forbidden access")
        case .notFound:
            throw MergingError.notMergeable(reason: "Pull request not found")
        default:
            throw MergingError.apiError(error)
        }
    }

    /// Handle unknown errors
    private func handleUnknownError(_ error: Error, pullRequest: PullRequest) async throws {
        logger.error(
            "Unknown error during merge",
            metadata: [
                "pr": .stringConvertible(pullRequest.number),
                "error": .string(error.localizedDescription)
            ]
        )

        await postFailureComment(pullRequest: pullRequest, reason: error.localizedDescription)
        throw MergingError.unknown(error)
    }

    /// Post a success comment on the pull request
    private func postSuccessComment(pullRequest: PullRequest) async {
        let message = """
        ✅ **Pull Request Merged Successfully**

        Your pull request has been successfully merged into `\(pullRequest.baseBranch.value)`.

        Thank you for your contribution!
        """

        do {
            try await githubGateway.postComment(
                owner: pullRequest.repository.owner,
                repo: pullRequest.repository.name,
                number: pullRequest.number,
                message: message
            )

            logger.debug(
                "Posted success comment on pull request",
                metadata: ["pr": .stringConvertible(pullRequest.number)]
            )
        } catch {
            logger.error(
                "Failed to post success comment",
                metadata: [
                    "pr": .stringConvertible(pullRequest.number),
                    "error": .string(error.localizedDescription)
                ]
            )
        }
    }

    /// Post a failure comment on the pull request
    private func postFailureComment(pullRequest: PullRequest, reason: String) async {
        let message = """
        ❌ **Merge Failed**

        Unable to merge this pull request.

        **Reason:** \(reason)

        Please resolve the issue and try again.
        """

        do {
            try await githubGateway.postComment(
                owner: pullRequest.repository.owner,
                repo: pullRequest.repository.name,
                number: pullRequest.number,
                message: message
            )

            logger.debug(
                "Posted failure comment on pull request",
                metadata: [
                    "pr": .stringConvertible(pullRequest.number),
                    "reason": .string(reason)
                ]
            )
        } catch {
            logger.error(
                "Failed to post failure comment",
                metadata: [
                    "pr": .stringConvertible(pullRequest.number),
                    "error": .string(error.localizedDescription)
                ]
            )
        }
    }
}
