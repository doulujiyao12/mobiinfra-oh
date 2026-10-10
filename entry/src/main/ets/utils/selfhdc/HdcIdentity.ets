import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { selfHdcEnsureDirectory, selfHdcExists, selfHdcReadText, selfHdcWriteAtomicText } from './SelfHdcFiles';
import { selfHdcErrorText } from './SelfHdcError';

interface StoredHdcIdentity {
  version: number;
  publicDer: string;
  privateDer: string;
}

export class HdcIdentity {
  private pair: cryptoFramework.KeyPair;
  fingerprint: string;
  pem: string;
  private constructor(pair: cryptoFramework.KeyPair, fingerprint: string, pem: string) {
    this.pair = pair;
    this.fingerprint = fingerprint;
    this.pem = pem;
  }

  static async load(filesDir: string): Promise<HdcIdentity> {
    try {
      let root = filesDir + '/self_hdc';
      selfHdcEnsureDirectory(root);
      let path = root + '/identity.json';
      let base64 = new util.Base64Helper();
      let generator = cryptoFramework.createAsyKeyGenerator('RSA3072');
      let pair: cryptoFramework.KeyPair;
      if (selfHdcExists(path)) {
        // Preserve the same client identity across sessions. Never use/copy the PC key.
        let stored = ArkJSON.parse(selfHdcReadText(path, 32768)) as StoredHdcIdentity;
        if (stored.version !== 1 || !stored.publicDer || !stored.privateDer) {
          throw new Error('saved identity invalid; do not silently replace a trusted key');
        }
        pair = await generator.convertKey({ data: base64.decodeSync(stored.publicDer) },
          { data: base64.decodeSync(stored.privateDer) });
      } else {
        pair = await generator.generateKeyPair();
        let stored: StoredHdcIdentity = {
          version: 1,
          publicDer: base64.encodeToStringSync(pair.pubKey.getEncoded().data),
          privateDer: base64.encodeToStringSync(pair.priKey.getEncoded().data)
        };
        // Only the app's private sandbox stores this file. Logs/exports exclude it.
        selfHdcWriteAtomicText(path, ArkJSON.stringify(stored));
      }
      let publicDer = pair.pubKey.getEncoded().data;
      let md = cryptoFramework.createMd('SHA256');
      await md.update({ data: publicDer });
      let digest = await md.digest();
      let fingerprint = '';
      digest.data.forEach((value: number): void => { fingerprint += value.toString(16).padStart(2, '0'); });
      let encoded = base64.encodeToStringSync(publicDer);
      let lines: string[] = [];
      for (let index = 0; index < encoded.length; index += 64) { lines.push(encoded.substring(index, index + 64)); }
      return new HdcIdentity(pair, fingerprint,
        '-----BEGIN PUBLIC KEY-----\n' + lines.join('\n') + '\n-----END PUBLIC KEY-----\n');
    } catch (e) { throw new Error('HDC_KEY: ' + selfHdcErrorText(e as Error)); }
  }

  async sign(challenge: Uint8Array, modern: boolean): Promise<string> {
    try {
      if (challenge.length === 0 || challenge.length > 1024 || (!modern && challenge.length > 373)) {
        throw new Error('invalid RSA challenge size');
      }
      let algorithm = modern ? 'RSA3072|PSS|SHA512|MGF1_SHA512' : 'RSA3072|PKCS1|NoHash|OnlySign';
      let signer = cryptoFramework.createSign(algorithm);
      await signer.init(this.pair.priKey);
      if (modern) { signer.setSignSpec(cryptoFramework.SignSpecItem.PSS_SALT_LEN_NUM, 64); }
      let signature = await signer.sign({ data: challenge });
      return new util.Base64Helper().encodeToStringSync(signature.data);
    } catch (e) { throw new Error('HDC_SIGN: ' + selfHdcErrorText(e as Error)); }
  }

  static async sessionId(): Promise<number> {
    try {
      let bytes = (await cryptoFramework.createRandom().generateRandom(4)).data;
      return new DataView(bytes.slice().buffer).getUint32(0, false) || 1;
    } catch (e) { throw new Error('HDC_RANDOM: ' + selfHdcErrorText(e as Error)); }
  }
}
