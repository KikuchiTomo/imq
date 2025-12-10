# アーキテクチャ設計 - 第4回検討（API設計とバージョニング戦略）

## 検討日
2025-12-10

## 前回の問題点

### 致命的な設計上の問題
1. **エンドポイントの文字列直書き** - 言語道断
2. **GitHubAPIのエンドポイントも文字列直書き** - 変更に脆弱
3. **APIバージョニング戦略の欠如** - 外部依存性が高いのに対策なし
4. **データベースクエリの文字列直書き** - 型安全性の欠如

これらは全て、保守性、拡張性、変更への耐性を著しく低下させる。

## 改善策

### 1. imq-core REST API設計（型安全なエンドポイント定義）

#### Swift側: APIEndpoint Protocol

```swift
// /imq-core/Sources/IMQCore/Presentation/API/APIEndpoint.swift

/**
 * API Endpoint Protocol
 * 全てのエンドポイントはこのプロトコルに準拠
 */
protocol APIEndpoint {
    var method: HTTPMethod { get }
    var path: String { get }
    var version: APIVersion { get }
}

enum HTTPMethod: String {
    case GET, POST, PUT, PATCH, DELETE
}

enum APIVersion: String {
    case v1 = "v1"
    case v2 = "v2"  // 将来の拡張用

    var pathPrefix: String {
        return "/api/\(self.rawValue)"
    }
}

/**
 * Queue API Endpoints
 */
enum QueueEndpoint: APIEndpoint {
    case list
    case get(id: String)
    case create
    case delete(id: String)
    case addEntry(queueID: String, prNumber: Int)
    case removeEntry(queueID: String, entryID: String)

    var method: HTTPMethod {
        switch self {
        case .list, .get:
            return .GET
        case .create, .addEntry:
            return .POST
        case .delete, .removeEntry:
            return .DELETE
        }
    }

    var path: String {
        let basePath = "/queues"
        switch self {
        case .list:
            return basePath
        case .get(let id):
            return "\(basePath)/\(id)"
        case .create:
            return basePath
        case .delete(let id):
            return "\(basePath)/\(id)"
        case .addEntry(let queueID, _):
            return "\(basePath)/\(queueID)/entries"
        case .removeEntry(let queueID, let entryID):
            return "\(basePath)/\(queueID)/entries/\(entryID)"
        }
    }

    var version: APIVersion {
        return .v1
    }

    var fullPath: String {
        return "\(version.pathPrefix)\(path)"
    }
}

/**
 * Configuration API Endpoints
 */
enum ConfigurationEndpoint: APIEndpoint {
    case get
    case update
    case reset

    var method: HTTPMethod {
        switch self {
        case .get:
            return .GET
        case .update:
            return .PUT
        case .reset:
            return .POST
        }
    }

    var path: String {
        let basePath = "/config"
        switch self {
        case .get, .update:
            return basePath
        case .reset:
            return "\(basePath)/reset"
        }
    }

    var version: APIVersion {
        return .v1
    }

    var fullPath: String {
        return "\(version.pathPrefix)\(path)"
    }
}

/**
 * Stats API Endpoints
 */
enum StatsEndpoint: APIEndpoint {
    case overview
    case queueStats(queueID: String)
    case checkStats

    var method: HTTPMethod {
        return .GET
    }

    var path: String {
        let basePath = "/stats"
        switch self {
        case .overview:
            return basePath
        case .queueStats(let queueID):
            return "\(basePath)/queues/\(queueID)"
        case .checkStats:
            return "\(basePath)/checks"
        }
    }

    var version: APIVersion {
        return .v1
    }

    var fullPath: String {
        return "\(version.pathPrefix)\(path)"
    }
}
```

#### Vapor Routes実装

```swift
// /imq-core/Sources/IMQServer/routes.swift

import Vapor

func routes(_ app: Application) throws {
    // Health check
    app.get("health") { req in
        return ["status": "ok"]
    }

    // API versioning support
    let v1 = app.grouped("api", "v1")

    // Queue routes
    try registerQueueRoutes(v1)

    // Configuration routes
    try registerConfigurationRoutes(v1)

    // Stats routes
    try registerStatsRoutes(v1)

    // WebSocket
    app.webSocket("ws", "events", onUpgrade: WebSocketController.handleConnection)
}

private func registerQueueRoutes(_ router: RoutesBuilder) throws {
    let controller = QueueController()

    // GET /api/v1/queues
    router.get(
        QueueEndpoint.list.path,
        use: controller.list
    )

    // GET /api/v1/queues/:id
    router.get(
        QueueEndpoint.get(id: ":id").path,
        use: controller.get
    )

    // POST /api/v1/queues
    router.post(
        QueueEndpoint.create.path,
        use: controller.create
    )

    // DELETE /api/v1/queues/:id
    router.delete(
        QueueEndpoint.delete(id: ":id").path,
        use: controller.delete
    )

    // POST /api/v1/queues/:queueID/entries
    router.post(
        "queues", ":queueID", "entries",
        use: controller.addEntry
    )

    // DELETE /api/v1/queues/:queueID/entries/:entryID
    router.delete(
        "queues", ":queueID", "entries", ":entryID",
        use: controller.removeEntry
    )
}
```

#### JavaScript側: API Routes定義

```javascript
// /Resources/Public/js/api/routes.js

/**
 * API Routes Definition
 * エンドポイントの中央管理
 */
export const APIVersion = {
    V1: 'v1',
    V2: 'v2'  // 将来の拡張用
};

/**
 * API Routes Builder
 */
class APIRoutesBuilder {
    constructor(version) {
        this.version = version;
        this.basePrefix = `/api/${version}`;
    }

    /**
     * Queue routes
     */
    get queues() {
        const base = `${this.basePrefix}/queues`;
        return {
            list: () => base,
            get: (id) => `${base}/${id}`,
            create: () => base,
            delete: (id) => `${base}/${id}`,
            entries: {
                add: (queueID) => `${base}/${queueID}/entries`,
                remove: (queueID, entryID) => `${base}/${queueID}/entries/${entryID}`
            }
        };
    }

    /**
     * Configuration routes
     */
    get config() {
        const base = `${this.basePrefix}/config`;
        return {
            get: () => base,
            update: () => base,
            reset: () => `${base}/reset`
        };
    }

    /**
     * Stats routes
     */
    get stats() {
        const base = `${this.basePrefix}/stats`;
        return {
            overview: () => base,
            queueStats: (queueID) => `${base}/queues/${queueID}`,
            checkStats: () => `${base}/checks`
        };
    }
}

// Export versioned routes
export const APIRoutes = {
    v1: new APIRoutesBuilder(APIVersion.V1),
    v2: new APIRoutesBuilder(APIVersion.V2)
};

// Default to v1
export const defaultRoutes = APIRoutes.v1;
```

#### API Client の改善版

```javascript
// /Resources/Public/js/clients/APIClient.js
import { defaultRoutes, APIRoutes } from '../api/routes.js';

/**
 * REST API Client (改善版)
 */
class APIClient {
    constructor(baseURL, options = {}) {
        this.baseURL = baseURL;
        this.routes = options.routes || defaultRoutes;
        this.timeout = options.timeout || 30000;
    }

    /**
     * Generic request method
     */
    async request(method, path, options = {}) {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), this.timeout);

        try {
            const response = await fetch(`${this.baseURL}${path}`, {
                method,
                headers: {
                    'Content-Type': 'application/json',
                    ...options.headers
                },
                body: options.body ? JSON.stringify(options.body) : undefined,
                signal: controller.signal
            });

            clearTimeout(timeoutId);

            if (!response.ok) {
                throw new APIError(
                    `HTTP ${response.status}: ${response.statusText}`,
                    response.status,
                    await response.json().catch(() => null)
                );
            }

            return await response.json();
        } catch (error) {
            clearTimeout(timeoutId);
            if (error.name === 'AbortError') {
                throw new APIError('Request timeout', 408);
            }
            throw error;
        }
    }

    /**
     * Queues API
     */
    async getQueues() {
        return this.request('GET', this.routes.queues.list());
    }

    async getQueue(id) {
        return this.request('GET', this.routes.queues.get(id));
    }

    async createQueue(data) {
        return this.request('POST', this.routes.queues.create(), { body: data });
    }

    async deleteQueue(id) {
        return this.request('DELETE', this.routes.queues.delete(id));
    }

    /**
     * Configuration API
     */
    async getConfiguration() {
        return this.request('GET', this.routes.config.get());
    }

    async updateConfiguration(config) {
        return this.request('PUT', this.routes.config.update(), { body: config });
    }

    /**
     * Stats API
     */
    async getStats() {
        return this.request('GET', this.routes.stats.overview());
    }

    async getQueueStats(queueID) {
        return this.request('GET', this.routes.stats.queueStats(queueID));
    }

    /**
     * Version migration helper
     */
    migrateToV2() {
        this.routes = APIRoutes.v2;
    }
}

class APIError extends Error {
    constructor(message, statusCode, details = null) {
        super(message);
        this.name = 'APIError';
        this.statusCode = statusCode;
        this.details = details;
    }
}

export { APIClient, APIError };
```

### 2. GitHub API Client設計（バージョニングと変更への耐性）

#### GitHub API Endpoint Definition

```swift
// /imq-core/Sources/IMQCore/Data/Gateways/GitHub/GitHubAPIEndpoint.swift

/**
 * GitHub API Endpoint Definition
 * GitHub APIのバージョンと仕様変更に対応
 */
struct GitHubAPIEndpoint {
    let path: String
    let method: HTTPMethod
    let apiVersion: String
    let acceptHeader: String

    /**
     * GitHub API Version
     * https://docs.github.com/en/rest/overview/api-versions
     */
    static let currentVersion = "2022-11-28"

    /**
     * Pull Request Endpoints
     */
    static func pullRequest(owner: String, repo: String, number: Int) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/pulls/\(number)",
            method: .GET,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    static func pullRequestList(owner: String, repo: String, state: PullRequestState = .open) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/pulls?state=\(state.rawValue)",
            method: .GET,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    static func updatePullRequestBranch(owner: String, repo: String, number: Int) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/pulls/\(number)/update-branch",
            method: .PUT,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    static func mergePullRequest(owner: String, repo: String, number: Int) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/pulls/\(number)/merge",
            method: .PUT,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    /**
     * Branch Protection Endpoints
     */
    static func branchProtection(owner: String, repo: String, branch: String) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/branches/\(branch)/protection",
            method: .GET,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    static func requiredStatusChecks(owner: String, repo: String, branch: String) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/branches/\(branch)/protection/required_status_checks",
            method: .GET,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    /**
     * Actions Endpoints
     */
    static func triggerWorkflow(owner: String, repo: String, workflowID: String) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/actions/workflows/\(workflowID)/dispatches",
            method: .POST,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    static func workflowRun(owner: String, repo: String, runID: Int) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/actions/runs/\(runID)",
            method: .GET,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    static func cancelWorkflowRun(owner: String, repo: String, runID: Int) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/actions/runs/\(runID)/cancel",
            method: .POST,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    /**
     * Comment Endpoints
     */
    static func createComment(owner: String, repo: String, issueNumber: Int) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/issues/\(issueNumber)/comments",
            method: .POST,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    /**
     * Label Endpoints
     */
    static func addLabels(owner: String, repo: String, issueNumber: Int) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/issues/\(issueNumber)/labels",
            method: .POST,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    static func removeLabel(owner: String, repo: String, issueNumber: Int, label: String) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/issues/\(issueNumber)/labels/\(label)",
            method: .DELETE,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    /**
     * Events Endpoints (for Polling)
     */
    static func repositoryEvents(owner: String, repo: String) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/events",
            method: .GET,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }

    /**
     * Compare Endpoints
     */
    static func compareBranches(owner: String, repo: String, base: String, head: String) -> GitHubAPIEndpoint {
        return GitHubAPIEndpoint(
            path: "/repos/\(owner)/\(repo)/compare/\(base)...\(head)",
            method: .GET,
            apiVersion: currentVersion,
            acceptHeader: "application/vnd.github+json"
        )
    }
}

enum PullRequestState: String {
    case open = "open"
    case closed = "closed"
    case all = "all"
}
```

#### GitHub API Client Implementation

```swift
// /imq-core/Sources/IMQCore/Data/Gateways/GitHub/GitHubAPIClient.swift

import Foundation
import AsyncHTTPClient

/**
 * GitHub API Client
 * バージョニングとレート制限を考慮した実装
 */
protocol GitHubAPIClient {
    func request<T: Decodable>(
        _ endpoint: GitHubAPIEndpoint,
        body: Data?
    ) async throws -> T
}

final class GitHubAPIClientImpl: GitHubAPIClient {
    private let httpClient: HTTPClient
    private let token: String
    private let baseURL = "https://api.github.com"

    // Rate limiting
    private var rateLimitRemaining: Int?
    private var rateLimitReset: Date?

    init(token: String, httpClient: HTTPClient) {
        self.token = token
        self.httpClient = httpClient
    }

    func request<T: Decodable>(
        _ endpoint: GitHubAPIEndpoint,
        body: Data? = nil
    ) async throws -> T {
        // レート制限チェック
        try await checkRateLimit()

        // リクエスト構築
        var request = HTTPClientRequest(url: "\(baseURL)\(endpoint.path)")
        request.method = mapHTTPMethod(endpoint.method)

        // ヘッダー設定
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "Accept", value: endpoint.acceptHeader)
        request.headers.add(name: "X-GitHub-Api-Version", value: endpoint.apiVersion)
        request.headers.add(name: "User-Agent", value: "IMQ/1.0")

        if let body = body {
            request.body = .bytes(ByteBuffer(data: body))
            request.headers.add(name: "Content-Type", value: "application/json")
        }

        // リクエスト実行
        let response = try await httpClient.execute(request, timeout: .seconds(30))

        // レート制限情報の更新
        updateRateLimitInfo(from: response.headers)

        // ステータスコードチェック
        guard (200...299).contains(response.status.code) else {
            throw GitHubAPIError.httpError(
                statusCode: Int(response.status.code),
                message: try await parseErrorMessage(from: response)
            )
        }

        // レスポンスのデコード
        let body = try await response.body.collect(upTo: 1024 * 1024 * 10) // 10MB limit
        let data = Data(buffer: body)

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubAPIError.decodingError(error)
        }
    }

    /**
     * レート制限チェック
     */
    private func checkRateLimit() async throws {
        guard let remaining = rateLimitRemaining,
              let reset = rateLimitReset else {
            return
        }

        if remaining == 0 && Date() < reset {
            let waitTime = reset.timeIntervalSinceNow
            throw GitHubAPIError.rateLimitExceeded(resetAt: reset, waitTime: waitTime)
        }
    }

    /**
     * レート制限情報の更新
     */
    private func updateRateLimitInfo(from headers: HTTPHeaders) {
        if let remaining = headers.first(name: "x-ratelimit-remaining"),
           let remainingInt = Int(remaining) {
            self.rateLimitRemaining = remainingInt
        }

        if let reset = headers.first(name: "x-ratelimit-reset"),
           let resetTimestamp = Double(reset) {
            self.rateLimitReset = Date(timeIntervalSince1970: resetTimestamp)
        }
    }

    private func mapHTTPMethod(_ method: HTTPMethod) -> HTTPClient.Method {
        switch method {
        case .GET: return .GET
        case .POST: return .POST
        case .PUT: return .PUT
        case .PATCH: return .PATCH
        case .DELETE: return .DELETE
        }
    }

    private func parseErrorMessage(from response: HTTPClientResponse) async throws -> String {
        let body = try await response.body.collect(upTo: 1024 * 100) // 100KB
        let data = Data(buffer: body)

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }

        return "Unknown error"
    }
}

enum GitHubAPIError: Error {
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case rateLimitExceeded(resetAt: Date, waitTime: TimeInterval)
    case invalidResponse
}
```

### 3. Database Client設計（型安全なクエリビルダー）

#### Query Builder Pattern

```swift
// /imq-core/Sources/IMQCore/Data/Database/QueryBuilder.swift

/**
 * Type-safe Query Builder
 */
struct Query<T: TableRepresentable> {
    private var tableName: String
    private var conditions: [Condition] = []
    private var orderBy: [OrderBy] = []
    private var limitValue: Int?
    private var offsetValue: Int?

    init(table: T.Type) {
        self.tableName = T.tableName
    }

    /**
     * WHERE clause
     */
    func `where`<V>(_ keyPath: KeyPath<T, V>, _ op: ComparisonOperator, _ value: V) -> Query<T> {
        var query = self
        let columnName = T.columnName(for: keyPath)
        query.conditions.append(Condition(column: columnName, operator: op, value: value))
        return query
    }

    /**
     * AND clause
     */
    func and<V>(_ keyPath: KeyPath<T, V>, _ op: ComparisonOperator, _ value: V) -> Query<T> {
        return self.where(keyPath, op, value)
    }

    /**
     * ORDER BY clause
     */
    func orderBy<V>(_ keyPath: KeyPath<T, V>, _ direction: OrderDirection = .ascending) -> Query<T> {
        var query = self
        let columnName = T.columnName(for: keyPath)
        query.orderBy.append(OrderBy(column: columnName, direction: direction))
        return query
    }

    /**
     * LIMIT clause
     */
    func limit(_ value: Int) -> Query<T> {
        var query = self
        query.limitValue = value
        return query
    }

    /**
     * OFFSET clause
     */
    func offset(_ value: Int) -> Query<T> {
        var query = self
        query.offsetValue = value
        return query
    }

    /**
     * Build SQL string
     */
    func buildSQL() -> (sql: String, bindings: [Any]) {
        var sql = "SELECT * FROM \(tableName)"
        var bindings: [Any] = []

        if !conditions.isEmpty {
            let conditionStrings = conditions.map { "\($0.column) \($0.operator.symbol) ?" }
            sql += " WHERE " + conditionStrings.joined(separator: " AND ")
            bindings.append(contentsOf: conditions.map { $0.value })
        }

        if !orderBy.isEmpty {
            let orderStrings = orderBy.map { "\($0.column) \($0.direction.rawValue)" }
            sql += " ORDER BY " + orderStrings.joined(separator: ", ")
        }

        if let limit = limitValue {
            sql += " LIMIT \(limit)"
        }

        if let offset = offsetValue {
            sql += " OFFSET \(offset)"
        }

        return (sql, bindings)
    }
}

/**
 * Table representable protocol
 */
protocol TableRepresentable {
    static var tableName: String { get }
    static func columnName<V>(for keyPath: KeyPath<Self, V>) -> String
}

enum ComparisonOperator {
    case equals
    case notEquals
    case greaterThan
    case lessThan
    case greaterThanOrEquals
    case lessThanOrEquals
    case like
    case `in`

    var symbol: String {
        switch self {
        case .equals: return "="
        case .notEquals: return "!="
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .greaterThanOrEquals: return ">="
        case .lessThanOrEquals: return "<="
        case .like: return "LIKE"
        case .in: return "IN"
        }
    }
}

enum OrderDirection: String {
    case ascending = "ASC"
    case descending = "DESC"
}

struct Condition {
    let column: String
    let `operator`: ComparisonOperator
    let value: Any
}

struct OrderBy {
    let column: String
    let direction: OrderDirection
}
```

#### Table Definitions

```swift
// /imq-core/Sources/IMQCore/Data/Database/Tables.swift

/**
 * Queue Table
 */
struct QueueTable: TableRepresentable {
    let id: String
    let repositoryID: String
    let baseBranch: String
    let createdAt: Double

    static var tableName: String { "queues" }

    static func columnName<V>(for keyPath: KeyPath<QueueTable, V>) -> String {
        switch keyPath {
        case \QueueTable.id: return "id"
        case \QueueTable.repositoryID: return "repository_id"
        case \QueueTable.baseBranch: return "base_branch"
        case \QueueTable.createdAt: return "created_at"
        default: fatalError("Unknown key path")
        }
    }
}

/**
 * Usage example
 */
extension SQLiteQueueRepository {
    func find(baseBranch: String, repositoryID: String) async throws -> Queue? {
        // Type-safe query
        let query = Query(table: QueueTable.self)
            .where(\.baseBranch, .equals, baseBranch)
            .and(\.repositoryID, .equals, repositoryID)
            .limit(1)

        let (sql, bindings) = query.buildSQL()

        // Execute query
        guard let row = try await database.queryOne(sql, bindings) else {
            return nil
        }

        return try mapToQueue(row)
    }
}
```

## まとめ

### 改善された設計の利点

1. **型安全性**
   - エンドポイントがenumで定義され、コンパイル時にチェック可能
   - 文字列の typo が発生しない

2. **変更への耐性**
   - APIバージョンが中央管理され、アップグレードが容易
   - GitHubの仕様変更に対応しやすい

3. **保守性**
   - エンドポイントの追加・変更が1箇所で完結
   - ドキュメントとしても機能

4. **テスタビリティ**
   - モックの作成が容易
   - エンドポイント定義を使ったテストケースの生成が可能

5. **拡張性**
   - 新しいAPIバージョンの追加が容易
   - レート制限などの横断的関心事の実装が一元化

## 次の実装ドキュメント

この設計をベースに、各機能の実装ドキュメント（imps/）を作成します。
