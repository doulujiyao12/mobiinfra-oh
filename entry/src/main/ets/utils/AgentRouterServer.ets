import { socket } from '@kit.NetworkKit';
import { util, JSON as ArkJSON } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { CloudModelClient, CloudModelConfig } from './CloudModelClient';
import { AgentExecutionController } from './AgentExecutionController';
import { HdcWorkflowBridge } from './HdcWorkflowBridge';
import { AppLogger } from './AppLogger';

type RequestValue = Object | string | number | boolean | null;
type AgentRouteMode = 'local' | 'cloud';
type LogHandler = (msg: string) => void;
type ApprovalHandler = (response: string) => Promise<boolean>;
type CloudConfigProvider = () => CloudModelConfig;
type AgentPrefillHandler = (prefix: string) => Promise<string>;
type AgentStepHandler = (variablePart: string, onToken?: (token: string) => void) => Promise<string>;
type AgentResetHandler = () => Promise<string>;
type AgentChatHandler = (userMessage: string) => Promise<string>;
type NativeResetHandler = () => string;
type HdcServerUrlProvider = () => string;

const HOST_APP_BUNDLE_NAME: string = 'com.clawmate.app';

type RequestKey =
  'type' | 'preserve_execution' | 'message' | 'hidden' | 'prefix' | 'variable' |
    'image_b64' | 'width' | 'height' | 'response' | 'prompt';

interface RequestMap {
  type?: RequestValue;
  preserve_execution?: RequestValue;
  message?: RequestValue;
  hidden?: RequestValue;
  prefix?: RequestValue;
  variable?: RequestValue;
  image_b64?: RequestValue;
  width?: RequestValue;
  height?: RequestValue;
  response?: RequestValue;
  prompt?: RequestValue;
}

interface TaskResponse {
  task: string;
}

interface StatusResponse {
  status: string;
  result?: string;
  message?: string;
}

interface ActionErrorResponse {
  action: string;
  reason: string;
}

interface ErrorResponse {
  error: string;
}

interface CloudDebugResponse {
  __cloud_debug_prompt: string;
  response: string;
}

interface CaptureOverlayResponse {
  status: string;
  hidden: boolean;
}

export class AgentRouterServer {
  private server: socket.TCPSocketServer | null = null;
  private isRunning: boolean = false;
  private filesDir: string = '';
  private routeMode: AgentRouteMode = 'local';
  private cloudConnectLogged: boolean = false;
  private cloudActionHistory: string[] = [];
  private cloudTask: string = '';
  private cancellationRequested: boolean = false;
  private localAgentPrefill: AgentPrefillHandler | null = null;
  private localAgentStep: AgentStepHandler | null = null;
  private localAgentReset: AgentResetHandler | null = null;
  private localChat: AgentChatHandler | null = null;
  private localReset: NativeResetHandler | null = null;
  private localLogHandler: LogHandler | null = null;
  private localApprovalHandler: ApprovalHandler | null = null;
  private cloudClientRef: CloudModelClient | null = null;
  private cloudLogHandler: LogHandler | null = null;
  private cloudApprovalHandler: ApprovalHandler | null = null;
  private cloudConfigProvider: CloudConfigProvider | null = null;
  private hdcServerUrlProvider: HdcServerUrlProvider | null = null;
  public currentTask: string = '';

  public running(): boolean {
    return this.isRunning;
  }

  public hasPendingTask(): boolean {
    return this.currentTask.length > 0;
  }

  public getRouteMode(): AgentRouteMode {
    return this.routeMode;
  }

  public configureLocal(agentPrefill: AgentPrefillHandler, agentStep: AgentStepHandler,
    agentReset: AgentResetHandler, chat: AgentChatHandler, reset: NativeResetHandler,
    onLog: LogHandler, onRequireApproval?: ApprovalHandler): void {
    this.localAgentPrefill = agentPrefill;
    this.localAgentStep = agentStep;
    this.localAgentReset = agentReset;
    this.localChat = chat;
    this.localReset = reset;
    this.localLogHandler = onLog;
    this.localApprovalHandler = onRequireApproval ?? null;
  }

  public configureCloud(cloudClient: CloudModelClient, cloudConfigProvider: CloudConfigProvider,
    onLog: LogHandler, onRequireApproval?: ApprovalHandler): void {
    this.cloudClientRef = cloudClient;
    this.cloudConfigProvider = cloudConfigProvider;
    this.cloudLogHandler = onLog;
    this.cloudApprovalHandler = onRequireApproval ?? null;
  }

  public setHdcServerUrlProvider(provider: HdcServerUrlProvider | null): void {
    this.hdcServerUrlProvider = provider;
  }

  public useLocal(): void {
    this.routeMode = 'local';
  }

  public useCloud(): void {
    this.routeMode = 'cloud';
  }

  public async ensureStarted(port: number, filesDir: string): Promise<boolean> {
    if (!this.isRunning) {
      return await this.start(port, filesDir);
    }
    if (this.hasPendingTask()) {
      this.log(this.routeMode, 'Agent router backend is busy; keep current listener.');
      return true;
    }
    return await this.restart(port, filesDir);
  }

  public submitLocalTask(task: string): void {
    this.routeMode = 'local';
    this.currentTask = task;
    this.cloudTask = '';
    this.cloudActionHistory = [];
    this.cloudConnectLogged = false;
    this.clearCancellationState();
  }

  public submitCloudTask(task: string): void {
    this.routeMode = 'cloud';
    this.currentTask = task;
    this.cloudTask = '';
    this.cloudActionHistory = [];
    this.cloudConnectLogged = false;
    this.clearCancellationState();
  }

  public async requestTaskCancellation(): Promise<void> {
    let activeMode = this.routeMode;
    this.cancellationRequested = true;
    this.currentTask = '';
    this.cloudActionHistory = [];
    this.cloudTask = '';
    let returnPromise = this.returnToHostApp(activeMode);
    this.log(activeMode, '>> [Cancel] 用户点击悬浮窗，请求终止当前任务。');

    if (activeMode === 'cloud') {
      try {
        this.cloudClientRef?.cancelActiveRequests();
      } catch (e) {
      }
      await returnPromise;
      return;
    }

    if (!this.localAgentReset || !this.localReset) {
      return;
    }

    try {
      await this.localAgentReset();
    } catch (e) {
    }

    try {
      this.localReset();
    } catch (e) {
    }
    await returnPromise;
  }

  private async returnToHostApp(mode: AgentRouteMode): Promise<boolean> {
    let returned = false;
    if (AgentExecutionController.returnToApp()) {
      this.log(mode, '>> [Cancel] return-to-app handler invoked before local cleanup.');
      returned = true;
    }

    let hdcServerUrl = this.hdcServerUrlProvider ? this.hdcServerUrlProvider().trim() : '';
    if (hdcServerUrl.length === 0) {
      return returned;
    }

    try {
      let bridge = new HdcWorkflowBridge(hdcServerUrl, (message: string) => {
        this.log(mode, message);
      });
      await bridge.startApp(HOST_APP_BUNDLE_NAME, HOST_APP_BUNDLE_NAME, false);
      this.log(mode, '>> [Cancel] returned to host app via HDC bridge before local cleanup.');
      return true;
    } catch (e) {
      let err = e as Error;
      this.log(mode, '>> [Cancel] HDC return to host app failed before cleanup: ' + (err.message || String(e)));
    }
    return returned;
  }

  public async start(port: number, filesDir: string): Promise<boolean> {
    if (this.isRunning) {
      this.log(this.routeMode, 'Agent router backend is already running.');
      return true;
    }

    this.filesDir = filesDir;
    this.cancellationRequested = false;
    let server = socket.constructTCPSocketServerInstance();
    let ipAddress: socket.NetAddress = { address: '0.0.0.0', port: port, family: 1 };

    server.on('connect', (client: socket.TCPSocketConnection) => {
      let bufferStr = '';
      if (this.routeMode === 'cloud' && !this.cloudConnectLogged) {
        this.cloudConnectLogged = true;
        this.log('cloud', '>> [Cloud Connect] PC client connected to App TCP router.');
      }

      client.on('message', async (data) => {
        let textDecoder = util.TextDecoder.create('utf-8');
        let str = textDecoder.decodeWithStream(new Uint8Array(data.message));
        bufferStr += str;

        let eofIdx = bufferStr.indexOf('<<EOF>>');
        if (eofIdx === -1) {
          return;
        }

        let payload = bufferStr.substring(0, eofIdx);
        bufferStr = bufferStr.substring(eofIdx + 7);

        try {
          let req = ArkJSON.parse(payload) as RequestMap;
          await this.handleRequest(client, req);
        } catch (e) {
          let message = String(e);
          if (this.isCancellationRequested()) {
            this.log(this.routeMode, '>> [Request] cancelled during in-flight request.');
            this.sendTerminate(client, 'Task cancelled by user');
            return;
          }
          this.log(this.routeMode, '[ERROR] Routed request handling failed: ' + message);
          this.sendError(client, 'Failed');
        }
      });
    });

    try {
      await server.listen(ipAddress);
      this.server = server;
      this.isRunning = true;
      this.log(this.routeMode,
        '====== Agent router backend started ======\nTCP port: ' + port +
        '\nCloud Agent and local MNN Agent now share the same port via in-app routing.');
      return true;
    } catch (e) {
      this.log(this.routeMode, '[ERROR] Agent router backend failed to start: ' + String(e));
      try {
        await server.close();
      } catch (closeErr) {
      }
      return false;
    }
  }

  public async restart(port: number, filesDir: string): Promise<boolean> {
    await this.stop();
    return await this.start(port, filesDir);
  }

  public async stop(): Promise<void> {
    let oldServer = this.server;
    this.server = null;
    this.isRunning = false;
    if (oldServer === null) {
      return;
    }

    try {
      await oldServer.close();
    } catch (e) {
      this.log(this.routeMode, 'Agent router backend close warning: ' + String(e));
    }
  }

  private async handleRequest(client: socket.TCPSocketConnection, req: RequestMap): Promise<void> {
    let reqType = this.getString(req, 'type');

    if (reqType === 'poll') {
      if (this.routeMode === 'cloud' && this.currentTask.length > 0) {
        this.log('cloud', '>> [Cloud Poll] PC fetched task: ' + this.currentTask);
      }
      this.sendTask(client);
      return;
    }

    if (reqType === 'clear') {
      await this.handleClear(client, this.getBoolean(req, 'preserve_execution'));
      return;
    }

    if (reqType === 'error') {
      this.currentTask = '';
      this.finishExecution();
      this.log(this.routeMode, '>> [PC Error] ' + this.getString(req, 'message'));
      this.sendStatus(client, 'ok');
      return;
    }

    if (reqType === 'capture_overlay_hide') {
      let hidden = await AgentExecutionController.hideCaptureOverlay();
      let response: CaptureOverlayResponse = {
        status: 'ok',
        hidden: hidden
      };
      this.sendJson(client, ArkJSON.stringify(response));
      return;
    }

    if (reqType === 'capture_overlay_restore') {
      let hidden = this.getBoolean(req, 'hidden');
      await AgentExecutionController.restoreCaptureOverlay(hidden);
      this.sendStatus(client, 'ok');
      return;
    }

    if (this.isCancellationRequested()) {
      this.log(this.routeMode, '>> [Cancel] cancellation intercepted before handling request: ' + reqType);
      this.sendTerminate(client, 'Task cancelled by user');
      return;
    }

    await AgentExecutionController.waitIfPaused();
    if (this.isCancellationRequested()) {
      this.log(this.routeMode, '>> [Cancel] cancellation intercepted after pause: ' + reqType);
      this.sendTerminate(client, 'Task cancelled by user');
      return;
    }

    if (this.routeMode === 'cloud') {
      await this.handleCloudRequest(client, req, reqType);
      return;
    }

    await this.handleLocalRequest(client, req, reqType);
  }

  private async handleClear(client: socket.TCPSocketConnection, preserveExecution: boolean): Promise<void> {
    this.currentTask = '';

    if (this.routeMode === 'cloud') {
      this.cloudActionHistory = [];
      this.cloudTask = '';
      this.log('cloud', '>> [Cloud Clear] Task and cloud history cleared.');
      if (!preserveExecution) {
        this.finishExecution();
      }
      this.sendStatus(client, 'ok');
      return;
    }

    if (this.localAgentReset) {
      try {
        await this.localAgentReset();
      } catch (e) {
        if (this.localReset) {
          this.localReset();
        }
      }
    }

    this.log('local', '>> [Local Clear] Task cleared and model context reset.');
    if (!preserveExecution) {
      this.finishExecution();
    }
    this.sendStatus(client, 'ok');
  }

  private async handleLocalRequest(client: socket.TCPSocketConnection, req: RequestMap, reqType: string): Promise<void> {
    if (!this.localAgentPrefill || !this.localAgentStep || !this.localAgentReset || !this.localChat) {
      this.log('local', '[ERROR] Local backend is not configured.');
      this.sendError(client, 'Local backend unavailable');
      return;
    }

    if (reqType === 'agent_prefill') {
      let prefix = this.getString(req, 'prefix');
      this.log('local', '>> [Agent Prefill] prompt chars=' + prefix.length + '\n' + prefix);
      AgentExecutionController.updateFloatText('Prefill...');
      try {
        let result = await this.localAgentPrefill(prefix);
        if (this.isCancellationRequested()) {
          this.log('local', '>> [Agent Prefill] cancelled by user.');
          this.sendStatus(client, 'cancelled', '', 'Task cancelled by user');
          return;
        }
        AgentExecutionController.updateFloatText('AI Agent running...');
        this.log('local', '>> [Agent Prefill Done] ' + result);
        this.sendStatus(client, 'ok', result);
      } catch (e) {
        let message = String(e);
        if (this.isCancellationRequested()) {
          this.log('local', '>> [Agent Prefill] cancelled while running.');
          this.sendStatus(client, 'cancelled', '', 'Task cancelled by user');
          return;
        }
        this.log('local', '>> [Agent Prefill ERROR] ' + message);
        this.sendStatus(client, 'error', '', message);
      }
      return;
    }

    if (reqType === 'agent_step') {
      let variable = this.getString(req, 'variable');
      let imageBase64 = this.getString(req, 'image_b64');
      if (imageBase64.length > 0) {
        let imgPath = this.saveSnapshot(this.filesDir, imageBase64);
        let w = this.getScalarText(req, 'width');
        let h = this.getScalarText(req, 'height');
        let imgTag = '<img>' + imgPath + '<hw>' + h + ',' + w + '</hw></img>';
        this.log('local', '>> [Agent Step] image saved: ' + imgPath + ' (' + w + 'x' + h + ')');
        if (variable.indexOf('<image_placeholder>') !== -1) {
          variable = variable.replace('<image_placeholder>', imgTag);
        } else {
          variable = imgTag + variable;
        }
      }

      this.log('local', '>> [Agent Step] variable prompt:\n' + variable);
      AgentExecutionController.updateFloatText('Thinking...');
      let streamedText = '';
      try {
        let response = await this.localAgentStep(variable, (token: string) => {
          if (this.isCancellationRequested()) {
            return;
          }
          streamedText += token;
          AgentExecutionController.replaceFloatText(streamedText);
        }) as string;
        if (this.isCancellationRequested()) {
          this.log('local', '>> [Agent Step] cancelled after inferencing.');
          this.sendTerminate(client, 'Task cancelled by user');
          return;
        }
        AgentExecutionController.updateFloatText('AI Agent running...');
        this.log('local', '>> [Agent Step] model response:\n' + response);

        if (this.localApprovalHandler) {
          let isApproved = await this.localApprovalHandler(response);
          if (this.isCancellationRequested()) {
            this.log('local', '>> [Agent Step] cancelled while waiting for approval.');
            this.sendTerminate(client, 'Task cancelled by user');
            return;
          }
          if (!isApproved) {
            this.currentTask = '';
            this.finishExecution();
            this.sendActionError(client, 'User rejected');
            return;
          }
        }

        if (response.indexOf('"done"') !== -1 || response.indexOf('"stop"') !== -1) {
          this.currentTask = '';
          this.finishExecution();
          this.log('local', '>> [Agent] Task completed.');
        }

        this.sendJson(client, response);
      } catch (e) {
        let message = String(e);
        if (this.isCancellationRequested() || message.indexOf('__agent_cancelled__') !== -1) {
          this.log('local', '>> [Agent Step] cancelled during inferencing.');
          this.sendTerminate(client, 'Task cancelled by user');
          return;
        }
        this.log('local', '>> [Agent Step ERROR] ' + message);
        this.sendActionError(client, message);
      }
      return;
    }

    if (reqType === 'agent_reset') {
      try {
        await this.localAgentReset();
      } catch (e) {
      }
      this.currentTask = '';
      AgentExecutionController.updateFloatText('AI Agent running...');
      this.log('local', '>> [Agent Reset] Local Agent context reset.');
      this.sendStatus(client, 'ok');
      return;
    }

    if (reqType === 'action') {
      let prompt = this.getString(req, 'prompt');
      let imageBase64 = this.getString(req, 'image_b64');
      if (imageBase64.length > 0) {
        let imgPath = this.saveSnapshot(this.filesDir, imageBase64);
        let w = this.getScalarText(req, 'width');
        let h = this.getScalarText(req, 'height');
        let imgTag = '<img>' + imgPath + '<hw>' + h + ',' + w + '</hw></img>';
        this.log('local', '>> [Action] image saved: ' + imgPath + ' (' + w + 'x' + h + ')');
        if (prompt.indexOf('<image_placeholder>') !== -1) {
          prompt = prompt.replace('<image_placeholder>', imgTag);
        } else {
          prompt = imgTag + '\n' + prompt;
        }
      }

      this.log('local', '>> [Action] full prompt:\n' + prompt);
      AgentExecutionController.updateFloatText('Inferencing...');
      let chat = this.localChat;
      if (!chat) {
        this.log('local', '[ERROR] Local chat API is unavailable.');
        this.sendError(client, 'Local chat API is unavailable');
        return;
      }
      let response = await chat(prompt) as string;
      if (this.isCancellationRequested()) {
        this.log('local', '>> [Action] cancelled after inferencing.');
        this.sendTerminate(client, 'Task cancelled by user');
        return;
      }
      AgentExecutionController.updateFloatText('AI Agent running...');
      this.log('local', '>> [Action] model response:\n' + response);

      if (this.localApprovalHandler) {
        let isApproved = await this.localApprovalHandler(response);
        if (this.isCancellationRequested()) {
          this.log('local', '>> [Action] cancelled while waiting for approval.');
          this.sendTerminate(client, 'Task cancelled by user');
          return;
        }
        if (!isApproved) {
          this.currentTask = '';
          this.finishExecution();
          this.sendActionError(client, 'User rejected');
          return;
        }
      }

      if (response.indexOf('"done"') !== -1 || response.indexOf('"stop"') !== -1) {
        this.currentTask = '';
        this.finishExecution();
        this.log('local', '>> [Action] Task completed.');
      }

      this.sendJson(client, response);
      return;
    }

    this.sendError(client, 'Unsupported request type: ' + reqType);
  }

  private async handleCloudRequest(client: socket.TCPSocketConnection, req: RequestMap, reqType: string): Promise<void> {
    let cloudClient = this.cloudClientRef;
    let cloudConfig = this.getCloudConfig();
    if (!cloudClient || !cloudConfig) {
      this.log('cloud', '[ERROR] Cloud backend is not configured.');
      this.sendError(client, 'Cloud backend unavailable');
      return;
    }

    if (reqType !== 'poll') {
      this.log('cloud', '>> [Cloud Request] type=' + reqType);
    }

    if (reqType === 'cloud_history_append') {
      let response = this.getString(req, 'response');
      if (response.length > 0) {
        this.cloudActionHistory.push(this.normalizeCloudHistoryItem(response));
        this.log('cloud', '>> [Cloud History] appended after PC execution success, history=' + this.cloudActionHistory.length);
      }
      this.sendStatus(client, 'ok');
      return;
    }

    if (reqType === 'agent_prefill') {
      let prefix = this.getString(req, 'prefix');
      this.cloudActionHistory = [];
      this.cloudTask = this.extractCloudTask(prefix);
      this.log('cloud', '>> [Cloud Agent Prefill] Qwen prompt mode, task=' + this.cloudTask);
      if (this.isCancellationRequested()) {
        this.sendStatus(client, 'cancelled', '', 'Task cancelled by user');
        return;
      }
      this.sendStatus(client, 'ok', 'cloud qwen prompt mode');
      return;
    }

    if (reqType === 'agent_step') {
      let prompt = this.getString(req, 'variable');
      let imageBase64 = this.getString(req, 'image_b64');
      if (imageBase64.length > 0) {
        let imgPath = this.saveSnapshot(this.filesDir, imageBase64);
        this.log('cloud', '>> [Cloud Agent Step] image saved: ' + imgPath);
      }

      AgentExecutionController.updateFloatText('Cloud thinking...');
      if (imageBase64.length > 0) {
        this.log('cloud', '>> [Cloud Decider] sending Qwen messages, history=' + this.cloudActionHistory.length);
      } else {
        this.log('cloud', '>> [Cloud Planner] sending agent_step text...');
      }

      let qwenTask = this.cloudTask.length > 0 ? this.cloudTask : this.currentTask;
      let debugPrompt = '';
      if (imageBase64.length > 0) {
        debugPrompt = cloudClient.formatQwenDeciderPromptForLog(qwenTask, this.cloudActionHistory, imageBase64);
        this.log('cloud', '>> [Cloud Decider Prompt]\n' + debugPrompt);
      }
      let response = imageBase64.length > 0 ?
        await cloudClient.chatQwenDecider(qwenTask, this.cloudActionHistory, imageBase64, cloudConfig) :
        await cloudClient.chatPlanner(prompt, cloudConfig);
      if (this.isCancellationRequested()) {
        this.log('cloud', '>> [Cloud Agent Step] cancelled after inferencing.');
        this.sendTerminate(client, 'Task cancelled by user');
        return;
      }
      AgentExecutionController.updateFloatText('AI Agent running...');
      this.log('cloud', '>> [Cloud Agent Step] model response:\n' + response);

      if (this.cloudApprovalHandler) {
        let isApproved = await this.cloudApprovalHandler(response);
        if (this.isCancellationRequested()) {
          this.log('cloud', '>> [Cloud Agent Step] cancelled while waiting for approval.');
          this.sendTerminate(client, 'Task cancelled by user');
          return;
        }
        if (!isApproved) {
          this.currentTask = '';
          this.finishExecution();
          this.sendActionError(client, 'User rejected');
          return;
        }
      }

      if (response.indexOf('"done"') !== -1 || response.indexOf('"stop"') !== -1) {
        this.currentTask = '';
        this.finishExecution();
        this.log('cloud', '>> [Cloud Agent] Task completed.');
      }
      if (imageBase64.length > 0) {
        this.sendCloudDebugResponse(client, debugPrompt, response);
        return;
      }
      this.sendJson(client, response);
      return;
    }

    if (reqType === 'agent_reset') {
      this.currentTask = '';
      this.cloudActionHistory = [];
      this.cloudTask = '';
      AgentExecutionController.updateFloatText('AI Agent running...');
      this.log('cloud', '>> [Cloud Agent Reset] Cloud Agent context reset.');
      this.sendStatus(client, 'ok');
      return;
    }

    if (reqType === 'action') {
      let prompt = this.getString(req, 'prompt');
      let imageBase64 = this.getString(req, 'image_b64');
      if (imageBase64.length > 0) {
        let imgPath = this.saveSnapshot(this.filesDir, imageBase64);
        this.log('cloud', '>> [Cloud Action] image saved: ' + imgPath);
      }

      AgentExecutionController.updateFloatText('Cloud inferencing...');
      if (imageBase64.length > 0) {
        this.log('cloud', '>> [Cloud Decider] sending action with screenshot...');
      } else {
        this.log('cloud', '>> [Cloud Planner] sending action text...');
      }
      let response = imageBase64.length > 0 ?
        await cloudClient.chatDecider(prompt, imageBase64, cloudConfig) :
        await cloudClient.chatPlanner(prompt, cloudConfig);
      if (this.isCancellationRequested()) {
        this.log('cloud', '>> [Cloud Action] cancelled after inferencing.');
        this.sendTerminate(client, 'Task cancelled by user');
        return;
      }
      AgentExecutionController.updateFloatText('AI Agent running...');
      this.log('cloud', '>> [Cloud Action] model response:\n' + response);

      if (this.cloudApprovalHandler) {
        let isApproved = await this.cloudApprovalHandler(response);
        if (this.isCancellationRequested()) {
          this.log('cloud', '>> [Cloud Action] cancelled while waiting for approval.');
          this.sendTerminate(client, 'Task cancelled by user');
          return;
        }
        if (!isApproved) {
          this.currentTask = '';
          this.finishExecution();
          this.sendActionError(client, 'User rejected');
          return;
        }
      }

      if (response.indexOf('"done"') !== -1 || response.indexOf('"stop"') !== -1) {
        this.currentTask = '';
        this.finishExecution();
      }
      this.sendJson(client, response);
      return;
    }

    this.sendError(client, 'Unsupported request type: ' + reqType);
  }

  private isCancellationRequested(): boolean {
    return this.cancellationRequested || AgentExecutionController.isCancelRequested();
  }

  private clearCancellationState(): void {
    this.cancellationRequested = false;
  }

  private finishExecution(reason?: string): void {
    this.clearCancellationState();
    AgentExecutionController.finishExecution(reason ?? 'AI Agent running...');
  }

  private getCloudConfig(): CloudModelConfig | null {
    return this.cloudConfigProvider ? this.cloudConfigProvider() : null;
  }

  private log(mode: AgentRouteMode, message: string): void {
    AppLogger.info('AgentRouter.' + mode, message);
    if (mode === 'cloud') {
      this.cloudLogHandler?.(message);
      return;
    }
    this.localLogHandler?.(message);
  }

  private extractCloudTask(prefix: string): string {
    let marker = '### Current Task';
    let start = prefix.indexOf(marker);
    if (start < 0) {
      return this.currentTask;
    }
    let rest = prefix.substring(start + marker.length).trim();
    let nextSection = rest.indexOf('\n### ');
    if (nextSection >= 0) {
      rest = rest.substring(0, nextSection).trim();
    }
    return rest.length > 0 ? rest : this.currentTask;
  }

  private cleanupSnapshots(filesDir: string): void {
    try {
      let files = fs.listFileSync(filesDir);
      for (let fileName of files) {
        if (fileName.startsWith('agent_snapshot_')) {
          fs.unlinkSync(filesDir + '/' + fileName);
        }
      }
    } catch (e) {
    }
  }

  private saveSnapshot(filesDir: string, imageBase64: string): string {
    this.cleanupSnapshots(filesDir);
    let ts = new Date().getTime();
    let imgPath = filesDir + '/agent_snapshot_' + ts + '.jpg';
    let base64Helper = new util.Base64Helper();
    let imgBuffer = base64Helper.decodeSync(imageBase64);
    try {
      let file = fs.openSync(imgPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, imgBuffer.buffer);
      } finally {
        fs.closeSync(file);
      }
      return imgPath;
    } catch (e) {
      let err = e as Error;
      throw err;
    }
  }

  private getRequestValue(req: RequestMap, key: RequestKey): RequestValue | undefined {
    switch (key) {
      case 'type':
        return req.type;
      case 'preserve_execution':
        return req.preserve_execution;
      case 'message':
        return req.message;
      case 'hidden':
        return req.hidden;
      case 'prefix':
        return req.prefix;
      case 'variable':
        return req.variable;
      case 'image_b64':
        return req.image_b64;
      case 'width':
        return req.width;
      case 'height':
        return req.height;
      case 'response':
        return req.response;
      case 'prompt':
        return req.prompt;
    }
  }

  private getString(req: RequestMap, key: RequestKey): string {
    let value = this.getRequestValue(req, key);
    return typeof value === 'string' ? value : '';
  }

  private getBoolean(req: RequestMap, key: RequestKey): boolean {
    let value = this.getRequestValue(req, key);
    return value === true || value === 'true';
  }

  private getScalarText(req: RequestMap, key: RequestKey): string {
    let value = this.getRequestValue(req, key);
    if (typeof value === 'number' || typeof value === 'string' || typeof value === 'boolean') {
      return String(value);
    }
    return '';
  }

  private sendJson(client: socket.TCPSocketConnection, payload: string): void {
    let sendOptions: socket.TCPSendOptions = {
      data: payload + '<<EOF>>'
    };
    try {
      client.send(sendOptions);
    } catch (e) {
      let err = e as Error;
      throw err;
    }
  }

  private sendStatus(client: socket.TCPSocketConnection, status: string, result?: string, message?: string): void {
    let response: StatusResponse = {
      status: status,
      result: result,
      message: message
    };
    this.sendJson(client, ArkJSON.stringify(response));
  }

  private sendTask(client: socket.TCPSocketConnection): void {
    let response: TaskResponse = {
      task: this.currentTask
    };
    this.sendJson(client, ArkJSON.stringify(response));
  }

  private sendActionError(client: socket.TCPSocketConnection, reason: string): void {
    let response: ActionErrorResponse = {
      action: 'error',
      reason: reason
    };
    this.sendJson(client, ArkJSON.stringify(response));
  }

  private sendError(client: socket.TCPSocketConnection, error: string): void {
    let response: ErrorResponse = {
      error: error
    };
    this.sendJson(client, ArkJSON.stringify(response));
  }

  private sendCloudDebugResponse(client: socket.TCPSocketConnection, debugPrompt: string, modelResponse: string): void {
    let response: CloudDebugResponse = {
      __cloud_debug_prompt: debugPrompt,
      response: modelResponse
    };
    this.sendJson(client, ArkJSON.stringify(response));
  }

  private sendTerminate(client: socket.TCPSocketConnection, reason: string): void {
    this.sendJson(client, ArkJSON.stringify({
      action: 'terminate',
      reasoning: reason,
      parameters: {
        status: 'cancelled',
        message: reason
      }
    }));
  }

  private normalizeCloudHistoryItem(response: string): string {
    let text = response.trim();
    let jsonStart = text.indexOf('{');
    let jsonEnd = text.lastIndexOf('}');
    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      text = text.substring(jsonStart, jsonEnd + 1);
    }

    try {
      let parsed = ArkJSON.parse(text) as Object;
      return ArkJSON.stringify(parsed);
    } catch (e) {
      return response;
    }
  }
}
