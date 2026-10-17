import { AgentActionParser, ParsedAgentAction } from '../AgentActionParser';
import { HdcBridgeResponse } from '../WorkflowTypes';

export interface PhoneAgentScreenSize { width: number; height: number; }

export const PHONE_AGENT_MAX_ACTION_TOKENS: number = 4096;
export const PHONE_AGENT_ACTION_OUTPUT_RULES: string =
  '\nReturn one complete JSON action. Keep reasoning to one short sentence; do not repeat the input text there. ' +
  'For long messages, first click to focus the input, then use a separate input action with the full text. ' +
  'Describe a text input field as "input field" in target_element when focusing it. ' +
  'If using click_input, put bbox before text in parameters. Never omit the coordinates of a click.';

// An input action can contain the entire user message, not just a short coordinate pair.
export function phoneAgentActionTokenBudget(task: string): number {
  return Math.min(PHONE_AGENT_MAX_ACTION_TOKENS, Math.ceil((1024 + task.length * 3) / 512) * 512);
}

export function phoneAgentOutputWasTruncated(finishReason: string): boolean {
  return finishReason === 'length' || finishReason === 'max_tokens';
}

export function phoneAgentLogText(message: string): string {
  return message.replace(/data:image\/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+/g, '[image data omitted]');
}

// Use the original display dimensions: resized dimensions times 2/4 lose pixels on odd-sized displays.
export function phoneAgentScreenSize(shot: HdcBridgeResponse): PhoneAgentScreenSize {
  let width = shot.screen_width || 0; let height = shot.screen_height || 0;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0 ||
    !shot.image_b64 || !shot.width || !shot.height || shot.width <= 0 || shot.height <= 0) {
    throw new Error('PHONE_AGENT_IMAGE: missing original screen dimensions or model image');
  }
  return { width: width, height: height };
}

export function phoneAgentAssertCompleted(parsed: ParsedAgentAction): void {
  let rootStatus = AgentActionParser.getMapString(parsed.data, 'status').trim().toLowerCase();
  let status = AgentActionParser.getMapString(parsed.parameters, 'status').trim().toLowerCase() || rootStatus;
  if (rootStatus === 'failed' || rootStatus === 'suspended') { status = rootStatus; }
  if (parsed.action !== 'done' || (status !== '' && status !== 'success' && status !== 'completed')) {
    throw new Error('PHONE_AGENT_INCOMPLETE: action=' + parsed.action + ' status=' + (status || 'unspecified') +
      ' reason=' + AgentActionParser.getMapString(parsed.parameters, 'reason',
      AgentActionParser.getMapString(parsed.data, 'reason', '模型未确认任务成功')));
  }
}
