# アーキテクチャ設計 - 第3回検討（最終版）

## 検討日
2025-12-10

## 前回の課題への対応 + フロントエンドアーキテクチャの追加

### 重要な指摘事項

**問題点**: プランファイルのAlpine.jsコード例が、責務が混在していてクリーンではない
- WebSocket接続、API呼び出し、状態管理、イベントハンドリングが全て1つのコンポーネントに集約
- 責務の分離ができていない
- テストしづらい
- 再利用性が低い

**改善方針**: フロントエンドも適切にレイヤー分割し、クリーンアーキテクチャの原則を適用

## フロントエンド（imq-gui JavaScript）のアーキテクチャ

### レイヤー構成

```
┌─────────────────────────────────────┐
│   Components (Alpine.js)            │  View層（表示のみ）
├─────────────────────────────────────┤
│   Stores (State Management)         │  状態管理
├─────────────────────────────────────┤
│   Services (Business Logic)         │  ビジネスロジック
├─────────────────────────────────────┤
│   Clients (API/WebSocket)           │  通信層
└─────────────────────────────────────┘
```

### ディレクトリ構造（改善版）

```
Resources/Public/js/
├── clients/
│   ├── APIClient.js                 # REST API通信
│   └── WebSocketClient.js           # WebSocket通信
├── services/
│   ├── EventBus.js                  # イベント配信
│   └── QueueService.js              # キュー操作のビジネスロジック
├── stores/
│   ├── QueueStore.js                # キュー状態管理
│   └── ConfigStore.js               # 設定状態管理
├── components/
│   ├── dashboard.js                 # Dashboardコンポーネント
│   ├── queueList.js                 # QueueListコンポーネント
│   └── configEditor.js              # Config編集コンポーネント
├── utils/
│   └── eventTypes.js                # イベント型定義（enum代替）
└── app.js                           # エントリーポイント
```

### 詳細設計

#### 1. Clients Layer（通信層）

**APIClient.js**: REST API通信を抽象化
```javascript
// /Resources/Public/js/clients/APIClient.js

/**
 * REST API Client
 * 責務: imq-core REST APIとの通信のみ
 */
class APIClient {
    constructor(baseURL) {
        this.baseURL = baseURL;
    }

    /**
     * Queues API
     */
    async getQueues() {
        const response = await fetch(`${this.baseURL}/api/v1/queues`);
        if (!response.ok) {
            throw new APIError('Failed to fetch queues', response.status);
        }
        return await response.json();
    }

    async getQueue(id) {
        const response = await fetch(`${this.baseURL}/api/v1/queues/${id}`);
        if (!response.ok) {
            throw new APIError('Failed to fetch queue', response.status);
        }
        return await response.json();
    }

    /**
     * Configuration API
     */
    async getConfiguration() {
        const response = await fetch(`${this.baseURL}/api/v1/config`);
        if (!response.ok) {
            throw new APIError('Failed to fetch configuration', response.status);
        }
        return await response.json();
    }

    async updateConfiguration(config) {
        const response = await fetch(`${this.baseURL}/api/v1/config`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(config)
        });
        if (!response.ok) {
            throw new APIError('Failed to update configuration', response.status);
        }
        return await response.json();
    }

    /**
     * Stats API
     */
    async getStats() {
        const response = await fetch(`${this.baseURL}/api/v1/stats`);
        if (!response.ok) {
            throw new APIError('Failed to fetch stats', response.status);
        }
        return await response.json();
    }
}

class APIError extends Error {
    constructor(message, statusCode) {
        super(message);
        this.name = 'APIError';
        this.statusCode = statusCode;
    }
}

export { APIClient, APIError };
```

**WebSocketClient.js**: WebSocket通信を抽象化
```javascript
// /Resources/Public/js/clients/WebSocketClient.js

/**
 * WebSocket Client
 * 責務: WebSocket接続の管理と再接続のみ
 */
class WebSocketClient {
    constructor(url, options = {}) {
        this.url = url;
        this.reconnectInterval = options.reconnectInterval || 5000;
        this.maxReconnectAttempts = options.maxReconnectAttempts || 10;
        this.reconnectAttempts = 0;
        this.ws = null;
        this.listeners = new Map();
        this.connectionState = ConnectionState.DISCONNECTED;
    }

    /**
     * 接続開始
     */
    connect() {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            console.warn('WebSocket is already connected');
            return;
        }

        this.ws = new WebSocket(this.url);

        this.ws.onopen = () => {
            console.log('WebSocket connected');
            this.connectionState = ConnectionState.CONNECTED;
            this.reconnectAttempts = 0;
            this.emit('connection', { state: 'connected' });
        };

        this.ws.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                this.emit('message', data);
            } catch (error) {
                console.error('Failed to parse WebSocket message:', error);
            }
        };

        this.ws.onclose = () => {
            console.log('WebSocket disconnected');
            this.connectionState = ConnectionState.DISCONNECTED;
            this.emit('connection', { state: 'disconnected' });
            this.attemptReconnect();
        };

        this.ws.onerror = (error) => {
            console.error('WebSocket error:', error);
            this.emit('error', error);
        };
    }

    /**
     * 再接続試行
     */
    attemptReconnect() {
        if (this.reconnectAttempts >= this.maxReconnectAttempts) {
            console.error('Max reconnect attempts reached');
            this.connectionState = ConnectionState.FAILED;
            this.emit('connection', { state: 'failed' });
            return;
        }

        this.reconnectAttempts++;
        this.connectionState = ConnectionState.RECONNECTING;

        console.log(`Attempting to reconnect (${this.reconnectAttempts}/${this.maxReconnectAttempts})...`);

        setTimeout(() => {
            this.connect();
        }, this.reconnectInterval);
    }

    /**
     * イベントリスナー登録
     */
    on(event, callback) {
        if (!this.listeners.has(event)) {
            this.listeners.set(event, []);
        }
        this.listeners.get(event).push(callback);

        // Unsubscribe function
        return () => {
            const callbacks = this.listeners.get(event);
            const index = callbacks.indexOf(callback);
            if (index > -1) {
                callbacks.splice(index, 1);
            }
        };
    }

    /**
     * イベント発火
     */
    emit(event, data) {
        const callbacks = this.listeners.get(event);
        if (callbacks) {
            callbacks.forEach(callback => callback(data));
        }
    }

    /**
     * 接続切断
     */
    disconnect() {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
    }

    /**
     * 接続状態取得
     */
    getConnectionState() {
        return this.connectionState;
    }
}

const ConnectionState = {
    DISCONNECTED: 'disconnected',
    CONNECTING: 'connecting',
    CONNECTED: 'connected',
    RECONNECTING: 'reconnecting',
    FAILED: 'failed'
};

export { WebSocketClient, ConnectionState };
```

#### 2. Utils Layer（ユーティリティ）

**eventTypes.js**: イベント型定義（TypeScriptのenumの代替）
```javascript
// /Resources/Public/js/utils/eventTypes.js

/**
 * WebSocketで受信するイベントタイプ
 */
export const WSEventType = Object.freeze({
    // Queue events
    QUEUE_ENTRY_ADDED: 'queue.entry.added',
    QUEUE_ENTRY_REMOVED: 'queue.entry.removed',
    QUEUE_ENTRY_STATUS_CHANGED: 'queue.entry.status_changed',

    // Check events
    CHECK_STARTED: 'check.started',
    CHECK_COMPLETED: 'check.completed',
    CHECK_FAILED: 'check.failed',

    // PR events
    PR_UPDATED: 'pull_request.updated',
    PR_MERGED: 'pull_request.merged',

    // System events
    CONFIG_UPDATED: 'config.updated'
});

/**
 * 内部イベントタイプ（フロントエンド内のイベントバス用）
 */
export const AppEventType = Object.freeze({
    // Data events
    QUEUES_UPDATED: 'app.queues.updated',
    QUEUE_UPDATED: 'app.queue.updated',
    CONFIG_UPDATED: 'app.config.updated',

    // UI events
    NOTIFICATION_SHOW: 'app.notification.show',
    ERROR_OCCURRED: 'app.error.occurred'
});
```

#### 3. Services Layer（ビジネスロジック）

**EventBus.js**: イベント配信（Pub/Sub）
```javascript
// /Resources/Public/js/services/EventBus.js

/**
 * Event Bus (Pub/Sub pattern)
 * 責務: アプリケーション内のイベント配信のみ
 */
class EventBus {
    constructor() {
        this.listeners = new Map();
    }

    /**
     * イベントリスナー登録
     */
    on(eventType, callback) {
        if (!this.listeners.has(eventType)) {
            this.listeners.set(eventType, []);
        }
        this.listeners.get(eventType).push(callback);

        // Unsubscribe function
        return () => {
            const callbacks = this.listeners.get(eventType);
            const index = callbacks.indexOf(callback);
            if (index > -1) {
                callbacks.splice(index, 1);
            }
        };
    }

    /**
     * イベント発火
     */
    emit(eventType, data) {
        const callbacks = this.listeners.get(eventType);
        if (callbacks) {
            callbacks.forEach(callback => {
                try {
                    callback(data);
                } catch (error) {
                    console.error(`Error in event listener for ${eventType}:`, error);
                }
            });
        }
    }

    /**
     * 一度だけ実行されるリスナー
     */
    once(eventType, callback) {
        const unsubscribe = this.on(eventType, (data) => {
            callback(data);
            unsubscribe();
        });
        return unsubscribe;
    }

    /**
     * 全リスナーをクリア
     */
    clear() {
        this.listeners.clear();
    }
}

// Singleton instance
const eventBus = new EventBus();

export { eventBus, EventBus };
```

**QueueService.js**: キュー操作のビジネスロジック
```javascript
// /Resources/Public/js/services/QueueService.js
import { eventBus } from './EventBus.js';
import { AppEventType } from '../utils/eventTypes.js';

/**
 * Queue Service
 * 責務: キュー関連のビジネスロジック
 */
class QueueService {
    constructor(apiClient) {
        this.apiClient = apiClient;
    }

    /**
     * 全キューを取得
     */
    async fetchQueues() {
        try {
            const queues = await this.apiClient.getQueues();
            eventBus.emit(AppEventType.QUEUES_UPDATED, queues);
            return queues;
        } catch (error) {
            eventBus.emit(AppEventType.ERROR_OCCURRED, {
                message: 'Failed to fetch queues',
                error
            });
            throw error;
        }
    }

    /**
     * 特定のキューを取得
     */
    async fetchQueue(id) {
        try {
            const queue = await this.apiClient.getQueue(id);
            eventBus.emit(AppEventType.QUEUE_UPDATED, queue);
            return queue;
        } catch (error) {
            eventBus.emit(AppEventType.ERROR_OCCURRED, {
                message: `Failed to fetch queue ${id}`,
                error
            });
            throw error;
        }
    }

    /**
     * キューエントリの順番を取得
     */
    getEntryPosition(queue, entryId) {
        return queue.entries.findIndex(entry => entry.id === entryId) + 1;
    }

    /**
     * キューの統計情報を計算
     */
    calculateQueueStats(queue) {
        const totalEntries = queue.entries.length;
        const pendingCount = queue.entries.filter(e => e.status === 'pending').length;
        const checkingCount = queue.entries.filter(e => e.status === 'checking').length;
        const readyCount = queue.entries.filter(e => e.status === 'ready').length;

        return {
            totalEntries,
            pendingCount,
            checkingCount,
            readyCount
        };
    }
}

export { QueueService };
```

#### 4. Stores Layer（状態管理）

**QueueStore.js**: キュー状態管理（Alpine.js Storeパターン）
```javascript
// /Resources/Public/js/stores/QueueStore.js
import { eventBus } from '../services/EventBus.js';
import { AppEventType, WSEventType } from '../utils/eventTypes.js';

/**
 * Queue Store (State Management)
 * 責務: キュー状態の保持と更新のみ
 */
function createQueueStore(queueService, wsClient) {
    return {
        // State
        queues: [],
        loading: false,
        error: null,
        lastUpdated: null,

        // Computed properties
        get totalQueues() {
            return this.queues.length;
        },

        get totalPRs() {
            return this.queues.reduce((sum, queue) => sum + queue.entries.length, 0);
        },

        // Actions
        async init() {
            this.subscribeToEvents();
            await this.loadQueues();
        },

        async loadQueues() {
            this.loading = true;
            this.error = null;

            try {
                this.queues = await queueService.fetchQueues();
                this.lastUpdated = new Date();
            } catch (error) {
                this.error = error.message;
            } finally {
                this.loading = false;
            }
        },

        subscribeToEvents() {
            // WebSocket events
            wsClient.on('message', (event) => {
                this.handleWebSocketEvent(event);
            });

            // Internal app events
            eventBus.on(AppEventType.QUEUES_UPDATED, (queues) => {
                this.queues = queues;
                this.lastUpdated = new Date();
            });
        },

        handleWebSocketEvent(event) {
            switch (event.type) {
                case WSEventType.QUEUE_ENTRY_ADDED:
                    this.handleEntryAdded(event.data);
                    break;
                case WSEventType.QUEUE_ENTRY_REMOVED:
                    this.handleEntryRemoved(event.data);
                    break;
                case WSEventType.QUEUE_ENTRY_STATUS_CHANGED:
                    this.handleEntryStatusChanged(event.data);
                    break;
                default:
                    console.log('Unhandled event type:', event.type);
            }
        },

        handleEntryAdded(data) {
            const queue = this.queues.find(q => q.id === data.queueId);
            if (queue) {
                queue.entries.push(data.entry);
                this.lastUpdated = new Date();
            }
        },

        handleEntryRemoved(data) {
            const queue = this.queues.find(q => q.id === data.queueId);
            if (queue) {
                queue.entries = queue.entries.filter(e => e.id !== data.entryId);
                this.lastUpdated = new Date();
            }
        },

        handleEntryStatusChanged(data) {
            const queue = this.queues.find(q => q.id === data.queueId);
            if (queue) {
                const entry = queue.entries.find(e => e.id === data.entryId);
                if (entry) {
                    entry.status = data.newStatus;
                    this.lastUpdated = new Date();
                }
            }
        }
    };
}

export { createQueueStore };
```

#### 5. Components Layer（View層）

**dashboard.js**: Dashboardコンポーネント（表示のみ）
```javascript
// /Resources/Public/js/components/dashboard.js

/**
 * Dashboard Component
 * 責務: ダッシュボードの表示のみ（ロジックはStoreとServiceに委譲）
 */
function createDashboardComponent(queueStore, wsClient) {
    return {
        // Local UI state only
        selectedQueueId: null,
        filterStatus: 'all',

        // Computed properties
        get filteredQueues() {
            if (this.filterStatus === 'all') {
                return queueStore.queues;
            }
            return queueStore.queues.filter(queue => {
                return queue.entries.some(entry => entry.status === this.filterStatus);
            });
        },

        get connectionStatus() {
            return wsClient.getConnectionState();
        },

        get isConnected() {
            return this.connectionStatus === 'connected';
        },

        // Event handlers
        selectQueue(queueId) {
            this.selectedQueueId = queueId;
        },

        setFilter(status) {
            this.filterStatus = status;
        },

        async refresh() {
            await queueStore.loadQueues();
        }
    };
}

export { createDashboardComponent };
```

#### 6. Entry Point

**app.js**: アプリケーションのエントリーポイント
```javascript
// /Resources/Public/js/app.js
import { APIClient } from './clients/APIClient.js';
import { WebSocketClient } from './clients/WebSocketClient.js';
import { QueueService } from './services/QueueService.js';
import { createQueueStore } from './stores/QueueStore.js';
import { createDashboardComponent } from './components/dashboard.js';

// Configuration
const API_BASE_URL = window.IMQ_CONFIG?.apiUrl || 'http://localhost:8080';
const WS_URL = window.IMQ_CONFIG?.wsUrl || 'ws://localhost:8080/ws/events';

// Initialize clients
const apiClient = new APIClient(API_BASE_URL);
const wsClient = new WebSocketClient(WS_URL);

// Initialize services
const queueService = new QueueService(apiClient);

// Initialize stores
const queueStore = createQueueStore(queueService, wsClient);

// Alpine.js setup
document.addEventListener('alpine:init', () => {
    // Register global store
    Alpine.store('queues', queueStore);

    // Register components
    Alpine.data('dashboard', () => createDashboardComponent(queueStore, wsClient));
});

// Connect WebSocket
wsClient.connect();

// Initialize store
queueStore.init();

// Global error handler
window.addEventListener('unhandledrejection', (event) => {
    console.error('Unhandled promise rejection:', event.reason);
    eventBus.emit(AppEventType.ERROR_OCCURRED, {
        message: 'Unexpected error occurred',
        error: event.reason
    });
});
```

### Leaf Templateでの使用例

```html
<!-- Resources/Views/dashboard.leaf -->
#extend("layout"):
    #export("content"):
        <div x-data="dashboard" x-init="$store.queues.init()">
            <!-- Connection status -->
            <div class="mb-4">
                <span
                    x-show="isConnected"
                    class="badge badge-success">
                    Connected
                </span>
                <span
                    x-show="!isConnected"
                    class="badge badge-error">
                    Disconnected
                </span>
            </div>

            <!-- Filter -->
            <div class="mb-4">
                <select x-model="filterStatus" @change="setFilter($event.target.value)">
                    <option value="all">All</option>
                    <option value="pending">Pending</option>
                    <option value="checking">Checking</option>
                    <option value="ready">Ready</option>
                </select>
            </div>

            <!-- Queue list -->
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <template x-for="queue in filteredQueues" :key="queue.id">
                    <div
                        class="card"
                        @click="selectQueue(queue.id)">
                        <h3 x-text="queue.repository.fullName + ' / ' + queue.baseBranch"></h3>
                        <p x-text="queue.entries.length + ' PRs'"></p>
                    </div>
                </template>
            </div>

            <!-- Refresh button -->
            <button
                @click="refresh()"
                :disabled="$store.queues.loading">
                <span x-show="!$store.queues.loading">Refresh</span>
                <span x-show="$store.queues.loading">Loading...</span>
            </button>
        </div>
    #endexport
#endextend
```

## アーキテクチャの利点

### 1. 責務の分離
- **Clients**: 通信のみ
- **Services**: ビジネスロジックのみ
- **Stores**: 状態管理のみ
- **Components**: 表示のみ

### 2. テスタビリティ
```javascript
// 各レイヤーを独立してテスト可能
describe('QueueService', () => {
    it('should fetch queues', async () => {
        const mockAPIClient = {
            getQueues: jest.fn().mockResolvedValue([])
        };
        const service = new QueueService(mockAPIClient);
        await service.fetchQueues();
        expect(mockAPIClient.getQueues).toHaveBeenCalled();
    });
});
```

### 3. 再利用性
- 各クラスが独立しているため、他のコンポーネントでも再利用可能
- APIClientは他のページでも使用可能

### 4. 拡張性
- 新しいイベントタイプの追加が容易（eventTypes.jsに追加するだけ）
- 新しいServiceの追加が容易（既存のクラスに影響なし）

### 5. 型安全性（将来的にTypeScriptへ移行可能）
- 明確なインターフェースにより、TypeScriptへの移行が容易
- JSDocで型アノテーションを追加可能

## まとめ

### imq-core (Swift)
- ✅ クリーンアーキテクチャ（4層）
- ✅ 依存性逆転の原則
- ✅ 単一責任の原則
- ✅ Actor patternで並行性制御

### imq-gui (JavaScript)
- ✅ レイヤー分割（4層）
- ✅ 責務の分離
- ✅ イベント駆動アーキテクチャ
- ✅ テスタビリティ

### 全体
- ✅ API経由の通信（SQLite直接アクセスなし）
- ✅ WebSocketでリアルタイム更新
- ✅ エラーハンドリング戦略
- ✅ 拡張性と保守性

## 次のステップ

この設計をベースに、各機能の実装ドキュメントを作成します：
1. ✅ `plan-docs/github-integration/` - GitHub連携の詳細
2. ✅ `plan-docs/queue-processing/` - キュー処理の詳細
3. ✅ `plan-docs/check-execution/` - Check実行の詳細
4. ✅ `plan-docs/web-gui/` - Web GUIの詳細実装
