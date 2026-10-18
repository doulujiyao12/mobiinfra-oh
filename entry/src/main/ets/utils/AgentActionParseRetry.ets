import { AgentActionParser, ParsedAgentAction } from './AgentActionParser';

export const MAX_SAME_SCREEN_JSON_PARSE_RETRIES: number = 3;

export interface AgentActionParseRetryInfo {
  retryNumber: number;
  maxRetries: number;
  errorMessage: string;
  rawResponse: string;
}

export type AgentActionRequest = () => Promise<string>;
export type AgentActionParseRetryHandler = (info: AgentActionParseRetryInfo) => void;
export type AgentActionValidator = (parsed: ParsedAgentAction) => void;

export class AgentActionParseRetry {
  // Request errors propagate. Optional action validation also runs before dispatch and can trigger same-screen retry.
  static async request(request: AgentActionRequest,
    onRetry?: AgentActionParseRetryHandler, validate?: AgentActionValidator): Promise<ParsedAgentAction> {
    let parseFailureCount = 0;
    while (true) {
      let response = await request();
      try {
        let parsed = AgentActionParser.parse(response, true);
        if (validate !== undefined) { validate(parsed); }
        return parsed;
      } catch (e) {
        let err = e as Error;
        let errorMessage = err.message || String(e);
        if (parseFailureCount >= MAX_SAME_SCREEN_JSON_PARSE_RETRIES) {
          throw new Error('Agent ' + (validate !== undefined ? 'action validation' : 'JSON parse') + ' failed after ' +
            String(MAX_SAME_SCREEN_JSON_PARSE_RETRIES) + ' same-screen retries: ' + errorMessage);
        }
        parseFailureCount += 1;
        if (onRetry !== undefined) {
          onRetry({
            retryNumber: parseFailureCount,
            maxRetries: MAX_SAME_SCREEN_JSON_PARSE_RETRIES,
            errorMessage: errorMessage,
            rawResponse: response
          });
        }
      }
    }
  }
}
