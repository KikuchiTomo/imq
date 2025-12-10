import Foundation
import Logging

/// Implementation of QueueProcessingUseCase protocol
/// Orchestrates the complete queue processing workflow
actor QueueProcessingUseCaseImpl: QueueProcessingUseCase {
    // MARK: - Properties

    private let queueRepository: QueueRepository
    private let conflictDetectionUseCase: ConflictDetectionUseCase
    private let prUpdateUseCase: PRUpdateUseCase
    private let checkExecutionUseCase: CheckExecutionUseCase
    private let mergingUseCase: MergingUseCase
    private let logger: Logger

    // MARK: - Initialization

    /// Initialize queue processing use case
    /// - Parameters:
    ///   - queueRepository: Repository for queue operations
    ///   - conflictDetectionUseCase: Use case for conflict detection
    ///   - prUpdateUseCase: Use case for PR updates
    ///   - checkExecutionUseCase: Use case for check execution
    ///   - mergingUseCase: Use case for merging PRs
    ///   - logger: Logger for structured logging
    init(
        queueRepository: QueueRepository,
        conflictDetectionUseCase: ConflictDetectionUseCase,
        prUpdateUseCase: PRUpdateUseCase,
        checkExecutionUseCase: CheckExecutionUseCase,
        mergingUseCase: MergingUseCase,
        logger: Logger
    ) {
        self.queueRepository = queueRepository
        self.conflictDetectionUseCase = conflictDetectionUseCase
        self.prUpdateUseCase = prUpdateUseCase
        self.checkExecutionUseCase = checkExecutionUseCase
        self.mergingUseCase = mergingUseCase
        self.logger = logger
    }

    // MARK: - QueueProcessingUseCase Protocol Implementation

    func processQueue(
        for baseBranch: BranchName,
        in repository: Repository
    ) async throws {
        logger.info(
            "Starting queue processing",
            metadata: [
                "baseBranch": .string(baseBranch.value),
                "repo": .string(repository.name)
            ]
        )

        // Find the queue for this base branch
        guard let queue = try await queueRepository.find(
            baseBranch: baseBranch,
            repository: repository.id
        ) else {
            logger.error(
                "Queue not found",
                metadata: [
                    "baseBranch": .string(baseBranch.value),
                    "repo": .string(repository.name)
                ]
            )
            throw QueueProcessingError.queueNotFound(
                baseBranch: baseBranch.value,
                repository: repository.name
            )
        }

        // Check if there are any pending entries
        guard !queue.pendingEntries.isEmpty else {
            logger.info(
                "No pending entries in queue",
                metadata: ["baseBranch": .string(baseBranch.value)]
            )
            throw QueueProcessingError.noPendingEntries
        }

        // Process the first pending entry
        guard let nextEntry = queue.pendingEntries.first else {
            logger.info(
                "No pending entries to process",
                metadata: ["baseBranch": .string(baseBranch.value)]
            )
            throw QueueProcessingError.noPendingEntries
        }

        logger.info(
            "Processing queue entry",
            metadata: [
                "entryID": .string(nextEntry.id.value),
                "pr": .stringConvertible(nextEntry.pullRequest.number),
                "position": .stringConvertible(nextEntry.position)
            ]
        )

        // Process the entry through all stages
        do {
            try await processEntry(nextEntry, queue: queue)
        } catch {
            logger.error(
                "Queue processing failed",
                metadata: [
                    "entryID": .string(nextEntry.id.value),
                    "error": .string(error.localizedDescription)
                ]
            )
            throw error
        }

        logger.info(
            "Queue processing completed",
            metadata: ["baseBranch": .string(baseBranch.value)]
        )
    }

    // MARK: - Private Helper Methods

    /// Process a single queue entry through all stages
    private func processEntry(_ entry: QueueEntry, queue: Queue) async throws {
        // Stage 1: Mark as running
        let runningEntry = entry.withStarted()
        try await queueRepository.updateEntry(runningEntry)

        logger.info(
            "Queue entry marked as running",
            metadata: [
                "entryID": .string(entry.id.value),
                "pr": .stringConvertible(entry.pullRequest.number)
            ]
        )

        do {
            // Stage 2: Detect conflicts
            try await detectConflictsStage(entry: runningEntry)

            // Stage 3: Update PR if needed
            let updatedEntry = try await updatePRStage(entry: runningEntry)

            // Stage 4: Execute checks
            try await executeChecksStage(entry: updatedEntry)

            // Stage 5: Merge PR
            try await mergeStage(entry: updatedEntry)

            // Mark as completed
            let completedEntry = updatedEntry.withCompleted(status: .completed)
            try await queueRepository.updateEntry(completedEntry)

            logger.info(
                "Queue entry processing completed successfully",
                metadata: [
                    "entryID": .string(entry.id.value),
                    "pr": .stringConvertible(entry.pullRequest.number)
                ]
            )
        } catch {
            // Mark as failed
            let failedEntry = runningEntry.withCompleted(status: .failed)
            try await queueRepository.updateEntry(failedEntry)

            logger.error(
                "Queue entry processing failed",
                metadata: [
                    "entryID": .string(entry.id.value),
                    "pr": .stringConvertible(entry.pullRequest.number),
                    "error": .string(error.localizedDescription)
                ]
            )

            throw error
        }
    }

    /// Stage 1: Detect conflicts
    private func detectConflictsStage(entry: QueueEntry) async throws {
        logger.info(
            "Stage: Detecting conflicts",
            metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
        )

        do {
            let conflictResult = try await conflictDetectionUseCase.detectConflicts(
                for: entry.pullRequest
            )

            switch conflictResult {
            case .noConflict:
                logger.info(
                    "No conflicts detected",
                    metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
                )
            case .hasConflict:
                logger.error(
                    "Conflicts detected - cannot proceed",
                    metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
                )
                throw QueueProcessingError.conflictDetectionFailed(
                    NSError(
                        domain: "ConflictDetection",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Pull request has conflicts"]
                    )
                )
            case .unknown(let error):
                logger.error(
                    "Conflict detection failed with unknown error",
                    metadata: [
                        "pr": .stringConvertible(entry.pullRequest.number),
                        "error": .string(error.localizedDescription)
                    ]
                )
                throw QueueProcessingError.conflictDetectionFailed(error)
            }
        } catch let error as QueueProcessingError {
            throw error
        } catch {
            throw QueueProcessingError.conflictDetectionFailed(error)
        }
    }

    /// Stage 2: Update PR branch
    private func updatePRStage(entry: QueueEntry) async throws -> QueueEntry {
        logger.info(
            "Stage: Updating PR branch",
            metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
        )

        do {
            let updateResult = try await prUpdateUseCase.updatePR(entry.pullRequest)

            switch updateResult {
            case .updated(let newHeadSHA):
                logger.info(
                    "PR branch updated successfully",
                    metadata: [
                        "pr": .stringConvertible(entry.pullRequest.number),
                        "newHeadSHA": .string(newHeadSHA)
                    ]
                )

                // Update the entry with new HEAD SHA if available and not empty
                if !newHeadSHA.isEmpty {
                    let updatedPR = PullRequest(
                        id: entry.pullRequest.id,
                        repository: entry.pullRequest.repository,
                        number: entry.pullRequest.number,
                        title: entry.pullRequest.title,
                        authorLogin: entry.pullRequest.authorLogin,
                        baseBranch: entry.pullRequest.baseBranch,
                        headBranch: entry.pullRequest.headBranch,
                        headSHA: CommitSHA(newHeadSHA),
                        isConflicted: false,
                        isUpToDate: true,
                        createdAt: entry.pullRequest.createdAt,
                        updatedAt: Date()
                    )
                    return entry.withPullRequest(updatedPR)
                }
                return entry

            case .alreadyUpToDate:
                logger.info(
                    "PR branch already up to date",
                    metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
                )
                return entry

            case .failed(let error):
                logger.error(
                    "PR branch update failed",
                    metadata: [
                        "pr": .stringConvertible(entry.pullRequest.number),
                        "error": .string(error.localizedDescription)
                    ]
                )
                throw QueueProcessingError.prUpdateFailed(error)
            }
        } catch let error as QueueProcessingError {
            throw error
        } catch {
            throw QueueProcessingError.prUpdateFailed(error)
        }
    }

    /// Stage 3: Execute checks
    private func executeChecksStage(entry: QueueEntry) async throws {
        logger.info(
            "Stage: Executing checks",
            metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
        )

        do {
            // Create a basic check configuration
            // In a real implementation, this would be fetched from configuration
            let checkConfiguration = CheckConfiguration(
                checks: [],
                failFast: true
            )

            // Skip check execution if no checks configured
            if checkConfiguration.isEmpty {
                logger.info(
                    "No checks configured, skipping check execution",
                    metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
                )
                return
            }

            let checkResult = try await checkExecutionUseCase.executeChecks(
                for: entry.pullRequest,
                configuration: checkConfiguration
            )

            if checkResult.allPassed {
                logger.info(
                    "All checks passed",
                    metadata: [
                        "pr": .stringConvertible(entry.pullRequest.number),
                        "totalChecks": .stringConvertible(checkResult.totalChecks)
                    ]
                )
            } else {
                logger.error(
                    "Some checks failed",
                    metadata: [
                        "pr": .stringConvertible(entry.pullRequest.number),
                        "failedChecks": .string(checkResult.failedChecks.joined(separator: ", ")),
                        "failedCount": .stringConvertible(checkResult.failedCount)
                    ]
                )
                throw QueueProcessingError.checkExecutionFailed(
                    NSError(
                        domain: "CheckExecution",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Checks failed: \(checkResult.failedChecks.joined(separator: ", "))"
                        ]
                    )
                )
            }
        } catch let error as QueueProcessingError {
            throw error
        } catch {
            throw QueueProcessingError.checkExecutionFailed(error)
        }
    }

    /// Stage 4: Merge PR
    private func mergeStage(entry: QueueEntry) async throws {
        logger.info(
            "Stage: Merging PR",
            metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
        )

        do {
            try await mergingUseCase.mergePullRequest(entry.pullRequest)

            logger.info(
                "PR merged successfully",
                metadata: ["pr": .stringConvertible(entry.pullRequest.number)]
            )
        } catch {
            logger.error(
                "PR merge failed",
                metadata: [
                    "pr": .stringConvertible(entry.pullRequest.number),
                    "error": .string(error.localizedDescription)
                ]
            )
            throw QueueProcessingError.mergeFailed(error)
        }
    }
}
