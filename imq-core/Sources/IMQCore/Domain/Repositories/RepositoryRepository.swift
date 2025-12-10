import Foundation

/// Repository protocol for Repository entity operations
/// Manages persistence and retrieval of GitHub repositories
protocol RepositoryRepository: Sendable {
    /// Finds a repository by its unique identifier
    /// - Parameter id: The repository ID to search for
    /// - Returns: The matching repository if found, nil otherwise
    /// - Throws: Repository errors if retrieval fails
    func find(id: RepositoryID) async throws -> Repository?

    /// Finds a repository by its full name (owner/name)
    /// - Parameter fullName: The full repository name (e.g., "owner/repo")
    /// - Returns: The matching repository if found, nil otherwise
    /// - Throws: Repository errors if retrieval fails
    func findByFullName(_ fullName: String) async throws -> Repository?

    /// Saves a repository (create or update)
    /// - Parameter repository: The repository to save
    /// - Throws: Repository errors if save operation fails
    func save(_ repository: Repository) async throws

    /// Deletes a repository
    /// - Parameter repository: The repository to delete
    /// - Throws: Repository errors if delete operation fails
    func delete(_ repository: Repository) async throws
}
