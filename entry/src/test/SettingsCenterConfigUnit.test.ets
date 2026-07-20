import { describe, it, expect } from '@ohos/hypium';
import {
  SettingsActionKind,
  isSettingsSectionSelected,
  isMaskedSensitiveSettingValue,
  maskSensitiveSettingValue,
  normalizeSettingsSectionId,
  restoreMaskedSensitiveSettingDefault,
  SETTINGS_SECTION_ITEMS,
  SETTINGS_SECTION_NONE,
  settingsInputShouldUseMultiline,
  settingsSensitiveInputShouldUseMultiline,
  SettingsSectionId,
  settingsSectionSubtitle,
  settingsSectionTitle
} from '../main/ets/pages/settings/SettingsCenterTypes';
import { settingsActionColor } from '../main/ets/pages/settings/SettingsCenterTheme';
import {
  DEFAULT_ENDPOINT_CONFIG,
  configuredEndpointSecretOrDefault,
  configuredEndpointValueOrDefault
} from '../main/ets/config/DefaultEndpointConfig';
import {
  CloudModelConfig,
  cloudDeciderApiKey,
  cloudPlannerApiKey
} from '../main/ets/utils/CloudModelClient';
import { buildCloudOutputLog } from '../main/ets/utils/CloudLogOutput';
import {
  hiddenDefaultSettingEditorValue,
  hiddenDefaultSettingPlaceholder,
  migrateDefaultSettingValue,
  settingUsesDefaultValue
} from '../main/ets/utils/DefaultSettingVisibility';
import {
  DEFAULT_GALLERY_AMAP_WEB_KEY,
  DEFAULT_GALLERY_API_BASE_URL,
  DEFAULT_GALLERY_API_KEY,
  DEFAULT_GALLERY_EMBEDDING_API_KEY,
  DEFAULT_GALLERY_EMBEDDING_BASE_URL,
  DEFAULT_GALLERY_EMBEDDING_MODEL,
  DEFAULT_GALLERY_MODEL
} from '../main/ets/utils/gallery/GallerySettingsDefaults';

export default function settingsCenterConfigUnitTest() {
  describe('settingsCenterConfigUnitTest', () => {
    it('usesConfirmedSettingsSectionOrder', 0, () => {
      expect(SETTINGS_SECTION_ITEMS.length).assertEqual(5);
      expect(SETTINGS_SECTION_ITEMS[0].id).assertEqual(SettingsSectionId.PersonalPrivacy);
      expect(SETTINGS_SECTION_ITEMS[1].id).assertEqual(SettingsSectionId.DataCollection);
      expect(SETTINGS_SECTION_ITEMS[2].id).assertEqual(SettingsSectionId.ModelAgents);
      expect(SETTINGS_SECTION_ITEMS[3].id).assertEqual(SettingsSectionId.TaskAutomation);
      expect(SETTINGS_SECTION_ITEMS[4].id).assertEqual(SettingsSectionId.StorageAbout);
    });

    it('exposesChineseSectionTitles', 0, () => {
      expect(settingsSectionTitle(SettingsSectionId.PersonalPrivacy)).assertEqual('个人与隐私');
      expect(settingsSectionTitle(SettingsSectionId.DataCollection)).assertEqual('数据采集');
      expect(settingsSectionTitle(SettingsSectionId.ModelAgents)).assertEqual('模型与智能体');
      expect(settingsSectionTitle(SettingsSectionId.TaskAutomation)).assertEqual('任务与自动化');
      expect(settingsSectionTitle(SettingsSectionId.StorageAbout)).assertEqual('存储与关于');
      expect(settingsSectionSubtitle(SettingsSectionId.ModelAgents)).assertEqual('云端 Planner/Decider、本地模型与 HDC');
    });

    it('normalizesSettingsSectionSelection', 0, () => {
      expect(normalizeSettingsSectionId(SettingsSectionId.TaskAutomation)).assertEqual(SettingsSectionId.TaskAutomation);
      expect(isSettingsSectionSelected(SettingsSectionId.TaskAutomation)).assertTrue();
      expect(normalizeSettingsSectionId(SETTINGS_SECTION_NONE)).assertEqual(SETTINGS_SECTION_NONE);
      expect(normalizeSettingsSectionId(99)).assertEqual(SETTINGS_SECTION_NONE);
      expect(isSettingsSectionSelected(99)).assertFalse();
      expect(isSettingsSectionSelected(SETTINGS_SECTION_NONE)).assertFalse();
    });

    it('mapsSettingsActionKindsToStableColors', 0, () => {
      expect(settingsActionColor(SettingsActionKind.Primary)).assertEqual('#4F68FF');
      expect(settingsActionColor(SettingsActionKind.Secondary)).assertEqual('#607D8B');
      expect(settingsActionColor(SettingsActionKind.Success)).assertEqual('#38BE8B');
      expect(settingsActionColor(SettingsActionKind.Warning)).assertEqual('#FF9800');
      expect(settingsActionColor(SettingsActionKind.Danger)).assertEqual('#F44336');
      expect(settingsActionColor(SettingsActionKind.Special)).assertEqual('#765BFF');
    });

    it('masksSensitiveSettingValuesByDefault', 0, () => {
      expect(maskSensitiveSettingValue('')).assertEqual('');
      expect(maskSensitiveSettingValue('abc')).assertEqual('•••');
      expect(maskSensitiveSettingValue('sk-1234567890abcdef')).assertEqual('sk-1••••••••cdef');
    });

    it('usesMultilineInputsForLongConfigurationText', 0, () => {
      expect(settingsInputShouldUseMultiline('https://ark.cn-beijing.volces.com/api/v3/images/generations', ''))
        .assertTrue();
      expect(settingsInputShouldUseMultiline('mimo-v2.5-tts', '')).assertFalse();
      expect(settingsSensitiveInputShouldUseMultiline('sk-1234567890abcdefghijklmnopqrstuvwxyz', ''))
        .assertTrue();
      expect(settingsSensitiveInputShouldUseMultiline('', 'MiMO TTS 服务密钥，格式 tp-xxxxx')).assertTrue();
    });

    it('restoresMaskedDefaultSensitiveValues', 0, () => {
      expect(restoreMaskedSensitiveSettingDefault('sk-1••••••••cdef', 'sk-1234567890abcdef'))
        .assertEqual('sk-1234567890abcdef');
      expect(restoreMaskedSensitiveSettingDefault('sk-other••••••••abcd', 'sk-1234567890abcdef'))
        .assertEqual('');
    });

    it('doesNotUseMaskedSensitiveValuesAsEndpointSecrets', 0, () => {
      expect(isMaskedSensitiveSettingValue('366e••••••••0f68')).assertTrue();
      expect(configuredEndpointSecretOrDefault('366e••••••••0f68', '')).assertEqual('');
      expect(configuredEndpointSecretOrDefault('mobiagent-key', 'fallback-key')).assertEqual('mobiagent-key');
      expect(configuredEndpointSecretOrDefault('   ', 'fallback-key')).assertEqual('fallback-key');
    });

    it('resolvesConfiguredEndpointValuesWithDefaultFallback', 0, () => {
      expect(configuredEndpointValueOrDefault('', 'default-model')).assertEqual('default-model');
      expect(configuredEndpointValueOrDefault('   ', 'default-model')).assertEqual('default-model');
      expect(configuredEndpointValueOrDefault(' custom-model ', 'default-model')).assertEqual('custom-model');
    });

    it('hidesDefaultEndpointValuesButKeepsCustomOverridesVisible', 0, () => {
      expect(settingUsesDefaultValue('https://internal.example/v1', 'https://internal.example/v1')).assertTrue();
      expect(settingUsesDefaultValue('', 'https://internal.example/v1')).assertTrue();
      expect(settingUsesDefaultValue('https://custom.example/v1', 'https://internal.example/v1')).assertFalse();
      expect(hiddenDefaultSettingEditorValue('https://internal.example/v1', 'https://internal.example/v1'))
        .assertEqual('');
      expect(hiddenDefaultSettingPlaceholder('https://internal.example/v1', 'https://internal.example/v1',
        '输入 URL')).assertEqual('默认（输入新值以覆盖）');
      expect(hiddenDefaultSettingEditorValue('https://custom.example/v1', 'https://internal.example/v1'))
        .assertEqual('https://custom.example/v1');
    });

    it('migratesOldDefaultsWithoutOverwritingCustomValues', 0, () => {
      expect(migrateDefaultSettingValue('', 'new-default-key', [''], '')).assertEqual('new-default-key');
      expect(migrateDefaultSettingValue('old-default-key', 'new-default-key', [], 'old-default-key'))
        .assertEqual('new-default-key');
      expect(migrateDefaultSettingValue('custom-key', 'new-default-key', [''], 'old-default-key'))
        .assertEqual('custom-key');
    });

    it('resetsCloudOutputForFocusedPlannerTests', 0, () => {
      expect(buildCloudOutputLog('old log', '[now] 测试 Planner：http://127.0.0.1:9003', true, 60000))
        .assertEqual('[now] 测试 Planner：http://127.0.0.1:9003');
      expect(buildCloudOutputLog('old log', '[now] Planner 测试返回：ok', false, 60000))
        .assertEqual('old log\n[now] Planner 测试返回：ok');
    });

    it('exposesModelAndApiDefaultsForFreshInstall', 0, () => {
      expect(DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl).assertEqual('http://123.60.91.241:9003');
      expect(DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel).assertEqual('');
      expect(DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl).assertEqual('http://123.60.91.241:8080');
      expect(DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey).assertEqual('mobiagent-key');
      expect(DEFAULT_ENDPOINT_CONFIG.cloudDeciderApiKey).assertEqual('mobiagent-key');
      expect(DEFAULT_ENDPOINT_CONFIG.avatarImageModel).assertEqual('doubao-seedream-4-5-251128');
      expect(DEFAULT_ENDPOINT_CONFIG.avatarImageApiKey.length > 0).assertTrue();
      expect(DEFAULT_ENDPOINT_CONFIG.avatarImageResponseFormat).assertEqual('url');
      expect(DEFAULT_ENDPOINT_CONFIG.voiceTtsBaseUrl).assertEqual('https://api.xiaomimimo.com/v1');
      expect(DEFAULT_ENDPOINT_CONFIG.voiceTtsApiKey.length > 0).assertTrue();
      expect(DEFAULT_GALLERY_API_BASE_URL).assertEqual('https://api.modelbest.co/v1');
      expect(DEFAULT_GALLERY_API_KEY.length > 0).assertTrue();
      expect(DEFAULT_GALLERY_MODEL).assertEqual('MiniCPM-V-4.6-Instruct');
      expect(DEFAULT_GALLERY_EMBEDDING_BASE_URL).assertEqual('https://api.siliconflow.cn/v1');
      expect(DEFAULT_GALLERY_EMBEDDING_API_KEY.length > 0).assertTrue();
      expect(DEFAULT_GALLERY_EMBEDDING_MODEL).assertEqual('BAAI/bge-m3');
      expect(DEFAULT_GALLERY_AMAP_WEB_KEY.length > 0).assertTrue();
    });

    it('resolvesSeparatePlannerAndDeciderApiKeys', 0, () => {
      let config: CloudModelConfig = {
        plannerBaseUrl: 'http://planner',
        plannerModel: '',
        plannerApiKey: 'planner-key',
        deciderBaseUrl: 'http://decider',
        deciderApiKey: 'decider-key',
        apiKey: 'legacy-key',
        deciderModel: ''
      };
      expect(cloudPlannerApiKey(config)).assertEqual('planner-key');
      expect(cloudDeciderApiKey(config)).assertEqual('decider-key');

      let legacyConfig: CloudModelConfig = {
        plannerBaseUrl: 'http://planner',
        plannerModel: '',
        deciderBaseUrl: 'http://decider',
        apiKey: 'legacy-key',
        deciderModel: ''
      };
      expect(cloudPlannerApiKey(legacyConfig)).assertEqual('legacy-key');
      expect(cloudDeciderApiKey(legacyConfig)).assertEqual('legacy-key');
    });
  });
}
