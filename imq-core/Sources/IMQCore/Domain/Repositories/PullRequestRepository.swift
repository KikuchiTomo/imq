import Foundation

/// Repository protocol for PullRequest entity operations
/// Manages persistence and retrieval of pull requests
protocol PullRequestRepository: Sendable {
    /// Finds a pull request by its unique identifier
    /// - Parameter id: The pull request ID to search for
    /// - Returns: The matching pull request if found, nil otherwise
    /// - Throws: Repository errors if retrieval fails
    func find(id: PullRequestID) async throws -> PullRequest?

    /// Finds a pull request by its number within a repository
    /// - Parameters:
    ///   - number: The pull request number
    ///   - repository: The repository ID where the PR exists
    /// - Returns: The matching pull request if found, nil otherwise
    /// - Throws: Repository errors if retrieval fails
    func findByNumber(number: Int, repository: RepositoryID) async throws -> PullRequest?

    /// Saves a pull request (create or update)
    /// - Parameter pullRequest: The pull request to save
    /// - Throws: Repository errors if save operation fails
    func save(_ pullRequest: PullRequest) async throws

    /// Deletes a pull request
    /// - Parameter pullRequest: The pull request to delete
    /// - Throws: Repository errors if delete operation fails
    func delete(_ pullRequest: PullRequest) async throws
}
