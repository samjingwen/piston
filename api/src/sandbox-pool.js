const config = require('./config');

const available_slots = Array.from(
    { length: config.max_concurrent_jobs },
    (_, index) => index + 1,
);
const leased_slots = new Set();
const waiters = [];

async function acquire() {
    if (available_slots.length === 0) {
        return new Promise(resolve => waiters.push(resolve));
    }

    const slot_id = available_slots.shift();
    leased_slots.add(slot_id);
    return slot_id;
}

function release(slot_id) {
    if (!leased_slots.delete(slot_id)) {
        throw new Error(`Sandbox slot ${slot_id} is not leased`);
    }

    const waiter = waiters.shift();
    if (waiter !== undefined) {
        leased_slots.add(slot_id);
        waiter(slot_id);
    } else {
        available_slots.push(slot_id);
        available_slots.sort((left, right) => left - right);
    }
}

module.exports = { acquire, release };
