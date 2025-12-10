import { eventBus } from '../services/EventBus.js';
import { AppEventType, WSEventType } from '../utils/eventTypes.js';

/**
 * Configuration store for settings view.
 */
function createConfigStore(apiClient, wsClient) {
    return {
        config: {
            triggerLabel: 'merge-queue',
            githubMode: 'polling',
            pollingInterval: 60,
            webhookSecret: '',
            checkConfigurations: '{}',
            notificationTemplates: '{}'
        },
        loading: false,
        saving: false,
        error: null,
        message: null,

        async init() {
            this.subscribe();
            await this.load();
        },

        async load() {
            this.loading = true;
            this.error = null;
            try {
                const data = await apiClient.getConfiguration();
                if (data) {
                    this.config = {
                        ...this.config,
                        ...data
                    };
                }
            } catch (error) {
                this.error = error.message || 'Failed to load configuration';
            } finally {
                this.loading = false;
            }
        },

        async save() {
            this.saving = true;
            this.error = null;
            this.message = null;
            try {
                const updated = await apiClient.updateConfiguration(this.config);
                if (updated) {
                    this.config = { ...this.config, ...updated };
                }
                this.message = 'Configuration updated';
                eventBus.emit(AppEventType.CONFIG_UPDATED, this.config);
            } catch (error) {
                this.error = error.message || 'Failed to save configuration';
            } finally {
                this.saving = false;
            }
        },

        subscribe() {
            wsClient.on('message', (data) => {
                if (data?.type === WSEventType.CONFIG_UPDATED && data?.payload) {
                    this.config = {
                        ...this.config,
                        ...data.payload
                    };
                    this.message = 'Configuration updated remotely';
                }
            });
        }
    };
}

export { createConfigStore };
