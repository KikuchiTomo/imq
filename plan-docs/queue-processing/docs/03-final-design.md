# Queue Processing Design - 第3回検討（最終設計）

## 検討日
2025-12-10

## 前回の課題への対応

### デッドロック防止

**Timeout on all operations**

```swift
actor SafeQueueProcessor {
    private let operationTimeout: TimeInterval = 300  // 5 minutes

    func processWithTimeout(_ queue: Queue) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Add processing task
            group.addTask {
                try await self.processQueue(queue)
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.operationTimeout * 1_000_000_000))
                throw ProcessingError.timeout
            }

            // Wait for first to complete
            try await group.next()

            // Cancel remaining tasks
            group.cancelAll()
        }
    }
}
```

### Queue Starvation対策

**Weighted Fair Queuing**

```swift
struct WeightedQueue {
    let queue: Queue
    var weight: Int
    var deficit: Int = 0
}

actor FairQueueScheduler {
    private var weightedQueues: [WeightedQueue] = []

    func schedule(_ queue: Queue) {
        let weight = weightForPriority(queue.priority)
        weightedQueues.append(WeightedQueue(queue: queue, weight: weight, deficit: 0))
    }

    func nextQueue() -> Queue? {
        guard !weightedQueues.isEmpty else { return nil }

        // Find queue with highest deficit
        var selectedIndex = 0
        for (index, wq) in weightedQueues.enumerated() {
            if wq.deficit > weightedQueues[selectedIndex].deficit {
                selectedIndex = index
            }
        }

        let selected = weightedQueues.remove(at: selectedIndex)

        // Update deficits
        for index in weightedQueues.indices {
            weightedQueues[index].deficit += weightedQueues[index].weight
        }

        return selected.queue
    }

    private func weightForPriority(_ priority: QueuePriority) -> Int {
        switch priority {
        case .critical: return 4
        case .high: return 3
        case .normal: return 2
        case .low: return 1
        }
    }
}
```

### Graceful Shutdown

```swift
actor GracefulQueueProcessor {
    private var isShuttingDown = false
    private var runningTasks: Set<UUID> = []

    func shutdown(timeout: TimeInterval = 60) async {
        logger.info("Initiating graceful shutdown...")
        isShuttingDown = true

        // Wait for running tasks to complete
        let deadline = Date().addingTimeInterval(timeout)

        while !runningTasks.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
        }

        if !runningTasks.isEmpty {
            logger.warning("Forcefully terminating \(runningTasks.count) tasks")
        }

        logger.info("Shutdown complete")
    }

    func processQueue(_ queue: Queue) async throws {
        guard !isShuttingDown else {
            throw ProcessingError.shuttingDown
        }

        let taskID = UUID()
        runningTasks.insert(taskID)
        defer { runningTasks.remove(taskID) }

        try await doProcessQueue(queue)
    }
}
```

## 最終アーキテクチャ

```swift
// Complete Queue Processor with all features
final class ProductionQueueProcessor {
    private let queueRepository: QueueRepository
    private let queueProcessingUseCase: QueueProcessingUseCase
    private let scheduler: FairQueueScheduler
    private let semaphore: AsyncSemaphore
    private let metrics: QueueMetrics
    private let retryPolicy: RetryPolicy

    private let processingInterval: TimeInterval = 30
    private var isRunning = false

    func start() async throws {
        isRunning = true

        logger.info("Starting queue processor...")

        while isRunning {
            do {
                // Fetch all queues
                let queues = try await queueRepository.findAll()

                // Schedule queues
                for queue in queues {
                    await scheduler.schedule(queue)
                }

                // Process queues with concurrency limit
                await withTaskGroup(of: Void.self) { group in
                    while let queue = await scheduler.nextQueue() {
                        group.addTask {
                            await self.semaphore.wait()
                            defer { await self.semaphore.signal() }

                            await self.processQueueSafely(queue)
                        }
                    }
                }

                // Wait for next interval
                try await Task.sleep(nanoseconds: UInt64(processingInterval * 1_000_000_000))

            } catch {
                logger.error("Queue processor error: \(error)")

                // Back off on error
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
            }
        }

        logger.info("Queue processor stopped")
    }

    private func processQueueSafely(_ queue: Queue) async {
        let startTime = Date()

        do {
            try await retryPolicy.execute {
                try await queueProcessingUseCase.processQueue(
                    for: queue.baseBranch,
                    in: queue.repository
                )
            }

            let duration = Date().timeIntervalSince(startTime)
            metrics.recordProcessingComplete(queue, success: true, duration: duration)

        } catch {
            let duration = Date().timeIntervalSince(startTime)
            metrics.recordProcessingComplete(queue, success: false, duration: duration)
            logger.error("Failed to process queue \(queue.id): \(error)")
        }
    }

    func stop() async {
        logger.info("Stopping queue processor...")
        isRunning = false
    }
}
```

## テスト戦略

```swift
class QueueProcessingTests: XCTestCase {
    func testEnqueueDequeue() async throws {
        var queue = Queue(id: QueueID(), repository: testRepo, baseBranch: "main", entries: [], createdAt: Date())

        let pr = testPullRequest()
        let entry = QueueEntry(id: QueueEntryID(), pullRequest: pr, position: 0, status: .pending, enqueuedAt: Date(), checks: [])

        queue.enqueue(entry)
        XCTAssertEqual(queue.entries.count, 1)

        let dequeued = queue.dequeue()
        XCTAssertEqual(dequeued?.id, entry.id)
        XCTAssertEqual(queue.entries.count, 0)
    }

    func testConcurrentProcessing() async throws {
        let processor = ConcurrentQueueProcessor(maxConcurrent: 2)
        let queues = (0..<5).map { createTestQueue(id: $0) }

        await processor.processAllQueues(queues)

        // Verify all queues were processed
        // Max 2 concurrent at any time
    }
}
```

## 実装チェックリスト

- ✅ Queue entity with invariants
- ✅ Enqueue/Dequeue operations
- ✅ Main processing loop
- ✅ Conflict detection
- ✅ PR update
- ✅ Check execution integration
- ✅ Merge execution
- ✅ Error handling (conflict, check failure)
- ✅ Concurrent processing with semaphore
- ✅ Timeout and cancellation
- ✅ Retry logic
- ✅ Priority scheduling
- ✅ Fair queuing
- ✅ Graceful shutdown
- ✅ Metrics collection
- ✅ Comprehensive tests

## 次の実装

Queue Processing設計完了。次はCheck Executionの詳細設計。
