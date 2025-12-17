import Vapor
import IMQCore
import Logging
import AsyncHTTPClient

// Import gateway types from IMQCore
typealias GitHubGateway = IMQCore.GitHubGateway

/// Service for processing merge queues
/// Monitors queues and processes pending pull requests
public actor QueueProcessingService {
    // MARK: - Properties

    private let app: Application
    private let githubGateway: GitHubGateway
    private let checkExecutionService: CheckExecutionService
    private let logger: Logger
    private var processingTask: Task<Void, Never>?
    private var isRunning = false
    private let processingInterval: TimeInterval

    // MARK: - Initialization

    init(
        app: Application,
        githubGateway: GitHubGateway,
        checkExecutionService: CheckExecutionService,
        processingInterval: TimeInterval = 10.0,
        logger: Logger
    ) {
        self.app = app
        self.githubGateway = githubGateway
        self.checkExecutionService = checkExecutionService
        self.processingInterval = processingInterval
        self.logger = logger
    }

    // MARK: - Public Methods

    /// Start the queue processing loop
    public func start() {
        guard !isRunning else {
            logger.warning("Queue processing service already running")
            return
        }

        isRunning = true
        logger.info("Starting queue processing service")

        processingTask = Task { [weak self] in
            await self?.processingLoop()
        }
    }

    /// Stop the queue processing loop
    public func stop() async {
        guard isRunning else { return }

        logger.info("Stopping queue processing service")
        isRunning = false
        processingTask?.cancel()
        processingTask = nil
    }

    // MARK: - Private Methods

    private func processingLoop() async {
        while isRunning {
            do {
                try await processAllQueues()
            } catch {
                logger.error("Error processing queues", metadata: [
                    "error": .string(error.localizedDescription)
                ])
            }

            // Wait before next iteration
            try? await Task.sleep(nanoseconds: UInt64(processingInterval * 1_000_000_000))
        }

        logger.info("Queue processing service stopped")
    }

    private func processAllQueues() async throws {
        guard let queueRepo = app.storage[QueueRepositoryKey.self],
              let prRepo = app.storage[PullRequestRepositoryKey.self],
              let configRepo = app.storage[ConfigRepositoryKey.self] else {
            logger.error("Repositories not available")
            return
        }

        // Get all queues
        let queues = try await queueRepo.getAll()

        for queue in queues where queue.status == .active {
            do {
                try await processQueue(queue, queueRepo: queueRepo, prRepo: prRepo, configRepo: configRepo)
            } catch {
                logger.error("Failed to process queue", metadata: [
                    "queueID": "\(queue.id)",
                    "error": .string(error.localizedDescription)
                ])
            }
        }
    }

    private func processQueue(
        _ queue: Queue,
        queueRepo: QueueRepository,
        prRepo: PullRequestRepository,
        configRepo: ConfigurationRepository
    ) async throws {
        // Get all entries for this queue
        let entries = try await queueRepo.getEntries(queueID: queue.id)

        // Filter for pending entries
        let pendingEntries = entries.filter { $0.status == .pending }

        guard !pendingEntries.isEmpty else {
            return
        }

        // Process the first pending entry
        if let firstEntry = pendingEntries.first {
            try await processEntry(
                firstEntry,
                queue: queue,
                queueRepo: queueRepo,
                prRepo: prRepo,
                configRepo: configRepo
            )
        }
    }

    private func processEntry(
        _ entry: QueueEntry,
        queue: Queue,
        queueRepo: QueueRepository,
        prRepo: PullRequestRepository,
        configRepo: ConfigurationRepository
    ) async throws {
        logger.info("Processing queue entry", metadata: [
            "entryID": "\(entry.id)",
            "prID": "\(entry.pullRequestID)",
            "position": "\(entry.position)"
        ])

        var updatedEntry = entry
        updatedEntry.status = .processing
        try await queueRepo.updateEntry(updatedEntry)

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(queue.id),
            action: "entry_processing",
            entryID: String(entry.id)
        ))

        do {
            guard let pr = try? await prRepo.get(id: entry.pullRequestID) else {
                logger.error("Pull request not found", metadata: ["prID": "\(entry.pullRequestID)"])
                throw ProcessingError.pullRequestNotFound
            }

            let repoInfo = try parseRepositoryInfo(pr: pr)
            let config = try await configRepo.get()

            let context = ProcessingContext(
                pullRequest: pr,
                repoInfo: repoInfo,
                config: config,
                entry: entry,
                queue: queue,
                queueRepo: queueRepo,
                prRepo: prRepo
            )

            try await executeChecksIfNeeded(context: context, updatedEntry: &updatedEntry)
            try await updateAndMergePR(context: context)
            try await handleMergeSuccess(context: context, updatedEntry: &updatedEntry)
        } catch {
            guard let pr = try? await prRepo.get(id: entry.pullRequestID),
                  let repoInfo = try? parseRepositoryInfo(pr: pr),
                  let config = try? await configRepo.get() else {
                throw error
            }

            let context = ProcessingContext(
                pullRequest: pr,
                repoInfo: repoInfo,
                config: config,
                entry: entry,
                queue: queue,
                queueRepo: queueRepo,
                prRepo: prRepo
            )

            try await handleProcessingError(error: error, context: context, updatedEntry: &updatedEntry)
            throw error
        }
    }

    private func executeChecksIfNeeded(
        context: ProcessingContext,
        updatedEntry: inout QueueEntry
    ) async throws {
        guard !context.config.checkConfigurations.isEmpty &&
              context.config.checkConfigurations != "[]" else {
            return
        }

        logger.info("Executing checks", metadata: ["prNumber": "\(context.pullRequest.number)"])
        let checksPassed = try await checkExecutionService.executeChecks(
            owner: context.repoInfo.owner,
            repo: context.repoInfo.repo,
            prNumber: context.pullRequest.number,
            headSHA: context.pullRequest.headSHA,
            checkConfigurations: context.config.checkConfigurations
        )

        guard checksPassed else {
            logger.warning("Checks failed for PR", metadata: ["prNumber": "\(context.pullRequest.number)"])
            updatedEntry.status = .failed
            try await context.queueRepo.updateEntry(updatedEntry)
            try await context.queueRepo.removeEntry(id: context.entry.id)

            await WebSocketController.broadcastQueueEvent(QueueEvent(
                queueID: String(context.queue.id),
                action: "entry_failed",
                entryID: String(context.entry.id)
            ))

            try? await githubGateway.postComment(
                owner: context.repoInfo.owner,
                repo: context.repoInfo.repo,
                number: context.pullRequest.number,
                message: "❌ Checks failed. Removed from merge queue."
            )

            throw ProcessingError.checksFailed
        }
    }

    private func updateAndMergePR(context: ProcessingContext) async throws {
        logger.info("Updating PR branch", metadata: ["prNumber": "\(context.pullRequest.number)"])
        let updateResult = try await githubGateway.updatePullRequestBranch(
            owner: context.repoInfo.owner,
            repo: context.repoInfo.repo,
            number: context.pullRequest.number
        )

        logger.info("Branch updated", metadata: [
            "prNumber": "\(context.pullRequest.number)",
            "message": .string(updateResult.message)
        ])

        try await Task.sleep(nanoseconds: 2_000_000_000)

        logger.info("Merging pull request", metadata: ["prNumber": "\(context.pullRequest.number)"])
        let mergeResult = try await githubGateway.mergePullRequest(
            owner: context.repoInfo.owner,
            repo: context.repoInfo.repo,
            number: context.pullRequest.number,
            options: MergeOptions(commitMessage: "Merged via IMQ", mergeMethod: "squash")
        )

        logger.info("Pull request merged successfully", metadata: [
            "prNumber": "\(context.pullRequest.number)",
            "sha": .string(mergeResult.sha)
        ])
    }

    private func handleMergeSuccess(
        context: ProcessingContext,
        updatedEntry: inout QueueEntry
    ) async throws {
        updatedEntry.status = .completed
        try await context.queueRepo.updateEntry(updatedEntry)
        try await context.queueRepo.removeEntry(id: context.entry.id)

        var mergedPR = context.pullRequest
        mergedPR.status = .merged
        try await context.prRepo.save(mergedPR)

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(context.queue.id),
            action: "entry_completed",
            entryID: String(context.entry.id)
        ))

        try? await githubGateway.postComment(
            owner: context.repoInfo.owner,
            repo: context.repoInfo.repo,
            number: context.pullRequest.number,
            message: "✅ Successfully merged via IMQ!"
        )
    }

    private func handleProcessingError(
        error: Error,
        context: ProcessingContext,
        updatedEntry: inout QueueEntry
    ) async throws {
        logger.error("Failed to process entry", metadata: [
            "entryID": "\(context.entry.id)",
            "error": .string(error.localizedDescription)
        ])

        updatedEntry.status = .failed
        try await context.queueRepo.updateEntry(updatedEntry)

        await WebSocketController.broadcastQueueEvent(QueueEvent(
            queueID: String(context.queue.id),
            action: "entry_failed",
            entryID: String(context.entry.id)
        ))

        if let pr = try? await context.prRepo.get(id: context.entry.pullRequestID),
           let repoInfo = try? parseRepositoryInfo(pr: pr) {
            try? await githubGateway.postComment(
                owner: repoInfo.owner,
                repo: repoInfo.repo,
                number: pr.number,
                message: "❌ Failed to merge: \(error.localizedDescription)"
            )
        }
    }

    private func parseRepositoryInfo(pr: PullRequest) throws -> (owner: String, repo: String) {
        // Parse repository info from the PR
        // Assuming repository is stored as "owner/repo" format
        guard let configRepo = app.storage[ConfigRepositoryKey.self] else {
            throw ProcessingError.configurationNotAvailable
        }

        // Get from environment variable
        guard let repoFullName = Environment.get("IMQ_GITHUB_REPO") else {
            throw ProcessingError.repositoryInfoNotFound
        }

        let components = repoFullName.split(separator: "/")
        guard components.count == 2 else {
            throw ProcessingError.invalidRepositoryFormat
        }

        return (owner: String(components[0]), repo: String(components[1]))
    }
}

// MARK: - Processing Context

struct ProcessingContext {
    let pullRequest: PullRequest
    let repoInfo: (owner: String, repo: String)
    let config: SystemConfiguration
    let entry: QueueEntry
    let queue: Queue
    let queueRepo: QueueRepository
    let prRepo: PullRequestRepository
}

// MARK: - Error Types

enum ProcessingError: Error, LocalizedError {
    case pullRequestNotFound
    case repositoryInfoNotFound
    case invalidRepositoryFormat
    case configurationNotAvailable
    case checksFailed

    var errorDescription: String? {
        switch self {
        case .pullRequestNotFound:
            return "Pull request not found in database"
        case .repositoryInfoNotFound:
            return "Repository information not found"
        case .invalidRepositoryFormat:
            return "Invalid repository format, expected 'owner/repo'"
        case .configurationNotAvailable:
            return "Configuration repository not available"
        case .checksFailed:
            return "Required checks failed"
        }
    }
}

// MARK: - Storage Key

struct QueueProcessingServiceKey: StorageKey {
    typealias Value = QueueProcessingService
}
