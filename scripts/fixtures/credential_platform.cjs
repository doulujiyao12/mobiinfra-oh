// In-memory Harmony filesystem and real AES-GCM for credential migration tests.
const crypto = require('node:crypto');

function credentialPlatform() {
  const files = new Map();
  const handles = new Map();
  const platform = {
    files, failRename: false, dropWrite: false,
    reset() { files.clear(); handles.clear(); this.failRename = false; this.dropWrite = false; },
    util: {
      TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
      TextDecoder: class {
        constructor(name) { this.decoder = new TextDecoder(name); }
        decodeToString(value) { return this.decoder.decode(value); }
        decodeWithStream(value) { return this.decoder.decode(value); }
      },
      Base64Helper: class {
        encodeToStringSync(value) { return Buffer.from(value).toString('base64'); }
        decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); }
      },
      generateRandomUUID: () => crypto.randomUUID()
    },
    fs: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      accessSync: path => files.has(path),
      mkdirSync: path => files.set(path, null),
      readTextSync(path) {
        if (!files.has(path)) throw Error('ENOENT');
        return files.get(path).toString('utf8');
      },
      openSync(path) { files.set(path, Buffer.alloc(0)); const fd = handles.size + 1; handles.set(fd, path); return { fd }; },
      writeSync(fd, value) {
        const path = handles.get(fd);
        // Exercise partial-write handling.
        const bytes = Buffer.from(value).subarray(0, 97);
        if (!platform.dropWrite) files.set(path, Buffer.concat([files.get(path), bytes]));
        return bytes.length;
      },
      fsyncSync() {}, closeSync() {},
      renameSync(from, to) {
        if (platform.failRename) throw Error('fixture disk failure');
        files.set(to, files.get(from)); files.delete(from);
      }
    },
    cryptoFramework: {
      CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
      createRandom: () => ({ generateRandomSync: count => ({ data: new Uint8Array(crypto.randomBytes(count)) }) }),
      createSymKeyGenerator: () => ({ convertKeySync: blob => blob.data }),
      createCipher() {
        let cipher, encrypt;
        return {
          initSync(mode, key, params) {
            encrypt = mode === 0;
            cipher = encrypt ? crypto.createCipheriv('aes-256-gcm', key, params.iv.data) :
              crypto.createDecipheriv('aes-256-gcm', key, params.iv.data);
            cipher.setAAD(params.aad.data);
            if (!encrypt) cipher.setAuthTag(params.authTag.data);
          },
          doFinalSync(blob) {
            const chunks = [cipher.update(blob.data), cipher.final()];
            if (encrypt) chunks.push(cipher.getAuthTag());
            return { data: new Uint8Array(Buffer.concat(chunks)) };
          }
        };
      }
    }
  };
  return platform;
}
module.exports = { credentialPlatform };
