/**
 * Config editor component focusing on UI interactions.
 */
function createConfigEditor(configStore) {
    return {
        store: configStore,
        saving: false,
        error: null,
        message: null,

        get config() {
            return this.store.config || {};
        },
        get loading() {
            return this.store.loading || false;
        },

        async init() {
            await this.store.init();
            // Convert checkConfigurations to checks after loading
            if (!this.config.checks && this.config.checkConfigurations) {
                this.config.checks = this.config.checkConfigurations.map(name => ({
                    name: name,
                    type: 'githubActions',
                    workflowName: '',
                    jobName: '',
                    scriptPath: '',
                    arguments: '',
                    timeout: null,
                    failFast: 'true'
                }));
            } else if (!this.config.checks) {
                this.config.checks = [];
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
            this.saving = true;
            this.error = null;
            this.message = null;
            try {
                // Convert checks (array of objects) to checkConfigurations (array of strings)
                if (this.config.checks) {
                    this.store.config.checkConfigurations = this.config.checks.map(check => check.name || '');
                }
                await this.store.save();
                this.message = 'Configuration updated successfully!';
                setTimeout(() => { this.message = null; }, 3000);
            } catch (err) {
                this.error = err.message || 'Failed to save configuration';
            } finally {
                this.saving = false;
            }
        },

        reset() {
            if (confirm('Are you sure you want to reset all settings to defaults?')) {
                this.error = null;
                this.message = null;
                try {
                    this.store.reset();
                    this.message = 'Configuration reset to defaults';
                    setTimeout(() => { this.message = null; }, 3000);
                } catch (err) {
                    this.error = err.message || 'Failed to reset configuration';
                }
            }
        }
    };
}

export { createConfigEditor };
