import { util } from '@kit.ArkTS';
import { CODEX_PAIRING_PREFIX, CodexPairingBundle, validateCodexPairing } from './CodexTypes';

// Files, pasted text and QR codes use the same decoder and trust validation.
export function parseCodexPairingInput(input: string): CodexPairingBundle {
  let raw = input.trim();
  if (!raw || raw.length > 12288) { throw new Error('配对内容为空或过长，请在电脑端重新生成'); }
  let bundle: CodexPairingBundle;
  try {
    if (raw.startsWith(CODEX_PAIRING_PREFIX)) {
      let encoded = raw.substring(CODEX_PAIRING_PREFIX.length);
      if (!/^[A-Za-z0-9_-]+$/.test(encoded)) { throw new Error('Invalid encoding'); }
      encoded = encoded.replace(/-/g, '+').replace(/_/g, '/');
      while (encoded.length % 4 !== 0) { encoded += '='; }
      raw = new util.TextDecoder().decodeWithStream(new util.Base64Helper().decodeSync(encoded));
    }
    if (!raw.startsWith('{') || raw.length > 8192) { throw new Error('Invalid pairing document'); }
    bundle = JSON.parse(raw) as CodexPairingBundle;
  } catch (e) {
    throw new Error('请使用电脑端生成的完整配对信息，证书指纹不能用来配对');
  }
  validateCodexPairing(bundle);
  return bundle;
}
