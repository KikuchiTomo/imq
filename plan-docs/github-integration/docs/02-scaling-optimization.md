# GitHub連携設計 - 第2回検討（スケーリングと最適化）

## 検討日
2025-12-10

## 前回の課題への対応

### 課題1: Polling頻度の最適化

**問題**: 固定60秒間隔では、アクティブなリポジトリでは遅延が大きく、非アクティブなリポジトリではレート制限の無駄遣い

**解決策**: **Adaptive Polling（適応的ポーリング）**

#### 実装方針

```swift
// Adaptive Polling Event Source
class GitHubAdaptivePollingEventSource: GitHubEventSource {
    private struct RepositoryPollingState {
        var interval: TimeInterval
        var consecutiveEmptyPolls: Int
        var lastEventTime: Date?

        static let minInterval: TimeInterval = 10   // 最短10秒
        static let maxInterval: TimeInterval = 300  // 最長5分
        static let defaultInterval: TimeInterval = 60
    }

    private var pollingStates: [String: RepositoryPollingState] = [:]

    private func adjustPollingInterval(
        repository: Repository,
        hadNewEvents: Bool
    ) {
        var state = pollingStates[repository.id] ?? RepositoryPollingState(
            interval: RepositoryPollingState.defaultInterval,
            consecutiveEmptyPolls: 0,
            lastEventTime: nil
        )

        if hadNewEvents {
            // New events found: decrease interval (poll more frequently)
            state.consecutiveEmptyPolls = 0
            state.lastEventTime = Date()
            state.interval = max(
                RepositoryPollingState.minInterval,
                state.interval * 0.75  // 25% faster
            )
        } else {
            // No new events: increase interval (poll less frequently)
            state.consecutiveEmptyPolls += 1

            if state.consecutiveEmptyPolls >= 3 {
                state.interval = min(
                    RepositoryPollingState.maxInterval,
                    state.interval * 1.5  // 50% slower
                )
            }
        }

        pollingStates[repository.id] = state
    }

    private func getNextPollTime(repository: Repository) -> Date {
        let state = pollingStates[repository.id] ?? RepositoryPollingState(
            interval: RepositoryPollingState.defaultInterval,
            consecutiveEmptyPolls: 0,
            lastEventTime: nil
        )

        return Date().addingTimeInterval(state.interval)
    }

    func start() async throws {
        // Priority queueでリポジトリを管理
        let queue = PriorityQueue<(Repository, Date)> { $0.1 < $1.1 }

        // Initialize queue
        for repository in repositories {
            queue.enqueue((repository, Date()))
        }

        while isRunning {
            guard let (repository, scheduledTime) = queue.dequeue() else {
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                continue
            }

            // Wait until scheduled time
            let now = Date()
            if scheduledTime > now {
                let waitTime = scheduledTime.timeIntervalSince(now)
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }

            // Poll events
            do {
                let events = try await pollEvents(repository: repository)
                let hadNewEvents = !events.isEmpty

                // Emit events
                for event in events {
                    emit(event)
                }

                // Adjust polling interval
                adjustPollingInterval(repository: repository, hadNewEvents: hadNewEvents)

                // Reschedule
                let nextPollTime = getNextPollTime(repository: repository)
                queue.enqueue((repository, nextPollTime))

            } catch {
                handleError(error, repository: repository)

                // Reschedule with current interval (don't adjust on error)
                let state = pollingStates[repository.id]!
                queue.enqueue((repository, Date().addingTimeInterval(state.interval)))
            }
        }
    }
}
```

#### 利点
- ✅ アクティブなリポジトリは高頻度でポーリング（最短10秒）
- ✅ 非アクティブなリポジトリは低頻度でポーリング（最長5分）
- ✅ レート制限の効率的な使用

### 課題2: 複数リポジトリのスケーリング

**問題**: 多数のリポジトリを監視する場合、レート制限やメモリ使用量が課題

**解決策**: **リポジトリグループとバッチ処理**

#### 実装方針

```swift
// Repository Grouping Strategy
enum RepositoryPriority {
    case high      // アクティブ、重要なリポジトリ
    case normal    // 通常のリポジトリ
    case low       // 非アクティブなリポジトリ
}

struct RepositoryGroup {
    let priority: RepositoryPriority
    let repositories: [Repository]
    let pollingInterval: TimeInterval

    var weight: Int {
        switch priority {
        case .high: return 3
        case .normal: return 2
        case .low: return 1
        }
    }
}

class GitHubBatchPollingEventSource: GitHubEventSource {
    private let groups: [RepositoryGroup]

    init(repositories: [Repository]) {
        // Group repositories by activity
        self.groups = Self.groupRepositories(repositories)
    }

    private static func groupRepositories(_ repositories: [Repository]) -> [RepositoryGroup] {
        var high: [Repository] = []
        var normal: [Repository] = []
        var low: [Repository] = []

        // TODO: Analyze repository activity to determine priority
        // For now, all repositories are normal priority
        normal = repositories

        return [
            RepositoryGroup(priority: .high, repositories: high, pollingInterval: 15),
            RepositoryGroup(priority: .normal, repositories: normal, pollingInterval: 60),
            RepositoryGroup(priority: .low, repositories: low, pollingInterval: 300)
        ]
    }

    func start() async throws {
        // Process groups concurrently with different intervals
        try await withThrowingTaskGroup(of: Void.self) { group in
            for repositoryGroup in groups {
                group.addTask {
                    try await self.processGroup(repositoryGroup)
                }
            }

            try await group.waitForAll()
        }
    }

    private func processGroup(_ group: RepositoryGroup) async throws {
        while isRunning {
            // Batch poll repositories in this group
            let batchSize = 5  // Process 5 repos at a time
            for batch in group.repositories.chunked(into: batchSize) {
                await withTaskGroup(of: Void.self) { taskGroup in
                    for repository in batch {
                        taskGroup.addTask {
                            do {
                                let events = try await self.pollEvents(repository: repository)
                                for event in events {
                                    self.emit(event)
                                }
                            } catch {
                                self.handleError(error, repository: repository)
                            }
                        }
                    }
                }

                // Small delay between batches to avoid rate limiting
                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
            }

            // Wait for next interval
            try await Task.sleep(nanoseconds: UInt64(group.pollingInterval * 1_000_000_000))
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
```

#### スケーリング戦略

```swift
// Rate Limit Budget Allocator
class RateLimitBudgetAllocator {
    private let hourlyBudget: Int = 5000  // GitHub rate limit
    private let safetyMargin: Double = 0.2  // Keep 20% as safety margin

    func allocateBudget(groups: [RepositoryGroup]) -> [RepositoryGroup: Int] {
        let availableBudget = Int(Double(hourlyBudget) * (1.0 - safetyMargin))

        // Calculate total weight
        let totalWeight = groups.reduce(0) { $0 + $1.weight * $1.repositories.count }

        // Allocate budget proportionally
        var allocation: [RepositoryGroup: Int] = [:]
        for group in groups {
            let groupWeight = group.weight * group.repositories.count
            let groupBudget = (availableBudget * groupWeight) / totalWeight
            allocation[group] = groupBudget
        }

        return allocation
    }

    func canPoll(group: RepositoryGroup, used: Int, allocated: Int) -> Bool {
        return used < allocated
    }
}
```

### 課題3: イベントの順序保証

**問題**: Webhook/Pollingで受信順序がバラバラになり、状態の整合性が崩れる可能性

**解決策**: **イベントシーケンス番号とバッファリング**

#### 実装方針

```swift
// Event Sequencer
actor EventSequencer {
    private struct SequencedEvent {
        let event: GitHubEvent
        let sequenceNumber: Int
        let timestamp: Date
    }

    private var buffer: [String: [SequencedEvent]] = [:]  // pullRequestID -> events
    private var nextExpected: [String: Int] = [:]  // pullRequestID -> next sequence number
    private let bufferTimeout: TimeInterval = 30  // 30 seconds

    func add(_ event: GitHubEvent, sequenceNumber: Int) async -> [GitHubEvent] {
        let prID = extractPullRequestID(event)

        // Initialize if first event for this PR
        if nextExpected[prID] == nil {
            nextExpected[prID] = sequenceNumber
        }

        // Add to buffer
        var events = buffer[prID] ?? []
        events.append(SequencedEvent(
            event: event,
            sequenceNumber: sequenceNumber,
            timestamp: Date()
        ))
        events.sort { $0.sequenceNumber < $1.sequenceNumber }
        buffer[prID] = events

        // Try to emit in-order events
        return emitReadyEvents(prID: prID)
    }

    private func emitReadyEvents(prID: String) -> [GitHubEvent] {
        guard var events = buffer[prID],
              var expected = nextExpected[prID] else {
            return []
        }

        var readyEvents: [GitHubEvent] = []

        while let first = events.first, first.sequenceNumber == expected {
            readyEvents.append(first.event)
            events.removeFirst()
            expected += 1
        }

        // Update state
        buffer[prID] = events
        nextExpected[prID] = expected

        // Clean up old buffers
        cleanupExpiredBuffers()

        return readyEvents
    }

    private func cleanupExpiredBuffers() {
        let now = Date()
        for (prID, events) in buffer {
            // If all buffered events are older than timeout, emit them anyway
            if let oldestEvent = events.first,
               now.timeIntervalSince(oldestEvent.timestamp) > bufferTimeout {
                // Force emit all buffered events
                buffer[prID] = []
                // Reset expected sequence
                if let lastEvent = events.last {
                    nextExpected[prID] = lastEvent.sequenceNumber + 1
                }
            }
        }
    }

    private func extractPullRequestID(_ event: GitHubEvent) -> String {
        switch event {
        case .pullRequestOpened(let pr),
             .pullRequestClosed(let pr),
             .pullRequestLabeled(let pr, _),
             .pullRequestUnlabeled(let pr, _):
            return pr.id.value
        default:
            return ""
        }
    }
}

// Usage in Event Source
class OrderedGitHubEventSource: GitHubEventSource {
    private let sequencer = EventSequencer()
    private var sequenceCounter = 0

    override func emit(_ event: GitHubEvent) {
        Task {
            let sequence = sequenceCounter
            sequenceCounter += 1

            let orderedEvents = await sequencer.add(event, sequenceNumber: sequence)
            for orderedEvent in orderedEvents {
                super.emit(orderedEvent)
            }
        }
    }
}
```

### 課題4: エラー回復と状態の整合性

**問題**: 一時的なエラー後、キューの状態とGitHubの状態が不整合になる可能性

**解決策**: **定期的な整合性チェックとリコンシリエーション（Reconciliation）**

#### 実装方針

```swift
// State Reconciler
class StateReconciler {
    private let queueRepository: QueueRepository
    private let githubGateway: GitHubGateway
    private let reconciliationInterval: TimeInterval = 600  // 10 minutes

    func start() async throws {
        while true {
            try await Task.sleep(nanoseconds: UInt64(reconciliationInterval * 1_000_000_000))

            do {
                try await reconcile()
            } catch {
                logger.error("Reconciliation failed: \(error)")
            }
        }
    }

    private func reconcile() async throws {
        logger.info("Starting state reconciliation...")

        // Get all queues
        let queues = try await queueRepository.findAll()

        for queue in queues {
            try await reconcileQueue(queue)
        }

        logger.info("State reconciliation completed")
    }

    private func reconcileQueue(_ queue: Queue) async throws {
        for entry in queue.entries {
            let pr = entry.pullRequest

            // Fetch latest state from GitHub
            let latestPR = try await githubGateway.fetchPullRequest(
                repository: pr.repository,
                number: pr.number
            )

            // Check for discrepancies
            if pr.headSHA != latestPR.headSHA {
                logger.warning("PR #\(pr.number) has been updated. Expected SHA: \(pr.headSHA), Actual: \(latestPR.headSHA)")
                // TODO: Handle outdated PR
            }

            if latestPR.isClosed {
                logger.warning("PR #\(pr.number) is closed but still in queue")
                // TODO: Remove from queue
            }

            // Check labels
            let hasLabel = latestPR.labels.contains { $0.name == config.triggerLabel }
            if !hasLabel {
                logger.warning("PR #\(pr.number) no longer has trigger label")
                // TODO: Remove from queue
            }
        }
    }
}
```

#### Circuit Breaker Pattern

```swift
// Circuit Breaker for GitHub API calls
actor CircuitBreaker {
    enum State {
        case closed      // Normal operation
        case open        // Too many failures, block requests
        case halfOpen    // Testing if service recovered
    }

    private var state: State = .closed
    private var failureCount: Int = 0
    private var lastFailureTime: Date?

    private let failureThreshold: Int = 5
    private let timeout: TimeInterval = 60  // 60 seconds
    private let successThreshold: Int = 2

    func call<T>(_ operation: () async throws -> T) async throws -> T {
        switch state {
        case .closed:
            do {
                let result = try await operation()
                onSuccess()
                return result
            } catch {
                onFailure()
                throw error
            }

        case .open:
            // Check if timeout has passed
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) > timeout {
                state = .halfOpen
                return try await call(operation)
            } else {
                throw CircuitBreakerError.circuitOpen
            }

        case .halfOpen:
            do {
                let result = try await operation()
                onSuccess()
                return result
            } catch {
                state = .open
                lastFailureTime = Date()
                throw error
            }
        }
    }

    private func onSuccess() {
        failureCount = 0
        if state == .halfOpen {
            state = .closed
        }
    }

    private func onFailure() {
        failureCount += 1
        lastFailureTime = Date()

        if failureCount >= failureThreshold {
            state = .open
        }
    }
}

enum CircuitBreakerError: Error {
    case circuitOpen
}

// Usage in GitHub API Client
class GitHubAPIClientWithCircuitBreaker: GitHubAPIClient {
    private let circuitBreaker = CircuitBreaker()
    private let baseClient: GitHubAPIClient

    func request<T: Decodable>(_ endpoint: GitHubAPIEndpoint, body: Data?) async throws -> T {
        return try await circuitBreaker.call {
            try await baseClient.request(endpoint, body: body)
        }
    }
}
```

## GraphQL APIの活用

### REST vs GraphQL

| | REST API | GraphQL API |
|---|----------|-------------|
| **レート制限** | 5,000 req/hour | 5,000 points/hour |
| **データ取得** | 複数リクエスト必要 | 1リクエストで完結 |
| **柔軟性** | 固定レスポンス | 必要なデータのみ |
| **学習コスト** | 低 | 高 |

### GraphQL API使用例

```swift
// GraphQL Query for Pull Request with all required data
let query = """
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      number
      title
      headRefName
      headRefOid
      baseRefName
      mergeable
      labels(first: 10) {
        nodes {
          name
        }
      }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              state
              contexts(first: 100) {
                nodes {
                  ... on StatusContext {
                    context
                    state
                  }
                  ... on CheckRun {
                    name
                    conclusion
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
"""

// Single request to get all data
let response = try await githubGraphQLClient.query(query, variables: [
    "owner": owner,
    "repo": repo,
    "number": number
])
```

**利点**:
- ✅ 1回のリクエストで全データ取得（REST APIでは3-4回必要）
- ✅ 必要なフィールドのみ取得（データ転送量削減）
- ✅ レート制限の効率的な使用

**欠点**:
- ❌ クエリの構築が複雑
- ❌ エラーハンドリングがREST APIと異なる

**推奨**: 複雑なデータ取得はGraphQL、シンプルな操作はRESTを使い分ける

## まとめ

### 改善された点

1. ✅ **Adaptive Polling**: リポジトリのアクティビティに応じて頻度を調整
2. ✅ **バッチ処理**: 複数リポジトリを効率的に処理
3. ✅ **イベント順序保証**: シーケンス番号とバッファリング
4. ✅ **整合性チェック**: 定期的なリコンシリエーション
5. ✅ **Circuit Breaker**: エラー時の自動復旧

### パフォーマンス予測

| リポジトリ数 | レート制限使用量 | 平均遅延 |
|------------|----------------|---------|
| 1-5 | ~500/hour | <30秒 |
| 6-20 | ~2000/hour | <60秒 |
| 21-50 | ~4000/hour | <120秒 |

## 次回検討事項
1. WebhookとPollingのシームレスな切り替え
2. GitHub Apps認証の導入（より高いレート制限）
3. イベントのプライオリティキュー
4. メトリクスとモニタリング
