import { randomBytes, randomUUID, createHash, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import path from 'node:path';
import { BridgeError } from './core.mjs';

const digest = token => createHash('sha256').update(token).digest();
export const PAIRING_PREFIX = 'CLAWMATE-CODEX-PAIR:';

// A certificate and a short-lived, one-use secret travel together over a physical/user-chosen channel.
// Long-lived device tokens are never included in a QR code or pairing file.
export class PairingManager {
  pending = null;
  constructor(stateDir) {
    this.filename = path.join(stateDir, 'devices.json');
    try { this.state = JSON.parse(readFileSync(this.filename, 'utf8')); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      this.state = { serverId: randomUUID(), devices: [] };
      this.save();
    }
  }
  save() {
    writeFileSync(this.filename + '.tmp', JSON.stringify(this.state), { mode: 0o600 });
    renameSync(this.filename + '.tmp', this.filename);
  }
  create({ origin, name, caCertificate }) {
    const url = new URL(origin);
    if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
      throw new Error('Pairing requires an HTTPS origin');
    }
    const code = randomBytes(32).toString('base64url');
    const expiresAt = Date.now() + 5 * 60000;
    this.pending = { hash: digest(code), expiresAt };
    return { type: 'clawmate-codex-pairing', version: 1, name, origin: url.origin,
      serverId: this.state.serverId, caCertificate: caCertificate || '', code, expiresAt };
  }
  redeem(body) {
    if (!this.pending || Date.now() > this.pending.expiresAt ||
      typeof body.code !== 'string' || !timingSafeEqual(digest(body.code), this.pending.hash)) {
      throw new BridgeError(401, 'Pairing code expired, used or invalid; generate a new pairing file on the PC');
    }
    if (typeof body.deviceName !== 'string' || !body.deviceName.trim() || body.deviceName.length > 80) {
      throw new BridgeError(400, 'Device name must be 1 to 80 characters');
    }
    if (this.state.devices.length >= 32) throw new BridgeError(409, 'Device limit reached; remove an unused device on the PC');
    const token = randomBytes(32).toString('base64url');
    const device = { id: randomUUID(), name: body.deviceName.trim(), tokenHash: digest(token).toString('hex'), createdAt: Date.now() };
    this.state.devices.push(device);
    try { this.save(); } catch (error) { this.state.devices.pop(); throw error; }
    this.pending = null;
    return { token, deviceId: device.id, serverId: this.state.serverId };
  }
  authenticates(token) {
    if (typeof token !== 'string' || token.length > 256) return false;
    const supplied = digest(token);
    return this.state.devices.some(device => timingSafeEqual(supplied, Buffer.from(device.tokenHash, 'hex')));
  }
  list() { return this.state.devices.map(({ id, name, createdAt }) => ({ id, name, createdAt })); }
  revoke(id) {
    this.state.devices = this.state.devices.filter(device => device.id !== id);
    this.save();
  }
  cancel() { this.pending = null; }
  reset() {
    this.pending = null; this.state = { serverId: randomUUID(), devices: [] }; this.save();
  }
}
