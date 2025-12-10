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

document.addEventListener('alpine:init', () => {
    Alpine.store('queues', queueStore);
    Alpine.store('config', configStore);

    Alpine.data('dashboard', () => createDashboardComponent(queueStore, wsClient));
    Alpine.data('configEditor', () => createConfigEditor(configStore));
});

// Kick off connections and initial fetch
wsClient.connect();
queueStore.init();
configStore.init();
