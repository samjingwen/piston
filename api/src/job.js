const logplease = require('logplease');
const { randomUUID } = require('crypto');
const cp = require('child_process');
const path = require('path');
const config = require('./config');
const fs = require('fs/promises');
const globals = require('./globals');
const sandbox_pool = require('./sandbox-pool');
const sandbox_storage = require('./sandbox-storage');
const util = require('util');

const job_states = {
    READY: Symbol('Ready to be primed'),
    PRIMED: Symbol('Primed and ready for execution'),
    EXECUTED: Symbol('Executed and ready for cleanup'),
};

const MAX_BOX_ID = 999;
const ISOLATE_PATH = '/usr/local/bin/isolate';
let box_id = 0;

const exec_file = util.promisify(cp.execFile);

const get_next_box_id = () => ++box_id % MAX_BOX_ID;

class Job {
    #dirty_boxes;
    #slot_id;
    #cleanup_started;
    constructor({
        runtime,
        files,
        args,
        stdin,
        timeouts,
        cpu_times,
        memory_limits,
    }) {
        this.uuid = randomUUID();

        this.logger = logplease.create(`job/${this.uuid}`);

        this.runtime = runtime;
        this.files = files.map((file, i) => ({
            name: file.name || `file${i}.code`,
            content: file.content,
            encoding: ['base64', 'hex', 'utf8'].includes(file.encoding)
                ? file.encoding
                : 'utf8',
        }));

        this.args = args;
        this.stdin = stdin;
        // Add a trailing newline if it doesn't exist
        if (this.stdin.slice(-1) !== '\n') {
            this.stdin += '\n';
        }

        this.timeouts = timeouts;
        this.cpu_times = cpu_times;
        this.memory_limits = memory_limits;

        this.state = job_states.READY;
        this.#dirty_boxes = [];
        this.#slot_id = null;
        this.#cleanup_started = false;
    }

    async #create_isolate_box() {
        const box_id = get_next_box_id();
        const metadata_file_path = `/tmp/${box_id}-metadata.txt`;
        const init_args = ['--init', '--cg', `-b${box_id}`];
        let result;
        try {
            result = await exec_file(ISOLATE_PATH, init_args);
        } catch (error) {
            throw new Error(
                `Failed to run isolate --init: ${error.message}\nstdout: ${error.stdout ?? ''}\nstderr: ${error.stderr ?? ''}`,
            );
        }
        if (result.stdout === '') {
            throw new Error('Received empty stdout from isolate --init');
        }

        const box = {
            id: box_id,
            metadata_file_path,
            dir: `${result.stdout.trim()}/box`,
            storage_attached: false,
        };
        this.#dirty_boxes.push(box);
        if (sandbox_storage.enabled) {
            await sandbox_storage.attach(this.#slot_id, box.id);
            box.storage_attached = true;
        }
        return box;
    }

    async #detach_storage(box) {
        if (!box.storage_attached) return;
        await sandbox_storage.detach(this.#slot_id, box.id);
        box.storage_attached = false;
    }

    async prime() {
        if (this.#slot_id !== null) {
            throw new Error('Job already has a sandbox slot');
        }
        this.logger.info(`Awaiting job slot`);
        this.#slot_id = await sandbox_pool.acquire();
        this.logger.info(`Priming job`);
        this.logger.debug('Running isolate --init');
        const box = await this.#create_isolate_box();

        this.logger.debug(`Creating submission files in Isolate box`);
        const submission_dir = path.join(box.dir, 'submission');
        await fs.mkdir(submission_dir);
        for (const file of this.files) {
            const file_path = path.join(submission_dir, file.name);
            const rel = path.relative(submission_dir, file_path);

            if (rel.startsWith('..'))
                throw Error(
                    `File path "${file.name}" tries to escape parent directory: ${rel}`,
                );

            const file_content = Buffer.from(file.content, file.encoding);

            await fs.mkdir(path.dirname(file_path), {
                recursive: true,
                mode: 0o700,
            });
            await fs.writeFile(file_path, file_content);
        }

        this.state = job_states.PRIMED;

        this.logger.debug('Primed job');
        return box;
    }

    async safe_call(
        box,
        file,
        args,
        timeout,
        cpu_time,
        memory_limit,
        event_bus = null,
    ) {
        let stdout = '';
        let stderr = '';
        let output = '';
        let memory = null;
        let code = null;
        let signal = null;
        let message = null;
        let status = null;
        let cpu_time_stat = null;
        let wall_time_stat = null;

        const proc = cp.spawn(
            ISOLATE_PATH,
            [
                '--run',
                `-b${box.id}`,
                `--meta=${box.metadata_file_path}`,
                '--cg',
                '-s',
                '-c',
                '/box/submission',
                '-E',
                'HOME=/tmp',
                ...this.runtime.env_vars.flatMap(v => ['-E', v]),
                '-E',
                `PISTON_LANGUAGE=${this.runtime.language}`,
                `--dir=${this.runtime.pkgdir}`,
                `--dir=/etc:noexec`,
                ...(sandbox_storage.enabled
                    ? ['--dir=/tmp=tmpfs:fs:rw:noexec']
                    : []),
                `--processes=${this.runtime.max_process_count}`,
                `--open-files=${this.runtime.max_open_files}`,
                `--fsize=${Math.floor(this.runtime.max_file_size / 1000)}`,
                `--wall-time=${timeout / 1000}`,
                `--time=${cpu_time / 1000}`,
                `--extra-time=0`,
                ...(memory_limit >= 0
                    ? [`--cg-mem=${Math.floor(memory_limit / 1000)}`]
                    : []),
                ...(config.disable_networking ? [] : ['--share-net']),
                '--',
                '/bin/bash',
                path.join(this.runtime.pkgdir, file),
                ...args,
            ],
            {
                stdio: 'pipe',
            },
        );

        if (event_bus === null) {
            proc.stdin.write(this.stdin);
            proc.stdin.end();
            proc.stdin.destroy();
        } else {
            event_bus.on('stdin', data => {
                proc.stdin.write(data);
            });

            event_bus.on('kill', signal => {
                proc.kill(signal);
            });
        }

        proc.stderr.on('data', async data => {
            if (event_bus !== null) {
                event_bus.emit('stderr', data);
            } else if (
                stderr.length + data.length >
                this.runtime.output_max_size
            ) {
                message = 'stderr length exceeded';
                status = 'EL';
                this.logger.info(message);
                try {
                    process.kill(proc.pid, 'SIGABRT');
                } catch (e) {
                    // Could already be dead and just needs to be waited on
                    this.logger.debug(
                        `Got error while SIGABRTing process ${proc}:`,
                        e,
                    );
                }
            } else {
                stderr += data;
                output += data;
            }
        });

        proc.stdout.on('data', async data => {
            if (event_bus !== null) {
                event_bus.emit('stdout', data);
            } else if (
                stdout.length + data.length >
                this.runtime.output_max_size
            ) {
                message = 'stdout length exceeded';
                status = 'OL';
                this.logger.info(message);
                try {
                    process.kill(proc.pid, 'SIGABRT');
                } catch (e) {
                    // Could already be dead and just needs to be waited on
                    this.logger.debug(
                        `Got error while SIGABRTing process ${proc}:`,
                        e,
                    );
                }
            } else {
                stdout += data;
                output += data;
            }
        });

        const data = await new Promise((res, rej) => {
            proc.on('exit', (_, signal) => {
                res({
                    signal,
                });
            });

            proc.on('error', err => {
                rej({
                    error: err,
                });
            });
        });

        try {
            const metadata_str = (
                await fs.readFile(box.metadata_file_path)
            ).toString();
            const metadata_lines = metadata_str.split('\n');
            for (const line of metadata_lines) {
                if (!line) continue;

                const [key, value] = line.split(':');
                if (key === undefined || value === undefined) {
                    throw new Error(
                        `Failed to parse metadata file, received: ${line}`,
                    );
                }
                switch (key) {
                    case 'cg-mem':
                        memory = Number.parseInt(value, 10) * 1000;
                        break;
                    case 'exitcode':
                        code = Number.parseInt(value, 10);
                        break;
                    case 'exitsig':
                        signal =
                            globals.SIGNALS[Number.parseInt(value, 10)] ?? null;
                        break;
                    case 'message':
                        message = message || value;
                        break;
                    case 'status':
                        status = status || value;
                        break;
                    case 'time':
                        cpu_time_stat = Number.parseFloat(value) * 1000;
                        break;
                    case 'time-wall':
                        wall_time_stat = Number.parseFloat(value) * 1000;
                        break;
                    default:
                        break;
                }
            }
        } catch (e) {
            throw new Error(
                `Error reading metadata file: ${box.metadata_file_path}\nError: ${e.message}\nIsolate run stdout: ${stdout}\nIsolate run stderr: ${stderr}`,
            );
        }

        return {
            ...data,
            stdout,
            stderr,
            code,
            signal: ['TO', 'OL', 'EL'].includes(status) ? 'SIGKILL' : signal,
            output,
            memory,
            message,
            status,
            cpu_time: cpu_time_stat,
            wall_time: wall_time_stat,
        };
    }

    async execute(box, event_bus = null) {
        if (this.state !== job_states.PRIMED) {
            throw new Error(
                'Job must be in primed state, current state: ' +
                    this.state.toString(),
            );
        }

        this.logger.info(`Executing job runtime=${this.runtime.toString()}`);

        const code_files =
            (this.runtime.language === 'file' && this.files) ||
            this.files.filter(file => file.encoding == 'utf8');

        this.logger.debug('Compiling');

        let compile;
        let compile_errored = false;
        const { emit_event_bus_result, emit_event_bus_stage } =
            event_bus === null
                ? {
                      emit_event_bus_result: () => {},
                      emit_event_bus_stage: () => {},
                  }
                : {
                      emit_event_bus_result: (stage, result) => {
                          const { error, code, signal } = result;
                          event_bus.emit('exit', stage, {
                              error,
                              code,
                              signal,
                          });
                      },
                      emit_event_bus_stage: stage => {
                          event_bus.emit('stage', stage);
                      },
                  };

        if (this.runtime.compiled) {
            this.logger.debug('Compiling');
            emit_event_bus_stage('compile');
            compile = await this.safe_call(
                box,
                'compile',
                code_files.map(x => x.name),
                this.timeouts.compile,
                this.cpu_times.compile,
                this.memory_limits.compile,
                event_bus,
            );
            emit_event_bus_result('compile', compile);
            compile_errored = compile.code !== 0;
            if (!compile_errored) {
                const old_box_dir = box.dir;
                if (sandbox_storage.enabled) {
                    await this.#detach_storage(box);
                }
                box = await this.#create_isolate_box();
                if (!sandbox_storage.enabled) {
                    await fs.rename(
                        path.join(old_box_dir, 'submission'),
                        path.join(box.dir, 'submission'),
                    );
                }
            }
        }

        let run;
        if (!compile_errored) {
            this.logger.debug('Running');
            emit_event_bus_stage('run');
            run = await this.safe_call(
                box,
                'run',
                [code_files[0].name, ...this.args],
                this.timeouts.run,
                this.cpu_times.run,
                this.memory_limits.run,
                event_bus,
            );
            emit_event_bus_result('run', run);
        }

        this.state = job_states.EXECUTED;

        return {
            compile,
            run,
            language: this.runtime.language,
            version: this.runtime.version.raw,
        };
    }

    async cleanup() {
        if (this.#cleanup_started) return;
        this.#cleanup_started = true;
        this.logger.info(`Cleaning up job`);

        if (this.#slot_id === null) {
            return;
        }

        try {
            for (const box of this.#dirty_boxes) {
                await this.#detach_storage(box);
            }

            for (const box of this.#dirty_boxes) {
                try {
                    await exec_file(ISOLATE_PATH, [
                        '--cleanup',
                        '--cg',
                        `-b${box.id}`,
                    ]);
                } catch (error) {
                    const cleanup_error = new Error(
                        `Failed to run isolate --cleanup on box #${box.id}: ${error.message}\nstdout: ${error.stdout ?? ''}\nstderr: ${error.stderr ?? ''}`,
                    );
                    if (sandbox_storage.enabled) throw cleanup_error;
                    this.logger.error(cleanup_error.message);
                }
            }

            for (const box of this.#dirty_boxes) {
                try {
                    await fs.rm(box.metadata_file_path);
                } catch (error) {
                    if (error.code === 'ENOENT') continue;
                    if (sandbox_storage.enabled) throw error;
                    this.logger.error(
                        `Failed to remove metadata for box #${box.id}: ${error.message}`,
                    );
                }
            }

            if (sandbox_storage.enabled) {
                await sandbox_storage.reset(this.#slot_id);
            }

            sandbox_pool.release(this.#slot_id);
            this.#slot_id = null;
        } catch (error) {
            if (sandbox_storage.enabled) {
                this.logger.error(
                    `Sandbox slot ${this.#slot_id} is quarantined after cleanup failed: ${error.message}`,
                );
                try {
                    await sandbox_storage.quarantine(
                        this.#slot_id,
                        error.message,
                    );
                } catch (_) {
                    // The supervisor may already be stopping after a failed storage operation.
                }
            } else {
                this.logger.error(`Job cleanup failed: ${error.message}`);
            }
            throw error;
        }
    }
}

module.exports = {
    Job,
};
