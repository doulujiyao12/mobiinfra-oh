import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { ReadCoordinator, readContext } from '../read-coordinator.mjs';
import { CodexRpc } from '../rpc.mjs';
import { TaskSync } from '../task-sync.mjs';

test('reads coalesce, time out, release their budget, and isolate independent mutations', async () => {
  const reads = new ReadCoordinator({ timeout: 50, cooldown: 10, limit: 1 });
  let invoked = 0; let signal;
  const first = reads.run('one', async () => {
    invoked++; signal = readContext.getStore().signal;
    await new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
  });
  assert.equal(reads.run('one', () => { throw new Error('duplicate'); }), first);
  assert.equal(readContext.getStore(), undefined, 'a mutation outside run has no read cancellation context');
  await assert.rejects(reads.run('two', () => 2), error => error.status === 429);
  await assert.rejects(first, error => error.status === 504);
  assert.equal(signal.aborted, true); assert.equal(invoked, 1);
  await assert.rejects(reads.run('one', () => 1), error => error.status === 504);
  await delay(30);
  assert.equal(await reads.run('one', () => 42), 42); assert.equal(reads.entries.size, 0);
});

test('read timeout cancels one stdio pending request without killing or cancelling a turn', async t => {
  const program = `require('node:readline').createInterface({input:process.stdin}).on('line',l=>{
    const m=JSON.parse(l); if(m.method==='thread/read') return;
    setTimeout(()=>console.log(JSON.stringify({id:m.id,result:{ok:true}})),30);
  });`;
  const rpc = new CodexRpc(process.execPath, ['-e', program]); t.after(() => rpc.close());
  // Warm the fake subprocess before testing a short deterministic read budget.
  assert.equal((await rpc.request('initialize')).ok, true);
  const reads = new ReadCoordinator({ timeout: 50, cooldown: 1 });
  const reading = reads.run('read', () => rpc.request('thread/read'));
  const mutation = rpc.request('turn/start');
  await assert.rejects(reading, error => error.status === 504);
  assert.equal((await mutation).ok, true);
  assert.equal(rpc.pending.size, 0); assert.equal(rpc.closed, false);
  assert.equal((await rpc.request('thread/list')).ok, true);
});

const task = (revision, items) => ({ id: 'session', revision, items, approvals: [], artifacts: [], status: 'running' });
test('task deltas append, correct, remove and reorder rows and keep exact turn metadata', () => {
  const sync = new TaskSync();
  const first = task(1, [{ id: 'a', turnId: 't1', kind: 'assistant', text: 'hello' }, { id: 'b', kind: 'tool', text: 'old' }]);
  assert.deepEqual(sync.envelope(first, null, true), { task: first });
  first.items[0].text = 'mutated after send';
  const second = task(2, [{ id: 'c', turnId: 't2', kind: 'user', text: 'new' },
    { id: 'a', turnId: 't1', kind: 'assistant', text: 'hello world' }]);
  const delta = sync.envelope(second, '1', true).taskDelta;
  assert.deepEqual(delta.itemOrder, ['c', 'a']);
  assert.deepEqual(delta.items.find(item => item.id === 'a'), { id: 'a', turnId: 't1', kind: 'assistant', text: ' world', append: true });
  assert.equal(delta.baseRevision, 1); assert.deepEqual(delta.task.items, []);
  const third = task(3, [{ id: 'a', turnId: 't1', kind: 'assistant', text: 'corrected' }]);
  assert.equal(sync.envelope(third, '2', true).taskDelta.items[0].append, false);
  assert.deepEqual(sync.envelope(third, '2', false), { task: third }, 'legacy clients receive a full snapshot');
  assert.deepEqual(sync.envelope(third, '999', true), { task: third }, 'missing bases recover with a full snapshot');
});

test('delta cache has bounded versions and memory and substantially reduces streamed history bytes', () => {
  const sync = new TaskSync({ versions: 2, maxBytes: 1200000 });
  const items = Array.from({ length: 40 }, (_, i) => ({ id: String(i), kind: 'assistant', text: '历史'.repeat(2000) }));
  const first = task(1, items); sync.envelope(first, '', true);
  const second = task(2, items.map((item, i) => i === 39 ? { ...item, text: item.text + '继续' } : item));
  const wire = sync.envelope(second, '1', true);
  assert.ok(Buffer.byteLength(JSON.stringify(wire)) < Buffer.byteLength(JSON.stringify(second)) / 20);
  sync.envelope(task(3, []), '2', true);
  assert.equal(sync.entries.get('session').length, 2);
  assert.ok(sync.envelope(task(4, []), '1', true).task);
  sync.envelope({ ...task(1, items), id: 'other' }, '', true);
  assert.ok(sync.bytes <= sync.maxBytes);
  const tiny = new TaskSync({ maxBytes: 1 }); tiny.envelope(first, '', true);
  assert.equal(tiny.entries.size, 0); assert.equal(tiny.bytes, 0);
});
