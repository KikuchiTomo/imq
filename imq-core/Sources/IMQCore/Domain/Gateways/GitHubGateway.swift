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

    /// Merge a pull request
    /// - Parameters:
    ///   - owner: Repository owner (user or organization)
    ///   - repo: Repository name
    ///   - number: Pull request number
    ///   - commitTitle: Title for the merge commit
    ///   - commitMessage: Message for the merge commit
    ///   - mergeMethod: Merge method (merge, squash, rebase)
    /// - Returns: Merge result with SHA
    /// - Throws: GitHubAPIError if merge fails
    func mergePullRequest(
        owner: String,
        repo: String,
        number: Int,
        commitTitle: String?,
        commitMessage: String?,
        mergeMethod: String
    ) async throws -> MergeResult
}

// MARK: - Response Types

/// GitHub pull request response
public struct GitHubPullRequest: Sendable, Codable {
    /// Pull request ID
    public let id: Int

    /// Pull request number
    public let number: Int

    /// Pull request title
    public let title: String

    /// Pull request state (open, closed)
    public let state: String

    /// Whether the pull request can be merged (nil if still calculating)
    public let mergeable: Bool?

    /// Mergeable state (clean, dirty, unstable, etc.)
    public let mergeableState: String

    /// HEAD commit SHA
    public let headSHA: String

    /// Base branch name
    public let baseBranch: String

    /// Head branch name
    public let headBranch: String

    public init(id: Int, number: Int, title: String, state: String, mergeable: Bool?, mergeableState: String, headSHA: String, baseBranch: String, headBranch: String) {
        self.id = id
        self.number = number
        self.title = title
        self.state = state
        self.mergeable = mergeable
        self.mergeableState = mergeableState
        self.headSHA = headSHA
        self.baseBranch = baseBranch
        self.headBranch = headBranch
    }
}

/// Branch update result
public struct BranchUpdateResult: Sendable, Codable {
    /// New HEAD commit SHA after update
    public let headSHA: String

    /// Update status message
    public let message: String

    public init(headSHA: String, message: String) {
        self.headSHA = headSHA
        self.message = message
    }
}

/// Commit comparison result
public struct CommitComparison: Sendable, Codable {
    /// Number of commits ahead
    public let aheadBy: Int

    /// Number of commits behind
    public let behindBy: Int

    /// Comparison status (ahead, behind, identical, diverged)
    public let status: String

    public init(aheadBy: Int, behindBy: Int, status: String) {
        self.aheadBy = aheadBy
        self.behindBy = behindBy
        self.status = status
    }
}

/// GitHub Actions workflow run
public struct WorkflowRun: Sendable, Codable {
    /// Workflow run ID
    public let id: Int

    /// Workflow run status (queued, in_progress, completed)
    public let status: String

    /// Workflow run conclusion (success, failure, cancelled, timed_out, etc.)
    public let conclusion: String?

    public init(id: Int, status: String, conclusion: String?) {
        self.id = id
        self.status = status
        self.conclusion = conclusion
    }
}

/// Merge result
public struct MergeResult: Sendable, Codable {
    /// SHA of the merge commit
    public let sha: String

    /// Whether the merge was successful
    public let merged: Bool

    /// Merge status message
    public let message: String

    public init(sha: String, merged: Bool, message: String) {
        self.sha = sha
        self.merged = merged
        self.message = message
    }
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
