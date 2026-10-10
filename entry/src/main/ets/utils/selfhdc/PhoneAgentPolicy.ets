import { AgentActionParser, ParsedAgentAction } from '../AgentActionParser';
import { HdcBridgeResponse } from '../WorkflowTypes';

export interface PhoneAgentScreenSize { width: number; height: number; }

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
