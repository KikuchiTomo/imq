import Foundation
import NIOHTTP1

/// HTTP method for GitHub API requests
enum GitHubHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}

/// GitHub API version
enum GitHubAPIVersion: Sendable {
    case v1

    /// Base URL for GitHub API
    var baseURL: String {
        switch self {
        case .v1:
            return "https://api.github.com"
        }
    }

    /// API version header value
    var versionHeader: String {
        switch self {
        case .v1:
            return "2022-11-28"
        }
    }
}

/// Type-safe GitHub API endpoint definitions
/// Provides strongly-typed endpoints with automatic path building and HTTP method configuration
enum GitHubAPIEndpoint: Sendable {
    // MARK: - Pull Requests

    /// Get pull request details
    /// GET /repos/{owner}/{repo}/pulls/{number}
    case getPullRequest(owner: String, repo: String, number: Int)

    /// Update pull request branch
    /// PUT /repos/{owner}/{repo}/pulls/{number}/update-branch
    case updatePullRequestBranch(owner: String, repo: String, number: Int)

    /// Post comment on pull request
    /// POST /repos/{owner}/{repo}/issues/{number}/comments
    case postPullRequestComment(owner: String, repo: String, number: Int)

    /// Merge pull request
    /// PUT /repos/{owner}/{repo}/pulls/{number}/merge
    case mergePullRequest(owner: String, repo: String, number: Int)

    // MARK: - Commits

    /// Compare two commits
    /// GET /repos/{owner}/{repo}/compare/{base}...{head}
    case compareCommits(owner: String, repo: String, base: String, head: String)

    // MARK: - Actions (Workflows)

    /// Trigger workflow dispatch
    /// POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches
    case triggerWorkflow(owner: String, repo: String, workflowID: String)

    /// Get workflow run details
    /// GET /repos/{owner}/{repo}/actions/runs/{run_id}
    case getWorkflowRun(owner: String, repo: String, runID: Int)

    // MARK: - Computed Properties

    /// The complete path for the endpoint
    var path: String {
        switch self {
        case .getPullRequest(let owner, let repo, let number):
            return "/repos/\(owner)/\(repo)/pulls/\(number)"

        case .updatePullRequestBranch(let owner, let repo, let number):
            return "/repos/\(owner)/\(repo)/pulls/\(number)/update-branch"

        case .postPullRequestComment(let owner, let repo, let number):
            return "/repos/\(owner)/\(repo)/issues/\(number)/comments"

        case .mergePullRequest(let owner, let repo, let number):
            return "/repos/\(owner)/\(repo)/pulls/\(number)/merge"

        case .compareCommits(let owner, let repo, let base, let head):
            return "/repos/\(owner)/\(repo)/compare/\(base)...\(head)"

        case .triggerWorkflow(let owner, let repo, let workflowID):
            return "/repos/\(owner)/\(repo)/actions/workflows/\(workflowID)/dispatches"

        case .getWorkflowRun(let owner, let repo, let runID):
            return "/repos/\(owner)/\(repo)/actions/runs/\(runID)"
        }
    }

    /// The HTTP method for the endpoint
    var method: GitHubHTTPMethod {
        switch self {
        case .getPullRequest,
             .compareCommits,
             .getWorkflowRun:
            return .get

        case .updatePullRequestBranch,
             .mergePullRequest:
            return .put

        case .postPullRequestComment,
             .triggerWorkflow:
            return .post
        }
    }

    /// Build complete URL for the endpoint
    /// - Parameter version: API version to use (defaults to v1)
    /// - Returns: Complete URL string
    func url(version: GitHubAPIVersion = .v1) -> String {
        return "\(version.baseURL)\(path)"
    }
}
