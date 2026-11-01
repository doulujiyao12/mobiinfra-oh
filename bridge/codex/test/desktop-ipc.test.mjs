import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { DesktopIpc, desktopEndpoint } from '../desktop-ipc.mjs';

function fixture(t) {
  const socket = new EventEmitter(); socket.destroyed = false; const sent = [];
  const frame = value => { const bytes = Buffer.from(JSON.stringify(value)); const header = Buffer.alloc(4); header.writeUInt32LE(bytes.length); return Buffer.concat([header, bytes]); };
  socket.push = value => { const bytes = frame(value); for (let index = 0; index < bytes.length; index += 3) socket.emit('data', bytes.subarray(index, index + 3)); };
  socket.destroy = error => { if (socket.destroyed) return; socket.destroyed = true; if (error) socket.emit('error', error); socket.emit('close'); };
  socket.write = bytes => {
    const message = JSON.parse(bytes.subarray(4).toString('utf8')); sent.push(message);
    if (message.type !== 'request') return;
    queueMicrotask(() => socket.push({ type: 'response', requestId: message.requestId, resultType: 'success', method: message.method,
      handledByClientId: 'owner', result: message.method === 'initialize' ? { clientId: 'clawmate-test' } : {} }));
  };
  const ipc = new DesktopIpc({ endpoint: 'fixture-only', connect: () => { queueMicrotask(() => socket.emit('connect')); return socket; } });
  t.after(() => ipc.close()); return { ipc, socket, sent, frame };
}
test('coordination uses little-endian frames, a truthful client identity and pinned method versions', async t => {
  const f = fixture(t); assert.equal(await f.ipc.owner('authorized-thread'), 'owner');
  assert.equal(f.sent[0].params.clientType, 'clawmate'); assert.equal(f.sent[0].version, 0);
  assert.equal(f.sent[1].method, 'thread-owner-discovery'); assert.equal(f.sent[1].version, 1);
  assert.equal(f.sent[1].params.hostId, 'local');
  f.ipc.follow('authorized-thread', 'owner', true);
  assert.deepEqual(f.sent.at(-1).targetClientIds, ['owner']);
  assert.equal(f.sent.at(-1).version, 1);
  for (const method of ['account/logout', 'command/exec', 'constructor', '__proto__']) await assert.rejects(f.ipc.request(method, {}), /不支持/);
  assert.equal(desktopEndpoint({}, 'win32'), '\\\\.\\pipe\\codex-ipc');
});
test('does not claim ownership or handle arbitrary incoming requests and only delivers addressed broadcasts', async t => {
  const f = fixture(t); await f.ipc.connect(); const received = [];
  f.ipc.on('broadcast', value => received.push(value));
  f.socket.push({ type: 'client-discovery-request', requestId: 'query' }); assert.equal(f.sent.at(-1).response.canHandle, false);
  f.socket.push({ type: 'request', requestId: 'unsafe', method: 'command/exec' }); assert.equal(f.sent.at(-1).resultType, 'error');
  f.socket.push({ type: 'broadcast', method: 'thread-stream-state-changed', targetClientIds: ['other'], params: {} });
  f.socket.push({ type: 'broadcast', method: 'account-token-changed', params: {} });
  assert.equal(received.length, 0);
  f.socket.push({ type: 'broadcast', method: 'thread-stream-state-changed', targetClientIds: [f.ipc.clientId], params: {} });
  assert.equal(received.length, 1);
});
test('invalid frames and disconnects reject pending calls; never retry an uncertain mutation', async t => {
  const f = fixture(t); await f.ipc.connect(); f.socket.write = bytes => { f.sent.push(JSON.parse(bytes.subarray(4))); };
  const operation = f.ipc.request('thread-follower-start-turn', { conversationId: 'thread' }, 'owner');
  await Promise.resolve(); const header = Buffer.alloc(4); header.writeUInt32LE(17 * 1024 * 1024); f.socket.emit('data', header);
  await assert.rejects(operation, error => error.outcomeUnknown === true);
  assert.equal(f.sent.filter(value => value.method === 'thread-follower-start-turn').length, 1);
});
test('a response from a different owner is not accepted', async t => {
  const f = fixture(t); await f.ipc.connect();
  await assert.rejects(f.ipc.request('thread-follower-interrupt-turn', { conversationId: 'thread' }, 'changed-owner'), /持有者已改变/);
});

test('a late close from the previous socket cannot invalidate a reconnected client', async t => {
  const sockets = [];
  const ipc = new DesktopIpc({ endpoint: 'fixture-only', connect: () => {
    const socket = new EventEmitter(); socket.destroyed = false;
    socket.destroy = () => { socket.destroyed = true; };
    socket.write = bytes => {
      const message = JSON.parse(bytes.subarray(4));
      queueMicrotask(() => {
        const payload = Buffer.from(JSON.stringify({ type: 'response', requestId: message.requestId,
          resultType: 'success', method: message.method, handledByClientId: 'owner', result: { clientId: 'client-' + sockets.indexOf(socket) } }));
        const header = Buffer.alloc(4); header.writeUInt32LE(payload.length); socket.emit('data', Buffer.concat([header, payload]));
      });
    };
    sockets.push(socket); queueMicrotask(() => socket.emit('connect')); return socket;
  } });
  t.after(() => ipc.close());
  await ipc.connect(); sockets[0].emit('error', new Error('temporary disconnect'));
  await ipc.connect(); assert.equal(ipc.clientId, 'client-1');
  sockets[0].emit('close'); assert.equal(ipc.clientId, 'client-1');
  assert.equal(await ipc.owner('thread'), 'owner');
});

test('closing before connect promptly rejects initialization', async t => {
  const socket = new EventEmitter(); socket.destroyed = false;
  socket.destroy = () => { socket.destroyed = true; socket.emit('close'); };
  const ipc = new DesktopIpc({ endpoint: 'fixture-only', connect: () => socket }); t.after(() => ipc.close());
  const connecting = ipc.connect(); ipc.close();
  await assert.rejects(connecting, /握手前关闭/);
});
