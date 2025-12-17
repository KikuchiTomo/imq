import Foundation
import Vapor

// MARK: - Server Layer Models

/// Simple Queue model for server layer
public struct Queue: Content, Sendable {
    public var id: Int
    public let repositoryID: Int
    public var status: QueueStatus
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int,
        repositoryID: Int,
        status: QueueStatus,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Queue status
public enum QueueStatus: String, Content, Sendable {
    case active
    case paused
    case inactive
}

/// Simple QueueEntry model for server layer
public struct QueueEntry: Content, Sendable {
    public var id: Int
    public let queueID: Int
    public let pullRequestID: Int
    public let position: Int
    public var status: QueueEntryStatus
    public let addedAt: Date

    public init(
        id: Int,
        queueID: Int,
        pullRequestID: Int,
        position: Int,
        status: QueueEntryStatus,
        addedAt: Date
    ) {
        self.id = id
        self.queueID = queueID
        self.pullRequestID = pullRequestID
        self.position = position
        self.status = status
        self.addedAt = addedAt
    }
}

/// Queue entry status
public enum QueueEntryStatus: String, Content, Sendable {
    case pending
    case processing
    case completed
    case failed
    case cancelled
}

/// Simple PullRequest model for server layer
public struct PullRequest: Content, Sendable {
    public var id: Int
    public let repositoryID: Int
    public let number: Int
    public let title: String
    public let headBranch: String
    public let baseBranch: String
    public let headSHA: String
    public var status: PRStatus
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int,
        repositoryID: Int,
        number: Int,
        title: String,
        headBranch: String,
        baseBranch: String,
        headSHA: String,
        status: PRStatus,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.number = number
        self.title = title
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.headSHA = headSHA
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Pull request status
public enum PRStatus: String, Content, Sendable {
    case open
    case merged
    case closed
}

// MARK: - Repository Protocols

/// Queue repository protocol for server layer
public protocol QueueRepository: Sendable {
    func getAll() async throws -> [Queue]
    func get(id: Int) async throws -> Queue
    func save(_ queue: Queue) async throws -> Queue
    func delete(id: Int) async throws
    func getEntries(queueID: Int) async throws -> [QueueEntry]
    func addEntry(_ entry: QueueEntry) async throws -> QueueEntry
    func updateEntry(_ entry: QueueEntry) async throws
    func removeEntry(id: Int) async throws
    func reorderEntries(queueID: Int, entryIDs: [Int]) async throws
}

/// Pull request repository protocol for server layer
public protocol PullRequestRepository: Sendable {
    func get(id: Int) async throws -> PullRequest
    func getByNumber(repositoryID: Int, number: Int) async throws -> PullRequest
    func save(_ pr: PullRequest) async throws -> PullRequest
    func delete(id: Int) async throws
}

// MARK: - API DTOs

/// Simple Queue DTO for API responses
public struct QueueDTO: Content, Sendable {
    public let id: Int
    public let repositoryID: Int
    public let status: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: Int, repositoryID: Int, status: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.repositoryID = repositoryID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Simple QueueEntry DTO for API responses
public struct QueueEntryDTO: Content, Sendable {
    public let id: Int
    public let queueID: Int
    public let pullRequestID: Int
    public let position: Int
    public let status: String
    public let addedAt: Date

    public init(id: Int, queueID: Int, pullRequestID: Int, position: Int, status: String, addedAt: Date) {
        self.id = id
        self.queueID = queueID
        self.pullRequestID = pullRequestID
        self.position = position
        self.status = status
        self.addedAt = addedAt
    }
}

/// API Response wrapper
public struct APIResponse<T: Content>: Content {
    public let success: Bool
    public let data: T?
    public let error: String?

    public init(success: Bool, data: T? = nil, error: String? = nil) {
        self.success = success
        self.data = data
        self.error = error
    }

    public static func success(_ data: T) -> APIResponse<T> {
        return APIResponse(success: true, data: data)
    }

    public static func failure(_ error: String) -> APIResponse<T> {
        return APIResponse(success: false, error: error)
    }
}

/// Request DTOs
public struct CreateQueueRequest: Content {
    public let repositoryID: Int
}

public struct AddEntryRequest: Content {
    public let pullRequestID: Int
}

public struct ReorderQueueRequest: Content {
    public let entryIDs: [Int]
}

/// Configuration DTO for API responses
public struct ConfigurationDTO: Content {
    public let triggerLabel: String
    public let webhookSecret: String?
    public let webhookProxyUrl: String?
    public let checkConfigurations: [String]
    public let notificationTemplates: [String]

    public init(
        triggerLabel: String,
        webhookSecret: String?,
        webhookProxyUrl: String?,
        checkConfigurations: [String],
        notificationTemplates: [String]
    ) {
        self.triggerLabel = triggerLabel
        self.webhookSecret = webhookSecret
        self.webhookProxyUrl = webhookProxyUrl
        self.checkConfigurations = checkConfigurations
        self.notificationTemplates = notificationTemplates
    }
}
