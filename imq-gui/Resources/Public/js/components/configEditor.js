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
        },

        async save() {
            await this.store.save();
        }
    };
}

export { createConfigEditor };
