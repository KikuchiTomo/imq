# Conflict Detection and PR Update Implementation

**Document Version:** 1.0
**Created:** 2025-12-10
**Status:** Implementation Ready
**Related Design Docs:**
- `../docs/03-final-design.md` - Queue processing flow

## Overview

Implementation details for conflict detection using GitHub API and PR update mechanisms. These operations are critical for maintaining queue integrity and ensuring mergeable PRs.

## Critical Files to Create

1. `imq-core/Sources/IMQCore/Domain/UseCases/ConflictDetectionUseCase.swift` - Conflict detection logic
2. `imq-core/Sources/IMQCore/Domain/UseCases/PRUpdateUseCase.swift` - PR update logic
3. `imq-core/Sources/IMQCore/Data/Gateways/GitHubGateway.swift` - GitHub API interactions

## 1. Conflict Detection Use Case

**File:** `imq-core/Sources/IMQCore/Domain/UseCases/ConflictDetectionUseCase.swift`

### Protocol Definition

```swift
import Foundation

/// Use case for detecting conflicts in pull requests
protocol ConflictDetectionUseCase {
    /// Check if a PR has conflicts with its base branch
    /// - Parameters:
    ///   - pullRequest: The pull request to check
    /// - Returns: Conflict detection result
    func detectConflicts(for pullRequest: PullRequest) async throws -> ConflictResult
}

enum ConflictResult {
    case noConflict
    case hasConflict
    case unknown(Error)
}
```

### Implementation

```swift
import Foundation
import Logging

final class ConflictDetectionUseCaseImpl: ConflictDetectionUseCase {
    private let githubGateway: GitHubGateway
    private let logger: Logger

    init(githubGateway: GitHubGateway, logger: Logger) {
        self.githubGateway = githubGateway
        self.logger = logger
    }

    func detectConflicts(for pullRequest: PullRequest) async throws -> ConflictResult {
        logger.debug("Detecting conflicts for PR #\(pullRequest.number)",
                    metadata: ["repo": "\(pullRequest.repository.fullName)",
                              "pr": "\(pullRequest.number)",
                              "base": "\(pullRequest.baseBranch)",
                              "head": "\(pullRequest.headBranch)"])

        do {
            // Fetch PR details from GitHub to get mergeable status
            let prDetails = try await githubGateway.getPullRequest(
                owner: pullRequest.repository.owner,
                repo: pullRequest.repository.name,
                number: pullRequest.number
            )

            // GitHub's mergeable field indicates conflict status
            // nil = calculating, true = no conflict, false = has conflict
            guard let mergeable = prDetails.mergeable else {
                logger.debug("Mergeable status not yet computed, will retry")
                // GitHub is still calculating, retry later
                return .noConflict
            }

            if mergeable {
                logger.debug("No conflicts detected for PR #\(pullRequest.number)")
                return .noConflict
            } else {
                logger.warning("Conflicts detected for PR #\(pullRequest.number)")
                return .hasConflict
            }

        } catch {
            logger.error("Failed to detect conflicts for PR #\(pullRequest.number): \(error)")
            return .unknown(error)
        }
    }
}
```

## 2. PR Update Use Case

**File:** `imq-core/Sources/IMQCore/Domain/UseCases/PRUpdateUseCase.swift`

### Protocol Definition

```swift
import Foundation

/// Use case for updating pull requests
protocol PRUpdateUseCase {
    /// Update a PR's head branch with the latest base branch
    /// - Parameters:
    ///   - pullRequest: The pull request to update
    /// - Returns: Update result
    func updatePR(_ pullRequest: PullRequest) async throws -> PRUpdateResult
}

enum PRUpdateResult {
    case updated(newHeadSHA: String)
    case alreadyUpToDate
    case failed(Error)
}
```

### Implementation

```swift
import Foundation
import Logging

final class PRUpdateUseCaseImpl: PRUpdateUseCase {
    private let githubGateway: GitHubGateway
    private let pullRequestRepository: PullRequestRepository
    private let logger: Logger

    init(
        githubGateway: GitHubGateway,
        pullRequestRepository: PullRequestRepository,
        logger: Logger
    ) {
        self.githubGateway = githubGateway
        self.pullRequestRepository = pullRequestRepository
        self.logger = logger
    }

    func updatePR(_ pullRequest: PullRequest) async throws -> PRUpdateResult {
        logger.info("Updating PR #\(pullRequest.number)",
                   metadata: ["repo": "\(pullRequest.repository.fullName)",
                             "pr": "\(pullRequest.number)",
                             "currentSHA": "\(pullRequest.headSHA)"])

        do {
            // Check if PR is already up to date
            let isUpToDate = try await checkIfUpToDate(pullRequest)

            if isUpToDate {
                logger.debug("PR #\(pullRequest.number) is already up to date")
                return .alreadyUpToDate
            }

            // Update the PR branch using GitHub's update-branch API
            let result = try await githubGateway.updatePullRequestBranch(
                owner: pullRequest.repository.owner,
                repo: pullRequest.repository.name,
                number: pullRequest.number
            )

            logger.info("Successfully updated PR #\(pullRequest.number)",
                       metadata: ["newSHA": "\(result.headSHA)"])

            // Update PR in repository with new SHA
            var updatedPR = pullRequest
            updatedPR.headSHA = result.headSHA
            updatedPR.isUpToDate = true
            updatedPR.updatedAt = Date()

            try await pullRequestRepository.save(updatedPR)

            return .updated(newHeadSHA: result.headSHA)

        } catch let error as GitHubAPIError {
            logger.error("Failed to update PR #\(pullRequest.number): \(error)")
            return .failed(error)

        } catch {
            logger.error("Unexpected error updating PR #\(pullRequest.number): \(error)")
            return .failed(error)
        }
    }

    /// Check if PR branch is up to date with base branch
    private func checkIfUpToDate(_ pullRequest: PullRequest) async throws -> Bool {
        let comparison = try await githubGateway.compareCommits(
            owner: pullRequest.repository.owner,
            repo: pullRequest.repository.name,
            base: pullRequest.baseBranch,
            head: pullRequest.headSHA
        )

        // If comparison shows 0 commits behind, it's up to date
        return comparison.behindBy == 0
    }
}
```

## 3. GitHub Gateway Interface

**File:** `imq-core/Sources/IMQCore/Domain/Gateways/GitHubGateway.swift`

### Protocol Definition

```swift
import Foundation

/// Gateway for GitHub API interactions
protocol GitHubGateway {
    /// Get pull request details
    func getPullRequest(
        owner: String,
        repo: String,
        number: Int
    ) async throws -> GitHubPullRequest

    /// Update pull request branch with latest base
    func updatePullRequestBranch(
        owner: String,
        repo: String,
        number: Int
    ) async throws -> BranchUpdateResult

    /// Compare two commits/branches
    func compareCommits(
        owner: String,
        repo: String,
        base: String,
        head: String
    ) async throws -> CommitComparison
}

// MARK: - Response Types

struct GitHubPullRequest {
    let id: Int
    let number: Int
    let title: String
    let state: String
    let mergeable: Bool?
    let mergeableState: String
    let headSHA: String
    let baseBranch: String
    let headBranch: String
}

struct BranchUpdateResult {
    let headSHA: String
    let message: String
}

struct CommitComparison {
    let aheadBy: Int
    let behindBy: Int
    let status: String  // "ahead", "behind", "identical", "diverged"
}
```

## 4. Complete Queue Processing Use Case Integration

**File:** `imq-core/Sources/IMQCore/Domain/UseCases/QueueProcessingUseCase.swift`

### Implementation with Conflict Detection and PR Update

```swift
import Foundation
import Logging

final class QueueProcessingUseCaseImpl: QueueProcessingUseCase {
    private let queueRepository: QueueRepository
    private let pullRequestRepository: PullRequestRepository
    private let conflictDetectionUseCase: ConflictDetectionUseCase
    private let prUpdateUseCase: PRUpdateUseCase
    private let checkExecutionUseCase: CheckExecutionUseCase
    private let mergingUseCase: MergingUseCase
    private let logger: Logger

    init(
        queueRepository: QueueRepository,
        pullRequestRepository: PullRequestRepository,
        conflictDetectionUseCase: ConflictDetectionUseCase,
        prUpdateUseCase: PRUpdateUseCase,
        checkExecutionUseCase: CheckExecutionUseCase,
        mergingUseCase: MergingUseCase,
        logger: Logger
    ) {
        self.queueRepository = queueRepository
        self.pullRequestRepository = pullRequestRepository
        self.conflictDetectionUseCase = conflictDetectionUseCase
        self.prUpdateUseCase = prUpdateUseCase
        self.checkExecutionUseCase = checkExecutionUseCase
        self.mergingUseCase = mergingUseCase
        self.logger = logger
    }

    func processQueue(for baseBranch: String, in repository: Repository) async throws {
        logger.info("Processing queue",
                   metadata: ["repo": "\(repository.fullName)",
                             "branch": "\(baseBranch)"])

        // Get queue for base branch
        guard let queue = try await queueRepository.find(
            baseBranch: baseBranch,
            repository: repository
        ) else {
            logger.debug("No queue found for \(baseBranch)")
            return
        }

        // Get first pending entry
        guard let entry = queue.entries.first(where: { $0.status == .pending }) else {
            logger.debug("No pending entries in queue")
            return
        }

        logger.info("Processing queue entry",
                   metadata: ["entryID": "\(entry.id)",
                             "pr": "\(entry.pullRequest.number)"])

        // Step 1: Check for conflicts
        let conflictResult = try await conflictDetectionUseCase.detectConflicts(
            for: entry.pullRequest
        )

        switch conflictResult {
        case .hasConflict:
            logger.warning("PR has conflicts, removing from queue")
            try await removeFromQueue(entry: entry, reason: "Conflicts detected")
            return

        case .unknown(let error):
            logger.error("Failed to detect conflicts: \(error)")
            throw error

        case .noConflict:
            break
        }

        // Step 2: Update PR if needed
        let updateResult = try await prUpdateUseCase.updatePR(entry.pullRequest)

        switch updateResult {
        case .updated(let newSHA):
            logger.info("PR updated", metadata: ["newSHA": "\(newSHA)"])
            // Continue with new SHA

        case .alreadyUpToDate:
            logger.debug("PR already up to date")

        case .failed(let error):
            logger.error("Failed to update PR: \(error)")
            throw error
        }

        // Step 3: Execute checks
        try await updateEntryStatus(entry: entry, status: .running)

        let checksResult = try await checkExecutionUseCase.executeChecks(
            for: entry.pullRequest,
            configuration: queue.configuration
        )

        // Step 4: Handle check results
        if checksResult.allPassed {
            logger.info("All checks passed, proceeding to merge")

            // Merge the PR
            try await mergingUseCase.mergePullRequest(entry.pullRequest)

            // Mark entry as completed
            try await updateEntryStatus(entry: entry, status: .completed)

            logger.info("Successfully processed and merged PR",
                       metadata: ["pr": "\(entry.pullRequest.number)"])

        } else {
            logger.warning("Some checks failed, removing from queue")
            try await removeFromQueue(
                entry: entry,
                reason: "Check failures: \(checksResult.failedChecks.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Helper Methods

    private func updateEntryStatus(entry: QueueEntry, status: QueueEntryStatus) async throws {
        var updatedEntry = entry
        updatedEntry.status = status

        if status == .running && entry.startedAt == nil {
            updatedEntry.startedAt = Date()
        } else if status == .completed && entry.completedAt == nil {
            updatedEntry.completedAt = Date()
        }

        try await queueRepository.updateEntry(updatedEntry)
    }

    private func removeFromQueue(entry: QueueEntry, reason: String) async throws {
        logger.info("Removing entry from queue",
                   metadata: ["entryID": "\(entry.id)",
                             "reason": "\(reason)"])

        try await queueRepository.removeEntry(entry.id)

        // Optionally post comment on PR
        // try await githubGateway.postComment(pr: entry.pullRequest, message: reason)
    }
}
```

## Error Handling

### Error Recovery Strategy

```swift
// Conflict detection errors
catch let error as GitHubAPIError {
    switch error {
    case .rateLimitExceeded:
        // Wait and retry
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return try await detectConflicts(for: pullRequest)

    case .notFound:
        // PR was deleted
        return .unknown(error)

    case .httpError(let status, _) where status >= 500:
        // Server error, retry
        return .unknown(error)

    default:
        throw error
    }
}
```

## Testing Strategy

### Unit Tests

```swift
final class ConflictDetectionUseCaseTests: XCTestCase {
    var useCase: ConflictDetectionUseCaseImpl!
    var mockGateway: MockGitHubGateway!

    override func setUp() {
        mockGateway = MockGitHubGateway()
        useCase = ConflictDetectionUseCaseImpl(
            githubGateway: mockGateway,
            logger: Logger(label: "test")
        )
    }

    func testDetectNoConflicts() async throws {
        // Setup mock to return mergeable = true
        mockGateway.mockPRDetails = GitHubPullRequest(
            id: 1,
            number: 123,
            title: "Test PR",
            state: "open",
            mergeable: true,
            mergeableState: "clean",
            headSHA: "abc123",
            baseBranch: "main",
            headBranch: "feature"
        )

        let pr = createTestPR()
        let result = try await useCase.detectConflicts(for: pr)

        switch result {
        case .noConflict:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected no conflict")
        }
    }

    func testDetectConflicts() async throws {
        // Setup mock to return mergeable = false
        mockGateway.mockPRDetails = GitHubPullRequest(
            id: 1,
            number: 123,
            title: "Test PR",
            state: "open",
            mergeable: false,
            mergeableState: "dirty",
            headSHA: "abc123",
            baseBranch: "main",
            headBranch: "feature"
        )

        let pr = createTestPR()
        let result = try await useCase.detectConflicts(for: pr)

        switch result {
        case .hasConflict:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected conflict")
        }
    }
}
```

## Performance Considerations

### Caching

- Cache conflict detection results by SHA
- Avoid redundant API calls for same PR state

### Rate Limiting

- Respect GitHub API rate limits
- Use conditional requests with ETag

### Batch Operations

- Process multiple queue entries in parallel where possible
- Limit concurrent GitHub API calls to avoid rate limiting

---

**Related:** 01-queue-processor-implementation.md, ../check-execution/imps/01-executor-factory-parallel-execution-implementation.md
