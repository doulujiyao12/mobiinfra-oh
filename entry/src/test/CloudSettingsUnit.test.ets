import { describe, expect, it } from '@ohos/hypium';
import {
  CloudChatCompletionOptions, CloudModelClient, CloudModelConfig, cloudPlannerApiKey, cloudDeciderApiKey
} from '../main/ets/utils/CloudModelClient';
import { cloudApiProvider, normalizeCloudChatUrl } from '../main/ets/utils/CloudApiCompatibility';
import {
  cloudSettingValuesDiffer, cloudSettingsUseSeparateValues, resolveCloudSettings,
  sharedCloudSettingEditorValue, updateUnifiedCloudSetting
} from '../main/ets/utils/CloudSettingsConfig';

function defaults(): CloudModelConfig {
  return { plannerBaseUrl: 'https://planner.example/v1', plannerModel: 'planner-default', plannerApiKey: 'default-p',
    deciderBaseUrl: 'https://decider.example/v1', deciderModel: 'vision-default', deciderApiKey: 'default-d',
    apiKey: 'default-shared' };
}

function blank(): CloudModelConfig {
  return { plannerBaseUrl: '', plannerModel: '', plannerApiKey: '', deciderBaseUrl: '', deciderModel: '',
    deciderApiKey: '', apiKey: '' };
}

interface TestToolParameters { type: string; }

function options(baseUrl: string): CloudChatCompletionOptions {
  let parameters: TestToolParameters = { type: 'object' };
  return { baseUrl: baseUrl, apiKey: 'test-only', model: 'user-model', messages: [{ role: 'user', content: 'hello' }],
    maxTokens: 1024, temperature: 0, top_p: 0.8, top_k: 20, min_p: 0.1, repetition_penalty: 1.2,
    presence_penalty: 0.5, chatTemplateKwargs: { enable_thinking: false },
    tools: [{ type: 'function', function: { name: 'query_memory', description: 'test tool',
      parameters: parameters } }], toolChoice: 'auto' };
}

export default function cloudSettingsUnitTest(): void {
  describe('cloudSettingsUnitTest', () => {
    it('usesEachRolesOriginalDefaultsWhenEmptyAndDoesNotFlattenSplitDefaults', 0, () => {
      let config = resolveCloudSettings(blank(), defaults());
      expect(config.plannerBaseUrl).assertEqual(defaults().plannerBaseUrl);
      expect(config.deciderBaseUrl).assertEqual(defaults().deciderBaseUrl);
      expect(config.plannerModel).assertEqual('planner-default');
      expect(config.deciderModel).assertEqual('vision-default');
      expect(cloudPlannerApiKey(config)).assertEqual('default-p');
      expect(cloudDeciderApiKey(config)).assertEqual('default-d');
      expect(cloudSettingsUseSeparateValues(defaults(), defaults())).assertFalse();
      expect(cloudSettingValuesDiffer('', '', 'planner-default', 'vision-default')).assertFalse();
      expect(cloudSettingValuesDiffer('custom', '', 'planner-default', 'vision-default')).assertTrue();
      expect(sharedCloudSettingEditorValue(config.plannerBaseUrl, config.deciderBaseUrl,
        defaults().plannerBaseUrl, defaults().deciderBaseUrl)).assertEqual('');
    });

    it('appliesEachUnifiedFieldToBothRolesAndClearsBackToDefaults', 0, () => {
      let config = updateUnifiedCloudSetting(defaults(), 'url', 'https://openrouter.ai/api/v1');
      config = updateUnifiedCloudSetting(config, 'model', 'vendor/model');
      config = updateUnifiedCloudSetting(config, 'key', 'custom-key');
      let resolved = resolveCloudSettings(config, defaults());
      expect(resolved.plannerBaseUrl).assertEqual('https://openrouter.ai/api/v1');
      expect(resolved.deciderBaseUrl).assertEqual(resolved.plannerBaseUrl);
      expect(resolved.plannerModel).assertEqual('vendor/model');
      expect(resolved.deciderModel).assertEqual('vendor/model');
      expect(cloudDeciderApiKey(resolved)).assertEqual('custom-key');
      expect(cloudSettingsUseSeparateValues(config, defaults())).assertFalse();
      expect(sharedCloudSettingEditorValue(config.plannerModel, config.deciderModel,
        defaults().plannerModel, defaults().deciderModel)).assertEqual('vendor/model');
      config = updateUnifiedCloudSetting(config, 'url', '  ');
      resolved = resolveCloudSettings(config, defaults());
      expect(resolved.plannerBaseUrl).assertEqual(defaults().plannerBaseUrl);
      expect(resolved.deciderBaseUrl).assertEqual(defaults().deciderBaseUrl);
      config = updateUnifiedCloudSetting(config, 'key', '');
      config = updateUnifiedCloudSetting(config, 'model', '');
      resolved = resolveCloudSettings(config, defaults());
      expect(resolved.plannerModel).assertEqual('planner-default');
      expect(resolved.deciderModel).assertEqual('vision-default');
      expect(cloudPlannerApiKey(resolved)).assertEqual('default-p');
      expect(cloudDeciderApiKey(resolved)).assertEqual('default-d');
      expect(config.apiKey).assertEqual('');
    });

    it('preservesIndependentAdvancedSettingsAndNeverCopiesBuiltInSecretsToCustomUrls', 0, () => {
      let config = defaults();
      config.plannerBaseUrl = 'https://api.openai.com/v1'; config.plannerApiKey = 'user-key';
      config.plannerModel = 'user-model';
      expect(cloudSettingsUseSeparateValues(config, defaults())).assertTrue();
      let resolved = resolveCloudSettings(config, defaults());
      expect(resolved.deciderBaseUrl).assertEqual(defaults().deciderBaseUrl);
      expect(cloudPlannerApiKey(resolved)).assertEqual('user-key');
      expect(cloudDeciderApiKey(resolved)).assertEqual('default-d');
      config.plannerApiKey = '';
      resolved = resolveCloudSettings(config, defaults());
      expect(cloudPlannerApiKey(resolved)).assertEqual('');
      config.apiKey = 'previous-shared-key';
      expect(cloudPlannerApiKey(resolveCloudSettings(config, defaults()))).assertEqual('');
      config.apiKey = defaults().apiKey;
      config.plannerApiKey = defaults().plannerApiKey;
      expect(cloudPlannerApiKey(resolveCloudSettings(config, defaults()))).assertEqual('');
      config.apiKey = 'old-user-key';
      expect(cloudPlannerApiKey(resolveCloudSettings(config, defaults()))).assertEqual('old-user-key');
      config.plannerApiKey = 'sk-1••••••••abcd'; config.apiKey = '';
      expect(cloudPlannerApiKey(resolveCloudSettings(config, defaults()))).assertEqual('');
      config = updateUnifiedCloudSetting(defaults(), 'key', 'user-key');
      config.deciderBaseUrl = 'https://other.example/v1'; config.deciderApiKey = '';
      config.apiKey = '';
      expect(cloudDeciderApiKey(resolveCloudSettings(config, defaults()))).assertEqual('');
    });

    it('onlyUsesTheLegacySharedKeyWhenRoleKeysAreAbsent', 0, () => {
      let config = blank(); config.apiKey = 'legacy-key';
      expect(cloudPlannerApiKey(config)).assertEqual('');
      expect(cloudDeciderApiKey(config)).assertEqual('');
      config.plannerApiKey = undefined; config.deciderApiKey = undefined;
      expect(cloudPlannerApiKey(config)).assertEqual('legacy-key');
      expect(cloudDeciderApiKey(config)).assertEqual('legacy-key');
    });

    it('acceptsProviderRootsVersionedUrlsAndCompleteEndpointsWithoutDuplicatingPaths', 0, () => {
      expect(normalizeCloudChatUrl(' https://api.openai.com/ ')).assertEqual('https://api.openai.com/v1/chat/completions');
      expect(normalizeCloudChatUrl('https://api.openai.com/v1/')).assertEqual('https://api.openai.com/v1/chat/completions');
      expect(normalizeCloudChatUrl('https://openrouter.ai')).assertEqual('https://openrouter.ai/api/v1/chat/completions');
      expect(normalizeCloudChatUrl('https://openrouter.ai/api')).assertEqual('https://openrouter.ai/api/v1/chat/completions');
      expect(normalizeCloudChatUrl('https://openrouter.ai/api/v1/')).assertEqual('https://openrouter.ai/api/v1/chat/completions');
      expect(normalizeCloudChatUrl('https://api.deepseek.com')).assertEqual('https://api.deepseek.com/chat/completions');
      expect(normalizeCloudChatUrl('https://api.deepseek.com/v1')).assertEqual('https://api.deepseek.com/v1/chat/completions');
      let complete = 'https://proxy.example/prefix/v1/chat/completions?route=test';
      expect(normalizeCloudChatUrl(complete)).assertEqual(complete);
      expect(normalizeCloudChatUrl('http://localhost:9003')).assertEqual('http://localhost:9003/v1/chat/completions');
      expect(cloudApiProvider('https://api.openai.com.evil.example')).assertEqual('compatible');
      expect(cloudApiProvider('https://proxy.example/openrouter.ai')).assertEqual('compatible');
    });

    it('buildsProviderSpecificBodiesForStreamingAndNonStreamingRequests', 0, () => {
      let input = options('https://api.openai.com/v1');
      let openai = CloudModelClient.buildChatRequestBody(input, true);
      expect(openai.max_completion_tokens).assertEqual(1024);
      expect(openai.max_tokens === undefined).assertTrue();
      expect(openai.temperature === undefined).assertTrue();
      expect(openai.top_p === undefined).assertTrue();
      expect(openai.chat_template_kwargs === undefined).assertTrue();
      expect(openai.top_k === undefined).assertTrue();
      expect(openai.stream).assertTrue();
      expect(openai.tools?.length).assertEqual(1);
      expect(openai.tool_choice).assertEqual('auto');
      let router = CloudModelClient.buildChatRequestBody(options('https://openrouter.ai/api/v1'));
      expect(router.max_tokens).assertEqual(1024);
      expect(router.model).assertEqual('user-model');
      expect(router.chat_template_kwargs === undefined).assertTrue();
      expect(router.thinking === undefined).assertTrue();
      let deepseek = CloudModelClient.buildChatRequestBody(options('https://api.deepseek.com'));
      expect(deepseek.thinking?.type).assertEqual('disabled');
      expect(deepseek.chat_template_kwargs === undefined).assertTrue();
      expect(deepseek.max_tokens).assertEqual(1024);
      let thinkingInput = options('https://api.deepseek.com'); thinkingInput.chatTemplateKwargs = { enable_thinking: true };
      expect(CloudModelClient.buildChatRequestBody(thinkingInput).thinking?.type).assertEqual('enabled');
      let legacy = CloudModelClient.buildChatRequestBody(options('http://localhost:9003'));
      expect(legacy.chat_template_kwargs?.enable_thinking).assertFalse();
      expect(legacy.top_k).assertEqual(20);
      expect(legacy.repetition_penalty).assertEqual(1.2);
      expect(legacy.temperature).assertEqual(0);
    });

    it('retainsDeepSeekReasoningForToolHistoryAndDoesNotSendItToOtherProviders', 0, () => {
      let result = CloudModelClient.parseChatCompletionResponseText('{"choices":[{"message":' +
        '{"role":"assistant","content":"answer","reasoning_content":"reasoning"},"finish_reason":"stop"}]}');
      expect(result.assistantMessage.reasoning_content).assertEqual('reasoning');
      let input = options('https://api.deepseek.com'); input.messages = [result.assistantMessage];
      expect(CloudModelClient.buildChatRequestBody(input).messages[0].reasoning_content).assertEqual('reasoning');
      input.baseUrl = 'https://api.openai.com';
      expect(CloudModelClient.buildChatRequestBody(input).messages[0].reasoning_content === undefined).assertTrue();
      expect(result.assistantMessage.reasoning_content).assertEqual('reasoning');
    });

    it('requiresProviderCredentialsAndModelIdBeforeStartingRequests', 0, () => {
      for (let url of ['https://api.deepseek.com', 'https://openrouter.ai/api/v1', 'https://api.openai.com/v1']) {
        let missingModel = options(url); missingModel.model = ' ';
        let rejectedModel = false;
        try { CloudModelClient.buildChatRequestBody(missingModel); } catch (e) {
          rejectedModel = true; expect((e as Error).message).assertContain('模型 ID');
        }
        expect(rejectedModel).assertTrue();
        let missingKey = options(url); missingKey.apiKey = '';
        let rejectedKey = false;
        try { CloudModelClient.buildChatRequestBody(missingKey); } catch (e) {
          rejectedKey = true; expect((e as Error).message).assertContain('API Key');
        }
        expect(rejectedKey).assertTrue();
      }
    });
  });
}
