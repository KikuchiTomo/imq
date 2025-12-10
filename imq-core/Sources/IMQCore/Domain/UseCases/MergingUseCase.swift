import Foundation

/// Use case for merging pull requests
/// Handles the final merge operation for pull requests that have passed all checks
protocol MergingUseCase: Sendable {
    /// Merge a pull request into its base branch
    /// - Parameter pullRequest: The pull request to merge
    /// - Throws: MergingError if the merge operation fails
    func mergePullRequest(_ pullRequest: PullRequest) async throws
}

// MARK: - Error Types

/// Merging operation error
enum MergingError: Error, LocalizedError {
    case notMergeable(reason: String)
    case mergeConflict
    case checksFailed
    case unauthorized
    case branchProtectionViolation(rule: String)
    case apiError(Error)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notMergeable(let reason):
            return "Pull request is not mergeable: \(reason)"
        case .mergeConflict:
            return "Pull request has merge conflicts"
        case .checksFailed:
            return "Required checks have not passed"
        case .unauthorized:
            return "Unauthorized to merge pull request"
        case .branchProtectionViolation(let rule):
            return "Branch protection rule violation: \(rule)"
        case .apiError(let error):
            return "API error: \(error.localizedDescription)"
        case .unknown(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}
