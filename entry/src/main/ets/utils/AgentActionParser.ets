import { parseJsonCompat, stringifyJsonCompat } from './JsonCompat';
import { WorkflowJsonRepair } from './WorkflowJsonRepair';
import { WorkflowJsonMap, WorkflowJsonValue } from './WorkflowTypes';

export interface ParsedAgentAction {
  raw: string;
  data: WorkflowJsonMap;
  action: string;
  parameters: WorkflowJsonMap;
}

interface Point {
  x: number;
  y: number;
}

interface EmptyMap {
}

interface RawResponseMap {
  raw_response: string;
}

interface ClickActionPayload {
  action: string;
  x: number;
  y: number;
  target_element?: string;
}

interface ClickInputActionPayload {
  action: string;
  x: number;
  y: number;
  text: string;
  target_element?: string;
}

interface InputActionPayload {
  action: string;
  text: string;
  x?: number;
  y?: number;
  target_element?: string;
}

interface SwipeWithCoordsActionPayload {
  action: string;
  start_x: number;
  start_y: number;
  end_x: number;
  end_y: number;
  target_element?: string;
}

interface SwipeActionPayload {
  action: string;
  direction: string;
  width: number;
  height: number;
  target_element?: string;
}

interface SleepActionPayload {
  action: string;
  seconds: number;
}

interface AppStartActionPayload {
  action: string;
  app_name: string;
  package_name: string;
  reset_first: boolean;
}

interface KeyActionPayload {
  action: string;
  key: string;
}

export class AgentActionParser {
  static extractJsonMap(raw: string, failOnParseError: boolean = true): WorkflowJsonMap {
    let text = WorkflowJsonRepair.normalizeJsonText(raw);
    try {
      let parsed = parseJsonCompat<WorkflowJsonMap>(text);
      return AgentActionParser.unwrapKnownPayload(parsed, 0);
    } catch (e) {
      let candidates = WorkflowJsonRepair.repairCandidates(text);
      let lastMessage = (e as Error).message || String(e);
      for (let i = 0; i < candidates.length; i++) {
        try {
          let parsed = parseJsonCompat<WorkflowJsonMap>(candidates[i]);
          return AgentActionParser.unwrapKnownPayload(parsed, 0);
        } catch (repairError) {
          lastMessage = (repairError as Error).message || String(repairError);
        }
      }
      if (failOnParseError) {
        throw new Error('Agent JSON parse failed: ' + lastMessage);
      }
      let fallback: RawResponseMap = {
        raw_response: raw
      };
      return fallback as Object as WorkflowJsonMap;
    }
  }

  static parse(raw: string, failOnParseError: boolean = true): ParsedAgentAction {
    let data = AgentActionParser.extractJsonMap(raw, failOnParseError);
    let action = AgentActionParser.getMapString(data, 'action').toLowerCase();
    if (failOnParseError && action.length === 0) {
      throw new Error('Agent JSON parse failed: response missing action');
    }
    let paramsValue = data['parameters'];
    if (paramsValue === undefined || paramsValue === null) {
      paramsValue = data['coordinates'];
    }
    let params = AgentActionParser.toMap(paramsValue);
    if (Object.keys(params).length === 0) {
      if (data['coords'] !== undefined || data['bbox'] !== undefined || data['text'] !== undefined ||
        data['direction'] !== undefined || data['start_coords'] !== undefined || data['end_coords'] !== undefined) {
        params = data;
      }
    }
    let parsed: ParsedAgentAction = {
      raw: raw,
      data: data,
      action: action,
      parameters: params
    };
    return parsed;
  }

  static isTerminal(action: string): boolean {
    let normalized = action.toLowerCase();
    return normalized === 'done' || normalized === 'stop' || normalized === 'terminate' || normalized === 'abort';
  }

  // Phone execution must not invent missing text/coordinates by closing a truncated response.
  // Keep the existing syntax repairs for complete responses and the legacy PC parsing path.
  static parseExecutable(raw: string): ParsedAgentAction {
    let text = WorkflowJsonRepair.normalizeJsonText(raw);
    let inString = false;
    let escaped = false;
    let objects = 0;
    let arrays = 0;
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
      throw new Error('Agent action response is truncated: incomplete JSON; no action was executed');
    }
    let parsed = AgentActionParser.parse(raw, true);
    if (parsed.action === 'input' || parsed.action === 'click_input') {
      let input = parsed.parameters['text'];
      if (typeof input !== 'string' || input.length === 0) {
        throw new Error('Agent input action missing required nonempty text');
      }
    }
    if (!AgentActionParser.isTerminal(parsed.action) && parsed.action !== 'error') {
      // Pure validation: catches a complete JSON object with absent bbox/coords before HDC is called.
      AgentActionParser.buildHdcActionPayload(parsed, 1000, 1000);
    }
    return parsed;
  }

  static buildHdcActionPayload(parsed: ParsedAgentAction, width: number, height: number): WorkflowJsonMap {
    let action = parsed.action;
    let params = parsed.parameters;
    if (action.length === 0) {
      throw new Error('Agent response missing action');
    }

    if (action === 'click') {
      let point = AgentActionParser.resolveClickPoint(params, width, height);
      let payload: ClickActionPayload = {
        action: 'click',
        x: point.x,
        y: point.y
      };
      let targetElement = AgentActionParser.getTargetElement(parsed);
      if (targetElement.length > 0) {
        payload.target_element = targetElement;
      }
      return payload as Object as WorkflowJsonMap;
    }

    if (action === 'click_input') {
      let point = AgentActionParser.resolveClickPoint(params, width, height);
      let payload: ClickInputActionPayload = {
        action: 'click_input',
        x: point.x,
        y: point.y,
        text: AgentActionParser.getMapString(params, 'text')
      };
      let targetElement = AgentActionParser.getTargetElement(parsed);
      if (targetElement.length > 0) {
        payload.target_element = targetElement;
      }
      return payload as Object as WorkflowJsonMap;
    }

    if (action === 'input') {
      let payload: InputActionPayload = {
        action: 'input',
        text: AgentActionParser.getMapString(params, 'text')
      };
      if (params['coords'] !== undefined || params['bbox'] !== undefined) {
        let point = AgentActionParser.resolveClickPoint(params, width, height);
        payload.x = point.x;
        payload.y = point.y;
      }
      let targetElement = AgentActionParser.getTargetElement(parsed);
      if (targetElement.length > 0) {
        payload.target_element = targetElement;
      }
      return payload as Object as WorkflowJsonMap;
    }

    if (action === 'swipe') {
      let startCoords = AgentActionParser.getNumberArray(params, 'start_coords');
      let endCoords = AgentActionParser.getNumberArray(params, 'end_coords');
      let explicitDirection = AgentActionParser.getMapString(params, 'direction');
      let direction = explicitDirection.length > 0 ? explicitDirection : 'UP';
      if (startCoords.length >= 2 && endCoords.length >= 2) {
        let start = AgentActionParser.convertNormalizedPoint(startCoords[0], startCoords[1], width, height);
        let end = AgentActionParser.convertNormalizedPoint(endCoords[0], endCoords[1], width, height);
        if (AgentActionParser.shouldUseExplicitSwipeCoords(start, end, explicitDirection, width, height)) {
          let payload: SwipeWithCoordsActionPayload = {
            action: 'swipe_with_coords',
            start_x: start.x,
            start_y: start.y,
            end_x: end.x,
            end_y: end.y
          };
          let targetElement = AgentActionParser.getTargetElement(parsed);
          if (targetElement.length > 0) {
            payload.target_element = targetElement;
          }
          return payload as Object as WorkflowJsonMap;
        }
      }
      let payload: SwipeActionPayload = {
        action: 'swipe',
        direction: direction,
        width: width,
        height: height
      };
      let targetElement = AgentActionParser.getTargetElement(parsed);
      if (targetElement.length > 0) {
        payload.target_element = targetElement;
      }
      return payload as Object as WorkflowJsonMap;
    }

    if (action === 'wait') {
      let payload: SleepActionPayload = {
        action: 'sleep',
        seconds: AgentActionParser.getMapNumber(params, 'seconds', 1)
      };
      return payload as Object as WorkflowJsonMap;
    }

    if (action === 'open_app') {
      let appName = AgentActionParser.getMapString(params, 'app_name');
      let packageName = AgentActionParser.getMapString(params, 'package_name');
      if (appName.length === 0 && packageName.length === 0) {
        throw new Error('Open_app action missing app_name/package_name');
      }
      let payload: AppStartActionPayload = {
        action: 'app_start',
        app_name: appName,
        package_name: packageName.length > 0 ? packageName : appName,
        reset_first: true
      };
      return payload as Object as WorkflowJsonMap;
    }

    if (action === 'press_home') {
      let payload: KeyActionPayload = {
        action: 'keyevent',
        key: 'HOME'
      };
      return payload as Object as WorkflowJsonMap;
    }

    if (action === 'press_back') {
      let payload: KeyActionPayload = {
        action: 'keyevent',
        key: 'BACK'
      };
      return payload as Object as WorkflowJsonMap;
    }

    throw new Error('Unknown action: ' + action);
  }

  static getSwipeFallbackDiagnostic(parsed: ParsedAgentAction, width: number, height: number): string {
    if (parsed.action !== 'swipe') {
      return '';
    }
    let params = parsed.parameters;
    let direction = AgentActionParser.getMapString(params, 'direction');
    let startCoords = AgentActionParser.getNumberArray(params, 'start_coords');
    let endCoords = AgentActionParser.getNumberArray(params, 'end_coords');
    if (direction.length === 0 || startCoords.length < 2 || endCoords.length < 2) {
      return '';
    }
    let start = AgentActionParser.convertNormalizedPoint(startCoords[0], startCoords[1], width, height);
    let end = AgentActionParser.convertNormalizedPoint(endCoords[0], endCoords[1], width, height);
    let reason = AgentActionParser.explicitSwipeRejectionReason(start, end, direction, width, height);
    if (reason.length === 0) {
      return '';
    }
    return 'explicit swipe coords rejected: direction=' + direction.toUpperCase() +
      ', start=[' + String(start.x) + ',' + String(start.y) + ']' +
      ', end=[' + String(end.x) + ',' + String(end.y) + ']' +
      ', reason=' + reason + '; using direction-based swipe';
  }

  static getMapString(map: WorkflowJsonMap, key: string, fallback: string = ''): string {
    let value = map[key];
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    return fallback;
  }

  static getMapNumber(map: WorkflowJsonMap, key: string, fallback: number = 0): number {
    let value = map[key];
    if (typeof value === 'number') {
      return value;
    }
    if (typeof value === 'string') {
      let parsed = Number(value);
      return isNaN(parsed) ? fallback : parsed;
    }
    return fallback;
  }

  private static getTargetElement(parsed: ParsedAgentAction): string {
    let targetElement = AgentActionParser.getMapString(parsed.parameters, 'target_element');
    if (targetElement.length === 0) {
      targetElement = AgentActionParser.getMapString(parsed.data, 'target_element');
    }
    if (targetElement.length === 0) {
      targetElement = AgentActionParser.getMapString(parsed.parameters, 'targetElement');
    }
    return targetElement;
  }

  static normalizeCloudHistoryItem(response: string): string {
    let text = response.trim();
    let jsonStart = text.indexOf('{');
    let jsonEnd = text.lastIndexOf('}');
    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      text = text.substring(jsonStart, jsonEnd + 1);
    }
    try {
      let parsed = parseJsonCompat<Object>(text);
      return stringifyJsonCompat(parsed);
    } catch (e) {
      return response;
    }
  }

  private static resolveClickPoint(params: WorkflowJsonMap, width: number, height: number): Point {
    let coords = AgentActionParser.getNumberArray(params, 'coords');
    if (coords.length >= 2) {
      return AgentActionParser.convertNormalizedPoint(coords[0], coords[1], width, height);
    }

    let bbox = AgentActionParser.getNumberArray(params, 'bbox');
    if (bbox.length < 4) {
      throw new Error('Click action missing required parameter: bbox or coords');
    }
    let x1 = AgentActionParser.normalizedToAbsolute(bbox[0], width);
    let y1 = AgentActionParser.normalizedToAbsolute(bbox[1], height);
    let x2 = AgentActionParser.normalizedToAbsolute(bbox[2], width);
    let y2 = AgentActionParser.normalizedToAbsolute(bbox[3], height);
    let point: Point = {
      x: AgentActionParser.truncate((x1 + x2) / 2),
      y: AgentActionParser.truncate((y1 + y2) / 2)
    };
    return point;
  }

  private static convertNormalizedPoint(x: number, y: number, width: number, height: number): Point {
    let point: Point = {
      x: AgentActionParser.normalizedToAbsolute(x, width),
      y: AgentActionParser.normalizedToAbsolute(y, height)
    };
    return point;
  }

  private static shouldUseExplicitSwipeCoords(start: Point, end: Point, direction: string, width: number,
    height: number): boolean {
    return AgentActionParser.explicitSwipeRejectionReason(start, end, direction, width, height).length === 0;
  }

  private static explicitSwipeRejectionReason(start: Point, end: Point, direction: string, width: number,
    height: number): string {
    let normalized = direction.toLowerCase();
    if (normalized.length === 0) {
      return '';
    }
    let dx = Math.abs(end.x - start.x);
    let dy = Math.abs(end.y - start.y);
    if (normalized === 'up' || normalized === 'down') {
      if (dy < height * 0.12) {
        return 'vertical distance too short';
      }
      if (dy < dx) {
        return 'gesture is not primarily vertical';
      }
      if (start.y < height * 0.28 || start.y > height * 0.88) {
        return 'start point is outside the safe vertical area';
      }
      if (normalized === 'down' ? end.y <= start.y : end.y >= start.y) {
        return 'coordinates conflict with direction';
      }
      return '';
    }
    if (normalized === 'left' || normalized === 'right') {
      if (dx < width * 0.12) {
        return 'horizontal distance too short';
      }
      if (dx < dy) {
        return 'gesture is not primarily horizontal';
      }
      if (start.x < width * 0.12 || start.x > width * 0.88) {
        return 'start point is outside the safe horizontal area';
      }
      if (normalized === 'right' ? end.x <= start.x : end.x >= start.x) {
        return 'coordinates conflict with direction';
      }
      return '';
    }
    return '';
  }

  private static normalizedToAbsolute(value: number, size: number): number {
    let clamped = Math.min(value, 1000);
    return AgentActionParser.truncate(clamped * size / 1000);
  }

  private static truncate(value: number): number {
    if (value < 0) {
      return Math.ceil(value);
    }
    return Math.floor(value);
  }

  private static getNumberArray(map: WorkflowJsonMap, key: string): number[] {
    return AgentActionParser.valueToNumberArray(map[key]);
  }

  private static valueToNumberArray(value: WorkflowJsonValue | undefined): number[] {
    if (value === undefined || value === null || !Array.isArray(value)) {
      return [];
    }
    let items = value as Object[];
    if (items.length === 1 && Array.isArray(items[0])) {
      return AgentActionParser.valueToNumberArray(items[0] as WorkflowJsonValue);
    }
    let result: number[] = [];
    for (let i = 0; i < items.length; i++) {
      let parsed = Number(String(items[i]));
      if (!isNaN(parsed)) {
        result.push(parsed);
      }
    }
    return result;
  }

  private static toMap(value: WorkflowJsonValue | undefined): WorkflowJsonMap {
    if (value === undefined || value === null || Array.isArray(value)) {
      let empty: EmptyMap = {};
      return empty as Object as WorkflowJsonMap;
    }
    if (typeof value === 'object') {
      return value as WorkflowJsonMap;
    }
    let empty: EmptyMap = {};
    return empty as Object as WorkflowJsonMap;
  }

  private static unwrapKnownPayload(map: WorkflowJsonMap, depth: number): WorkflowJsonMap {
    if (AgentActionParser.isKnownPayload(map) || depth >= 4) {
      return map;
    }

    let nested = AgentActionParser.findNestedPayload(map, depth);
    if (nested !== null) {
      return nested;
    }
    return map;
  }

  private static isKnownPayload(map: WorkflowJsonMap): boolean {
    return map['action'] !== undefined || map['app'] !== undefined || map['target_app'] !== undefined ||
      map['app_name'] !== undefined || map['package_name'] !== undefined || map['bundle'] !== undefined ||
      map['bundle_name'] !== undefined || map['final_task_description'] !== undefined;
  }

  private static findNestedPayload(map: WorkflowJsonMap, depth: number): WorkflowJsonMap | null {
    let wrapperKeys: string[] = [
      'response',
      'content',
      'output',
      'text',
      'message',
      'result',
      'data',
      'arguments',
      'tool_input',
      'choices',
      'delta'
    ];
    for (let i = 0; i < wrapperKeys.length; i++) {
      let nested = AgentActionParser.valueToKnownPayload(map[wrapperKeys[i]], depth + 1);
      if (nested !== null) {
        return nested;
      }
    }

    if (depth === 0) {
      let keys = Object.keys(map);
      for (let i = 0; i < keys.length; i++) {
        if (wrapperKeys.indexOf(keys[i]) >= 0) {
          continue;
        }
        let nested = AgentActionParser.valueToKnownPayload(map[keys[i]], depth + 1);
        if (nested !== null) {
          return nested;
        }
      }
    }
    return null;
  }

  private static valueToKnownPayload(value: WorkflowJsonValue | undefined, depth: number): WorkflowJsonMap | null {
    if (value === undefined || value === null || depth > 4) {
      return null;
    }
    if (typeof value === 'string') {
      return AgentActionParser.stringToKnownPayload(value, depth);
    }
    if (Array.isArray(value)) {
      let items = value as Object[];
      let limit = items.length > 8 ? 8 : items.length;
      for (let i = 0; i < limit; i++) {
        let nested = AgentActionParser.valueToKnownPayload(items[i] as WorkflowJsonValue, depth + 1);
        if (nested !== null) {
          return nested;
        }
      }
      return null;
    }
    if (typeof value === 'object') {
      let nestedMap = value as WorkflowJsonMap;
      let unwrapped = AgentActionParser.unwrapKnownPayload(nestedMap, depth + 1);
      if (AgentActionParser.isKnownPayload(unwrapped)) {
        return unwrapped;
      }
    }
    return null;
  }

  private static stringToKnownPayload(value: string, depth: number): WorkflowJsonMap | null {
    let text = WorkflowJsonRepair.normalizeJsonText(value);
    try {
      let parsed = parseJsonCompat<WorkflowJsonMap>(text);
      let unwrapped = AgentActionParser.unwrapKnownPayload(parsed, depth + 1);
      return AgentActionParser.isKnownPayload(unwrapped) ? unwrapped : null;
    } catch (e) {
      let candidates = WorkflowJsonRepair.repairCandidates(text);
      for (let i = 0; i < candidates.length; i++) {
        try {
          let parsed = parseJsonCompat<WorkflowJsonMap>(candidates[i]);
          let unwrapped = AgentActionParser.unwrapKnownPayload(parsed, depth + 1);
          if (AgentActionParser.isKnownPayload(unwrapped)) {
            return unwrapped;
          }
        } catch (repairError) {
        }
      }
    }
    return null;
  }
}
