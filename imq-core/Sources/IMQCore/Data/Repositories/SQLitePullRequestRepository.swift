import Foundation
import SQLite
import Logging

/// SQLite implementation of PullRequestRepository protocol
/// Manages persistence of pull request entities in SQLite database
final class SQLitePullRequestRepository: PullRequestRepository {
    private let database: SQLiteConnectionManager
    private let repositoryRepository: RepositoryRepository
    private let logger: Logger

    // MARK: - Table and Column Definitions

    private let pullRequestsTable = Table("pull_requests")
    private let idColumn = Expression<String>("id")
    private let repositoryIdColumn = Expression<String>("repository_id")
    private let numberColumn = Expression<Int64>("number")
    private let titleColumn = Expression<String>("title")
    private let authorLoginColumn = Expression<String>("author_login")
    private let baseBranchColumn = Expression<String>("base_branch")
    private let headBranchColumn = Expression<String>("head_branch")
    private let headSHAColumn = Expression<String>("head_sha")
    private let isConflictedColumn = Expression<Int64>("is_conflicted")
    private let isUpToDateColumn = Expression<Int64>("is_up_to_date")
    private let createdAtColumn = Expression<Double>("created_at")
    private let updatedAtColumn = Expression<Double>("updated_at")

    /// Initialize the repository with database connection manager
    /// - Parameters:
    ///   - database: SQLite connection manager for database operations
    ///   - repositoryRepository: Repository for loading associated repositories
    ///   - logger: Logger instance for debugging and monitoring
    init(
        database: SQLiteConnectionManager,
        repositoryRepository: RepositoryRepository,
        logger: Logger
    ) {
        self.database = database
        self.repositoryRepository = repositoryRepository
        self.logger = logger
    }

    // MARK: - PullRequestRepository Implementation

    /// Finds a pull request by its unique identifier
    /// - Parameter id: The pull request ID to search for
    /// - Returns: The matching pull request if found, nil otherwise
    /// - Throws: DatabaseError if query execution fails
    func find(id: PullRequestID) async throws -> PullRequest? {
        try await database.withConnection { connection in
            let query = "SELECT * FROM pull_requests WHERE id = ? LIMIT 1"

            guard let row = try connection.prepare(query).bind(id.value).makeIterator().next() else {
                return nil
            }

            return try await self.mapRowToPullRequest(row)
        }
    }

    /// Finds a pull request by its number within a repository
    /// - Parameters:
    ///   - number: The pull request number
    ///   - repository: The repository ID where the PR exists
    /// - Returns: The matching pull request if found, nil otherwise
    /// - Throws: DatabaseError if query execution fails
    func findByNumber(number: Int, repository: RepositoryID) async throws -> PullRequest? {
        try await database.withConnection { connection in
            let query = """
            SELECT * FROM pull_requests
            WHERE repository_id = ? AND number = ?
            LIMIT 1
            """

            guard let row = try connection.prepare(query)
                .bind(repository.value, Int64(number))
                .makeIterator()
                .next() else {
                return nil
            }

            return try await self.mapRowToPullRequest(row)
        }
    }

    /// Saves a pull request (create or update)
    /// - Parameter pullRequest: The pull request to save
    /// - Throws: DatabaseError if save operation fails
    func save(_ pullRequest: PullRequest) async throws {
        try await database.withConnection { connection in
            // Check if pull request exists
            let existsQuery = "SELECT COUNT(*) FROM pull_requests WHERE id = ?"
            let count = try connection.scalar(existsQuery, pullRequest.id.value) as! Int64

            if count > 0 {
                // Update existing pull request
                let updateQuery = """
                UPDATE pull_requests
                SET repository_id = ?, number = ?, title = ?, author_login = ?,
                    base_branch = ?, head_branch = ?, head_sha = ?,
                    is_conflicted = ?, is_up_to_date = ?,
                    created_at = ?, updated_at = ?
                WHERE id = ?
                """

                try connection.run(
                    updateQuery,
                    pullRequest.repository.id.value,
                    Int64(pullRequest.number),
                    pullRequest.title,
                    pullRequest.authorLogin,
                    pullRequest.baseBranch.value,
                    pullRequest.headBranch.value,
                    pullRequest.headSHA.value,
                    pullRequest.isConflicted ? 1 : 0,
                    pullRequest.isUpToDate ? 1 : 0,
                    pullRequest.createdAt.timeIntervalSince1970,
                    pullRequest.updatedAt.timeIntervalSince1970,
                    pullRequest.id.value
                )

                logger.debug("Updated pull request", metadata: [
                    "id": "\(pullRequest.id.value)",
                    "number": "\(pullRequest.number)",
                    "repository": "\(pullRequest.repository.fullName)"
                ])
            } else {
                // Insert new pull request
                let insertQuery = """
                INSERT INTO pull_requests (
                    id, repository_id, number, title, author_login,
                    base_branch, head_branch, head_sha,
                    is_conflicted, is_up_to_date,
                    created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """

                try connection.run(
                    insertQuery,
                    pullRequest.id.value,
                    pullRequest.repository.id.value,
                    Int64(pullRequest.number),
                    pullRequest.title,
                    pullRequest.authorLogin,
                    pullRequest.baseBranch.value,
                    pullRequest.headBranch.value,
                    pullRequest.headSHA.value,
                    pullRequest.isConflicted ? 1 : 0,
                    pullRequest.isUpToDate ? 1 : 0,
                    pullRequest.createdAt.timeIntervalSince1970,
                    pullRequest.updatedAt.timeIntervalSince1970
                )

                logger.debug("Inserted pull request", metadata: [
                    "id": "\(pullRequest.id.value)",
                    "number": "\(pullRequest.number)",
                    "repository": "\(pullRequest.repository.fullName)"
                ])
            }
        }
    }

    /// Deletes a pull request
    /// - Parameter pullRequest: The pull request to delete
    /// - Throws: DatabaseError if delete operation fails
    func delete(_ pullRequest: PullRequest) async throws {
        try await database.withConnection { connection in
            let query = "DELETE FROM pull_requests WHERE id = ?"
            try connection.run(query, pullRequest.id.value)

            logger.debug("Deleted pull request", metadata: [
                "id": "\(pullRequest.id.value)",
                "number": "\(pullRequest.number)",
                "repository": "\(pullRequest.repository.fullName)"
            ])
        }
    }

    // MARK: - Private Helpers

    /// Maps a database row to a PullRequest entity
    /// - Parameter row: SQLite row from query result
    /// - Returns: PullRequest entity
    /// - Throws: Error if mapping fails or repository not found
    private func mapRowToPullRequest(_ row: Row) async throws -> PullRequest {
        let id = PullRequestID(try row.get(idColumn))
        let repositoryId = RepositoryID(try row.get(repositoryIdColumn))
        let number = Int(try row.get(numberColumn))
        let title = try row.get(titleColumn)
        let authorLogin = try row.get(authorLoginColumn)
        let baseBranch = BranchName(try row.get(baseBranchColumn))
        let headBranch = BranchName(try row.get(headBranchColumn))
        let headSHA = CommitSHA(try row.get(headSHAColumn))
        let isConflicted = (try row.get(isConflictedColumn)) != 0
        let isUpToDate = (try row.get(isUpToDateColumn)) != 0
        let createdAtTimestamp = try row.get(createdAtColumn)
        let updatedAtTimestamp = try row.get(updatedAtColumn)
        let createdAt = Date(timeIntervalSince1970: createdAtTimestamp)
        let updatedAt = Date(timeIntervalSince1970: updatedAtTimestamp)

        // Load associated repository
        guard let repository = try await repositoryRepository.find(id: repositoryId) else {
            throw DatabaseError.notFound(
                entityType: "Repository",
                id: repositoryId.value
            )
        }

        return PullRequest(
            id: id,
            repository: repository,
            number: number,
            title: title,
            authorLogin: authorLogin,
            baseBranch: baseBranch,
            headBranch: headBranch,
            headSHA: headSHA,
            isConflicted: isConflicted,
            isUpToDate: isUpToDate,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
