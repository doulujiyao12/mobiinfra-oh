import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createWavHeader, triggeredFileName } from '../../watch_entry/src/main/ets/core/Wav.ts';
import { createSyncHarness, waitFor } from './sync-harness.mjs';

function fixture(t) {
  const base = fileURLToPath(new URL('../../.codex-tmp/watch-tests/', import.meta.url));
  fs.mkdirSync(base, { recursive: true });
  const dir = fs.mkdtempSync(path.join(base, 'sync-'));
  fs.mkdirSync(path.join(dir, 'recordings'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}
function wav(dir, index = 1, timestamp = 1793520000000 + index * 10000) {
  const id = triggeredFileName(timestamp, index, 16000, 'speech');
  const data = Buffer.concat([Buffer.from(createWavHeader(6400, 16000)), Buffer.alloc(6400, index)]);
  fs.writeFileSync(path.join(dir, 'recordings', id), data);
  return id;
}
function store(h, dir) { return new (h.load('sync/RecordingSyncStore.ets').RecordingSyncStore)(dir); }
function ack(offer) {
  return { recordingId: offer.recording.id, transferId: offer.transferId, sha256: offer.sha256, bytes: offer.recording.bytes };
}

test('catalog pagination survives insertion/deletion and excludes partial or unsafe files', async t => {
  const dir = fixture(t); const h = createSyncHarness(dir); t.after(h.dispose);
  const ids = [1, 2, 3, 4].map(n => wav(dir, n));
  fs.writeFileSync(path.join(dir, 'recordings', ids[3] + '.part'), Buffer.alloc(100));
  const s = store(h, dir);
  const page = await s.list('phone', '', 2);
  assert.deepEqual(Array.from(page.recordings, r => r.id), [ids[3], ids[2]]);
  wav(dir, 5); fs.unlinkSync(path.join(dir, 'recordings', ids[2]));
  const rest = await s.list('phone', page.nextCursor, 2);
  assert.deepEqual(Array.from(rest.recordings, r => r.id), [ids[1], ids[0]]);
  await assert.rejects(s.prepare('phone', '../private.txt'), /已完成/);
  await assert.rejects(s.prepare('phone', ids[3] + '.part'), /已完成/);
});

test('SHA256 offers and durable ACKs survive restart; duplicates and peer isolation are safe', async t => {
  const dir = fixture(t); const id = wav(dir);
  const h = createSyncHarness(dir); t.after(h.dispose); h.state.maxWrite = 17;
  const s = store(h, dir); const source = s.sourceId();
  const offer = await s.prepare('phoneA', id);
  assert.equal(offer.sha256, crypto.createHash('sha256').update(fs.readFileSync(offer.path)).digest('hex'));
  assert.equal((await s.prepare('phoneA', id)).transferId, offer.transferId);
  await assert.rejects(s.confirm('phoneA', { ...ack(offer), bytes: offer.recording.bytes + 2 }), /不匹配/);
  await assert.rejects(s.confirm('phoneB', ack(offer)), /不匹配/);
  assert.equal((await s.confirmedIds('phoneA')).length, 0);
  const restarted = store(h, dir);
  assert.equal(restarted.sourceId(), source);
  await restarted.confirm('phoneA', ack(offer));
  await restarted.confirm('phoneA', ack(offer));
  assert.deepEqual(Array.from(await store(h, dir).confirmedIds('phoneA')), [id]);
  assert.equal((await restarted.confirmedIds('phoneB')).length, 0);
  assert.ok(fs.existsSync(offer.path), 'ACK never deletes watch audio');
});

test('failed journal replacement cannot claim synced, and corrupt journals are preserved', async t => {
  const dir = fixture(t); const id = wav(dir);
  const h = createSyncHarness(dir); t.after(h.dispose);
  const s = store(h, dir); const offer = await s.prepare('phone', id);
  h.state.failRename = true;
  await assert.rejects(s.confirm('phone', ack(offer)), /simulated/);
  assert.equal((await s.confirmedIds('phone')).length, 0);
  h.state.failRename = false;
  assert.equal((await store(h, dir).confirmedIds('phone')).length, 0);
  const journal = path.join(dir, 'recording-sync.v1.json');
  fs.writeFileSync(journal, '{broken');
  assert.throws(() => store(h, dir), /损坏/);
  assert.equal(fs.readFileSync(journal, 'utf8'), '{broken');
  assert.ok(fs.existsSync(path.join(dir, 'recordings', id)));
});

test('real controller + Worker + Wear Engine adapter complete list/file/verified ACK flow', async t => {
  const dir = fixture(t); const id = wav(dir);
  const h = createSyncHarness(dir); t.after(h.dispose);
  const controller = h.load('services/PhoneSyncController.ets').phoneSyncController;
  let view; controller.subscribe(state => { view = state; });
  controller.initialize({ filesDir: dir });
  t.after(() => controller.destroy());
  await waitFor(() => h.state.receivers.size === 1 && view.status === 'waiting');
  assert.equal(h.state.registrations[0].app.remoteApp.bundleName, 'com.coevomind.clawmate');
  assert.equal(h.state.registrations[0].app.remoteApp.fingerprint, '6917613102135452205');
  assert.equal((await h.request('LIST_RECORDINGS')).code, 'HELLO_REQUIRED');
  assert.equal((await h.request('HELLO')).type, 'HELLO_RESULT');
  const list = await h.request('LIST_RECORDINGS', { limit: 8 });
  assert.equal(list.recordings[0].id, id);
  assert.equal(JSON.stringify(list).includes(dir), false);
  const offer = await h.request('GET_RECORDING', { recordingId: id });
  assert.equal(JSON.stringify(offer).includes(dir), false);
  await h.request('READY_RECORDING', { transferId: offer.transferId });
  await waitFor(() => h.state.transfers.length === 1);
  const transfer = h.state.transfers[0];
  const fd = transfer.file.file.fd;
  assert.ok(h.handles.has(fd), 'descriptor remains open throughout SDK transfer');
  const phoneFile = path.join(dir, 'phone-received.wav');
  fs.copyFileSync(h.handles.get(fd).path, phoneFile);
  transfer.callback(undefined, { progress: 0 });
  transfer.callback(undefined, { progress: 100 });
  assert.ok(h.handles.has(fd), '100% is not SDK success');
  assert.equal(view.syncedIds.length, 0);
  transfer.callback(undefined, { code: 207 });
  await waitFor(() => view.status === 'awaiting_ack');
  assert.equal(h.handles.has(fd), false);
  assert.equal(view.syncedIds.length, 0, 'transport success alone must not mark synced');
  assert.equal(fs.statSync(phoneFile).size, offer.bytes);
  const digest = crypto.createHash('sha256').update(fs.readFileSync(phoneFile)).digest('hex');
  assert.equal(digest, offer.sha256);
  const reply = await h.request('ACK_RECORDING', { ...ack(offer), sha256: digest });
  assert.equal(reply.type, 'RECORDING_ACKED');
  assert.deepEqual(Array.from(view.syncedIds), [id]);
  assert.ok(fs.existsSync(path.join(dir, 'recordings', id)));
  assert.equal((await h.request('ACK_RECORDING', ack(offer))).type, 'RECORDING_ACKED');
});

test('disconnect during transfer preserves audio and allows idempotent retry after reconnect', async t => {
  const dir = fixture(t); const id = wav(dir);
  const h = createSyncHarness(dir); t.after(h.dispose);
  const controller = h.load('services/PhoneSyncController.ets').phoneSyncController;
  let view; controller.subscribe(state => { view = state; });
  controller.initialize({ filesDir: dir }); t.after(() => controller.destroy());
  await waitFor(() => h.state.receivers.size === 1);
  await h.request('HELLO');
  const offer = await h.request('GET_RECORDING', { recordingId: id });
  await h.request('READY_RECORDING', { transferId: offer.transferId });
  await waitFor(() => h.state.transfers.length === 1);
  const old = h.state.transfers[0];
  await controller.reconnect();
  assert.equal(h.handles.has(old.file.file.fd), false);
  assert.equal(view.syncedIds.length, 0);
  await h.request('HELLO');
  const retry = await h.request('GET_RECORDING', { recordingId: id });
  assert.equal(retry.transferId, offer.transferId);
  old.callback(undefined, { code: 207 }); // Stale SDK completion must not affect the new session.
  assert.equal(view.syncedIds.length, 0);
  await h.request('CANCEL_TRANSFER', { transferId: retry.transferId });
  assert.ok(fs.existsSync(path.join(dir, 'recordings', id)));
});

test('background task updates retain audio recording when file transfer ends', async t => {
  const h = createSyncHarness(fixture(t)); t.after(h.dispose);
  const bg = h.load('services/BackgroundTasks.ets').backgroundTasks;
  bg.initialize({});
  await bg.setMode('audioRecording', true);
  await bg.setMode('dataTransfer', true);
  await bg.setMode('dataTransfer', false);
  assert.deepEqual(h.state.background, [
    ['start', ['audioRecording']], ['update', ['audioRecording', 'dataTransfer']], ['update', ['audioRecording']]
  ]);
  await bg.setMode('audioRecording', false);
  assert.deepEqual(h.state.background.at(-1), ['stop', []]);
});

test('actual companion client validates/saves WAV and recovers a lost ACK reply without retransmitting', async t => {
  const dir = fixture(t); const id = wav(dir);
  const phoneDir = path.join(dir, 'phone'); fs.mkdirSync(phoneDir);
  const h = createSyncHarness(dir); t.after(h.dispose); h.state.autoTransfer = true;
  const controller = h.load('services/PhoneSyncController.ets').phoneSyncController;
  let view; controller.subscribe(state => { view = state; });
  controller.initialize({ filesDir: dir }); t.after(() => controller.destroy());
  await waitFor(() => h.state.receivers.size === 1);
  const phone = h.phoneClient({ filesDir: phoneDir }); t.after(() => phone.close());
  await phone.connect();
  assert.equal(h.state.phoneRegistrations[0].app.remoteApp.fingerprint, '6917613102135452205');
  const list = await phone.list();
  assert.equal(list.recordings[0].id, id);
  h.state.dropAckReplies = 1; h.state.fastRequestTimeout = 100;
  const saved = await phone.download(id);
  assert.ok(saved.path.startsWith(phoneDir));
  assert.deepEqual(fs.readFileSync(saved.path), fs.readFileSync(path.join(dir, 'recordings', id)));
  assert.deepEqual(Array.from(view.syncedIds), [id]);
  assert.equal(h.state.transfers.length, 1);
  assert.ok(h.state.messages.filter(m => m.type === 'RECORDING_ACKED').length >= 2);
  // Existing durable local copy is SHA256-checked and ACKed without sending WAV again.
  await phone.download(id);
  assert.equal(h.state.transfers.length, 1);
  // Simulate cleared phone app audio while watch still has its receipt. Must download again.
  fs.unlinkSync(saved.path);
  assert.equal((await phone.list()).recordings[0].synced, true);
  await phone.download(id);
  assert.equal(h.state.transfers.length, 2);
  assert.ok(fs.existsSync(saved.path));
});

test('corrupted file is never acknowledged; retry obtains a verified durable copy', async t => {
  const dir = fixture(t); const id = wav(dir);
  const phoneDir = path.join(dir, 'phone'); fs.mkdirSync(phoneDir);
  const h = createSyncHarness(dir); t.after(h.dispose);
  h.state.autoTransfer = true; h.state.corruptNextTransfer = true;
  const controller = h.load('services/PhoneSyncController.ets').phoneSyncController;
  let view; controller.subscribe(state => { view = state; });
  controller.initialize({ filesDir: dir }); t.after(() => controller.destroy());
  await waitFor(() => h.state.receivers.size === 1);
  const phone = h.phoneClient({ filesDir: phoneDir }); t.after(() => phone.close());
  await phone.connect();
  await assert.rejects(phone.download(id), /SHA256/);
  assert.equal(view.syncedIds.length, 0);
  assert.equal(h.state.messages.some(m => m.type === 'RECORDING_ACKED'), false);
  const saved = await phone.download(id);
  assert.equal(view.syncedIds.length, 1);
  assert.deepEqual(fs.readFileSync(saved.path), fs.readFileSync(path.join(dir, 'recordings', id)));
});

test('cancel while background permission is pending never starts a late native file send', async t => {
  const dir = fixture(t); const id = wav(dir);
  const h = createSyncHarness(dir); t.after(h.dispose); h.state.deferBackground = true;
  const controller = h.load('services/PhoneSyncController.ets').phoneSyncController;
  controller.initialize({ filesDir: dir }); t.after(() => controller.destroy());
  await waitFor(() => h.state.receivers.size === 1);
  await h.request('HELLO');
  const offer = await h.request('GET_RECORDING', { recordingId: id });
  await h.request('READY_RECORDING', { transferId: offer.transferId });
  await waitFor(() => h.state.releaseBackground !== undefined);
  const cancelled = h.request('CANCEL_TRANSFER', { transferId: offer.transferId });
  await new Promise(resolve => setTimeout(resolve, 10));
  h.state.releaseBackground();
  assert.equal((await cancelled).type, 'TRANSFER_CANCELLED');
  assert.equal(h.state.transfers.length, 0);
  assert.deepEqual(h.state.background.at(-1), ['stop', []]);
});

test('managed phone library paths remain deduplicated after moving a verified download', async t => {
  const dir = fixture(t); const id = wav(dir);
  const phoneDir = path.join(dir, 'phone'); fs.mkdirSync(phoneDir);
  const h = createSyncHarness(dir); t.after(h.dispose); h.state.autoTransfer = true;
  const controller = h.load('services/PhoneSyncController.ets').phoneSyncController;
  controller.initialize({ filesDir: dir }); t.after(() => controller.destroy());
  await waitFor(() => h.state.receivers.size === 1);
  const phone = h.phoneClient({ filesDir: phoneDir }); t.after(() => phone.close());
  await phone.connect();
  const saved = await phone.download(id);
  const managed = path.join(phoneDir, 'managed.wav'); fs.renameSync(saved.path, managed);
  const reused = await phone.download(id, managed);
  assert.equal(reused.path, managed); assert.equal(reused.sourceId, phone.identity());
  assert.equal(h.state.transfers.length, 1);
  const damaged = fs.readFileSync(managed); damaged[100] ^= 1; fs.writeFileSync(managed, damaged);
  const repaired = await phone.download(id, managed);
  assert.notEqual(repaired.path, managed); assert.equal(h.state.transfers.length, 2);
  assert.deepEqual(fs.readFileSync(repaired.path), fs.readFileSync(path.join(dir, 'recordings', id)));
});

test('closing a pending device discovery prevents late receiver registration', async t => {
  const dir = fixture(t); const phoneDir = path.join(dir, 'phone'); fs.mkdirSync(phoneDir);
  const h = createSyncHarness(dir); t.after(h.dispose); h.state.deferPhoneDevices = true;
  const phone = h.phoneClient({ filesDir: phoneDir });
  const connecting = phone.connect(); const rejected = assert.rejects(connecting, /取消|关闭/);
  await waitFor(() => h.state.releasePhoneDevices !== undefined);
  await phone.close(); h.state.releasePhoneDevices(); await rejected;
  assert.equal(h.state.phoneRegistrations.length, 0); assert.equal(h.state.phoneFileReceivers.size, 0);
  assert.equal(phone.identity(), '');
});
