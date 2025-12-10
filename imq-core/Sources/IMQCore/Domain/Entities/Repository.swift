import Foundation

/// Repository entity representing a GitHub repository
///
/// This entity encapsulates all the essential information about a repository
/// that is being managed by IMQ. It maintains immutable state and serves as
/// the foundation for queue management and PR processing.
public struct Repository: Codable, Sendable, Identifiable {
    // MARK: - Properties

    /// Unique identifier for the repository
    public let id: RepositoryID

    /// Repository owner (username or organization name)
    public let owner: String

    /// Repository name
    public let name: String

    /// Full repository name (owner/name)
    public let fullName: String

    /// Default branch name (typically "main" or "master")
    public let defaultBranch: BranchName

    /// Timestamp when the repository was created
    public let createdAt: Date

    // MARK: - Initialization

    /// Creates a new Repository entity
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the repository
    ///   - owner: Repository owner name
    ///   - name: Repository name
    ///   - fullName: Full repository name (owner/name)
    ///   - defaultBranch: Default branch name
    ///   - createdAt: Creation timestamp
    public init(
        id: RepositoryID,
        owner: String,
        name: String,
        fullName: String,
        defaultBranch: BranchName,
        createdAt: Date
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.fullName = fullName
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
    }
}

// MARK: - Equatable

extension Repository: Equatable {
    public static func == (lhs: Repository, rhs: Repository) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension Repository: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
