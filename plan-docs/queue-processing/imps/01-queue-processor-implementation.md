# Queue Processor Implementation

**Document Version:** 1.0
**Created:** 2025-12-10
**Status:** Implementation Ready
**Related Design Docs:**
- `../docs/01-basic-queue-design.md` - Queue states and transitions
- `../docs/02-concurrency-optimization.md` - Concurrency patterns
- `../docs/03-final-design.md` - Fair scheduling and graceful shutdown

## Overview

Complete implementation guide for the Queue Processor, including the main processing loop, priority scheduling, fair queuing, and concurrency control using Swift Concurrency patterns.

## Architecture

### Component Diagram
```
QueueProcessor (Actor)
    ├─> FairQueueScheduler (Actor) - Priority + Fair scheduling
    ├─> AsyncSemaphore (Actor) - Concurrency control
    ├─> QueueProcessingUseCase - Business logic
    ├─> RetryPolicy - Error recovery
    └─> QueueMetrics - Observability
```

## Critical Files to Create

1. `imq-core/Sources/IMQCore/Application/Services/QueueProcessor.swift` - Main processor actor
2. `imq-core/Sources/IMQCore/Application/Services/FairQueueScheduler.swift` - Scheduler
3. `imq-core/Sources/IMQCore/Application/Concurrency/AsyncSemaphore.swift` - Semaphore
4. `imq-core/Sources/IMQCore/Application/Policies/RetryPolicy.swift` - Retry logic
5. `imq-core/Sources/IMQCore/Application/Metrics/QueueMetrics.swift` - Metrics

## 1. Queue Processor Actor

**File:** `imq-core/Sources/IMQCore/Application/Services/QueueProcessor.swift`

### Implementation Pattern

```swift
import Foundation
import Logging

/// Main queue processor with concurrent processing capabilities
/// Handles multiple queues with priority scheduling and fairness guarantees
actor QueueProcessor {
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

    // MARK: - State

    private var isRunning = false
    private var isShuttingDown = false
    private var runningTasks: Set<UUID> = []

    // MARK: - Initialization

    init(
        queueRepository: QueueRepository,
        queueProcessingUseCase: QueueProcessingUseCase,
        maxConcurrentProcessing: Int = 3,
        processingInterval: TimeInterval = 30,
        shutdownTimeout: TimeInterval = 60,
        logger: Logger
    ) {
        self.queueRepository = queueRepository
        self.queueProcessingUseCase = queueProcessingUseCase
        self.maxConcurrentProcessing = maxConcurrentProcessing
        self.processingInterval = processingInterval
        self.shutdownTimeout = shutdownTimeout
        self.logger = logger

        // Initialize supporting actors
        self.scheduler = FairQueueScheduler(logger: logger)
        self.semaphore = AsyncSemaphore(value: maxConcurrentProcessing)
        self.metrics = QueueMetrics()
        self.retryPolicy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 60.0
        )
    }

    // MARK: - Main Processing Loop

    /// Start the queue processor
    /// Continuously processes queues until stopped
    func start() async throws {
        guard !isRunning else {
            logger.warning("Queue processor is already running")
            return
        }

        isRunning = true
        logger.info("Starting queue processor...",
                   metadata: ["maxConcurrent": "\(maxConcurrentProcessing)",
                             "interval": "\(processingInterval)s"])

        while isRunning && !isShuttingDown {
            do {
                // Fetch all queues from repository
                let queues = try await queueRepository.findAll()
                logger.debug("Fetched \(queues.count) queue(s)")

                // Schedule queues with priority
                for queue in queues {
                    await scheduler.schedule(queue)
                }

                // Process queues with concurrency limit
                await processScheduledQueues()

                // Wait for next processing cycle
                try await Task.sleep(nanoseconds: UInt64(processingInterval * 1_000_000_000))

            } catch is CancellationError {
                logger.info("Queue processor cancelled")
                break
            } catch {
                logger.error("Queue processor error: \(error)")
                metrics.recordProcessorError()

                // Back off on error
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }
        }

        logger.info("Queue processor stopped")
    }

    /// Process all scheduled queues with concurrency control
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

    /// Process a single queue with semaphore control
    private func processQueueWithSemaphore(_ queue: Queue) async {
        // Acquire semaphore
        await semaphore.wait()
        defer {
            Task { await self.semaphore.signal() }
        }

        // Track running task
        let taskID = UUID()
        runningTasks.insert(taskID)
        defer { runningTasks.remove(taskID) }

        await processQueueSafely(queue)
    }

    /// Process queue with retry, timeout, and metrics
    private func processQueueSafely(_ queue: Queue) async {
        let startTime = Date()

        logger.info("Processing queue: \(queue.id)",
                   metadata: ["repo": "\(queue.repository.fullName)",
                             "branch": "\(queue.baseBranch)",
                             "entries": "\(queue.entries.count)"])

        do {
            // Process with timeout (5 minutes default)
            try await withTimeout(seconds: 300) {
                // Execute with retry policy
                try await retryPolicy.execute {
                    try await queueProcessingUseCase.processQueue(
                        for: queue.baseBranch,
                        in: queue.repository
                    )
                }
            }

            let duration = Date().timeIntervalSince(startTime)
            metrics.recordProcessingComplete(queue, success: true, duration: duration)
            logger.info("Successfully processed queue \(queue.id)",
                       metadata: ["duration": "\(String(format: "%.2f", duration))s"])

        } catch let error as TimeoutError {
            let duration = Date().timeIntervalSince(startTime)
            metrics.recordProcessingComplete(queue, success: false, duration: duration)
            logger.error("Queue processing timeout for \(queue.id): \(error)")

        } catch {
            let duration = Date().timeIntervalSince(startTime)
            metrics.recordProcessingComplete(queue, success: false, duration: duration)
            logger.error("Failed to process queue \(queue.id): \(error)")
        }
    }

    // MARK: - Graceful Shutdown

    /// Initiate graceful shutdown
    /// Waits for running tasks to complete before shutting down
    func shutdown() async {
        logger.info("Initiating graceful shutdown...")
        isShuttingDown = true
        isRunning = false

        let deadline = Date().addingTimeInterval(shutdownTimeout)

        while !runningTasks.isEmpty && Date() < deadline {
            let remaining = runningTasks.count
            logger.info("Waiting for \(remaining) running task(s) to complete...")
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        if !runningTasks.isEmpty {
            logger.warning("Forcefully terminating \(runningTasks.count) task(s)")
            metrics.recordForcedShutdown(taskCount: runningTasks.count)
        }

        logger.info("Shutdown complete")
    }

    // MARK: - Helper Methods

    /// Execute operation with timeout
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

enum TimeoutError: Error {
    case operationTimedOut(seconds: TimeInterval)
    case noResult
}
```

## 2. Fair Queue Scheduler

**File:** `imq-core/Sources/IMQCore/Application/Services/FairQueueScheduler.swift`

### Implementation Pattern

```swift
import Foundation
import Logging

/// Fair queue scheduler using Weighted Deficit Round Robin algorithm
/// Ensures both priority and fairness in queue processing
actor FairQueueScheduler {
    private let logger: Logger
    private var weightedQueues: [WeightedQueue] = []

    init(logger: Logger) {
        self.logger = logger
    }

    /// Schedule a queue for processing
    func schedule(_ queue: Queue) {
        let priority = determinePriority(for: queue)
        let weight = weightForPriority(priority)

        let weightedQueue = WeightedQueue(
            queue: queue,
            priority: priority,
            weight: weight,
            deficit: 0
        )

        weightedQueues.append(weightedQueue)

        logger.debug("Scheduled queue \(queue.id)",
                    metadata: ["priority": "\(priority)",
                              "weight": "\(weight)"])
    }

    /// Get next queue to process (Weighted Deficit Round Robin)
    func nextQueue() -> Queue? {
        guard !weightedQueues.isEmpty else {
            return nil
        }

        // Find queue with highest deficit
        var selectedIndex = 0
        var maxDeficit = weightedQueues[0].deficit

        for (index, wq) in weightedQueues.enumerated() {
            if wq.deficit > maxDeficit {
                maxDeficit = wq.deficit
                selectedIndex = index
            }
        }

        let selected = weightedQueues.remove(at: selectedIndex)

        // Update deficits for remaining queues
        for index in weightedQueues.indices {
            weightedQueues[index].deficit += weightedQueues[index].weight
        }

        logger.debug("Selected queue \(selected.queue.id) for processing",
                    metadata: ["deficit": "\(selected.deficit)"])

        return selected.queue
    }

    /// Determine priority based on branch name
    private func determinePriority(for queue: Queue) -> QueuePriority {
        let baseBranch = queue.baseBranch.lowercased()

        if baseBranch.contains("hotfix") {
            return .critical
        } else if baseBranch.contains("release") {
            return .high
        } else if ["main", "master"].contains(baseBranch) {
            return .normal
        } else {
            return .low
        }
    }

    /// Get weight for priority level
    private func weightForPriority(_ priority: QueuePriority) -> Int {
        switch priority {
        case .critical: return 4
        case .high: return 3
        case .normal: return 2
        case .low: return 1
        }
    }
}

struct WeightedQueue {
    let queue: Queue
    let priority: QueuePriority
    let weight: Int
    var deficit: Int
}

enum QueuePriority: Int, Comparable {
    case critical = 0  // Hotfix branches
    case high = 1      // Release branches
    case normal = 2    // Main/master
    case low = 3       // Feature branches

    static func < (lhs: QueuePriority, rhs: QueuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

## 3. Async Semaphore

**File:** `imq-core/Sources/IMQCore/Application/Concurrency/AsyncSemaphore.swift`

### Implementation Pattern

```swift
import Foundation

/// Thread-safe semaphore for async operations
/// Controls concurrent access to resources
actor AsyncSemaphore {
    private var count: Int
    private let maxCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.count = value
        self.maxCount = value
    }

    /// Acquire the semaphore
    /// Suspends if count is 0 until signal() is called
    func wait() async {
        count -= 1

        if count >= 0 {
            return
        }

        // Need to wait
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Release the semaphore
    /// Wakes up one waiting task if any
    func signal() {
        count += 1

        guard count <= maxCount else {
            count = maxCount
            return
        }

        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
```

## Testing Strategy

### Unit Tests

```swift
import XCTest
@testable import IMQCore

final class QueueProcessorTests: XCTestCase {
    var processor: QueueProcessor!
    var mockRepository: MockQueueRepository!
    var mockUseCase: MockQueueProcessingUseCase!

    override func setUp() async throws {
        mockRepository = MockQueueRepository()
        mockUseCase = MockQueueProcessingUseCase()

        processor = QueueProcessor(
            queueRepository: mockRepository,
            queueProcessingUseCase: mockUseCase,
            maxConcurrentProcessing: 2,
            processingInterval: 1,
            logger: Logger(label: "test")
        )
    }

    func testConcurrentProcessing() async throws {
        // Setup multiple queues
        let queues = (0..<5).map { createTestQueue(id: $0) }
        mockRepository.queues = queues

        let task = Task {
            try await processor.start()
        }

        // Wait for processing
        try await Task.sleep(nanoseconds: 2_000_000_000)

        await processor.shutdown()
        try await task.value

        // Verify concurrency limit
        let maxConcurrent = await mockUseCase.maxConcurrentProcessing
        XCTAssertLessThanOrEqual(maxConcurrent, 2)
    }
}
```

## Performance Tuning

### Configuration Guidelines

- **maxConcurrentProcessing**: Default 3, adjust based on CPU cores
- **processingInterval**: Default 30s, increase for lower load
- **shutdownTimeout**: Default 60s, increase for long-running checks

### Memory Management

- Clear completed tasks from runningTasks set
- Limit metrics history size
- Use value types (struct) where possible

---

**Related:** 02-conflict-detection-pr-update-implementation.md
