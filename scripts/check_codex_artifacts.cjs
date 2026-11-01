// Production ArkTS file-receive logic with local filesystem/network mocks, no device or paid inference.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const os = require('node:os');
const assert = require('node:assert/strict');
const { createHash, randomUUID } = require('node:crypto');
const ts = require(process.argv[2] || 'typescript');
const folder = path.resolve(__dirname, '../entry/src/main/ets/pages/codex');
const loaded = new Map();
const io = {
  OpenMode: { READ_ONLY: 1, READ_WRITE: 2, CREATE: 4, TRUNC: 8 },
  access: async name => fs.existsSync(name), mkdir: async name => fs.mkdirSync(name, { recursive: true }),
  open: async (name, flags) => ({ fd: fs.openSync(name, flags & 4 ? 'w+' : 'r') }),
  close: async file => fs.closeSync(file.fd), stat: async name => typeof name === 'number' ? fs.fstatSync(name) : fs.statSync(name),
  read: async (fd, buffer, options) => fs.readSync(fd, Buffer.from(buffer), 0, options.length, options.offset),
  write: async (fd, value, options) => typeof value === 'string' ? fs.writeSync(fd, value) :
    fs.writeSync(fd, Buffer.from(value), 0, options.length, options.offset),
  rename: async (from, to) => fs.renameSync(from, to), unlink: async name => fs.unlinkSync(name)
};
const mocks = {
  '@kit.CoreFileKit': { fileIo: io },
  '@kit.ArkTS': { JSON, util: { TextEncoder: class { encodeInto(value) { return Buffer.from(value); } },
    Base64Helper: class { decodeSync(value) { return Uint8Array.from(Buffer.from(value, 'base64')); } }, generateRandomUUID: () => randomUUID() } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => {
    const hash = createHash('sha256'); return { update: async blob => { hash.update(blob.data); }, digest: async () => ({ data: hash.digest() }) };
  } } }, './CodexClient': {}
};
function load(name) {
  if (mocks[name]) return mocks[name];
  if (loaded.has(name)) return loaded.get(name);
  const filename = path.join(folder, name.replace('./', '') + '.ets');
  const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, { require: load, module, exports: module.exports, Uint8Array, ArrayBuffer, Number, Error }, { filename });
  loaded.set(name, module.exports); return module.exports;
}
async function main() {
  const { CodexArtifactStore, validateCodexArtifact } = load('./CodexArtifactStore');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-phone-artifacts-'));
  try {
    const data = Buffer.alloc(1024 * 1024 + 37, 0x5a);
    const artifact = { id: randomUUID(), name: '最终报告.pdf', size: data.length, sha256: createHash('sha256').update(data).digest('hex'),
      mimeType: 'application/pdf', turnId: 'turn-a', createdAt: Date.now() };
    let calls = 0;
    const client = { artifactChunkBytes: () => 1024 * 1024, call: async route => {
      calls++; const offset = Number(new URL('https://bridge' + route).searchParams.get('offset'));
      return { artifactChunk: { id: artifact.id, offset, total: artifact.size, sha256: artifact.sha256,
        base64: data.subarray(offset, offset + 1024 * 1024).toString('base64') } };
    } };
    const store = await CodexArtifactStore.create(root, 'https://computer-a:8787', 'session-a');
    const saved = await store.receive('session-a', artifact, client, () => true, () => {});
    assert.deepEqual(fs.readFileSync(saved.localPath), data); assert.equal(calls, 2);
    assert.equal(fs.existsSync(path.join(path.dirname(saved.localPath), '.metadata.json')), true);
    await store.receive('session-a', artifact, client, () => true, () => {});
    assert.equal(calls, 2, 'already verified files are not downloaded again');
    const other = await CodexArtifactStore.create(root, 'https://computer-b:8787', 'session-a');
    const another = await other.receive('session-a', artifact, client, () => true, () => {});
    assert.notEqual(another.localPath, saved.localPath, 'computer/session namespaces cannot collide');
    const differentSession = await CodexArtifactStore.create(root, 'https://computer-a:8787', 'session-b');
    assert.notEqual((await differentSession.receive('session-b', artifact, client, () => true, () => {})).localPath, saved.localPath);
    for (const bad of [{ ...artifact, name: '../bad.pdf' }, { ...artifact, id: '../../x' }, { ...artifact, size: 0 }, { ...artifact, sha256: 'wrong' }]) {
      assert.throws(() => validateCodexArtifact(bad));
    }
    const corrupt = { ...artifact, id: randomUUID(), size: 101,
      sha256: createHash('sha256').update(Buffer.alloc(101, 0x5a)).digest('hex') };
    const broken = { artifactChunkBytes: () => 65536, call: async () => ({ artifactChunk: { id: corrupt.id, offset: 0, total: corrupt.size, sha256: corrupt.sha256,
      base64: Buffer.alloc(101, 0).toString('base64') } }) };
    await assert.rejects(store.receive('session-a', corrupt, broken, () => true, () => {}), /SHA256/);
    const cancelled = { ...artifact, id: randomUUID() };
    await assert.rejects(store.receive('session-a', cancelled, client, () => false, () => {}), /取消/);
    const partials = fs.readdirSync(root, { recursive: true }).filter(name => name.endsWith('.part'));
    assert.equal(partials.length, 0, 'failed/cancelled transfers leave no partial file');
    const metadataBytes = Buffer.from('final json');
    const metadataArtifact = { ...artifact, id: randomUUID(), name: 'metadata.json', size: metadataBytes.length,
      sha256: createHash('sha256').update(metadataBytes).digest('hex') };
    const metadataSaved = await store.receive('session-a', metadataArtifact, { artifactChunkBytes: () => 65536, call: async () => ({ artifactChunk: {
      id: metadataArtifact.id, offset: 0, total: metadataBytes.length, sha256: metadataArtifact.sha256, base64: metadataBytes.toString('base64')
    } }) }, () => true, () => {});
    assert.equal(fs.readFileSync(metadataSaved.localPath).toString(), 'final json', 'manifest cannot overwrite a delivered metadata.json');
    let smallCalls = 0;
    const small = { ...artifact, id: randomUUID() };
    const smallClient = { artifactChunkBytes: () => 65536, call: async route => {
      smallCalls++; const params = new URL('https://bridge' + route).searchParams;
      const offset = Number(params.get('offset')); assert.equal(params.get('length'), '65536');
      return { artifactChunk: { id: small.id, offset, total: small.size, sha256: small.sha256,
        base64: data.subarray(offset, offset + 65536).toString('base64') } };
    } };
    const smallSaved = await store.receive('session-a', small, smallClient, () => true, () => {});
    assert.deepEqual(fs.readFileSync(smallSaved.localPath), data); assert.equal(smallCalls, 17);
    console.log('PASS: chunked receive, exact bytes/SHA256, persistent files, no duplicate download, computer/session isolation, invalid metadata, cancellation, corruption, partial cleanup and metadata filename collision.');
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
