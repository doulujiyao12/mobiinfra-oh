import { describe, it, expect } from '@ohos/hypium';
import { normalizeCodexOrigin, validCodexToken, codexTaskBusy, codexStatusLabel } from '../main/ets/pages/codex/CodexTypes';

export default function codexPolicyUnitTest() {
  describe('codexPolicyUnitTest', () => {
    it('acceptsHttpsOriginsAndNormalizesTrailingSlash', 0, () => {
      expect(normalizeCodexOrigin(' https://Codex.example.com:8787/ ')).assertEqual('https://codex.example.com:8787');
      expect(normalizeCodexOrigin('https://192.168.1.8:8787')).assertEqual('https://192.168.1.8:8787');
      expect(normalizeCodexOrigin('https://[fd00::1]:8787')).assertEqual('https://[fd00::1]:8787');
    });
    it('rejectsCleartextCredentialsQueriesAndPaths', 0, () => {
      const rejected: string[] = ['http://192.168.1.8:8787', 'https://user:pass@host',
        'https://host?token=secret', 'https://host/path', 'https://host#x', 'https://host:0',
        'https://host:65536', 'https://host\n.evil.com'];
      rejected.forEach((value: string) => {
        let failed: boolean = false;
        try { normalizeCodexOrigin(value); } catch (e) { failed = true; }
        expect(failed).assertTrue();
      });
    });
    it('requiresServerGeneratedTokenFormat', 0, () => {
      expect(validCodexToken('a'.repeat(43))).assertTrue();
      expect(validCodexToken('password')).assertFalse();
      expect(validCodexToken('a'.repeat(42) + '\n')).assertFalse();
    });
    it('keepsApprovalAndStoppingStatesBusy', 0, () => {
      expect(codexTaskBusy('waitingApproval')).assertTrue();
      expect(codexTaskBusy('stopping')).assertTrue();
      expect(codexTaskBusy('completed')).assertFalse();
      expect(codexStatusLabel('failed')).assertEqual('执行失败');
    });
  });
}
