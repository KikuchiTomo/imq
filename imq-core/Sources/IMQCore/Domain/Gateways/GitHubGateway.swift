import Foundation

/// Gateway for GitHub API interactions
/// Provides methods for managing pull requests, branches, commits, workflows, and comments
protocol GitHubGateway: Sendable {
    /// Get pull request details from GitHub
    /// - Parameters:
    ///   - owner: Repository owner (user or organization)
    ///   - repo: Repository name
    ///   - number: Pull request number
    /// - Returns: GitHub pull request details
    /// - Throws: GitHubAPIError if the request fails
    func getPullRequest(
        owner: String,
        repo: String,
        number: Int
    ) async throws -> GitHubPullRequest

    /// Update pull request branch with latest base branch
    /// - Parameters:
    ///   - owner: Repository owner (user or organization)
    ///   - repo: Repository name
    ///   - number: Pull request number
    /// - Returns: Branch update result with new HEAD SHA
    /// - Throws: GitHubAPIError if the update fails
    func updatePullRequestBranch(
        owner: String,
        repo: String,
        number: Int
    ) async throws -> BranchUpdateResult

    /// Compare two commits or branches
    /// - Parameters:
    ///   - owner: Repository owner (user or organization)
    ///   - repo: Repository name
    ///   - base: Base branch or commit SHA
    ///   - head: Head branch or commit SHA
    /// - Returns: Commit comparison details
    /// - Throws: GitHubAPIError if the comparison fails
    func compareCommits(
        owner: String,
        repo: String,
        base: String,
        head: String
    ) async throws -> CommitComparison

    /// Trigger a GitHub Actions workflow
    /// - Parameters:
    ///   - owner: Repository owner (user or organization)
    ///   - repo: Repository name
    ///   - workflowName: Name of the workflow file (e.g., "ci.yml")
    ///   - ref: Git reference (branch, tag, or SHA)
    ///   - inputs: Input parameters for the workflow
    /// - Returns: Triggered workflow run details
    /// - Throws: GitHubAPIError if the workflow trigger fails
    func triggerWorkflow(
        owner: String,
        repo: String,
        workflowName: String,
        ref: String,
        inputs: [String: String]
    ) async throws -> WorkflowRun

    /// Get workflow run details
    /// - Parameters:
    ///   - owner: Repository owner (user or organization)
    ///   - repo: Repository name
    ///   - runID: Workflow run ID
    /// - Returns: Workflow run details
    /// - Throws: GitHubAPIError if the request fails
    func getWorkflowRun(
        owner: String,
        repo: String,
        runID: Int
    ) async throws -> WorkflowRun

    /// Post a comment on a pull request
    /// - Parameters:
    ///   - owner: Repository owner (user or organization)
    ///   - repo: Repository name
    ///   - number: Pull request number
    ///   - message: Comment message (supports markdown)
    /// - Throws: GitHubAPIError if posting the comment fails
    func postComment(
        owner: String,
        repo: String,
        number: Int,
        message: String
    ) async throws
}

// MARK: - Response Types

/// GitHub pull request response
struct GitHubPullRequest: Sendable, Codable {
    /// Pull request ID
    let id: Int

    /// Pull request number
    let number: Int

    /// Pull request title
    let title: String

    /// Pull request state (open, closed)
    let state: String

    /// Whether the pull request can be merged (nil if still calculating)
    let mergeable: Bool?

    /// Mergeable state (clean, dirty, unstable, etc.)
    let mergeableState: String

    /// HEAD commit SHA
    let headSHA: String

    /// Base branch name
    let baseBranch: String

    /// Head branch name
    let headBranch: String
}

/// Branch update result
struct BranchUpdateResult: Sendable, Codable {
    /// New HEAD commit SHA after update
    let headSHA: String

    /// Update status message
    let message: String
}

/// Commit comparison result
struct CommitComparison: Sendable, Codable {
    /// Number of commits ahead
    let aheadBy: Int

    /// Number of commits behind
    let behindBy: Int

    /// Comparison status (ahead, behind, identical, diverged)
    let status: String
}

/// GitHub Actions workflow run
struct WorkflowRun: Sendable, Codable {
    /// Workflow run ID
    let id: Int

    /// Workflow run status (queued, in_progress, completed)
    let status: String

    /// Workflow run conclusion (success, failure, cancelled, timed_out, etc.)
    let conclusion: String?
}

// MARK: - Error Types

/// GitHub API error
enum GitHubAPIError: Error, LocalizedError {
    case rateLimitExceeded
    case notFound
    case unauthorized
    case forbidden
    case validationFailed(String)
    case httpError(statusCode: Int, message: String)
    case networkError(Error)
    case decodingError(Error)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .rateLimitExceeded:
            return "GitHub API rate limit exceeded"
        case .notFound:
            return "Resource not found"
        case .unauthorized:
            return "Unauthorized: Invalid or missing GitHub token"
        case .forbidden:
            return "Forbidden: Insufficient permissions"
        case .validationFailed(let message):
            return "Validation failed: \(message)"
        case .httpError(let statusCode, let message):
            return "HTTP \(statusCode): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .unknown(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}
