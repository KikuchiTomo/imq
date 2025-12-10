/**
 * REST API Client for IMQ Core.
 * Handles unwrap of APIResponse<T> format.
 */
class APIClient {
    constructor(baseURL) {
        this.baseURL = baseURL.replace(/\/$/, '');
    }

    async request(path, options = {}) {
        const response = await fetch(`${this.baseURL}${path}`, {
            headers: {
                'Content-Type': 'application/json',
                ...(options.headers || {})
            },
            ...options
        });

        const contentType = response.headers.get('content-type') || '';
        const isJSON = contentType.includes('application/json');
        const payload = isJSON ? await response.json() : await response.text();

        if (!response.ok) {
            throw new APIError(payload?.error?.message || 'Request failed', response.status);
        }

        // APIResponse wrapper support
        if (payload && typeof payload === 'object' && 'success' in payload) {
            if (!payload.success) {
                throw new APIError(payload?.error?.message || 'Request failed', response.status);
            }
            return payload.data;
        }

        return payload;
    }

    // Queues
    async getQueues() {
        return this.request('/api/v1/queues');
    }

    async getQueue(id) {
        return this.request(`/api/v1/queues/${id}`);
    }

    // Configuration
    async getConfiguration() {
        return this.request('/api/v1/config');
    }

    async updateConfiguration(config) {
        return this.request('/api/v1/config', {
            method: 'PUT',
            body: JSON.stringify(config)
        });
    }

    // Stats
    async getStats() {
        return this.request('/api/v1/stats');
    }
}

class APIError extends Error {
    constructor(message, statusCode) {
        super(message);
        this.name = 'APIError';
        this.statusCode = statusCode;
    }
}

export { APIClient, APIError };
