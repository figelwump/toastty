import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { createInterface } from 'node:readline';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

test('socket framing preserves UTF-8 split across data chunks', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'toastty-mcp-frame-'));
  const socket = join(directory, 'test.sock');
  const server = createServer(client => {
    client.once('data', () => {
      const response = Buffer.from(JSON.stringify({
        ok: true, result: { label: 'café' },
      }) + '\n');
      const split = response.indexOf(Buffer.from('é')) + 1;
      client.write(response.subarray(0, split));
      setTimeout(() => client.write(response.subarray(split)), 10);
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(socket, resolve);
  });
  const adapter = spawn('node', [fileURLToPath(new URL('./server.mjs', import.meta.url))], {
    env: { ...process.env, TOASTTY_SOCKET_PATH: socket },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  try {
    const lines = createInterface({ input: adapter.stdout });
    const response = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('MCP reply timed out')), 5000);
      lines.once('line', line => { clearTimeout(timeout); resolve(JSON.parse(line)); });
      adapter.once('exit', code => { clearTimeout(timeout); reject(new Error(`MCP exited ${code}`)); });
    });
    adapter.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: 'toastty_list_sessions', arguments: {} } }) + '\n');
    const reply = await response;
    assert.equal(reply.result.structuredContent.label, 'café');
  } finally {
    adapter.kill();
    await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  }
});

test('malformed JSON-RPC value does not terminate the adapter', async () => {
  const adapter = spawn('node', [fileURLToPath(new URL('./server.mjs', import.meta.url))], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  try {
    const lines = createInterface({ input: adapter.stdout });
    const responses = new Promise((resolve, reject) => {
      const output = [];
      const timeout = setTimeout(() => reject(new Error('MCP replies timed out')), 5000);
      lines.on('line', line => {
        output.push(JSON.parse(line));
        if (output.length === 2) { clearTimeout(timeout); resolve(output); }
      });
      adapter.once('exit', code => { clearTimeout(timeout); reject(new Error(`MCP exited ${code}`)); });
    });
    adapter.stdin.write('null\n');
    adapter.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'ping' }) + '\n');
    const [invalid, ping] = await responses;
    assert.equal(invalid.error.code, -32600);
    assert.equal(ping.id, 2);
    assert.deepEqual(ping.result, {});
  } finally {
    adapter.kill();
  }
});
