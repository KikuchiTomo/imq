import { eventBus } from '../services/EventBus.js';
import { AppEventType, WSEventType } from '../utils/eventTypes.js';

/**
 * Queue store for Alpine.js state.
 */
function createQueueStore(queueService, wsClient) {
    return {
        queues: [],
        loading: false,
        error: null,
        lastUpdated: null,
        connectionState: wsClient.getConnectionState(),

        get totalQueues() {
            return this.queues.length;
        },

        get totalEntries() {
            return this.queues.reduce((sum, queue) => sum + (queue.entries?.length || 0), 0);
        },

        async init() {
            this.subscribeToEventBus();
            this.subscribeToWebSocket();
            await this.loadQueues();
        },

        async loadQueues() {
            this.loading = true;
            this.error = null;
            try {
                this.queues = await queueService.fetchQueues();
                this.lastUpdated = new Date();
            } catch (error) {
                this.error = error.message || 'Failed to load queues';
            } finally {
                this.loading = false;
            }
        },

        subscribeToEventBus() {
            eventBus.on(AppEventType.QUEUES_UPDATED, (queues) => {
                this.queues = queues || [];
                this.lastUpdated = new Date();
            });

            eventBus.on(AppEventType.QUEUE_UPDATED, (queue) => {
                if (!queue) { return; }
                this.upsertQueue(queue);
                this.lastUpdated = new Date();
            });
        },

        subscribeToWebSocket() {
            wsClient.on('connection', ({ state }) => {
                this.connectionState = state;
            });

            wsClient.on('message', (data) => {
                if (!data?.type) { return; }
                switch (data.type) {
                case WSEventType.QUEUE_ENTRY_ADDED:
                    this.handleEntryAdded(data.payload);
                    break;
                case WSEventType.QUEUE_ENTRY_REMOVED:
                    this.handleEntryRemoved(data.payload);
                    break;
                case WSEventType.QUEUE_ENTRY_STATUS_CHANGED:
                    this.handleEntryStatusChanged(data.payload);
                    break;
                default:
                    break;
                }
            });
        },

        handleEntryAdded(payload) {
            if (!payload?.queueId || !payload?.entry) { return; }
            const queue = this.queues.find(q => q.id === payload.queueId);
            if (queue) {
                queue.entries = queue.entries || [];
                queue.entries.push(payload.entry);
            }
        },

        handleEntryRemoved(payload) {
            if (!payload?.queueId || !payload?.entryId) { return; }
            const queue = this.queues.find(q => q.id === payload.queueId);
            if (queue?.entries) {
                queue.entries = queue.entries.filter(e => e.id !== payload.entryId);
            }
        },

        handleEntryStatusChanged(payload) {
            if (!payload?.queueId || !payload?.entryId || !payload?.newStatus) { return; }
            const queue = this.queues.find(q => q.id === payload.queueId);
            const entry = queue?.entries?.find(e => e.id === payload.entryId);
            if (entry) {
                entry.status = payload.newStatus;
            }
        },

        upsertQueue(queue) {
            const idx = this.queues.findIndex(q => q.id === queue.id);
            if (idx >= 0) {
                this.queues.splice(idx, 1, queue);
            } else {
                this.queues.push(queue);
            }
        }
    };
}

export { createQueueStore };
