# アーキテクチャ設計 - 第2回検討（改善）

## 検討日
2025-12-10

## 前回の課題への対応

### 課題1: SQLiteの共有とアクセスパターン

**問題**: imq-coreとimq-guiが同じSQLiteにアクセスすると同時書き込みの競合が発生する可能性

**解決策**: **API経由のみのアクセスに統一**

```
imq-gui → REST API → imq-core → SQLite
        (読み取り)              (読み書き)
```

**決定事項**:
- imq-guiはSQLiteに直接アクセスしない
- 全てのデータアクセスはimq-coreのREST APIを経由
- imq-guiはステートレス（セッション情報もimq-coreが管理）

**メリット**:
- 同時書き込み競合の完全回避
- imq-guiの実装がシンプル（API Clientのみ）
- 将来的なスケールアウトが容易（imq-guiは複数起動可能）

**デメリット**:
- REST APIのオーバーヘッド（ただしLAN内なので許容範囲）
- imq-coreが停止するとimq-guiも使用不可（これは設計上当然）

### 課題2: ユースケースの粒度再検討

**第1回のユースケース**:
1. QueueingUseCase
2. QueueProcessingUseCase
3. CheckExecutionUseCase
4. ConflictDetectionUseCase
5. PRUpdateUseCase
6. MergeUseCase
7. LabelEventHandlingUseCase

**分析**:
- `QueueProcessingUseCase`が内部で3, 4, 5, 6を呼び出す
- 個別のユースケースとして公開する必要があるか？

**改善案**: **ユースケースを2種類に分類**

#### A. トップレベルユースケース（外部から呼ばれる）
1. **LabelEventHandlingUseCase**: ラベル追加/削除のハンドリング
   - ラベル追加 → QueueingUseCaseを呼ぶ
   - ラベル削除 → キューから削除

2. **QueueProcessingUseCase**: キュー処理のメインループ
   - コンフリクト検出
   - PR更新
   - チェック実行
   - マージ

#### B. 内部ユースケース（他のユースケースから呼ばれる）
3. **QueueingUseCase**: PRをキューに追加
4. **CheckExecutionUseCase**: チェックの実行
5. **ConflictDetectionUseCase**: コンフリクト検出
6. **PRUpdateUseCase**: PRの更新
7. **MergeUseCase**: PRのマージ

**結論**: 7つのユースケースは適切。ただし、呼び出し階層を明確化する。

```
[External Triggers]
    ↓
LabelEventHandlingUseCase ──→ QueueingUseCase
    ↓
QueueProcessingUseCase
    ├──→ ConflictDetectionUseCase
    ├──→ PRUpdateUseCase
    ├──→ CheckExecutionUseCase
    └──→ MergeUseCase
```

### 課題3: イベント駆動アーキテクチャの詳細設計

**EventBusの役割を明確化**:

```swift
// イベントの種類
enum IMQEvent {
    // キュー関連
    case queueEntryAdded(QueueEntry)
    case queueEntryRemoved(QueueEntry)
    case queueEntryStatusChanged(QueueEntry, oldStatus: QueueEntryStatus)

    // チェック関連
    case checkStarted(Check)
    case checkCompleted(Check, result: CheckResult)
    case checkFailed(Check, error: Error)

    // PR関連
    case pullRequestUpdated(PullRequest)
    case pullRequestMerged(PullRequest)

    // GitHub関連
    case githubEventReceived(GitHubEvent)
}
```

**EventBusの用途**:
1. **WebSocketへの配信**: imq-guiへのリアルタイム更新
2. **ロギング**: 全イベントをログに記録
3. **メトリクス収集**: 統計情報の更新
4. **拡張性**: 将来的に外部通知（Slack等）を追加可能

**実装方針**:
- `AsyncStream<IMQEvent>`を使用
- 複数のサブスクライバーをサポート
- バックプレッシャー対応（遅いサブスクライバーがシステムを遅延させない）

### 課題4: WebSocketの配信内容

**配信する情報**:
```typescript
// WebSocket message format
{
  "type": "queue.entry.status_changed",
  "timestamp": 1702800000,
  "data": {
    "queueId": "...",
    "entryId": "...",
    "oldStatus": "checking",
    "newStatus": "ready",
    "pullRequest": {
      "number": 123,
      "title": "...",
      ...
    }
  }
}
```

**配信戦略**:
- **Granular Updates**: 個別の変更を細かく配信
- **Full State**: 状態変更時にキュー全体を送信しない（効率的）
- **Optimistic Updates**: imq-gui側で楽観的更新を実装可能

## 改善された全体アーキテクチャ

### レイヤー間の依存関係（厳密化）

```
Presentation Layer
    ↓ depends on
Application Layer
    ↓ depends on
Domain Layer (interfaces only)
    ↑ implements
Data Layer
```

**依存性逆転の原則**:
- Data LayerはDomain Layerのインターフェースを実装
- Domain LayerはData Layerを知らない

### Swift Concurrencyの活用

**Actor Pattern**:
```swift
// キュー状態をActorで保護
actor QueueCoordinator {
    private var queues: [QueueID: Queue] = [:]

    func enqueue(_ entry: QueueEntry, to queueID: QueueID) async {
        // スレッドセーフな操作
    }

    func dequeue(from queueID: QueueID) async -> QueueEntry? {
        // スレッドセーフな操作
    }
}
```

**Task Groups**:
```swift
// 複数のキューを並行処理
await withTaskGroup(of: Void.self) { group in
    for queue in queues {
        group.addTask {
            await processQueue(queue)
        }
    }
}
```

### エラーハンドリング戦略

**エラーの分類**:
1. **Recoverable Errors**: リトライ可能（ネットワークエラー等）
2. **Business Logic Errors**: ビジネスルール違反（コンフリクト等）
3. **Fatal Errors**: 継続不可能（DB破損等）

**ハンドリング方針**:
```swift
// Custom Error Types
enum IMQError: Error {
    // Recoverable
    case networkError(underlyingError: Error, retryable: Bool)
    case githubAPIRateLimit(resetAt: Date)

    // Business Logic
    case conflictDetected(pullRequest: PullRequest)
    case checkFailed(check: Check, reason: String)

    // Fatal
    case databaseCorrupted
    case configurationInvalid(reason: String)
}
```

## 最終的なモジュール構成

### imq-core

```
IMQCore/
├── Domain/
│   ├── Entities/
│   │   ├── PullRequest.swift
│   │   ├── Queue.swift
│   │   ├── QueueEntry.swift
│   │   ├── Check.swift
│   │   ├── Repository.swift
│   │   ├── Configuration.swift
│   │   └── ValueObjects.swift
│   ├── UseCases/
│   │   ├── LabelEventHandlingUseCase.swift       # Top-level
│   │   ├── QueueProcessingUseCase.swift          # Top-level
│   │   ├── QueueingUseCase.swift                 # Internal
│   │   ├── CheckExecutionUseCase.swift           # Internal
│   │   ├── ConflictDetectionUseCase.swift        # Internal
│   │   ├── PRUpdateUseCase.swift                 # Internal
│   │   └── MergeUseCase.swift                    # Internal
│   ├── Repositories/
│   │   ├── QueueRepository.swift
│   │   ├── PullRequestRepository.swift
│   │   ├── CheckRepository.swift
│   │   └── ConfigurationRepository.swift
│   └── Gateways/
│       ├── GitHubGateway.swift
│       ├── NotificationGateway.swift
│       └── CheckExecutor.swift
│
├── Data/
│   ├── Database/
│   │   ├── SQLiteDatabase.swift
│   │   ├── Schema.swift
│   │   └── Migrations.swift
│   ├── Repositories/
│   │   └── (implements Domain/Repositories)
│   ├── Gateways/
│   │   ├── GitHub/
│   │   │   ├── GitHubGatewayImpl.swift
│   │   │   ├── GitHubAPIClient.swift
│   │   │   └── Models/
│   │   └── Notification/
│   │       └── NotificationServiceImpl.swift
│   ├── EventSources/
│   │   ├── GitHubEventSource.swift              # Protocol
│   │   ├── GitHubPollingEventSource.swift
│   │   ├── GitHubWebhookEventSource.swift
│   │   └── GitHubEventSourceFactory.swift
│   └── CheckExecution/
│       ├── CheckExecutorFactory.swift
│       ├── GitHubActionsCheckExecutor.swift
│       └── LocalScriptCheckExecutor.swift
│
├── Application/
│   ├── DI/
│   │   ├── DependencyContainer.swift
│   │   └── ServiceFactory.swift
│   └── Services/
│       ├── IMQDaemon.swift
│       ├── QueueProcessor.swift
│       ├── EventBus.swift                        # NEW
│       └── GitHubIntegrationService.swift
│
└── Presentation/
    ├── (будет определен в следующей итерации)
```

### imq-gui

```
IMQGUILib/
├── Models/
│   ├── QueueDTO.swift
│   ├── ConfigurationDTO.swift
│   └── EventDTO.swift                            # NEW
├── Services/
│   ├── IMQAPIClient.swift
│   └── WebSocketClient.swift
└── Routes/
    ├── routes.swift
    ├── DashboardController.swift
    ├── QueuesController.swift
    └── ConfigController.swift
```

## 改善された点のまとめ

1. ✅ **SQLiteアクセス**: API経由に統一、競合回避
2. ✅ **ユースケース階層**: Top-levelとInternalの区別を明確化
3. ✅ **EventBus**: 役割と実装方針を明確化
4. ✅ **WebSocket**: 配信内容と戦略を定義
5. ✅ **Swift Concurrency**: Actor patternとTask groupsの活用
6. ✅ **エラーハンドリング**: エラー分類と戦略を定義

## 次回検討事項
1. Presentation Layer（CLI/API）の詳細設計
2. 設定ファイルの構造と読み込み方法
3. テスト戦略の詳細化
4. パフォーマンス最適化の方針
5. セキュリティ考慮事項（GitHub Token管理等）
