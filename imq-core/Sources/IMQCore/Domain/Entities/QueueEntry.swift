import Foundation

/// Queue Entry entity representing a pull request in the merge queue
///
/// This entity tracks the state of a pull request as it progresses through
/// the merge queue. It maintains the position, status, and timestamps for
/// monitoring and processing purposes.
public struct QueueEntry: Codable, Sendable, Identifiable {
    // MARK: - Properties

    /// Unique identifier for the queue entry
    public let id: QueueEntryID

    /// ID of the queue this entry belongs to
    public let queueID: QueueID

    /// Pull request associated with this queue entry
    public let pullRequest: PullRequest

    /// Position in the queue (0-based, where 0 is front of queue)
    public let position: Int

    /// Current status of the queue entry
    public let status: QueueEntryStatus

    /// Timestamp when the entry was added to the queue
    public let enqueuedAt: Date

    /// Timestamp when processing started (nil if not yet started)
    public let startedAt: Date?

    /// Timestamp when processing completed (nil if not yet completed)
    public let completedAt: Date?

    // MARK: - Initialization

    /// Creates a new QueueEntry entity
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the queue entry
    ///   - queueID: ID of the parent queue
    ///   - pullRequest: Pull request for this entry
    ///   - position: Position in the queue
    ///   - status: Current processing status
    ///   - enqueuedAt: Timestamp of enqueue
    ///   - startedAt: Timestamp when processing started
    ///   - completedAt: Timestamp when processing completed
    public init(
        id: QueueEntryID,
        queueID: QueueID,
        pullRequest: PullRequest,
        position: Int,
        status: QueueEntryStatus,
        enqueuedAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.queueID = queueID
        self.pullRequest = pullRequest
        self.position = position
        self.status = status
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

// MARK: - Equatable

extension QueueEntry: Equatable {
    public static func == (lhs: QueueEntry, rhs: QueueEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension QueueEntry: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Computed Properties

extension QueueEntry {
    /// Returns true if the entry is currently being processed
    public var isProcessing: Bool {
        status == .running
    }

    /// Returns true if the entry has finished processing (successfully or not)
    public var isFinished: Bool {
        switch status {
        case .completed, .failed, .cancelled:
            return true
        case .pending, .running:
            return false
        }
    }

    /// Returns the duration the entry has been in the queue
    public var queueDuration: TimeInterval? {
        guard let end = completedAt ?? startedAt else {
            return Date().timeIntervalSince(enqueuedAt)
        }
        return end.timeIntervalSince(enqueuedAt)
    }

    /// Returns the processing duration (time from start to completion)
    public var processingDuration: TimeInterval? {
        guard let started = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(started)
    }

    /// Returns the wait time before processing started
    public var waitTime: TimeInterval? {
        guard let started = startedAt else { return nil }
        return started.timeIntervalSince(enqueuedAt)
    }
}

// MARK: - State Transition Helpers

extension QueueEntry {
    /// Creates a new entry with updated status
    public func withStatus(_ newStatus: QueueEntryStatus) -> QueueEntry {
        QueueEntry(
            id: id,
            queueID: queueID,
            pullRequest: pullRequest,
            position: position,
            status: newStatus,
            enqueuedAt: enqueuedAt,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// Creates a new entry marking processing as started
    public func withStarted(at date: Date = Date()) -> QueueEntry {
        QueueEntry(
            id: id,
            queueID: queueID,
            pullRequest: pullRequest,
            position: position,
            status: .running,
            enqueuedAt: enqueuedAt,
            startedAt: date,
            completedAt: completedAt
        )
    }

    /// Creates a new entry marking processing as completed
    public func withCompleted(status: QueueEntryStatus, at date: Date = Date()) -> QueueEntry {
        QueueEntry(
            id: id,
            queueID: queueID,
            pullRequest: pullRequest,
            position: position,
            status: status,
            enqueuedAt: enqueuedAt,
            startedAt: startedAt,
            completedAt: date
        )
    }

    /// Creates a new entry with updated position
    public func withPosition(_ newPosition: Int) -> QueueEntry {
        QueueEntry(
            id: id,
            queueID: queueID,
            pullRequest: pullRequest,
            position: newPosition,
            status: status,
            enqueuedAt: enqueuedAt,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// Creates a new entry with updated pull request
    public func withPullRequest(_ newPullRequest: PullRequest) -> QueueEntry {
        QueueEntry(
            id: id,
            queueID: queueID,
            pullRequest: newPullRequest,
            position: position,
            status: status,
            enqueuedAt: enqueuedAt,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}
