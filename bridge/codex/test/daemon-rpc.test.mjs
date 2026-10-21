import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtempSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { WebSocketServer } from 'ws';
import { DaemonRpc } from '../daemon-rpc.mjs';
import { ReadCoordinator } from '../read-coordinator.mjs';

async function fixture(t, handler, options) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'cm-ws-'));
  const socket = process.platform === 'win32' ? '\\\\.\\pipe\\cm-ws-' + randomUUID() : path.join(directory, 'rpc.sock');
  const httpServer = http.createServer(); const server = new WebSocketServer({ server: httpServer, perMessageDeflate: false });
  server.on('connection', connection => connection.on('message', bytes => handler(connection, JSON.parse(bytes.toString()))));
  await new Promise(resolve => httpServer.listen(socket, resolve));
  const rpc = new DaemonRpc(socket, options);
  t.after(async () => { rpc.close(); for (const client of server.clients) client.terminate();
    await new Promise(resolve => server.close(resolve)); await new Promise(resolve => httpServer.close(resolve)); rmSync(directory, { recursive: true, force: true }); });
  return rpc;
}
test('Unix/pipe WebSocket initialization, notifications and server responses preserve RPC identity', async t => {
  const received = [];
  const rpc = await fixture(t, (socket, message) => {
    received.push(message);
    if (message.method === 'initialize') socket.send(JSON.stringify({ id: message.id, result: {} }));
    if (message.method === 'thread/read') {
      socket.send(JSON.stringify({ id: message.id, result: { thread: { id: 'one' } } }));
      socket.send(JSON.stringify({ id: 'approval-1', method: 'item/fileChange/requestApproval', params: { threadId: 'one' } }));
    }
  });
  const events = []; rpc.on('message', message => events.push(message)); await rpc.initialize();
  assert.equal((await rpc.request('thread/read', { threadId: 'one' })).thread.id, 'one');
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(events[0].id, 'approval-1'); rpc.send({ id: 'approval-1', result: { decision: 'decline' } });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(received[0].params.clientInfo.name, 'clawmate_harmony'); assert.equal(received[1].method, 'initialized');
  assert.deepEqual(received.at(-1), { id: 'approval-1', result: { decision: 'decline' } });
});
test('daemon RPC errors differ from uncertain turn timeout and no request is retried', async t => {
  let starts = 0;
  const rpc = await fixture(t, (socket, message) => {
    if (message.method === 'turn/start') { starts++; return; }
    socket.send(JSON.stringify({ id: message.id, error: { code: -32600, message: 'rejected' } }));
  }, { timeout: 70 });
  await assert.rejects(rpc.request('thread/read'), error => error.rpcCode === -32600 && !error.outcomeUnknown);
  await assert.rejects(rpc.request('turn/start'), error => error.outcomeUnknown === true);
  assert.equal(starts, 1); assert.equal(rpc.pending.size, 0);
});
test('disconnect marks a submitted turn uncertain and never sends daemon shutdown', async t => {
  const rpc = await fixture(t, (socket, message) => { if (message.method === 'turn/start') socket.terminate(); });
  await assert.rejects(rpc.request('turn/start'), error => error.outcomeUnknown === true);
  assert.equal(rpc.closed, true); assert.equal(rpc.pending.size, 0);
});

test('a timed-out daemon read releases its pending entry and leaves shared execution usable', async t => {
  const rpc = await fixture(t, (socket, message) => {
    if (message.method !== 'thread/read') socket.send(JSON.stringify({ id: message.id, result: { ok: true } }));
  });
  await rpc.opened;
  const reads = new ReadCoordinator({ timeout: 50, cooldown: 1 });
  await assert.rejects(reads.run('one', () => rpc.request('thread/read')), error => error.status === 504);
  assert.equal(rpc.pending.size, 0); assert.equal(rpc.closed, false);
  assert.equal((await rpc.request('turn/start')).ok, true);
});
