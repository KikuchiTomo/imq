/**
 * WebSocket event types dispatched by imq-core.
 */
export const WSEventType = Object.freeze({
    QUEUE_ENTRY_ADDED: 'queue.entry.added',
    QUEUE_ENTRY_REMOVED: 'queue.entry.removed',
    QUEUE_ENTRY_STATUS_CHANGED: 'queue.entry.status_changed',
    CONFIG_UPDATED: 'config.updated'
});

/**
 * Internal UI event types.
 */
export const AppEventType = Object.freeze({
    QUEUES_UPDATED: 'app.queues.updated',
    QUEUE_UPDATED: 'app.queue.updated',
    CONFIG_UPDATED: 'app.config.updated',
    ERROR_OCCURRED: 'app.error.occurred',
    NOTIFICATION_SHOW: 'app.notification.show'
});
