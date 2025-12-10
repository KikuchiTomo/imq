import Foundation

/// Use case for processing merge queues
/// Handles the complete queue processing workflow including conflict detection,
/// PR updates, check execution, and merging
protocol QueueProcessingUseCase: Sendable {
    /// Process a queue for a specific base branch in a repository
    /// - Parameters:
    ///   - baseBranch: The base branch name for the queue
    ///   - repository: The repository containing the queue
    /// - Throws: QueueProcessingError if processing fails
    func processQueue(
        for baseBranch: BranchName,
        in repository: Repository
    ) async throws
}

// MARK: - Error Types

/// Queue processing error
enum QueueProcessingError: Error, LocalizedError {
    case queueNotFound(baseBranch: String, repository: String)
    case noPendingEntries
    case conflictDetectionFailed(Error)
    case prUpdateFailed(Error)
    case checkExecutionFailed(Error)
    case mergeFailed(Error)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .queueNotFound(let baseBranch, let repository):
            return "Queue not found for branch '\(baseBranch)' in repository '\(repository)'"
        case .noPendingEntries:
            return "No pending entries in queue"
        case .conflictDetectionFailed(let error):
            return "Conflict detection failed: \(error.localizedDescription)"
        case .prUpdateFailed(let error):
            return "Pull request update failed: \(error.localizedDescription)"
        case .checkExecutionFailed(let error):
            return "Check execution failed: \(error.localizedDescription)"
        case .mergeFailed(let error):
            return "Merge failed: \(error.localizedDescription)"
        case .unknown(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}
