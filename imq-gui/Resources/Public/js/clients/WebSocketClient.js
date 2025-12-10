import { eventBus } from '../services/EventBus.js';
import { AppEventType } from '../utils/eventTypes.js';

const ConnectionState = {
    DISCONNECTED: 'disconnected',
    CONNECTING: 'connecting',
    CONNECTED: 'connected',
    RECONNECTING: 'reconnecting',
    FAILED: 'failed'
};

/**
 * WebSocket Client with simple reconnect and event dispatching.
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

    connect() {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            return;
        }

        this.connectionState = ConnectionState.CONNECTING;
        this.ws = new WebSocket(this.url);

        this.ws.onopen = () => {
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
                eventBus.emit(AppEventType.ERROR_OCCURRED, {
                    message: 'WebSocket parse error',
                    error
                });
            }
        };

        this.ws.onclose = () => {
            this.connectionState = ConnectionState.DISCONNECTED;
            this.emit('connection', { state: 'disconnected' });
            this.attemptReconnect();
        };

        this.ws.onerror = (error) => {
            this.emit('error', error);
        };
    }

    attemptReconnect() {
        if (this.reconnectAttempts >= this.maxReconnectAttempts) {
            this.connectionState = ConnectionState.FAILED;
            this.emit('connection', { state: 'failed' });
            return;
        }

        this.reconnectAttempts += 1;
        this.connectionState = ConnectionState.RECONNECTING;

        setTimeout(() => this.connect(), this.reconnectInterval);
    }

    on(event, callback) {
        if (!this.listeners.has(event)) {
            this.listeners.set(event, []);
        }
        this.listeners.get(event).push(callback);

        return () => {
            const callbacks = this.listeners.get(event) || [];
            const idx = callbacks.indexOf(callback);
            if (idx >= 0) {
                callbacks.splice(idx, 1);
            }
        };
    }

    emit(event, data) {
        const callbacks = this.listeners.get(event) || [];
        callbacks.forEach(cb => {
            try {
                cb(data);
            } catch (error) {
                console.error(`WebSocket listener error for ${event}`, error);
            }
        });
    }

    disconnect() {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
    }

    getConnectionState() {
        return this.connectionState;
    }
}

export { WebSocketClient, ConnectionState };
