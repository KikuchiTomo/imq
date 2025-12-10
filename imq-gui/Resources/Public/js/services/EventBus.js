/**
 * Simple event bus (pub/sub).
 */
class EventBus {
    constructor() {
        this.listeners = new Map();
    }

    on(eventType, callback) {
        if (!this.listeners.has(eventType)) {
            this.listeners.set(eventType, []);
        }
        this.listeners.get(eventType).push(callback);

        return () => {
            const callbacks = this.listeners.get(eventType);
            if (!callbacks) { return; }
            const idx = callbacks.indexOf(callback);
            if (idx >= 0) {
                callbacks.splice(idx, 1);
            }
        };
    }

    once(eventType, callback) {
        const unsubscribe = this.on(eventType, (data) => {
            callback(data);
            unsubscribe();
        });
        return unsubscribe;
    }

    emit(eventType, data) {
        const callbacks = this.listeners.get(eventType);
        if (!callbacks) { return; }

        callbacks.forEach(cb => {
            try {
                cb(data);
            } catch (error) {
                console.error(`EventBus listener error for ${eventType}`, error);
            }
        });
    }

    clear() {
        this.listeners.clear();
    }
}

const eventBus = new EventBus();

export { eventBus, EventBus };
