const config = require('./config');

const REQUEST_TIMEOUT_MS = 30000;
let next_request_id = 1;
const pending_requests = new Map();

if (config.sandbox_storage_enabled) {
    process.on('message', message => {
        if (message?.type !== 'sandbox-storage-result') return;

        const pending = pending_requests.get(message.request_id);
        if (pending === undefined) return;

        pending_requests.delete(message.request_id);
        clearTimeout(pending.timeout);
        if (message.ok) {
            pending.resolve();
        } else {
            pending.reject(new Error(message.error));
        }
    });

    process.on('disconnect', () => {
        for (const pending of pending_requests.values()) {
            clearTimeout(pending.timeout);
            pending.reject(
                new Error('Sandbox storage supervisor disconnected'),
            );
        }
        pending_requests.clear();
    });
}

function request(action, slot_id, box_id = null, reason = null) {
    if (!config.sandbox_storage_enabled) return Promise.resolve();
    if (typeof process.send !== 'function' || !process.connected) {
        return Promise.reject(
            new Error('Sandbox storage supervisor is unavailable'),
        );
    }

    const request_id = next_request_id++;
    return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
            pending_requests.delete(request_id);
            reject(new Error(`Sandbox storage ${action} operation timed out`));
        }, REQUEST_TIMEOUT_MS);

        pending_requests.set(request_id, { resolve, reject, timeout });
        process.send(
            {
                type: 'sandbox-storage-request',
                request_id,
                action,
                slot_id,
                box_id,
                reason,
            },
            error => {
                if (!error) return;
                const pending = pending_requests.get(request_id);
                if (pending === undefined) return;
                pending_requests.delete(request_id);
                clearTimeout(pending.timeout);
                reject(error);
            },
        );
    });
}

module.exports = {
    enabled: config.sandbox_storage_enabled,
    attach: (slot_id, box_id) => request('attach', slot_id, box_id),
    detach: (slot_id, box_id) => request('detach', slot_id, box_id),
    reset: slot_id => request('reset', slot_id),
    quarantine: (slot_id, reason) =>
        request('quarantine', slot_id, null, reason),
};
