import Foundation
import Logging

/// Main queue processor with concurrent processing capabilities
///
/// QueueProcessor is the heart of IMQ, continuously processing merge queues
/// with fair scheduling and concurrency control. It runs a main loop that:
/// 1. Fetches all queues from the repository
/// 2. Schedules them with priority (using FairQueueScheduler)
/// 3. Processes queues concurrently (limited by AsyncSemaphore)
/// 4. Handles errors with retry logic
/// 5. Collects metrics for observability
/// 6. Supports graceful shutdown
///
/// Example usage:
/// ```swift
/// let processor = QueueProcessor(
///     queueRepository: queueRepo,
///     queueProcessingUseCase: processingUseCase,
///     maxConcurrentProcessing: 3,
///     logger: logger
/// )
///
/// // Start processing (runs until stopped)
/// Task {
///     try await processor.start()
/// }
///
/// // Later, gracefully shutdown
/// await processor.shutdown()
/// ```
public actor QueueProcessor: Sendable {
    // MARK: - Dependencies

    private let queueRepository: QueueRepository
    private let queueProcessingUseCase: QueueProcessingUseCase
    private let scheduler: FairQueueScheduler
    private let semaphore: AsyncSemaphore
    private let metrics: QueueMetrics
    private let retryPolicy: RetryPolicy
    private let logger: Logger

    // MARK: - Configuration

    private let processingInterval: TimeInterval
    private let maxConcurrentProcessing: Int
    private let shutdownTimeout: TimeInterval
    private let processingTimeout: TimeInterval

    // MARK: - State

    private var isRunning = false
    private var isShuttingDown = false
    private var runningTasks: Set<UUID> = []

    // MARK: - Initialization

    /// Creates a new QueueProcessor
    ///
    /// - Parameters:
    ///   - queueRepository: Repository for accessing queues
    ///   - queueProcessingUseCase: Use case for processing queue entries
    ///   - maxConcurrentProcessing: Maximum number of queues to process concurrently
    ///   - processingInterval: Time to wait between processing cycles (in seconds)
    ///   - processingTimeout: Maximum time for a single queue processing (in seconds)
    ///   - shutdownTimeout: Maximum time to wait for graceful shutdown (in seconds)
    ///   - retryPolicy: Retry policy for transient failures
    ///   - metrics: Metrics collector
    ///   - scheduler: Queue scheduler
    ///   - logger: Logger for processor operations
    init(
        queueRepository: QueueRepository,
        queueProcessingUseCase: QueueProcessingUseCase,
        maxConcurrentProcessing: Int = 3,
        processingInterval: TimeInterval = 30,
        processingTimeout: TimeInterval = 300,
        shutdownTimeout: TimeInterval = 60,
        retryPolicy: RetryPolicy = .conservative,
        metrics: QueueMetrics = QueueMetrics(),
        scheduler: FairQueueScheduler? = nil,
        logger: Logger = Logger(label: "imq.processor")
    ) {
        precondition(maxConcurrentProcessing > 0, "Max concurrent processing must be > 0")
        precondition(processingInterval > 0, "Processing interval must be > 0")

        self.queueRepository = queueRepository
        self.queueProcessingUseCase = queueProcessingUseCase
        self.maxConcurrentProcessing = maxConcurrentProcessing
        self.processingInterval = processingInterval
        self.processingTimeout = processingTimeout
        self.shutdownTimeout = shutdownTimeout
        self.retryPolicy = retryPolicy
        self.metrics = metrics
        self.logger = logger

        // Initialize supporting actors
        self.scheduler = scheduler ?? FairQueueScheduler(logger: logger)
        self.semaphore = AsyncSemaphore(permits: maxConcurrentProcessing)
    }

    // MARK: - Main Processing Loop

    /// Starts the queue processor
    ///
    /// This method runs continuously until `shutdown()` is called or an
    /// unrecoverable error occurs. It fetches queues, schedules them fairly,
    /// and processes them with concurrency control.
    ///
    /// Example:
    /// ```swift
    /// Task {
    ///     try await processor.start()
    /// }
    /// ```
    ///
    /// - Throws: QueueProcessorError for unrecoverable errors
    public func start() async throws {
        guard !isRunning else {
            logger.warning("Queue processor is already running")
            return
        }

        isRunning = true
        logger.info(
            "Starting queue processor",
            metadata: [
                "maxConcurrent": "\(maxConcurrentProcessing)",
                "interval": "\(processingInterval)s",
                "timeout": "\(processingTimeout)s"
            ]
        )

        while isRunning && !isShuttingDown {
            do {
                // Fetch all queues from repository
                let queues = try await queueRepository.findAll()
                logger.debug("Fetched \(queues.count) queue(s)")

                // Record queue metrics
                for queue in queues {
                    await metrics.recordQueueLength(
                        repository: queue.repository,
                        branch: queue.baseBranch,
                        length: queue.count
                    )
                }

                // Schedule queues with priority
                await scheduler.scheduleAll(queues)

                let schedulerSummary = await scheduler.summary()
                logger.debug(
                    "Scheduled queues",
                    metadata: [
                        "total": "\(schedulerSummary.totalQueues)",
                        "critical": "\(schedulerSummary.criticalCount)",
                        "high": "\(schedulerSummary.highCount)",
                        "normal": "\(schedulerSummary.normalCount)",
                        "low": "\(schedulerSummary.lowCount)"
                    ]
                )

                // Process queues with concurrency limit
                await processScheduledQueues()

                // Wait for next processing cycle
                try await Task.sleep(nanoseconds: UInt64(processingInterval * 1_000_000_000))

            } catch is CancellationError {
                logger.info("Queue processor cancelled")
                break
            } catch {
                logger.error("Queue processor error: \(error)")
                await metrics.recordProcessorError()

                // Back off on error to avoid tight error loops
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }
        }

        logger.info("Queue processor stopped")
    }

    /// Stops the queue processor
    ///
    /// Sets the running flag to false, causing the main loop to exit
    /// after the current processing cycle completes.
    ///
    /// Example:
    /// ```swift
    /// await processor.stop()
    /// ```
    public func stop() {
        logger.info("Stopping queue processor")
        isRunning = false
    }

    // MARK: - Graceful Shutdown

    /// Initiates graceful shutdown
    ///
    /// This method:
    /// 1. Sets the shutdown flag to prevent new tasks
    /// 2. Waits for running tasks to complete (up to shutdownTimeout)
    /// 3. Forcefully terminates remaining tasks if timeout is exceeded
    ///
    /// Example:
    /// ```swift
    /// await processor.shutdown()
    /// ```
    public func shutdown() async {
        logger.info("Initiating graceful shutdown")
        isShuttingDown = true
        isRunning = false

        let deadline = Date().addingTimeInterval(shutdownTimeout)

        while !runningTasks.isEmpty && Date() < deadline {
            let remaining = runningTasks.count
            let timeLeft = deadline.timeIntervalSince(Date())

            logger.info(
                "Waiting for running tasks to complete",
                metadata: [
                    "remaining": "\(remaining)",
                    "timeLeft": "\(String(format: "%.1f", timeLeft))s"
                ]
            )

            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        if !runningTasks.isEmpty {
            logger.warning("Forcefully terminating \(runningTasks.count) task(s)")
            await metrics.recordForcedShutdown(taskCount: runningTasks.count)
            runningTasks.removeAll()
        }

        logger.info("Shutdown complete")
    }

    // MARK: - Processing Methods

    /// Processes all scheduled queues with concurrency control
    private func processScheduledQueues() async {
        await withTaskGroup(of: Void.self) { group in
            while let queue = await scheduler.nextQueue(), !isShuttingDown {
                // Add processing task with semaphore
                group.addTask {
                    await self.processQueueWithSemaphore(queue)
                }
            }

            // Wait for all tasks to complete
            await group.waitForAll()
        }
    }

    /// Processes a single queue with semaphore control
    private func processQueueWithSemaphore(_ queue: Queue) async {
        // Acquire semaphore
        await semaphore.wait()
        defer {
            Task { await self.semaphore.signal() }
        }

        // Track running task
        let taskID = UUID()
        await addRunningTask(taskID)
        defer {
            Task { await self.removeRunningTask(taskID) }
        }

        await processQueueSafely(queue)
    }

    /// Processes a queue with retry, timeout, and metrics
    private func processQueueSafely(_ queue: Queue) async {
        let startTime = Date()

        logger.info(
            "Processing queue",
            metadata: [
                "queueID": "\(queue.id.value)",
                "repo": "\(queue.repository.fullName)",
                "branch": "\(queue.baseBranch.value)",
                "entries": "\(queue.entries.count)"
            ]
        )

        do {
            // Process with timeout
            try await withTimeout(seconds: processingTimeout) {
                // Execute with retry policy
                try await self.retryPolicy.execute(logger: self.logger) {
                    try await self.queueProcessingUseCase.processQueue(
                        for: queue.baseBranch,
                        in: queue.repository
                    )
                }
            }

            let duration = Date().timeIntervalSince(startTime)
            await metrics.recordProcessingComplete(queue, success: true, duration: duration)

            logger.info(
                "Successfully processed queue",
                metadata: [
                    "queueID": "\(queue.id.value)",
                    "duration": "\(String(format: "%.2f", duration))s"
                ]
            )

        } catch let error as TimeoutError {
            let duration = Date().timeIntervalSince(startTime)
            await metrics.recordProcessingComplete(queue, success: false, duration: duration)

            logger.error(
                "Queue processing timeout",
                metadata: [
                    "queueID": "\(queue.id.value)",
                    "error": "\(error)",
                    "duration": "\(String(format: "%.2f", duration))s"
                ]
            )

        } catch {
            let duration = Date().timeIntervalSince(startTime)
            await metrics.recordProcessingComplete(queue, success: false, duration: duration)

            logger.error(
                "Failed to process queue",
                metadata: [
                    "queueID": "\(queue.id.value)",
                    "error": "\(error)",
                    "duration": "\(String(format: "%.2f", duration))s"
                ]
            )
        }
    }

    // MARK: - State Management

    /// Adds a task to the running tasks set
    private func addRunningTask(_ taskID: UUID) {
        runningTasks.insert(taskID)
    }

    /// Removes a task from the running tasks set
    private func removeRunningTask(_ taskID: UUID) {
        runningTasks.remove(taskID)
    }

    // MARK: - Status

    /// Returns processor status information
    public func status() -> ProcessorStatus {
        ProcessorStatus(
            isRunning: isRunning,
            isShuttingDown: isShuttingDown,
            runningTaskCount: runningTasks.count,
            maxConcurrentProcessing: maxConcurrentProcessing
        )
    }

    /// Returns metrics summary
    public func getMetrics() async -> MetricsSummary {
        await metrics.getSummary()
    }

    // MARK: - Helper Methods

    /// Executes an operation with timeout
    ///
    /// - Parameters:
    ///   - seconds: Timeout duration in seconds
    ///   - operation: The operation to execute
    /// - Returns: The result of the operation
    /// - Throws: TimeoutError if operation exceeds timeout
    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add operation task
            group.addTask {
                try await operation()
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.operationTimedOut(seconds: seconds)
            }

            // Wait for first to complete
            guard let result = try await group.next() else {
                throw TimeoutError.noResult
            }

            // Cancel remaining tasks
            group.cancelAll()

            return result
        }
    }
}

// MARK: - Supporting Types

/// Timeout error
public enum TimeoutError: Error, LocalizedError {
    case operationTimedOut(seconds: TimeInterval)
    case noResult

    public var errorDescription: String? {
        switch self {
        case .operationTimedOut(let seconds):
            return "Operation timed out after \(seconds) seconds"
        case .noResult:
            return "No result received from operation"
        }
    }
}

/// Queue processor error
public enum QueueProcessorError: Error, LocalizedError {
    case alreadyRunning
    case notRunning
    case shutdownTimeout

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Queue processor is already running"
        case .notRunning:
            return "Queue processor is not running"
        case .shutdownTimeout:
            return "Graceful shutdown timed out"
        }
    }
}

/// Processor status
public struct ProcessorStatus: Sendable {
    public let isRunning: Bool
    public let isShuttingDown: Bool
    public let runningTaskCount: Int
    public let maxConcurrentProcessing: Int

    public var isHealthy: Bool {
        isRunning && !isShuttingDown
    }

    public var concurrencyUsage: Double {
        guard maxConcurrentProcessing > 0 else { return 0.0 }
        return (Double(runningTaskCount) / Double(maxConcurrentProcessing)) * 100.0
    }
}
