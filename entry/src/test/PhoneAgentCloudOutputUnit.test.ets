import { describe, expect, it } from '@ohos/hypium';
import {
  CloudChatCompletionOptions, CloudChatCompletionResult, CloudModelClient, CloudModelConfig,
  PhoneAgentCloudOptions
} from '../main/ets/utils/CloudModelClient';
import { PHONE_AGENT_MAX_ACTION_TOKENS } from '../main/ets/utils/selfhdc/PhoneAgentPolicy';

// No network/device calls: only override the request boundary and exercise the production phone response path.
class ScriptedAgentCloudClient extends CloudModelClient {
  budgets: number[] = [];
  requests: CloudChatCompletionOptions[] = [];
  results: CloudChatCompletionResult[] = [];

  async chatCompletion(options: CloudChatCompletionOptions): Promise<CloudChatCompletionResult> {
    this.budgets.push(options.maxTokens || 0);
    this.requests.push(options);
    let result = this.results.shift();
    if (result === undefined) { throw new Error('Unexpected extra model request'); }
    return result;
  }
}

function completion(content: string, finishReason: string): CloudChatCompletionResult {
  return { content: content, finishReason: finishReason, toolCalls: [],
    assistantMessage: { role: 'assistant', content: content } };
}

function config(): CloudModelConfig {
  return { plannerBaseUrl: 'https://test.invalid', plannerModel: 'test', apiKey: '',
    deciderBaseUrl: 'https://test.invalid', deciderModel: 'test' };
}

function phoneOptions(logs: string[]): PhoneAgentCloudOptions {
  return { onDiagnostic: (message: string): void => { logs.push(message); }, ensureActive: (): void => {} };
}

export default function phoneAgentCloudOutputUnitTest(): void {
  describe('phoneAgentCloudOutputUnitTest', () => {
    it('discardsLengthLimitedResponseAndRetriesTheSameScreenshotWithMoreTokens', 0, async () => {
      let client = new ScriptedAgentCloudClient();
      // Even syntactically valid content is unsafe when the provider reports length truncation.
      client.results = [completion('{"action":"input","parameters":{"text":"残缺"}}', 'length'),
        completion('{"action":"input","parameters":{"text":"完整需求"}}', 'stop')];
      let logs: string[] = [];
      let response = await client.chatQwenDecider('', [], 'test-image', config(), phoneOptions(logs));
      expect(response.includes('完整需求')).assertTrue();
      expect(client.budgets.length).assertEqual(2);
      expect(client.budgets[0]).assertEqual(1024);
      expect(client.budgets[1]).assertEqual(2048);
      expect(client.requests[0].messages === client.requests[1].messages).assertTrue();
      expect(logs.join('\n')).assertContain('finishReason=length');
      expect(logs.join('\n')).assertContain('no device action executed');
      let system = client.requests[0].messages[0].content as string;
      expect(system.includes('do not repeat the input text')).assertTrue();
    });

    it('stopsAtTheBudgetLimitInsteadOfDispatchingTruncatedText', 0, async () => {
      let client = new ScriptedAgentCloudClient();
      client.results = [completion('partial', 'length'), completion('partial', 'length'),
        completion('partial', 'length')];
      let failure = '';
      try { await client.chatQwenDecider('', [], 'test-image', config(), phoneOptions([])); }
      catch (e) { failure = (e as Error).message; }
      expect(client.budgets.length).assertEqual(3);
      expect(client.budgets[2]).assertEqual(PHONE_AGENT_MAX_ACTION_TOKENS);
      expect(failure).assertContain('PHONE_AGENT_OUTPUT_TRUNCATED');
    });

    it('honorsCancellationBeforeIssuingAnotherRequest', 0, async () => {
      let client = new ScriptedAgentCloudClient();
      client.results = [completion('partial', 'length')];
      let checks = 0;
      let options: PhoneAgentCloudOptions = {
        onDiagnostic: (): void => {},
        ensureActive: (): void => {
          checks += 1;
          if (checks > 1) { throw new Error('Task cancelled'); }
        }
      };
      let failure = '';
      try { await client.chatQwenDecider('', [], 'test-image', config(), options); }
      catch (e) { failure = (e as Error).message; }
      expect(client.budgets.length).assertEqual(1);
      expect(failure).assertEqual('Task cancelled');
    });

    it('preservesLegacyPcDeciderBudgetAndPromptWhenPhoneOptionsAreAbsent', 0, async () => {
      let client = new ScriptedAgentCloudClient();
      client.results = [completion('{"action":"wait"}', 'stop'), completion('{"action":"wait"}', 'stop')];
      await client.chatQwenDecider('查询', [], 'test-image', config());
      await client.chatDecider('legacy full prompt', 'test-image', config());
      expect(client.budgets[0]).assertEqual(256);
      expect(client.budgets[1]).assertEqual(256);
      let system = client.requests[0].messages[0].content as string;
      expect(system.includes('do not repeat the input text')).assertFalse();
    });
  });
}
