import assert from 'node:assert/strict';

const baseUrl = process.argv[2];
const mode = process.argv[3] || 'full';

if (!baseUrl) {
    throw new Error('Usage: node tests/acceptance-arm64.mjs <base-url> [mode]');
}

async function request(path, options = {}) {
    const response = await fetch(`${baseUrl}${path}`, options);
    const text = await response.text();
    const body = text ? JSON.parse(text) : null;
    return { response, body };
}

async function execute(content, overrides = {}) {
    const { response, body } = await request('/api/v2/execute', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
            language: 'python',
            version: '3.12.0',
            files: [{ name: 'main.py', content }],
            ...overrides,
        }),
    });

    assert.equal(response.status, 200, JSON.stringify(body));
    return body;
}

async function assertRuntimeAvailable() {
    const packages = await request('/api/v2/packages');
    assert.equal(packages.response.status, 200);
    const pythonPackage = packages.body.find(
        entry =>
            entry.language === 'python' && entry.language_version === '3.12.0'
    );
    assert.deepEqual(pythonPackage, {
        language: 'python',
        language_version: '3.12.0',
        installed: true,
    });

    const runtimes = await request('/api/v2/runtimes');
    assert.equal(runtimes.response.status, 200);
    assert.equal(runtimes.body.length, 1);
    assert.equal(runtimes.body[0].language, 'python');
    assert.equal(runtimes.body[0].version, '3.12.0');
}

async function assertWebSocket() {
    const url = new URL('/api/v2/connect', baseUrl);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';

    await new Promise((resolve, reject) => {
        const messages = [];
        const socket = new WebSocket(url);
        const timer = setTimeout(
            () =>
                reject(
                    new Error(
                        `WebSocket timed out: ${JSON.stringify(messages)}`
                    )
                ),
            10000
        );

        socket.addEventListener('open', () => {
            socket.send(
                JSON.stringify({
                    type: 'init',
                    language: 'python',
                    version: '3.12.0',
                    files: [
                        {
                            name: 'main.py',
                            content: "print('websocket-ok')",
                        },
                    ],
                })
            );
        });

        socket.addEventListener('message', event => {
            messages.push(JSON.parse(event.data));
        });

        socket.addEventListener('error', () => {
            clearTimeout(timer);
            reject(new Error('WebSocket connection failed'));
        });

        socket.addEventListener('close', event => {
            clearTimeout(timer);
            try {
                assert.equal(event.code, 4999);
                assert.equal(event.reason, 'Job Completed');
                assert(
                    messages.some(
                        message =>
                            message.type === 'runtime' &&
                            message.language === 'python' &&
                            message.version === '3.12.0'
                    )
                );
                assert(
                    messages.some(
                        message =>
                            message.type === 'stage' && message.stage === 'run'
                    )
                );
                assert(
                    messages.some(
                        message =>
                            message.type === 'data' &&
                            message.stream === 'stdout' &&
                            message.data === 'websocket-ok\n'
                    )
                );
                assert(
                    messages.some(
                        message =>
                            message.type === 'exit' &&
                            message.stage === 'run' &&
                            message.code === 0
                    )
                );
                resolve();
            } catch (error) {
                reject(error);
            }
        });
    });
}

async function fullAcceptance() {
    const root = await request('/');
    assert.equal(root.response.status, 200);
    assert.deepEqual(root.body, { message: 'Piston v3.1.1' });

    await assertRuntimeAvailable();

    const unsupported = await request('/api/v2/execute', {
        method: 'POST',
        body: '{}',
    });
    assert.equal(unsupported.response.status, 415);
    assert.equal(
        unsupported.body.message,
        'requests must be of type application/json'
    );

    const unknown = await request('/api/v2/execute', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
            language: 'missing',
            version: '*',
            files: [{ content: 'x' }],
        }),
    });
    assert.equal(unknown.response.status, 400);
    assert.equal(unknown.body.message, 'missing-* runtime is unknown');

    const basic = await execute(
        "import platform\nprint('hello-arm64')\nprint(platform.machine())"
    );
    assert.equal(basic.run.code, 0);
    assert.equal(basic.run.stdout, 'hello-arm64\naarch64\n');

    const alias = await request('/api/v2/execute', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
            language: 'py3',
            version: '*',
            files: [{ name: 'main.py', content: "print('alias-ok')" }],
        }),
    });
    assert.equal(alias.response.status, 200);
    assert.equal(alias.body.language, 'python');
    assert.equal(alias.body.run.stdout, 'alias-ok\n');

    const scientific = await execute(`
import networkx as nx
import numpy as np
import scipy
from scipy import linalg

A = np.array([[3.0, 1.0], [1.0, 2.0]])
b = np.array([9.0, 8.0])
x = linalg.solve(A, b)
graph = nx.Graph()
graph.add_weighted_edges_from([
    ('a', 'b', 2),
    ('b', 'c', 3),
    ('a', 'c', 10),
])

print(np.__version__, scipy.__version__, nx.__version__)
print(
    np.allclose(A @ x, b),
    nx.shortest_path_length(graph, 'a', 'c', weight='weight'),
)
`);
    assert.equal(scientific.run.code, 0);
    assert.equal(scientific.run.stdout, '2.5.4 1.18.1 3.7\nTrue 5\n');

    const wallTimeout = await execute('while True: pass', {
        run_timeout: 200,
        run_cpu_time: 1000,
    });
    assert.equal(wallTimeout.run.status, 'TO');
    assert.equal(wallTimeout.run.signal, 'SIGKILL');
    assert.match(wallTimeout.run.message, /wall clock/);

    const cpuTimeout = await execute('while True: pass', {
        run_timeout: 1000,
        run_cpu_time: 100,
    });
    assert.equal(cpuTimeout.run.status, 'TO');
    assert.equal(cpuTimeout.run.signal, 'SIGKILL');
    assert.match(cpuTimeout.run.message, /Time limit exceeded/);
    assert(cpuTimeout.run.cpu_time <= 250, JSON.stringify(cpuTimeout.run));

    const memory = await execute(
        'value = bytearray(256 * 1024 * 1024)\nprint(len(value))',
        { run_memory_limit: 32 * 1024 * 1024 }
    );
    assert.notEqual(memory.run.code, 0);
    assert(memory.run.memory <= 48 * 1024 * 1024, JSON.stringify(memory.run));

    const output = await execute("print('x' * 5000)");
    assert.equal(output.run.status, 'OL');
    assert.equal(output.run.signal, 'SIGKILL');

    const processes = await execute(`
import os
import time

children = []
for _ in range(200):
    try:
        pid = os.fork()
    except OSError as error:
        print('blocked', len(children), error.errno)
        break
    if pid == 0:
        time.sleep(1)
        os._exit(0)
    children.append(pid)

for pid in children:
    os.waitpid(pid, 0)
`);
    assert.equal(processes.run.code, 0);
    const processMatch = processes.run.stdout.match(/blocked (\d+) (\d+)/);
    assert(processMatch, JSON.stringify(processes.run));
    assert(Number(processMatch[1]) < 200, JSON.stringify(processes.run));

    const fileSize = await execute(`
with open('large.bin', 'wb') as file:
    file.write(b'x' * 20_000_000)
print('unexpected')
`);
    assert.notEqual(fileSize.run.code, 0);
    assert.match(fileSize.run.stderr, /File too large/);

    const network = await execute(`
import urllib.request

try:
    urllib.request.urlopen('http://repo:8000/index', timeout=1)
    print('NETWORK_ALLOWED')
except Exception as error:
    print('NETWORK_BLOCKED', type(error).__name__)
`);
    assert.equal(network.run.code, 0);
    assert.match(network.run.stdout, /NETWORK_BLOCKED/);
    assert.doesNotMatch(network.run.stdout, /NETWORK_ALLOWED/);

    for (let attempt = 0; attempt < 2; attempt += 1) {
        const fileIsolation = await execute(`
from pathlib import Path

path = Path('/tmp/piston-persistence-probe')
print('existed', path.exists())
path.write_text('probe')
`);
        assert.equal(fileIsolation.run.code, 0);
        assert.equal(fileIsolation.run.stdout, 'existed False\n');
    }

    await assertWebSocket();
}

async function persistenceAcceptance() {
    await assertRuntimeAvailable();
    const result = await execute("print('persistence-ok')");
    assert.equal(result.run.code, 0);
    assert.equal(result.run.stdout, 'persistence-ok\n');
}

async function deletionAcceptance() {
    const packages = await request('/api/v2/packages');
    assert.equal(packages.response.status, 200);
    const pythonPackage = packages.body.find(
        entry =>
            entry.language === 'python' && entry.language_version === '3.12.0'
    );
    assert(pythonPackage, 'Python 3.12.0 is missing from the package index');
    assert.equal(pythonPackage.installed, false);

    const runtimes = await request('/api/v2/runtimes');
    assert.equal(runtimes.response.status, 200);
    assert.deepEqual(runtimes.body, []);
}

switch (mode) {
    case 'full':
        await fullAcceptance();
        break;
    case 'persistence':
        await persistenceAcceptance();
        break;
    case 'deleted':
        await deletionAcceptance();
        break;
    default:
        throw new Error(`Unknown acceptance mode: ${mode}`);
}

console.log(`ARM64 acceptance mode '${mode}' passed`);
