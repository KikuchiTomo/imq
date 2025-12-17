import Foundation
import Vapor
import SQLite
import Logging
import IMQCore

// MARK: - SQLite Queue Repository Implementation

public final class SQLiteQueueRepository: QueueRepository {
    private let database: SQLiteConnectionManager
    private let logger: Logger

    public init(database: SQLiteConnectionManager, logger: Logger) {
        self.database = database
        self.logger = logger
    }

    public func getAll() async throws -> [Queue] {
        try await database.withConnection { connection in
            let query = "SELECT id, repository_id, status, created_at, updated_at FROM queues"
            let rowIterator = try connection.prepareRowIterator(query)
            var queues: [Queue] = []

            while let row = try rowIterator.failableNext() {
                queues.append(try self.mapRowToQueue(row))
            }

            return queues
        }
    }

    public func get(id: Int) async throws -> Queue {
        try await database.withConnection { connection in
            let query = "SELECT id, repository_id, status, created_at, updated_at FROM queues WHERE id = ?"
            let rowIterator = try connection.prepareRowIterator(query, bindings: id)

            guard let row = try rowIterator.failableNext() else {
                throw Abort(.notFound, reason: "Queue not found")
            }

            return try self.mapRowToQueue(row)
        }
    }

    public func save(_ queue: Queue) async throws -> Queue {
        try await database.withConnection { connection in
            let now = Date()

            if queue.id == 0 {
                // Insert new queue
                try connection.run("""
                INSERT INTO queues (repository_id, status, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                """, queue.repositoryID, queue.status.rawValue, now.timeIntervalSince1970, now.timeIntervalSince1970)

                let newID = Int(connection.lastInsertRowid)
                return Queue(
                    id: newID,
                    repositoryID: queue.repositoryID,
                    status: queue.status,
                    createdAt: now,
                    updatedAt: now
                )
            } else {
                // Update existing queue
                try connection.run("""
                UPDATE queues
                SET repository_id = ?, status = ?, updated_at = ?
                WHERE id = ?
                """, queue.repositoryID, queue.status.rawValue, now.timeIntervalSince1970, queue.id)

                return Queue(
                    id: queue.id,
                    repositoryID: queue.repositoryID,
                    status: queue.status,
                    createdAt: queue.createdAt,
                    updatedAt: now
                )
            }
        }
    }

    public func delete(id: Int) async throws {
        try await database.withConnection { connection in
            // First delete all entries
            try connection.run("DELETE FROM queue_entries WHERE queue_id = ?", id)
            // Then delete the queue
            try connection.run("DELETE FROM queues WHERE id = ?", id)
        }
    }

    public func getEntries(queueID: Int) async throws -> [QueueEntry] {
        try await database.withConnection { connection in
            let query = """
            SELECT id, queue_id, pull_request_id, position, status, added_at
            FROM queue_entries
            WHERE queue_id = ?
            ORDER BY position ASC
            """
            let rowIterator = try connection.prepareRowIterator(query, bindings: queueID)
            var entries: [QueueEntry] = []

            while let row = try rowIterator.failableNext() {
                entries.append(try self.mapRowToQueueEntry(row))
            }

            return entries
        }
    }

    public func addEntry(_ entry: QueueEntry) async throws -> QueueEntry {
        try await database.withConnection { connection in
            let now = Date()

            try connection.run("""
            INSERT INTO queue_entries (queue_id, pull_request_id, position, status, added_at)
            VALUES (?, ?, ?, ?, ?)
            """, entry.queueID, entry.pullRequestID, entry.position, entry.status.rawValue, now.timeIntervalSince1970)

            let newID = Int(connection.lastInsertRowid)
            return QueueEntry(
                id: newID,
                queueID: entry.queueID,
                pullRequestID: entry.pullRequestID,
                position: entry.position,
                status: entry.status,
                addedAt: now
            )
        }
    }

    public func updateEntry(_ entry: QueueEntry) async throws {
        try await database.withConnection { connection in
            try connection.run("""
            UPDATE queue_entries
            SET status = ?, position = ?
            WHERE id = ?
            """, entry.status.rawValue, entry.position, entry.id)
        }
    }

    public func removeEntry(id: Int) async throws {
        try await database.withConnection { connection in
            try connection.run("DELETE FROM queue_entries WHERE id = ?", id)
        }
    }

    public func reorderEntries(queueID: Int, entryIDs: [Int]) async throws {
        try await database.withConnection { connection in
            for (index, entryID) in entryIDs.enumerated() {
                try connection.run("""
                UPDATE queue_entries
                SET position = ?
                WHERE id = ? AND queue_id = ?
                """, index, entryID, queueID)
            }
        }
    }

    // MARK: - Private Helpers

    private func mapRowToQueue(_ row: Row) throws -> Queue {
        let idCol = Expression<Int64>("id")
        let repositoryIDCol = Expression<Int64>("repository_id")
        let statusCol = Expression<String>("status")
        let createdAtCol = Expression<Double>("created_at")
        let updatedAtCol = Expression<Double>("updated_at")

        return Queue(
            id: Int(try row.get(idCol)),
            repositoryID: Int(try row.get(repositoryIDCol)),
            status: QueueStatus(rawValue: try row.get(statusCol)) ?? .active,
            createdAt: Date(timeIntervalSince1970: try row.get(createdAtCol)),
            updatedAt: Date(timeIntervalSince1970: try row.get(updatedAtCol))
        )
    }

    private func mapRowToQueueEntry(_ row: Row) throws -> QueueEntry {
        let idCol = Expression<Int64>("id")
        let queueIDCol = Expression<Int64>("queue_id")
        let pullRequestIDCol = Expression<Int64>("pull_request_id")
        let positionCol = Expression<Int64>("position")
        let statusCol = Expression<String>("status")
        let addedAtCol = Expression<Double>("added_at")

        return QueueEntry(
            id: Int(try row.get(idCol)),
            queueID: Int(try row.get(queueIDCol)),
            pullRequestID: Int(try row.get(pullRequestIDCol)),
            position: Int(try row.get(positionCol)),
            status: QueueEntryStatus(rawValue: try row.get(statusCol)) ?? .pending,
            addedAt: Date(timeIntervalSince1970: try row.get(addedAtCol))
        )
    }
}

// MARK: - SQLite Pull Request Repository Implementation

public final class SQLitePullRequestRepository: PullRequestRepository {
    private let database: SQLiteConnectionManager
    private let logger: Logger

    public init(database: SQLiteConnectionManager, logger: Logger) {
        self.database = database
        self.logger = logger
    }

    public func get(id: Int) async throws -> PullRequest {
        try await database.withConnection { connection in
            let query = """
            SELECT id, repository_id, number, title, head_branch, base_branch, head_sha, status, created_at, updated_at
            FROM pull_requests
            WHERE id = ?
            """
            let rowIterator = try connection.prepareRowIterator(query, bindings: id)

            guard let row = try rowIterator.failableNext() else {
                throw Abort(.notFound, reason: "Pull request not found")
            }

            return try self.mapRowToPullRequest(row)
        }
    }

    public func getByNumber(repositoryID: Int, number: Int) async throws -> PullRequest {
        try await database.withConnection { connection in
            let query = """
            SELECT id, repository_id, number, title, head_branch, base_branch, head_sha, status, created_at, updated_at
            FROM pull_requests
            WHERE repository_id = ? AND number = ?
            """
            let rowIterator = try connection.prepareRowIterator(query, bindings: repositoryID, number)

            guard let row = try rowIterator.failableNext() else {
                throw Abort(.notFound, reason: "Pull request not found")
            }

            return try self.mapRowToPullRequest(row)
        }
    }

    public func save(_ pr: PullRequest) async throws -> PullRequest {
        try await database.withConnection { connection in
            let now = Date()

            if pr.id == 0 {
                // Insert new PR (use INSERT OR REPLACE to handle duplicates on repository_id + number)
                try connection.run("""
                INSERT OR REPLACE INTO pull_requests (repository_id, number, title, head_branch, base_branch, head_sha, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, pr.repositoryID, pr.number, pr.title, pr.headBranch, pr.baseBranch, pr.headSHA, pr.status.rawValue, now.timeIntervalSince1970, now.timeIntervalSince1970)

                let newID = Int(connection.lastInsertRowid)
                return PullRequest(
                    id: newID,
                    repositoryID: pr.repositoryID,
                    number: pr.number,
                    title: pr.title,
                    headBranch: pr.headBranch,
                    baseBranch: pr.baseBranch,
                    headSHA: pr.headSHA,
                    status: pr.status,
                    createdAt: now,
                    updatedAt: now
                )
            } else {
                // Update existing PR
                try connection.run("""
                UPDATE pull_requests
                SET repository_id = ?, number = ?, title = ?, head_branch = ?, base_branch = ?, head_sha = ?, status = ?, updated_at = ?
                WHERE id = ?
                """, pr.repositoryID, pr.number, pr.title, pr.headBranch, pr.baseBranch, pr.headSHA, pr.status.rawValue, now.timeIntervalSince1970, pr.id)

                return PullRequest(
                    id: pr.id,
                    repositoryID: pr.repositoryID,
                    number: pr.number,
                    title: pr.title,
                    headBranch: pr.headBranch,
                    baseBranch: pr.baseBranch,
                    headSHA: pr.headSHA,
                    status: pr.status,
                    createdAt: pr.createdAt,
                    updatedAt: now
                )
            }
        }
    }

    public func delete(id: Int) async throws {
        try await database.withConnection { connection in
            try connection.run("DELETE FROM pull_requests WHERE id = ?", id)
        }
    }

    // MARK: - Private Helpers

    private func mapRowToPullRequest(_ row: Row) throws -> PullRequest {
        let idCol = Expression<Int64>("id")
        let repositoryIDCol = Expression<Int64>("repository_id")
        let numberCol = Expression<Int64>("number")
        let titleCol = Expression<String>("title")
        let headBranchCol = Expression<String>("head_branch")
        let baseBranchCol = Expression<String>("base_branch")
        let headSHACol = Expression<String>("head_sha")
        let statusCol = Expression<String>("status")
        let createdAtCol = Expression<Double>("created_at")
        let updatedAtCol = Expression<Double>("updated_at")

        return PullRequest(
            id: Int(try row.get(idCol)),
            repositoryID: Int(try row.get(repositoryIDCol)),
            number: Int(try row.get(numberCol)),
            title: try row.get(titleCol),
            headBranch: try row.get(headBranchCol),
            baseBranch: try row.get(baseBranchCol),
            headSHA: try row.get(headSHACol),
            status: PRStatus(rawValue: try row.get(statusCol)) ?? .open,
            createdAt: Date(timeIntervalSince1970: try row.get(createdAtCol)),
            updatedAt: Date(timeIntervalSince1970: try row.get(updatedAtCol))
        )
    }
}
