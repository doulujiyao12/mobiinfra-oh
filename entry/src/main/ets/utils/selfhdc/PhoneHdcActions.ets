import { WorkflowJsonMap } from '../WorkflowTypes';
import { selfHdcShellQuote, selfHdcSwipeForSize } from './SelfHdcPolicy';

export interface PhoneHdcPoint { x: number; y: number; }
export interface PhoneHdcCommand {
  command: string;
  label: string;
  delayMs: number;
  sensitive: boolean;
}
export interface PhoneHdcActionPlan {
  action: string;
  commands: PhoneHdcCommand[];
  inputTarget: PhoneHdcPoint | null;
}

export function phoneHdcString(payload: WorkflowJsonMap, key: string, fallback: string = ''): string {
  let value = payload[key];
  if (value === undefined) { return fallback; }
  if (typeof value !== 'string') { throw new Error('PHONE_HDC_ARGUMENT: ' + key + ' must be text'); }
  return value;
}

function numberField(payload: WorkflowJsonMap, key: string, fallback?: number): number {
  let value = payload[key];
  if (value === undefined && fallback !== undefined) { return fallback; }
  if ((typeof value !== 'number' && typeof value !== 'string') || String(value).trim() === '') {
    throw new Error('PHONE_HDC_ARGUMENT: missing/invalid ' + key);
  }
  let result = Number(value);
  if (!Number.isFinite(result)) { throw new Error('PHONE_HDC_ARGUMENT: invalid ' + key); }
  return result;
}

// PC workflow input-target policy, reproduced here without changing the PC implementation.
export class PhoneHdcActions {
  private width: number = 0;
  private height: number = 0;
  private inputTarget: PhoneHdcPoint | null = null;

  setScreen(width: number, height: number): void {
    selfHdcSwipeForSize(width, height);
    if (width !== this.width || height !== this.height) { this.reset(); }
    this.width = width; this.height = height;
  }

  reset(): void { this.inputTarget = null; }

  private point(x: number, y: number): PhoneHdcPoint {
    if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0 || x > this.width || y > this.height ||
      this.width === 0 || this.height === 0) {
      throw new Error('PHONE_HDC_COORDINATE: point outside physical screen ' + this.width + 'x' + this.height);
    }
    // Normalized model coordinates can resolve the final edge to exactly width/height.
    return { x: Math.min(Math.floor(x), this.width - 1), y: Math.min(Math.floor(y), this.height - 1) };
  }

  private command(command: string, label: string, delayMs: number = 0, sensitive: boolean = false): PhoneHdcCommand {
    return { command: command, label: label, delayMs: delayMs, sensitive: sensitive };
  }

  plan(payload: WorkflowJsonMap): PhoneHdcActionPlan {
    let action = phoneHdcString(payload, 'action').toLowerCase();
    let commands: PhoneHdcCommand[] = [];
    let inputTarget: PhoneHdcPoint | null = this.inputTarget;
    if (action === 'click' || action === 'click_input' || action === 'input') {
      let hasX = payload['x'] !== undefined;
      let hasY = payload['y'] !== undefined;
      if (hasX !== hasY) { throw new Error('PHONE_HDC_FOCUS: x/y must be supplied together'); }
      let point = hasX ? this.point(numberField(payload, 'x'), numberField(payload, 'y')) : this.inputTarget;
      if (!point || (action !== 'input' && !hasX)) {
        throw new Error('PHONE_HDC_FOCUS: input needs coordinates or a prior input-field click; refusing unknown focus');
      }
      commands.push(this.command('uitest uiInput click ' + point.x + ' ' + point.y, 'activate/click', 500));
      if (action === 'click') {
        inputTarget = null;
        let target = phoneHdcString(payload, 'target_element', phoneHdcString(payload, 'targetElement')).toLowerCase();
        if (/input box|input field|search box|search field|search bar|text input|text field|textbox|text box|edittext|edit box|输入框|输入栏|搜索框|搜索栏|搜索输入/.test(target)) {
          inputTarget = point;
        }
      } else {
        let text = phoneHdcString(payload, 'text');
        if (text.indexOf('\0') >= 0 || text.length > 8192) {
          throw new Error('PHONE_HDC_TEXT: NUL or text longer than 8192 characters is unsupported');
        }
        inputTarget = point;
        commands.push(this.command('uitest uiInput keyEvent 2072 2017', 'select-all', 100));
        commands.push(this.command('uitest uiInput keyEvent 2071', 'clear-input', 100));
        if (text.length > 0) {
          commands.push(this.command('uitest uiInput text ' + selfHdcShellQuote(text), 'input-text chars=' + text.length, 250, true));
        }
        // Match the PC's default driver-input path. Diagnostics can explicitly suppress submission.
        if (payload['submit_enter'] !== false) {
          commands.push(this.command('uitest uiInput keyEvent 2054', 'submit-enter', 300));
        }
      }
    } else if (action === 'swipe' || action === 'swipe_with_coords') {
      inputTarget = null;
      let start: PhoneHdcPoint;
      let end: PhoneHdcPoint;
      if (action === 'swipe_with_coords') {
        start = this.point(numberField(payload, 'start_x'), numberField(payload, 'start_y'));
        end = this.point(numberField(payload, 'end_x'), numberField(payload, 'end_y'));
      } else {
        let direction = phoneHdcString(payload, 'direction', 'up').toLowerCase();
        if (direction === 'up' || direction === 'down') {
          start = this.point(this.width * 0.5, this.height * (direction === 'up' ? 0.7 : 0.3));
          end = this.point(this.width * 0.5, this.height * (direction === 'up' ? 0.3 : 0.7));
        } else if (direction === 'left' || direction === 'right') {
          start = this.point(this.width * (direction === 'left' ? 0.7 : 0.3), this.height * 0.5);
          end = this.point(this.width * (direction === 'left' ? 0.3 : 0.7), this.height * 0.5);
        } else { throw new Error('PHONE_HDC_ARGUMENT: unknown swipe direction ' + direction); }
      }
      commands.push(this.command('uitest uiInput swipe ' + start.x + ' ' + start.y + ' ' + end.x + ' ' + end.y,
        'swipe', 700));
    } else if (action === 'keyevent') {
      let key = phoneHdcString(payload, 'key', 'BACK').toUpperCase();
      let code = key === 'BACK' ? 2 : (key === 'HOME' ? 1 : (key === 'ENTER' ? 2054 : 0));
      if (code === 0) {
        if (!/^\d{1,5}$/.test(key) || Number(key) < 1 || Number(key) > 10000) {
          throw new Error('PHONE_HDC_ARGUMENT: unsupported key ' + key);
        }
        code = Number(key);
      }
      if (code === 1 || code === 2) { inputTarget = null; }
      commands.push(this.command('uitest uiInput keyEvent ' + code, 'keyevent', 300));
    } else if (action === 'sleep' || action === 'wait') {
      let seconds = numberField(payload, 'seconds', 1);
      if (seconds < 0 || seconds > 60) { throw new Error('PHONE_HDC_ARGUMENT: wait must be 0..60 seconds'); }
      commands.push(this.command('', 'wait', Math.floor(seconds * 1000)));
    } else { throw new Error('PHONE_HDC_UNSUPPORTED: gui_action=' + action); }
    return { action: action, commands: commands, inputTarget: inputTarget };
  }

  commit(plan: PhoneHdcActionPlan): void { this.inputTarget = plan.inputTarget; }
}
