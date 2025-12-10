import Foundation
import Vapor

/// Queue Data Transfer Object
public struct QueueDTO: Content {
    public let id: String
    public let repositoryID: String
    public let baseBranch: String
    public let entriesCount: Int
    public let createdAt: Date

    public init(id: String, repositoryID: String, baseBranch: String, entriesCount: Int, createdAt: Date) {
        self.id = id
        self.repositoryID = repositoryID
        self.baseBranch = baseBranch
        self.entriesCount = entriesCount
        self.createdAt = createdAt
    }
}

/// Queue Entry Data Transfer Object
public struct QueueEntryDTO: Content {
    public let id: String
    public let position: Int
    public let status: String
    public let pullRequest: PullRequestDTO
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, position: Int, status: String, pullRequest: PullRequestDTO, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.position = position
        self.status = status
        self.pullRequest = pullRequest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Pull Request Data Transfer Object
public struct PullRequestDTO: Content {
    public let number: Int
    public let title: String
    public let author: String
    public let headSHA: String
    public let headBranch: String
    public let baseBranch: String
    public let url: String

    public init(number: Int, title: String, author: String, headSHA: String, headBranch: String, baseBranch: String, url: String) {
        self.number = number
        self.title = title
        self.author = author
        self.headSHA = headSHA
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.url = url
    }
}

/// Create Queue Request
public struct CreateQueueRequest: Content {
    public let repositoryID: String
    public let baseBranch: String

    public init(repositoryID: String, baseBranch: String) {
        self.repositoryID = repositoryID
        self.baseBranch = baseBranch
    }
}

/// Add Entry Request
public struct AddEntryRequest: Content {
    public let prNumber: Int

    public init(prNumber: Int) {
        self.prNumber = prNumber
    }
}

/// Reorder Queue Request
public struct ReorderQueueRequest: Content {
    public let entryIDs: [String]

    public init(entryIDs: [String]) {
        self.entryIDs = entryIDs
    }
}
