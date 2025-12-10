import Foundation

/// Use case for updating pull requests
/// Handles updating a PR's head branch with the latest base branch changes
protocol PRUpdateUseCase: Sendable {
    /// Update a pull request's head branch with the latest base branch
    /// - Parameter pullRequest: The pull request to update
    /// - Returns: Update result indicating success, already up-to-date, or failure
    /// - Throws: Error if the update operation fails
    func updatePR(_ pullRequest: PullRequest) async throws -> PRUpdateResult
}

// MARK: - Result Types

/// Result of pull request update operation
enum PRUpdateResult: Sendable {
    /// PR was successfully updated with new HEAD SHA
    case updated(newHeadSHA: String)

    /// PR is already up-to-date, no update needed
    case alreadyUpToDate

    /// PR update failed with error
    case failed(Error)

    /// Whether the update was successful
    var wasSuccessful: Bool {
        switch self {
        case .updated, .alreadyUpToDate:
            return true
        case .failed:
            return false
        }
    }

    /// The new HEAD SHA if the update was successful
    var newHeadSHA: String? {
        if case .updated(let sha) = self {
            return sha
        }
        return nil
    }
}
