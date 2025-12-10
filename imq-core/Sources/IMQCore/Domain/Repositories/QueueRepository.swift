import Foundation

/// Repository protocol for Queue entity operations
/// Manages persistence and retrieval of merge queues
protocol QueueRepository: Sendable {
    /// Retrieves all queues
    /// - Returns: Array of all queues in the system
    /// - Throws: Repository errors if retrieval fails
    func findAll() async throws -> [Queue]

    /// Finds a queue by its base branch and repository
    /// - Parameters:
    ///   - baseBranch: The base branch name to search for
    ///   - repository: The repository ID to search in
    /// - Returns: The matching queue if found, nil otherwise
    /// - Throws: Repository errors if retrieval fails
    func find(baseBranch: BranchName, repository: RepositoryID) async throws -> Queue?

    /// Saves a queue (create or update)
    /// - Parameter queue: The queue to save
    /// - Throws: Repository errors if save operation fails
    func save(_ queue: Queue) async throws

    /// Deletes a queue
    /// - Parameter queue: The queue to delete
    /// - Throws: Repository errors if delete operation fails
    func delete(_ queue: Queue) async throws

    /// Updates a queue entry within a queue
    /// - Parameter entry: The queue entry to update
    /// - Throws: Repository errors if update operation fails
    func updateEntry(_ entry: QueueEntry) async throws

    /// Removes a queue entry from a queue
    /// - Parameter entry: The queue entry to remove
    /// - Throws: Repository errors if removal operation fails
    func removeEntry(_ entry: QueueEntry) async throws
}
