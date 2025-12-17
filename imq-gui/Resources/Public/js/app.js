import { APIClient } from './clients/APIClient.js';
import { WebSocketClient } from './clients/WebSocketClient.js';
import { QueueService } from './services/QueueService.js';
import { createQueueStore } from './stores/QueueStore.js';
import { createConfigStore } from './stores/ConfigStore.js';
import { createDashboardComponent } from './components/dashboard.js';
import { createConfigEditor } from './components/configEditor.js';

const API_BASE_URL = window.IMQ_CONFIG?.apiURL || 'http://localhost:8080';
const WS_URL = window.IMQ_CONFIG?.wsURL || 'ws://localhost:8080/ws/events';

const apiClient = new APIClient(API_BASE_URL);
const wsClient = new WebSocketClient(WS_URL, {
    reconnectInterval: 4000,
    maxReconnectAttempts: 20
});

const queueService = new QueueService(apiClient);
const queueStore = createQueueStore(queueService, wsClient);
const configStore = createConfigStore(apiClient, wsClient);

console.log('[IMQ] app.js loaded, waiting for Alpine...');

// Wait for Alpine to be available
function initAlpine() {
    if (typeof window.Alpine === 'undefined') {
        console.log('[IMQ] Alpine not ready, retrying...');
        setTimeout(initAlpine, 50);
        return;
    }

    console.log('[IMQ] Alpine ready, registering components...');

    window.Alpine.store('queues', queueStore);
    window.Alpine.store('config', configStore);

    window.Alpine.data('dashboard', () => createDashboardComponent(queueStore, wsClient));
    window.Alpine.data('configEditor', () => createConfigEditor(configStore));

    console.log('[IMQ] Components registered');

    // Connect WebSocket after a short delay
    setTimeout(() => {
        wsClient.connect();
    }, 500);
}

// Start initialization
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initAlpine);
} else {
    initAlpine();
}
