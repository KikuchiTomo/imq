# GitHub連携設計 - 第3回検討（最終設計とベストプラクティス）

## 検討日
2025-12-10

## 前回までの成果

- ✅ Adaptive Polling（適応的ポーリング）
- ✅ バッチ処理とスケーリング戦略
- ✅ イベント順序保証
- ✅ Circuit Breaker pattern
- ✅ State Reconciliation

## 最終設計

### 1. GitHub Apps認証の導入（推奨）

#### Personal Access Token vs GitHub Apps

| | Personal Access Token | GitHub Apps |
|---|----------------------|-------------|
| **レート制限** | 5,000/hour | 5,000/hour (per installation) |
| **認証** | ユーザーベース | アプリベース |
| **権限** | ユーザーの権限 | 細粒度の権限 |
| **スケール** | 単一ユーザー | 複数installation |
| **セキュリティ** | トークン漏洩リスク | Private key + JWT |

#### GitHub Apps実装

```swift
// GitHub App Authenticator
class GitHubAppAuthenticator {
    private let appID: String
    private let privateKey: String
    private let installationID: String

    /**
     * Generate JWT for GitHub App
     */
    private func generateJWT() throws -> String {
        let header = ["alg": "RS256", "typ": "JWT"]
        let now = Date()
        let payload: [String: Any] = [
            "iat": Int(now.timeIntervalSince1970) - 60,  // Issued 60 seconds ago
            "exp": Int(now.timeIntervalSince1970) + 600,  // Expires in 10 minutes
            "iss": appID
        ]

        // Sign with private key
        return try JWT.encode(header: header, payload: payload, privateKey: privateKey)
    }

    /**
     * Get installation access token
     */
    func getInstallationToken() async throws -> String {
        let jwt = try generateJWT()

        var request = HTTPClientRequest(
            url: "https://api.github.com/app/installations/\(installationID)/access_tokens"
        )
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(jwt)")
        request.headers.add(name: "Accept", value: "application/vnd.github+json")

        let response = try await httpClient.execute(request)
        let data = try await response.body.collect(upTo: 1024 * 1024)

        struct TokenResponse: Codable {
            let token: String
            let expiresAt: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: Data(buffer: data))
        return tokenResponse.token
    }
}

// Token Cache (access tokens expire after 1 hour)
actor GitHubAppTokenCache {
    private var token: String?
    private var expiresAt: Date?

    func getToken(authenticator: GitHubAppAuthenticator) async throws -> String {
        // Check if cached token is still valid
        if let token = token,
           let expiresAt = expiresAt,
           Date() < expiresAt.addingTimeInterval(-300) {  // Refresh 5 min before expiry
            return token
        }

        // Fetch new token
        let newToken = try await authenticator.getInstallationToken()
        self.token = newToken
        self.expiresAt = Date().addingTimeInterval(3600)  // 1 hour

        return newToken
    }

    func invalidate() {
        token = nil
        expiresAt = nil
    }
}
```

#### 設定ファイルの拡張

```bash
# .env
# GitHub App Configuration (推奨)
IMQ_GITHUB_APP_ID=123456
IMQ_GITHUB_APP_PRIVATE_KEY_PATH=/path/to/private-key.pem
IMQ_GITHUB_APP_INSTALLATION_ID=789012

# または Personal Access Token
IMQ_GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

### 2. WebhookとPollingのシームレスな切り替え

#### Dynamic Mode Switching

```swift
// GitHub Integration Manager
actor GitHubIntegrationManager {
    private var currentMode: GitHubIntegrationMode
    private var eventSource: GitHubEventSource?
    private let config: ApplicationConfiguration
    private let factory: GitHubEventSourceFactory

    init(config: ApplicationConfiguration) {
        self.config = config
        self.currentMode = config.githubMode
        self.factory = GitHubEventSourceFactory()
    }

    func start() async throws {
        eventSource = factory.create(
            mode: currentMode,
            config: config,
            apiClient: apiClient,
            repositories: repositories
        )

        try await eventSource?.start()

        // Monitor health and auto-switch if needed
        startHealthMonitoring()
    }

    func switchMode(to newMode: GitHubIntegrationMode, reason: String) async throws {
        logger.info("Switching GitHub integration mode from \(currentMode) to \(newMode). Reason: \(reason)")

        // Stop current event source
        try await eventSource?.stop()

        // Create new event source
        eventSource = factory.create(
            mode: newMode,
            config: config,
            apiClient: apiClient,
            repositories: repositories
        )

        // Start new event source
        try await eventSource?.start()

        currentMode = newMode

        // Notify admin
        await notifyModeSwitch(from: currentMode, to: newMode, reason: reason)
    }

    private func startHealthMonitoring() {
        Task {
            while true {
                try await Task.sleep(nanoseconds: 60_000_000_000)  // 1 minute

                let health = await checkHealth()

                if !health.isHealthy {
                    // Auto-switch to polling if webhook is unhealthy
                    if currentMode == .webhook {
                        try await switchMode(
                            to: .polling,
                            reason: "Webhook health check failed: \(health.issue)"
                        )
                    }
                }
            }
        }
    }

    private func checkHealth() async -> HealthStatus {
        // Check if we're receiving events
        let lastEventTime = await eventSource?.lastEventTime ?? Date.distantPast
        let timeSinceLastEvent = Date().timeIntervalSince(lastEventTime)

        // If no events in 10 minutes and repositories are active, something might be wrong
        if timeSinceLastEvent > 600 {
            return HealthStatus(
                isHealthy: false,
                issue: "No events received in \(Int(timeSinceLastEvent)) seconds"
            )
        }

        return HealthStatus(isHealthy: true, issue: nil)
    }
}

struct HealthStatus {
    let isHealthy: Bool
    let issue: String?
}
```

### 3. イベントのプライオリティキュー

#### Priority-based Event Processing

```swift
// Event Priority
enum EventPriority: Int, Comparable {
    case critical = 0   // Label events, merge conflicts
    case high = 1       // Check completion, PR updates
    case normal = 2     // PR opened, comments
    case low = 3        // PR synchronize

    static func < (lhs: EventPriority, rhs: EventPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

extension GitHubEvent {
    var priority: EventPriority {
        switch self {
        case .pullRequestLabeled, .pullRequestUnlabeled:
            return .critical
        case .checkRunCompleted, .workflowRunCompleted:
            return .high
        case .pullRequestOpened, .pullRequestClosed:
            return .normal
        case .pullRequestSynchronized:
            return .low
        }
    }
}

// Priority Event Queue
actor PriorityEventQueue {
    private struct PrioritizedEvent: Comparable {
        let event: GitHubEvent
        let priority: EventPriority
        let timestamp: Date

        static func < (lhs: PrioritizedEvent, rhs: PrioritizedEvent) -> Bool {
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private var heap: BinaryHeap<PrioritizedEvent> = BinaryHeap()
    private var processing: Set<String> = []  // Event IDs being processed

    func enqueue(_ event: GitHubEvent) {
        let prioritized = PrioritizedEvent(
            event: event,
            priority: event.priority,
            timestamp: Date()
        )
        heap.insert(prioritized)
    }

    func dequeue() -> GitHubEvent? {
        guard let prioritized = heap.removeMin() else {
            return nil
        }

        let eventID = extractEventID(prioritized.event)
        processing.insert(eventID)

        return prioritized.event
    }

    func markCompleted(_ event: GitHubEvent) {
        let eventID = extractEventID(event)
        processing.remove(eventID)
    }

    private func extractEventID(_ event: GitHubEvent) -> String {
        // Generate unique ID for event
        switch event {
        case .pullRequestLabeled(let pr, let label):
            return "\(pr.id)-label-\(label.name)"
        case .checkRunCompleted(let checkRun):
            return "check-\(checkRun.id)"
        default:
            return UUID().uuidString
        }
    }
}

// Priority Event Processor
class PriorityEventProcessor {
    private let queue = PriorityEventQueue()
    private let handler: LabelEventHandlingUseCase

    func start() async {
        while true {
            if let event = await queue.dequeue() {
                await process(event)
                await queue.markCompleted(event)
            } else {
                // Wait for new events
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
            }
        }
    }

    private func process(_ event: GitHubEvent) async {
        do {
            switch event {
            case .pullRequestLabeled(let pr, let label):
                try await handler.handleLabelAdded(pullRequest: pr, label: label)
            case .pullRequestUnlabeled(let pr, let label):
                try await handler.handleLabelRemoved(pullRequest: pr, label: label)
            // ... other event types
            default:
                break
            }
        } catch {
            logger.error("Failed to process event: \(error)")
        }
    }
}
```

### 4. メトリクスとモニタリング

#### Metrics Collection

```swift
// GitHub Integration Metrics
struct GitHubIntegrationMetrics {
    // Event metrics
    var eventsReceived: Counter
    var eventsProcessed: Counter
    var eventsDropped: Counter

    // API metrics
    var apiCallsTotal: Counter
    var apiCallsSuccessful: Counter
    var apiCallsFailed: Counter
    var apiCallDuration: Histogram

    // Rate limit metrics
    var rateLimitRemaining: Gauge
    var rateLimitReset: Gauge

    // Polling metrics
    var pollingIntervalCurrent: Gauge
    var pollingErrorsTotal: Counter

    // Webhook metrics
    var webhookRequestsTotal: Counter
    var webhookRequestsRejected: Counter

    // Queue metrics
    var eventQueueSize: Gauge
    var eventProcessingDuration: Histogram
}

// Metrics Reporter
class MetricsReporter {
    private let metrics: GitHubIntegrationMetrics

    func recordEvent(_ event: GitHubEvent) {
        metrics.eventsReceived.increment()
    }

    func recordEventProcessed(_ event: GitHubEvent, duration: TimeInterval) {
        metrics.eventsProcessed.increment()
        metrics.eventProcessingDuration.observe(duration)
    }

    func recordAPICall(_ endpoint: GitHubAPIEndpoint, duration: TimeInterval, success: Bool) {
        metrics.apiCallsTotal.increment()

        if success {
            metrics.apiCallsSuccessful.increment()
        } else {
            metrics.apiCallsFailed.increment()
        }

        metrics.apiCallDuration.observe(duration)
    }

    func updateRateLimit(remaining: Int, resetAt: Date) {
        metrics.rateLimitRemaining.set(Double(remaining))
        metrics.rateLimitReset.set(resetAt.timeIntervalSince1970)
    }

    func exportPrometheus() -> String {
        // Export metrics in Prometheus format
        var output = ""

        output += "# TYPE imq_github_events_received_total counter\n"
        output += "imq_github_events_received_total \(metrics.eventsReceived.value)\n"

        output += "# TYPE imq_github_api_calls_total counter\n"
        output += "imq_github_api_calls_total \(metrics.apiCallsTotal.value)\n"

        output += "# TYPE imq_github_rate_limit_remaining gauge\n"
        output += "imq_github_rate_limit_remaining \(metrics.rateLimitRemaining.value)\n"

        // ... other metrics

        return output
    }
}
```

#### Health Check Endpoint

```swift
// Vapor route for health check
app.get("health", "github") { req async throws -> GitHubHealthResponse in
    let integrationManager = req.application.integrationManager

    let health = await integrationManager.checkHealth()
    let metrics = await integrationManager.getMetrics()

    return GitHubHealthResponse(
        status: health.isHealthy ? "healthy" : "unhealthy",
        mode: integrationManager.currentMode.rawValue,
        lastEventTime: await integrationManager.lastEventTime,
        rateLimitRemaining: metrics.rateLimitRemaining.value,
        rateLimitReset: Date(timeIntervalSince1970: metrics.rateLimitReset.value),
        eventsReceived: metrics.eventsReceived.value,
        eventsProcessed: metrics.eventsProcessed.value,
        apiCallsTotal: metrics.apiCallsTotal.value,
        apiErrors: metrics.apiCallsFailed.value
    )
}

struct GitHubHealthResponse: Content {
    let status: String
    let mode: String
    let lastEventTime: Date?
    let rateLimitRemaining: Double
    let rateLimitReset: Date
    let eventsReceived: Int
    let eventsProcessed: Int
    let apiCallsTotal: Int
    let apiErrors: Int
}
```

### 5. テスト戦略

#### Unit Tests

```swift
// Mock GitHub API Client
class MockGitHubAPIClient: GitHubAPIClient {
    var responses: [GitHubAPIEndpoint: Any] = [:]
    var callCount: [GitHubAPIEndpoint: Int] = [:]

    func request<T: Decodable>(_ endpoint: GitHubAPIEndpoint, body: Data?) async throws -> T {
        callCount[endpoint, default: 0] += 1

        guard let response = responses[endpoint] as? T else {
            throw MockError.noResponseConfigured
        }

        return response
    }

    func configure<T: Encodable>(_ endpoint: GitHubAPIEndpoint, response: T) {
        responses[endpoint] = response
    }
}

// Test case
class GitHubGatewayTests: XCTestCase {
    func testFetchPullRequest() async throws {
        // Arrange
        let mockClient = MockGitHubAPIClient()
        let gateway = GitHubGatewayImpl(apiClient: mockClient)

        let mockPR = GitHubPullRequestResponse(
            id: 1,
            number: 123,
            title: "Test PR",
            // ...
        )

        let endpoint = GitHubAPIEndpoint.pullRequest(owner: "test", repo: "repo", number: 123)
        mockClient.configure(endpoint, response: mockPR)

        // Act
        let result = try await gateway.fetchPullRequest(
            repository: Repository(owner: "test", name: "repo"),
            number: 123
        )

        // Assert
        XCTAssertEqual(result.number, 123)
        XCTAssertEqual(mockClient.callCount[endpoint], 1)
    }
}
```

#### Integration Tests

```swift
// Test with actual GitHub API (test repository)
class GitHubIntegrationTests: XCTestCase {
    var client: GitHubAPIClient!

    override func setUp() async throws {
        // Use test token from environment
        guard let token = ProcessInfo.processInfo.environment["GITHUB_TEST_TOKEN"] else {
            throw XCTSkip("GITHUB_TEST_TOKEN not set")
        }

        client = GitHubAPIClientImpl(token: token, httpClient: HTTPClient.shared)
    }

    func testFetchPullRequest() async throws {
        // Use a known test PR in a test repository
        let endpoint = GitHubAPIEndpoint.pullRequest(
            owner: "imq-test",
            repo: "test-repo",
            number: 1
        )

        let pr: GitHubPullRequestResponse = try await client.request(endpoint)

        XCTAssertEqual(pr.number, 1)
        XCTAssertFalse(pr.title.isEmpty)
    }

    func testRateLimitHandling() async throws {
        // Verify rate limit headers are processed correctly
        let endpoint = GitHubAPIEndpoint.repositoryEvents(owner: "imq-test", repo: "test-repo")

        let _: [GitHubEventResponse] = try await client.request(endpoint)

        // Check that rate limit info is updated
        // (This requires accessing internal state or using a spy)
    }
}
```

#### End-to-End Tests

```swift
// E2E test scenario
class GitHubE2ETests: XCTestCase {
    func testFullPollingCycle() async throws {
        // 1. Start polling event source
        let eventSource = GitHubPollingEventSource(/*...*/)
        try await eventSource.start()

        // 2. Create a PR in test repository
        let pr = try await createTestPR()

        // 3. Add trigger label
        try await addLabel(pr: pr, label: "merge-queue")

        // 4. Wait for event to be detected
        let receivedEvent = try await waitForEvent(timeout: 120)

        // 5. Verify event
        guard case .pullRequestLabeled(let eventPR, let label) = receivedEvent else {
            XCTFail("Expected pullRequestLabeled event")
            return
        }

        XCTAssertEqual(eventPR.number, pr.number)
        XCTAssertEqual(label.name, "merge-queue")

        // Cleanup
        try await closePR(pr)
        try await eventSource.stop()
    }
}
```

## ベストプラクティスまとめ

### 認証
1. ✅ **GitHub Apps** を使用（スケーラビリティ、セキュリティ）
2. ✅ Private keyは環境変数で管理
3. ✅ Installation tokenはキャッシュ（1時間有効）

### イベント処理
1. ✅ **Adaptive Polling** でレート制限を節約
2. ✅ **Priority Queue** で重要なイベントを優先処理
3. ✅ **Event Sequencing** で順序を保証

### エラーハンドリング
1. ✅ **Circuit Breaker** で障害の伝播を防止
2. ✅ **Exponential Backoff** でリトライ
3. ✅ **State Reconciliation** で整合性を維持

### モニタリング
1. ✅ **Metrics** を収集（Prometheus format）
2. ✅ **Health Check** エンドポイントを提供
3. ✅ **Auto Mode Switching** で自動復旧

### テスト
1. ✅ **Unit Tests** でロジックを検証
2. ✅ **Integration Tests** で実際のAPIをテスト
3. ✅ **E2E Tests** でフルシナリオを検証

## 実装ファイルリスト

```
/imq-core/Sources/IMQCore/Data/Gateways/GitHub/
├── GitHubAPIEndpoint.swift                    # API endpoint定義
├── GitHubAPIClient.swift                      # API client interface
├── GitHubAPIClientImpl.swift                  # REST API implementation
├── GitHubAppAuthenticator.swift               # GitHub Apps auth
├── GitHubAppTokenCache.swift                  # Token cache
├── GitHubGatewayImpl.swift                    # Gateway implementation
├── Models/
│   ├── GitHubPullRequestResponse.swift
│   ├── GitHubEventResponse.swift
│   ├── GitHubCheckRunResponse.swift
│   └── GitHubWorkflowRunResponse.swift
└── CircuitBreaker.swift                       # Circuit breaker

/imq-core/Sources/IMQCore/Data/EventSources/
├── GitHubEventSource.swift                    # Protocol
├── GitHubPollingEventSource.swift             # Polling implementation
├── GitHubAdaptivePollingEventSource.swift     # Adaptive polling
├── GitHubBatchPollingEventSource.swift        # Batch processing
├── GitHubWebhookEventSource.swift             # Webhook implementation
├── GitHubEventSourceFactory.swift             # Factory
├── WebhookServer.swift                        # Webhook HTTP server
├── EventSequencer.swift                       # Event ordering
├── PriorityEventQueue.swift                   # Priority queue
└── GitHubEvent.swift                          # Event types

/imq-core/Sources/IMQCore/Application/Services/
├── GitHubIntegrationManager.swift             # Integration manager
├── StateReconciler.swift                      # State reconciliation
├── RateLimitMonitor.swift                     # Rate limit monitoring
├── RateLimitBudgetAllocator.swift             # Budget allocation
└── MetricsReporter.swift                      # Metrics collection
```

## 最終チェックリスト

- ✅ Polling/Webhook両対応
- ✅ GitHub Apps認証
- ✅ Adaptive Polling
- ✅ レート制限対策
- ✅ Circuit Breaker
- ✅ Event Sequencing
- ✅ Priority Queue
- ✅ State Reconciliation
- ✅ Health Monitoring
- ✅ Metrics Collection
- ✅ 包括的なテスト

## 次の実装ドキュメント

GitHub連携の設計が完了したので、次は：
1. Queue Processing（キュー処理）の詳細設計
2. Check Execution（チェック実行）の詳細設計
