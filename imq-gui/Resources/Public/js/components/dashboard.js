/**
 * Dashboard component (view only, logic delegated to stores/services).
 */
function createDashboardComponent(queueStore, wsClient) {
    return {
        selectedQueueId: null,
        filterStatus: 'all',

        get connectionState() {
            return queueStore.connectionState;
        },

        get isConnected() {
            return this.connectionState === 'connected';
        },

        get queues() {
            if (this.filterStatus === 'all') {
                return queueStore.queues;
            }
            return queueStore.queues.filter(queue => {
                return (queue.entries || []).some(entry => entry.status === this.filterStatus);
            });
        },

        selectQueue(id) {
            this.selectedQueueId = id;
        },

        async refresh() {
            await queueStore.loadQueues();
        },

        statusColor(status) {
            switch (status) {
            case 'ready': return 'status-ready';
            case 'checking': return 'status-checking';
            case 'pending': return 'status-pending';
            default: return 'status-failed';
            }
        },

        queueStats(queue) {
            const entries = queue.entries || [];
            const total = entries.length;
            const ready = entries.filter(e => e.status === 'ready').length;
            const checking = entries.filter(e => e.status === 'checking').length;
            const pending = entries.filter(e => e.status === 'pending').length;
            return { total, ready, checking, pending };
        },

        prLink(pr) {
            return pr?.url || '#';
        }
    };
}

export { createDashboardComponent };
