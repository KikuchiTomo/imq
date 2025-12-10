import Foundation
import SQLite
import Logging

/// SQLite implementation of RepositoryRepository protocol
/// Manages persistence of GitHub repository entities in SQLite database
final class SQLiteRepositoryRepository: RepositoryRepository {
    private let database: SQLiteConnectionManager
    private let logger: Logger

    /// Initialize the repository with database connection manager
    /// - Parameters:
    ///   - database: SQLite connection manager for database operations
    ///   - logger: Logger instance for debugging and monitoring
    init(database: SQLiteConnectionManager, logger: Logger) {
        self.database = database
        self.logger = logger
    }

    // MARK: - RepositoryRepository Implementation

    /// Finds a repository by its unique identifier
    /// - Parameter id: The repository ID to search for
    /// - Returns: The matching repository if found, nil otherwise
    /// - Throws: DatabaseError if query execution fails
    func find(id: RepositoryID) async throws -> Repository? {
        try await database.withConnection { connection in
            let query = "SELECT * FROM repositories WHERE id = ? LIMIT 1"

            guard let row = try connection.prepare(query).bind(id.value).makeIterator().next() else {
                return nil
            }

            return try self.mapRowToRepository(row)
        }
    }

    /// Finds a repository by its full name (owner/name)
    /// - Parameter fullName: The full repository name (e.g., "owner/repo")
    /// - Returns: The matching repository if found, nil otherwise
    /// - Throws: DatabaseError if query execution fails
    func findByFullName(_ fullName: String) async throws -> Repository? {
        try await database.withConnection { connection in
            let query = "SELECT * FROM repositories WHERE full_name = ? LIMIT 1"

            guard let row = try connection.prepare(query).bind(fullName).makeIterator().next() else {
                return nil
            }

            return try self.mapRowToRepository(row)
        }
    }

    /// Saves a repository (create or update)
    /// - Parameter repository: The repository to save
    /// - Throws: DatabaseError if save operation fails
    func save(_ repository: Repository) async throws {
        try await database.withConnection { connection in
            // Check if repository exists
            let existsQuery = "SELECT COUNT(*) FROM repositories WHERE id = ?"
            let count = try connection.scalar(existsQuery, repository.id.value) as! Int64

            if count > 0 {
                // Update existing repository
                let updateQuery = """
                UPDATE repositories
                SET owner = ?, name = ?, full_name = ?, default_branch = ?, created_at = ?
                WHERE id = ?
                """

                try connection.run(
                    updateQuery,
                    repository.owner,
                    repository.name,
                    repository.fullName,
                    repository.defaultBranch.value,
                    repository.createdAt.timeIntervalSince1970,
                    repository.id.value
                )

                logger.debug("Updated repository", metadata: [
                    "id": "\(repository.id.value)",
                    "fullName": "\(repository.fullName)"
                ])
            } else {
                // Insert new repository
                let insertQuery = """
                INSERT INTO repositories (id, owner, name, full_name, default_branch, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """

                try connection.run(
                    insertQuery,
                    repository.id.value,
                    repository.owner,
                    repository.name,
                    repository.fullName,
                    repository.defaultBranch.value,
                    repository.createdAt.timeIntervalSince1970
                )

                logger.debug("Inserted repository", metadata: [
                    "id": "\(repository.id.value)",
                    "fullName": "\(repository.fullName)"
                ])
            }
        }
    }

    /// Deletes a repository
    /// - Parameter repository: The repository to delete
    /// - Throws: DatabaseError if delete operation fails
    func delete(_ repository: Repository) async throws {
        try await database.withConnection { connection in
            let query = "DELETE FROM repositories WHERE id = ?"
            try connection.run(query, repository.id.value)

            logger.debug("Deleted repository", metadata: [
                "id": "\(repository.id.value)",
                "fullName": "\(repository.fullName)"
            ])
        }
    }

    // MARK: - Private Helpers

    /// Maps a database row to a Repository entity
    /// - Parameter row: SQLite row from query result
    /// - Returns: Repository entity
    /// - Throws: Error if mapping fails
    private func mapRowToRepository(_ row: Row) throws -> Repository {
        let id = RepositoryID(row[0] as! String)
        let owner = row[1] as! String
        let name = row[2] as! String
        let fullName = row[3] as! String
        let defaultBranch = BranchName(row[4] as! String)
        let createdAtTimestamp = row[5] as! Double
        let createdAt = Date(timeIntervalSince1970: createdAtTimestamp)

        return Repository(
            id: id,
            owner: owner,
            name: name,
            fullName: fullName,
            defaultBranch: defaultBranch,
            createdAt: createdAt
        )
    }
}
