import { eventBus } from './EventBus.js';
import { AppEventType } from '../utils/eventTypes.js';

/**
 * Queue Service: wraps API client and emits events for store consumption.
 */
class QueueService {
    constructor(apiClient) {
        this.apiClient = apiClient;
    }

    async fetchQueues() {
        try {
            const queues = await this.apiClient.getQueues();
            eventBus.emit(AppEventType.QUEUES_UPDATED, queues || []);
            return queues || [];
        } catch (error) {
            eventBus.emit(AppEventType.ERROR_OCCURRED, {
                message: 'Failed to fetch queues',
                error
            });
            throw error;
        }
    }

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

    calculateQueueStats(queue) {
        const totalEntries = queue.entries?.length || 0;
        const pending = queue.entries?.filter(e => e.status === 'pending').length || 0;
        const checking = queue.entries?.filter(e => e.status === 'checking').length || 0;
        const ready = queue.entries?.filter(e => e.status === 'ready').length || 0;

        return { totalEntries, pending, checking, ready };
    }
}

export { QueueService };
