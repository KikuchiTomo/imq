# Queue Processing Design - 第2回検討（並行処理と最適化）

## 検討日
2025-12-10

## 前回の課題への対応

### 課題1: 並行処理の制御

**解決策**: **Semaphore による同時実行制限**

```swift
actor ConcurrentQueueProcessor {
    private let maxConcurrentProcessing: Int = 3
    private let semaphore: AsyncSemaphore

    init() {
        self.semaphore = AsyncSemaphore(value: maxConcurrentProcessing)
    }

    func processAllQueues(_ queues: [Queue]) async {
        await withTaskGroup(of: Void.self) { group in
            for queue in queues {
                group.addTask {
                    await self.semaphore.wait()
                    defer { await self.semaphore.signal() }

                    do {
                        try await self.processQueue(queue)
                    } catch {
                        logger.error("Failed to process queue \(queue.id): \(error)")
                    }
                }
            }
        }
    }
}

// Simple Async Semaphore implementation
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.count = value
    }

    func wait() async {
        count -= 1
        if count >= 0 {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        count += 1
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
```

### 課題2: チェックのタイムアウトとキャンセル

**解決策**: **TaskGroup with timeout**

```swift
extension CheckExecutionUseCaseImpl {
    func executeChecks(
        for entry: QueueEntry,
        timeout: TimeInterval = 1800  // 30 minutes
    ) async throws -> CheckExecutionResult {
        return try await withThrowingTaskGroup(of: CheckResult.self) { group in
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CheckExecutionError.timeout
            }

            // Add check execution tasks
            let checks = try await getRequiredChecks(for: entry)
            for check in checks {
                group.addTask {
                    try await self.executeCheck(check, pullRequest: entry.pullRequest)
                }
            }

            var results: [CheckResult] = []
            var timedOut = false

            // Collect results
            for try await result in group {
                if case .timeout = result as? CheckExecutionError {
                    timedOut = true
                    group.cancelAll()
                    break
                }

                results.append(result)

                // Fail fast: cancel remaining checks if one fails
                if case .failure = result.status {
                    group.cancelAll()
                    break
                }
            }

            if timedOut {
                throw CheckExecutionError.timeout
            }

            return CheckExecutionResult(
                allPassed: results.allSatisfy { $0.status == .success },
                results: results
            )
        }
    }
}
```

### 課題3: リトライロジック

**解決策**: **Exponential backoff with max retries**

```swift
class RetryPolicy {
    let maxRetries: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    init(maxRetries: Int = 3, baseDelay: TimeInterval = 1.0, maxDelay: TimeInterval = 60.0) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    func execute<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Don't retry on non-retriable errors
                if !isRetriable(error) {
                    throw error
                }

                // Calculate delay with exponential backoff
                let delay = min(
                    baseDelay * pow(2.0, Double(attempt)),
                    maxDelay
                )

                logger.warning("Attempt \(attempt + 1)/\(maxRetries + 1) failed: \(error). Retrying in \(delay)s...")

                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? RetryError.maxRetriesExceeded
    }

    private func isRetriable(_ error: Error) -> Bool {
        switch error {
        case is NetworkError, is TimeoutError:
            return true
        case let apiError as GitHubAPIError:
            switch apiError {
            case .rateLimitExceeded, .httpError(let status, _) where status >= 500:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }
}
```

### 課題4: キュー優先度

**解決策**: **Priority-based scheduling**

```swift
enum QueuePriority: Int, Comparable {
    case critical = 0  // Hotfix branches
    case high = 1      // Release branches
    case normal = 2    // Main/master
    case low = 3       // Feature branches

    static func < (lhs: QueuePriority, rhs: QueuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension Queue {
    var priority: QueuePriority {
        // Determine priority based on branch name
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
}

actor PriorityQueueScheduler {
    private var queues: [Queue] = []

    func schedule(_ queue: Queue) {
        queues.append(queue)
        queues.sort { $0.priority < $1.priority }
    }

    func nextQueue() -> Queue? {
        return queues.isEmpty ? nil : queues.removeFirst()
    }
}
```

## メトリクスとモニタリング

```swift
struct QueueMetrics {
    var queueSize: Gauge
    var processingDuration: Histogram
    var successRate: Counter
    var failureRate: Counter
    var waitTime: Histogram  // Time from enqueue to start processing

    func recordEnqueue(_ entry: QueueEntry, queueSize: Int) {
        self.queueSize.set(Double(queueSize))
    }

    func recordProcessingStart(_ entry: QueueEntry) {
        let waitTime = Date().timeIntervalSince(entry.enqueuedAt)
        self.waitTime.observe(waitTime)
    }

    func recordProcessingComplete(_ entry: QueueEntry, success: Bool, duration: TimeInterval) {
        self.processingDuration.observe(duration)

        if success {
            self.successRate.increment()
        } else {
            self.failureRate.increment()
        }
    }
}
```

## まとめ

### 改善された点
- ✅ 同時実行制限（Semaphore）
- ✅ タイムアウトとキャンセル
- ✅ リトライロジック（Exponential backoff）
- ✅ キュー優先度
- ✅ メトリクス収集

## 次回検討事項
1. デッドロック防止策
2. Queue starvation（優先度の低いキューが永遠に処理されない）対策
3. Graceful shutdown
