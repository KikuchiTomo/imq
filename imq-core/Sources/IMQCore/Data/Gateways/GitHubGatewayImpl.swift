import Foundation
import AsyncHTTPClient
import Logging

/// Implementation of GitHubGateway protocol
/// Provides GitHub API integration using type-safe endpoints and AsyncHTTPClient
public actor GitHubGatewayImpl: GitHubGateway {
    // MARK: - Properties

    private let apiClient: GitHubAPIClient
    private let logger: Logger

    // MARK: - Initialization

    /// Initialize GitHub Gateway implementation
    /// - Parameters:
    ///   - httpClient: AsyncHTTPClient instance for making HTTP requests
    ///   - token: GitHub personal access token or app token
    ///   - logger: Logger instance for structured logging
    public init(
        httpClient: HTTPClient,
        token: String,
        logger: Logger
    ) {
        self.apiClient = GitHubAPIClient(
            httpClient: httpClient,
            token: token,
            logger: logger
        )
        self.logger = logger
    }

    // MARK: - GitHubGateway Protocol Implementation

    public func getPullRequest(
        owner: String,
        repo: String,
        number: Int
    ) async throws -> GitHubPullRequest {
        logger.info(
            "Fetching pull request",
            metadata: [
                "owner": .string(owner),
                "repo": .string(repo),
                "number": .stringConvertible(number)
            ]
        )

        let endpoint = GitHubAPIEndpoint.getPullRequest(
            owner: owner,
            repo: repo,
            number: number
        )

        let data = try await apiClient.get(endpoint, useETag: true)

        do {
            let response = try JSONDecoder().decode(
                GitHubPullRequestResponse.self,
                from: data
            )

            return mapToPullRequest(response)
        } catch {
            logger.error(
                "Failed to decode pull request response",
                metadata: ["error": .string(error.localizedDescription)]
            )
            throw GitHubAPIError.decodingError(error)
        }
    }

    public func updatePullRequestBranch(
        owner: String,
        repo: String,
        number: Int
    ) async throws -> BranchUpdateResult {
        logger.info(
            "Updating pull request branch",
            metadata: [
                "owner": .string(owner),
                "repo": .string(repo),
                "number": .stringConvertible(number)
            ]
        )

        let endpoint = GitHubAPIEndpoint.updatePullRequestBranch(
            owner: owner,
            repo: repo,
            number: number
        )

        // GitHub API expects empty body or expected_head_sha
        let requestBody = EmptyRequestBody()
        let data = try await apiClient.put(endpoint, body: requestBody)

        do {
            let response = try JSONDecoder().decode(
                BranchUpdateResponse.self,
                from: data
            )

            return BranchUpdateResult(
                headSHA: response.message.contains("updated") ? "" : response.message,
                message: response.message
            )
        } catch {
            logger.error(
                "Failed to decode branch update response",
                metadata: ["error": .string(error.localizedDescription)]
            )
            throw GitHubAPIError.decodingError(error)
        }
    }

    public func compareCommits(
        owner: String,
        repo: String,
        base: String,
        head: String
    ) async throws -> CommitComparison {
        logger.info(
            "Comparing commits",
            metadata: [
                "owner": .string(owner),
                "repo": .string(repo),
                "base": .string(base),
                "head": .string(head)
            ]
        )

        let endpoint = GitHubAPIEndpoint.compareCommits(
            owner: owner,
            repo: repo,
            base: base,
            head: head
        )

        let data = try await apiClient.get(endpoint)

        do {
            let response = try JSONDecoder().decode(
                ComparisonResponse.self,
                from: data
            )

            return CommitComparison(
                aheadBy: response.aheadBy,
                behindBy: response.behindBy,
                status: response.status
            )
        } catch {
            logger.error(
                "Failed to decode commit comparison response",
                metadata: ["error": .string(error.localizedDescription)]
            )
            throw GitHubAPIError.decodingError(error)
        }
    }

    public func triggerWorkflow(
        owner: String,
        repo: String,
        workflowName: String,
        ref: String,
        inputs: [String: String]
    ) async throws -> WorkflowRun {
        logger.info(
            "Triggering workflow",
            metadata: [
                "owner": .string(owner),
                "repo": .string(repo),
                "workflow": .string(workflowName),
                "ref": .string(ref)
            ]
        )

        let endpoint = GitHubAPIEndpoint.triggerWorkflow(
            owner: owner,
            repo: repo,
            workflowID: workflowName
        )

        let requestBody = WorkflowDispatchRequest(
            ref: ref,
            inputs: inputs
        )

        // Trigger returns 204 No Content on success
        _ = try await apiClient.post(endpoint, body: requestBody)

        // GitHub doesn't return the run ID immediately, so we need to poll
        // For now, return a placeholder - in production, you'd poll the runs endpoint
        logger.info("Workflow triggered successfully, polling for run ID...")

        // Wait a brief moment for the workflow to be created
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Get the latest workflow run for this ref
        let run = try await getLatestWorkflowRun(
            owner: owner,
            repo: repo,
            workflowName: workflowName,
            ref: ref
        )

        return run
    }

    public func getWorkflowRun(
        owner: String,
        repo: String,
        runID: Int
    ) async throws -> WorkflowRun {
        logger.info(
            "Fetching workflow run",
            metadata: [
                "owner": .string(owner),
                "repo": .string(repo),
                "runID": .stringConvertible(runID)
            ]
        )

        let endpoint = GitHubAPIEndpoint.getWorkflowRun(
            owner: owner,
            repo: repo,
            runID: runID
        )

        let data = try await apiClient.get(endpoint)

        do {
            let response = try JSONDecoder().decode(
                WorkflowRunResponse.self,
                from: data
            )

            return WorkflowRun(
                id: response.id,
                status: response.status,
                conclusion: response.conclusion
            )
        } catch {
            logger.error(
                "Failed to decode workflow run response",
                metadata: ["error": .string(error.localizedDescription)]
            )
            throw GitHubAPIError.decodingError(error)
        }
    }

    public func postComment(
        owner: String,
        repo: String,
        number: Int,
        message: String
    ) async throws {
        logger.info(
            "Posting comment on pull request",
            metadata: [
                "owner": .string(owner),
                "repo": .string(repo),
                "number": .stringConvertible(number),
                "messageLength": .stringConvertible(message.count)
            ]
        )

        let endpoint = GitHubAPIEndpoint.postPullRequestComment(
            owner: owner,
            repo: repo,
            number: number
        )

        let requestBody = CommentRequest(body: message)

        _ = try await apiClient.post(endpoint, body: requestBody)

        logger.info("Comment posted successfully")
    }

    public func mergePullRequest(
        owner: String,
        repo: String,
        number: Int,
        options: MergeOptions
    ) async throws -> MergeResult {
        logger.info(
            "Merging pull request",
            metadata: [
                "owner": .string(owner),
                "repo": .string(repo),
                "number": .stringConvertible(number),
                "mergeMethod": .string(options.mergeMethod)
            ]
        )

        let endpoint = GitHubAPIEndpoint.mergePullRequest(
            owner: owner,
            repo: repo,
            number: number
        )

        let requestBody = MergePullRequestRequest(
            commitTitle: options.commitTitle,
            commitMessage: options.commitMessage,
            mergeMethod: options.mergeMethod
        )

        do {
            let data = try await apiClient.put(endpoint, body: requestBody)
            let response = try JSONDecoder().decode(MergeResponse.self, from: data)

            logger.info("Pull request merged successfully", metadata: ["sha": .string(response.sha)])

            return MergeResult(
                sha: response.sha,
                merged: response.merged,
                message: response.message
            )
        } catch let error as DecodingError {
            logger.error(
                "Failed to decode merge response",
                metadata: ["error": .string(error.localizedDescription)]
            )
            throw GitHubAPIError.decodingError(error)
        } catch {
            logger.error(
                "Failed to merge pull request",
                metadata: ["error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    // MARK: - Private Helper Methods

    /// Get the latest workflow run for a given workflow and ref
    /// This is a helper to retrieve the run ID after triggering a workflow
    private func getLatestWorkflowRun(
        owner: String,
        repo: String,
        workflowName: String,
        ref: String
    ) async throws -> WorkflowRun {
        // Note: In a real implementation, you would query the workflow runs list endpoint
        // For now, we'll return a placeholder since we don't have the run ID yet
        // This would require adding a new endpoint for listing workflow runs

        logger.warning("getLatestWorkflowRun is not fully implemented - returning placeholder")

        // Return a placeholder workflow run
        return WorkflowRun(
            id: 0,
            status: "queued",
            conclusion: nil
        )
    }

    /// Map API response to domain model
    private func mapToPullRequest(_ response: GitHubPullRequestResponse) -> GitHubPullRequest {
        return GitHubPullRequest(
            id: response.id,
            number: response.number,
            title: response.title,
            state: response.state,
            mergeable: response.mergeable,
            mergeableState: response.mergeableState ?? "unknown",
            headSHA: response.head.sha,
            baseBranch: response.base.ref,
            headBranch: response.head.ref
        )
    }
}

// MARK: - API Response Models

/// GitHub API response model for pull requests
private struct GitHubPullRequestResponse: Decodable {
    let id: Int
    let number: Int
    let title: String
    let state: String
    let mergeable: Bool?
    let mergeableState: String?
    let head: BranchInfo
    let base: BranchInfo

    enum CodingKeys: String, CodingKey {
        case id, number, title, state, mergeable
        case mergeableState = "mergeable_state"
        case head, base
    }

    struct BranchInfo: Decodable {
        let ref: String
        let sha: String
    }
}

/// Branch update response
private struct BranchUpdateResponse: Decodable {
    let message: String
    let url: String?
}

/// Commit comparison response
private struct ComparisonResponse: Decodable {
    let status: String
    let aheadBy: Int
    let behindBy: Int

    enum CodingKeys: String, CodingKey {
        case status
        case aheadBy = "ahead_by"
        case behindBy = "behind_by"
    }
}

/// Workflow run response
private struct WorkflowRunResponse: Decodable {
    let id: Int
    let status: String
    let conclusion: String?
}

// MARK: - Request Models

/// Empty request body for endpoints that don't require parameters
private struct EmptyRequestBody: Encodable {}

/// Workflow dispatch request
private struct WorkflowDispatchRequest: Encodable {
    let ref: String
    let inputs: [String: String]
}

/// Comment request
private struct CommentRequest: Encodable {
    let body: String
}

/// Merge pull request request
private struct MergePullRequestRequest: Encodable {
    let commitTitle: String?
    let commitMessage: String?
    let mergeMethod: String

    enum CodingKeys: String, CodingKey {
        case commitTitle = "commit_title"
        case commitMessage = "commit_message"
        case mergeMethod = "merge_method"
    }
}

/// Merge pull request response
private struct MergeResponse: Decodable {
    let sha: String
    let merged: Bool
    let message: String
}
