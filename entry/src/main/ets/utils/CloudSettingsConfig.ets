import { configuredEndpointSecretOrDefault, configuredEndpointValueOrDefault } from '../config/DefaultEndpointConfig';
import { CloudModelConfig } from './CloudModelClient';
import { hiddenDefaultSettingEditorValue } from './DefaultSettingVisibility';
import { normalizeCloudChatUrl } from './CloudApiCompatibility';

export function sharedCloudSettingEditorValue(planner: string, decider: string,
  plannerDefault: string, deciderDefault: string): string {
  let first = hiddenDefaultSettingEditorValue(planner, plannerDefault).trim();
  let second = hiddenDefaultSettingEditorValue(decider, deciderDefault).trim();
  return first === second ? first : '';
}

export function cloudSettingValuesDiffer(planner: string, decider: string,
  plannerDefault: string, deciderDefault: string): boolean {
  return hiddenDefaultSettingEditorValue(planner, plannerDefault).trim() !==
    hiddenDefaultSettingEditorValue(decider, deciderDefault).trim();
}

export function cloudSettingsUseSeparateValues(config: CloudModelConfig, defaults: CloudModelConfig): boolean {
  return cloudSettingValuesDiffer(config.plannerBaseUrl, config.deciderBaseUrl, defaults.plannerBaseUrl, defaults.deciderBaseUrl) ||
    cloudSettingValuesDiffer(config.plannerModel, config.deciderModel, defaults.plannerModel, defaults.deciderModel) ||
    cloudSettingValuesDiffer(config.plannerApiKey || '', config.deciderApiKey || '',
      defaults.plannerApiKey || '', defaults.deciderApiKey || '');
}

export function updateUnifiedCloudSetting(config: CloudModelConfig, field: string, value: string): CloudModelConfig {
  let next: CloudModelConfig = {
    plannerBaseUrl: config.plannerBaseUrl, plannerModel: config.plannerModel, plannerApiKey: config.plannerApiKey,
    deciderBaseUrl: config.deciderBaseUrl, deciderModel: config.deciderModel, deciderApiKey: config.deciderApiKey,
    apiKey: config.apiKey
  };
  if (field === 'url') { next.plannerBaseUrl = value; next.deciderBaseUrl = value; }
  else if (field === 'model') { next.plannerModel = value; next.deciderModel = value; }
  else if (field === 'key') { next.plannerApiKey = value; next.deciderApiKey = value; next.apiKey = value; }
  else { throw new Error('Unsupported cloud setting field'); }
  return next;
}

function endpointKey(raw: string, legacy: string, endpoint: string, defaultUrl: string,
  defaultKey: string, defaultLegacyKey: string): string {
  if (normalizeCloudChatUrl(endpoint) === normalizeCloudChatUrl(defaultUrl)) {
    return configuredEndpointSecretOrDefault(raw, defaultKey);
  }
  // An explicitly cleared role key must not revive a previously entered shared key.
  if (raw.trim().length === 0) { return ''; }
  // Never send a built-in service credential to a newly configured provider.
  let explicitKey = configuredEndpointSecretOrDefault(raw, '');
  if (explicitKey && explicitKey !== defaultKey && explicitKey !== defaultLegacyKey) { return explicitKey; }
  let legacyKey = configuredEndpointSecretOrDefault(legacy, '');
  return legacyKey && legacyKey !== defaultLegacyKey ? legacyKey : '';
}

export function resolveCloudSettings(config: CloudModelConfig, defaults: CloudModelConfig): CloudModelConfig {
  let plannerUrl = configuredEndpointValueOrDefault(config.plannerBaseUrl, defaults.plannerBaseUrl);
  let deciderUrl = configuredEndpointValueOrDefault(config.deciderBaseUrl, defaults.deciderBaseUrl);
  let plannerKey = endpointKey(config.plannerApiKey || '', config.apiKey, plannerUrl, defaults.plannerBaseUrl,
    defaults.plannerApiKey || defaults.apiKey, defaults.apiKey);
  let deciderKey = endpointKey(config.deciderApiKey || '', config.apiKey, deciderUrl, defaults.deciderBaseUrl,
    defaults.deciderApiKey || defaults.apiKey, defaults.apiKey);
  return {
    plannerBaseUrl: plannerUrl, plannerModel: configuredEndpointValueOrDefault(config.plannerModel, defaults.plannerModel),
    plannerApiKey: plannerKey, deciderBaseUrl: deciderUrl,
    deciderModel: configuredEndpointValueOrDefault(config.deciderModel, defaults.deciderModel),
    deciderApiKey: deciderKey, apiKey: plannerKey
  };
}
