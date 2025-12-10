/**
 * Config editor component focusing on UI interactions.
 */
function createConfigEditor(configStore) {
    return {
        store: configStore,

        get config() { return this.store.config; },
        get loading() { return this.store.loading; },
        get saving() { return this.store.saving; },
        get error() { return this.store.error; },
        get message() { return this.store.message; },

        async init() {
            await this.store.init();

            // Initialize config with defaults if needed
            if (!this.config.checks) {
                this.config.checks = [];
            }
            if (!this.config.githubToken) {
                this.config.githubToken = '';
            }
            if (!this.config.githubAPIURL) {
                this.config.githubAPIURL = 'https://api.github.com';
            }
            if (!this.config.githubMode) {
                this.config.githubMode = 'polling';
            }
            if (!this.config.pollingInterval) {
                this.config.pollingInterval = 60;
            }
            if (!this.config.triggerLabel) {
                this.config.triggerLabel = 'merge-queue';
            }
            if (!this.config.databasePath) {
                this.config.databasePath = '~/.imq/imq.db';
            }
            if (!this.config.databasePoolSize) {
                this.config.databasePoolSize = 5;
            }
            if (!this.config.logLevel) {
                this.config.logLevel = 'info';
            }
            if (!this.config.logFormat) {
                this.config.logFormat = 'pretty';
            }
        },

        addCheck() {
            if (!this.config.checks) {
                this.config.checks = [];
            }
            this.config.checks.push({
                name: '',
                type: 'githubActions',
                workflowName: '',
                jobName: '',
                scriptPath: '',
                arguments: '',
                timeout: null,
                failFast: 'true'
            });
        },

        removeCheck(index) {
            if (this.config.checks && this.config.checks.length > index) {
                this.config.checks.splice(index, 1);
            }
        },

        async save() {
            await this.store.save();
        },

        reset() {
            if (confirm('Are you sure you want to reset all settings to defaults?')) {
                this.store.reset();
            }
        }
    };
}

export { createConfigEditor };
