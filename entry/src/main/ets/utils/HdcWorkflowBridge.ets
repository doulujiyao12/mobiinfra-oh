import { http } from '@kit.NetworkKit';
import { JSON as ArkJSON } from '@kit.ArkTS';
import { AgentExecutionController } from './AgentExecutionController';
import { AppLogger } from './AppLogger';
import { HdcBridgeResponse, WorkflowJsonMap } from './WorkflowTypes';

interface HdcBridgeRequest {
  action: string;
  payload: WorkflowJsonMap;
}

interface EmptyBridgePayload {
}

interface StartAppPayload {
  app_name: string;
  package_name: string;
  reset_first: boolean;
}

interface ScreenshotPayload {
  factor: number;
  style?: string;
  manage_overlay?: boolean;
  target_width?: number;
  target_height?: number;
}

interface ExecuteDeciderPayload {
  response: string;
  width: number;
  height: number;
}

interface LoadPromptPayload {
  prompt_name: string;
}

export class HdcWorkflowBridge {
  private baseUrl: string;
  private logHandler: (message: string) => void;

  constructor(baseUrl: string, logHandler: (message: string) => void) {
    this.baseUrl = baseUrl;
    this.logHandler = logHandler;
  }

  private workflowUrl(): string {
    let url = this.baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url + '/api/workflow';
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private elapsedMs(startedAtMs: number): number {
    return new Date().getTime() - startedAtMs;
  }

  private payloadKeysText(payload: WorkflowJsonMap): string {
    let keys = Object.keys(payload);
    return keys.length > 0 ? keys.join('|') : '(empty)';
  }

  private compactText(value: string, maxChars: number): string {
    let text = value.replace(/\s+/g, ' ').trim();
    if (text.length <= maxChars) {
      return text;
    }
    return text.substring(0, maxChars) + '...';
  }

  private responseSummary(requestAction: string, response: HdcBridgeResponse): string {
    let message = response.message && response.message.length > 0 ? this.compactText(response.message, 160) : '(empty)';
    let responseAction = response.action && response.action.length > 0 ? response.action : requestAction;
    let width = response.width === undefined ? '(empty)' : String(response.width);
    let height = response.height === undefined ? '(empty)' : String(response.height);
    return 'status=' + response.status + ', message=' + message + ', action=' + responseAction +
      ', width=' + width + ', height=' + height;
  }

  async request(action: string, payload?: WorkflowJsonMap): Promise<HdcBridgeResponse> {
    let emptyPayload: EmptyBridgePayload = {};
    let requestPayload = payload === undefined ? emptyPayload as Object as WorkflowJsonMap : payload;
    let body: HdcBridgeRequest = {
      action: action,
      payload: requestPayload
    };
    let httpReq = http.createHttp();
    let startedAt = new Date().getTime();
    try {
      AppLogger.info('HdcBridge', 'request action=' + action + ', payloadKeys=' +
        this.payloadKeysText(requestPayload));
      let options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: ArkJSON.stringify(body),
        connectTimeout: 8000,
        readTimeout: 120000,
        expectDataType: http.HttpDataType.STRING
      };
      let resp = await httpReq.request(this.workflowUrl(), options);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        let errorResponse: HdcBridgeResponse = {
          status: 'error',
          message: 'HDC bridge HTTP ' + resp.responseCode + ': ' + String(resp.result)
        };
        AppLogger.info('HdcBridge', 'response http=' + resp.responseCode + ', durationMs=' +
          this.elapsedMs(startedAt) + ', ' + this.responseSummary(action, errorResponse));
        return errorResponse;
      }
      let parsed = ArkJSON.parse(resp.result as string) as HdcBridgeResponse;
      AppLogger.info('HdcBridge', 'response http=' + resp.responseCode + ', durationMs=' +
        this.elapsedMs(startedAt) + ', ' + this.responseSummary(action, parsed));
      if (parsed.status !== 'ok') {
        this.logHandler('HDC bridge 返回失败：' + (parsed.message || parsed.status));
      }
      return parsed;
    } catch (e) {
      let err = e as Error;
      AppLogger.errorCause('HdcBridge', 'request failed action=' + action + ', durationMs=' +
        this.elapsedMs(startedAt), err);
      return {
        status: 'error',
        message: 'HDC bridge 请求失败：' + err.message
      };
    } finally {
      httpReq.destroy();
    }
  }

  async health(): Promise<boolean> {
    let response = await this.request('health');
    return response.status === 'ok';
  }

  async startApp(appName: string, packageName: string, resetFirst: boolean = true): Promise<void> {
    let payload: StartAppPayload = {
      app_name: appName,
      package_name: packageName,
      reset_first: resetFirst
    };
    let response = await this.request('app_start', payload as Object as WorkflowJsonMap);
    if (response.status !== 'ok') {
      throw new Error(response.message || 'app_start failed');
    }
  }

  async screenshot(): Promise<HdcBridgeResponse> {
    return await this.screenshotWithFactor(0.5);
  }

  async screenshotWithFactor(factor: number): Promise<HdcBridgeResponse> {
    return await this.screenshotWithOptions(factor);
  }

  async screenshotWithSize(width: number, height: number): Promise<HdcBridgeResponse> {
    return await this.screenshotWithOptions(0.25, width, height);
  }

  private async screenshotWithOptions(factor: number, targetWidth?: number, targetHeight?: number): Promise<HdcBridgeResponse> {
    let restoreToken = await AgentExecutionController.hideCaptureOverlay();
    try {
      if (restoreToken) {
        await this.sleep(120);
      }
      let payload: ScreenshotPayload = {
        factor: factor,
        style: factor <= 0.25 ? 'local' : 'mobiagent',
        manage_overlay: false
      };
      if (targetWidth !== undefined && targetHeight !== undefined) {
        payload.target_width = targetWidth;
        payload.target_height = targetHeight;
      }
      let response = await this.request('screenshot', payload as Object as WorkflowJsonMap);
      if (response.status !== 'ok' || !response.image_b64) {
        throw new Error(response.message || 'screenshot failed');
      }
      return response;
    } finally {
      await AgentExecutionController.restoreCaptureOverlay(restoreToken);
    }
  }

  async executeModelAction(responseText: string, width: number, height: number): Promise<HdcBridgeResponse> {
    let payload: ExecuteDeciderPayload = {
      response: responseText,
      width: width,
      height: height
    };
    let response = await this.request('execute_decider_action', payload as Object as WorkflowJsonMap);
    if (response.status !== 'ok') {
      throw new Error(response.message || 'execute_decider_action failed');
    }
    return response;
  }

  async loadPromptTemplate(promptName: string): Promise<string> {
    let payload: LoadPromptPayload = {
      prompt_name: promptName
    };
    let response = await this.request('load_prompt_template', payload as Object as WorkflowJsonMap);
    if (response.status !== 'ok') {
      throw new Error(response.message || 'load_prompt_template failed');
    }
    return response.result || '';
  }

  async agentConfig(): Promise<HdcBridgeResponse> {
    let response = await this.request('agent_config');
    if (response.status !== 'ok') {
      throw new Error(response.message || 'agent_config failed');
    }
    return response;
  }

  async prepareAgentRun(): Promise<void> {
    let response = await this.request('prepare_agent_run');
    if (response.status !== 'ok') {
      throw new Error(response.message || 'prepare_agent_run failed');
    }
  }

  async guiAction(payload: WorkflowJsonMap): Promise<HdcBridgeResponse> {
    let response = await this.request('gui_action', payload);
    if (response.status !== 'ok') {
      throw new Error(response.message || 'gui_action failed');
    }
    return response;
  }
}
