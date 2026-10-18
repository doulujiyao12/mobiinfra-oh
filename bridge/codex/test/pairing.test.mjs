import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { PairingManager } from '../pairing.mjs';

function fixture(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'clawmate-pair-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return { dir, manager: new PairingManager(dir) };
}
const options = { origin: 'https://192.168.1.10:8787', name: 'PC', caCertificate: 'public certificate' };
test('pairing exchanges a one-use expiring code for an independent device token', t => {
  const { manager, dir } = fixture(t);
  const bundle = manager.create(options);
  assert.equal(bundle.type, 'clawmate-codex-pairing');
  assert.ok(bundle.expiresAt > Date.now());
  assert.ok(!JSON.stringify(bundle).includes('token'));
  const result = manager.redeem({ code: bundle.code, deviceName: 'phone' });
  assert.ok(manager.authenticates(result.token));
  assert.equal(result.serverId, bundle.serverId);
  assert.throws(() => manager.redeem({ code: bundle.code, deviceName: 'phone' }), /expired/);
  assert.ok(!readFileSync(path.join(dir, 'devices.json'), 'utf8').includes(result.token));
  assert.ok(!readFileSync(path.join(dir, 'devices.json'), 'utf8').includes(bundle.code));
});
test('expired and superseded codes cannot pair and revocation survives restart', t => {
  const { manager, dir } = fixture(t);
  const first = manager.create(options); const second = manager.create(options);
  assert.throws(() => manager.redeem({ code: first.code, deviceName: 'phone' }), /expired/);
  manager.pending.expiresAt = Date.now() - 1;
  assert.throws(() => manager.redeem({ code: second.code, deviceName: 'phone' }), /expired/);
  const current = manager.create(options);
  const device = manager.redeem({ code: current.code, deviceName: 'phone' });
  const restarted = new PairingManager(dir);
  assert.ok(restarted.authenticates(device.token));
  restarted.revoke(device.deviceId);
  assert.equal(new PairingManager(dir).authenticates(device.token), false);
});
test('pairing rejects cleartext origins, invalid names and invalid tokens', t => {
  const { manager } = fixture(t);
  assert.throws(() => manager.create({ ...options, origin: 'http://localhost' }), /HTTPS/);
  const bundle = manager.create(options);
  assert.throws(() => manager.redeem({ code: bundle.code, deviceName: '' }), /name/);
  assert.equal(manager.authenticates('wrong'), false);
  manager.cancel(); assert.throws(() => manager.redeem({ code: bundle.code, deviceName: 'phone' }), /expired/);
});
