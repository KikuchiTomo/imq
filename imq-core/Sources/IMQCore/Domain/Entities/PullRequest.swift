import Foundation

/// Pull Request entity representing a GitHub pull request
///
/// This entity contains all the essential information about a pull request
/// that is needed for queue management, conflict detection, and merging.
/// It maintains immutable state and is designed for concurrent access.
public struct PullRequest: Codable, Sendable, Identifiable {
    // MARK: - Properties

    /// Unique identifier for the pull request
    public let id: PullRequestID

    /// Repository this pull request belongs to
    public let repository: Repository

    /// Pull request number (GitHub's PR number)
    public let number: Int

    /// Pull request title
    public let title: String

    /// Login name of the pull request author
    public let authorLogin: String

    /// Base branch (target branch for merging)
    public let baseBranch: BranchName

    /// Head branch (source branch with changes)
    public let headBranch: BranchName

    /// SHA of the head commit
    public let headSHA: CommitSHA

    /// Whether the pull request has conflicts with the base branch
    public let isConflicted: Bool

    /// Whether the pull request is up to date with the base branch
    public let isUpToDate: Bool

    /// Timestamp when the pull request was created
    public let createdAt: Date

    /// Timestamp when the pull request was last updated
    public let updatedAt: Date

    // MARK: - Initialization

    /// Creates a new PullRequest entity
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the pull request
    ///   - repository: Repository this PR belongs to
    ///   - number: Pull request number
    ///   - title: Pull request title
    ///   - authorLogin: Author's GitHub login
    ///   - baseBranch: Target branch name
    ///   - headBranch: Source branch name
    ///   - headSHA: SHA of the head commit
    ///   - isConflicted: Whether the PR has conflicts
    ///   - isUpToDate: Whether the PR is up to date
    ///   - createdAt: Creation timestamp
    ///   - updatedAt: Last update timestamp
    public init(
        id: PullRequestID,
        repository: Repository,
        number: Int,
        title: String,
        authorLogin: String,
        baseBranch: BranchName,
        headBranch: BranchName,
        headSHA: CommitSHA,
        isConflicted: Bool,
        isUpToDate: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repository = repository
        self.number = number
        self.title = title
        self.authorLogin = authorLogin
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.isConflicted = isConflicted
        self.isUpToDate = isUpToDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Equatable

extension PullRequest: Equatable {
    public static func == (lhs: PullRequest, rhs: PullRequest) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension PullRequest: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Computed Properties

extension PullRequest {
    /// Returns true if the pull request is ready for merging
    /// (no conflicts and up to date with base)
    public var isReadyForMerge: Bool {
        !isConflicted && isUpToDate
    }

    /// Returns true if the pull request needs updating
    public var needsUpdate: Bool {
        !isUpToDate || isConflicted
    }
}
