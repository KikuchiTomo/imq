# Queue Processing Design - 第1回検討

## 検討日
2025-12-10

## 目的
IMQのキュー処理ロジックを設計し、PR の enqueue から merge までのフローを定義する。

## キュー処理の全体フロー

```
┌─────────────────────┐
│  Label Added Event  │
└──────────┬──────────┘
           ↓
    ┌──────────────┐
    │  Enqueueing  │
    └──────┬───────┘
           ↓
    ┌──────────────┐
    │  Queue Entry │
    │  (pending)   │
    └──────┬───────┘
           ↓
┌──────────────────────┐
│  Queue Processing    │
│  Loop (every 30s)    │
└──────────┬───────────┘
           ↓
    ┌──────────────┐
    │  Conflict?   │
    └──┬───────┬───┘
       │       │
      Yes      No
       │       ↓
       │  ┌────────────┐
       │  │ Up to date?│
       │  └──┬─────┬───┘
       │     │    No
       │     │     ↓
       │    Yes  ┌────────┐
       │     │   │ Update │
       │     │   │  PR    │
       │     │   └────┬───┘
       │     │        │
       │     └────────┘
       │          ↓
       │    ┌──────────┐
       │    │ Execute  │
       │    │  Checks  │
       │    └────┬─────┘
       │         │
       │    ┌────┴──────┐
       │   Pass       Fail
       │    │           │
       │    ↓           ↓
       │  ┌────┐    ┌───────┐
       │  │Merge│    │Remove │
       │  └────┘    │& Notify│
       │            └───────┘
       ↓
    ┌────────┐
    │ Remove │
    │& Notify│
    └────────┘
```

## 1. Queue データ構造

### 1.1 Queue Entity

```swift
// Domain/Entities/Queue.swift
struct Queue {
    let id: QueueID
    let repository: Repository
    let baseBranch: String
    private(set) var entries: [QueueEntry]
    let createdAt: Date

    // Invariants
    // - entries are sorted by position (ascending)
    // - positions are contiguous (0, 1, 2, ...)

    /**
     * Add entry to the end of queue
     */
    mutating func enqueue(_ entry: QueueEntry) {
        let position = entries.count
        var newEntry = entry
        newEntry.position = position
        entries.append(newEntry)
    }

    /**
     * Remove and return the first entry
     */
    mutating func dequeue() -> QueueEntry? {
        guard !entries.isEmpty else {
            return nil
        }

        let first = entries.removeFirst()

        // Reindex remaining entries
        for (index, var entry) in entries.enumerated() {
            entry.position = index
            entries[index] = entry
        }

        return first
    }

    /**
     * Remove entry by ID
     */
    mutating func remove(entryID: QueueEntryID) {
        entries.removeAll { $0.id == entryID }

        // Reindex
        for (index, var entry) in entries.enumerated() {
            entry.position = index
            entries[index] = entry
        }
    }

    /**
     * Get entry position (1-indexed for display)
     */
    func position(of entryID: QueueEntryID) -> Int? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return nil
        }
        return index + 1  // 1-indexed
    }

    /**
     * Get the entry currently being processed (first in queue)
     */
    var currentEntry: QueueEntry? {
        return entries.first
    }
}

struct QueueEntry {
    let id: QueueEntryID
    let pullRequest: PullRequest
    var position: Int
    var status: QueueEntryStatus
    let enqueuedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var checks: [Check]

    var isProcessing: Bool {
        return position == 0 && (status == .updating || status == .checking)
    }
}

enum QueueEntryStatus: String, Codable {
    case pending      // Waiting in queue
    case updating     // PR update in progress
    case checking     // Checks running
    case ready        // All checks passed, ready to merge
    case failed       // Failed (conflict or check failure)
    case cancelled    // Cancelled by user
}
```

### 1.2 Queue Invariants（不変条件）

キューの整合性を保つための不変条件：

1. **Position Contiguity**: positions は 0 から連続した整数
2. **Single Processing**: 同時に処理できるのは position = 0 のエントリのみ
3. **Status Transition**: ステータス遷移は決まった順序のみ
4. **Unique PR**: 同じPRは1つのキューに1回だけ

```swift
extension Queue {
    /**
     * Validate queue invariants
     */
    func validate() throws {
        // Check position contiguity
        for (index, entry) in entries.enumerated() {
            guard entry.position == index else {
                throw QueueError.invalidPosition(
                    expected: index,
                    actual: entry.position
                )
            }
        }

        // Check unique PRs
        let prIDs = entries.map { $0.pullRequest.id }
        let uniquePRIDs = Set(prIDs)
        guard prIDs.count == uniquePRIDs.count else {
            throw QueueError.duplicatePR
        }

        // Check only first entry can be processing
        for (index, entry) in entries.enumerated() {
            if index > 0 && entry.isProcessing {
                throw QueueError.multipleProcessing
            }
        }
    }
}

enum QueueError: Error {
    case invalidPosition(expected: Int, actual: Int)
    case duplicatePR
    case multipleProcessing
    case entryNotFound
}
```

## 2. Queue Processing Loop

### 2.1 Main Processing Loop

```swift
// Domain/UseCases/QueueProcessingUseCase.swift
protocol QueueProcessingUseCase {
    func processQueue(
        for baseBranch: String,
        in repository: Repository
    ) async throws
}

final class QueueProcessingUseCaseImpl: QueueProcessingUseCase {
    private let queueRepository: QueueRepository
    private let conflictDetectionUseCase: ConflictDetectionUseCase
    private let prUpdateUseCase: PRUpdateUseCase
    private let checkExecutionUseCase: CheckExecutionUseCase
    private let mergeUseCase: MergeUseCase
    private let notificationService: NotificationService
    private let eventBus: EventBus

    func processQueue(
        for baseBranch: String,
        in repository: Repository
    ) async throws {
        // 1. Load queue
        guard var queue = try await queueRepository.find(
            baseBranch: baseBranch,
            repository: repository
        ) else {
            return  // No queue for this branch
        }

        // 2. Validate invariants
        try queue.validate()

        // 3. Get current entry (first in queue)
        guard var currentEntry = queue.currentEntry else {
            return  // Empty queue
        }

        // 4. Skip if already processing
        if currentEntry.isProcessing {
            logger.debug("Entry #\(currentEntry.pullRequest.number) is already processing")
            return
        }

        // 5. Process entry
        do {
            currentEntry = try await processEntry(currentEntry, queue: &queue)

            // 6. Update queue
            queue.entries[0] = currentEntry
            try await queueRepository.save(queue)

        } catch {
            // Handle processing error
            try await handleProcessingError(entry: currentEntry, queue: &queue, error: error)
        }
    }

    private func processEntry(
        _ entry: QueueEntry,
        queue: inout Queue
    ) async throws -> QueueEntry {
        var updatedEntry = entry
        updatedEntry.startedAt = Date()

        // Step 1: Conflict Detection
        logger.info("Processing PR #\(entry.pullRequest.number): Conflict detection")
        let conflictResult = try await conflictDetectionUseCase.detectConflict(
            for: entry.pullRequest
        )

        switch conflictResult {
        case .conflicted:
            // Remove from queue
            try await handleConflict(entry: entry, queue: &queue)
            throw QueueProcessingError.conflicted

        case .outdated:
            // Update PR
            logger.info("PR #\(entry.pullRequest.number) is outdated, updating...")
            updatedEntry.status = .updating
            try await queueRepository.save(queue)

            let updatedPR = try await prUpdateUseCase.updatePullRequest(entry.pullRequest)
            updatedEntry.pullRequest = updatedPR

        case .upToDate:
            logger.info("PR #\(entry.pullRequest.number) is up to date")
        }

        // Step 2: Execute Checks
        logger.info("Processing PR #\(entry.pullRequest.number): Executing checks")
        updatedEntry.status = .checking
        try await queueRepository.save(queue)

        let checkResult = try await checkExecutionUseCase.executeChecks(for: updatedEntry)

        if checkResult.allPassed {
            // Step 3: Merge
            logger.info("Processing PR #\(entry.pullRequest.number): All checks passed, merging")
            updatedEntry.status = .ready

            try await mergeUseCase.merge(pullRequest: updatedEntry.pullRequest)

            updatedEntry.completedAt = Date()

            // Remove from queue
            queue.dequeue()
            try await queueRepository.save(queue)

            // Notify success
            try await notificationService.notifyMergeCompleted(entry: updatedEntry)
            eventBus.emit(.pullRequestMerged(updatedEntry.pullRequest))

        } else {
            // Checks failed
            try await handleCheckFailure(
                entry: updatedEntry,
                queue: &queue,
                results: checkResult.results
            )
            throw QueueProcessingError.checksFailed
        }

        return updatedEntry
    }
}

enum QueueProcessingError: Error {
    case conflicted
    case checksFailed
    case mergeFailed(underlying: Error)
}
```

### 2.2 Queue Processor Service

```swift
// Application/Services/QueueProcessor.swift
actor QueueProcessor {
    private let queueRepository: QueueRepository
    private let queueProcessingUseCase: QueueProcessingUseCase
    private let processingInterval: TimeInterval = 30  // 30 seconds

    private var isRunning = false
    private var processingTasks: [QueueID: Task<Void, Never>] = [:]

    func start() async {
        isRunning = true

        while isRunning {
            do {
                // Get all queues
                let queues = try await queueRepository.findAll()

                // Process each queue
                for queue in queues {
                    // Skip if already processing
                    guard processingTasks[queue.id] == nil else {
                        continue
                    }

                    // Start processing task
                    let task = Task {
                        do {
                            try await queueProcessingUseCase.processQueue(
                                for: queue.baseBranch,
                                in: queue.repository
                            )
                        } catch {
                            logger.error("Queue processing failed for \(queue.id): \(error)")
                        }

                        // Remove from processing tasks
                        await self.removeProcessingTask(queueID: queue.id)
                    }

                    processingTasks[queue.id] = task
                }

                // Wait for interval
                try await Task.sleep(nanoseconds: UInt64(processingInterval * 1_000_000_000))

            } catch {
                logger.error("Queue processor error: \(error)")
            }
        }
    }

    func stop() async {
        isRunning = false

        // Cancel all processing tasks
        for task in processingTasks.values {
            task.cancel()
        }
        processingTasks.removeAll()
    }

    private func removeProcessingTask(queueID: QueueID) {
        processingTasks.removeValue(forKey: queueID)
    }
}
```

## 3. Error Handling

### 3.1 エラーの種類

```swift
enum QueueProcessingError: Error {
    // Recoverable errors
    case conflicted
    case checksFailed
    case prUpdateFailed(underlying: Error)

    // Fatal errors
    case queueCorrupted
    case repositoryNotFound
}
```

### 3.2 エラーハンドリング戦略

```swift
extension QueueProcessingUseCaseImpl {
    private func handleConflict(
        entry: QueueEntry,
        queue: inout Queue
    ) async throws {
        logger.warning("PR #\(entry.pullRequest.number) has conflicts")

        // Remove from queue
        queue.remove(entryID: entry.id)
        try await queueRepository.save(queue)

        // Remove trigger label
        try await githubGateway.removeLabelFromPullRequest(
            repository: entry.pullRequest.repository,
            pullRequestNumber: entry.pullRequest.number,
            label: config.triggerLabel
        )

        // Notify assignees
        try await notificationService.notifyConflictDetected(entry: entry)

        // Emit event
        eventBus.emit(.queueEntryRemoved(entry, reason: .conflicted))
    }

    private func handleCheckFailure(
        entry: QueueEntry,
        queue: inout Queue,
        results: [CheckResult]
    ) async throws {
        logger.warning("PR #\(entry.pullRequest.number) checks failed")

        // Remove from queue
        queue.remove(entryID: entry.id)
        try await queueRepository.save(queue)

        // Remove trigger label
        try await githubGateway.removeLabelFromPullRequest(
            repository: entry.pullRequest.repository,
            pullRequestNumber: entry.pullRequest.number,
            label: config.triggerLabel
        )

        // Notify assignees with failed check details
        try await notificationService.notifyCheckFailed(
            entry: entry,
            results: results
        )

        // Emit event
        eventBus.emit(.queueEntryRemoved(entry, reason: .checksFailed(results)))
    }

    private func handleProcessingError(
        entry: QueueEntry,
        queue: inout Queue,
        error: Error
    ) async throws {
        logger.error("Processing error for PR #\(entry.pullRequest.number): \(error)")

        // Classify error
        switch error {
        case QueueProcessingError.conflicted,
             QueueProcessingError.checksFailed:
            // Already handled
            break

        case let QueueProcessingError.prUpdateFailed(underlying):
            // Retry later (keep in queue)
            logger.warning("PR update failed, will retry: \(underlying)")

        default:
            // Unknown error: notify and keep in queue
            try await notificationService.notifyError(entry: entry, error: error)
        }
    }
}
```

## 4. Queueing Use Case

### 4.1 Enqueue Logic

```swift
// Domain/UseCases/QueueingUseCase.swift
protocol QueueingUseCase {
    func enqueuePullRequest(
        _ pullRequest: PullRequest,
        to baseBranch: String
    ) async throws -> QueueEntry
}

final class QueueingUseCaseImpl: QueueingUseCase {
    private let queueRepository: QueueRepository
    private let pullRequestRepository: PullRequestRepository
    private let notificationService: NotificationService
    private let configurationRepository: ConfigurationRepository
    private let eventBus: EventBus

    func enqueuePullRequest(
        _ pullRequest: PullRequest,
        to baseBranch: String
    ) async throws -> QueueEntry {
        // 1. Get or create queue
        var queue = try await queueRepository.findOrCreate(
            baseBranch: baseBranch,
            repository: pullRequest.repository
        )

        // 2. Check if PR is already in queue
        if queue.entries.contains(where: { $0.pullRequest.id == pullRequest.id }) {
            throw QueueingError.alreadyInQueue
        }

        // 3. Validate PR can be enqueued
        try validatePullRequest(pullRequest)

        // 4. Create queue entry
        let entry = QueueEntry(
            id: QueueEntryID(),
            pullRequest: pullRequest,
            position: queue.entries.count,
            status: .pending,
            enqueuedAt: Date(),
            startedAt: nil,
            completedAt: nil,
            checks: []
        )

        // 5. Add to queue
        queue.enqueue(entry)
        try await queueRepository.save(queue)

        // 6. Save PR
        try await pullRequestRepository.save(pullRequest)

        // 7. Notify
        let config = try await configurationRepository.load()
        let position = queue.position(of: entry.id) ?? 0

        try await notificationService.notifyEnqueued(
            entry: entry,
            position: position,
            template: config.notificationTemplates.queueEnqueued
        )

        // 8. Emit event
        eventBus.emit(.queueEntryAdded(entry, queue: queue))

        logger.info("Enqueued PR #\(pullRequest.number) to \(baseBranch) queue at position \(position)")

        return entry
    }

    private func validatePullRequest(_ pr: PullRequest) throws {
        // Check if PR is open
        guard pr.state == .open else {
            throw QueueingError.pullRequestClosed
        }

        // Check if PR is not draft
        guard !pr.isDraft else {
            throw QueueingError.pullRequestDraft
        }

        // Check if PR is not conflicted
        guard !pr.isConflicted else {
            throw QueueingError.pullRequestConflicted
        }
    }
}

enum QueueingError: Error {
    case alreadyInQueue
    case pullRequestClosed
    case pullRequestDraft
    case pullRequestConflicted
    case invalidBaseBranch
}
```

## 検討事項と課題

### ✅ 良い点
1. **明確な状態遷移**: pending → updating → checking → ready/failed
2. **不変条件の保証**: position の連続性、unique PR
3. **エラーハンドリング**: conflict, check failure ごとに適切な処理

### ⚠️ 潜在的な問題点
1. **並行処理**: 複数のキューを同時に処理する場合のリソース管理
2. **長時間実行**: check実行に時間がかかる場合、他のPRが待たされる
3. **リトライロジック**: 一時的なエラーからの回復方法が不明確
4. **キュー優先度**: 全てのキューが同じ優先度で処理される

## 次回検討事項
1. 並行処理の制御（同時に処理できるキュー数の制限）
2. チェックのタイムアウトとキャンセル処理
3. リトライロジックの詳細設計
4. キュー優先度の導入
5. メトリクスとモニタリング
