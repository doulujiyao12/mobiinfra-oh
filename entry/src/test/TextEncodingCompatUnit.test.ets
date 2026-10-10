import { describe, it, expect } from '@ohos/hypium';
import { decodeUtf8Compat, encodeUtf8Compat } from '../main/ets/utils/TextEncodingCompat';

export default function textEncodingCompatUnitTest() {
  describe('textEncodingCompatUnitTest', () => {
    it('encodesUtf8WithoutChangingContent', 0, () => {
      let source = 'abc采集😀';
      let encoded = encodeUtf8Compat(source);

      expect(encoded.length).assertEqual(13);
      expect(decodeUtf8Compat(encoded)).assertEqual(source);
    });

    it('encodesLongAsciiWithExactByteLength', 0, () => {
      let parts: string[] = [];
      for (let i = 0; i < 128; i++) {
        parts.push('0123456789abcdef');
      }
      let source = parts.join('');
      let encoded = encodeUtf8Compat(source);

      expect(encoded.length).assertEqual(source.length);
      expect(decodeUtf8Compat(encoded)).assertEqual(source);
    });
  });
}
