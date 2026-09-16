import { PrivacyConsent } from './PrivacyConsent';
import { AiServiceAccess, AI_LOGIN_REQUIRED_MESSAGE } from './AiServiceAccess';
import { http } from '@kit.NetworkKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import {
  CLOUD_DECIDER_CURRENT_STEP_PROMPT,
  CLOUD_DECIDER_SYSTEM_PROMPT,
  CLOUD_DECIDER_USER_PROMPT
} from './CloudDeciderPrompt';
import { AppLogger } from './AppLogger';
import { decodeUtf8Compat } from './TextEncodingCompat';
import { parseJsonCompat } from './JsonCompat';
import { WorkflowJsonRepair } from './WorkflowJsonRepair';
import { GalleryModelJson } from './gallery/GalleryTypes';

// OpenAI-compatible 云端模型客户端。Planner 和 Decider 可以指向不同 base URL，
// 请求统一规范化到 /v1/chat/completions，并支持在任务取消时销毁未完成请求。
export interface CloudModelConfig {
  plannerBaseUrl: string;
  plannerModel: string;
  plannerApiKey?: string;
  deciderBaseUrl: string;
  deciderApiKey?: string;
  // 历史共享密钥字段，保留给旧调用方和旧配置做兼容兜底。
  apiKey: string;
  deciderModel: string;
}

export function cloudPlannerApiKey(config: CloudModelConfig): string {
  let plannerApiKey = config.plannerApiKey;
  if (plannerApiKey !== undefined && plannerApiKey.trim().length > 0) {
    return plannerApiKey.trim();
  }
  return config.apiKey.trim();
}

export function cloudDeciderApiKey(config: CloudModelConfig): string {
  let deciderApiKey = config.deciderApiKey;
  if (deciderApiKey !== undefined && deciderApiKey.trim().length > 0) {
    return deciderApiKey.trim();
  }
  return config.apiKey.trim();
}

export interface GalleryCloudModelConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
}

export interface EmbeddingCloudConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
}

export interface GalleryMonthSummaryResult {
  title: string;
  summary: string;
  suggestion: string;
  rawText: string;
}

export interface GalleryQuestionAnswerResult {
  answer: string;
  matchedIds: string[];
  confidence: number;
  rawText: string;
}

export interface CloudImageUrl {
  url: string;
}

export interface CloudTextPart {
  type: string;
  text: string;
}

export interface CloudImagePart {
  type: string;
  image_url: CloudImageUrl;
}

export type CloudContentPart = CloudTextPart | CloudImagePart;

export interface CloudToolCallFunction {
  name: string;
  arguments: string;
}

export interface CloudToolCall {
  id: string;
  type: string;
  function: CloudToolCallFunction;
}

export interface CloudChatMessage {
  role: string;
  content: string | CloudContentPart[];
  tool_call_id?: string;
  tool_calls?: CloudToolCall[];
  name?: string;
}

export interface CloudChatTemplateKwargs {
  enable_thinking: boolean;
}

export interface CloudChatToolFunctionDefinition {
  name: string;
  description: string;
  parameters: Object;
  strict?: boolean;
}

export interface CloudChatToolDefinition {
  type: string;
  function: CloudChatToolFunctionDefinition;
}

export interface CloudChatCompletionOptions {
  baseUrl: string;
  apiKey: string;
  messages: CloudChatMessage[];
  temperature?: number;
  model?: string;
  maxTokens?: number;
  readTimeout?: number;
  chatTemplateKwargs?: CloudChatTemplateKwargs;
  top_p?: number;
  top_k?: number;
  min_p?: number;
  presence_penalty?: number;
  repetition_penalty?: number;
  tools?: CloudChatToolDefinition[];
  toolChoice?: string;
}

export type CloudChatStreamDeltaHandler = (delta: string) => void;

export interface CloudChatCompletionStreamCallbacks {
  onContentDelta?: CloudChatStreamDeltaHandler;
}

export interface CloudChatStreamDiagnostics {
  responseCode: number;
  receivedBytes: number;
  sseLineCount: number;
  contentDeltaChars: number;
  reasoningDeltaChars: number;
  toolCallCount: number;
  rawPreview: string;
}

interface CloudChatRequest {
  messages: CloudChatMessage[];
  stream: boolean;
  temperature?: number;
  max_tokens?: number;
  model?: string;
  top_p?: number;
  top_k?: number;
  min_p?: number;
  presence_penalty?: number;
  repetition_penalty?: number;
  chat_template_kwargs?: CloudChatTemplateKwargs;
  tools?: CloudChatToolDefinition[];
  tool_choice?: string;
}

interface CloudChatOptions {
  temperature?: number;
  top_p?: number;
  top_k?: number;
  min_p?: number;
  presence_penalty?: number;
  repetition_penalty?: number;
  chat_template_kwargs?: CloudChatTemplateKwargs;
}

interface CloudChatMessageResult {
  role?: string;
  content?: string | null;
  tool_calls?: CloudToolCall[];
}

interface CloudChatChoice {
  message: CloudChatMessageResult;
  finish_reason?: string;
}

interface CloudChatResponse {
  choices: CloudChatChoice[];
}

interface CloudErrorDetail {
  message?: string;
  type?: string;
  code?: string | number | null;
}

interface CloudErrorResponse {
  error?: string | CloudErrorDetail;
  message?: string;
  detail?: string;
}

export interface CloudStreamToolCallFunctionDelta {
  name?: string | null;
  arguments?: string | null;
}

export interface CloudStreamToolCallDelta {
  index?: number | null;
  id?: string | null;
  type?: string | null;
  function?: CloudStreamToolCallFunctionDelta | null;
}

interface CloudStreamChoiceDelta {
  content?: string | null;
  reasoning_content?: string | null;
  reasoning?: string | null;
  tool_calls?: CloudStreamToolCallDelta[] | null;
}

interface CloudStreamChoice {
  delta?: CloudStreamChoiceDelta;
  finish_reason?: string | null;
}

interface CloudStreamResponse {
  choices?: CloudStreamChoice[];
}

export interface CloudChatStreamChunk {
  contentDelta: string;
  reasoningDelta: string;
  toolCallDeltas: CloudStreamToolCallDelta[];
  finishReason: string;
  done: boolean;
}

export interface CloudChatCompletionResult {
  content: string;
  toolCalls: CloudToolCall[];
  finishReason: string;
  assistantMessage: CloudChatMessage;
}

interface CloudEmbeddingRequest {
  model: string;
  input: string;
}

interface CloudEmbeddingItem {
  embedding: number[];
}

interface CloudEmbeddingResponse {
  data: CloudEmbeddingItem[];
}

type JsonPayload = Record<string, Object | string | number | boolean | null>;
type GalleryFieldKey = 'title' | 'category' | 'summary' | 'details' | 'tags' | 'importance';

interface GalleryFieldAnalysisResult {
  key: GalleryFieldKey;
  rawText: string;
  parsed: GalleryModelJson;
}

interface GalleryFieldAnalysisBundle {
  json: GalleryModelJson;
  rawText: string;
}

export class CloudModelClient {
  private activeRequests: http.HttpRequest[] = [];
  private readonly galleryChatOptions: CloudChatOptions = {
    temperature: 0,
    top_p: 1,
    top_k: 1,
    min_p: 0.0,
    presence_penalty: 0,
    repetition_penalty: 1.05,
    chat_template_kwargs: {
      enable_thinking: false
    }
  };

  private registerActiveRequest(request: http.HttpRequest): void {
    this.activeRequests.push(request);
  }

  private unregisterActiveRequest(request: http.HttpRequest): void {
    this.activeRequests = this.activeRequests.filter((item: http.HttpRequest) => item !== request);
  }

  cancelActiveRequests(): void {
    // 浮窗终止任务时会调用这里，主动 destroy 当前 HTTP 请求，避免云端长推理阻塞收尾。
    let pending = this.activeRequests.slice();
    this.activeRequests = [];
    for (let i = 0; i < pending.length; i++) {
      try {
        PrivacyConsent.destroyHttp(pending[i]);
      } catch (e) {
        AppLogger.warnCause('CloudModel', 'destroy pending request failed', e as Error);
      }
    }
  }

  private buildQwenHistoryText(historyItems: string[]): string {
    // Qwen Decider 的历史只保留结构化动作摘要，避免把整段模型输出反复塞回上下文。
    if (historyItems.length === 0) {
      return '(No history)';
    }

    let lines: string[] = [];
    for (let i = 0; i < historyItems.length; i++) {
      lines.push(`${i + 1}. ${historyItems[i]}`);
    }
    return lines.join('\n');
  }

  private buildQwenContextText(task: string, historyItems: string[]): string {
    return CLOUD_DECIDER_USER_PROMPT
      .replace('{task}', task)
      .replace('{history}', this.buildQwenHistoryText(historyItems));
  }

  formatQwenDeciderPromptForLog(task: string, historyItems: string[], imageBase64: string): string {
    // 日志中只展示 base64 前缀，既能确认图像被传入，又不会把完整截图刷进日志。
    let imagePrefixLength = imageBase64.length > 48 ? 48 : imageBase64.length;
    let imagePrefix = imageBase64.substring(0, imagePrefixLength);
    return '[0] role=system\n' +
      CLOUD_DECIDER_SYSTEM_PROMPT +
      '\n\n[1] role=user / content[0] type=text\n' +
      this.buildQwenContextText(task, historyItems) +
      '\n\n[1] role=user / content[1] type=image_url\n' +
      'data:image/jpeg;base64,' + imagePrefix + '... (base64 chars=' + imageBase64.length + ')' +
      '\n\n[1] role=user / content[2] type=text\n' +
      CLOUD_DECIDER_CURRENT_STEP_PROMPT;
  }

  private normalizeChatUrl(baseUrl: string): string {
    // 兼容三种用户输入：host、host/v1、host/v1/chat/completions。
    let url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) {
      return url;
    }
    if (url.endsWith('/v1')) {
      return url + '/chat/completions';
    }
    return url + '/v1/chat/completions';
  }

  private normalizeEmbeddingUrl(baseUrl: string): string {
    let url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/embeddings')) {
      return url;
    }
    if (url.endsWith('/v1')) {
      return url + '/embeddings';
    }
    return url + '/v1/embeddings';
  }

  private buildChatRequestBody(options: CloudChatCompletionOptions, stream: boolean = false): CloudChatRequest {
    let requestBody: CloudChatRequest = {
      messages: options.messages,
      stream: stream
    };
    if (options.temperature !== undefined) {
      requestBody.temperature = options.temperature;
    }
    if (options.maxTokens !== undefined) {
      requestBody.max_tokens = options.maxTokens;
    }
    if (options.model !== undefined && options.model.trim().length > 0) {
      requestBody.model = options.model.trim();
    }
    if (options.top_p !== undefined) {
      requestBody.top_p = options.top_p;
    }
    if (options.top_k !== undefined) {
      requestBody.top_k = options.top_k;
    }
    if (options.min_p !== undefined) {
      requestBody.min_p = options.min_p;
    }
    if (options.presence_penalty !== undefined) {
      requestBody.presence_penalty = options.presence_penalty;
    }
    if (options.repetition_penalty !== undefined) {
      requestBody.repetition_penalty = options.repetition_penalty;
    }
    if (options.chatTemplateKwargs !== undefined) {
      requestBody.chat_template_kwargs = options.chatTemplateKwargs;
    }
    if (options.tools !== undefined && options.tools.length > 0) {
      requestBody.tools = options.tools;
      if (options.toolChoice !== undefined && options.toolChoice.length > 0) {
        requestBody.tool_choice = options.toolChoice;
      }
    }
    return requestBody;
  }

  static parseChatCompletionStreamDataLine(line: string): CloudChatStreamChunk {
    let emptyChunk: CloudChatStreamChunk = {
      contentDelta: '',
      reasoningDelta: '',
      toolCallDeltas: [],
      finishReason: '',
      done: false
    };
    let trimmed = line.trim();
    if (trimmed.length === 0 || !trimmed.startsWith('data:')) {
      return emptyChunk;
    }
    let payload = trimmed.substring(5).trim();
    if (payload === '[DONE]') {
      return {
        contentDelta: '',
        reasoningDelta: '',
        toolCallDeltas: [],
        finishReason: '',
        done: true
      };
    }
    let parsed: CloudStreamResponse;
    try {
      parsed = parseJsonCompat<CloudStreamResponse>(payload);
    } catch (e) {
      let err = e as Error;
      throw new Error('Cloud stream JSON parse failed: ' + err.message);
    }
    let choices = parsed.choices === undefined ? [] : parsed.choices;
    if (choices.length === 0) {
      return emptyChunk;
    }
    let choice = choices[0];
    let delta = choice.delta;
    if (delta === undefined) {
      return {
        contentDelta: '',
        reasoningDelta: '',
        toolCallDeltas: [],
        finishReason: choice.finish_reason === undefined || choice.finish_reason === null ? '' : choice.finish_reason,
        done: false
      };
    }
    let rawContent = delta.content;
    let reasoningContent = delta.reasoning_content === undefined ? delta.reasoning : delta.reasoning_content;
    return {
      contentDelta: typeof rawContent === 'string' ? rawContent : '',
      reasoningDelta: typeof reasoningContent === 'string' ? reasoningContent : '',
      toolCallDeltas: Array.isArray(delta.tool_calls) ? delta.tool_calls.slice() : [],
      finishReason: choice.finish_reason === undefined || choice.finish_reason === null ? '' : choice.finish_reason,
      done: false
    };
  }

  static parseChatCompletionResponseText(text: string): CloudChatCompletionResult {
    let parsed: CloudChatResponse;
    try {
      parsed = parseJsonCompat<CloudChatResponse>(text);
    } catch (e) {
      let err = e as Error;
      throw new Error('Cloud response JSON parse failed: ' + err.message);
    }
    let choices = parsed.choices === undefined ? [] : parsed.choices;
    if (choices.length === 0) {
      throw new Error('Cloud response has no choices');
    }
    let choice = choices[0];
    let message = choice.message;
    let rawContent = message.content;
    let content = typeof rawContent === 'string' ? rawContent : '';
    let toolCalls = message.tool_calls === undefined ? [] : message.tool_calls.slice();
    let assistantMessage: CloudChatMessage = {
      role: 'assistant',
      content: content,
      tool_calls: toolCalls
    };
    return {
      content: content,
      toolCalls: toolCalls,
      finishReason: choice.finish_reason === undefined ? '' : choice.finish_reason,
      assistantMessage: assistantMessage
    };
  }

  private static previewTextForLog(text: string, maxLength: number): string {
    let normalizedMaxLength = maxLength <= 0 ? 512 : Math.floor(maxLength);
    let singleLine = text.replace(/\r/g, '\\r').replace(/\n/g, '\\n');
    if (singleLine.length <= normalizedMaxLength) {
      return singleLine;
    }
    return singleLine.substring(0, normalizedMaxLength) + '...';
  }

  private static errorMessageFromNonSsePayload(text: string): string {
    try {
      let parsed = parseJsonCompat<CloudErrorResponse>(text);
      let messages: string[] = [];
      if (parsed.message !== undefined && parsed.message.length > 0) {
        messages.push(parsed.message);
      }
      if (parsed.detail !== undefined && parsed.detail.length > 0) {
        messages.push(parsed.detail);
      }
      let errorField = parsed.error;
      if (typeof errorField === 'string' && errorField.length > 0) {
        messages.push(errorField);
      } else if (errorField !== undefined && errorField !== null && typeof errorField === 'object' &&
        !Array.isArray(errorField)) {
        let detail = errorField as CloudErrorDetail;
        if (detail.message !== undefined && detail.message.length > 0) {
          messages.push(detail.message);
        }
        if (detail.type !== undefined && detail.type.length > 0) {
          messages.push('type=' + detail.type);
        }
        if (detail.code !== undefined && detail.code !== null) {
          messages.push('code=' + String(detail.code));
        }
      }
      return messages.join(', ');
    } catch (e) {
      return '';
    }
  }

  // 在 stream=true 时，错误场景不会返回 SSE，而是直接返回普通 JSON。
  // 该兜底优先尝试按非流式 chat completion 解析；失败时再抽取 error/message，避免上层只看到空回复。
  static parseNonSseStreamFallbackResponse(text: string): CloudChatCompletionResult {
    let trimmed = text.trim();
    if (trimmed.length === 0) {
      throw new Error('Cloud stream returned empty non-SSE response.');
    }
    try {
      return CloudModelClient.parseChatCompletionResponseText(trimmed);
    } catch (e) {
      let err = e as Error;
      let errorMessage = CloudModelClient.errorMessageFromNonSsePayload(trimmed);
      if (errorMessage.length > 0) {
        throw new Error(errorMessage);
      }
      throw new Error('Cloud stream returned non-SSE response: ' +
        CloudModelClient.previewTextForLog(trimmed, 512) + '; parse failed: ' + err.message);
    }
  }

  static formatStreamDiagnosticsForLog(diagnostics: CloudChatStreamDiagnostics): string {
    return 'status=' + String(diagnostics.responseCode) +
      ', bytes=' + String(diagnostics.receivedBytes) +
      ', sse_lines=' + String(diagnostics.sseLineCount) +
      ', content_delta_chars=' + String(diagnostics.contentDeltaChars) +
      ', reasoning_delta_chars=' + String(diagnostics.reasoningDeltaChars) +
      ', tool_calls=' + String(diagnostics.toolCallCount) +
      ', raw_preview=' + diagnostics.rawPreview;
  }

  private static streamStringDelta(value: string | null | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  // 流式工具调用会分片返回，并且部分 OpenAI-compatible 服务会把暂未产生的字段置为 null。
  // 这里集中做空值归一化，避免在 HTTP dataReceive 回调中访问 null.length 导致 JS crash。
  static applyStreamToolCallDeltas(toolCalls: CloudToolCall[], deltas: CloudStreamToolCallDelta[]): void {
    for (let i = 0; i < deltas.length; i++) {
      let delta = deltas[i];
      if (delta === undefined || delta === null) {
        continue;
      }
      let index = typeof delta.index === 'number' && delta.index >= 0 ? Math.floor(delta.index) : 0;
      while (toolCalls.length <= index) {
        toolCalls.push({
          id: '',
          type: 'function',
          function: {
            name: '',
            arguments: ''
          }
        });
      }
      let target = toolCalls[index];
      let deltaId = CloudModelClient.streamStringDelta(delta.id);
      if (deltaId.length > 0) {
        target.id = deltaId;
      }
      let deltaType = CloudModelClient.streamStringDelta(delta.type);
      if (deltaType.length > 0) {
        target.type = deltaType;
      }
      if (delta.function !== undefined && delta.function !== null) {
        let functionName = CloudModelClient.streamStringDelta(delta.function.name);
        if (functionName.length > 0) {
          target.function.name = functionName;
        }
        let functionArguments = CloudModelClient.streamStringDelta(delta.function.arguments);
        if (functionArguments.length > 0) {
          target.function.arguments += functionArguments;
        }
      }
      toolCalls[index] = target;
    }
  }

  private static compactStreamToolCalls(toolCalls: CloudToolCall[]): CloudToolCall[] {
    let compacted: CloudToolCall[] = [];
    for (let i = 0; i < toolCalls.length; i++) {
      let call = toolCalls[i];
      let hasPayload = call.id.length > 0 || call.function.name.length > 0 || call.function.arguments.length > 0;
      if (!hasPayload) {
        continue;
      }
      compacted.push({
        id: call.id.length > 0 ? call.id : 'stream-tool-call-' + String(i + 1),
        type: call.type.length > 0 ? call.type : 'function',
        function: {
          name: call.function.name,
          arguments: call.function.arguments
        }
      });
    }
    return compacted;
  }

  private static messagesContainImage(messages: CloudChatMessage[]): boolean {
    for (let i = 0; i < messages.length; i++) {
      let content = messages[i].content;
      if (!Array.isArray(content)) {
        continue;
      }
      for (let j = 0; j < content.length; j++) {
        if (content[j].type === 'image_url') {
          return true;
        }
      }
    }
    return false;
  }

  private static messageTextChars(messages: CloudChatMessage[]): number {
    let total = 0;
    for (let i = 0; i < messages.length; i++) {
      let content = messages[i].content;
      if (typeof content === 'string') {
        total += content.length;
      } else if (Array.isArray(content)) {
        for (let j = 0; j < content.length; j++) {
          if (content[j].type === 'text') {
            total += (content[j] as CloudTextPart).text.length;
          }
        }
      }
    }
    return total;
  }

  async chatCompletion(options: CloudChatCompletionOptions): Promise<CloudChatCompletionResult> {
    AiServiceAccess.requireAllowed();
    let requestBody = this.buildChatRequestBody(options);

    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + (options.apiKey.length > 0 ? options.apiKey : 'EMPTY')
    };
    let requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: ArkJSON.stringify(requestBody),
      connectTimeout: 10000,
      readTimeout: options.readTimeout === undefined ? 120000 : options.readTimeout,
      expectDataType: http.HttpDataType.STRING
    };

    let httpReq = PrivacyConsent.createHttp();
    this.registerActiveRequest(httpReq);
    let url = this.normalizeChatUrl(options.baseUrl);
    let startedAt = new Date().getTime();
    AppLogger.info('CloudModel', 'chat request start url=' + url +
      ' model=' + (options.model === undefined ? '' : options.model) +
      ' messages=' + options.messages.length.toString() +
      ' text_chars=' + CloudModelClient.messageTextChars(options.messages).toString() +
      ' has_image=' + CloudModelClient.messagesContainImage(options.messages).toString() +
      ' max_tokens=' + (options.maxTokens === undefined ? '' : options.maxTokens.toString()) +
      ' read_timeout=' + (options.readTimeout === undefined ? '' : options.readTimeout.toString()));
    try {
      let response = await httpReq.request(url, requestOptions);
      AiServiceAccess.requireAllowed();
      let elapsedMs = new Date().getTime() - startedAt;
      let responseText = response.result as string;
      AppLogger.info('CloudModel', 'chat response status=' + response.responseCode.toString() +
        ' elapsedMs=' + elapsedMs.toString() +
        ' bytes=' + responseText.length.toString() +
        ' preview=' + CloudModelClient.previewTextForLog(responseText, 512));
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Cloud HTTP ${response.responseCode}: ${response.result}`);
      }
      let parsed = CloudModelClient.parseChatCompletionResponseText(responseText);
      AppLogger.info('CloudModel', 'chat parsed content_chars=' + parsed.content.length.toString() +
        ' finish_reason=' + parsed.finishReason +
        ' content_preview=' + CloudModelClient.previewTextForLog(parsed.content, 512));
      return parsed;
    } catch (e) {
      let err = e as Error;
      AppLogger.error('CloudModel', 'chat request failed url=' + url +
        ' model=' + (options.model === undefined ? '' : options.model) +
        ' elapsedMs=' + (new Date().getTime() - startedAt).toString() +
        ' error=' + (err.message || String(e)));
      throw err;
    } finally {
      this.unregisterActiveRequest(httpReq);
      PrivacyConsent.destroyHttp(httpReq);
    }
  }

  async chatCompletionStream(options: CloudChatCompletionOptions,
    callbacks: CloudChatCompletionStreamCallbacks = {}): Promise<CloudChatCompletionResult> {
    AiServiceAccess.requireAllowed();
    let requestBody = this.buildChatRequestBody(options, true);
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + (options.apiKey.length > 0 ? options.apiKey : 'EMPTY')
    };
    let requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: ArkJSON.stringify(requestBody),
      connectTimeout: 10000,
      readTimeout: options.readTimeout === undefined ? 120000 : options.readTimeout
    };

    let httpReq = PrivacyConsent.createHttp();
    this.registerActiveRequest(httpReq);
    let url = this.normalizeChatUrl(options.baseUrl);
    AppLogger.info('CloudModel', 'chat stream request start url=' + url +
      ' model=' + (options.model === undefined ? '' : options.model) +
      ' messages=' + options.messages.length.toString() +
      ' text_chars=' + CloudModelClient.messageTextChars(options.messages).toString() +
      ' has_image=' + CloudModelClient.messagesContainImage(options.messages).toString() +
      ' max_tokens=' + (options.maxTokens === undefined ? '' : options.maxTokens.toString()) +
      ' read_timeout=' + (options.readTimeout === undefined ? '' : options.readTimeout.toString()));
    return new Promise<CloudChatCompletionResult>((resolve, reject) => {
      let self = this;
      let resolved = false;
      let textBuffer = '';
      let rawResponseText = '';
      let rawResponseTruncated = false;
      let contentParts: string[] = [];
      let toolCalls: CloudToolCall[] = [];
      let finishReason = '';
      let separateReasoningOpen = false;
      let responseCode = -1;
      let receivedBytes = 0;
      let sseLineCount = 0;
      let contentDeltaChars = 0;
      let reasoningDeltaChars = 0;
      let finishResultPending = false;
      let textDecoder = util.TextDecoder.create('utf-8');
      const MAX_RAW_RESPONSE_CHARS: number = 200000;

      let cleanup = (): void => {
        httpReq.off('dataReceive');
        httpReq.off('dataEnd');
        self.unregisterActiveRequest(httpReq);
        try {
          PrivacyConsent.destroyHttp(httpReq);
        } catch (e) {
          AppLogger.warnCause('CloudModel', 'destroy stream request failed', e as Error);
        }
      };
      let appendRawResponseText = (text: string): void => {
        if (rawResponseText.length >= MAX_RAW_RESPONSE_CHARS) {
          rawResponseTruncated = true;
          return;
        }
        let remaining = MAX_RAW_RESPONSE_CHARS - rawResponseText.length;
        if (text.length <= remaining) {
          rawResponseText += text;
          return;
        }
        rawResponseText += text.substring(0, remaining);
        rawResponseTruncated = true;
      };
      let buildDiagnostics = (toolCallCountOverride?: number): CloudChatStreamDiagnostics => {
        let rawPreview = CloudModelClient.previewTextForLog(rawResponseText, 512);
        if (rawResponseTruncated) {
          rawPreview += '...<truncated>';
        }
        return {
          responseCode: responseCode,
          receivedBytes: receivedBytes,
          sseLineCount: sseLineCount,
          contentDeltaChars: contentDeltaChars,
          reasoningDeltaChars: reasoningDeltaChars,
          toolCallCount: toolCallCountOverride === undefined ?
            CloudModelClient.compactStreamToolCalls(toolCalls).length : toolCallCountOverride,
          rawPreview: rawPreview
        };
      };
      let diagnosticsForLog = (toolCallCountOverride?: number): string => {
        return CloudModelClient.formatStreamDiagnosticsForLog(buildDiagnostics(toolCallCountOverride));
      };
      let httpStatusErrorMessage = (code: number): string => {
        let errorMessage = CloudModelClient.errorMessageFromNonSsePayload(rawResponseText.trim());
        if (errorMessage.length > 0) {
          return 'Cloud HTTP ' + String(code) + ': ' + errorMessage;
        }
        return 'Cloud HTTP ' + String(code);
      };
      let emitRawDelta = (delta: string): void => {
        if (delta.length === 0) {
          return;
        }
        contentParts.push(delta);
        if (callbacks.onContentDelta !== undefined) {
          callbacks.onContentDelta(delta);
        }
      };
      let closeSeparateReasoning = (): void => {
        if (!separateReasoningOpen) {
          return;
        }
        separateReasoningOpen = false;
        emitRawDelta('</think>\n\n');
      };
      let finishWithResult = (): void => {
        if (resolved) {
          return;
        }
        if (!AiServiceAccess.isAllowed()) {
          finishWithError(AI_LOGIN_REQUIRED_MESSAGE);
          return;
        }
        if (responseCode < 0) {
          finishResultPending = true;
          return;
        }
        finishResultPending = false;
        if (sseLineCount === 0 && rawResponseText.trim().length > 0) {
          try {
            let fallbackResult = CloudModelClient.parseNonSseStreamFallbackResponse(rawResponseText);
            resolved = true;
            cleanup();
            AppLogger.warn('CloudModel', 'chat stream received non-SSE response, fallback parsed: ' +
              diagnosticsForLog(fallbackResult.toolCalls.length));
            resolve(fallbackResult);
          } catch (e) {
            let err = e as Error;
            finishWithError('Cloud stream non-SSE response: ' + err.message);
          }
          return;
        }
        closeSeparateReasoning();
        resolved = true;
        let content = contentParts.join('');
        let finalToolCalls = CloudModelClient.compactStreamToolCalls(toolCalls);
        cleanup();
        if (content.length === 0 && finalToolCalls.length === 0) {
          AppLogger.warn('CloudModel', 'chat stream completed without content or tool calls: ' +
            diagnosticsForLog(finalToolCalls.length));
        } else {
          AppLogger.info('CloudModel', 'chat stream completed: ' + diagnosticsForLog(finalToolCalls.length));
        }
        resolve({
          content: content,
          toolCalls: finalToolCalls,
          finishReason: finishReason,
          assistantMessage: {
            role: 'assistant',
            content: content,
            tool_calls: finalToolCalls
          }
        });
      };
      let finishWithError = (message: string): void => {
        if (resolved) {
          return;
        }
        resolved = true;
        cleanup();
        AppLogger.warn('CloudModel', 'chat stream failed: ' + message + '; ' + diagnosticsForLog());
        reject(new Error(message));
      };
      PrivacyConsent.onHttpCancel(httpReq, () => {
        finishWithError(AiServiceAccess.isAllowed() ? '隐私授权已撤回' : AI_LOGIN_REQUIRED_MESSAGE);
      });
      let decodeStreamData = (data: ArrayBuffer): string => {
        try {
          return textDecoder.decodeWithStream(new Uint8Array(data));
        } catch (e) {
          return decodeUtf8Compat(new Uint8Array(data));
        }
      };
      let processStreamLine = (line: string): void => {
        if (resolved) {
          return;
        }
        if (!AiServiceAccess.isAllowed()) {
          finishWithError(AI_LOGIN_REQUIRED_MESSAGE);
          return;
        }
        try {
          if (line.trim().startsWith('data:')) {
            sseLineCount += 1;
          }
          let chunk = CloudModelClient.parseChatCompletionStreamDataLine(line);
          if (chunk.done) {
            finishWithResult();
            return;
          }
          if (chunk.finishReason.length > 0) {
            finishReason = chunk.finishReason;
          }
          if (chunk.toolCallDeltas.length > 0) {
            CloudModelClient.applyStreamToolCallDeltas(toolCalls, chunk.toolCallDeltas);
          }
          if (chunk.reasoningDelta.length > 0) {
            reasoningDeltaChars += chunk.reasoningDelta.length;
            if (!separateReasoningOpen) {
              separateReasoningOpen = true;
              emitRawDelta('<think>');
            }
            emitRawDelta(chunk.reasoningDelta);
          }
          if (chunk.contentDelta.length > 0) {
            contentDeltaChars += chunk.contentDelta.length;
            closeSeparateReasoning();
            emitRawDelta(chunk.contentDelta);
          }
        } catch (e) {
          let err = e as Error;
          finishWithError(err.message);
          return;
        }
      };
      let processBufferedText = (flushRemaining: boolean): void => {
        while (!resolved) {
          let newlineIndex = textBuffer.indexOf('\n');
          if (newlineIndex < 0) {
            break;
          }
          let line = textBuffer.substring(0, newlineIndex);
          textBuffer = textBuffer.substring(newlineIndex + 1);
          processStreamLine(line);
        }
        if (flushRemaining && !resolved && textBuffer.trim().length > 0) {
          let line = textBuffer;
          textBuffer = '';
          processStreamLine(line);
        }
      };

      httpReq.on('dataReceive', (data: ArrayBuffer) => {
        if (resolved) {
          return;
        }
        receivedBytes += data.byteLength;
        let decodedText = decodeStreamData(data);
        appendRawResponseText(decodedText);
        textBuffer += decodedText;
        processBufferedText(false);
      });
      httpReq.on('dataEnd', () => {
        processBufferedText(true);
        finishWithResult();
      });
      httpReq.requestInStream(this.normalizeChatUrl(options.baseUrl), requestOptions).then((code: number) => {
        responseCode = code;
        AppLogger.info('CloudModel', 'chat stream response status: ' + diagnosticsForLog());
        if (code < 200 || code >= 300) {
          finishWithError(httpStatusErrorMessage(code));
          return;
        }
        if (finishResultPending) {
          finishWithResult();
        }
      }).catch((e: Error) => {
        finishWithError(e.message);
      });
    });
  }

  async chatCompletionText(options: CloudChatCompletionOptions): Promise<string> {
    let result = await this.chatCompletion(options);
    return result.content;
  }

  private async chatMessages(baseUrl: string, messages: CloudChatMessage[], apiKey: string,
    model?: string, maxTokens?: number, readTimeout?: number,
    chatOptions?: CloudChatOptions): Promise<string> {
    // 这里返回 string 而不是直接抛业务错误，是为了让 PC Agent 仍能收到 action=error 的 JSON。
    let options: CloudChatCompletionOptions = {
      baseUrl: baseUrl,
      apiKey: apiKey,
      messages: messages,
      temperature: chatOptions?.temperature === undefined ? 0 : chatOptions.temperature,
      model: model,
      maxTokens: maxTokens,
      readTimeout: readTimeout
    };
    if (chatOptions !== undefined) {
      if (chatOptions.top_p !== undefined) {
        options.top_p = chatOptions.top_p;
      }
      if (chatOptions.top_k !== undefined) {
        options.top_k = chatOptions.top_k;
      }
      if (chatOptions.min_p !== undefined) {
        options.min_p = chatOptions.min_p;
      }
      if (chatOptions.presence_penalty !== undefined) {
        options.presence_penalty = chatOptions.presence_penalty;
      }
      if (chatOptions.repetition_penalty !== undefined) {
        options.repetition_penalty = chatOptions.repetition_penalty;
      }
      if (chatOptions.chat_template_kwargs !== undefined) {
        options.chatTemplateKwargs = chatOptions.chat_template_kwargs;
      }
    }
    try {
      let content = await this.chatCompletionText(options);
      return content;
    } catch (e) {
      let err = e as Error;
      AppLogger.error('CloudModel', 'chatMessages returning action=error baseUrl=' + baseUrl +
        ' model=' + (model === undefined ? '' : model) +
        ' error=' + (err.message || String(e)));
      return ArkJSON.stringify({ action: 'error', reason: err.message });
    }
  }

  private async chat(baseUrl: string, content: CloudContentPart[], apiKey: string,
    chatTemplateKwargs?: CloudChatTemplateKwargs, model?: string): Promise<string> {
    let message: CloudChatMessage = {
      role: 'user',
      content: content
    };
    let chatOptions: CloudChatOptions | undefined = chatTemplateKwargs === undefined ? undefined : {
      chat_template_kwargs: chatTemplateKwargs
    };
    return this.chatMessages(baseUrl, [message], apiKey, model, undefined, undefined, chatOptions);
  }

  async summarizeGalleryMonth(config: GalleryCloudModelConfig, monthAggregateText: string): Promise<GalleryMonthSummaryResult> {
    let prompt = '你是一个图库月度洞察助手。' +
      '\n\n请根据用户提供的月度图库聚合数据和图片摘要清单，判断这个月用户大概做了什么，并生成一个适合展示在“图库洞察”页的月度总结。' +
      '\n不要思考，不要输出思考过程、推理过程或分析步骤。' +
      '\n严格基于输入数据，不要编造具体人名、地点、城市、店名或未出现的事件。' +
      '\n如果只能推测，请使用“可能”“疑似”“看起来像”。' +
      '\n不要使用“人生高光”“最重要”等强判断。' +
      '\nsummary 必须包含 2 到 3 个具体观察，优先引用输入里的时间、类别、数量、平台、活动或事项线索；不要只写“内容丰富”“记录较多”这类笼统表述。' +
      '\n\n只输出 JSON，格式如下：' +
      '\n{' +
      '\n  "title": "最多14个字的标题",' +
      '\n  "summary": "80到140字的月度总结，说明这个月大概做了什么",' +
      '\n  "suggestion": "一句可执行整理建议"' +
      '\n}' +
      '\n\n月度图库聚合数据：\n' + monthAggregateText +
      '\n\n只输出 JSON，不要思考。';
    let message: CloudChatMessage = {
      role: 'user',
      content: prompt
    };
    let content = await this.chatMessages(config.baseUrl, [message], config.apiKey, config.model, 1024, 90000,
      this.galleryChatOptions);
    let payloadText = this.extractJsonObject(content);
    let payload: Record<string, Object> = {};
    try {
      payload = ArkJSON.parse(payloadText) as Record<string, Object>;
    } catch (e) {
      return {
        title: '',
        summary: content.trim(),
        suggestion: '',
        rawText: content
      };
    }
    let title = this.getPayloadString(payload, 'title');
    if (title.length === 0) {
      title = this.getPayloadString(payload, '标题');
    }
    let summary = this.getPayloadString(payload, 'summary');
    if (summary.length === 0) {
      summary = this.getPayloadString(payload, '摘要');
    }
    let suggestion = this.getPayloadString(payload, 'suggestion');
    if (suggestion.length === 0) {
      suggestion = this.getPayloadString(payload, 'suggestions');
    }
    if (suggestion.length === 0) {
      suggestion = this.getPayloadString(payload, '建议');
    }
    let reason = this.getPayloadString(payload, 'reason');
    if (summary.length === 0 && title.length === 0 && suggestion.length === 0) {
      throw new Error(reason.length > 0 ? reason : 'AI 月度总结返回缺少 title/summary/suggestion');
    }
    return {
      title: title,
      summary: summary.length > 0 ? summary : content.trim(),
      suggestion: suggestion,
      rawText: content
    };
  }

  async answerGalleryQuestion(config: GalleryCloudModelConfig, question: string,
    candidateText: string): Promise<GalleryQuestionAnswerResult> {
    let prompt = '你是图库问答助手。' +
      '\n不要思考，不要输出思考过程、推理过程或分析步骤。' +
      '\n只基于给定的候选图片记录回答用户问题，不要编造候选记录中没有的事实。' +
      '\n如果候选记录证据不足，请直接说明没有找到明确记录。' +
      '\n只输出 JSON，不要输出 Markdown、解释、前后缀或思考过程，格式如下：' +
      '\n{' +
      '\n  "answer": "基于候选图片的简短回答",' +
      '\n  "matchedIds": ["相关图片 id"],' +
      '\n  "confidence": 0.0' +
      '\n}' +
      '\n\n用户问题：\n' + question +
      '\n\n候选图片记录：\n' + candidateText;
    let message: CloudChatMessage = {
      role: 'user',
      content: prompt
    };
    let content = await this.chatMessages(config.baseUrl, [message], config.apiKey, config.model, 1024, 90000,
      this.galleryChatOptions);
    let payloadText = this.extractJsonObject(content);
    let payload: Record<string, Object> = {};
    try {
      payload = ArkJSON.parse(payloadText) as Record<string, Object>;
    } catch (e) {
      return {
        answer: content.trim(),
        matchedIds: [],
        confidence: 0,
        rawText: content
      };
    }
    let answer = this.getPayloadString(payload, 'answer');
    if (answer.length === 0) {
      answer = this.getPayloadString(payload, '回答');
    }
    let matchedIds = this.getPayloadStringArray(payload, 'matchedIds');
    if (matchedIds.length === 0) {
      matchedIds = this.getPayloadStringArray(payload, 'matched_ids');
    }
    let confidence = this.getPayloadNumber(payload, 'confidence');
    return {
      answer: answer.length > 0 ? answer : content.trim(),
      matchedIds: matchedIds,
      confidence: confidence,
      rawText: content
    };
  }

  private getPayloadString(payload: Record<string, Object>, key: string): string {
    let value = payload[key];
    if (value === undefined || value === null) {
      return '';
    }
    return String(value).trim();
  }

  private getPayloadStringArray(payload: Record<string, Object>, key: string): string[] {
    let value = payload[key];
    if (value === undefined || value === null) {
      return [];
    }
    if (Array.isArray(value)) {
      let items = value as Object[];
      let result: string[] = [];
      for (let i = 0; i < items.length; i++) {
        let text = String(items[i]).trim();
        if (text.length > 0) {
          result.push(text);
        }
      }
      return result;
    }
    let textValue = String(value).trim();
    if (textValue.length === 0) {
      return [];
    }
    return [textValue];
  }

  private getPayloadNumber(payload: Record<string, Object>, key: string): number {
    let value = payload[key];
    if (value === undefined || value === null) {
      return 0;
    }
    let parsed = parseFloat(String(value));
    if (isNaN(parsed)) {
      return 0;
    }
    return parsed;
  }

  private extractJsonObject(raw: string): string {
    let text = raw.trim();
    if (text.startsWith('```')) {
      let first = text.indexOf('\n');
      let last = text.lastIndexOf('```');
      if (first >= 0 && last > first) {
        text = text.substring(first + 1, last).trim();
      }
    }
    let start = text.indexOf('{');
    let end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return text.substring(start, end + 1);
    }
    return text;
  }

  async chatPlanner(prompt: string, config: CloudModelConfig): Promise<string> {
    // Planner 只吃纯文本，用来选择目标 App 或做一次性任务分解。
    let textPart: CloudTextPart = {
      type: 'text',
      text: prompt
    };
    return this.chat(config.plannerBaseUrl, [textPart], cloudPlannerApiKey(config), { enable_thinking: false },
      config.plannerModel);
  }

  async chatPlannerMessages(messages: CloudChatMessage[], config: CloudModelConfig): Promise<string> {
    return this.chatMessages(config.plannerBaseUrl, messages, cloudPlannerApiKey(config), config.plannerModel,
      undefined, undefined, {
        chat_template_kwargs: { enable_thinking: false }
      });
  }

  async chatPcAgentPrompt(prompt: string, imageBase64: string, config: CloudModelConfig): Promise<string> {
    let content: CloudContentPart[] = [];
    if (imageBase64.length > 0) {
      content.push({
        type: 'image_url',
        image_url: {
          url: 'data:image/jpeg;base64,' + imageBase64
        }
      });
    }
    content.push({
      type: 'text',
      text: prompt
    });
    let messages: CloudChatMessage[] = [{ role: 'user', content: content }];
    let options: CloudChatCompletionOptions = {
      baseUrl: config.plannerBaseUrl,
      apiKey: cloudPlannerApiKey(config),
      messages: messages
    };
    try {
      let result = await this.chatCompletionStream(options);
      return result.content;
    } catch (e) {
      let err = e as Error;
      AppLogger.error('CloudModel', 'chatPcAgentPrompt returning action=error baseUrl=' + config.plannerBaseUrl +
        ' error=' + (err.message || String(e)));
      return ArkJSON.stringify({ action: 'error', reason: err.message });
    }
  }

  async chatDecider(prompt: string, imageBase64: string, config: CloudModelConfig): Promise<string> {
    // 通用图文 Decider：完整 prompt 与当前截图作为同一条 user 消息发送。
    let imageUrl: CloudImageUrl = {
      url: 'data:image/jpeg;base64,' + imageBase64
    };
    let imagePart: CloudImagePart = {
      type: 'image_url',
      image_url: imageUrl
    };
    let textPart: CloudTextPart = {
      type: 'text',
      text: prompt
    };
    return this.chatMessages(config.deciderBaseUrl, [{ role: 'user', content: [imagePart, textPart] }],
      cloudDeciderApiKey(config), config.deciderModel, 256);
  }

  async chatImageQuestion(question: string, imageBase64: string, config: CloudModelConfig): Promise<string> {
    // workflow 中的图片问答步骤可能比动作 JSON 更长，因此使用更大的 max_tokens 和较短超时。
    let imageUrl: CloudImageUrl = {
      url: 'data:image/jpeg;base64,' + imageBase64
    };
    let imagePart: CloudImagePart = {
      type: 'image_url',
      image_url: imageUrl
    };
    let textPart: CloudTextPart = {
      type: 'text',
      text: question
    };
    return this.chatMessages(config.deciderBaseUrl, [{ role: 'user', content: [imagePart, textPart] }],
      cloudDeciderApiKey(config), config.deciderModel, 1024, 60000);
  }

  async chatImagesQuestion(question: string, imageBase64List: string[], config: CloudModelConfig): Promise<string> {
    // GUI 任务总结需要对照最近多张截图，按时间顺序组织图片并标注最后一张为最新状态。
    if (imageBase64List.length === 0) {
      throw new Error('chatImagesQuestion requires at least one image');
    }
    if (imageBase64List.length === 1) {
      return this.chatImageQuestion(question, imageBase64List[0], config);
    }
    let content: CloudContentPart[] = [];
    content.push({
      type: 'text',
      text: '以下截图按时间顺序排列，最后一张截图是最新状态。'
    });
    for (let i = 0; i < imageBase64List.length; i++) {
      let label = '截图 ' + String(i + 1) + '/' + String(imageBase64List.length);
      if (i === imageBase64List.length - 1) {
        label += '（最新状态）';
      }
      content.push({
        type: 'text',
        text: label
      });
      content.push({
        type: 'image_url',
        image_url: {
          url: 'data:image/jpeg;base64,' + imageBase64List[i]
        }
      });
    }
    content.push({
      type: 'text',
      text: question
    });
    return this.chatMessages(config.deciderBaseUrl, [{ role: 'user', content: content }],
      cloudDeciderApiKey(config), config.deciderModel, 1024, 60000);
  }

  async analyzeGalleryImage(imageBase64: string, ocrText: string, exifText: string, config: GalleryCloudModelConfig): Promise<string> {
    let imageUrl: CloudImageUrl = {
      url: 'data:image/jpeg;base64,' + imageBase64
    };
    let imagePart: CloudImagePart = {
      type: 'image_url',
      image_url: imageUrl
    };
    let textPart: CloudTextPart = {
      type: 'text',
      text: this.galleryAnalysisBasePrompt(ocrText, exifText) +
        '\n只输出一个紧凑 JSON 对象，不要 Markdown，不要解释，不要思考过程，不要代码块。' +
        '\n必须严格使用这个结构：{"title":"","category":"其他","summary":"","details":["",""],"tags":[],"importance":0.5}' +
        '\n现在只返回 JSON 对象。'
    };
    AppLogger.info('CloudModel', 'gallery full-json request baseUrl=' + config.baseUrl +
      ' model=' + config.model +
      ' image_base64_chars=' + imageBase64.length.toString() +
      ' ocr_chars=' + ocrText.length.toString() +
      ' exif_chars=' + exifText.length.toString() +
      ' prompt_chars=' + textPart.text.length.toString() +
      ' ocr_preview=' + CloudModelClient.previewTextForLog(ocrText, 200));
    let rawText = await this.chatMessages(config.baseUrl, [{ role: 'user', content: [imagePart, textPart] }],
      config.apiKey, config.model, 4096, 90000, this.galleryChatOptions);
    AppLogger.info('CloudModel', 'gallery full-json response chars=' + rawText.length.toString() +
      ' preview=' + CloudModelClient.previewTextForLog(rawText, 512));
    return rawText;
  }

  async analyzeGalleryImageByFields(imageBase64: string, ocrText: string, exifText: string,
    config: GalleryCloudModelConfig): Promise<GalleryFieldAnalysisBundle> {
    let keys: GalleryFieldKey[] = ['title', 'category', 'summary', 'details', 'tags', 'importance'];
    let results = await Promise.all(keys.map(async (key: GalleryFieldKey) => {
      return await this.analyzeGalleryImageField(imageBase64, ocrText, exifText, config, key);
    }));
    let merged: GalleryModelJson = {};
    let rawParts: string[] = [];
    for (let i = 0; i < results.length; i++) {
      let result = results[i];
      rawParts.push(result.key + ': ' + result.rawText);
      if (result.key === 'title' && result.parsed.title !== undefined) {
        merged.title = result.parsed.title;
      } else if (result.key === 'category' && result.parsed.category !== undefined) {
        merged.category = result.parsed.category;
      } else if (result.key === 'summary' && result.parsed.summary !== undefined) {
        merged.summary = result.parsed.summary;
      } else if (result.key === 'details' && result.parsed.details !== undefined) {
        merged.details = result.parsed.details;
      } else if (result.key === 'tags' && result.parsed.tags !== undefined) {
        merged.tags = result.parsed.tags;
      } else if (result.key === 'importance' && result.parsed.importance !== undefined) {
        merged.importance = result.parsed.importance;
      }
    }
    let bundle: GalleryFieldAnalysisBundle = {
      json: merged,
      rawText: rawParts.join('\n')
    };
    return bundle;
  }

  async createEmbedding(input: string, config: EmbeddingCloudConfig): Promise<number[]> {
    AiServiceAccess.requireAllowed();
    let requestBody: CloudEmbeddingRequest = {
      model: config.model,
      input: input
    };
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + (config.apiKey.length > 0 ? config.apiKey : 'EMPTY')
    };
    let requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: ArkJSON.stringify(requestBody),
      connectTimeout: 10000,
      readTimeout: 90000,
      expectDataType: http.HttpDataType.STRING
    };

    let httpReq = PrivacyConsent.createHttp();
    this.registerActiveRequest(httpReq);
    try {
      let response = await httpReq.request(this.normalizeEmbeddingUrl(config.baseUrl), requestOptions);
      AiServiceAccess.requireAllowed();
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Embedding HTTP ${response.responseCode}: ${response.result}`);
      }
      let parsed = ArkJSON.parse(response.result as string) as CloudEmbeddingResponse;
      if (parsed.data.length === 0) {
        throw new Error('Embedding response has no vectors');
      }
      return parsed.data[0].embedding;
    } catch (e) {
      let err = e as Error;
      throw err;
    } finally {
      this.unregisterActiveRequest(httpReq);
      PrivacyConsent.destroyHttp(httpReq);
    }
  }

  async chatQwenDecider(task: string, historyItems: string[], imageBase64: string, config: CloudModelConfig): Promise<string> {
    // Qwen 专用 Decider：system、任务/历史、截图、当前步输出约束分开组织，输出更稳定。
    let contextText = this.buildQwenContextText(task, historyItems);
    let imageUrl: CloudImageUrl = {
      url: 'data:image/jpeg;base64,' + imageBase64
    };
    let contextPart: CloudTextPart = {
      type: 'text',
      text: contextText
    };
    let imagePart: CloudImagePart = {
      type: 'image_url',
      image_url: imageUrl
    };
    let stepPart: CloudTextPart = {
      type: 'text',
      text: CLOUD_DECIDER_CURRENT_STEP_PROMPT
    };
    let systemMessage: CloudChatMessage = {
      role: 'system',
      content: CLOUD_DECIDER_SYSTEM_PROMPT
    };
    let userMessage: CloudChatMessage = {
      role: 'user',
      content: [contextPart, imagePart, stepPart]
    };
    let messages: CloudChatMessage[] = [systemMessage, userMessage];
    return this.chatMessages(config.deciderBaseUrl, messages, cloudDeciderApiKey(config), config.deciderModel, 256);
  }

  private galleryAnalysisBasePrompt(ocrText: string, exifText: string): string {
    return '你是图库采集分析器。结合图片、OCR、拍摄信息，提取可入库的生活记忆，只返回json。' +
      '\n字段简述：title是图片主题；category是分类；summary是1句核心概括；details是可核查细节列表；tags是便于检索的短标签；importance是重要度。' +
      '\n只输出一个紧凑 JSON 对象，不要 Markdown，不要解释，不要思考过程，不要代码块。' +
      '\n必须严格使用这个结构：{"title":"","category":"其他","summary":"","details":["",""],"tags":[],"importance":0.5}' +
      '\n字段要求：title不超过18字；summary用1句话概括这张图最核心的信息，不超过60字，尽量写清人物/事项/场景，信息不确定时用“疑似”“可能”“看起来像”等保守表达，不要编造。' +
      '\ndetails优先输出3到8条具体细节；如果图片里可核查信息确实很少，可以少于3条。每条尽量记录人物、商户、地点、商品、金额、时间、订单号、聊天事项、待办、文档标题等可识别信息；看不清就不要写。' +
      '\ntags输出1到5个短标签，优先用中文，通常2到4字。' +
      '\n可用tags：聊天、待办、会议、工作、项目、客户、通知、截图、账单、消费、外卖、餐饮、购物、快递、售后、健康、体检、用药、运动、睡眠、饮食、医疗、文档、合同、笔记、课程、作业、证件、资料、发票、家庭、朋友、聚会、亲子、节日、纪念、账号、安全、配置、报错、登录、密码。你最好这些tags中挑选，也可以自己补充。' +
      '\nimportance是0到1之间的数字，代表重要程度，比如说0.5。' +
      '\ntitle、summary、details、tags 的内容都必须使用中文，除非是英文专有名词。所有字符串不能包含换行或未转义双引号。' +
      '\ncategory 只能是以下之一：聊天、文档、餐饮、购物、出行、健康、工作、其他。' +
      '\n本地 OCR 文本：\n' + (ocrText.length > 0 ? ocrText : '空') +
      '\n拍摄信息：\n' + (exifText.length > 0 ? exifText : '空');
  }

  private gallerySingleFieldPrompt(key: GalleryFieldKey, ocrText: string, exifText: string): string {
    let context = '你是图库采集分析器。结合图片、OCR、拍摄信息，提取可入库的生活记忆。' +
      '\n本地 OCR 文本：\n' + (ocrText.length > 0 ? ocrText : '空') +
      '\n拍摄信息：\n' + (exifText.length > 0 ? exifText : '空') +
      '\n通用要求：只基于图片、OCR 和拍摄信息，不要编造；不确定时使用“疑似”“可能”“看起来像”等保守表达。' +
      '\n所有字符串优先使用中文，除非是英文专有名词；字符串不能包含换行或未转义双引号。';
    let outputRule = '\n输出要求：不要 Markdown，不要解释，不要思考过程，不要代码块。现在只返回 JSON 对象。';
    if (key === 'title') {
      return context + outputRule +
        '\n本次只生成 title。title 是图片主题，不超过18字，要概括“这是什么/在做什么/属于什么事项”。' +
        '\n优先使用图片和 OCR 中最明确的主体，例如聊天事项、订单/账单、文档标题、餐饮/购物/出行/健康场景。' +
        '\n不要写“图片”“截图”“一张图”这类空泛标题，除非确实无法识别具体内容。' +
        '\n只返回一个 JSON 对象，并且只包含一个 key：{"title":""}。不要返回其他字段。';
    }
    if (key === 'category') {
      return context + outputRule +
        '\n本次只生成 category。category 必须从聊天、文档、餐饮、购物、出行、健康、工作、其他中选择一个。' +
        '\n分类规则：聊天=聊天记录/消息/群通知；文档=合同/笔记/课程/证件/资料/发票等文档；餐饮=外卖/菜单/餐厅/饮食；购物=订单/快递/售后/商品/账单消费；出行=机票/火车/酒店/地图/行程；健康=体检/医疗/用药/运动/睡眠；工作=会议/项目/客户/办公事项；无法明确时用其他。' +
        '\n只返回一个 JSON 对象，并且只包含一个 key：{"category":""}。不要返回其他字段。';
    }
    if (key === 'summary') {
      return context + outputRule +
        '\n本次只生成 summary。summary 是给用户回看图库时直接可读的一句话核心概括，不超过60字。' +
        '\n必须优先说明图片最重要的事实：人物/对象、事项、平台或场景，以及 OCR 中可确认的时间、金额、地点、商户、订单、待办、文档标题等关键信息。' +
        '\n如果信息不确定，使用“疑似”“可能”“看起来像”等保守表达；不要编造图片和 OCR 中没有的事实。' +
        '\n不要只写“这是一张聊天截图/文档截图/购物截图”这类泛化描述，要尽量说清截图记录了什么事。' +
        '\n只返回一个 JSON 对象，并且只包含一个 key：{"summary":""}。不要返回其他字段。';
    }
    if (key === 'details') {
      return context + outputRule +
        '\n本次只生成 details。details 是可核查细节数组，优先输出3到8条，信息很少时可以少于3条。' +
        '\n每条只写图片或 OCR 能支持的事实，优先抽取人物、商户、地点、商品、金额、时间、订单号、聊天事项、待办、文档标题、账号/登录/报错等线索。' +
        '\n不要把同一事实重复拆成多条；看不清或不能确认的内容不要写，必要时用“疑似/可能”。' +
        '\n只返回一个 JSON 对象，并且只包含一个 key：{"details":["",""]}。不要返回其他字段。';
    }
    if (key === 'tags') {
      return context + outputRule +
        '\n本次只生成 tags。tags 是便于检索的短标签，输出1到5个，优先中文，通常2到4字。' +
        '\n可用标签：聊天、待办、会议、工作、项目、客户、通知、截图、账单、消费、外卖、餐饮、购物、快递、售后、健康、体检、用药、运动、睡眠、饮食、医疗、文档、合同、笔记、课程、作业、证件、资料、发票、家庭、朋友、聚会、亲子、节日、纪念、账号、安全、配置、报错、登录、密码。' +
        '\n优先从可用标签中选择，也可以补充 OCR 中明确出现且适合检索的短词。标签应覆盖类别、事项类型和关键主题，例如“账单”“快递”“会议”“体检”“登录”。' +
        '\n不要输出长句、重复标签、过泛标签；如果只有一个明确主题，少量标签即可。' +
        '\n只返回一个 JSON 对象，并且只包含一个 key：{"tags":[]}。不要返回其他字段。';
    }
    return context + outputRule +
      '\n本次只生成 importance。importance 是0到1的数字，表示这张图作为生活记忆的保留价值。' +
      '\n评分参考：重要证件/合同/医疗/订单售后/明确待办/高价值账单接近0.8到1；普通聊天/日常消费/一般资料约0.4到0.7；无明确信息、重复截图、低价值内容约0到0.3。' +
      '\n只返回一个 JSON 对象，并且只包含一个 key：{"importance":0.5}。不要返回其他字段。';
  }

  private async analyzeGalleryImageField(imageBase64: string, ocrText: string, exifText: string,
    config: GalleryCloudModelConfig, key: GalleryFieldKey): Promise<GalleryFieldAnalysisResult> {
    let imageUrl: CloudImageUrl = {
      url: 'data:image/jpeg;base64,' + imageBase64
    };
    let imagePart: CloudImagePart = {
      type: 'image_url',
      image_url: imageUrl
    };
    let textPart: CloudTextPart = {
      type: 'text',
      text: this.gallerySingleFieldPrompt(key, ocrText, exifText)
    };
    let rawText = await this.chatMessages(config.baseUrl, [{ role: 'user', content: [imagePart, textPart] }],
      config.apiKey, config.model, 2048, 90000, this.galleryChatOptions);
    AppLogger.info('CloudModel', 'gallery field response key=' + key +
      ' chars=' + rawText.length.toString() +
      ' preview=' + CloudModelClient.previewTextForLog(rawText, 256));
    return {
      key: key,
      rawText: rawText,
      parsed: this.parseGalleryFieldJson(key, rawText)
    };
  }

  private parseGalleryFieldJson(key: GalleryFieldKey, rawText: string): GalleryModelJson {
    let raw = rawText.trim();
    let rawParsed = this.tryParseGalleryFieldJson(raw);
    if (rawParsed) {
      return this.normalizeGalleryFieldJson(key, rawParsed);
    }
    let cleaned = WorkflowJsonRepair.normalizeJsonText(rawText);
    let cleanedParsed = this.tryParseGalleryFieldJson(cleaned);
    if (cleanedParsed) {
      AppLogger.info('CloudModel', 'gallery field json normalized key=' + key);
      return this.normalizeGalleryFieldJson(key, cleanedParsed);
    }
    let candidates: string[] = [];
    let repairedCandidates = WorkflowJsonRepair.repairCandidates(cleaned);
    for (let i = 0; i < repairedCandidates.length; i++) {
      if (candidates.indexOf(repairedCandidates[i]) < 0) {
        candidates.push(repairedCandidates[i]);
      }
    }
    for (let i = 0; i < candidates.length; i++) {
      let parsed = this.tryParseGalleryFieldJson(candidates[i]);
      if (parsed) {
        AppLogger.info('CloudModel', 'gallery field json repaired key=' + key +
          ' candidate=' + (i + 1).toString() + '/' + candidates.length.toString());
        return this.normalizeGalleryFieldJson(key, parsed);
      }
    }
    AppLogger.warn('CloudModel', 'gallery field json parse failed key=' + key +
      ' rawTail=' + this.debugTail(rawText));
    return this.fallbackGalleryFieldFromText(key, rawText);
  }

  private normalizeGalleryFieldJson(key: GalleryFieldKey, parsed: GalleryModelJson): GalleryModelJson {
    let result: GalleryModelJson = {};
    let payload = parsed as JsonPayload;
    if (key === 'title') {
      let title = this.galleryFieldString(payload['title']);
      if (title.length > 0) {
        result.title = title;
      }
    } else if (key === 'category') {
      let category = this.normalizeGalleryCategory(this.galleryFieldString(payload['category']));
      if (category.length > 0) {
        result.category = category;
      }
    } else if (key === 'summary') {
      let summary = this.galleryFieldString(payload['summary']);
      if (summary.length > 0) {
        result.summary = summary;
      }
    } else if (key === 'details') {
      result.details = this.galleryFieldStringArray(payload['details'], true);
    } else if (key === 'tags') {
      result.tags = this.galleryFieldStringArray(payload['tags'], true);
    } else if (key === 'importance') {
      let importance = this.galleryFieldNumber(payload['importance']);
      if (!isNaN(importance)) {
        result.importance = Math.max(0, Math.min(1, importance));
      }
    }
    return result;
  }

  private fallbackGalleryFieldFromText(key: GalleryFieldKey, text: string): GalleryModelJson {
    let trimmed = text.replace(/```(?:json)?/g, '').replace(/```/g, '').trim();
    let loose = this.looseGalleryFieldText(key, trimmed);
    let result: GalleryModelJson = {};
    if (key === 'title' && loose.length > 0) {
      result.title = loose;
    } else if (key === 'category') {
      let category = this.normalizeGalleryCategory(loose);
      if (category.length === 0) {
        category = this.normalizeGalleryCategory(trimmed);
      }
      if (category.length > 0) {
        result.category = category;
      }
    } else if (key === 'summary' && loose.length > 0) {
      result.summary = loose;
    } else if (key === 'details') {
      result.details = this.looseGalleryFieldArray(key, trimmed);
    } else if (key === 'tags') {
      result.tags = this.looseGalleryFieldArray(key, trimmed);
    } else if (key === 'importance') {
      let importance = this.looseGalleryImportance(trimmed);
      if (!isNaN(importance)) {
        result.importance = Math.max(0, Math.min(1, importance));
      }
    }
    return result;
  }

  private looseGalleryFieldText(key: GalleryFieldKey, text: string): string {
    let cleaned = text.replace(/```(?:json)?/g, '')
      .replace(/```/g, '')
      .replace(/[“”]/g, '"')
      .replace(/[‘’]/g, "'")
      .replace(/，/g, ',')
      .replace(/[：:]/g, '')
      .replace(/[()（）]/g, '')
      .replace(/[“”"'‘’`]+/g, '')
      .replace(/[{}]/g, '')
      .replace(/\s+/g, '');
    cleaned = this.stripLooseGalleryFieldName(cleaned, key);
    return cleaned.replace(/^[\[:,，、;；]+/, '').replace(/[\],，、;；]+$/, '');
  }

  private looseGalleryFieldArrayText(key: GalleryFieldKey, text: string): string {
    return this.looseGalleryFieldText(key, text).replace(/[\[\]]/g, '');
  }

  private looseGalleryFieldArray(key: GalleryFieldKey, text: string): string[] {
    let markdownItems = this.markdownListItems(text);
    if (markdownItems.length > 0) {
      return markdownItems;
    }
    return this.galleryFieldStringArray(this.looseGalleryFieldArrayText(key, text), true);
  }

  private markdownListItems(text: string): string[] {
    let lines = text.replace(/\r/g, '\n').split('\n');
    let result: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      let match = lines[i].match(/^\s*(?:[-*+]|[0-9]+[.)、])\s+(.+)$/);
      if (match && match.length > 1) {
        let value = match[1].trim().replace(/[“”"'‘’`]+/g, '');
        if (value.length > 0 && result.indexOf(value) < 0) {
          result.push(value);
        }
      }
    }
    return result;
  }

  private looseGalleryImportance(text: string): number {
    let normalized = text.replace(/％/g, '%');
    let percent = normalized.match(/([0-9]+(?:\.[0-9]+)?)\s*%/);
    if (percent && percent.length > 1) {
      return Number(percent[1]) / 100;
    }
    let number = normalized.match(/([0-9]+(?:\.[0-9]+)?)/);
    if (!number || number.length <= 1) {
      return NaN;
    }
    let value = Number(number[1]);
    return value > 1 ? value / 100 : value;
  }

  private stripLooseGalleryFieldName(text: string, key: GalleryFieldKey): string {
    let cleaned = text;
    let markers: string[] = [key + ':'];
    for (let i = 0; i < markers.length; i++) {
      cleaned = cleaned.split(markers[i]).join('');
    }
    if (cleaned.startsWith(key)) {
      cleaned = cleaned.substring(key.length);
    }
    return cleaned;
  }

  private galleryFieldString(value: Object | string | number | boolean | null | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    return String(value).trim().replace(/[\r\n\t]+/g, ' ');
  }

  private galleryFieldStringArray(value: Object | string | number | boolean | null | undefined,
    splitText: boolean): string[] {
    if (value === undefined || value === null) {
      return [];
    }
    let rawItems: string[] = [];
    if (Array.isArray(value)) {
      let items = value as Object[];
      for (let i = 0; i < items.length; i++) {
        rawItems.push(String(items[i]));
      }
    } else {
      let text = String(value);
      rawItems = splitText ? text.split(/[\n\r,，、;；]/) : [text];
    }
    let result: string[] = [];
    for (let i = 0; i < rawItems.length; i++) {
      let item = rawItems[i].trim().replace(/[\r\n\t]+/g, ' ');
      if (item.length > 0 && result.indexOf(item) < 0) {
        result.push(item);
      }
    }
    return result;
  }

  private galleryFieldNumber(value: Object | string | number | boolean | null | undefined): number {
    if (value === undefined || value === null) {
      return NaN;
    }
    return Number(String(value).trim());
  }

  private normalizeGalleryCategory(value: string): string {
    let categories: string[] = ['聊天', '文档', '餐饮', '购物', '出行', '健康', '工作', '其他'];
    for (let i = 0; i < categories.length; i++) {
      if (value.indexOf(categories[i]) >= 0) {
        return categories[i];
      }
    }
    return '';
  }

  private debugTail(text: string): string {
    let normalized = text.replace(/[\r\n\t]+/g, ' ');
    if (normalized.length <= 240) {
      return normalized;
    }
    return normalized.substring(normalized.length - 240);
  }

  private tryParseGalleryFieldJson(text: string): GalleryModelJson | null {
    try {
      return ArkJSON.parse(text) as GalleryModelJson;
    } catch (e) {
      return null;
    }
  }
}
