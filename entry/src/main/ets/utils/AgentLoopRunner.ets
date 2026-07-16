import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { CloudModelClient, CloudModelConfig } from './CloudModelClient';
import { AgentExecutionController } from './AgentExecutionController';
import { HdcWorkflowBridge } from './HdcWorkflowBridge';
import { AgentPromptTemplates } from './AgentPromptTemplates';
import { AgentActionParser, ParsedAgentAction } from './AgentActionParser';
import { AgentActionParseRetry, AgentActionParseRetryInfo } from './AgentActionParseRetry';
import {
  agentPostActionDelayMs,
  DEFAULT_AGENT_POST_ACTION_DELAY_MS
} from './AgentLoopTimingPolicy';
import { HdcBridgeResponse, WorkflowJsonMap } from './WorkflowTypes';
import { AppLogger } from './AppLogger';
import { AgentLoopNativeApi } from 'libentry.so';

type AgentLoopMode = 'local' | 'cloud';
export type AgentPromptMode = 'local' | 'cloud';
type LogHandler = (message: string) => void;
type ApprovalHandler = (response: string) => Promise<boolean>;
type CloudConfigProvider = () => CloudModelConfig;

interface PlannerTarget {
  appName: string;
  packageName: string;
}

const MAX_AGENT_STEPS: number = 15;
const HOST_APP_BUNDLE_NAME: string = 'com.clawmate.app';

export class AgentLoopRunner {
  private filesDir: string;
  private modelDirPath: string;
  private localApi: AgentLoopNativeApi;
  private cloudClient: CloudModelClient;
  private cloudConfigProvider: CloudConfigProvider;
  private hdcBridge: HdcWorkflowBridge;
  private localLogHandler: LogHandler;
  private cloudLogHandler: LogHandler;
  private localApprovalHandler: ApprovalHandler;
  private cloudApprovalHandler: ApprovalHandler;
  private mode: AgentLoopMode = 'local';
  private noReasonMode: boolean = false;
  private cancellationRequested: boolean = false;
  private cloudActionHistory: string[] = [];
  private cloudTask: string = '';
  private localActionCallCount: number = 0;
  private cloudPromptMode: AgentPromptMode = 'cloud';
  private postActionDelayMs: number = DEFAULT_AGENT_POST_ACTION_DELAY_MS;

  // 使用显式构造参数，避免 ArkTS 对跨文件 options 对象字面量的限制。
  constructor(
    filesDir: string,
    modelDir: string,
    hdcServerIp: string,
    localApi: AgentLoopNativeApi,
    cloudClient: CloudModelClient,
    cloudConfigProvider: CloudConfigProvider,
    localLogHandler: LogHandler,
    cloudLogHandler: LogHandler,
    localApprovalHandler: ApprovalHandler,
    cloudApprovalHandler: ApprovalHandler,
    cloudPromptMode: AgentPromptMode = 'cloud'
  ) {
    this.filesDir = filesDir;
    this.modelDirPath = modelDir;
    this.localApi = localApi;
    this.cloudClient = cloudClient;
    this.cloudConfigProvider = cloudConfigProvider;
    this.hdcBridge = new HdcWorkflowBridge(hdcServerIp, cloudLogHandler);
    this.localLogHandler = localLogHandler;
    this.cloudLogHandler = cloudLogHandler;
    this.localApprovalHandler = localApprovalHandler;
    this.cloudApprovalHandler = cloudApprovalHandler;
    this.cloudPromptMode = cloudPromptMode;
  }

  getMode(): AgentLoopMode {
    return this.mode;
  }

  async requestCancellation(): Promise<void> {
    let activeMode = this.mode;
    this.cancellationRequested = true;
    if (activeMode === 'cloud') {
      this.cloudClient.cancelActiveRequests();
    }
    await this.returnToHostApp(activeMode);
    if (activeMode === 'local') {
      await this.resetLocalContext();
    }
  }

  async runLocalTask(task: string): Promise<void> {
    this.mode = 'local';
    this.cancellationRequested = false;
    this.localActionCallCount = 0;
    this.postActionDelayMs = DEFAULT_AGENT_POST_ACTION_DELAY_MS;
    AgentExecutionController.beginExecution('本地 Agent 执行中...');
    try {
      await this.syncAgentConfig();
      await this.hdcBridge.prepareAgentRun();
      await this.resetLocalContext();
      let plannerTarget = await this.runPlanner(task, 'local');
      this.configureTargetTiming(plannerTarget);
      await this.launchTargetApp(plannerTarget);
      await this.resetLocalContext();
      await this.runAgentSteps(task, 'local');
      await this.returnToHostApp('local');
      AgentExecutionController.finishExecution('本地 Agent 已完成');
    } catch (e) {
      let err = e as Error;
      if (!this.isCancellationRequested()) {
        await this.returnToHostApp('local');
      }
      AgentExecutionController.finishExecution('本地 Agent 结束');
      throw err;
    } finally {
      await this.resetLocalContext();
    }
  }

  async runCloudTask(task: string, returnToHostAppOnFinish: boolean): Promise<void> {
    this.mode = 'cloud';
    this.cancellationRequested = false;
    this.cloudActionHistory = [];
    this.cloudTask = '';
    this.postActionDelayMs = DEFAULT_AGENT_POST_ACTION_DELAY_MS;
    AgentExecutionController.beginExecution('云端 Agent 执行中...');
    try {
      await this.syncAgentConfig();
      await this.hdcBridge.prepareAgentRun();
      let plannerTarget = await this.runPlanner(task, 'cloud', this.promptModeForCloudRequest());
      this.configureTargetTiming(plannerTarget);
      await this.launchTargetApp(plannerTarget);
      this.cloudActionHistory = [];
      await this.runAgentSteps(task, 'cloud', this.promptModeForCloudRequest());
      if (returnToHostAppOnFinish) {
        await this.returnToHostApp('cloud');
      } else {
        this.log('cloud', '>> [Agent] stay in target app after task completion.');
      }
      AgentExecutionController.finishExecution('云端 Agent 已完成');
    } catch (e) {
      let err = e as Error;
      this.cloudClient.cancelActiveRequests();
      if (!this.isCancellationRequested()) {
        await this.returnToHostApp('cloud');
      }
      AgentExecutionController.finishExecution('云端 Agent 结束');
      throw err;
    } finally {
      this.cloudActionHistory = [];
      this.cloudTask = '';
    }
  }

  private async syncAgentConfig(): Promise<void> {
    try {
      let response = await this.hdcBridge.agentConfig();
      if (response.status === 'ok' && typeof response.no_reason === 'boolean') {
        this.noReasonMode = response.no_reason;
      }
    } catch (e) {
      this.noReasonMode = false;
    }
  }

  private promptModeForCloudRequest(): AgentPromptMode {
    return this.cloudPromptMode === 'local' ? 'local' : 'cloud';
  }

  private async runPlanner(task: string, mode: AgentLoopMode, promptMode: AgentPromptMode = mode): Promise<PlannerTarget> {
    this.checkCancellation();
    let template = AgentPromptTemplates.load('planner_oneshot_harmony.md');
    if (template.trim().length === 0) {
      template = AgentPromptTemplates.load('planner.md');
    }
    if (template.trim().length === 0) {
      throw new Error('Planner prompt template is missing');
    }

    let prompt = template.replace('{task_description}', task).replace('<task_description>', task);
    if (prompt.indexOf(task) < 0) {
      prompt += '\n\n用户任务: ' + task;
    }

    let stageTitle = mode === 'cloud' && promptMode === 'local' ? 'PCAgent Stage 1' : 'Stage 1 - Planner';
    this.log(mode, '>> [' + stageTitle + '] prompt mode=' + promptMode + ', chars=' + prompt.length + '\n' + prompt);
    let response = mode === 'local' ? await this.runLocalAction(prompt, undefined, undefined, undefined, 'planner') :
      (promptMode === 'local' ? await this.runPcAgentPrompt(prompt, '', 'Stage 1') : await this.runCloudPlanner(prompt));
    let data = AgentActionParser.extractJsonMap(response, true);
    let action = AgentActionParser.getMapString(data, 'action').toLowerCase();
    if (action === 'error') {
      throw new Error(AgentActionParser.getMapString(data, 'reason', response));
    }
    if (action === 'terminate' || action === 'stop' || action === 'abort') {
      throw new Error('Planner cancelled the task: ' + action);
    }

    let appName = AgentActionParser.getMapString(data, 'app');
    if (appName.length === 0) {
      appName = AgentActionParser.getMapString(data, 'target_app');
    }
    if (appName.length === 0) {
      appName = AgentActionParser.getMapString(data, 'app_name');
    }
    let packageName = AgentActionParser.getMapString(data, 'package_name');
    if (packageName.length === 0) {
      packageName = AgentActionParser.getMapString(data, 'bundle');
    }
    if (packageName.length === 0) {
      packageName = AgentActionParser.getMapString(data, 'bundle_name');
    }
    if (appName.length === 0 && packageName.length > 0) {
      appName = packageName;
    }
    if (appName.length === 0) {
      throw new Error('Planner output missing app_name/package_name');
    }
    this.log(mode, '>> [Planner] parsed target: app=' + appName + ', package=' +
      (packageName.length > 0 ? packageName : '(empty)'));
    let target: PlannerTarget = {
      appName: appName,
      packageName: packageName
    };
    return target;
  }

  private async launchTargetApp(target: PlannerTarget): Promise<void> {
    this.checkCancellation();
    this.log(this.mode, '>> [Planner] launching target app: ' + target.appName + ' ' + target.packageName);
    await this.hdcBridge.startApp(target.appName, target.packageName, true);
    await this.sleep(300);
  }

  private configureTargetTiming(target: PlannerTarget): void {
    this.postActionDelayMs = agentPostActionDelayMs(target.appName, target.packageName);
    this.log(this.mode, '>> [Agent] post-action screenshot delay=' + String(this.postActionDelayMs) +
      'ms for target app=' + target.appName + ', package=' +
      (target.packageName.length > 0 ? target.packageName : '(empty)'));
  }

  private async returnToHostApp(mode: AgentLoopMode): Promise<boolean> {
    try {
      await this.hdcBridge.startApp(HOST_APP_BUNDLE_NAME, HOST_APP_BUNDLE_NAME, false);
      this.log(mode, '>> [Agent] returned to host app via HDC bridge.');
      return true;
    } catch (e) {
      let err = e as Error;
      this.log(mode, '>> [Agent] HDC return to host app failed: ' + (err.message || String(e)));
    }

    if (AgentExecutionController.returnToApp()) {
      this.log(mode, '>> [Agent] return-to-app handler invoked.');
      return true;
    }
    this.log(mode, '>> [Agent] return-to-app handler is unavailable.');
    return false;
  }

  private async runAgentSteps(task: string, mode: AgentLoopMode, promptMode: AgentPromptMode = mode): Promise<void> {
    this.checkCancellation();
    let useNoReasonPrompt = this.resolveAgentNoReasonMode();
    let prefixFile = useNoReasonPrompt ? 'e2e_v2_agent_prefix_noreason.md' : 'e2e_v2_agent_prefix.md';
    this.log(mode, '>> [Agent] prompt mode=' + promptMode + '/' + (useNoReasonPrompt ? 'no_reason' : 'reason'));
    this.log(mode, '>> [Agent] prefix source=' + AgentPromptTemplates.promptSource(this.modelDirPath, prefixFile));
    let prefixTemplate = AgentPromptTemplates.loadFromModelDir(this.modelDirPath, prefixFile);
    if (prefixTemplate.trim().length === 0) {
      this.log(mode, '>> [Agent] prefix template missing, fallback to full prompt mode.');
      await this.runFullPromptMode(task, mode);
      return;
    }
    let prefix = prefixTemplate.replace('{task}', task);
    let useCloudWithLocalPrompt = mode === 'cloud' && promptMode === 'local';
    if (mode === 'local') {
      await this.localAgentPrefill(prefix);
    } else if (useCloudWithLocalPrompt) {
      this.cloudActionHistory = [];
      this.cloudTask = task;
      this.log('cloud', '>> [PCAgent Prefill] local prompt mode, prefix chars=' + prefix.length);
    } else {
      this.cloudActionHistory = [];
      this.cloudTask = this.extractCloudTask(prefix, task);
      this.log('cloud', '>> [Cloud Agent Prefill] Qwen prompt mode, task=' + this.cloudTask);
    }

    let screenshotFactor = mode === 'cloud' && promptMode !== 'local' ? 0.5 : 0.25;
    let inverseScreenshotFactor = Math.round(1 / screenshotFactor);
    let variableFile = useNoReasonPrompt ? 'e2e_v2_agent_variable_noreason.md' : 'e2e_v2_agent_variable.md';
    this.log(mode, '>> [Agent] variable source=' + AgentPromptTemplates.promptSource(this.modelDirPath, variableFile));
    let variableTemplate = AgentPromptTemplates.loadFromModelDir(this.modelDirPath, variableFile);
    if (variableTemplate.trim().length === 0) {
      this.log(mode, '>> [Agent] variable template missing, fallback to full prompt mode.');
      if (mode === 'local') {
        await this.localAgentReset();
      }
      await this.runFullPromptMode(task, mode);
      return;
    }

    let localHistory: string[] = [];
    let completed = false;
    try {
      for (let i = 0; i < MAX_AGENT_STEPS; i++) {
        await this.waitForRunnableState();
        let agentLabel = useCloudWithLocalPrompt ? 'PCAgent' : ((mode === 'cloud' ? 'Cloud' : 'MNN') + ' Agent');
        AgentExecutionController.updateFloatText(agentLabel + ' ' + (i + 1) + '/' + MAX_AGENT_STEPS + ': 截图');
        let shot = await this.hdcBridge.screenshotWithFactor(screenshotFactor);
        let imageBase64 = shot.image_b64 || '';
        let width = shot.width || 0;
        let height = shot.height || 0;
        let historyText = localHistory.length > 0 ? localHistory.join('  ') : '(No history)';
        let variable = variableTemplate.replace('{history}', historyText);
        let parsed = await AgentActionParseRetry.request(async (): Promise<string> => {
          let candidate = mode === 'local' ?
            await this.localAgentStep(variable, imageBase64, width, height) :
            (useCloudWithLocalPrompt ?
              await this.pcAgentStep(prefix, variable, imageBase64) :
              await this.cloudAgentStep(imageBase64));
          await this.sleep(300);
          return candidate;
        }, (info: AgentActionParseRetryInfo): void => {
          this.log(mode, '>> [Agent] JSON parse failed; same-screen retry ' + String(info.retryNumber) + '/' +
            String(info.maxRetries) + ': ' + info.errorMessage);
          AgentExecutionController.updateFloatText(agentLabel + ' ' + (i + 1) + '/' + MAX_AGENT_STEPS +
            ': JSON解析失败，同屏重试 ' +
            String(info.retryNumber) + '/' + String(info.maxRetries));
        });
        let response = parsed.raw;
        if (parsed.action === 'error') {
          throw new Error(AgentActionParser.getMapString(parsed.parameters, 'reason', response));
        }
        AgentExecutionController.updateFloatText(agentLabel + ' ' + (i + 1) + '/' + MAX_AGENT_STEPS + ': ' +
          parsed.action);
        this.log(mode, '>> [Agent] parsed step ' + (i + 1) + ': action=' + parsed.action);
        if (AgentActionParser.isTerminal(parsed.action)) {
          completed = true;
          break;
        }
        let fullWidth = width * inverseScreenshotFactor;
        let fullHeight = height * inverseScreenshotFactor;
        await this.executeParsedAction(parsed, fullWidth, fullHeight);
        if (mode === 'cloud' && !useCloudWithLocalPrompt) {
          this.cloudActionHistory.push(AgentActionParser.normalizeCloudHistoryItem(response));
          this.log('cloud', '>> [Cloud History] appended after HDC execution, history=' + this.cloudActionHistory.length);
        }
        if (mode === 'local' || useCloudWithLocalPrompt) {
          localHistory.push((i + 1) + ': Action=' + parsed.action);
          this.log(mode, '[Agent] Appended JSON data to history: ' + localHistory[localHistory.length - 1]);
        }
        // 这段等待位于下一轮截图之前，因此同时覆盖有悬浮窗和无悬浮窗的截图路径。
        await this.sleep(this.postActionDelayMs);
      }
      if (!completed) {
        this.log(mode, '>> [Agent] reached max steps: ' + MAX_AGENT_STEPS);
      }
    } finally {
      if (mode === 'local') {
        await this.localAgentReset();
      }
    }
  }

  private resolveAgentNoReasonMode(): boolean {
    let hasNoReasonPrompts = this.hasAgentPromptPair('e2e_v2_agent_prefix_noreason.md',
      'e2e_v2_agent_variable_noreason.md');
    if (hasNoReasonPrompts) {
      return true;
    }
    let hasReasonPrompts = this.hasAgentPromptPair('e2e_v2_agent_prefix.md', 'e2e_v2_agent_variable.md');
    if (hasReasonPrompts) {
      return false;
    }
    return this.noReasonMode;
  }

  private hasAgentPromptPair(prefixFile: string, variableFile: string): boolean {
    return AgentPromptTemplates.hasModelPrompt(this.modelDirPath, prefixFile) &&
      AgentPromptTemplates.hasModelPrompt(this.modelDirPath, variableFile);
  }

  private async runFullPromptMode(task: string, mode: AgentLoopMode): Promise<void> {
    let template = AgentPromptTemplates.load('e2e_v2.md');
    if (template.trim().length === 0) {
      template = '任务目标: {task}\n历史记录: {history}\n请分析当前屏幕截图，按照要求严格输出JSON，包含reasoning, action (click/swipe/input/done), parameters。';
    }
    let history: string[] = [];
    for (let i = 0; i < MAX_AGENT_STEPS; i++) {
      await this.waitForRunnableState();
      let shot = await this.hdcBridge.screenshotWithFactor(0.25);
      let imageBase64 = shot.image_b64 || '';
      let width = shot.width || 0;
      let height = shot.height || 0;
      let historyText = history.length > 0 ? history.join('\n') : 'None';
      let prompt = template.replace('{task}', task).replace('<task>', task)
        .replace('{history}', historyText).replace('<history>', historyText)
        .replace('{history_str}', historyText);
      let parsed = await AgentActionParseRetry.request(async (): Promise<string> => {
        let candidate = mode === 'local' ?
          await this.runLocalAction(prompt, imageBase64, width, height, 'full-step-' + (i + 1)) :
          await this.runCloudDeciderPrompt(prompt, imageBase64);
        await this.sleep(300);
        return candidate;
      }, (info: AgentActionParseRetryInfo): void => {
        this.log(mode, '>> [Agent] JSON parse failed; same-screen retry ' + String(info.retryNumber) + '/' +
          String(info.maxRetries) + ': ' + info.errorMessage);
        AgentExecutionController.updateFloatText((mode === 'cloud' ? 'Cloud' : 'MNN') +
          ' Agent ' + (i + 1) + '/' + MAX_AGENT_STEPS + ': JSON解析失败，同屏重试 ' +
          String(info.retryNumber) + '/' + String(info.maxRetries));
      });
      let response = parsed.raw;
      if (AgentActionParser.isTerminal(parsed.action)) {
        break;
      }
      if (parsed.action === 'error') {
        throw new Error(AgentActionParser.getMapString(parsed.parameters, 'reason', response));
      }
      await this.executeParsedAction(parsed, width * 4, height * 4);
      history.push((i + 1) + ': Action=' + parsed.action);
      await this.sleep(this.postActionDelayMs);
    }
  }

  private async executeParsedAction(parsed: ParsedAgentAction, width: number, height: number): Promise<HdcBridgeResponse> {
    this.checkCancellation();
    let swipeFallbackDiagnostic = AgentActionParser.getSwipeFallbackDiagnostic(parsed, width, height);
    if (swipeFallbackDiagnostic.length > 0) {
      this.log(this.mode, '>> [Agent] Swipe fallback: ' + swipeFallbackDiagnostic);
    }
    let payload = AgentActionParser.buildHdcActionPayload(parsed, width, height);
    this.log(this.mode, '>> [Agent] HDC action payload:\n' + ArkJSON.stringify(payload));
    return await this.hdcBridge.guiAction(payload as Object as WorkflowJsonMap);
  }

  private async runLocalAction(prompt: string, imageBase64?: string, width?: number, height?: number,
    stage: string = 'action'): Promise<string> {
    let finalPrompt = prompt;
    if (imageBase64 !== undefined && imageBase64.length > 0) {
      let imgPath = this.saveSnapshot(imageBase64);
      let imgTag = '<img>' + imgPath + '<hw>' + String(height || 0) + ',' + String(width || 0) + '</hw></img>';
      this.log('local', '>> [Action] image saved: ' + imgPath + ' (' + String(width || 0) + 'x' + String(height || 0) + ')');
      finalPrompt = finalPrompt.indexOf('<image_placeholder>') >= 0 ?
        finalPrompt.replace('<image_placeholder>', imgTag) :
        imgTag + '\n' + finalPrompt;
    }
    this.localActionCallCount += 1;
    this.log('local', '>> [Action][' + stage + '] infer call #' + this.localActionCallCount +
      ' full prompt:\n' + finalPrompt);
    AgentExecutionController.updateFloatText('Inferencing...');
    let chat = this.localApi['chat'];
    if (typeof chat !== 'function') {
      throw new Error('Local chat API is unavailable');
    }
    let response = await chat(finalPrompt) as string;
    this.checkCancellation();
    AgentExecutionController.updateFloatText('AI Agent running...');
    this.log('local', '>> [Action][' + stage + '] infer call #' + this.localActionCallCount +
      ' model response:\n' + response);
    if (!await this.localApprovalHandler(response)) {
      throw new Error('User rejected');
    }
    return response;
  }

  private async localAgentPrefill(prefix: string): Promise<void> {
    this.log('local', '>> [Agent Prefill] prompt chars=' + prefix.length + '\n' + prefix);
    AgentExecutionController.updateFloatText('Prefill...');
    let agentPrefill = this.localApi['agentPrefill'];
    if (typeof agentPrefill !== 'function') {
      throw new Error('Local agentPrefill API is unavailable');
    }
    let result = await agentPrefill(prefix) as string;
    this.checkCancellation();
    AgentExecutionController.updateFloatText('AI Agent running...');
    this.log('local', '>> [Agent Prefill Done] ' + result);
  }

  private async localAgentStep(variable: string, imageBase64: string, width: number, height: number): Promise<string> {
    let finalVariable = variable;
    if (imageBase64.length > 0) {
      let imgPath = this.saveSnapshot(imageBase64);
      let imgTag = '<img>' + imgPath + '<hw>' + height + ',' + width + '</hw></img>';
      this.log('local', '>> [Agent Step] image saved: ' + imgPath + ' (' + width + 'x' + height + ')');
      finalVariable = finalVariable.indexOf('<image_placeholder>') >= 0 ?
        finalVariable.replace('<image_placeholder>', imgTag) :
        imgTag + finalVariable;
    }
    this.log('local', '>> [Agent Step] variable prompt:\n' + finalVariable);
    AgentExecutionController.updateFloatText('Thinking...');
    let agentStep = this.localApi['agentStep'];
    if (typeof agentStep !== 'function') {
      throw new Error('Local agentStep API is unavailable');
    }
    let streamedText = '';
    let response = await agentStep(finalVariable, (token: string) => {
      if (this.isCancellationRequested()) {
        return;
      }
      streamedText += token;
      AgentExecutionController.replaceFloatText(streamedText);
    }) as string;
    this.checkCancellation();
    AgentExecutionController.updateFloatText('AI Agent running...');
    this.log('local', '>> [Agent Step] model response:\n' + response);
    if (!await this.localApprovalHandler(response)) {
      throw new Error('User rejected');
    }
    return response;
  }

  private async runCloudPlanner(prompt: string): Promise<string> {
    AgentExecutionController.updateFloatText('Cloud planning...');
    this.log('cloud', '>> [Cloud Planner] prompt:\n' + prompt);
    let response = await this.cloudClient.chatPlanner(prompt, this.cloudConfigProvider());
    this.checkCancellation();
    AgentExecutionController.updateFloatText('AI Agent running...');
    this.log('cloud', '>> [Cloud Planner] model response:\n' + response);
    if (!await this.cloudApprovalHandler(response)) {
      throw new Error('User rejected');
    }
    return response;
  }

  private async cloudAgentStep(imageBase64: string): Promise<string> {
    if (imageBase64.length > 0) {
      let imgPath = this.saveSnapshot(imageBase64);
      this.log('cloud', '>> [Cloud Agent Step] image saved: ' + imgPath);
    }
    let qwenTask = this.cloudTask.length > 0 ? this.cloudTask : '';
    let debugPrompt = this.cloudClient.formatQwenDeciderPromptForLog(qwenTask, this.cloudActionHistory, imageBase64);
    this.log('cloud', '>> [Cloud Decider Prompt]\n' + debugPrompt);
    AgentExecutionController.updateFloatText('Cloud thinking...');
    let response = await this.cloudClient.chatQwenDecider(qwenTask, this.cloudActionHistory, imageBase64,
      this.cloudConfigProvider());
    this.checkCancellation();
    AgentExecutionController.updateFloatText('AI Agent running...');
    this.log('cloud', '>> [Cloud Agent Step] model response:\n' + response);
    if (!await this.cloudApprovalHandler(response)) {
      throw new Error('User rejected');
    }
    return response;
  }

  private async pcAgentStep(prefix: string, variable: string, imageBase64: string): Promise<string> {
    let finalVariable = variable;
    if (imageBase64.length > 0) {
      finalVariable = finalVariable.indexOf('<image_placeholder>') >= 0 ?
        finalVariable.replace('<image_placeholder>', '') :
        finalVariable;
    }
    let prompt = prefix + '\n\n' + finalVariable;
    return await this.runPcAgentPrompt(prompt, imageBase64, 'Agent Step');
  }

  private async runCloudDeciderPrompt(prompt: string, imageBase64: string): Promise<string> {
    AgentExecutionController.updateFloatText('Cloud thinking...');
    let response = await this.cloudClient.chatDecider(prompt, imageBase64, this.cloudConfigProvider());
    this.checkCancellation();
    AgentExecutionController.updateFloatText('AI Agent running...');
    this.log('cloud', '>> [Cloud Action] model response:\n' + response);
    if (!await this.cloudApprovalHandler(response)) {
      throw new Error('User rejected');
    }
    return response;
  }

  private async runPcAgentPrompt(prompt: string, imageBase64: string, stage: string): Promise<string> {
    AgentExecutionController.updateFloatText('PC Agent thinking...');
    this.log('cloud', '>> [PCAgent Prompt][' + stage + ']\n' + prompt);
    let response = await this.cloudClient.chatPcAgentPrompt(prompt, imageBase64, this.cloudConfigProvider());
    this.checkCancellation();
    AgentExecutionController.updateFloatText('AI Agent running...');
    this.log('cloud', '>> [PCAgent Prompt][' + stage + '] model response:\n' + response);
    if (!await this.cloudApprovalHandler(response)) {
      throw new Error('User rejected');
    }
    return response;
  }

  private async resetLocalContext(): Promise<void> {
    try {
      await this.localApi.agentReset();
    } catch (e) {
    }
  }

  private async localAgentReset(): Promise<void> {
    try {
      await this.localApi.agentReset();
      this.log('local', '>> [Agent Reset] Local Agent context reset.');
    } catch (e) {
    }
  }

  private extractCloudTask(prefix: string, fallback: string): string {
    let marker = '### Current Task';
    let start = prefix.indexOf(marker);
    if (start < 0) {
      return fallback;
    }
    let rest = prefix.substring(start + marker.length).trim();
    let nextSection = rest.indexOf('\n### ');
    if (nextSection >= 0) {
      rest = rest.substring(0, nextSection).trim();
    }
    return rest.length > 0 ? rest : fallback;
  }

  private saveSnapshot(imageBase64: string): string {
    this.cleanupSnapshots();
    let ts = new Date().getTime();
    let imgPath = this.filesDir + '/agent_snapshot_' + ts + '.jpg';
    let base64Helper = new util.Base64Helper();
    let imgBuffer = base64Helper.decodeSync(imageBase64);
    let file = fs.openSync(imgPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, imgBuffer.buffer);
    } finally {
      fs.closeSync(file);
    }
    return imgPath;
  }

  private cleanupSnapshots(): void {
    try {
      let files = fs.listFileSync(this.filesDir);
      for (let fileName of files) {
        if (fileName.startsWith('agent_snapshot_')) {
          fs.unlinkSync(this.filesDir + '/' + fileName);
        }
      }
    } catch (e) {
    }
  }

  private async waitForRunnableState(): Promise<void> {
    this.checkCancellation();
    await AgentExecutionController.waitIfPaused();
    this.checkCancellation();
  }

  private checkCancellation(): void {
    if (this.isCancellationRequested()) {
      throw new Error('Task cancelled by user');
    }
  }

  private isCancellationRequested(): boolean {
    return this.cancellationRequested || AgentExecutionController.isCancelRequested();
  }

  private log(mode: AgentLoopMode, message: string): void {
    AppLogger.info('AgentLoop.' + mode, message);
    if (mode === 'cloud') {
      this.cloudLogHandler(message);
      return;
    }
    this.localLogHandler(message);
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
}
