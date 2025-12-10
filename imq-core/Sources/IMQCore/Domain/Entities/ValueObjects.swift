import Foundation

// MARK: - ID Value Objects

/// Repository ID value object
public struct RepositoryID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String = UUID().uuidString) {
        self.value = value
    }

    public var description: String {
        value
    }
}

/// Pull Request ID value object
public struct PullRequestID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String = UUID().uuidString) {
        self.value = value
    }

    public var description: String {
        value
    }
}

/// Queue ID value object
public struct QueueID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String = UUID().uuidString) {
        self.value = value
    }

    public var description: String {
        value
    }
}

/// Queue Entry ID value object
public struct QueueEntryID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String = UUID().uuidString) {
        self.value = value
    }

    public var description: String {
        value
    }
}

/// Check ID value object
public struct CheckID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String = UUID().uuidString) {
        self.value = value
    }

    public var description: String {
        value
    }
}

// MARK: - Status Enums

/// Queue Entry Status
public enum QueueEntryStatus: String, Codable, Sendable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
}

/// Check Status
public enum CheckStatus: String, Codable, Sendable {
    case pending = "pending"
    case running = "running"
    case passed = "passed"
    case failed = "failed"
    case cancelled = "cancelled"
    case timedOut = "timed_out"
}

// MARK: - Branch Name Value Object

/// Git branch name value object
public struct BranchName: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String {
        value
    }
}

// MARK: - SHA Value Object

/// Git commit SHA value object
public struct CommitSHA: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String {
        value
    }

    /// Validate SHA format (40 hex characters)
    public var isValid: Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit }
    }
}
