import {
  CloudChatCompletionOptions,
  CloudChatCompletionResult,
  CloudChatMessage,
  CloudChatToolDefinition,
  CloudModelClient,
  CloudModelConfig,
  cloudPlannerApiKey
} from './CloudModelClient';
import {
  ChatToolExecutionContext,
  ChatToolRegistry,
  createDefaultChatToolRegistry
} from './ChatToolRegistry';
import {
  MobileGuiTaskConfirmCallback,
  MobileGuiTaskRunCallback
} from './MobileGuiTaskTypes';

export type ChatReactTraceHandler = (line: string) => void;
export type ChatReactContentDeltaHandler = (delta: string) => void;

export interface ChatReactAgentRunOptions {
  maxIterations?: number;
  filesDir?: string;
  sessionId?: string;
  userMessage?: string;
  confirmMobileGuiTask?: MobileGuiTaskConfirmCallback;
  runMobileGuiTask?: MobileGuiTaskRunCallback;
  enableThinking?: boolean;
  enableTools?: boolean;
  maxTokens?: number;
  readTimeout?: number;
  logResponseContent?: boolean;
  beforeIteration?: () => Promise<void>;
  onTrace?: ChatReactTraceHandler;
  onContentDelta?: ChatReactContentDeltaHandler;
}

export interface ChatReactAgentResult {
  content: string;
  iterations: number;
  toolCallCount: number;
  reachedLimit: boolean;
  finishReason: string;
}

const DEFAULT_MAX_REACT_ITERATIONS: number = 30;
export const CHAT_REACT_EMPTY_CONTENT_MESSAGE: string = '模型未返回有效内容。';
const ITERATION_LIMIT_MESSAGE: string = '工具调用轮数已达到上限，未生成最终答案。';
const QWEN_CHAT_MAX_TOKENS: number = 32768;

interface QwenChatSamplingPreset {
  temperature: number;
  top_p: number;
  top_k: number;
  min_p: number;
  presence_penalty: number;
  repetition_penalty: number;
}

const QWEN_GENERAL_THINKING_PRESET: QwenChatSamplingPreset = {
  temperature: 1.0,
  top_p: 0.95,
  top_k: 20,
  min_p: 0.0,
  presence_penalty: 1.5,
  repetition_penalty: 1.0
};

const QWEN_GENERAL_INSTRUCT_PRESET: QwenChatSamplingPreset = {
  temperature: 0.7,
  top_p: 0.8,
  top_k: 20,
  min_p: 0.0,
  presence_penalty: 1.5,
  repetition_penalty: 1.0
};

export class ChatReactAgent {
  private client: CloudModelClient;
  private registry: ChatToolRegistry;

  constructor(client: CloudModelClient, registry: ChatToolRegistry = createDefaultChatToolRegistry()) {
    this.client = client;
    this.registry = registry;
  }

  async run(messages: CloudChatMessage[], config: CloudModelConfig,
    options: ChatReactAgentRunOptions = {}): Promise<ChatReactAgentResult> {
    let maxIterations = this.normalizeMaxIterations(options.maxIterations);
    let workingMessages = messages.slice();
    let toolsEnabled = options.enableTools !== false;
    let tools = toolsEnabled ? this.registry.getOpenAiTools() : [];
    let toolCallCount = 0;

    for (let iteration = 1; iteration <= maxIterations; iteration++) {
      if (options.beforeIteration !== undefined) {
        await options.beforeIteration();
      }
      let completionOptions = this.buildCompletionOptions(workingMessages, config, tools, options);
      let result = await this.requestCompletion(completionOptions, options);
      if (!toolsEnabled || result.toolCalls.length === 0) {
        let finalContent = result.content.trim();
        return {
          content: finalContent.length > 0 ? finalContent : CHAT_REACT_EMPTY_CONTENT_MESSAGE,
          iterations: iteration,
          toolCallCount: toolCallCount,
          reachedLimit: false,
          finishReason: result.finishReason
        };
      }

      workingMessages.push(result.assistantMessage);
      for (let i = 0; i < result.toolCalls.length; i++) {
        let toolCall = result.toolCalls[i];
        let toolContext: ChatToolExecutionContext = {
          filesDir: options.filesDir === undefined ? '' : options.filesDir,
          sessionId: options.sessionId === undefined ? '' : options.sessionId,
          userMessage: options.userMessage === undefined ? '' : options.userMessage,
          confirmMobileGuiTask: options.confirmMobileGuiTask,
          runMobileGuiTask: options.runMobileGuiTask
        };
        let toolResult = await this.registry.executeToolCall(toolCall, toolContext);
        toolCallCount += 1;
        if (options.onTrace !== undefined) {
          options.onTrace(toolResult.traceLine);
        }
        if (toolResult.terminal) {
          // 用户已经拒绝或取消具备设备副作用的操作，不再请求下一轮模型，避免再次发起同一工具调用。
          return {
            content: toolResult.terminalMessage,
            iterations: iteration,
            toolCallCount: toolCallCount,
            reachedLimit: false,
            finishReason: 'tool_terminal'
          };
        }
        workingMessages.push({
          role: 'tool',
          content: toolResult.content,
          tool_call_id: toolResult.toolCallId,
          name: toolResult.toolName
        });
      }
    }

    return this.limitResult(maxIterations, toolCallCount);
  }

  private async requestCompletion(completionOptions: CloudChatCompletionOptions,
    options: ChatReactAgentRunOptions): Promise<CloudChatCompletionResult> {
    if (options.onContentDelta === undefined) {
      return this.client.chatCompletion(completionOptions);
    }
    return this.client.chatCompletionStream(completionOptions, {
      onContentDelta: options.onContentDelta
    });
  }

  private buildCompletionOptions(messages: CloudChatMessage[], config: CloudModelConfig,
    tools: CloudChatToolDefinition[], runOptions: ChatReactAgentRunOptions): CloudChatCompletionOptions {
    let enableThinking = runOptions.enableThinking === true;
    let preset = enableThinking ? QWEN_GENERAL_THINKING_PRESET : QWEN_GENERAL_INSTRUCT_PRESET;
    let options: CloudChatCompletionOptions = {
      baseUrl: config.plannerBaseUrl,
      apiKey: cloudPlannerApiKey(config),
      messages: messages,
      temperature: preset.temperature,
      maxTokens: runOptions.maxTokens === undefined ? QWEN_CHAT_MAX_TOKENS : runOptions.maxTokens,
      readTimeout: runOptions.readTimeout,
      logResponseContent: runOptions.logResponseContent,
      top_p: preset.top_p,
      top_k: preset.top_k,
      min_p: preset.min_p,
      presence_penalty: preset.presence_penalty,
      repetition_penalty: preset.repetition_penalty,
      model: config.plannerModel,
      chatTemplateKwargs: {
        enable_thinking: enableThinking
      }
    };
    if (tools.length > 0) {
      options.tools = tools;
      options.toolChoice = 'auto';
    }
    return options;
  }

  private normalizeMaxIterations(maxIterations?: number): number {
    if (maxIterations === undefined || maxIterations <= 0) {
      return DEFAULT_MAX_REACT_ITERATIONS;
    }
    return Math.floor(maxIterations);
  }

  private limitResult(iterations: number, toolCallCount: number): ChatReactAgentResult {
    return {
      content: ITERATION_LIMIT_MESSAGE,
      iterations: iterations,
      toolCallCount: toolCallCount,
      reachedLimit: true,
      finishReason: ''
    };
  }
}
