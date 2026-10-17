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

export class AgentActionParseRetry {
  // Model request errors propagate. Phone callers also validate response completeness and required action fields.
  static async request(request: AgentActionRequest,
    onRetry?: AgentActionParseRetryHandler, requireExecutable: boolean = false): Promise<ParsedAgentAction> {
    let parseFailureCount = 0;
    while (true) {
      let response = await request();
      try {
        return requireExecutable ? AgentActionParser.parseExecutable(response) : AgentActionParser.parse(response, true);
      } catch (e) {
        let err = e as Error;
        let errorMessage = err.message || String(e);
        if (parseFailureCount >= MAX_SAME_SCREEN_JSON_PARSE_RETRIES) {
          throw new Error('Agent ' + (requireExecutable ? 'action validation' : 'JSON parse') + ' failed after ' +
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
