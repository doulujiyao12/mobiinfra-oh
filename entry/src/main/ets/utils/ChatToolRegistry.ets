import {
  CloudChatToolDefinition,
  CloudToolCall
} from './CloudModelClient';
import { parseJsonCompat, stringifyJsonCompat } from './JsonCompat';
import { MobileGuiTaskExecutionCallbacks } from './MobileGuiTaskTypes';
import { CodexChatRunCallback } from '../pages/codex/CodexChatTypes';

export interface ChatToolExecutionContext extends MobileGuiTaskExecutionCallbacks {
  filesDir: string;
  sessionId: string;
  userMessage: string;
  runCodexTask?: CodexChatRunCallback;
}

export interface ChatTool {
  name: string;
  description: string;
  parameters: Object;
  strict?: boolean;
  execute: (argsText: string, context: ChatToolExecutionContext) => Promise<string>;
  /**
   * 判断工具结果是否代表本轮聊天必须终止的用户意图。终止后不再把结果交给模型重试，
   * 适用于用户明确拒绝或取消具有真实设备副作用的操作。
   */
  terminalResultMessage?: (content: string) => string | null;
}

export interface ChatToolExecutionResult {
  toolName: string;
  toolCallId: string;
  argumentsText: string;
  content: string;
  traceLine: string;
  success: boolean;
  terminal: boolean;
  terminalMessage: string;
}

interface ChatToolArgumentValidation {
  ok: boolean;
  normalizedArgs: string;
  error: string;
}

interface ChatToolErrorPayload {
  ok: boolean;
  error: string;
}

const MAX_TOOL_RESULT_LENGTH: number = 4000;

export class ChatToolRegistry {
  private tools: ChatTool[] = [];

  registerTool(tool: ChatTool): void {
    this.tools = this.tools.filter((item: ChatTool) => item.name !== tool.name);
    this.tools.push(tool);
  }

  hasTools(): boolean {
    return this.tools.length > 0;
  }

  getOpenAiTools(): CloudChatToolDefinition[] {
    let definitions: CloudChatToolDefinition[] = [];
    for (let i = 0; i < this.tools.length; i++) {
      let tool = this.tools[i];
      definitions.push({
        type: 'function',
        function: {
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
          strict: tool.strict === undefined ? false : tool.strict
        }
      });
    }
    return definitions;
  }

  async executeToolCall(toolCall: CloudToolCall, context: ChatToolExecutionContext): Promise<ChatToolExecutionResult> {
    let toolName = toolCall.function.name;
    let argsText = toolCall.function.arguments === undefined ? '' : toolCall.function.arguments;
    let normalized = this.validateArguments(argsText);
    if (!normalized.ok) {
      return this.errorResult(toolName, toolCall.id, normalized.normalizedArgs, normalized.error);
    }

    let tool = this.findTool(toolName);
    if (tool === null) {
      return this.errorResult(toolName, toolCall.id, normalized.normalizedArgs, 'Tool ' + toolName + ' does not exist.');
    }

    try {
      let rawContent = await tool.execute(normalized.normalizedArgs, context);
      let content = this.truncateResult(rawContent);
      let terminalMessage = tool.terminalResultMessage === undefined ? null :
        tool.terminalResultMessage(rawContent);
      return {
        toolName: toolName,
        toolCallId: toolCall.id,
        argumentsText: normalized.normalizedArgs,
        content: content,
        traceLine: this.buildTraceLine(toolName, normalized.normalizedArgs, rawContent),
        success: true,
        terminal: terminalMessage !== null,
        terminalMessage: terminalMessage === null ? '' : terminalMessage
      };
    } catch (e) {
      let err = e as Error;
      return this.errorResult(toolName, toolCall.id, normalized.normalizedArgs,
        'Tool ' + toolName + ' failed: ' + err.message);
    }
  }

  private findTool(name: string): ChatTool | null {
    for (let i = 0; i < this.tools.length; i++) {
      if (this.tools[i].name === name) {
        return this.tools[i];
      }
    }
    return null;
  }

  private validateArguments(argsText: string): ChatToolArgumentValidation {
    let normalizedArgs = argsText.trim().length === 0 ? '{}' : argsText.trim();
    try {
      let parsed = parseJsonCompat<Object | string | number | boolean | null>(normalizedArgs);
      if (parsed !== null && typeof parsed === 'object') {
        return {
          ok: true,
          normalizedArgs: normalizedArgs,
          error: ''
        };
      }
      return {
        ok: false,
        normalizedArgs: normalizedArgs,
        error: 'Tool arguments must be a JSON object.'
      };
    } catch (e) {
      let err = e as Error;
      return {
        ok: false,
        normalizedArgs: normalizedArgs,
        error: 'Tool arguments JSON parse failed: ' + err.message
      };
    }
  }

  private errorResult(toolName: string, toolCallId: string, argumentsText: string,
    errorMessage: string): ChatToolExecutionResult {
    let content = this.errorPayload(errorMessage);
    return {
      toolName: toolName,
      toolCallId: toolCallId,
      argumentsText: argumentsText,
      content: content,
      traceLine: this.buildTraceLine(toolName, argumentsText, content),
      success: false,
      terminal: false,
      terminalMessage: ''
    };
  }

  private errorPayload(errorMessage: string): string {
    let payload: ChatToolErrorPayload = {
      ok: false,
      error: errorMessage
    };
    return stringifyJsonCompat(payload as Object);
  }

  private truncateResult(text: string): string {
    if (text.length <= MAX_TOOL_RESULT_LENGTH) {
      return text;
    }
    return text.substring(0, MAX_TOOL_RESULT_LENGTH) + '...';
  }

  private buildTraceLine(toolName: string, argumentsText: string, content: string): string {
    return '工具：' + toolName + '\n参数：' + argumentsText + '\n结果：' + content;
  }
}

export function createDefaultChatToolRegistry(): ChatToolRegistry {
  return new ChatToolRegistry();
}
