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
            case 'failed': return 'status-failed';
            default: return 'status-pending';
            }
        },

        statusIcon(status) {
            switch (status) {
            case 'ready':
                return '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>';
            case 'checking':
                return '<svg class="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/></svg>';
            case 'pending':
                return '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>';
            case 'failed':
                return '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>';
            default:
                return '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>';
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
            if (!pr) return '#';
            // Build GitHub PR URL from repository and PR number
            const repo = pr.repository || '';
            const prNumber = pr.number || '';
            if (repo && prNumber) {
                return `https://github.com/${repo}/pull/${prNumber}`;
            }
            return pr.url || '#';
        },

        actionsLink(pr) {
            if (!pr) return '#';
            // Build GitHub Actions URL
            const repo = pr.repository || '';
            const headSha = pr.headSha || '';
            if (repo && headSha) {
                return `https://github.com/${repo}/commit/${headSha}/checks`;
            }
            return this.prLink(pr);
        },

        formatStatus(status) {
            if (!status) return 'Unknown';
            return status.charAt(0).toUpperCase() + status.slice(1);
        },

        formatDuration(startTime, endTime) {
            if (!startTime) return '';
            const start = new Date(startTime);
            const end = endTime ? new Date(endTime) : new Date();
            const diff = Math.floor((end - start) / 1000); // seconds

            if (diff < 60) return `${diff}s`;
            if (diff < 3600) return `${Math.floor(diff / 60)}m ${diff % 60}s`;
            return `${Math.floor(diff / 3600)}h ${Math.floor((diff % 3600) / 60)}m`;
        }
    };
}

export { createDashboardComponent };
