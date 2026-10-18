import { AgentActionParser, ParsedAgentAction } from '../AgentActionParser';
import { HdcBridgeResponse, WorkflowJsonMap, WorkflowJsonValue } from '../WorkflowTypes';
import { WorkflowJsonRepair } from '../WorkflowJsonRepair';

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

function assertCompletePhoneAction(raw: string): void {
  let text = WorkflowJsonRepair.normalizeJsonText(raw);
  let inString = false; let escaped = false; let objects = 0; let arrays = 0;
  for (let i = 0; i < text.length; i++) {
    let ch = text.charAt(i);
    if (inString) {
      if (escaped) { escaped = false; }
      else if (ch === '\\') { escaped = true; }
      else if (ch === '"') { inString = false; }
    } else if (ch === '"') { inString = true; }
    else if (ch === '{') { objects += 1; }
    else if (ch === '}') { objects -= 1; }
    else if (ch === '[') { arrays += 1; }
    else if (ch === ']') { arrays -= 1; }
  }
  if (inString || objects > 0 || arrays > 0) {
    throw new Error('PHONE_AGENT_ACTION: truncated JSON/text; no device action executed');
  }
}

function phoneActionCoordinates(params: WorkflowJsonMap, key: string, count: number): number[] {
  let value = params[key];
  if (!Array.isArray(value)) { throw new Error('PHONE_AGENT_COORDINATE: missing ' + key); }
  let items = value as WorkflowJsonValue[];
  if (items.length === 1 && Array.isArray(items[0])) { items = items[0] as WorkflowJsonValue[]; }
  if (items.length !== count) { throw new Error('PHONE_AGENT_COORDINATE: invalid ' + key + ' length'); }
  let result: number[] = [];
  for (let item of items) {
    if ((typeof item !== 'number' && typeof item !== 'string') || String(item).trim() === '') {
      throw new Error('PHONE_AGENT_COORDINATE: invalid ' + key + ' value');
    }
    let number = Number(String(item));
    if (!Number.isFinite(number) || number < 0 || number > 1000) {
      throw new Error('PHONE_AGENT_COORDINATE: ' + key + ' must be finite values within 0–1000');
    }
    result.push(number);
  }
  return result;
}

function assertPhoneClickCoordinates(params: WorkflowJsonMap): void {
  if (params['coords'] !== undefined) { phoneActionCoordinates(params, 'coords', 2); return; }
  let box = phoneActionCoordinates(params, 'bbox', 4);
  if (box[0] >= box[2] || box[1] >= box[3]) {
    throw new Error('PHONE_AGENT_COORDINATE: bbox must have positive width and height');
  }
}

// Validate before the shared parser can discard invalid coordinate items or clamp them to the screen edge.
// This opt-in validator leaves the PC protocol and its existing parsing behavior unchanged.
export function phoneAgentValidateAction(parsed: ParsedAgentAction): void {
  assertCompletePhoneAction(parsed.raw);
  let params = parsed.parameters;
  if (parsed.action === 'click' || parsed.action === 'click_input') { assertPhoneClickCoordinates(params); }
  if (parsed.action === 'input' || parsed.action === 'click_input') {
    let text = params['text'];
    if (typeof text !== 'string' || text.indexOf('\0') >= 0 || text.length > 8192) {
      throw new Error('PHONE_AGENT_ACTION: input requires complete text of at most 8192 characters without NUL');
    }
    if (parsed.action === 'input' && (params['coords'] !== undefined || params['bbox'] !== undefined)) {
      assertPhoneClickCoordinates(params);
    }
  }
  if (parsed.action === 'swipe') {
    let hasCoordinates = params['start_coords'] !== undefined || params['end_coords'] !== undefined;
    let direction = AgentActionParser.getMapString(params, 'direction').toUpperCase();
    if (hasCoordinates) {
      phoneActionCoordinates(params, 'start_coords', 2);
      phoneActionCoordinates(params, 'end_coords', 2);
    }
    if ((!hasCoordinates && !direction) || (direction && ['UP', 'DOWN', 'LEFT', 'RIGHT'].indexOf(direction) < 0)) {
      throw new Error('PHONE_AGENT_ACTION: swipe requires valid coordinates or direction');
    }
  }
  if (!AgentActionParser.isTerminal(parsed.action) && parsed.action !== 'error') {
    AgentActionParser.buildHdcActionPayload(parsed, 1000, 1000);
  }
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
