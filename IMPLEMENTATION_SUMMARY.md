# IMQ Core - Implementation Summary

## 実装完了した機能

### 1. Queue Processing Service (キュー処理サービス)
**ファイル**: `Sources/IMQServer/Services/QueueProcessingService.swift`

**機能**:
- 10秒ごとに全てのアクティブキューを監視
- pending状態のPRを順番に処理
- チェック実行 → ブランチ更新 → マージの完全なワークフロー
- WebSocketでリアルタイム更新をブロードキャスト
- エラーハンドリングとPRへのコメント投稿

**動作フロー**:
1. キューから次のpending entryを取得
2. PRの詳細を取得
3. 設定されたチェックを実行
4. チェック合格 → PRブランチを更新
5. マージ実行（squash merge）
6. 成功/失敗のコメントをPRに投稿
7. WebSocketでGUIに通知

### 2. Check Execution Service (チェック実行サービス)
**ファイル**: `Sources/IMQServer/Services/CheckExecutionService.swift`

**サポートするチェックタイプ**:
- **`github_actions`**: GitHub Actionsワークフローを実行して結果を待機
- **`github_status`**: GitHubのステータスチェックを確認
- **`mergeable`**: PRがマージ可能かチェック

**設定例**:
```json
[
  {
    "name": "CI Tests",
    "type": "github_actions",
    "workflow_name": "ci.yml"
  },
  {
    "name": "Mergeable Check",
    "type": "mergeable"
  }
]
```

### 3. Queue Management (キュー管理)
**ファイル**: `Sources/IMQServer/Controllers/QueueController.swift`

**API エンドポイント**:
- `GET /api/v1/queues` - 全キュー一覧
- `GET /api/v1/queues/:id` - 特定キュー取得
- `POST /api/v1/queues` - キュー作成
- `DELETE /api/v1/queues/:id` - キュー削除
- `GET /api/v1/queues/:id/entries` - キューエントリ一覧
- `POST /api/v1/queues/:id/entries` - エントリ追加
- `DELETE /api/v1/queues/:id/entries/:entryID` - エントリ削除
- `PUT /api/v1/queues/:id/reorder` - エントリの並び替え

### 4. Webhook Processing (Webhook処理)
**ファイル**: `Sources/IMQServer/Controllers/WebhookController.swift`

**処理するイベント**:
- `pull_request.labeled` - トリガーラベルが付与されたらキューに追加
- `pull_request.unlabeled` - トリガーラベルが削除されたらキューから削除
- `pull_request.synchronize` - PR更新時に再キュー
- `pull_request.closed` - PR閉鎖時にキューから削除

**署名検証**: `IMQ_WEBHOOK_SECRET`環境変数で設定されたシークレットでHMAC-SHA256検証

### 5. Configuration Management (設定管理)
**ファイル**: `Sources/IMQServer/Controllers/ConfigurationController.swift`

**API エンドポイント**:
- `GET /api/v1/config` - 現在の設定取得
- `PUT /api/v1/config` - 設定更新
- `POST /api/v1/config/reset` - デフォルトにリセット

**設定項目**:
- `triggerLabel`: キューに追加するトリガーとなるラベル名（デフォルト: "A-merge"）
- `webhookSecret`: Webhook署名検証用シークレット（環境変数から読み取り専用）
- `webhookProxyUrl`: リバースプロキシURL（環境変数から読み取り専用）
- `checkConfigurations`: 実行するチェックのJSON配列
- `notificationTemplates`: 通知テンプレートのJSON配列

### 6. WebSocket Real-time Updates (WebSocket リアルタイム更新)
**ファイル**: `Sources/IMQServer/Controllers/WebSocketController.swift`

**エンドポイント**: `ws://localhost:8080/ws/events`

**イベントタイプ**:
- `queue_created` - キュー作成
- `queue_deleted` - キュー削除
- `entry_added` - エントリ追加
- `entry_removed` - エントリ削除
- `entry_processing` - エントリ処理中
- `entry_completed` - エントリ完了
- `entry_failed` - エントリ失敗
- `reordered` - エントリ並び替え

### 7. Database Schema (データベーススキーマ)
**場所**: `Sources/IMQServer/main.swift`

**テーブル**:
1. **configurations** - システム設定
   - `id`, `trigger_label`, `check_configurations`, `notification_templates`, `updated_at`

2. **queues** - マージキュー
   - `id`, `repository_id`, `status`, `created_at`, `updated_at`

3. **pull_requests** - PR情報
   - `id`, `repository_id`, `number`, `title`, `head_branch`, `base_branch`, `head_sha`, `status`, `created_at`, `updated_at`

4. **queue_entries** - キューエントリ
   - `id`, `queue_id`, `pull_request_id`, `position`, `status`, `added_at`

**インデックス**: パフォーマンス最適化のため、`queue_id`, `status`, `repository_id + number`にインデックスを作成

### 8. GitHub API Integration (GitHub API統合)
**ファイル**: `Sources/IMQCore/Data/Gateways/GitHubGatewayImpl.swift`

**実装済み機能**:
- `getPullRequest()` - PR詳細取得
- `updatePullRequestBranch()` - PRブランチ更新
- `mergePullRequest()` - PRマージ
- `postComment()` - コメント投稿
- `triggerWorkflow()` - Actionsワークフロー実行
- `getWorkflowRun()` - ワークフロー実行状態取得
- `compareCommits()` - コミット比較

## 環境変数

必須の環境変数:
```bash
# GitHub
IMQ_GITHUB_TOKEN=ghp_xxxxxxxxxxxxx
IMQ_GITHUB_REPO=owner/repo

# Server
IMQ_API_HOST=0.0.0.0
IMQ_API_PORT=8080

# Webhook
IMQ_WEBHOOK_SECRET=your-secret-here
IMQ_WEBHOOK_PROXY_URL=https://your-domain.com

# Database
IMQ_DATABASE_PATH=~/.imq/imq.db

# Configuration
IMQ_TRIGGER_LABEL=A-merge
```

## 起動方法

### 1. ビルド
```bash
swift build
```

### 2. 実行
```bash
.build/debug/imq-server
```

または環境変数を指定して:
```bash
IMQ_GITHUB_TOKEN=xxx IMQ_GITHUB_REPO=owner/repo .build/debug/imq-server
```

### 3. 確認
```bash
# ヘルスチェック
curl http://localhost:8080/health

# 設定取得
curl http://localhost:8080/api/v1/config

# キュー一覧
curl http://localhost:8080/api/v1/queues
```

## アーキテクチャ

```
┌─────────────────┐
│   GitHub        │
│   Webhook       │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│  IMQ Server (Vapor)                 │
│                                     │
│  ┌─────────────────────────────┐   │
│  │ WebhookController           │   │
│  │ - Signature verification    │   │
│  │ - Event processing          │   │
│  └──────────┬──────────────────┘   │
│             │                       │
│             ▼                       │
│  ┌─────────────────────────────┐   │
│  │ QueueRepository             │   │
│  │ - SQLite storage            │   │
│  └──────────┬──────────────────┘   │
│             │                       │
│             ▼                       │
│  ┌─────────────────────────────┐   │
│  │ QueueProcessingService      │   │
│  │ - Background loop (10s)     │   │
│  │ - Entry processing          │   │
│  └──────────┬──────────────────┘   │
│             │                       │
│             ▼                       │
│  ┌─────────────────────────────┐   │
│  │ CheckExecutionService       │   │
│  │ - GitHub Actions            │   │
│  │ - Status checks             │   │
│  └──────────┬──────────────────┘   │
│             │                       │
│             ▼                       │
│  ┌─────────────────────────────┐   │
│  │ GitHubGateway               │   │
│  │ - API calls                 │   │
│  │ - PR merge                  │   │
│  └──────────┬──────────────────┘   │
│             │                       │
└─────────────┼───────────────────────┘
              │
              ▼
     ┌─────────────────┐
     │   GitHub API    │
     └─────────────────┘

         WebSocket
              │
              ▼
     ┌─────────────────┐
     │   GUI Client    │
     └─────────────────┘
```

## 実装完了

全ての主要機能が実装され、ビルドが成功しています。

**実装済み**:
- ✅ Queue Processing Service
- ✅ Check Execution Service
- ✅ Webhook Handler
- ✅ Queue Controller (full CRUD)
- ✅ Configuration Controller
- ✅ WebSocket Broadcasting
- ✅ Database Schema & Migrations
- ✅ GitHub API Integration
- ✅ Error Handling & Logging

**次のステップ**:
1. 実際のGitHubリポジトリでテスト
2. CI/CDパイプライン設定
3. Dockerイメージ作成
4. 本番環境デプロイ
