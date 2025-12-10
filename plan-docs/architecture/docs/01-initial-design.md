# アーキテクチャ設計 - 第1回検討

## 検討日
2025-12-10

## 目的
IMQシステム全体のアーキテクチャを検討し、モジュール分割、依存関係、責務の配置を決定する。

## 前提条件
- 全てSwiftで実装
- imq-coreとimq-guiの2つのSwift Packageに分離
- クリーンアーキテクチャを採用
- SQLiteを共有データストアとして使用

## 初期設計案

### 1. プロジェクト構成

```
imq/
├── imq-core/           # ビジネスロジック + API Server
└── imq-gui/            # Web UI
```

#### imq-core の責務
- **ビジネスロジック**: キューイング、チェック実行、マージ処理
- **データ永続化**: SQLiteへの読み書き
- **GitHub連携**: API呼び出し、Webhook/Polling
- **REST API提供**: imq-gui用のAPI
- **CLI提供**: コマンドラインツール

#### imq-gui の責務
- **Web UI提供**: Leaf templatesでHTMLレンダリング
- **API Client**: imq-coreのREST APIを呼び出し
- **WebSocket**: リアルタイム更新の受信と表示

### 2. imq-core のレイヤー構成

クリーンアーキテクチャに従い、以下の4層に分割：

```
┌─────────────────────────────────────────┐
│      Presentation Layer (CLI/API)      │  外部とのインターフェース
├─────────────────────────────────────────┤
│      Application Layer (Services)      │  アプリケーション固有の処理
├─────────────────────────────────────────┤
│         Domain Layer (Core)            │  ビジネスロジック（純粋）
├─────────────────────────────────────────┤
│    Data Layer (Infrastructure)         │  外部依存の実装
└─────────────────────────────────────────┘
```

#### Domain Layer（ドメイン層）
**責務**: ビジネスルールの定義と実装

**含むもの**:
- Entities（エンティティ）
  - `PullRequest`: PRの状態と振る舞い
  - `Queue`: キューの管理
  - `QueueEntry`: キュー内のPR
  - `Check`: チェックの定義
  - `Repository`: リポジトリ情報
  - `Configuration`: システム設定

- Use Cases（ユースケース）
  - `QueueingUseCase`: PRをキューに追加
  - `QueueProcessingUseCase`: キューの処理
  - `CheckExecutionUseCase`: チェックの実行
  - `ConflictDetectionUseCase`: コンフリクト検出
  - `PRUpdateUseCase`: PRの更新
  - `MergeUseCase`: PRのマージ

- Repository Interfaces（リポジトリインターフェース）
  - `QueueRepository`
  - `PullRequestRepository`
  - `CheckRepository`
  - `ConfigurationRepository`

- Gateway Interfaces（外部サービスインターフェース）
  - `GitHubGateway`: GitHub API
  - `NotificationGateway`: 通知
  - `CheckExecutor`: チェック実行

**依存**: なし（完全に独立）

#### Data Layer（データ層）
**責務**: 外部依存の実装

**含むもの**:
- Repository Implementations
  - `SQLiteQueueRepository`
  - `SQLitePullRequestRepository`
  - など

- Gateway Implementations
  - `GitHubGatewayImpl`: GitHub REST API呼び出し
  - `NotificationServiceImpl`: GitHub Comment投稿

- Event Sources
  - `GitHubPollingEventSource`: Polling実装
  - `GitHubWebhookEventSource`: Webhook実装

- Check Executors
  - `GitHubActionsCheckExecutor`: GitHub Actions起動
  - `LocalScriptCheckExecutor`: ローカルスクリプト実行

**依存**: Domain Layer（インターフェースのみ）

#### Application Layer（アプリケーション層）
**責務**: アプリケーション固有のサービスとDI

**含むもの**:
- Services
  - `IMQDaemon`: メインデーモンプロセス
  - `QueueProcessor`: キュー処理ループ
  - `EventBus`: イベント配信
  - `GitHubIntegrationService`: GitHub連携の管理

- DI Container
  - `DependencyContainer`: 依存性注入コンテナ
  - `ServiceFactory`: サービスのファクトリ

**依存**: Domain Layer, Data Layer

#### Presentation Layer（プレゼンテーション層）
**責務**: 外部とのインターフェース

**含むもの**:
- CLI
  - `IMQCommand`: コマンドルート
  - `StartCommand`, `StopCommand`, など

- REST API
  - `QueueController`
  - `ConfigurationController`
  - `WebSocketController`

**依存**: Application Layer, Domain Layer

### 3. imq-gui の構成

```
IMQGUILib/
├── Models/          # DTOs（imq-coreから受け取るデータ）
├── Services/        # API Client, WebSocket Client
└── Routes/          # Vapor routes（Controller）
```

**依存**: imq-coreのREST APIのみ（直接的なコード依存なし）

### 4. データフロー

```
┌────────────┐
│  imq-gui   │
│  (Web UI)  │
└─────┬──────┘
      │ HTTP/WebSocket
      ↓
┌────────────────────────────────────┐
│           imq-core                 │
│  ┌──────────────────────────────┐  │
│  │    Presentation Layer        │  │
│  │  (REST API / CLI / WS)       │  │
│  └──────────┬───────────────────┘  │
│             ↓                      │
│  ┌──────────────────────────────┐  │
│  │    Application Layer         │  │
│  │  (Services / DI)             │  │
│  └──────────┬───────────────────┘  │
│             ↓                      │
│  ┌──────────────────────────────┐  │
│  │      Domain Layer            │  │
│  │  (Entities / Use Cases)      │  │
│  └──────────┬───────────────────┘  │
│             ↓                      │
│  ┌──────────────────────────────┐  │
│  │       Data Layer             │  │
│  │  (Repositories / Gateways)   │  │
│  └──────────┬───────────────────┘  │
│             ↓                      │
└─────────────┼──────────────────────┘
              ↓
     ┌────────┴────────┐
     │                 │
┌────┴─────┐    ┌──────┴──────┐
│  SQLite  │    │   GitHub    │
└──────────┘    │     API     │
                └─────────────┘
```

## 検討事項と課題

### ✅ 良い点
1. **関心の分離**: 各層の責務が明確
2. **テスタビリティ**: Domain層は外部依存がないためテストが容易
3. **拡張性**: 新しいCheck実行方法やGitHub連携方法を追加しやすい
4. **依存性逆転**: Data層がDomain層に依存（逆ではない）

### ⚠️ 潜在的な問題点
1. **SQLiteの共有**: imq-coreとimq-guiが同じDBにアクセスする場合、同時書き込みの問題
   - → imq-guiは読み取り専用にすべきか？
   - → それともimq-guiはAPIを通じてのみアクセスすべきか？

2. **ユースケースの粒度**: ユースケースが多すぎる可能性
   - 7つのユースケースは適切か？
   - 統合できるものはないか？

3. **イベント駆動の設計**: EventBusの役割が不明確
   - どのようなイベントを配信するのか？
   - Pub/Subパターンは必要か？

4. **WebSocketの配信内容**: どのような粒度でイベントを配信するか？
   - キュー全体の更新？
   - 個別のPRステータス更新？

## 次回検討事項
1. SQLiteアクセスパターンの詳細化（同時実行制御）
2. ユースケースの統合・分割の再検討
3. イベント駆動アーキテクチャの詳細設計
4. エラーハンドリング戦略
5. 非同期処理（Swift Concurrency）の設計方針
