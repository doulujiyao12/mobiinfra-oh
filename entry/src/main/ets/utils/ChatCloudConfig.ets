import { DEFAULT_ENDPOINT_CONFIG } from '../config/DefaultEndpointConfig';
import { CloudModelConfig } from './CloudModelClient';
import { resolveCloudSettings } from './CloudSettingsConfig';

export function defaultChatCloudConfig(): CloudModelConfig {
  return {
    plannerBaseUrl: DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl, plannerModel: DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel,
    plannerApiKey: DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey, deciderBaseUrl: DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl,
    deciderModel: DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel, deciderApiKey: DEFAULT_ENDPOINT_CONFIG.cloudDeciderApiKey,
    apiKey: DEFAULT_ENDPOINT_CONFIG.cloudApiKey
  };
}

let storageInitialized: boolean = false;

// Both the chat page and the Agent Extension use the same persisted model settings.
export function initializeChatCloudConfigStorage(): void {
  if (storageInitialized) {
    return;
  }
  PersistentStorage.persistProp('cloudPlannerBaseUrl', DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl);
  PersistentStorage.persistProp('cloudPlannerModel', DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel);
  PersistentStorage.persistProp('cloudPlannerApiKey', DEFAULT_ENDPOINT_CONFIG.cloudPlannerApiKey);
  PersistentStorage.persistProp('cloudDeciderBaseUrl', DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl);
  PersistentStorage.persistProp('cloudDeciderApiKey', DEFAULT_ENDPOINT_CONFIG.cloudDeciderApiKey);
  PersistentStorage.persistProp('cloudApiKey', DEFAULT_ENDPOINT_CONFIG.cloudApiKey);
  PersistentStorage.persistProp('cloudDeciderModel', DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel);
  storageInitialized = true;
}

export function readChatCloudConfig(): CloudModelConfig {
  initializeChatCloudConfigStorage();
  let stored: CloudModelConfig = {
    plannerBaseUrl: AppStorage.get<string>('cloudPlannerBaseUrl') || '',
    plannerModel: AppStorage.get<string>('cloudPlannerModel') || '',
    plannerApiKey: AppStorage.get<string>('cloudPlannerApiKey') || '',
    deciderBaseUrl: AppStorage.get<string>('cloudDeciderBaseUrl') || '',
    deciderModel: AppStorage.get<string>('cloudDeciderModel') || '',
    deciderApiKey: AppStorage.get<string>('cloudDeciderApiKey') || '',
    apiKey: AppStorage.get<string>('cloudApiKey') || ''
  };
  return resolveCloudSettings(stored, defaultChatCloudConfig());
}
