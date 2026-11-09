#!/usr/bin/env node
const child_process = require('child_process');
const fs = require('fs/promises');
const fss = require('fs');
const path = require('path');
const timers = require('timers/promises');
const util = require('util');
const Logger = require('logplease');
const config = require('./config');

const logger = Logger.create('sandbox-supervisor');
const exec_file = util.promisify(child_process.execFile);
const STORAGE_ROOT = '/var/lib/piston-sandbox';
const SCRATCH_IMAGE = path.join(STORAGE_ROOT, 'scratch.ext4');
const SCRATCH_MOUNT = path.join(STORAGE_ROOT, 'pool');
const ISOLATE_ROOT = '/var/local/lib/isolate';
const FINDMNT_PATH = '/usr/bin/findmnt';
const LOSETUP_PATH = '/usr/sbin/losetup';
const MKFS_PATH = '/usr/sbin/mkfs.ext4';
const MOUNT_PATH = '/usr/bin/mount';
const UMOUNT_PATH = '/usr/bin/umount';
const LOOP_DETACH_TIMEOUT_MS = 10000;
const LOOP_DETACH_POLL_MS = 25;
const slots = new Map();
const operation_queues = new Map();
let worker = null;
let shutting_down = false;
let shutdown_exit_code = null;

function read_piston_account() {
    const line = fss
        .readFileSync('/etc/passwd', 'utf8')
        .split('\n')
        .find(entry => entry.startsWith('piston:'));
    if (line === undefined) throw new Error('Cannot find piston user');

    const fields = line.split(':');
    const uid = Number(fields[2]);
    const gid = Number(fields[3]);
    if (!Number.isSafeInteger(uid) || !Number.isSafeInteger(gid)) {
        throw new Error('Piston user has invalid uid or gid');
    }
    return { uid, gid };
}

async function run(command, args) {
    try {
        return await exec_file(command, args, { maxBuffer: 1024 * 1024 });
    } catch (error) {
        const details = [error.message, error.stdout, error.stderr]
            .filter(Boolean)
            .join('\n');
        throw new Error(`${command} failed:\n${details}`);
    }
}

async function create_sparse_file(file_path, size_mb) {
    const handle = await fs.open(file_path, 'w', 0o600);
    try {
        await handle.truncate(size_mb * 1024 * 1024);
    } finally {
        await handle.close();
    }
}

async function format_slot(slot) {
    await run(MKFS_PATH, [
        '-F',
        '-q',
        '-N',
        String(config.sandbox_slot_inodes),
        slot.image_path,
    ]);
}

async function inspect_loop_device(loop_device) {
    let result;
    try {
        result = await exec_file(
            LOSETUP_PATH,
            [
                '--list',
                '--noheadings',
                '--raw',
                '--output',
                'NAME,BACK-INO,BACK-MAJ:MIN',
                loop_device,
            ],
            { maxBuffer: 1024 * 1024 }
        );
    } catch (error) {
        if (
            error.code === 1 &&
            String(error.stdout ?? '').trim() === '' &&
            String(error.stderr ?? '').trim() === ''
        ) {
            return null;
        }
        const details = [error.message, error.stdout, error.stderr]
            .filter(Boolean)
            .join('\n');
        throw new Error(`${LOSETUP_PATH} failed:\n${details}`);
    }

    const output = result.stdout.trim();
    if (output === loop_device) return null;

    const fields = output.split(/\s+/);
    if (
        fields.length !== 3 ||
        fields[0] !== loop_device ||
        !/^\d+$/.test(fields[1]) ||
        !/^\d+:\d+$/.test(fields[2])
    ) {
        throw new Error(
            `Received invalid loop device identity for ${loop_device}: ${output}`
        );
    }
    return `${fields[1]}:${fields[2]}`;
}

async function get_mounted_loop_device(box_path) {
    const { stdout } = await run(FINDMNT_PATH, [
        '--noheadings',
        '--raw',
        '--output',
        'SOURCE',
        '--target',
        box_path,
    ]);
    const loop_device = stdout.trim();
    if (!/^\/dev\/loop\d+$/.test(loop_device)) {
        throw new Error(
            `Sandbox mount at ${box_path} has invalid loop device ${loop_device}`
        );
    }
    return loop_device;
}

async function wait_for_loop_detach(loop_device, loop_identity) {
    const deadline = Date.now() + LOOP_DETACH_TIMEOUT_MS;
    while (Date.now() < deadline) {
        const current_identity = await inspect_loop_device(loop_device);
        if (current_identity !== loop_identity) return;
        await timers.setTimeout(LOOP_DETACH_POLL_MS);
    }
    throw new Error(
        `Loop device ${loop_device} did not detach within ${LOOP_DETACH_TIMEOUT_MS}ms`
    );
}

async function initialize_storage() {
    if (!config.sandbox_storage_enabled) return;

    await fs.mkdir(STORAGE_ROOT, { recursive: true, mode: 0o700 });
    await fs.mkdir(SCRATCH_MOUNT, { recursive: true, mode: 0o700 });
    await create_sparse_file(SCRATCH_IMAGE, config.sandbox_scratch_size_mb);
    await run(MKFS_PATH, ['-F', '-q', SCRATCH_IMAGE]);
    await run(MOUNT_PATH, ['--options', 'loop', SCRATCH_IMAGE, SCRATCH_MOUNT]);
    await fs.chmod(SCRATCH_MOUNT, 0o700);

    for (let slot_id = 1; slot_id <= config.max_concurrent_jobs; slot_id++) {
        const slot = {
            id: slot_id,
            image_path: path.join(SCRATCH_MOUNT, `slot-${slot_id}.ext4`),
            state: 'initializing',
            box_id: null,
            loop_device: null,
            loop_identity: null,
        };
        slots.set(slot_id, slot);
        await create_sparse_file(slot.image_path, config.sandbox_slot_size_mb);
        await format_slot(slot);
        slot.state = 'ready';
    }

    logger.info(
        `Initialized ${config.max_concurrent_jobs} bounded sandbox slots`
    );
}

function get_slot(slot_id) {
    if (!Number.isSafeInteger(slot_id)) {
        throw new Error('Sandbox slot id must be an integer');
    }
    const slot = slots.get(slot_id);
    if (slot === undefined) {
        throw new Error(`Sandbox slot ${slot_id} does not exist`);
    }
    return slot;
}

function get_box_path(box_id) {
    if (!Number.isSafeInteger(box_id) || box_id < 0 || box_id > 998) {
        throw new Error('Isolate box id is out of range');
    }
    return path.join(ISOLATE_ROOT, String(box_id), 'box');
}

async function attach_slot(slot_id, box_id) {
    const slot = get_slot(slot_id);
    if (!['ready', 'dirty'].includes(slot.state)) {
        throw new Error(
            `Sandbox slot ${slot_id} cannot attach from state ${slot.state}`
        );
    }

    const box_path = get_box_path(box_id);
    const box_lstat = await fs.lstat(box_path);
    if (!box_lstat.isDirectory() || box_lstat.isSymbolicLink()) {
        throw new Error(`Isolate box path ${box_path} is not a directory`);
    }
    if ((await fs.realpath(box_path)) !== box_path) {
        throw new Error(`Isolate box path ${box_path} is not canonical`);
    }

    await run(MOUNT_PATH, ['--options', 'loop', slot.image_path, box_path]);
    const loop_device = await get_mounted_loop_device(box_path);
    const loop_identity = await inspect_loop_device(loop_device);
    if (loop_identity === null) {
        throw new Error(`Sandbox loop device ${loop_device} is not attached`);
    }
    await fs.chown(box_path, box_lstat.uid, box_lstat.gid);
    await fs.chmod(box_path, box_lstat.mode & 0o777);
    slot.state = 'attached';
    slot.box_id = box_id;
    slot.loop_device = loop_device;
    slot.loop_identity = loop_identity;
}

async function detach_slot(slot_id, box_id) {
    const slot = get_slot(slot_id);
    if (slot.state !== 'attached' || slot.box_id !== box_id) {
        throw new Error(
            `Sandbox slot ${slot_id} is not attached to box ${box_id}`
        );
    }

    const loop_device = slot.loop_device;
    const loop_identity = slot.loop_identity;
    if (loop_device === null || loop_identity === null) {
        throw new Error(`Sandbox slot ${slot_id} has no attached loop device`);
    }

    await run(UMOUNT_PATH, [get_box_path(box_id)]);
    await wait_for_loop_detach(loop_device, loop_identity);
    slot.state = 'dirty';
    slot.box_id = null;
    slot.loop_device = null;
    slot.loop_identity = null;
}

async function reset_slot(slot_id) {
    const slot = get_slot(slot_id);
    if (!['ready', 'dirty'].includes(slot.state)) {
        throw new Error(
            `Sandbox slot ${slot_id} cannot reset from state ${slot.state}`
        );
    }

    await create_sparse_file(slot.image_path, config.sandbox_slot_size_mb);
    await format_slot(slot);
    slot.state = 'ready';
    slot.box_id = null;
    slot.loop_device = null;
    slot.loop_identity = null;
}

async function perform_operation(message) {
    switch (message.action) {
        case 'attach':
            return attach_slot(message.slot_id, message.box_id);
        case 'detach':
            return detach_slot(message.slot_id, message.box_id);
        case 'reset':
            return reset_slot(message.slot_id);
        case 'quarantine':
            get_slot(message.slot_id);
            logger.error(
                `Sandbox slot ${message.slot_id} was quarantined: ${String(
                    message.reason
                ).slice(0, 1000)}`
            );
            request_shutdown(1);
            return;
        default:
            throw new Error(`Unknown sandbox storage action ${message.action}`);
    }
}

function request_shutdown(exit_code = 0) {
    if (shutdown_exit_code === null || exit_code > shutdown_exit_code) {
        shutdown_exit_code = exit_code;
    }
    if (shutting_down) return;
    shutting_down = true;
    if (worker !== null && worker.exitCode === null) worker.kill('SIGTERM');
}

function handle_message(message) {
    if (message?.type !== 'sandbox-storage-request') return;

    const previous_operation =
        operation_queues.get(message.slot_id) ?? Promise.resolve();
    const operation = previous_operation.then(async () => {
        try {
            await perform_operation(message);
            worker.send({
                type: 'sandbox-storage-result',
                request_id: message.request_id,
                ok: true,
            });
        } catch (error) {
            logger.error(`Sandbox storage operation failed: ${error.message}`);
            if (worker.connected) {
                worker.send({
                    type: 'sandbox-storage-result',
                    request_id: message.request_id,
                    ok: false,
                    error: error.message,
                });
            }
            request_shutdown(1);
        }
    });
    operation_queues.set(message.slot_id, operation);
    operation.finally(() => {
        if (operation_queues.get(message.slot_id) === operation) {
            operation_queues.delete(message.slot_id);
        }
    });
}

async function main() {
    if (process.getuid() !== 0) {
        throw new Error('Sandbox supervisor must run as root');
    }

    Logger.setLogLevel(config.log_level);
    await initialize_storage();

    const account = read_piston_account();
    worker = child_process.fork('/piston_api/src/index.js', [], {
        cwd: '/piston_api',
        uid: account.uid,
        gid: account.gid,
        stdio: ['inherit', 'inherit', 'inherit', 'ipc'],
    });
    worker.on('message', handle_message);
    worker.on('error', error => {
        logger.error(`Piston API worker failed: ${error.message}`);
        request_shutdown(1);
    });
    worker.on('exit', (code, signal) => {
        if (signal !== null) {
            logger.error(`Piston API worker exited from signal ${signal}`);
        }
        process.exit(shutdown_exit_code ?? code ?? 1);
    });
}

process.on('SIGINT', request_shutdown);
process.on('SIGTERM', request_shutdown);

main().catch(error => {
    logger.error(error.message);
    process.exit(1);
});
