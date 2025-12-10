# IMQ (Immediate Merge Queue) 設計サマリー

## 📋 ドキュメント概要

このドキュメントは、IMQプロジェクトの全設計ドキュメントの要約です。

## 🎯 プロジェクト目標

**ローカルLAN環境で動作するGitHub Merge Queueシステムを完全にSwiftで実装する**

- 外部公開サーバ不要
- クリーンアーキテクチャ採用
- Web GUI完備
- 高い拡張性とテスタビリティ

## 🏗️ アーキテクチャ設計

### システム構成

```
imq-core (Swift)          imq-gui (Swift)
    ↓                         ↓
[REST API Server]    →    [Vapor Web Server]
    ↓                         ↓
[SQLite Database]    ←    [Leaf Templates + Alpine.js]
    ↓
[GitHub API]
```

### レイヤー構成（imq-core）

1. **Domain Layer** - ビジネスロジック（純粋、外部依存なし）
   - Entities: PullRequest, Queue, Check, Repository
   - Use Cases: Queueing, Processing, Check Execution, Merging
   - Interfaces: Repository, Gateway

2. **Data Layer** - インフラストラクチャ
   - Repository implementations (SQLite)
   - GitHub Gateway implementation
   - Event Sources (Polling/Webhook)
   - Check Executors

3. **Application Layer** - アプリケーションサービス
   - DI Container
   - IMQ Daemon
   - Queue Processor
   - Event Bus

4. **Presentation Layer** - 外部インターフェース
   - CLI Commands
   - REST API
   - WebSocket

### フロントエンド構成（imq-gui）

```
Components (Alpine.js)    - View層
    ↓
Stores (State)            - 状態管理
    ↓
Services (Logic)          - ビジネスロジック
    ↓
Clients (API/WS)          - 通信層
```

**設計原則**:
- 責務の完全な分離
- 文字列のハードコーディング禁止（エンドポイント、API routes）
- 型安全なAPI定義（enum based）
- テスタビリティ最優先

## 🔐 設定管理とセキュリティ

### 環境変数管理

```bash
# .env による設定管理
IMQ_GITHUB_TOKEN=ghp_xxx          # シークレット
IMQ_DATABASE_PATH=/path/to/db     # 環境依存
IMQ_API_HOST=0.0.0.0              # 設定
IMQ_POLLING_INTERVAL=60           # パラメータ
```

### セキュリティ対策

- ✅ Secretsは環境変数で管理（.envファイル）
- ✅ GitHub Apps認証推奨（Personal Access Tokenより安全）
- ✅ Webhook署名検証（HMAC-SHA256）
- ✅ ログへのシークレットマスキング
- ✅ 最小権限の原則

## 🔗 GitHub連携設計

### ハイブリッドモード

**Polling Mode**:
- 定期的にGitHub Events APIをポーリング
- 外部アクセス不要（ファイアウォール内で動作）
- Adaptive Polling（アクティビティに応じて頻度調整）

**Webhook Mode**:
- GitHub からのWebhook POST受信
- リアルタイム性が高い
- 署名検証必須

### 主要機能

1. **Adaptive Polling** - 10秒〜5分の間で動的調整
2. **Rate Limit管理** - ETag、Conditional Requests活用
3. **Circuit Breaker** - 障害の伝播防止
4. **Event Sequencing** - 順序保証
5. **Priority Queue** - 重要なイベント優先処理
6. **State Reconciliation** - 定期的な整合性チェック

### GitHub APIエンドポイント定義

```swift
// ❌ NG: 文字列直書き
let url = "/repos/\(owner)/\(repo)/pulls/\(number)"

// ✅ OK: 型安全な定義
let endpoint = GitHubAPIEndpoint.pullRequest(owner: owner, repo: repo, number: number)
let url = endpoint.path
```

## 📦 Queue Processing設計

### Queue データ構造

```swift
struct Queue {
    let id: QueueID
    let baseBranch: String
    private(set) var entries: [QueueEntry]  // 順序保証
}

struct QueueEntry {
    let pullRequest: PullRequest
    var status: QueueEntryStatus  // pending → updating → checking → ready
    var position: Int  // 連続した整数
}
```

### 処理フロー

```
Enqueue → Conflict Check → PR Update → Execute Checks → Merge
           ↓                  ↓             ↓             ↓
        Remove            Retry        Fail Fast     Success
```

### 主要機能

1. **Concurrent Processing** - Semaphoreで同時実行制限
2. **Priority Scheduling** - ブランチ優先度（hotfix > release > main > feature）
3. **Fair Queuing** - Weighted deficitによる公平性保証
4. **Graceful Shutdown** - 実行中のタスク完了を待機
5. **Retry Logic** - Exponential backoff
6. **Timeout** - 全操作にタイムアウト設定

## ✅ Check Execution設計

### Check Types

```swift
enum CheckType {
    case githubAction(workflowName: String, jobName: String?)
    case localScript(scriptPath: String)
    case custom(executorName: String, config: [String: Any])
}
```

### 実行戦略

1. **Parallel Execution** - 複数Checkを並行実行（最大5並列）
2. **Fail Fast** - 1つでも失敗したら即座に中断
3. **Dependency Resolution** - Check間の依存関係を解決
4. **Result Caching** - 同じSHAのCheck結果をキャッシュ
5. **Timeout** - Check毎にタイムアウト設定

### GitHub Actions統合

```swift
// Workflow起動
let run = try await githubGateway.triggerWorkflow(...)

// 完了まで Polling
while status != .completed {
    status = try await githubGateway.getWorkflowRunStatus(...)
    await Task.sleep(...)
}
```

## 📊 メトリクスとモニタリング

### 収集するメトリクス

- GitHub連携
  - eventsReceived, eventsProcessed
  - apiCallsTotal, apiCallsFailed
  - rateLimitRemaining

- Queue処理
  - queueSize, waitTime
  - processingDuration
  - successRate, failureRate

- Check実行
  - checkDuration
  - checkSuccessRate
  - cacheHitRate

### Health Check

```
GET /health/github
→ {
  "status": "healthy",
  "mode": "polling",
  "rateLimitRemaining": 4500,
  "eventsReceived": 123
}
```

## 🧪 テスト戦略

### Unit Tests
- Domain層のユースケースをモックでテスト
- 外部依存を完全に分離

### Integration Tests
- 実際のGitHub API呼び出し
- SQLite操作の検証

### E2E Tests
- 実際のPRでキューイング〜マージまで
- シナリオベースのテスト

## 🚀 技術スタック

### imq-core
- **Swift 5.9+**
- **Vapor 4** - REST API / WebSocket
- **SQLite.swift** - Database ORM
- **AsyncHTTPClient** - HTTP通信
- **ArgumentParser** - CLI

### imq-gui
- **Swift 5.9+**
- **Vapor 4** - Webサーバー
- **Leaf** - HTMLテンプレート
- **Alpine.js** - フロントエンド
- **Tailwind CSS** - スタイリング

## 📁 プロジェクト構造

```
imq/
├── imq-core/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── IMQCore/
│   │   │   ├── Domain/
│   │   │   ├── Data/
│   │   │   └── Application/
│   │   ├── IMQCLI/
│   │   └── IMQServer/
│   ├── Tests/
│   └── Resources/
│       └── schema.sql
│
├── imq-gui/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── IMQGUILib/
│   │   └── Run/
│   ├── Resources/
│   │   ├── Views/
│   │   └── Public/
│   └── Tests/
│
└── plan-docs/           # 本設計ドキュメント
    ├── architecture/
    ├── github-integration/
    ├── queue-processing/
    └── check-execution/
```

## 📝 設計ドキュメント一覧

### Architecture (5回の検討)
1. `architecture/docs/01-initial-design.md` - 初期設計
2. `architecture/docs/02-refinement.md` - 改善
3. `architecture/docs/03-final-design.md` - フロントエンド含む最終設計
4. `architecture/docs/04-api-versioning-design.md` - API設計
5. `architecture/docs/05-configuration-secrets-management.md` - 設定管理

### GitHub Integration (3回の検討)
1. `github-integration/docs/01-initial-design.md` - Polling/Webhook設計
2. `github-integration/docs/02-scaling-optimization.md` - スケーリング
3. `github-integration/docs/03-final-design.md` - GitHub Apps、メトリクス

### Queue Processing (3回の検討)
1. `queue-processing/docs/01-queue-design.md` - Queue構造、処理フロー
2. `queue-processing/docs/02-concurrency-optimization.md` - 並行処理
3. `queue-processing/docs/03-final-design.md` - 最終設計

### Check Execution (3回の検討)
1. `check-execution/docs/01-check-types.md` - Check種類、Executor
2. `check-execution/docs/02-parallel-execution.md` - 並行実行、依存関係
3. `check-execution/docs/03-final-design.md` - 最終設計

## ✨ 設計の特徴

### 1. 徹底した責務分離
- 各レイヤーの責務が明確
- 文字列ハードコーディング禁止
- 型安全なAPI定義

### 2. 外部依存への耐性
- API versioning戦略
- Circuit Breaker
- Retry logic
- Rate limit管理

### 3. 高い拡張性
- 新しいCheck typeの追加が容易
- 新しいGitHub連携モードの追加が容易
- プラグインシステムの基盤

### 4. 運用性
- メトリクス収集
- Health check
- Graceful shutdown
- 詳細なログ

### 5. セキュリティ
- Secretsの環境変数管理
- Webhook署名検証
- ログへのマスキング
- 最小権限

## 🎯 次のステップ

1. ✅ 設計ドキュメント完成
2. ⏭️ プロジェクト構造の作成（Package.swift）
3. ⏭️ Domain層の実装
4. ⏭️ Data層の実装
5. ⏭️ Presentation層の実装
6. ⏭️ GUI実装
7. ⏭️ テスト実装
8. ⏭️ ドキュメント整備

---

**設計完了日**: 2025-12-10

**設計検討回数**: 合計16回以上の詳細検討

**ドキュメント総数**: 15ファイル

**総設計時間**: 集中的な検討により完成
