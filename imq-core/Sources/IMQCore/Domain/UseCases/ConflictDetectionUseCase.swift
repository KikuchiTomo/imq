import Foundation

/// Use case for detecting conflicts in pull requests
/// Checks if a PR has merge conflicts with its base branch
protocol ConflictDetectionUseCase: Sendable {
    /// Detect if a pull request has conflicts with its base branch
    /// - Parameter pullRequest: The pull request to check for conflicts
    /// - Returns: Conflict detection result
    /// - Throws: Error if conflict detection fails
    func detectConflicts(for pullRequest: PullRequest) async throws -> ConflictResult
}

// MARK: - Result Types

/// Result of conflict detection
enum ConflictResult: Sendable {
    /// No conflicts detected - PR can be merged
    case noConflict

    /// Conflicts detected - PR cannot be merged
    case hasConflict

    /// Conflict detection status unknown due to error
    case unknown(Error)

    /// Whether the PR has no conflicts
    var hasNoConflict: Bool {
        if case .noConflict = self {
            return true
        }
        return false
    }

    /// Whether the PR has conflicts
    var hasConflicts: Bool {
        if case .hasConflict = self {
            return true
        }
        return false
    }
}
