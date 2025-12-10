# GitHub連携設計 - 第1回検討

## 検討日
2025-12-10

## 目的
IMQとGitHubの連携方法を設計し、イベント検出、API呼び出し、エラーハンドリングの詳細を決定する。

## 前提条件
- ハイブリッドモード: PollingとWebhookの両方をサポート
- GitHub API v3 (REST API) を使用
- APIバージョニング: `2022-11-28`
- 必要なスコープ: `repo`, `workflow`, `read:org`

## GitHub連携の全体像

### イベントの流れ

```
┌──────────────────┐
│     GitHub       │
│   (Events)       │
└────┬─────────────┘
     │
     ├─────────────────────────┬──────────────────────┐
     │                         │                      │
     ↓ (Polling)               ↓ (Webhook)          ↓ (API Calls)
┌──────────────┐      ┌──────────────────┐    ┌────────────────┐
│  /events API │      │  Webhook POST    │    │  REST API      │
│              │      │  /webhook        │    │  Requests      │
└──────┬───────┘      └────────┬─────────┘    └────────┬───────┘
       │                       │                       │
       └───────────────┬───────┘                       │
                       ↓                               ↓
               ┌────────────────┐              ┌───────────────┐
               │  Event Stream  │              │  API Gateway  │
               └────────┬───────┘              └───────┬───────┘
                        │                              │
                        └──────────┬───────────────────┘
                                   ↓
                          ┌─────────────────┐
                          │  Use Cases      │
                          └─────────────────┘
```

## 1. イベント検出（Polling vs Webhook）

### 1.1 Polling Mode

#### 仕組み
- GitHub APIの`/repos/{owner}/{repo}/events`を定期的にポーリング
- 最後に取得したイベントIDを記録し、新規イベントのみ処理
- ETagを使用してレート制限を節約

#### 実装方針

```swift
// Polling Event Source
class GitHubPollingEventSource: GitHubEventSource {
    private let apiClient: GitHubAPIClient
    private let repositories: [Repository]
    private let interval: TimeInterval
    private var lastEventIDs: [String: String] = [:]  // repo -> eventID

    func start() async throws {
        while isRunning {
            for repository in repositories {
                do {
                    let events = try await pollEvents(repository: repository)
                    for event in events {
                        emit(event)
                    }
                } catch {
                    handleError(error, repository: repository)
                }
            }

            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func pollEvents(repository: Repository) async throws -> [GitHubEvent] {
        // Get last event ID from database
        let lastEventID = try await getLastEventID(repository: repository)

        // Fetch events
        let endpoint = GitHubAPIEndpoint.repositoryEvents(
            owner: repository.owner,
            repo: repository.name
        )

        let response: [GitHubEventResponse] = try await apiClient.request(endpoint)

        // Filter new events only
        let newEvents = response.filter { $0.id > (lastEventID ?? "0") }

        // Update last event ID
        if let latestEventID = newEvents.first?.id {
            try await saveLastEventID(repository: repository, eventID: latestEventID)
        }

        return try newEvents.compactMap { try parseEvent($0) }
    }
}
```

#### 利点
- ✅ 外部からのアクセス不要（ファイアウォール内で動作可能）
- ✅ 実装がシンプル
- ✅ self-hosted runnerと同じ方式

#### 欠点
- ❌ リアルタイム性が低い（最大で interval 秒の遅延）
- ❌ GitHub APIのレート制限を消費

#### 最適化策
1. **ETagの使用**
```swift
private var etags: [String: String] = [:]  // repo -> etag

private func pollEvents(repository: Repository) async throws -> [GitHubEvent] {
    var request = HTTPClientRequest(url: endpoint.path)

    // Add ETag header
    if let etag = etags[repository.id] {
        request.headers.add(name: "If-None-Match", value: etag)
    }

    let response = try await httpClient.execute(request)

    // Handle 304 Not Modified
    if response.status.code == 304 {
        return []  // No new events
    }

    // Save ETag for next request
    if let etag = response.headers.first(name: "ETag") {
        etags[repository.id] = etag
    }

    // ... parse events
}
```

2. **Conditional Requests**でレート制限を節約
   - `If-None-Match` header使用時、304レスポンスはレート制限にカウントされない

### 1.2 Webhook Mode

#### 仕組み
- GitHubからのWebhook POSTリクエストを受信
- HMAC-SHA256で署名検証
- イベントをパースして処理

#### 実装方針

```swift
// Webhook Event Source
class GitHubWebhookEventSource: GitHubEventSource {
    private let webhookServer: WebhookServer
    private let secret: String

    func start() async throws {
        try await webhookServer.start { [weak self] request in
            guard let self = self else { return }

            // Verify signature
            guard self.verifySignature(request) else {
                throw WebhookError.invalidSignature
            }

            // Parse event
            if let event = try? self.parseWebhook(request) {
                self.emit(event)
            }
        }
    }

    private func verifySignature(_ request: WebhookRequest) -> Bool {
        guard let signature = request.headers["X-Hub-Signature-256"] else {
            return false
        }

        // HMAC-SHA256 verification
        let computedSignature = "sha256=" + HMAC<SHA256>.authenticationCode(
            for: request.body,
            using: SymmetricKey(data: secret.data(using: .utf8)!)
        ).hexString

        return signature == computedSignature
    }

    private func parseWebhook(_ request: WebhookRequest) throws -> GitHubEvent? {
        guard let eventType = request.headers["X-GitHub-Event"] else {
            return nil
        }

        let payload = try JSONDecoder().decode([String: Any].self, from: request.body)

        switch eventType {
        case "pull_request":
            return try parsePullRequestWebhook(payload)
        case "pull_request_review":
            return try parsePullRequestReviewWebhook(payload)
        case "check_run":
            return try parseCheckRunWebhook(payload)
        case "workflow_run":
            return try parseWorkflowRunWebhook(payload)
        default:
            return nil
        }
    }
}
```

#### Webhook Server (Vapor)

```swift
// Webhook Server using Vapor
class WebhookServer {
    private let app: Application
    private let port: Int

    func start(handler: @escaping (WebhookRequest) async throws -> Void) async throws {
        app.post("webhook") { req -> HTTPStatus in
            let webhookRequest = WebhookRequest(
                headers: req.headers.dictionary,
                body: req.body.data ?? Data()
            )

            try await handler(webhookRequest)

            return .ok
        }

        try app.run()
    }
}
```

#### 利点
- ✅ リアルタイム性が高い（即座にイベント受信）
- ✅ GitHub APIのレート制限を消費しない

#### 欠点
- ❌ 外部からアクセス可能なエンドポイントが必要
- ❌ HTTPS設定が推奨される
- ❌ セキュリティリスクが高い（署名検証必須）

#### セキュリティ対策
1. **署名検証** (必須)
2. **Replay攻撃対策**
```swift
// Check timestamp to prevent replay attacks
guard let timestamp = request.headers["X-GitHub-Delivery-Timestamp"],
      let deliveryTime = Double(timestamp) else {
    throw WebhookError.missingTimestamp
}

let now = Date().timeIntervalSince1970
let age = now - deliveryTime

// Reject if webhook is older than 5 minutes
if age > 300 {
    throw WebhookError.webhookTooOld
}
```
3. **IP制限** (オプション)
```swift
// GitHub webhook IPs: https://api.github.com/meta
let githubWebhookIPs = [
    "192.30.252.0/22",
    "185.199.108.0/22",
    // ...
]

guard githubWebhookIPs.contains(where: { $0.contains(request.remoteIP) }) else {
    throw WebhookError.unauthorizedIP
}
```

### 1.3 Hybrid Mode（推奨）

#### 実装方針

```swift
// Event Source Factory
class GitHubEventSourceFactory {
    func create(
        mode: GitHubIntegrationMode,
        config: ApplicationConfiguration,
        apiClient: GitHubAPIClient,
        repositories: [Repository]
    ) -> GitHubEventSource {
        switch mode {
        case .polling:
            return GitHubPollingEventSource(
                apiClient: apiClient,
                repositories: repositories,
                interval: config.pollingInterval
            )

        case .webhook:
            let webhookServer = WebhookServer(port: config.apiPort)
            return GitHubWebhookEventSource(
                webhookServer: webhookServer,
                secret: config.githubWebhookSecret!
            )
        }
    }
}

// Mode switching
class GitHubIntegrationService {
    private var currentEventSource: GitHubEventSource?
    private let factory: GitHubEventSourceFactory

    func switchMode(to mode: GitHubIntegrationMode) async throws {
        // Stop current source
        try await currentEventSource?.stop()

        // Create and start new source
        currentEventSource = factory.create(mode: mode, ...)
        try await currentEventSource?.start()
    }
}
```

## 2. 処理すべきイベント

### 2.1 Pull Request Events

```swift
enum GitHubEvent {
    // PR lifecycle
    case pullRequestOpened(pullRequest: PullRequest)
    case pullRequestClosed(pullRequest: PullRequest)
    case pullRequestReopened(pullRequest: PullRequest)
    case pullRequestSynchronized(pullRequest: PullRequest)  // New commits pushed

    // Labels
    case pullRequestLabeled(pullRequest: PullRequest, label: Label)
    case pullRequestUnlabeled(pullRequest: PullRequest, label: Label)

    // Reviews
    case pullRequestReviewSubmitted(pullRequest: PullRequest, review: Review)

    // Checks
    case checkRunCompleted(checkRun: CheckRun)
    case workflowRunCompleted(workflowRun: WorkflowRun)
}
```

### 2.2 イベントフィルタリング

```swift
class EventFilter {
    private let config: SystemConfiguration

    func shouldProcess(_ event: GitHubEvent) -> Bool {
        switch event {
        case .pullRequestLabeled(_, let label):
            // Only process if label matches trigger label
            return label.name == config.triggerLabel

        case .pullRequestUnlabeled(_, let label):
            return label.name == config.triggerLabel

        case .checkRunCompleted(let checkRun):
            // Only process if check is required
            return checkRun.isRequired

        default:
            return true
        }
    }
}
```

## 3. GitHub API呼び出し

### 3.1 必要なAPI呼び出し

| 目的 | Endpoint | メソッド | 頻度 |
|------|----------|---------|------|
| PR取得 | `/repos/{owner}/{repo}/pulls/{number}` | GET | 高 |
| PR一覧 | `/repos/{owner}/{repo}/pulls` | GET | 中 |
| PR更新 | `/repos/{owner}/{repo}/pulls/{number}/update-branch` | PUT | 中 |
| PRマージ | `/repos/{owner}/{repo}/pulls/{number}/merge` | PUT | 中 |
| Branch Protection | `/repos/{owner}/{repo}/branches/{branch}/protection` | GET | 低 |
| Required Checks | `/repos/{owner}/{repo}/branches/{branch}/protection/required_status_checks` | GET | 低 |
| Workflow起動 | `/repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches` | POST | 中 |
| Workflow Run状態 | `/repos/{owner}/{repo}/actions/runs/{run_id}` | GET | 高 |
| Comment投稿 | `/repos/{owner}/{repo}/issues/{number}/comments` | POST | 中 |
| Label削除 | `/repos/{owner}/{repo}/issues/{number}/labels/{label}` | DELETE | 中 |
| イベント取得 | `/repos/{owner}/{repo}/events` | GET | 高（Pollingのみ） |

### 3.2 レート制限対策

GitHub APIのレート制限:
- **認証済み**: 5,000 requests/hour
- **Primary rate limit**: 最大並列リクエスト数の制限あり
- **Secondary rate limit**: 短時間に大量リクエストで一時的にブロック

#### 対策1: レート制限の監視

```swift
class RateLimitMonitor {
    private var remaining: Int?
    private var resetTime: Date?
    private var limit: Int?

    func update(from headers: HTTPHeaders) {
        if let remaining = headers.first(name: "X-RateLimit-Remaining"),
           let remainingInt = Int(remaining) {
            self.remaining = remainingInt
        }

        if let reset = headers.first(name: "X-RateLimit-Reset"),
           let resetTimestamp = Double(reset) {
            self.resetTime = Date(timeIntervalSince1970: resetTimestamp)
        }

        if let limit = headers.first(name: "X-RateLimit-Limit"),
           let limitInt = Int(limit) {
            self.limit = limitInt
        }
    }

    func shouldWait() -> Bool {
        guard let remaining = remaining else {
            return false
        }

        // Wait if less than 10% remaining
        if let limit = limit, remaining < (limit / 10) {
            return true
        }

        return remaining == 0
    }

    func waitTime() -> TimeInterval {
        guard let resetTime = resetTime else {
            return 0
        }

        let now = Date()
        if resetTime > now {
            return resetTime.timeIntervalSince(now)
        }

        return 0
    }
}
```

#### 対策2: リトライ戦略

```swift
class RetryPolicy {
    private let maxRetries: Int
    private let baseDelay: TimeInterval

    func execute<T>(_ operation: () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch let error as GitHubAPIError {
                lastError = error

                switch error {
                case .rateLimitExceeded(let resetAt, _):
                    // Wait until rate limit resets
                    let waitTime = resetAt.timeIntervalSinceNow
                    try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))

                case .httpError(let statusCode, _):
                    if statusCode >= 500 {
                        // Server error: exponential backoff
                        let delay = baseDelay * pow(2.0, Double(attempt))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } else {
                        // Client error: don't retry
                        throw error
                    }

                default:
                    throw error
                }
            }
        }

        throw lastError!
    }
}
```

## 4. エラーハンドリング

### 4.1 エラーの分類

```swift
enum GitHubIntegrationError: Error {
    // Network errors (retriable)
    case networkError(underlying: Error)
    case timeout

    // API errors
    case rateLimitExceeded(resetAt: Date)
    case notFound(resource: String)
    case unauthorized
    case forbidden(reason: String)

    // GitHub errors
    case conflictError(pullRequest: PullRequest)
    case checksFailed(pullRequest: PullRequest, checks: [Check])

    // Configuration errors (fatal)
    case invalidToken
    case repositoryNotAccessible(repository: String)
}
```

### 4.2 エラー処理戦略

```swift
class GitHubIntegrationErrorHandler {
    func handle(_ error: Error, context: ErrorContext) async {
        switch error {
        case let error as GitHubIntegrationError:
            switch error {
            case .rateLimitExceeded(let resetAt):
                // Log and wait
                logger.warning("Rate limit exceeded. Reset at \(resetAt)")
                await notifyRateLimitExceeded(resetAt: resetAt)

            case .networkError, .timeout:
                // Retry with exponential backoff
                logger.warning("Network error: \(error). Will retry.")

            case .conflictError(let pr):
                // Remove from queue and notify
                await handleConflict(pr: pr)

            case .invalidToken, .repositoryNotAccessible:
                // Fatal error: stop daemon
                logger.critical("Fatal error: \(error)")
                await shutdown()

            default:
                logger.error("Unhandled error: \(error)")
            }

        default:
            logger.error("Unknown error: \(error)")
        }
    }
}
```

## 検討事項と課題

### ✅ 良い点
1. **ハイブリッドモード**: 環境に応じて選択可能
2. **レート制限対策**: 監視とリトライ戦略
3. **セキュリティ**: Webhook署名検証、Replay攻撃対策

### ⚠️ 潜在的な問題点
1. **Polling頻度**: 60秒間隔は適切か？短すぎるとレート制限、長すぎると遅延
2. **複数リポジトリ**: 多数のリポジトリを監視する場合のスケーラビリティ
3. **イベントの順序保証**: Webhook/Pollingで受信順序がバラバラになる可能性
4. **エラーからの回復**: 一時的なエラー後の状態の整合性

## 次回検討事項
1. Polling頻度の最適化戦略
2. 複数リポジトリのスケーリング設計
3. イベント順序の保証方法
4. エラー回復と状態の整合性
5. GitHub GraphQL APIの活用検討
