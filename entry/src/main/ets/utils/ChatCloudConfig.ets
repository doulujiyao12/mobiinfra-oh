import {
  DEFAULT_ENDPOINT_CONFIG,
  configuredEndpointSecretOrDefault,
  configuredEndpointValueOrDefault
} from '../config/DefaultEndpointConfig';
import { CloudModelConfig } from './CloudModelClient';

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
  let legacyApiKey = configuredEndpointSecretOrDefault(AppStorage.get<string>('cloudApiKey') || '',
    DEFAULT_ENDPOINT_CONFIG.cloudApiKey);
  let plannerApiKey = configuredEndpointSecretOrDefault(AppStorage.get<string>('cloudPlannerApiKey') || '', legacyApiKey);
  let deciderApiKey = configuredEndpointSecretOrDefault(AppStorage.get<string>('cloudDeciderApiKey') || '', legacyApiKey);
  return {
    plannerBaseUrl: configuredEndpointValueOrDefault(AppStorage.get<string>('cloudPlannerBaseUrl') || '',
      DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl),
    plannerModel: configuredEndpointValueOrDefault(AppStorage.get<string>('cloudPlannerModel') || '',
      DEFAULT_ENDPOINT_CONFIG.cloudPlannerModel),
    plannerApiKey: plannerApiKey,
    deciderBaseUrl: configuredEndpointValueOrDefault(AppStorage.get<string>('cloudDeciderBaseUrl') || '',
      DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl),
    deciderApiKey: deciderApiKey,
    apiKey: plannerApiKey,
    deciderModel: configuredEndpointValueOrDefault(AppStorage.get<string>('cloudDeciderModel') || '',
      DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel)
  };
}
