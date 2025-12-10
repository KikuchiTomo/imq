import Foundation

/// Queue entity representing a merge queue for a specific branch
///
/// This entity manages the queue of pull requests waiting to be merged
/// into a specific base branch. It maintains order and provides operations
/// for queue manipulation while ensuring consistency.
public struct Queue: Codable, Sendable, Identifiable {
    // MARK: - Properties

    /// Unique identifier for the queue
    public let id: QueueID

    /// Repository this queue belongs to
    public let repository: Repository

    /// Base branch name this queue is for
    public let baseBranch: BranchName

    /// Ordered list of queue entries (front to back)
    public let entries: [QueueEntry]

    /// Timestamp when the queue was created
    public let createdAt: Date

    // MARK: - Initialization

    /// Creates a new Queue entity
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the queue
    ///   - repository: Repository this queue belongs to
    ///   - baseBranch: Base branch name
    ///   - entries: Initial queue entries
    ///   - createdAt: Creation timestamp
    public init(
        id: QueueID,
        repository: Repository,
        baseBranch: BranchName,
        entries: [QueueEntry] = [],
        createdAt: Date
    ) {
        self.id = id
        self.repository = repository
        self.baseBranch = baseBranch
        self.entries = entries
        self.createdAt = createdAt
    }
}

// MARK: - Equatable

extension Queue: Equatable {
    public static func == (lhs: Queue, rhs: Queue) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension Queue: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Computed Properties

extension Queue {
    /// Returns the number of entries in the queue
    public var count: Int {
        entries.count
    }

    /// Returns true if the queue is empty
    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// Returns the front entry (next to be processed)
    public var front: QueueEntry? {
        entries.first
    }

    /// Returns all pending entries
    public var pendingEntries: [QueueEntry] {
        entries.filter { $0.status == .pending }
    }

    /// Returns all running entries
    public var runningEntries: [QueueEntry] {
        entries.filter { $0.status == .running }
    }

    /// Returns all completed entries
    public var completedEntries: [QueueEntry] {
        entries.filter { $0.status == .completed }
    }

    /// Returns all failed entries
    public var failedEntries: [QueueEntry] {
        entries.filter { $0.status == .failed }
    }
}

// MARK: - Queue Operations

extension Queue {
    /// Adds a pull request to the back of the queue
    ///
    /// - Parameter pullRequest: Pull request to enqueue
    /// - Returns: New queue with the entry added and updated entry
    public func enqueue(_ pullRequest: PullRequest) -> (queue: Queue, entry: QueueEntry) {
        let position = entries.count
        let entry = QueueEntry(
            id: QueueEntryID(),
            queueID: id,
            pullRequest: pullRequest,
            position: position,
            status: .pending,
            enqueuedAt: Date()
        )

        let newEntries = entries + [entry]
        let newQueue = Queue(
            id: id,
            repository: repository,
            baseBranch: baseBranch,
            entries: newEntries,
            createdAt: createdAt
        )

        return (newQueue, entry)
    }

    /// Removes and returns the front entry from the queue
    ///
    /// - Returns: New queue with front entry removed and the removed entry, or nil if empty
    public func dequeue() -> (queue: Queue, entry: QueueEntry)? {
        guard let firstEntry = entries.first else {
            return nil
        }

        let remainingEntries = Array(entries.dropFirst())
        let reindexedEntries = remainingEntries.enumerated().map { index, entry in
            entry.withPosition(index)
        }

        let newQueue = Queue(
            id: id,
            repository: repository,
            baseBranch: baseBranch,
            entries: reindexedEntries,
            createdAt: createdAt
        )

        return (newQueue, firstEntry)
    }

    /// Removes a specific entry from the queue
    ///
    /// - Parameter entryID: ID of the entry to remove
    /// - Returns: New queue with entry removed and the removed entry, or nil if not found
    public func remove(entryID: QueueEntryID) -> (queue: Queue, entry: QueueEntry)? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return nil
        }

        let removedEntry = entries[index]
        var newEntries = entries
        newEntries.remove(at: index)

        // Reindex remaining entries
        let reindexedEntries = newEntries.enumerated().map { idx, entry in
            entry.withPosition(idx)
        }

        let newQueue = Queue(
            id: id,
            repository: repository,
            baseBranch: baseBranch,
            entries: reindexedEntries,
            createdAt: createdAt
        )

        return (newQueue, removedEntry)
    }

    /// Updates a specific entry in the queue
    ///
    /// - Parameter entry: Updated entry
    /// - Returns: New queue with entry updated, or nil if entry not found
    public func updateEntry(_ entry: QueueEntry) -> Queue? {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return nil
        }

        var newEntries = entries
        newEntries[index] = entry

        return Queue(
            id: id,
            repository: repository,
            baseBranch: baseBranch,
            entries: newEntries,
            createdAt: createdAt
        )
    }

    /// Finds an entry by its ID
    ///
    /// - Parameter entryID: ID of the entry to find
    /// - Returns: The entry if found, nil otherwise
    public func findEntry(by entryID: QueueEntryID) -> QueueEntry? {
        entries.first { $0.id == entryID }
    }

    /// Finds an entry by pull request ID
    ///
    /// - Parameter pullRequestID: ID of the pull request
    /// - Returns: The entry if found, nil otherwise
    public func findEntry(byPullRequest pullRequestID: PullRequestID) -> QueueEntry? {
        entries.first { $0.pullRequest.id == pullRequestID }
    }

    /// Returns true if the queue contains a pull request
    ///
    /// - Parameter pullRequestID: ID of the pull request to check
    /// - Returns: True if the pull request is in the queue
    public func contains(pullRequest pullRequestID: PullRequestID) -> Bool {
        entries.contains { $0.pullRequest.id == pullRequestID }
    }

    /// Reorders entries by updating their positions
    ///
    /// - Parameter newOrder: Array of entry IDs in desired order
    /// - Returns: New queue with reordered entries, or nil if invalid order
    public func reorder(_ newOrder: [QueueEntryID]) -> Queue? {
        // Validate that all entries are present
        guard newOrder.count == entries.count else { return nil }
        guard Set(newOrder) == Set(entries.map { $0.id }) else { return nil }

        let reorderedEntries = newOrder.compactMap { entryID in
            entries.first { $0.id == entryID }
        }.enumerated().map { index, entry in
            entry.withPosition(index)
        }

        guard reorderedEntries.count == entries.count else { return nil }

        return Queue(
            id: id,
            repository: repository,
            baseBranch: baseBranch,
            entries: reorderedEntries,
            createdAt: createdAt
        )
    }
}
