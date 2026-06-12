import { promptAction, router } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import mnnllm from 'libentry.so';
import { CollectionPage } from './collection/CollectionPage';
import { ChatPage } from './chat/ChatPage';
import { CHAT_MODE_CLOUD_AGENT, chatInputAfterAcceptedSend } from './chat/ChatPageTypes';
import {
  CHAT_MESSAGE_KIND_CHAT,
  CHAT_MESSAGE_KIND_TASK_RESULT,
  CHAT_MESSAGE_KIND_TASK_TRACE,
  CHAT_MODE_LOCAL_INFERENCE,
  ChatMessage,
  ChatSessionRecord,
  ChatSessionSummary,
  buildCloudContextMessages,
  createChatMessage
} from './chat/ChatSessionTypes';
import { ChatSessionController, ChatSessionViewState } from './chat/ChatSessionController';
import { HomePage } from './home/HomePage';
import { mainTabIcon, mainTabLabel, MainTabIndex } from './main/MainTabConfig';
import { SettingsBackupController } from './settings/SettingsBackupController';
import { SettingsCenterPage } from './settings/SettingsCenterPage';
import { TaskPage } from './task/TaskPage';
import { AgentRouterServer } from '../utils/AgentRouterServer';
import { CloudModelClient, CloudModelConfig } from '../utils/CloudModelClient';
import {
  createEmptyCollectionViewModels,
  createEmptyHomeProfileViewModel,
  DataManagerFacade
} from '../datamanager/DataManagerFacade';
import {
  CollectionViewModel,
  DataManagerModelConfig,
  DataManagerProgress,
  HomeDomainViewModel,
  HomeProfileViewModel
} from '../datamanager/DataManagerTypes';
import {
  AvatarGenerateRequest,
  AvatarGenerationMode,
  AvatarHomeViewModel,
  AvatarProviderConfig,
  AvatarVersionViewModel
} from '../datamanager/avatar/AvatarTypes';
import { dataManagerError, dataManagerInfo, dataManagerWarn } from '../datamanager/DataManagerLog';
import { AgentExecutionController } from '../utils/AgentExecutionController';
import { AppLogger } from '../utils/AppLogger';
import { AgentLoopRunner } from '../utils/AgentLoopRunner';
import { WorkflowRunner } from '../utils/WorkflowRunner';
import { WorkflowStorage } from '../utils/WorkflowStorage';
import { WorkflowTask, WorkflowRunResult } from '../utils/WorkflowTypes';
import { showToastSafely } from '../utils/PromptSafe';
import { DEFAULT_ENDPOINT_CONFIG, LEGACY_ENDPOINT_CONFIG } from '../config/DefaultEndpointConfig';

// 首页总入口：负责把“数据归家”业务 UI、本地端侧推理、云端 Planner/Decider、
// 模型下载/调试工具和 PC 侧 HDC Agent 控制入口串起来。各业务 tab 的展示 UI
// 下沉到 home/collection/task，避免 Index.ets 继续膨胀。
const AUTO_HDC_SERVER_URL: string = 'http://127.0.0.1:19124';
const AUTO_HDC_REVERSE_HEALTH_RETRIES: number = 2;
const HDC_HEALTH_RETRY_DELAY_MS: number = 350;
const HDC_REVERSE_CONNECT_TIMEOUT_MS: number = 1500;
const HDC_REVERSE_READ_TIMEOUT_MS: number = 3000;
const HDC_SERVER_CONNECT_TIMEOUT_MS: number = 2500;
const HDC_SERVER_READ_TIMEOUT_MS: number = 5000;

interface ServerFile {
  name: string;
  size: number;
}

interface HdcConnectRequest {
  target: string;
  kill_others: boolean;
  prefer_wired: boolean;
}

interface HdcHealthResponse {
  status: string;
  message?: string;
  hdc_connected?: boolean;
  target?: string;
  tunnel_ready?: boolean;
  fport_ready?: boolean;
  rport_ready?: boolean;
  rport_listening?: boolean;
  rport_listen_check_supported?: boolean;
  app_server_url?: string;
  app_server_urls?: string[];
  pc_server_urls?: string[];
  loop_alive?: boolean;
}

interface HdcHealthAttempt {
  health: HdcHealthResponse | null;
  message: string;
}

interface HdcConnectAttempt {
  ok: boolean;
  responseCode: number;
  body: string;
  message: string;
  health?: HdcHealthResponse;
}

interface CloudAgentTaskSubmitResult {
  success: boolean;
  error: string;
}

type JsonValue = Object | string | number | boolean | null;
type JsonMap = Record<string, JsonValue>;

PersistentStorage.persistProp('wirelessIp', DEFAULT_ENDPOINT_CONFIG.wirelessHdcTarget);
PersistentStorage.persistProp('serverIp', DEFAULT_ENDPOINT_CONFIG.modelDownloadServerUrl);
PersistentStorage.persistProp('hdcServerIp', DEFAULT_ENDPOINT_CONFIG.hdcServerUrl);
PersistentStorage.persistProp('manualHdcServerIp', '');
PersistentStorage.persistProp('cloudPlannerBaseUrl', DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl);
PersistentStorage.persistProp('cloudDeciderBaseUrl', DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl);
PersistentStorage.persistProp('cloudApiKey', DEFAULT_ENDPOINT_CONFIG.cloudApiKey);
PersistentStorage.persistProp('cloudDeciderModel', DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel);
PersistentStorage.persistProp('avatarImageBaseUrl', DEFAULT_ENDPOINT_CONFIG.avatarImageBaseUrl);
PersistentStorage.persistProp('avatarImageApiKey', '');
PersistentStorage.persistProp('avatarTextToImageModel', DEFAULT_ENDPOINT_CONFIG.avatarImageModel);
PersistentStorage.persistProp('avatarImageToImageModel', DEFAULT_ENDPOINT_CONFIG.avatarImageModel);
PersistentStorage.persistProp('avatarImageSize', DEFAULT_ENDPOINT_CONFIG.avatarImageSize);
PersistentStorage.persistProp('avatarImageResponseFormat', DEFAULT_ENDPOINT_CONFIG.avatarImageResponseFormat);
PersistentStorage.persistProp('avatarImageOutputFormat', DEFAULT_ENDPOINT_CONFIG.avatarImageOutputFormat);
PersistentStorage.persistProp('avatarSequentialImageGeneration', 'disabled');
PersistentStorage.persistProp('avatarImageStream', false);
PersistentStorage.persistProp('avatarImageWatermark', DEFAULT_ENDPOINT_CONFIG.avatarImageWatermark);
PersistentStorage.persistProp('avatarImageTimeoutMs', 60000);
PersistentStorage.persistProp('endpointDefault.serverIp', '');
PersistentStorage.persistProp('endpointDefault.hdcServerIp', '');
PersistentStorage.persistProp('endpointDefault.wirelessIp', '');
PersistentStorage.persistProp('endpointDefault.cloudPlannerBaseUrl', '');
PersistentStorage.persistProp('endpointDefault.cloudDeciderBaseUrl', '');
PersistentStorage.persistProp('endpointDefault.cloudApiKey', '');
PersistentStorage.persistProp('endpointDefault.cloudDeciderModel', '');

@Entry
@Component
struct Index {
  @State output: string = '请先检查服务器连接';
  @State chatHistory: string = '';
  @State userInput: string = '';
  @State downloading: boolean = false;
  @State modelLoaded: boolean = false;
  @State connected: boolean = false;
  @State autoConfirm: boolean = true;
  @State debugImagePath: string = '';
  @State selectedModelVariant: string = '';
  @State customOppReady: boolean = false;
  @State threadNumInput: string = '4';
  @State backendTypeInput: string = 'cpu';
  @State mllmBackendTypeInput: string = 'cpu';
  @State currentTab: number = 0;
  @State chatMode: string = CHAT_MODE_CLOUD_AGENT;
  @State collectionModule: number = 0;
  @State taskScene: number = 0;
  @StorageLink('serverIp') serverIp: string = DEFAULT_ENDPOINT_CONFIG.modelDownloadServerUrl;
  @StorageLink('hdcServerIp') hdcServerIp: string = DEFAULT_ENDPOINT_CONFIG.hdcServerUrl;
  @StorageLink('manualHdcServerIp') manualHdcServerIp: string = '';
  @StorageLink('wirelessIp') wirelessIp: string = DEFAULT_ENDPOINT_CONFIG.wirelessHdcTarget;
  @StorageLink('cloudPlannerBaseUrl') cloudPlannerBaseUrl: string = DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl;
  @StorageLink('cloudDeciderBaseUrl') cloudDeciderBaseUrl: string = DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl;
  @StorageLink('cloudApiKey') cloudApiKey: string = DEFAULT_ENDPOINT_CONFIG.cloudApiKey;
  @StorageLink('cloudDeciderModel') cloudDeciderModel: string = DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel;
  @StorageLink('avatarImageBaseUrl') avatarImageBaseUrl: string = DEFAULT_ENDPOINT_CONFIG.avatarImageBaseUrl;
  @StorageLink('avatarImageApiKey') avatarImageApiKey: string = '';
  @StorageLink('avatarTextToImageModel') avatarTextToImageModel: string = DEFAULT_ENDPOINT_CONFIG.avatarImageModel;
  @StorageLink('avatarImageToImageModel') avatarImageToImageModel: string = DEFAULT_ENDPOINT_CONFIG.avatarImageModel;
  @StorageLink('avatarImageSize') avatarImageSize: string = DEFAULT_ENDPOINT_CONFIG.avatarImageSize;
  @StorageLink('avatarImageResponseFormat') avatarImageResponseFormat: string = DEFAULT_ENDPOINT_CONFIG.avatarImageResponseFormat;
  @StorageLink('avatarImageOutputFormat') avatarImageOutputFormat: string = DEFAULT_ENDPOINT_CONFIG.avatarImageOutputFormat;
  @StorageLink('avatarSequentialImageGeneration') avatarSequentialImageGeneration: string = 'disabled';
  @StorageLink('avatarImageStream') avatarImageStream: boolean = false;
  @StorageLink('avatarImageWatermark') avatarImageWatermark: boolean = DEFAULT_ENDPOINT_CONFIG.avatarImageWatermark;
  @StorageLink('avatarImageTimeoutMs') avatarImageTimeoutMs: number = 60000;
  @State isThinking: boolean = false;
  @State cloudOutput: string = '请先配置 Planner 和 Decider 云端服务';
  @State cloudUserInput: string = '';
  @State cloudDebugImagePath: string = '';
  private cloudTaskSessionId: string = '';
  private localTaskSessionId: string = '';
  @State cloudAutoConfirm: boolean = true;
  @State cloudThinking: boolean = false;
  @State chatSessions: ChatSessionSummary[] = [];
  @State activeChatSessionId: string = '';
  @State activeChatMessages: ChatMessage[] = [];
  @State chatSessionDrawerOpen: boolean = false;
  @State restoringLocalSession: boolean = false;
  @State hdcConnected: boolean = false;
  @State hdcUsingReverseTunnel: boolean = false;
  @State hdcAutoConnected: boolean = false;
  @State hdcAutoConnecting: boolean = false;
  @State hdcManualPairing: boolean = false;
  @State hdcAutoStatus: string = 'HDC Server will be auto-discovered after startup.';
  @State dataManagerRefreshing: boolean = false;
  @State dataManagerProgressStage: string = '准备';
  @State dataManagerProgressMessage: string = '准备整理数据';
  @State dataManagerProgressPercent: number = 0;
  @State homeProfile: HomeProfileViewModel = createEmptyHomeProfileViewModel();
  @State collectionViews: CollectionViewModel[] = createEmptyCollectionViewModels();
  @State avatarVersions: AvatarVersionViewModel[] = [];
  @State backupBusy: boolean = false;
  @State backupStatus: string = '尚未执行备份操作';

  private filesDir: string = '';
  private modelDir: string = '';
  private serverFiles: ServerFile[] = [];
  private totalBytesAll: number = 0;
  private dataManagerFacade: DataManagerFacade | null = null;
  private homeRecommendationViewDateKey: string = '';
  private homeRecommendationDateTimerId: number = -1;

  // PC 控制服务端单例。AgentRouterServer 在本地模型和云端模型之间切换同一个 9126 入口。
  private agentRouter: AgentRouterServer = new AgentRouterServer();
  private activeAgentRunner: AgentLoopRunner | null = null;
  private cloudClient: CloudModelClient = new CloudModelClient();

  private nextChatMessageId(prefix: string = 'msg'): string {
    return prefix + '-' + String(new Date().getTime()) + '-' + String(this.activeChatMessages.length + 1);
  }

  private currentChatSessionViewState(): ChatSessionViewState {
    return {
      sessions: this.chatSessions,
      activeSessionId: this.activeChatSessionId,
      activeMessages: this.activeChatMessages,
      mode: this.chatMode,
      activeSession: null
    };
  }

  private applyChatSessionViewState(state: ChatSessionViewState): void {
    this.chatSessions = state.sessions;
    this.activeChatSessionId = state.activeSessionId;
    this.activeChatMessages = state.activeMessages;
    this.chatMode = state.mode;
  }

  private initChatSessions(): void {
    this.applyChatSessionViewState(ChatSessionController.init(this.filesDir, this.chatMode));
  }

  private ensureActiveChatSession(): ChatSessionRecord | null {
    let state = ChatSessionController.ensureActive(this.filesDir, this.currentChatSessionViewState(), this.chatMode);
    this.applyChatSessionViewState(state);
    return state.activeSession;
  }

  private appendActiveChatMessage(message: ChatMessage): void {
    let state = ChatSessionController.appendMessage(this.filesDir, this.currentChatSessionViewState(), this.chatMode,
      message);
    this.applyChatSessionViewState(state);
  }

  private appendChatMessageForSession(sessionId: string, message: ChatMessage): void {
    let state = ChatSessionController.appendMessageToSession(this.filesDir, this.currentChatSessionViewState(),
      this.taskSessionId(sessionId), message);
    this.applyChatSessionViewState(state);
  }

  private appendActiveTaskTraceLine(line: string, messageId: string = ''): void {
    let state = ChatSessionController.appendTaskTraceLine(this.filesDir, this.currentChatSessionViewState(),
      this.chatMode, line, messageId);
    this.applyChatSessionViewState(state);
  }

  private attachTaskResultImage(sessionId: string, imagePath: string): void {
    let state = ChatSessionController.attachTaskResultImage(this.filesDir, this.currentChatSessionViewState(),
      sessionId, imagePath);
    this.applyChatSessionViewState(state);
  }

  private compactTraceText(text: string, maxLength: number = 180): string {
    let compact = text.trim().replace(/\s+/g, ' ');
    if (compact.length <= maxLength) {
      return compact;
    }
    return compact.substring(0, maxLength) + '...';
  }

  private extractJsonObjectText(text: string): string {
    let start = text.indexOf('{');
    let end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return '';
    }
    return text.substring(start, end + 1);
  }

  private parseAgentResponsePayload(message: string): JsonMap | null {
    if (message.indexOf('model response') < 0) {
      return null;
    }
    let jsonText = this.extractJsonObjectText(message);
    if (jsonText.length === 0) {
      return null;
    }
    try {
      return ArkJSON.parse(jsonText) as JsonMap;
    } catch (e) {
      return null;
    }
  }

  private jsonStringValue(map: JsonMap, key: string): string {
    let value = map[key];
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    return '';
  }

  private jsonMapValue(map: JsonMap, key: string): JsonMap | null {
    let value = map[key];
    if (value !== null && typeof value === 'object') {
      return value as JsonMap;
    }
    return null;
  }

  private agentActionTarget(payload: JsonMap): string {
    let params = this.jsonMapValue(payload, 'parameters');
    if (params === null) {
      return '';
    }
    let target = this.jsonStringValue(params, 'target_element');
    if (target.length === 0) {
      target = this.jsonStringValue(params, 'app_name');
    }
    if (target.length === 0) {
      target = this.jsonStringValue(params, 'package_name');
    }
    if (target.length === 0) {
      target = this.jsonStringValue(params, 'target');
    }
    let text = this.jsonStringValue(params, 'text');
    if (target.length > 0 && text.length > 0) {
      return target + '，输入：' + text;
    }
    if (target.length === 0 && text.length > 0) {
      return text;
    }
    return target;
  }

  private formatAgentTraceLog(message: string): string {
    let payload = this.parseAgentResponsePayload(message);
    if (payload === null) {
      return '';
    }
    let action = this.jsonStringValue(payload, 'action');
    if (action.length === 0) {
      return '';
    }
    let reasoning = this.jsonStringValue(payload, 'reasoning');
    if (reasoning.length === 0) {
      reasoning = this.jsonStringValue(payload, 'reason');
    }
    let target = this.agentActionTarget(payload);
    let lines: string[] = [];
    if (reasoning.length > 0) {
      lines.push('Reasoning：' + this.compactTraceText(reasoning));
    }
    lines.push('动作：' + action);
    if (target.length > 0) {
      lines.push('目标：' + this.compactTraceText(target, 120));
    }
    return lines.join('\n');
  }

  private toFileUri(path: string): string {
    if (path.startsWith('file://')) {
      return path;
    }
    return 'file://' + path;
  }

  private snapshotImagePathFromLog(message: string): string {
    let taggedMatch = message.match(/<img>(.*?)<hw>/);
    if (taggedMatch && taggedMatch[1]) {
      return this.toFileUri(taggedMatch[1]);
    }
    let absoluteMatch = message.match(/(\/[^\s]+agent_snapshot_[^\s]+\.jpg)/);
    if (absoluteMatch && absoluteMatch[1]) {
      return this.toFileUri(absoluteMatch[1]);
    }
    let fileNameMatch = message.match(/agent_snapshot_.*?\.jpg/);
    if (fileNameMatch && fileNameMatch[0]) {
      return this.toFileUri(this.filesDir + '/' + fileNameMatch[0]);
    }
    return '';
  }

  private taskSessionId(fallbackId: string): string {
    return fallbackId.length > 0 ? fallbackId : this.activeChatSessionId;
  }

  private appendTaskTraceLineForSession(sessionId: string, line: string, messageId: string = ''): void {
    let state = ChatSessionController.appendTaskTraceLineToSession(this.filesDir, this.currentChatSessionViewState(),
      this.taskSessionId(sessionId), line, messageId);
    this.applyChatSessionViewState(state);
  }

  private handleLocalAgentLog(message: string): void {
    AppLogger.info('LocalAgent', message);
    this.output = message;
    let sessionId = this.taskSessionId(this.localTaskSessionId);
    let traceLine = this.formatAgentTraceLog(message);
    if (traceLine.length > 0) {
      this.appendTaskTraceLineForSession(sessionId, traceLine);
    }
    let imagePath = this.snapshotImagePathFromLog(message);
    if (imagePath.length > 0) {
      this.debugImagePath = imagePath;
    }
  }

  private handleCloudAgentLog(message: string): void {
    this.appendCloudLog(message);
    let imagePath = this.snapshotImagePathFromLog(message);
    if (imagePath.length > 0) {
      this.cloudDebugImagePath = imagePath;
    }
  }

  private createChatSession(mode: string): void {
    let state = ChatSessionController.createSession(this.filesDir, this.currentChatSessionViewState(), mode);
    this.applyChatSessionViewState(state);
    this.chatSessionDrawerOpen = false;
    if (state.activeSession !== null && state.activeSession.mode === CHAT_MODE_LOCAL_INFERENCE && this.modelLoaded) {
      try {
        mnnllm.reset();
      } catch (e) {
        let err = e as Error;
        this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('system'), 'system',
          CHAT_MESSAGE_KIND_CHAT, '本地上下文清理失败：' + err.message, new Date().getTime()));
      }
    }
  }

  private async selectChatSession(sessionId: string): Promise<void> {
    if (this.cloudThinking || this.isThinking || this.restoringLocalSession) {
      showToastSafely('当前会话处理中，稍后再切换', 1500);
      return;
    }
    let state = ChatSessionController.selectSession(this.filesDir, this.currentChatSessionViewState(), sessionId);
    this.applyChatSessionViewState(state);
    if (state.activeSession === null || state.activeSession.id !== sessionId) {
      showToastSafely('会话文件不存在，已从列表移除', 1500);
      return;
    }
    this.chatSessionDrawerOpen = false;
    if (state.activeSession.mode === CHAT_MODE_LOCAL_INFERENCE) {
      await this.restoreLocalChatContext(state.activeSession);
    }
  }

  private async switchChatMode(mode: string): Promise<void> {
    if (this.chatMode === mode && this.activeChatSessionId.length > 0) {
      return;
    }
    let state = ChatSessionController.switchMode(this.filesDir, this.currentChatSessionViewState(), mode);
    this.applyChatSessionViewState(state);
    this.chatSessionDrawerOpen = false;
    if (state.activeSession !== null && state.activeSession.mode === CHAT_MODE_LOCAL_INFERENCE) {
      await this.restoreLocalChatContext(state.activeSession);
    }
  }

  private async confirmDeleteChatSession(session: ChatSessionSummary): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      promptAction.showDialog({
        title: '删除会话',
        message: '将删除“' + session.title + '”及其对应文件，此操作不可恢复。',
        buttons: [
          { text: '取消', color: '#666666' },
          { text: '删除', color: '#FF4D4F' }
        ]
      }).then((data: promptAction.ShowDialogSuccessResponse) => {
        resolve(data.index === 1);
      }).catch(() => {
        resolve(false);
      });
    });
  }

  private chatSessionExistsInState(state: ChatSessionViewState, sessionId: string): boolean {
    for (let i = 0; i < state.sessions.length; i++) {
      if (state.sessions[i].id === sessionId) {
        return true;
      }
    }
    return false;
  }

  private async deleteChatSession(sessionId: string): Promise<void> {
    let target: ChatSessionSummary | null = null;
    for (let i = 0; i < this.chatSessions.length; i++) {
      if (this.chatSessions[i].id === sessionId) {
        target = this.chatSessions[i];
        break;
      }
    }
    if (target !== null) {
      let confirmed = await this.confirmDeleteChatSession(target);
      if (!confirmed) {
        return;
      }
    }
    let state = ChatSessionController.deleteSession(this.filesDir, this.currentChatSessionViewState(), sessionId,
      this.chatMode);
    this.applyChatSessionViewState(state);
    if (this.chatSessionExistsInState(state, sessionId)) {
      showToastSafely('删除会话失败', 1500);
      return;
    }
    if (state.activeSession !== null && state.activeSession.mode === CHAT_MODE_LOCAL_INFERENCE) {
      await this.restoreLocalChatContext(state.activeSession);
    }
    showToastSafely('会话已删除', 1500);
  }

  private toggleActiveTaskTrace(messageId: string): void {
    let state = ChatSessionController.toggleTaskTrace(this.filesDir, this.currentChatSessionViewState(), messageId);
    this.applyChatSessionViewState(state);
  }

  private async restoreLocalChatContext(session: ChatSessionRecord): Promise<void> {
    if (!this.modelLoaded) {
      return;
    }
    this.restoringLocalSession = true;
    try {
      mnnllm.reset();
      for (let i = 0; i < session.messages.length; i++) {
        let message = session.messages[i];
        if (message.role === 'user' && message.kind === CHAT_MESSAGE_KIND_CHAT) {
          await mnnllm.chat(message.content);
        }
      }
    } catch (e) {
      let err = e as Error;
      this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('system'), 'system', CHAT_MESSAGE_KIND_CHAT,
        '本地上下文恢复失败：' + err.message, new Date().getTime()));
    } finally {
      this.restoringLocalSession = false;
    }
  }

  // 云端 Agent 日志会同步写入 AppStorage，便于日志页/浮窗读取最近状态。
  private appendCloudLog(message: string): void {
    AppLogger.info('CloudAgent', message);
    let stamp = new Date().toLocaleTimeString();
    let line = `[${stamp}] ${message}`;
    let nextLogs = this.cloudOutput.length > 0 ? this.cloudOutput + '\n' + line : line;
    if (nextLogs.length > 60000) {
      nextLogs = nextLogs.substring(nextLogs.length - 60000);
    }
    this.cloudOutput = nextLogs;
    AppStorage.setOrCreate('cloudAgentLogs', this.cloudOutput);
    let traceLine = this.formatAgentTraceLog(message);
    if (traceLine.length > 0) {
      this.appendTaskTraceLineForSession(this.cloudTaskSessionId, traceLine);
    }
    if (message.indexOf('Task completed') >= 0) {
      this.appendChatMessageForSession(this.cloudTaskSessionId,
        createChatMessage(this.nextChatMessageId('task-result'), 'task',
          CHAT_MESSAGE_KIND_TASK_RESULT, '任务执行完成。', new Date().getTime()));
    }
  }

  private resetCloudLog(message: string): void {
    AppLogger.info('CloudAgent', message);
    let stamp = new Date().toLocaleTimeString();
    this.cloudOutput = `[${stamp}] ${message}`;
    AppStorage.setOrCreate('cloudAgentLogs', this.cloudOutput);
  }

  private async approveLocalAgentResponse(response: string): Promise<boolean> {
    if (this.autoConfirm) {
      return true;
    }
    return new Promise<boolean>((resolve) => {
      promptAction.showDialog({
        title: '大模型返回确认',
        message: '模型推理结果：\n' + response + '\n\n是否同意执行？',
        buttons: [
          { text: '拒绝', color: '#ff0000' },
          { text: '同意', color: '#00cc00' }
        ]
      }).then((data: promptAction.ShowDialogSuccessResponse) => {
        resolve(data.index === 1);
      }).catch(() => {
        resolve(false);
      });
    });
  }

  private async approveCloudAgentResponse(response: string): Promise<boolean> {
    if (this.cloudAutoConfirm) {
      this.appendCloudLog('自动同意已开启，模型动作已放行给 App 内 Agent loop 执行。');
      return true;
    }
    this.appendCloudLog('等待用户确认模型动作。确认后 App 会通过 PC HDC bridge 执行动作。');
    return new Promise<boolean>((resolve) => {
      promptAction.showDialog({
        title: '云端模型返回确认',
        message: '模型推理结果:\n' + response + '\n\n是否同意执行？',
        buttons: [
          { text: '拒绝', color: '#ff0000' },
          { text: '同意', color: '#00cc00' }
        ]
      }).then((data: promptAction.ShowDialogSuccessResponse) => {
        let approved = data.index === 1;
        this.appendCloudLog(approved ? '用户已同意，动作交给 HDC bridge 执行。' : '用户已拒绝，任务终止。');
        resolve(approved);
      }).catch(() => {
        this.appendCloudLog('确认弹窗关闭或失败，动作按拒绝处理。');
        resolve(false);
      });
    });
  }

  private getDataManagerModelConfig(): DataManagerModelConfig {
    return {
      baseUrl: this.cloudPlannerBaseUrl,
      apiKey: this.cloudApiKey,
      enabled: this.cloudPlannerBaseUrl.trim().length > 0
    };
  }

  private getAvatarProviderConfig(): AvatarProviderConfig {
    let textModel = this.avatarTextToImageModel.trim().length > 0 ? this.avatarTextToImageModel :
      DEFAULT_ENDPOINT_CONFIG.avatarImageModel;
    let imageModel = this.avatarImageToImageModel.trim().length > 0 ? this.avatarImageToImageModel : textModel;
    return {
      imageBaseUrl: this.avatarImageBaseUrl.trim().length > 0 ? this.avatarImageBaseUrl :
        DEFAULT_ENDPOINT_CONFIG.avatarImageBaseUrl,
      apiKey: this.avatarImageApiKey,
      textToImageModel: textModel,
      imageToImageModel: imageModel,
      size: this.avatarImageSize.trim().length > 0 ? this.avatarImageSize : DEFAULT_ENDPOINT_CONFIG.avatarImageSize,
      responseFormat: this.avatarImageResponseFormat.trim().length > 0 ? this.avatarImageResponseFormat :
        DEFAULT_ENDPOINT_CONFIG.avatarImageResponseFormat,
      outputFormat: this.avatarImageOutputFormat.trim().length > 0 ? this.avatarImageOutputFormat :
        DEFAULT_ENDPOINT_CONFIG.avatarImageOutputFormat,
      sequentialImageGeneration: this.avatarSequentialImageGeneration.trim().length > 0 ?
        this.avatarSequentialImageGeneration : 'disabled',
      stream: this.avatarImageStream,
      watermark: this.avatarImageWatermark,
      timeoutMs: this.avatarImageTimeoutMs > 0 ? this.avatarImageTimeoutMs : 60000
    };
  }

  private mergeHomeAvatarView(avatar: AvatarHomeViewModel): void {
    this.homeProfile = {
      avatarUri: avatar.avatarUri,
      avatarStatus: avatar.avatarStatus,
      avatarUpdatedLabel: avatar.avatarUpdatedLabel,
      avatarActionLabel: avatar.avatarActionLabel,
      avatarVersionId: avatar.avatarVersionId,
      updatedLabel: this.homeProfile.updatedLabel,
      completeness: this.homeProfile.completeness,
      totalEvents: this.homeProfile.totalEvents,
      domains: this.homeProfile.domains,
      recommendations: this.homeProfile.recommendations,
      empty: this.homeProfile.empty
    };
  }

  private async confirmUnchangedAvatarRegeneration(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      promptAction.showDialog({
        title: '画像未变化',
        message: '当前画像内容与上次生成数字分身时一致，继续生成可能会得到相似结果。是否仍要重新生成？',
        buttons: [
          { text: '取消', color: '#666666' },
          { text: '继续生成', color: '#8066FF' }
        ]
      }).then((data: promptAction.ShowDialogSuccessResponse) => {
        resolve(data.index === 1);
      }).catch(() => {
        resolve(false);
      });
    });
  }

  private async avatarProviderSourceImage(mode: AvatarGenerationMode, sourceImage: string): Promise<string> {
    if (mode !== 'image_to_image') {
      return '';
    }
    let normalized = sourceImage.trim();
    if (normalized.length === 0) {
      throw new Error('请先选择参考照片');
    }
    if (normalized.startsWith('data:image/') || normalized.startsWith('http://') || normalized.startsWith('https://')) {
      return normalized;
    }
    return await this.imageUriToJpegDataUrl(normalized);
  }

  private async imageUriToJpegDataUrl(uri: string): Promise<string> {
    let imageFile: fileIo.File | null = null;
    let imageSource: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      imageFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      imageSource = image.createImageSource(imageFile.fd);
      pixelMap = await imageSource.createPixelMap();
      packer = image.createImagePacker();
      let data = await packer.packToData(pixelMap, {
        format: 'image/jpeg',
        quality: 90
      });
      let helper = new util.Base64Helper();
      return 'data:image/jpeg;base64,' + helper.encodeToStringSync(new Uint8Array(data));
    } catch (e) {
      let err = e as Error;
      throw err;
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (e) {
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (e) {
        }
      }
      if (imageSource !== null) {
        try {
          await imageSource.release();
        } catch (e) {
        }
      }
      if (imageFile !== null) {
        try {
          await fileIo.close(imageFile);
        } catch (e) {
        }
      }
    }
  }

  private async generateHomeAvatar(mode: AvatarGenerationMode, sourceImage: string): Promise<void> {
    if (this.dataManagerFacade === null) {
      dataManagerWarn('generateHomeAvatar skipped: facade is null');
      showToastSafely('数据管理服务未就绪', 1500);
      throw new Error('数据管理服务未就绪');
    }
    if (this.dataManagerFacade.isAvatarProfileSnapshotUnchanged()) {
      let confirmed = await this.confirmUnchangedAvatarRegeneration();
      if (!confirmed) {
        dataManagerInfo('generateHomeAvatar cancelled: profile snapshot unchanged');
        throw new Error('已取消生成');
      }
    }
    let config = this.getAvatarProviderConfig();
    if (config.apiKey.trim().length === 0) {
      dataManagerWarn('generateHomeAvatar skipped: missing avatar api key');
      showToastSafely('请先配置数字分身图片 API Key', 1800);
      throw new Error('缺少数字分身图片 API Key');
    }
    dataManagerInfo(`generateHomeAvatar start: mode=${mode}, baseUrl=${config.imageBaseUrl}, model=${config.textToImageModel}`);
    try {
      let providerSourceImage = await this.avatarProviderSourceImage(mode, sourceImage);
      let request: AvatarGenerateRequest =
        this.dataManagerFacade.buildAvatarGenerateRequest(mode, providerSourceImage, new Date().toISOString(), sourceImage);
      let avatar = await this.dataManagerFacade.generateAvatar(config, request);
      this.mergeHomeAvatarView(avatar);
      this.reloadDataManagerViewModels();
      showToastSafely('数字分身已生成', 1500);
      dataManagerInfo(`generateHomeAvatar success: version=${avatar.avatarVersionId}`);
    } catch (e) {
      let err = e as Error;
      this.reloadDataManagerViewModels();
      dataManagerError('generateHomeAvatar failed: ' + err.message);
      this.appendCloudLog('Avatar generation failed: ' + err.message);
      showToastSafely('数字分身生成失败：' + err.message, 2200);
      throw err;
    }
  }

  private initDataManager(): void {
    if (this.filesDir.length === 0) {
      dataManagerWarn('initDataManager skipped: filesDir is empty');
      return;
    }
    dataManagerInfo('initDataManager start: filesDir=' + this.filesDir);
    this.dataManagerFacade = new DataManagerFacade(this.filesDir);
    this.dataManagerFacade.ensureReady();
    this.reloadDataManagerViewModels();
    dataManagerInfo('initDataManager done');
  }

  private reloadDataManagerViewModels(): void {
    if (this.dataManagerFacade === null) {
      dataManagerWarn('reloadDataManagerViewModels skipped: facade is null');
      return;
    }
    this.homeProfile = this.dataManagerFacade.loadHomeViewModel();
    this.collectionViews = this.dataManagerFacade.loadCollectionViewModels();
    this.homeRecommendationViewDateKey = this.currentLocalDateKey();
    this.avatarVersions = this.dataManagerFacade.listAvatarVersions();
    dataManagerInfo(`reloadDataManagerViewModels done: homeEvents=${this.homeProfile.totalEvents}, domains=${this.homeProfile.domains.map((item: HomeDomainViewModel) => item.domain + ':' + item.desc).join('|')}, collectionTabs=${this.collectionViews.length}`);
  }

  private padDatePart(value: number): string {
    return value < 10 ? '0' + String(value) : String(value);
  }

  private currentLocalDateKey(): string {
    let date = new Date();
    return `${date.getFullYear()}-${this.padDatePart(date.getMonth() + 1)}-${this.padDatePart(date.getDate())}`;
  }

  private reloadHomeViewModelIfDateChanged(): void {
    let today = this.currentLocalDateKey();
    if (this.homeRecommendationViewDateKey === today) {
      return;
    }
    if (this.dataManagerFacade === null) {
      dataManagerWarn('reloadHomeViewModelIfDateChanged skipped: facade is null');
      return;
    }
    this.homeProfile = this.dataManagerFacade.loadHomeViewModel();
    this.homeRecommendationViewDateKey = today;
    dataManagerInfo(`home recommendation view date changed: today=${today}, recommendations=${this.homeProfile.recommendations.length}`);
  }

  private startHomeRecommendationDateTimer(): void {
    if (this.homeRecommendationDateTimerId !== -1) {
      return;
    }
    this.homeRecommendationDateTimerId = setInterval(() => {
      this.reloadHomeViewModelIfDateChanged();
    }, 60 * 1000);
  }

  private stopHomeRecommendationDateTimer(): void {
    if (this.homeRecommendationDateTimerId !== -1) {
      clearInterval(this.homeRecommendationDateTimerId);
      this.homeRecommendationDateTimerId = -1;
    }
  }

  private updateDataManagerProgress(progress: DataManagerProgress): void {
    this.dataManagerProgressStage = progress.percent < 60 ? '正在整理日志' : '正在构建索引';
    this.dataManagerProgressMessage = progress.message;
    this.dataManagerProgressPercent = Math.max(0, Math.min(100, progress.percent));
  }

  private async refreshDataManager(): Promise<void> {
    dataManagerInfo(`refreshDataManager invoked: hasFacade=${this.dataManagerFacade !== null}, refreshing=${this.dataManagerRefreshing}`);
    if (this.dataManagerFacade === null) {
      dataManagerWarn('refreshDataManager skipped: facade is null');
      return;
    }
    if (this.dataManagerRefreshing) {
      dataManagerWarn('refreshDataManager skipped: already refreshing');
      return;
    }
    if (!this.dataManagerFacade.hasDailyLogData()) {
      dataManagerInfo('refreshDataManager skipped: no daily-log data');
      showToastSafely('暂无数据', 1500);
      return;
    }
    this.dataManagerRefreshing = true;
    this.dataManagerProgressStage = '正在整理日志';
    this.dataManagerProgressMessage = '';
    this.dataManagerProgressPercent = 0;
    try {
      let modelConfig = this.getDataManagerModelConfig();
      dataManagerInfo(`refreshDataManager start: modelEnabled=${modelConfig.enabled}, baseUrl=${modelConfig.baseUrl}`);
      let summary = await this.dataManagerFacade.refresh(modelConfig, (progress: DataManagerProgress) => {
        this.updateDataManagerProgress(progress);
      });
      this.reloadDataManagerViewModels();
      this.appendCloudLog('DataManager refresh: ' + summary.message);
      this.dataManagerProgressStage = '完成';
      this.dataManagerProgressMessage = summary.message;
      this.dataManagerProgressPercent = 100;
      if (summary.skipped) {
        showToastSafely('已是最新数据', 1500);
      }
      dataManagerInfo('refreshDataManager success: ' + summary.message);
    } catch (e) {
      let err = e as Error;
      this.appendCloudLog('DataManager refresh failed: ' + err.message);
      this.dataManagerProgressStage = '失败';
      this.dataManagerProgressMessage = '整理失败: ' + err.message;
      this.dataManagerProgressPercent = 100;
      dataManagerError('refreshDataManager failed: ' + err.message);
    } finally {
      this.dataManagerRefreshing = false;
      dataManagerInfo('refreshDataManager finished');
    }
  }

  aboutToAppear() {
    // 页面启动时先修正旧版本持久化默认值，再初始化模型目录、日志捕获、自定义算子和 Agent 路由。
    this.migrateDefaultEndpointValues();
    if (this.manualHdcServerIp.trim().length === 0 && !this.isAutoHdcUrl(this.hdcServerIp)) {
      this.manualHdcServerIp = this.hdcServerIp;
    }
    let ctx = getContext(this) as common.UIAbilityContext;
    this.filesDir = ctx.filesDir;
    dataManagerInfo('Index aboutToAppear: filesDir=' + this.filesDir);
    this.syncModelDir();
    try {
      mnnllm.initLogFile(this.filesDir + '/mnn_runtime.log');
    } catch (e) {
      AppLogger.errorCause('NativeRuntime', 'initLogFile failed', e as Error);
    }
    this.prepareCustomOpp();
    this.initDataManager();
    this.initChatSessions();
    this.startHomeRecommendationDateTimer();
    this.agentRouter.configureLocal(
      (prefix: string): Promise<string> => mnnllm.agentPrefill(prefix),
      (variablePart: string, onToken?: (token: string) => void): Promise<string> =>
        mnnllm.agentStep(variablePart, onToken),
      (): Promise<string> => mnnllm.agentReset(),
      (userMessage: string): Promise<string> => mnnllm.chat(userMessage),
      (): string => mnnllm.reset(),
      (msg: string) => {
        this.handleLocalAgentLog(msg);
      }, async (response: string) => {
        return await this.approveLocalAgentResponse(response);
      });
    this.agentRouter.configureCloud(this.cloudClient, () => this.getCloudConfig(), (msg: string) => {
      this.handleCloudAgentLog(msg);
    }, async (response: string) => {
      return await this.approveCloudAgentResponse(response);
    });
    // 浮窗终止按钮只发取消信号；真正的模型上下文清理由当前路由的 LlmServer 完成。
    AgentExecutionController.registerLocalCancelHandler(async () => {
      if (this.activeAgentRunner !== null && this.activeAgentRunner.getMode() === 'local') {
        await this.activeAgentRunner.requestCancellation();
        this.output = '用户已通过悬浮窗终止本地 Agent 任务。';
        return;
      }
      if (this.agentRouter.getRouteMode() !== 'local') {
        return;
      }
      await this.agentRouter.requestTaskCancellation();
      this.output = '用户已通过悬浮窗终止本地 Agent 任务。';
    });
    AgentExecutionController.registerCloudCancelHandler(async () => {
      if (this.activeAgentRunner !== null && this.activeAgentRunner.getMode() === 'cloud') {
        await this.activeAgentRunner.requestCancellation();
        this.appendCloudLog('用户已通过悬浮窗终止云端 Agent 任务。');
        return;
      }
      if (this.agentRouter.getRouteMode() !== 'cloud') {
        return;
      }
      await this.agentRouter.requestTaskCancellation();
      this.appendCloudLog('用户已通过悬浮窗终止云端 Agent 任务。');
    });
    this.discoverHdcServer(false, false).catch(() => {
      this.hdcAutoConnecting = false;
    });
  }

  onPageShow(): void {
    this.reloadHomeViewModelIfDateChanged();
    this.startHomeRecommendationDateTimer();
  }

  onPageHide(): void {
    this.stopHomeRecommendationDateTimer();
  }

  aboutToDisappear(): void {
    this.stopHomeRecommendationDateTimer();
  }

  private migrateDefaultEndpointValues(): void {
    // 兼容历史版本写入 PersistentStorage 的默认地址，并跟踪上一次应用的默认值。
    this.serverIp = this.migrateEndpointValue(this.serverIp, DEFAULT_ENDPOINT_CONFIG.modelDownloadServerUrl,
      LEGACY_ENDPOINT_CONFIG.modelDownloadServerUrls, 'endpointDefault.serverIp');
    this.hdcServerIp = this.migrateEndpointValue(this.hdcServerIp, DEFAULT_ENDPOINT_CONFIG.hdcServerUrl,
      LEGACY_ENDPOINT_CONFIG.hdcServerUrls, 'endpointDefault.hdcServerIp');
    this.wirelessIp = this.migrateEndpointValue(this.wirelessIp, DEFAULT_ENDPOINT_CONFIG.wirelessHdcTarget,
      LEGACY_ENDPOINT_CONFIG.wirelessHdcTargets, 'endpointDefault.wirelessIp');
    this.cloudPlannerBaseUrl = this.migrateEndpointValue(this.cloudPlannerBaseUrl, DEFAULT_ENDPOINT_CONFIG.cloudPlannerBaseUrl,
      LEGACY_ENDPOINT_CONFIG.cloudPlannerBaseUrls, 'endpointDefault.cloudPlannerBaseUrl');
    this.cloudDeciderBaseUrl = this.migrateEndpointValue(this.cloudDeciderBaseUrl, DEFAULT_ENDPOINT_CONFIG.cloudDeciderBaseUrl,
      LEGACY_ENDPOINT_CONFIG.cloudDeciderBaseUrls, 'endpointDefault.cloudDeciderBaseUrl');
    this.cloudApiKey = this.migrateEndpointValue(this.cloudApiKey, DEFAULT_ENDPOINT_CONFIG.cloudApiKey,
      LEGACY_ENDPOINT_CONFIG.cloudApiKeys, 'endpointDefault.cloudApiKey');
    this.cloudDeciderModel = this.migrateEndpointValue(this.cloudDeciderModel, DEFAULT_ENDPOINT_CONFIG.cloudDeciderModel,
      LEGACY_ENDPOINT_CONFIG.cloudDeciderModels, 'endpointDefault.cloudDeciderModel', false);
  }

  private migrateEndpointValue(currentValue: string, configuredDefault: string, legacyDefaults: string[],
    snapshotKey: string, treatEmptyAsDefault: boolean = true): string {
    let lastAppliedDefault = AppStorage.get(snapshotKey) as string;
    let shouldUseConfiguredDefault = legacyDefaults.includes(currentValue) ||
      (lastAppliedDefault !== undefined && lastAppliedDefault.length > 0 && currentValue === lastAppliedDefault);
    if (treatEmptyAsDefault && currentValue.trim().length === 0) {
      shouldUseConfiguredDefault = true;
    }
    let nextValue = shouldUseConfiguredDefault ? configuredDefault : currentValue;
    AppStorage.setOrCreate(snapshotKey, configuredDefault);
    return nextValue;
  }

  private prepareCustomOpp(): boolean {
    let ctx = getContext(this) as common.UIAbilityContext;
    try {
      let res: string = mnnllm.prepareCustomOpp(ctx.resourceManager, this.filesDir + '/custom_opp');
      this.customOppReady = (res === 'ok');
      if (!this.customOppReady) {
        this.output = '自定义算子准备失败: ' + res;
      }
      return this.customOppReady;
    } catch (e) {
      let err = e as Error;
      this.customOppReady = false;
      this.output = '自定义算子准备异常: ' + err.message;
      return false;
    }
  }

  private getCurrentModelFolderName(): string {
    return this.selectedModelVariant.length > 0 ? this.selectedModelVariant : 'model';
  }

  private syncModelDir(): void {
    this.modelDir = `${this.filesDir}/${this.getCurrentModelFolderName()}`;
  }

  private switchModelVariant(variant: string): void {
    let nextVariant = '';
    if (variant === 'modelv2' || variant === 'modelv3' || variant === 'modelv4' || variant === 'model_omc') {
      nextVariant = variant;
    }
    if (this.selectedModelVariant === nextVariant) {
      return;
    }
    this.selectedModelVariant = nextVariant;
    this.syncModelDir();
    this.modelLoaded = false;
    this.output = `模型路径已切换至: ${this.getCurrentModelFolderName()}`;
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)}KB`;
    if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(1)}MB`;
    return `${(bytes / 1073741824).toFixed(2)}GB`;
  }

  clearScreenshots() {
    try {
      let files = fs.listFileSync(this.filesDir);
      let count = 0;
      for (let f of files) {
        if (f.startsWith('agent_') || f.toLowerCase().endsWith('.jpg') || f.toLowerCase().endsWith('.jpeg')) {
          try {
            fs.unlinkSync(`${this.filesDir}/${f}`);
            count++;
          } catch (e) {
            this.appendCloudLog(`删除截图失败：${f}，${String(e)}`);
          }
        }
      }
      this.output = `清理成功，删除了 ${count} 张缓存截图。`;
      this.debugImagePath = '';
      this.cloudDebugImagePath = '';
      this.appendCloudLog(`已删除 App 中保存的截图：${count} 张`);
    } catch(e) {
      this.output = `清理截图失败: ${e}`;
    }
  }

  listScreenshots() {
    try {
      let files = fs.listFileSync(this.filesDir);
      let screenshots = files.filter(f => f.toLowerCase().endsWith('.jpg') || f.toLowerCase().endsWith('.jpeg') || f.startsWith('agent_'));
      if (screenshots.length > 0) {
        this.output = `====== 沙箱内截图文件列表 ======\n${screenshots.join('\n')}`;
      } else {
        this.output = '沙箱内当前没有截图文件。';
      }
    } catch (e) {
      this.output = `列出截图失败: ${e}`;
    }
  }

  deleteModelFiles() {
    try {
      if (!fs.accessSync(this.modelDir)) {
        this.output = '模型目录不存在，无需删除。';
        return;
      }
      let deletedCount = this.deletePathRecursively(this.modelDir);
      this.modelLoaded = false;
      this.output = `模型删除成功\n已删除 ${this.getCurrentModelFolderName()} 目录及其内容（共 ${deletedCount} 项）。`;
    } catch (e) {
      this.output = `模型删除失败: ${e}`;
    }
  }

  deleteModelConfigJson() {
    let cfgPath = this.modelDir + '/config.json';
    try {
      if (!fs.accessSync(this.modelDir)) {
        this.output = `模型文件夹不存在: ${this.modelDir}`;
        return;
      }
      if (!fs.accessSync(cfgPath)) {
        this.output = `文件不存在: ${cfgPath}\n无需删除。`;
        return;
      }
      fs.unlinkSync(cfgPath);
      this.modelLoaded = false;
      this.output = `已删除 ${this.getCurrentModelFolderName()}/config.json。\n其他模型文件保留，可重新下载补齐 config.json。`;
    } catch (e) {
      this.output = `删除 config.json 失败: ${e}`;
    }
  }

  private deletePathRecursively(path: string): number {
    try {
      let children = fs.listFileSync(path);
      let deleted = 0;
      for (let name of children) {
        deleted += this.deletePathRecursively(`${path}/${name}`);
      }
      fs.rmdirSync(path);
      return deleted + 1;
    } catch {
      try {
        fs.unlinkSync(path);
        return 1;
      } catch (e) {
        let err = e as Error;
        throw err;
      }
    }
  }

  private calcPathSize(path: string): number {
    try {
      let children = fs.listFileSync(path);
      let sum = 0;
      for (let name of children) {
        let childPath = `${path}/${name}`;
        sum += this.calcPathSize(childPath);
      }
      return sum;
    } catch {
      try {
        return fs.statSync(path).size;
      } catch {
        return 0;
      }
    }
  }

  private buildFileTree(path: string, depth: number, out: string[]): void {
    let indent = '';
    for (let i = 0; i < depth; i++) {
      indent += '  ';
    }
    try {
      let children = fs.listFileSync(path);
      let dirSize = this.calcPathSize(path);
      let baseName = path.substring(path.lastIndexOf('/') + 1);
      out.push(`${indent}[D] ${baseName}/ (${this.formatSize(dirSize)})`);
      children.sort();
      for (let name of children) {
        this.buildFileTree(`${path}/${name}`, depth + 1, out);
      }
    } catch {
      let fileSize = 0;
      try { fileSize = fs.statSync(path).size; } catch {}
      let baseName = path.substring(path.lastIndexOf('/') + 1);
      out.push(`${indent}[F] ${baseName} (${this.formatSize(fileSize)})`);
    }
  }

  listModelFilesTree() {
    try {
      if (!fs.accessSync(this.modelDir)) {
        this.output = `模型目录不存在: ${this.modelDir}`;
        return;
      }
      let lines: string[] = [];
      this.buildFileTree(this.modelDir, 0, lines);
      this.output = `====== ${this.getCurrentModelFolderName()} 文件树 ======\n` +
        `根目录: ${this.modelDir}\n` +
        lines.join('\n');
    } catch (e) {
      this.output = `查看模型文件树失败: ${e}`;
    }
  }

  private deleteChunkVisionOmUnder(path: string): number {
    let deleted = 0;
    let children: string[] = [];
    try {
      children = fs.listFileSync(path);
    } catch {
      return 0;
    }
    for (let name of children) {
      let childPath = `${path}/${name}`;
      if (name.startsWith('chunk_')) {
        let visionPath = `${childPath}/vision.om`;
        try {
          if (fs.accessSync(visionPath)) {
            fs.unlinkSync(visionPath);
            deleted++;
          }
        } catch {}
      }
      deleted += this.deleteChunkVisionOmUnder(childPath);
    }
    return deleted;
  }

  deleteChunkVisionOmFiles() {
    try {
      if (!fs.accessSync(this.modelDir)) {
        this.output = `模型目录不存在: ${this.modelDir}`;
        return;
      }
      let count = this.deleteChunkVisionOmUnder(this.modelDir);
      this.output = `已在 ${this.getCurrentModelFolderName()} 下删除 ${count} 个 chunk_*/vision.om`;
    } catch (e) {
      this.output = `删除 chunk_*/vision.om 失败: ${e}`;
    }
  }

  deleteDebugOutputs() {
    let variants = ['model', 'modelv2', 'modelv3', 'modelv4', 'model_omc'];
    let totalDeleted = 0;
    let results: string[] = [];
    for (let variant of variants) {
      let debugDir = `${this.filesDir}/${variant}/debug_outputs`;
      try {
        if (!fs.accessSync(debugDir)) {
          continue;
        }
        let files = fs.listFileSync(debugDir);
        let count = 0;
        for (let f of files) {
          try {
            fs.unlinkSync(`${debugDir}/${f}`);
            count++;
          } catch {}
        }
        try {
          fs.rmdirSync(debugDir);
        } catch {}
        totalDeleted += count;
        results.push(`${variant}/debug_outputs: ${count} files`);
      } catch {
        // directory doesn't exist, skip
      }
    }
    if (totalDeleted === 0) {
      this.output = '所有 model 目录下均无 debug_outputs';
    } else {
      this.output = `已删除 ${totalDeleted} 个调试输出文件\n${results.join('\n')}`;
    }
  }

  private async exportEncryptedBackup(password: string, includeSensitiveSettings: boolean): Promise<void> {
    this.backupBusy = true;
    AppLogger.info('Backup.UI', 'export requested includeSensitive=' + String(includeSensitiveSettings));
    try {
      let context = this.backupAbilityContext();
      await SettingsBackupController.exportEncryptedBackup({
        context: context,
        filesDir: this.filesDir,
        password: password,
        includeSensitiveSettings: includeSensitiveSettings,
        onStatusChange: (status: string) => { this.backupStatus = status; }
      });
      AppLogger.info('Backup.UI', 'export flow finished');
    } catch (e) {
      let err = e as Error;
      AppLogger.errorCause('Backup.UI', 'export flow failed', err);
      throw err;
    } finally {
      this.backupBusy = false;
    }
  }

  private async importEncryptedBackup(password: string): Promise<void> {
    this.backupBusy = true;
    AppLogger.info('Backup.UI', 'import requested');
    try {
      let context = this.backupAbilityContext();
      await SettingsBackupController.importEncryptedBackup({
        context: context,
        filesDir: this.filesDir,
        password: password,
        onStatusChange: (status: string) => { this.backupStatus = status; },
        onRestored: () => {
          this.initDataManager();
          this.initChatSessions();
        }
      });
      AppLogger.info('Backup.UI', 'import flow finished');
    } catch (e) {
      let err = e as Error;
      AppLogger.errorCause('Backup.UI', 'import flow failed', err);
      throw err;
    } finally {
      this.backupBusy = false;
    }
  }

  private backupAbilityContext(): common.UIAbilityContext {
    try {
      let hostContext = this.getUIContext().getHostContext();
      if (hostContext === undefined) {
        throw new Error('host context is undefined');
      }
      return hostContext as common.UIAbilityContext;
    } catch (e) {
      AppLogger.errorCause('Backup.UI', 'get host context failed', e as Error);
      throw new Error('无法获取页面上下文，请返回设置页后重试');
    }
  }

  showConfigJson() {
    let cfgPath = this.modelDir + '/config.json';
    try {
      if (!fs.accessSync(cfgPath)) {
        this.output = `文件不存在: ${cfgPath}\n请先下载模型`;
        return;
      }
      let file = fs.openSync(cfgPath, fs.OpenMode.READ_ONLY);
      let stat = fs.statSync(cfgPath);
      let buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      let textDecoder = util.TextDecoder.create('utf-8');
      let content = textDecoder.decodeWithStream(new Uint8Array(buf));
      this.output = `====== ${this.getCurrentModelFolderName()}/config.json ======\n${content}`;
    } catch (e) {
      this.output = `读取 config.json 失败: ${e}`;
    }
  }

  updateConfigThreadNum() {
    let num = parseInt(this.threadNumInput);
    if (isNaN(num) || num <= 0) {
      this.output = '请输入有效的线程数（正整数）';
      return;
    }

    let cfgPath = this.modelDir + '/config.json';
    try {
      if (!fs.accessSync(cfgPath)) {
        this.output = `文件不存在: ${cfgPath}`;
        return;
      }

      // 读取文件。
      let fileRead = fs.openSync(cfgPath, fs.OpenMode.READ_ONLY);
      let stat = fs.statSync(cfgPath);
      let buf = new ArrayBuffer(stat.size);
      fs.readSync(fileRead.fd, buf);
      fs.closeSync(fileRead);

      let textDecoder = util.TextDecoder.create('utf-8');
      let content = textDecoder.decodeWithStream(new Uint8Array(buf));

      // 修改 JSON。
      let configObj = ArkJSON.parse(content) as JsonMap;
      configObj['thread_num'] = num;
      if (configObj['mllm']) {
        let mllmObj = configObj['mllm'] as JsonMap;
        mllmObj['thread_num'] = num;
      }

      // 写入文件。
      let newStr = ArkJSON.stringify(configObj, null, 4);
      let byteStr = util.TextEncoder.create('utf-8').encodeInto(newStr);
      let fileWrite = fs.openSync(cfgPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(fileWrite.fd, byteStr.buffer);
      fs.closeSync(fileWrite);

      this.output = `更新线程数成功: ${num}\n====== 新配置 ======\n${newStr}`;
    } catch (e) {
      this.output = `更新 config.json 失败: ${e}`;
    }
  }

  updateConfigBackendType(target: string) {
    let value = (target === 'mllm') ? this.mllmBackendTypeInput.trim() : this.backendTypeInput.trim();
    if (value.length === 0) {
      this.output = '请输入有效的 backend_type';
      return;
    }

    let cfgPath = this.modelDir + '/config.json';
    try {
      if (!fs.accessSync(cfgPath)) {
        this.output = `文件不存在: ${cfgPath}`;
        return;
      }

      let fileRead = fs.openSync(cfgPath, fs.OpenMode.READ_ONLY);
      let stat = fs.statSync(cfgPath);
      let buf = new ArrayBuffer(stat.size);
      fs.readSync(fileRead.fd, buf);
      fs.closeSync(fileRead);

      let textDecoder = util.TextDecoder.create('utf-8');
      let content = textDecoder.decodeWithStream(new Uint8Array(buf));
      let configObj = ArkJSON.parse(content) as JsonMap;

      if (target === 'mllm') {
        if (configObj['mllm']) {
          let mllmObj = configObj['mllm'] as JsonMap;
          mllmObj['backend_type'] = value;
        } else {
          this.output = 'config.json 中不存在 mllm 字段';
          return;
        }
      } else {
        configObj['backend_type'] = value;
      }

      let newStr = ArkJSON.stringify(configObj, null, 4);
      let byteStr = util.TextEncoder.create('utf-8').encodeInto(newStr);
      let fileWrite = fs.openSync(cfgPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(fileWrite.fd, byteStr.buffer);
      fs.closeSync(fileWrite);

      let label = (target === 'mllm') ? 'mllm.backend_type' : 'backend_type';
      this.output = `更新 ${label} 成功: ${value}\n====== 新配置 ======\n${newStr}`;
    } catch (e) {
      this.output = `更新 config.json 失败: ${e}`;
    }
  }

  async testAndConnectHdc() {
    if (this.wirelessIp.trim().length === 0) {
      this.output = '请先填写当前手机的无线 HDC 地址，例如 192.168.x.x:端口';
      return;
    }
    let serverUrl = this.manualHdcServerUrl();
    if (serverUrl.length === 0) {
      this.output = '请先填写 PC HDC Server 地址。';
      return;
    }
    this.hdcServerIp = serverUrl;
    this.manualHdcServerIp = serverUrl;
    this.markHdcDisconnected(true, 'Manual HDC pairing is running...');
    this.output = `正在请求远程服务执行 HDC 连接测试: ${this.wirelessIp}...`;
    let attempt = await this.requestManualHdcConnect(serverUrl, this.wirelessIp.trim());
    if (attempt.ok && attempt.health) {
      this.applyManualHdcSuccess(serverUrl, attempt.health, 'Manual HDC pairing succeeded');
      this.output = `远程连接测试请求成功!\n${attempt.body}`;
      return;
    }
    this.applyManualHdcFailure(serverUrl, attempt.message, 'Manual HDC pairing failed');
    this.output = `HDC 请求出错: ${attempt.message}\n请确认远端服务 ${serverUrl}/api/hdc/connect 已运行。`;
  }

  // ========== Step 1: Check connection, list files ==========
  async checkServer() {
    this.output = `正在连接 ${this.serverIp} ...`;
    // 每个 httpRequest 对应一个 HTTP 请求任务，不复用。
    let httpReq = http.createHttp();
    try {
      let listOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING,
      };
      let resp = await httpReq.request(`${this.serverIp}/api/files`, listOptions);
      if (resp.responseCode !== 200) {
        this.output = `连接失败: HTTP ${resp.responseCode}`;
        return;
      }
      let files: ServerFile[] = ArkJSON.parse(resp.result as string) as ServerFile[];
      this.serverFiles = files.filter((f: ServerFile) => f.name !== 'serve_model.py');
      this.totalBytesAll = 0;

      let listing = '服务器连接成功\n\n文件列表:\n';
      listing += '----------------------------------------\n';
      for (let f of this.serverFiles) {
        this.totalBytesAll += f.size;
        let pad = ' '.repeat(Math.max(1, 28 - f.name.length));
        listing += `  ${f.name}${pad}${this.formatSize(f.size)}\n`;
      }
      listing += '----------------------------------------\n';
      listing += `共 ${this.serverFiles.length} 个文件，总大小: ${this.formatSize(this.totalBytesAll)}\n\n`;
      listing += '点击“下载全部”开始下载';
      this.output = listing;
      this.connected = true;
    } catch (e) {
      let err = e as BusinessError;
      this.output = `连接失败: code=${err.code} ${err.message}\n\n请检查:\n1. 服务器 python serve_model.py 是否运行\n2. 防火墙是否开放端口\n3. 手机网络是否可达服务器`;
      this.connected = false;
    } finally {
      httpReq.destroy();
    }
  }

  // ========== Step 2: Stream-download one file ==========
  private downloadOneFile(file: ServerFile, index: number, fileCount: number,
    completedBytes: number): Promise<number> {
    const url = `${this.serverIp}/${file.name}`;
    const savePath = `${this.modelDir}/${file.name}`;

    // Skip if exists with correct size
    try {
      let st = fs.statSync(savePath);
      if (st.size === file.size) {
        this.output = `[${index + 1}/${fileCount}] ${file.name}\n` +
          `已存在 (${this.formatSize(st.size)})，跳过\n` +
          `总进度: ${this.formatSize(completedBytes + file.size)} / ${this.formatSize(this.totalBytesAll)}`;
        return Promise.resolve(file.size);
      }
    } catch {
      // not exists
    }

    this.output = `[${index + 1}/${fileCount}] 连接: ${file.name}`;
    let self = this;
    let idx = index;
    let completed = completedBytes;

    return new Promise<number>((resolve) => {
      // 每个 httpRequest 对应一个 HTTP 请求任务，不复用。
      let httpReq = http.createHttp();
      let fileHandle: fs.File;
      let failed = false;
      let resolved = false;

      try {
        fileHandle = fs.openSync(savePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY |
        fs.OpenMode.TRUNC);
      } catch {
        self.output = `[${idx + 1}/${fileCount}] 创建文件失败: ${file.name}`;
        httpReq.destroy();
        resolve(-1);
        return;
      }

      // Helper: cleanup and resolve
      let finish = (size: number): void => {
        if (resolved) return;
        resolved = true;
        httpReq.off('dataReceive');
        httpReq.off('dataReceiveProgress');
        httpReq.off('dataEnd');
        try { fs.closeSync(fileHandle); } catch {}
        httpReq.destroy();
        resolve(size);
      };

      // Subscribe: stream data -> write to file
      httpReq.on('dataReceive', (data: ArrayBuffer) => {
        if (!failed) {
          try {
            fs.writeSync(fileHandle.fd, data);
          } catch {
            failed = true;
          }
        }
      });

      // Subscribe: download progress
      httpReq.on('dataReceiveProgress', (data: http.DataReceiveProgressInfo) => {
        if (failed) return;
        let filePct = data.totalSize > 0 ? Math.floor(data.receiveSize * 100 / data.totalSize)
          : 0;
        let overallRecv = completed + data.receiveSize;
        let overallPct = self.totalBytesAll > 0
          ? Math.floor(overallRecv * 100 / self.totalBytesAll) : 0;
        self.output =
          `[${idx + 1}/${fileCount}] ${file.name}\n` +
            `文件: ${self.formatSize(data.receiveSize)} / ${self.formatSize(data.totalSize)} ${filePct}%\n` +
            `总量: ${self.formatSize(overallRecv)} / ${self.formatSize(self.totalBytesAll)} ${overallPct}%`;
      });

      // Subscribe: data receive complete
      httpReq.on('dataEnd', () => {
        if (failed) {
          self.output = `[${idx + 1}/${fileCount}] ${file.name} 写入失败`;
          finish(-1);
        } else {
          let fileSize = 0;
          try {
            fs.closeSync(fileHandle);
            fileSize = fs.statSync(savePath).size;
          } catch {}
          self.output = `[${idx + 1}/${fileCount}] ${file.name} 完成 (${self.formatSize(fileSize)})`;
          if (resolved) return;
          resolved = true;
          httpReq.off('dataReceive');
          httpReq.off('dataReceiveProgress');
          httpReq.off('dataEnd');
          httpReq.destroy();
          resolve(fileSize);
        }
      });

      // Issue stream request
      let streamOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 60000,
        readTimeout: 7200000, // 2 hours for large files
      };
      httpReq.requestInStream(url, streamOptions).then((code: number) => {
        if (code !== 200) {
          failed = true;
          self.output = `[${idx + 1}/${fileCount}] ${file.name} HTTP ${code}`;
          finish(-1);
        }
        // if 200, wait for dataEnd
      }).catch((err: BusinessError) => {
        failed = true;
        self.output = `[${idx + 1}/${fileCount}] ${file.name} 错误: code=${err.code} ${err.message}`;
        finish(-1);
      });
    });
  }

  // ========== Step 3: Download all files ==========
  async downloadAll() {
    if (this.serverFiles.length === 0) {
      this.output = '请先检查服务器连接';
      return;
    }
    this.downloading = true;
    try { fs.mkdirSync(this.modelDir); } catch {}

    let completedBytes = 0;
    let failed: string[] = [];

    for (let i = 0; i < this.serverFiles.length; i++) {
      let size = await this.downloadOneFile(this.serverFiles[i], i, this.serverFiles.length,
        completedBytes);
      if (size < 0) {
        failed.push(this.serverFiles[i].name);
      } else {
        completedBytes += size;
      }
    }

    if (failed.length === 0) {
      this.output = `全部下载完成!\n模型总大小: ${this.formatSize(completedBytes)}\n\n切换到聊天页的本地推理模式后会自动加载模型`;
    } else {
      this.output = `${failed.length} 个失败: ${failed.join(', ')}\n已下载: ${this.formatSize(completedBytes)}\n再次点击可继续，已有文件会跳过。`;
    }
    this.downloading = false;
  }

  private getCloudConfig(): CloudModelConfig {
    let config: CloudModelConfig = {
      plannerBaseUrl: this.cloudPlannerBaseUrl,
      deciderBaseUrl: this.cloudDeciderBaseUrl,
      apiKey: this.cloudApiKey,
      deciderModel: this.cloudDeciderModel
    };
    return config;
  }

  private isCloudConfigReady(): boolean {
    return this.cloudPlannerBaseUrl.trim().length > 0 &&
      this.cloudDeciderBaseUrl.trim().length > 0 &&
      this.cloudApiKey.trim().length > 0;
  }

  async testCloudPlanner() {
    if (!this.isCloudConfigReady()) {
      this.appendCloudLog('配置不完整：请先填写 Planner / Decider 的服务地址和 API Key。');
      return;
    }
    this.cloudThinking = true;
    this.appendCloudLog(`测试 Planner：${this.cloudPlannerBaseUrl}`);
    try {
      let response = await this.cloudClient.chatPlanner('请只回复 ok', this.getCloudConfig());
      this.appendCloudLog(`Planner 测试返回：\n${response}`);
    } catch (e) {
      let err = e as Error;
      this.appendCloudLog('Planner 连接失败：' + err.message);
    } finally {
      this.cloudThinking = false;
    }
  }

  async runCloudPlannerOnce() {
    if (!this.isCloudConfigReady()) {
      this.appendCloudLog('配置不完整：请先填写 Planner / Decider 的服务地址和 API Key。');
      return;
    }
    if (this.cloudUserInput.trim().length === 0 || this.cloudThinking) {
      return;
    }
    let task = this.cloudUserInput.trim();
    this.cloudUserInput = chatInputAfterAcceptedSend(this.cloudUserInput, true);
    this.cloudThinking = true;
    let activeSession = this.ensureActiveChatSession();
    if (activeSession === null) {
      this.appendCloudLog('会话初始化失败，无法调用 Planner。');
      this.cloudThinking = false;
      return;
    }
    let userMessage = createChatMessage(this.nextChatMessageId('user'), 'user', CHAT_MESSAGE_KIND_CHAT, task,
      new Date().getTime());
    let contextMessages = buildCloudContextMessages(activeSession.messages.concat([userMessage]));
    this.appendActiveChatMessage(userMessage);
    this.appendCloudLog(`手动调用 Planner，任务：${task}`);
    try {
      let response = await this.cloudClient.chatPlannerMessages(contextMessages, this.getCloudConfig());
      this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('assistant'), 'assistant',
        CHAT_MESSAGE_KIND_CHAT, response, new Date().getTime()));
      this.appendCloudLog(`Planner 手动返回：\n${response}`);
    } catch (e) {
      let err = e as Error;
      this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('assistant'), 'assistant',
        CHAT_MESSAGE_KIND_CHAT, '[错误] ' + err.message, new Date().getTime()));
      this.appendCloudLog('云端 Planner 推理失败：' + err.message);
    } finally {
      this.cloudThinking = false;
    }
  }

  private hdcServerApiUrl(path: string): string {
    return this.hdcApiUrl(this.hdcServerIp, path);
  }

  private normalizeHdcUrl(rawUrl: string): string {
    let url = rawUrl.trim();
    if (url.length === 0) {
      return '';
    }
    if (url.indexOf('http://') !== 0 && url.indexOf('https://') !== 0) {
      url = 'http://' + url;
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  private hdcApiUrl(baseUrl: string, path: string): string {
    let url = this.normalizeHdcUrl(baseUrl);
    return url + path;
  }

  private hdcInputEditable(): boolean {
    return this.hdcManualPairing || !this.hdcConnected;
  }

  private hdcInputBackgroundColor(): string {
    return this.hdcInputEditable() ? '#F2F5FC' : '#E6EAF2';
  }

  private hdcInputTextColor(): string {
    return this.hdcInputEditable() ? '#11182F' : '#7A8494';
  }

  private hdcStatusColor(): string {
    if (this.hdcConnected) {
      return '#2D9B73';
    }
    if (this.hdcAutoConnecting) {
      return '#4F68FF';
    }
    return '#D26B31';
  }

  private addHdcCandidate(candidates: string[], value: string): void {
    let normalized = this.normalizeHdcUrl(value);
    if (normalized.length > 0 && candidates.indexOf(normalized) < 0) {
      candidates.push(normalized);
    }
  }

  private hdcDiscoveryCandidates(): string[] {
    let candidates: string[] = [];
    this.addHdcCandidate(candidates, AUTO_HDC_SERVER_URL);
    this.addHdcCandidate(candidates, 'http://localhost:19124');
    this.addHdcCandidate(candidates, this.hdcServerIp);
    this.addHdcCandidate(candidates, this.manualHdcServerIp);
    this.addHdcCandidate(candidates, DEFAULT_ENDPOINT_CONFIG.hdcServerUrl);
    return candidates;
  }

  private isAutoHdcUrl(value: string): boolean {
    let normalized = this.normalizeHdcUrl(value);
    return normalized === this.normalizeHdcUrl(AUTO_HDC_SERVER_URL) ||
      normalized === this.normalizeHdcUrl('http://localhost:19124');
  }

  private hdcHealthRetryCount(baseUrl: string): number {
    if (this.normalizeHdcUrl(baseUrl) === this.normalizeHdcUrl(AUTO_HDC_SERVER_URL)) {
      return AUTO_HDC_REVERSE_HEALTH_RETRIES;
    }
    return 1;
  }

  private hdcHealthConnectTimeout(baseUrl: string): number {
    return this.isAutoHdcUrl(baseUrl) ? HDC_REVERSE_CONNECT_TIMEOUT_MS : HDC_SERVER_CONNECT_TIMEOUT_MS;
  }

  private hdcHealthReadTimeout(baseUrl: string): number {
    return this.isAutoHdcUrl(baseUrl) ? HDC_REVERSE_READ_TIMEOUT_MS : HDC_SERVER_READ_TIMEOUT_MS;
  }

  private manualHdcServerUrl(): string {
    let savedManual = this.normalizeHdcUrl(this.manualHdcServerIp);
    if (savedManual.length > 0 && !this.isAutoHdcUrl(savedManual)) {
      return savedManual;
    }

    let current = this.normalizeHdcUrl(this.hdcServerIp);
    if (current.length > 0 && !this.isAutoHdcUrl(current)) {
      return current;
    }

    let configured = this.normalizeHdcUrl(DEFAULT_ENDPOINT_CONFIG.hdcServerUrl);
    if (configured.length > 0 && !this.isAutoHdcUrl(configured)) {
      return configured;
    }
    return '';
  }

  private addHdcCandidatesFromList(candidates: string[], values: string[] | undefined): void {
    if (values === undefined) {
      return;
    }
    for (let value of values) {
      this.addHdcCandidate(candidates, value);
    }
  }

  private addHdcCandidatesFromHealth(candidates: string[], health: HdcHealthResponse): void {
    if (health.app_server_url !== undefined && health.app_server_url.length > 0) {
      this.addHdcCandidate(candidates, health.app_server_url);
    }
    this.addHdcCandidatesFromList(candidates, health.app_server_urls);
    this.addHdcCandidatesFromList(candidates, health.pc_server_urls);
  }

  private firstNonAutoHdcUrl(values: string[]): string {
    for (let value of values) {
      let normalized = this.normalizeHdcUrl(value);
      if (normalized.length > 0 && !this.isAutoHdcUrl(normalized)) {
        return normalized;
      }
    }
    return '';
  }

  private firstNonAutoHealthUrl(health: HdcHealthResponse): string {
    let values: string[] = [];
    if (health.pc_server_urls !== undefined) {
      for (let value of health.pc_server_urls) {
        values.push(value);
      }
    }
    if (health.app_server_urls !== undefined) {
      for (let value of health.app_server_urls) {
        values.push(value);
      }
    }
    if (health.app_server_url !== undefined && health.app_server_url.length > 0) {
      values.push(health.app_server_url);
    }
    return this.firstNonAutoHdcUrl(values);
  }

  private rememberHdcFallbackFromHealth(health: HdcHealthResponse, overwrite: boolean = false): void {
    let fallback = this.firstNonAutoHealthUrl(health);
    let current = this.normalizeHdcUrl(this.manualHdcServerIp);
    if (fallback.length > 0 && (overwrite || current.length === 0 || this.isAutoHdcUrl(current))) {
      this.manualHdcServerIp = fallback;
    }
  }

  private hdcTargetText(health: HdcHealthResponse): string {
    return health.target !== undefined && health.target.length > 0 ? ', target=' + health.target : '';
  }

  private markHdcDisconnected(manualPairing: boolean, statusText: string): void {
    this.hdcConnected = false;
    this.hdcUsingReverseTunnel = false;
    this.hdcAutoConnected = false;
    this.hdcManualPairing = manualPairing;
    this.hdcAutoStatus = statusText;
  }

  private markHdcConnected(serverUrl: string, health: HdcHealthResponse, statusPrefix: string): void {
    let normalized = this.normalizeHdcUrl(serverUrl);
    this.rememberHdcFallbackFromHealth(health, this.isAutoHdcUrl(normalized));
    this.hdcServerIp = normalized;
    this.hdcConnected = true;
    this.hdcUsingReverseTunnel = this.isAutoHdcUrl(normalized);
    this.hdcAutoConnected = this.hdcUsingReverseTunnel;
    this.hdcManualPairing = !this.hdcUsingReverseTunnel;
    let routeText = this.hdcUsingReverseTunnel ? 'reverse tunnel URL' : 'PC Server URL';
    this.hdcAutoStatus = statusPrefix + ': ' + routeText + '=' + normalized + this.hdcTargetText(health);
  }

  private async sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private async requestHdcHealth(baseUrl: string, connectTimeout: number = 2500,
    readTimeout: number = 5000): Promise<HdcHealthResponse | null> {
    let httpReq = http.createHttp();
    try {
      AppLogger.debug('HDC', 'health request url=' + this.hdcApiUrl(baseUrl, '/api/health'));
      let options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        expectDataType: http.HttpDataType.STRING
      };
      let resp = await httpReq.request(this.hdcApiUrl(baseUrl, '/api/health'), options);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        AppLogger.debug('HDC', 'health non-2xx baseUrl=' + baseUrl + ' http=' + resp.responseCode);
        return null;
      }
      try {
        return ArkJSON.parse(String(resp.result)) as HdcHealthResponse;
      } catch (e) {
        let err = e as Error;
        AppLogger.debug('HDC', 'health parse failed baseUrl=' + baseUrl + ' message=' + err.message);
        return null;
      }
    } catch (e) {
      let err = e as Error;
      AppLogger.debug('HDC', 'health request failed baseUrl=' + baseUrl + ' message=' + err.message);
      return null;
    } finally {
      httpReq.destroy();
    }
  }

  private async requestHdcHealthWithRetry(baseUrl: string): Promise<HdcHealthAttempt> {
    let retries = this.hdcHealthRetryCount(baseUrl);
    let lastMessage = 'No response from ' + baseUrl;
    for (let i = 0; i < retries; i++) {
      let health = await this.requestHdcHealth(baseUrl, this.hdcHealthConnectTimeout(baseUrl),
        this.hdcHealthReadTimeout(baseUrl));
      if (health) {
        return {
          health: health,
          message: this.hdcHealthMessage(health, 'HDC target is not connected')
        };
      }
      lastMessage = 'No response from ' + baseUrl + ' (attempt ' + (i + 1) + '/' + retries + ')';
      if (i + 1 < retries) {
        await this.sleep(HDC_HEALTH_RETRY_DELAY_MS);
      }
    }
    return {
      health: null,
      message: lastMessage
    };
  }

  private hdcHealthReady(baseUrl: string, health: HdcHealthResponse): boolean {
    if (health.status !== 'ok' || health.hdc_connected !== true) {
      return false;
    }
    if (this.isAutoHdcUrl(baseUrl)) {
      return health.rport_ready !== false;
    }
    return health.tunnel_ready !== false || health.fport_ready === true || health.rport_ready === true;
  }

  private hdcHealthMessage(health: HdcHealthResponse, fallback: string): string {
    if (health.message && health.message.length > 0) {
      return health.message;
    }
    return fallback;
  }

  private hdcHealthDebugText(health: HdcHealthResponse): string {
    let target = health.target && health.target.length > 0 ? health.target : '(empty)';
    let appServer = health.app_server_url && health.app_server_url.length > 0 ? health.app_server_url : '(empty)';
    return 'status=' + health.status +
      ', hdc_connected=' + String(health.hdc_connected === true) +
      ', tunnel_ready=' + String(health.tunnel_ready === true) +
      ', fport_ready=' + String(health.fport_ready === true) +
      ', rport_ready=' + String(health.rport_ready === true) +
      ', rport_listening=' + String(health.rport_listening === true) +
      ', loop_alive=' + String(health.loop_alive === true) +
      ', target=' + target +
      ', app_server_url=' + appServer;
  }

  private async requestManualHdcConnect(serverUrl: string, target: string): Promise<HdcConnectAttempt> {
    let httpReq = http.createHttp();
    try {
      AppLogger.debug('HDC', 'manual connect request server=' + serverUrl + ', target=' + target);
      let connectPayload: HdcConnectRequest = {
        target: target,
        kill_others: true,
        prefer_wired: true
      };
      let options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: ArkJSON.stringify(connectPayload),
        connectTimeout: 5000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING
      };
      let resp = await httpReq.request(this.hdcApiUrl(serverUrl, '/api/hdc/connect'), options);
      let body = String(resp.result);
      AppLogger.debug('HDC', 'manual connect response server=' + serverUrl + ', http=' + resp.responseCode +
        ', bodyLength=' + body.length);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return {
          ok: false,
          responseCode: resp.responseCode,
          body: body,
          message: 'HTTP ' + resp.responseCode + ' ' + body
        };
      }

      try {
        let parsed = ArkJSON.parse(body) as HdcHealthResponse;
        if (parsed.status !== 'ok') {
          return {
            ok: false,
            responseCode: resp.responseCode,
            body: body,
            message: parsed.message || body,
            health: parsed
          };
        }
        return {
          ok: true,
          responseCode: resp.responseCode,
          body: body,
          message: parsed.message || body,
          health: parsed
        };
      } catch (e) {
        let err = e as Error;
        AppLogger.debug('HDC', 'manual connect parse failed server=' + serverUrl + ', message=' + err.message);
        return {
          ok: false,
          responseCode: resp.responseCode,
          body: body,
          message: 'Invalid HDC connect response: ' + err.message
        };
      }
    } catch (e) {
      let err = e as Error;
      AppLogger.debug('HDC', 'manual connect request failed server=' + serverUrl + ', target=' + target +
        ', message=' + err.message);
      return {
        ok: false,
        responseCode: 0,
        body: '',
        message: err.message
      };
    } finally {
      httpReq.destroy();
    }
  }

  private applyManualHdcSuccess(serverUrl: string, health: HdcHealthResponse, statusPrefix: string): void {
    let normalized = this.normalizeHdcUrl(serverUrl);
    if (!this.isAutoHdcUrl(normalized)) {
      this.manualHdcServerIp = normalized;
    }
    this.markHdcConnected(normalized, health, statusPrefix);
  }

  private applyManualHdcFailure(serverUrl: string, message: string, statusPrefix: string): void {
    let normalized = this.normalizeHdcUrl(serverUrl);
    this.hdcServerIp = normalized;
    if (!this.isAutoHdcUrl(normalized)) {
      this.manualHdcServerIp = normalized;
    }
    this.markHdcDisconnected(true, statusPrefix + ': ' + message);
  }

  private async connectManualHdcTarget(useCloudLog: boolean): Promise<boolean> {
    let serverUrl = this.manualHdcServerUrl();
    let target = this.wirelessIp.trim();
    AppLogger.debug('HDC', 'manual fallback start server=' + (serverUrl.length > 0 ? serverUrl : '(empty)') +
      ', target=' + (target.length > 0 ? target : '(empty)') + ', useCloudLog=' + String(useCloudLog));
    if (serverUrl.length === 0) {
      AppLogger.debug('HDC', 'manual fallback skipped reason=missing-server');
      this.logAgentLoopReady('Manual HDC fallback skipped: PC HDC Server URL is not configured.', useCloudLog);
      return false;
    }
    if (target.length === 0) {
      AppLogger.debug('HDC', 'manual fallback skipped reason=missing-target server=' + serverUrl);
      this.logAgentLoopReady('Manual HDC fallback skipped: phone wireless HDC target is not configured.', useCloudLog);
      return false;
    }

    this.logAgentLoopReady('Auto HDC failed; trying manual HDC pairing: server=' + serverUrl + ', target=' + target, useCloudLog);
    this.markHdcDisconnected(true, 'Manual HDC fallback is running...');
    let attempt = await this.requestManualHdcConnect(serverUrl, target);
    AppLogger.debug('HDC', 'manual fallback attempt ok=' + String(attempt.ok) +
      ', http=' + attempt.responseCode + ', message=' + attempt.message);
    if (!attempt.ok || !attempt.health) {
      this.applyManualHdcFailure(serverUrl, attempt.message, 'Manual HDC fallback failed');
      AppLogger.debug('HDC', 'manual fallback failed selected=' + this.hdcServerIp +
        ', reason=' + attempt.message);
      this.logAgentLoopReady(this.hdcAutoStatus, useCloudLog);
      return false;
    }

    this.applyManualHdcSuccess(serverUrl, attempt.health, 'Manual HDC fallback succeeded');
    AppLogger.debug('HDC', 'manual fallback success selected=' + this.hdcServerIp +
      ', health=' + this.hdcHealthDebugText(attempt.health));
    this.logAgentLoopReady(this.hdcAutoStatus, useCloudLog);
    return true;
  }

  private setHdcManualPairing(): void {
    this.markHdcDisconnected(true, 'Manual HDC pairing enabled. Enter PC HDC Server and phone wireless HDC target.');
    if (this.isAutoHdcUrl(this.hdcServerIp)) {
      this.hdcServerIp = this.manualHdcServerUrl();
    }
  }

  private markHdcManualEditing(): void {
    this.markHdcDisconnected(true, 'Manual HDC pairing is being edited.');
  }

  private async discoverHdcServer(useCloudLog: boolean = false, force: boolean = false): Promise<boolean> {
    if (this.hdcAutoConnecting && !force) {
      AppLogger.debug('HDC', 'discover skipped: already connecting, connected=' + String(this.hdcConnected) +
        ', current=' + this.hdcServerIp);
      return this.hdcConnected;
    }

    this.hdcAutoConnecting = true;
    this.hdcAutoStatus = 'Auto-discovering HDC Server...';
    let candidates = this.hdcDiscoveryCandidates();
    let lastMessage = '';
    let attemptMessages: string[] = [];
    AppLogger.debug('HDC', 'discover start force=' + String(force) + ', candidates=' + candidates.join(', '));
    try {
      let index = 0;
      while (index < candidates.length) {
        let candidate = candidates[index];
        index += 1;
        AppLogger.debug('HDC', 'discover candidate[' + (index - 1) + ']=' + candidate);
        let attempt = await this.requestHdcHealthWithRetry(candidate);
        let health = attempt.health;
        if (health === null) {
          lastMessage = attempt.message;
          attemptMessages.push(lastMessage);
          AppLogger.debug('HDC', 'discover candidate no response message=' + lastMessage);
          continue;
        }
        AppLogger.debug('HDC', 'discover candidate health ' + this.hdcHealthDebugText(health));
        this.addHdcCandidatesFromHealth(candidates, health);
        this.rememberHdcFallbackFromHealth(health, this.isAutoHdcUrl(candidate));
        if (this.hdcHealthReady(candidate, health)) {
          let statusPrefix = this.isAutoHdcUrl(candidate) ? 'Auto HDC connected' : 'HDC Server fallback connected';
          this.markHdcConnected(candidate, health, statusPrefix);
          AppLogger.debug('HDC', 'discover success selected=' + this.hdcServerIp);
          this.logAgentLoopReady(this.hdcAutoStatus, useCloudLog);
          return true;
        }
        lastMessage = candidate + ': ' + attempt.message;
        attemptMessages.push(lastMessage);
      }
      let detail = attemptMessages.length > 0 ? attemptMessages.join('; ') : lastMessage;
      this.markHdcDisconnected(false, 'Auto HDC discovery failed. Use manual pairing if needed. ' + detail);
      AppLogger.debug('HDC', 'discover failed detail=' + detail);
      this.logAgentLoopReady(this.hdcAutoStatus, useCloudLog);
      return false;
    } finally {
      AppLogger.debug('HDC', 'discover end connected=' + String(this.hdcConnected) +
        ', selected=' + this.hdcServerIp);
      this.hdcAutoConnecting = false;
    }
  }

  private async ensureHdcServerReadyForTask(useCloudLog: boolean): Promise<boolean> {
    AppLogger.debug('HDC', 'ensure start useCloudLog=' + String(useCloudLog) + ', current=' + this.hdcServerIp);
    if (await this.discoverHdcServer(useCloudLog, true)) {
      AppLogger.debug('HDC', 'ensure success via=auto selected=' + this.hdcServerIp);
      return true;
    }

    if (await this.connectManualHdcTarget(useCloudLog)) {
      AppLogger.debug('HDC', 'ensure success via=manual selected=' + this.hdcServerIp);
      return true;
    }

    this.logAgentLoopReady('HDC connection failed: automatic tunnel and manual HDC pairing both failed.', useCloudLog);
    AppLogger.debug('HDC', 'ensure failed selected=' + this.hdcServerIp);
    return false;
  }

  private logAgentLoopReady(message: string, useCloudLog: boolean): void {
    if (useCloudLog) {
      this.appendCloudLog(message);
      return;
    }
    this.output = message;
  }

  private async ensurePcAgentLoopReady(useCloudLog: boolean): Promise<boolean> {
    if (!await this.ensureHdcServerReadyForTask(useCloudLog)) {
      return false;
    }
    if (this.hdcServerIp.trim().length === 0) {
      this.logAgentLoopReady('HDC Server 未配置，无法恢复 PC Agent loop。', useCloudLog);
      return false;
    }

    let httpReq = http.createHttp();
    try {
      let options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: '{}',
        connectTimeout: 5000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      };
      let resp = await httpReq.request(this.hdcServerApiUrl('/api/agent_loop/ensure'), options);
      let body = String(resp.result);
      let message = body;
      try {
        let parsed = ArkJSON.parse(body) as JsonMap;
        let parsedMessage = parsed['message'];
        if (typeof parsedMessage === 'string') {
          message = parsedMessage;
        }
      } catch (e) {
      }
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        this.logAgentLoopReady('PC Agent loop 已恢复：' + message, useCloudLog);
        return true;
      }
      this.logAgentLoopReady('PC Agent loop 恢复失败：HTTP ' + resp.responseCode + ' ' + message, useCloudLog);
      return false;
    } catch (e) {
      let err = e as BusinessError;
      this.logAgentLoopReady('PC Agent loop 恢复请求失败：' + err.message, useCloudLog);
      return false;
    } finally {
      httpReq.destroy();
    }
  }

  async startCloudBackend(): Promise<boolean> {
    if (!this.isCloudConfigReady()) {
      this.appendCloudLog('配置不完整：请先填写 Planner / Decider 的服务地址和 API Key。');
      return false;
    }
    this.appendCloudLog(`准备切换到云端 Agent 路由，复用 ${DEFAULT_ENDPOINT_CONFIG.agentRouterPort}...`);
    // 云端模式仍复用 PC 侧同一套 TCP 协议；区别是 App 通过 AgentRouterServer 转发到云端模型。
    this.agentRouter.useCloud();
    return await this.agentRouter.ensureStarted(DEFAULT_ENDPOINT_CONFIG.agentRouterPort, this.filesDir);
  }

  private async ensureLocalModelLoaded(): Promise<boolean> {
    // 本地 Agent 启动前自动加载模型，减少用户遗漏“加载大模型”按钮导致的失败。
    if (this.modelLoaded) {
      return true;
    }

    let cfg = this.modelDir + '/config.json';
    if (!this.prepareCustomOpp()) {
      return false;
    }

    this.output = '未检测到已加载模型，正在自动加载大模型...';
    try {
      let loadResult: string = await mnnllm.loadModel(cfg);
      this.output = loadResult;
      this.modelLoaded = this.output === 'ok';
      if (!this.modelLoaded) {
        this.output = `自动加载模型失败: ${this.output}`;
      }
      return this.modelLoaded;
    } catch (err) {
      let message = err instanceof Error ? (err as Error).message : String(err);
      this.output = '自动加载模型失败: ' + message;
      return false;
    }
  }

  private async startLocalBackend(): Promise<boolean> {
    // 本地模式下 9126 请求会进入 libentry.so/MNN，本函数只负责切换路由并启动监听。
    this.agentRouter.useLocal();
    return await this.agentRouter.ensureStarted(DEFAULT_ENDPOINT_CONFIG.agentRouterPort, this.filesDir);
  }

  private async ensureLocalAgentReady(): Promise<boolean> {
    if (!await this.ensureLocalModelLoaded()) {
      return false;
    }
    if (!await this.ensureHdcServerReadyForTask(false)) {
      return false;
    }
    if (this.hdcServerIp.trim().length === 0) {
      this.output = 'HDC Server 未配置，无法执行本地 Agent。';
      return false;
    }
    return true;
  }

  private async ensureCloudAgentBackend(): Promise<boolean> {
    if (!this.isCloudConfigReady()) {
      this.appendCloudLog('配置不完整：请先填写 Planner / Decider 的服务地址和 API Key。');
      return false;
    }
    if (!await this.ensureHdcServerReadyForTask(true)) {
      return false;
    }
    if (this.hdcServerIp.trim().length === 0) {
      this.appendCloudLog('HDC Server 未配置，无法执行云端 Agent。');
      return false;
    }
    return true;
  }

  private async runHomeRecommendationAgentTask(taskText: string): Promise<void> {
    let result = await this.submitDirectCloudAgentTask(taskText);
    if (!result.success) {
      throw new Error(result.error.length > 0 ? result.error : '云端 Agent 后端未就绪');
    }
    this.currentTab = MainTabIndex.Chat;
  }

  private createAgentLoopRunner(): AgentLoopRunner {
    return new AgentLoopRunner(
      this.filesDir,
      this.hdcServerIp,
      mnnllm,
      this.cloudClient,
      () => this.getCloudConfig(),
      (msg: string) => {
        this.handleLocalAgentLog(msg);
      },
      (msg: string) => {
        this.handleCloudAgentLog(msg);
      },
      async (response: string) => {
        return await this.approveLocalAgentResponse(response);
      },
      async (response: string) => {
        return await this.approveCloudAgentResponse(response);
      }
    );
  }

  private setHomeRecommendationCompleted(id: string, completed: boolean): void {
    if (this.dataManagerFacade === null) {
      dataManagerWarn('setHomeRecommendationCompleted skipped: facade is null');
      return;
    }
    if (this.dataManagerFacade.setHomeRecommendationCompleted(id, completed)) {
      this.homeProfile = this.dataManagerFacade.loadHomeViewModel();
    }
  }

  private async submitDirectCloudAgentTask(taskText: string): Promise<CloudAgentTaskSubmitResult> {
    let task = taskText.trim();
    if (task.length === 0) {
      return { success: false, error: '请先输入云端 Agent 任务。' };
    }
    if (!await this.ensureCloudAgentBackend()) {
      return { success: false, error: '' };
    }
    this.currentTab = MainTabIndex.Chat;
    this.resetCloudLog('云端 Agent 开始执行：' + task);
    this.appendCloudLog('Agent loop 已迁移到 App 内；PC 仅通过 HDC bridge 提供截图和动作执行。');
    this.appendCloudLog(`Planner=${this.cloudPlannerBaseUrl}, Decider=${this.cloudDeciderBaseUrl}`);
    let runner = this.createAgentLoopRunner();
    this.activeAgentRunner = runner;
    try {
      await runner.runCloudTask(task);
      this.appendCloudLog('云端 Agent 任务完成。');
      return { success: true, error: '' };
    } catch (e) {
      let err = e as Error;
      this.appendCloudLog('云端 Agent 执行失败：' + err.message);
      return { success: false, error: err.message };
    } finally {
      this.activeAgentRunner = null;
    }
  }

  private async runWorkflowTask(task: WorkflowTask): Promise<void> {
    if (!this.isCloudConfigReady()) {
      this.appendCloudLog('Workflow 无法启动：请先填写 Planner / Decider 的服务地址和 API Key。');
      WorkflowStorage.updateTaskRun(this.filesDir, task.id, '失败', '云端模型配置不完整');
      return;
    }
    if (!await this.ensureHdcServerReadyForTask(true)) {
      WorkflowStorage.updateTaskRun(this.filesDir, task.id, 'failed', 'HDC Server auto-discovery failed');
      return;
    }
    if (this.hdcServerIp.trim().length === 0) {
      this.appendCloudLog('Workflow 无法启动：请先配置 HDC Server。');
      WorkflowStorage.updateTaskRun(this.filesDir, task.id, '失败', 'HDC Server 未配置');
      return;
    }

    this.currentTab = MainTabIndex.Chat;
    this.resetCloudLog('准备执行 Workflow：' + task.title);
    this.appendCloudLog('Workflow 编排将在 App 沙箱内执行；PC 端仅负责 HDC 截图和动作桥接。');
    this.appendCloudLog('HDC Server=' + this.hdcServerIp);
    let runner = new WorkflowRunner(this.filesDir, this.cloudClient, () => this.getCloudConfig(),
      this.hdcServerIp, (msg: string) => { this.appendCloudLog(msg); });
    try {
      let result: WorkflowRunResult = await runner.runTask(task);
      let message = result.message;
      if (result.dailyLogPath.length > 0) {
        message += '，daily-log 已生成';
      }
      WorkflowStorage.updateTaskRun(this.filesDir, task.id, result.status, message);
      this.appendCloudLog('Workflow 运行摘要：' + result.runDir);
    } catch (e) {
      let err = e as Error;
      WorkflowStorage.updateTaskRun(this.filesDir, task.id, 'failed', err.message);
      this.appendCloudLog('Workflow 执行异常：' + err.message);
      AgentExecutionController.finishExecution('Workflow failed');
    }
  }

  private async sendLocalChatMessage(): Promise<void> {
    if (this.userInput.length === 0 || this.isThinking) {
      return;
    }
    if (!this.modelLoaded && !await this.ensureLocalModelLoaded()) {
      return;
    }
    let msg = this.userInput;
    this.userInput = chatInputAfterAcceptedSend(this.userInput, true);
    this.chatHistory += `\nUser: ${msg}\nAssistant: 思考中...`;
    this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('user'), 'user', CHAT_MESSAGE_KIND_CHAT,
      msg, new Date().getTime()));
    this.isThinking = true;
    try {
      let reply: string = await mnnllm.chat(msg);
      this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('assistant'), 'assistant',
        CHAT_MESSAGE_KIND_CHAT, reply, new Date().getTime()));
      this.chatHistory = this.chatHistory.replace('Assistant: 思考中...', `Assistant: ${reply}\n`);
    } catch (err) {
      let message = err instanceof Error ? (err as Error).message : String(err);
      this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('assistant'), 'assistant',
        CHAT_MESSAGE_KIND_CHAT, '[错误] ' + message, new Date().getTime()));
      this.chatHistory = this.chatHistory.replace('Assistant: 思考中...', `Assistant: [错误] ${message}\n`);
    } finally {
      this.isThinking = false;
    }
  }

  private async submitLocalAgentTask(): Promise<void> {
    let task = this.userInput.trim();
    if (task.length === 0) {
      this.output = '请在输入框输入任务目标，例如：去淘宝买手机';
      return;
    }
    if (this.isThinking) {
      return;
    }
    if (!await this.ensureLocalAgentReady()) {
      return;
    }
    this.ensureActiveChatSession();
    this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('user'), 'user', CHAT_MESSAGE_KIND_CHAT,
      task, new Date().getTime()));
    this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('task-trace'), 'task',
      CHAT_MESSAGE_KIND_TASK_TRACE, '本地任务执行过程', new Date().getTime(), []));
    this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('task-result'), 'task',
      CHAT_MESSAGE_KIND_TASK_RESULT, '本地 Agent 已开始执行。', new Date().getTime()));
    this.localTaskSessionId = this.activeChatSessionId;
    this.debugImagePath = '';
    this.userInput = chatInputAfterAcceptedSend(this.userInput, true);
    this.isThinking = true;
    let runner = this.createAgentLoopRunner();
    this.activeAgentRunner = runner;
    this.output = `====== 本地 Agent 开始执行 ======\n当前任务: ${task}\nAgent loop 在 App 内执行，PC 仅提供 HDC 截图和动作控制。`;
    try {
      await runner.runLocalTask(task);
      this.appendChatMessageForSession(this.localTaskSessionId,
        createChatMessage(this.nextChatMessageId('task-result'), 'task',
          CHAT_MESSAGE_KIND_TASK_RESULT, '任务执行完成。', new Date().getTime()));
      if (this.debugImagePath.length > 0) {
        this.attachTaskResultImage(this.localTaskSessionId, this.debugImagePath);
      }
    } catch (e) {
      let err = e as Error;
      this.appendChatMessageForSession(this.localTaskSessionId,
        createChatMessage(this.nextChatMessageId('task-result'), 'task',
          CHAT_MESSAGE_KIND_TASK_RESULT, '任务执行失败：' + err.message, new Date().getTime()));
    } finally {
      this.activeAgentRunner = null;
      this.localTaskSessionId = '';
      this.isThinking = false;
    }
  }

  private async submitCurrentCloudTask(): Promise<void> {
    let task = this.cloudUserInput.trim();
    if (task.length === 0 || this.cloudThinking) {
      return;
    }
    this.ensureActiveChatSession();
    this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('user'), 'user', CHAT_MESSAGE_KIND_CHAT,
      task, new Date().getTime()));
    this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('task-trace'), 'task',
      CHAT_MESSAGE_KIND_TASK_TRACE, '云端任务执行过程', new Date().getTime(), []));
    this.appendActiveChatMessage(createChatMessage(this.nextChatMessageId('task-result'), 'task',
      CHAT_MESSAGE_KIND_TASK_RESULT, '云端 Agent 已开始执行。', new Date().getTime()));
    this.cloudTaskSessionId = this.activeChatSessionId;
    this.cloudDebugImagePath = '';
    this.cloudUserInput = chatInputAfterAcceptedSend(this.cloudUserInput, true);
    this.cloudThinking = true;
    try {
      let result = await this.submitDirectCloudAgentTask(task);
      if (result.success) {
        this.appendChatMessageForSession(this.cloudTaskSessionId,
          createChatMessage(this.nextChatMessageId('task-result'), 'task',
            CHAT_MESSAGE_KIND_TASK_RESULT, '任务执行完成。', new Date().getTime()));
        if (this.cloudDebugImagePath.length > 0) {
          this.attachTaskResultImage(this.cloudTaskSessionId, this.cloudDebugImagePath);
        }
      } else {
        let errorText = result.error.length > 0 ? result.error : '云端 Agent 后端未就绪';
        this.appendChatMessageForSession(this.cloudTaskSessionId,
          createChatMessage(this.nextChatMessageId('task-result'), 'task',
            CHAT_MESSAGE_KIND_TASK_RESULT, '任务下发失败：' + errorText, new Date().getTime()));
        this.appendCloudLog(errorText);
      }
    } finally {
      this.cloudTaskSessionId = '';
      this.cloudThinking = false;
    }
  }

  private clearCloudDebugImage(): void {
    this.cloudDebugImagePath = '';
  }

  private clearLocalDebugImage(): void {
    this.debugImagePath = '';
  }

  @Builder TabItem(icon: string, label: string, index: number) {
    Column() {
      Text(icon)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.currentTab === index ? Color.White : '#747B87')
        .width(32)
        .height(32)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.currentTab === index ? '#4F68FF' : '#00FFFFFF')
        .borderRadius(16)
      Text(label)
        .fontSize(13)
        .fontColor(this.currentTab === index ? '#4F68FF' : '#747B87')
        .fontWeight(this.currentTab === index ? FontWeight.Bold : FontWeight.Regular)
        .margin({ top: 2 })
        .maxLines(1)
    }.width(72).height(58).justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.currentTab = index;
    })
  }

  @Builder DataManagerProgressOverlay() {
    if (this.dataManagerRefreshing) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          Text(this.dataManagerProgressStage)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#151A28')
            .maxLines(1)
          Progress({ value: this.dataManagerProgressPercent, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(8)
            .color('#4F68FF')
            .backgroundColor('#E7EBF5')
            .margin({ top: 18 })
          Row() {
            Text(`${Math.round(this.dataManagerProgressPercent)}%`)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#4F68FF')
          }
          .width('100%')
          .margin({ top: 10 })
        }
        .width('78%')
        .padding({ left: 22, right: 22, top: 24, bottom: 22 })
        .backgroundColor('#FFFFFFFF')
        .borderRadius(18)
        .shadow({ radius: 22, color: '#33000000', offsetX: 0, offsetY: 8 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#66000000')
      .zIndex(99)
      .onClick(() => {})
    }
  }

  build() {
    Stack() {
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() {
          HomePage({
            profile: this.homeProfile,
            onSetRecommendationCompleted: (id: string, completed: boolean) => {
              this.setHomeRecommendationCompleted(id, completed);
            },
            avatarVersions: this.avatarVersions,
            onExecuteAgentTask: async (taskDescription: string) => {
              await this.runHomeRecommendationAgentTask(taskDescription);
            },
            onGenerateAvatar: async (mode: AvatarGenerationMode, sourceImage: string) => {
              await this.generateHomeAvatar(mode, sourceImage);
            }
          })
        }.tabBar(this.TabItem(mainTabIcon(MainTabIndex.Home), mainTabLabel(MainTabIndex.Home), MainTabIndex.Home))
        TabContent() {
          CollectionPage({
            collectionModule: $collectionModule,
            viewModels: this.collectionViews,
            refreshing: this.dataManagerRefreshing,
            onRefresh: () => { this.refreshDataManager(); }
          })
        }.tabBar(this.TabItem(mainTabIcon(MainTabIndex.Summary), mainTabLabel(MainTabIndex.Summary), MainTabIndex.Summary))
        TabContent() {
          ChatPage({
            chatMode: $chatMode,
            cloudUserInput: $cloudUserInput,
            userInput: $userInput,
            cloudOutput: this.cloudOutput,
            cloudDebugImagePath: this.cloudDebugImagePath,
            cloudThinking: this.cloudThinking,
            localOutput: this.output,
            localDebugImagePath: this.debugImagePath,
            chatHistory: this.chatHistory,
            localThinking: this.isThinking,
            modelLoaded: this.modelLoaded,
            sessions: this.chatSessions,
            activeSessionId: this.activeChatSessionId,
            messages: this.activeChatMessages,
            sessionDrawerOpen: this.chatSessionDrawerOpen,
            restoringLocalSession: this.restoringLocalSession,
            onSwitchMode: async (mode: string) => { await this.switchChatMode(mode); },
            onOpenSessionDrawer: () => { this.chatSessionDrawerOpen = true; },
            onCloseSessionDrawer: () => { this.chatSessionDrawerOpen = false; },
            onCreateSession: (mode: string) => { this.createChatSession(mode); },
            onSelectSession: async (id: string) => { await this.selectChatSession(id); },
            onDeleteSession: async (id: string) => { await this.deleteChatSession(id); },
            onToggleTaskTrace: (id: string) => { this.toggleActiveTaskTrace(id); },
            onRunCloudPlanner: async () => { await this.runCloudPlannerOnce(); },
            onSubmitCloudTask: async () => { await this.submitCurrentCloudTask(); },
            onSendLocalMessage: async () => { await this.sendLocalChatMessage(); },
            onSubmitLocalTask: async () => { await this.submitLocalAgentTask(); },
            onClearCloudDebugImage: () => { this.clearCloudDebugImage(); },
            onClearLocalDebugImage: () => { this.clearLocalDebugImage(); },
            onOpenRuntimeLogs: () => { router.pushUrl({ url: 'pages/LogView' }); }
          })
        }.tabBar(this.TabItem(mainTabIcon(MainTabIndex.Chat), mainTabLabel(MainTabIndex.Chat), MainTabIndex.Chat))
        TabContent() {
          TaskPage({
            taskScene: $taskScene,
            onRunWorkflow: async (task: WorkflowTask) => { await this.runWorkflowTask(task); }
          })
        }.tabBar(this.TabItem(mainTabIcon(MainTabIndex.Task), mainTabLabel(MainTabIndex.Task), MainTabIndex.Task))
        TabContent() {
          SettingsCenterPage({
            autoConfirm: $autoConfirm,
            cloudAutoConfirm: $cloudAutoConfirm,
            threadNumInput: $threadNumInput,
            backendTypeInput: $backendTypeInput,
            mllmBackendTypeInput: $mllmBackendTypeInput,
            output: this.output,
            cloudOutput: this.cloudOutput,
            downloading: this.downloading,
            connected: this.connected,
            hdcAutoStatus: this.hdcAutoStatus,
            hdcAutoConnected: this.hdcAutoConnected,
            hdcAutoConnecting: this.hdcAutoConnecting,
            hdcManualPairing: this.hdcManualPairing,
            selectedModelVariant: this.selectedModelVariant,
            backupBusy: this.backupBusy,
            backupStatus: this.backupStatus,
            onCheckServer: () => { this.checkServer(); },
            onDownloadAll: () => { this.downloadAll(); },
            onDeleteModelFiles: () => { this.deleteModelFiles(); },
            onUpdateConfigThreadNum: () => { this.updateConfigThreadNum(); },
            onShowConfigJson: () => { this.showConfigJson(); },
            onDiscoverHdc: async () => {
              this.hdcManualPairing = false;
              await this.discoverHdcServer(true, true);
            },
            onSetHdcManualPairing: () => { this.setHdcManualPairing(); },
            onMarkHdcManualEditing: () => { this.markHdcManualEditing(); },
            onTestAndConnectHdc: async () => { await this.testAndConnectHdc(); },
            onTestCloudPlanner: async () => { await this.testCloudPlanner(); },
            onStartCloudBackend: async () => { await this.startCloudBackend(); },
            onClearScreenshots: () => { this.clearScreenshots(); },
            onDeleteDebugOutputs: () => { this.deleteDebugOutputs(); },
            onSwitchModelVariant: (variant: string) => { this.switchModelVariant(variant); },
            onListScreenshots: () => { this.listScreenshots(); },
            onDeleteModelConfigJson: () => { this.deleteModelConfigJson(); },
            onListModelFilesTree: () => { this.listModelFilesTree(); },
            onDeleteChunkVisionOmFiles: () => { this.deleteChunkVisionOmFiles(); },
            onUpdateConfigBackendType: (target: string) => { this.updateConfigBackendType(target); },
            onExportEncryptedBackup: async (password: string, includeSensitiveSettings: boolean) => {
              await this.exportEncryptedBackup(password, includeSensitiveSettings);
            },
            onImportEncryptedBackup: async (password: string) => {
              await this.importEncryptedBackup(password);
            }
          })
        }.tabBar(this.TabItem(mainTabIcon(MainTabIndex.Settings), mainTabLabel(MainTabIndex.Settings), MainTabIndex.Settings))
      }
      .onChange((index: number) => { this.currentTab = index; })
      .width('100%')
      .height('100%')
      .backgroundColor('#F4F8FF')

      this.DataManagerProgressOverlay()
    }
    .width('100%')
    .height('100%')
  }
}
