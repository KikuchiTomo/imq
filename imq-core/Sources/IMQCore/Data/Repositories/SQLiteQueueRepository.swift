import Foundation
import SQLite
import Logging

/// SQLite implementation of QueueRepository protocol
/// Manages persistence of queue and queue entry entities in SQLite database
final class SQLiteQueueRepository: QueueRepository {
    private let database: SQLiteConnectionManager
    private let repositoryRepository: RepositoryRepository
    private let pullRequestRepository: PullRequestRepository
    private let logger: Logger

    // MARK: - Table and Column Definitions

    // Queues table
    private let queuesTable = Table("queues")
    private let queueIdColumn = Expression<String>("id")
    private let queueRepositoryIdColumn = Expression<String>("repository_id")
    private let queueBaseBranchColumn = Expression<String>("base_branch")
    private let queueCreatedAtColumn = Expression<Double>("created_at")

    // Queue entries table
    private let queueEntriesTable = Table("queue_entries")
    private let entryIdColumn = Expression<String>("id")
    private let entryQueueIdColumn = Expression<String>("queue_id")
    private let entryPullRequestIdColumn = Expression<String>("pull_request_id")
    private let entryPositionColumn = Expression<Int64>("position")
    private let entryStatusColumn = Expression<String>("status")
    private let entryEnqueuedAtColumn = Expression<Double>("enqueued_at")
    private let entryStartedAtColumn = Expression<Double?>("started_at")
    private let entryCompletedAtColumn = Expression<Double?>("completed_at")

    /// Initialize the repository with database connection manager
    /// - Parameters:
    ///   - database: SQLite connection manager for database operations
    ///   - repositoryRepository: Repository for loading associated repositories
    ///   - pullRequestRepository: Repository for loading associated pull requests
    ///   - logger: Logger instance for debugging and monitoring
    init(
        database: SQLiteConnectionManager,
        repositoryRepository: RepositoryRepository,
        pullRequestRepository: PullRequestRepository,
        logger: Logger
    ) {
        self.database = database
        self.repositoryRepository = repositoryRepository
        self.pullRequestRepository = pullRequestRepository
        self.logger = logger
    }

    // MARK: - QueueRepository Implementation

    /// Retrieves all queues
    /// - Returns: Array of all queues in the system
    /// - Throws: DatabaseError if retrieval fails
    func findAll() async throws -> [Queue] {
        try await database.withConnection { connection in
            let query = "SELECT * FROM queues ORDER BY created_at ASC"
            var queues: [Queue] = []

            let rowIterator = try connection.prepareRowIterator(query)
            while let row = try rowIterator.failableNext() {
                let queue = try await self.mapRowToQueue(row, connection: connection)
                queues.append(queue)
            }

            return queues
        }
    }

    /// Finds a queue by its base branch and repository
    /// - Parameters:
    ///   - baseBranch: The base branch name to search for
    ///   - repository: The repository ID to search in
    /// - Returns: The matching queue if found, nil otherwise
    /// - Throws: DatabaseError if retrieval fails
    func find(baseBranch: BranchName, repository: RepositoryID) async throws -> Queue? {
        try await database.withConnection { connection in
            let query = """
            SELECT * FROM queues
            WHERE repository_id = ? AND base_branch = ?
            LIMIT 1
            """

            let rowIterator = try connection.prepareRowIterator(query, bindings: repository.value, baseBranch.value)
            guard let row = try rowIterator.failableNext() else {
                return nil
            }

            return try await self.mapRowToQueue(row, connection: connection)
        }
    }

    /// Saves a queue (create or update)
    /// - Parameter queue: The queue to save
    /// - Throws: DatabaseError if save operation fails
    func save(_ queue: Queue) async throws {
        try await database.withConnection { connection in
            // Check if queue exists
            let existsQuery = "SELECT COUNT(*) FROM queues WHERE id = ?"
            guard let count = try connection.scalar(existsQuery, queue.id.value) as? Int64 else {
                throw DatabaseError.invalidQuery("Failed to check queue existence")
            }

            if count > 0 {
                // Update existing queue
                let updateQuery = """
                UPDATE queues
                SET repository_id = ?, base_branch = ?, created_at = ?
                WHERE id = ?
                """

                try connection.run(
                    updateQuery,
                    queue.repository.id.value,
                    queue.baseBranch.value,
                    queue.createdAt.timeIntervalSince1970,
                    queue.id.value
                )

                logger.debug("Updated queue", metadata: [
                    "id": "\(queue.id.value)",
                    "repository": "\(queue.repository.fullName)",
                    "baseBranch": "\(queue.baseBranch.value)"
                ])
            } else {
                // Insert new queue
                let insertQuery = """
                INSERT INTO queues (id, repository_id, base_branch, created_at)
                VALUES (?, ?, ?, ?)
                """

                try connection.run(
                    insertQuery,
                    queue.id.value,
                    queue.repository.id.value,
                    queue.baseBranch.value,
                    queue.createdAt.timeIntervalSince1970
                )

                logger.debug("Inserted queue", metadata: [
                    "id": "\(queue.id.value)",
                    "repository": "\(queue.repository.fullName)",
                    "baseBranch": "\(queue.baseBranch.value)"
                ])
            }

            // Save all queue entries
            try await saveQueueEntries(queue.entries, connection: connection)
        }
    }

    /// Deletes a queue
    /// - Parameter queue: The queue to delete
    /// - Throws: DatabaseError if delete operation fails
    func delete(_ queue: Queue) async throws {
        try await database.withConnection { connection in
            // Delete queue (entries will cascade delete due to foreign key)
            let query = "DELETE FROM queues WHERE id = ?"
            try connection.run(query, queue.id.value)

            logger.debug("Deleted queue", metadata: [
                "id": "\(queue.id.value)",
                "repository": "\(queue.repository.fullName)",
                "baseBranch": "\(queue.baseBranch.value)"
            ])
        }
    }

    /// Updates a queue entry within a queue
    /// - Parameter entry: The queue entry to update
    /// - Throws: DatabaseError if update operation fails
    func updateEntry(_ entry: QueueEntry) async throws {
        try await database.withConnection { connection in
            let updateQuery = """
            UPDATE queue_entries
            SET pull_request_id = ?, position = ?, status = ?,
                enqueued_at = ?, started_at = ?, completed_at = ?
            WHERE id = ?
            """

            try connection.run(
                updateQuery,
                entry.pullRequest.id.value,
                Int64(entry.position),
                entry.status.rawValue,
                entry.enqueuedAt.timeIntervalSince1970,
                entry.startedAt?.timeIntervalSince1970,
                entry.completedAt?.timeIntervalSince1970,
                entry.id.value
            )

            logger.debug("Updated queue entry", metadata: [
                "id": "\(entry.id.value)",
                "queueId": "\(entry.queueID.value)",
                "position": "\(entry.position)",
                "status": "\(entry.status.rawValue)"
            ])
        }
    }

    /// Removes a queue entry from a queue
    /// - Parameter entry: The queue entry to remove
    /// - Throws: DatabaseError if removal operation fails
    func removeEntry(_ entry: QueueEntry) async throws {
        try await database.withConnection { connection in
            let query = "DELETE FROM queue_entries WHERE id = ?"
            try connection.run(query, entry.id.value)

            logger.debug("Removed queue entry", metadata: [
                "id": "\(entry.id.value)",
                "queueId": "\(entry.queueID.value)",
                "position": "\(entry.position)"
            ])
        }
    }

    // MARK: - Private Helpers

    /// Maps a database row to a Queue entity with all its entries
    /// - Parameters:
    ///   - row: SQLite row from query result
    ///   - connection: Database connection for loading entries
    /// - Returns: Queue entity with loaded entries
    /// - Throws: Error if mapping fails or repository not found
    private func mapRowToQueue(_ row: Row, connection: Connection) async throws -> Queue {
        let id = QueueID(try row.get(queueIdColumn))
        let repositoryId = RepositoryID(try row.get(queueRepositoryIdColumn))
        let baseBranch = BranchName(try row.get(queueBaseBranchColumn))
        let createdAtTimestamp = try row.get(queueCreatedAtColumn)
        let createdAt = Date(timeIntervalSince1970: createdAtTimestamp)

        // Load associated repository
        guard let repository = try await repositoryRepository.find(id: repositoryId) else {
            throw DatabaseError.notFound(
                entityType: "Repository",
                id: repositoryId.value
            )
        }

        // Load queue entries
        let entries = try await loadQueueEntries(queueId: id, connection: connection)

        return Queue(
            id: id,
            repository: repository,
            baseBranch: baseBranch,
            entries: entries,
            createdAt: createdAt
        )
    }

    /// Loads all queue entries for a given queue
    /// - Parameters:
    ///   - queueId: The queue ID to load entries for
    ///   - connection: Database connection
    /// - Returns: Array of queue entries ordered by position
    /// - Throws: Error if loading fails
    private func loadQueueEntries(queueId: QueueID, connection: Connection) async throws -> [QueueEntry] {
        let query = """
        SELECT * FROM queue_entries
        WHERE queue_id = ?
        ORDER BY position ASC
        """

        var entries: [QueueEntry] = []

        let rowIterator = try connection.prepareRowIterator(query, bindings: queueId.value)
        while let row = try rowIterator.failableNext() {
            let entry = try await mapRowToQueueEntry(row)
            entries.append(entry)
        }

        return entries
    }

    /// Maps a database row to a QueueEntry entity
    /// - Parameter row: SQLite row from query result
    /// - Returns: QueueEntry entity
    /// - Throws: Error if mapping fails or pull request not found
    private func mapRowToQueueEntry(_ row: Row) async throws -> QueueEntry {
        let id = QueueEntryID(try row.get(entryIdColumn))
        let queueId = QueueID(try row.get(entryQueueIdColumn))
        let pullRequestId = PullRequestID(try row.get(entryPullRequestIdColumn))
        let position = Int(try row.get(entryPositionColumn))
        let statusRaw = try row.get(entryStatusColumn)
        let enqueuedAtTimestamp = try row.get(entryEnqueuedAtColumn)
        let startedAtTimestamp = try row.get(entryStartedAtColumn)
        let completedAtTimestamp = try row.get(entryCompletedAtColumn)

        guard let status = QueueEntryStatus(rawValue: statusRaw) else {
            throw DatabaseError.invalidQuery("Invalid queue entry status: \(statusRaw)")
        }

        let enqueuedAt = Date(timeIntervalSince1970: enqueuedAtTimestamp)
        let startedAt = startedAtTimestamp.map { Date(timeIntervalSince1970: $0) }
        let completedAt = completedAtTimestamp.map { Date(timeIntervalSince1970: $0) }

        // Load associated pull request
        guard let pullRequest = try await pullRequestRepository.find(id: pullRequestId) else {
            throw DatabaseError.notFound(
                entityType: "PullRequest",
                id: pullRequestId.value
            )
        }

        return QueueEntry(
            id: id,
            queueID: queueId,
            pullRequest: pullRequest,
            position: position,
            status: status,
            enqueuedAt: enqueuedAt,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// Saves all queue entries for a queue
    /// - Parameters:
    ///   - entries: Array of queue entries to save
    ///   - connection: Database connection
    /// - Throws: Error if save operation fails
    private func saveQueueEntries(_ entries: [QueueEntry], connection: Connection) async throws {
        // First, get existing entry IDs for this queue
        guard let firstEntry = entries.first else {
            return // No entries to save
        }

        let queueId = firstEntry.queueID
        let existingIdsQuery = "SELECT id FROM queue_entries WHERE queue_id = ?"
        var existingIds = Set<String>()

        let rowIterator = try connection.prepareRowIterator(existingIdsQuery, bindings: queueId.value)
        while let row = try rowIterator.failableNext() {
            let idValue = try row.get(Expression<String>("id"))
            existingIds.insert(idValue)
        }

        let currentIds = Set(entries.map { $0.id.value })

        // Delete entries that are no longer in the queue
        let idsToDelete = existingIds.subtracting(currentIds)
        for idToDelete in idsToDelete {
            let deleteQuery = "DELETE FROM queue_entries WHERE id = ?"
            try connection.run(deleteQuery, idToDelete)
        }

        // Insert or update entries
        for entry in entries {
            if existingIds.contains(entry.id.value) {
                // Update existing entry
                let updateQuery = """
                UPDATE queue_entries
                SET pull_request_id = ?, position = ?, status = ?,
                    enqueued_at = ?, started_at = ?, completed_at = ?
                WHERE id = ?
                """

                try connection.run(
                    updateQuery,
                    entry.pullRequest.id.value,
                    Int64(entry.position),
                    entry.status.rawValue,
                    entry.enqueuedAt.timeIntervalSince1970,
                    entry.startedAt?.timeIntervalSince1970,
                    entry.completedAt?.timeIntervalSince1970,
                    entry.id.value
                )
            } else {
                // Insert new entry
                let insertQuery = """
                INSERT INTO queue_entries (
                    id, queue_id, pull_request_id, position, status,
                    enqueued_at, started_at, completed_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """

                try connection.run(
                    insertQuery,
                    entry.id.value,
                    entry.queueID.value,
                    entry.pullRequest.id.value,
                    Int64(entry.position),
                    entry.status.rawValue,
                    entry.enqueuedAt.timeIntervalSince1970,
                    entry.startedAt?.timeIntervalSince1970,
                    entry.completedAt?.timeIntervalSince1970
                )
            }
        }
    }
}
