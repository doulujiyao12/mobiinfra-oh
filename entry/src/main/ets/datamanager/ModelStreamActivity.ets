import { CloudChatStreamProgress } from '../utils/CloudModelClient';

export interface ModelStreamActivity {
  id: string;
  label: string;
  kind: string;
  attempt: number;
  phase: string;
  startedAt: number;
  elapsedSeconds: number;
  idleSeconds: number;
  receivedBytes: number;
  contentChars: number;
  reasoningChars: number;
  responseCode: number;
  preview: string;
  repeating: boolean;
  buffered: boolean;
  finishReason: string;
}

interface ActivityState {
  value: ModelStreamActivity;
  lastOutputAt: number;
  finishedAt: number;
  tail: string;
  repeatGuard: ModelStreamRepeatGuard;
}

export function isModelStreamActive(phase: string): boolean {
  return phase === 'waiting' || phase === 'receiving' || phase === 'validating';
}

// Ignore punctuation and short schema keys. The memory pipeline shares this
// detection with the activity UI and stops the affected model request.
export function hasRepeatedStreamTail(text: string): boolean {
  let tail = text.slice(-1024).replace(/\s+/g, ' ');
  for (let size = 16; size <= 128 && size * 4 <= tail.length; size++) {
    let unit = tail.slice(-size);
    if (!/[\w\u4e00-\u9fff]{2}/.test(unit)) { continue; }
    if (tail.slice(-size * 4) === unit.repeat(4)) { return true; }
  }
  return false;
}

export class ModelStreamRepeatGuard {
  private contentTail: string = '';
  private reasoningTail: string = '';
  update(progress: CloudChatStreamProgress): boolean {
    if (progress.contentDelta.length > 0) {
      this.contentTail = (this.contentTail + progress.contentDelta).slice(-2048);
      if (hasRepeatedStreamTail(this.contentTail)) { return true; }
    }
    if (progress.reasoningDelta.length > 0) {
      this.reasoningTail = (this.reasoningTail + progress.reasoningDelta).slice(-2048);
      if (hasRepeatedStreamTail(this.reasoningTail)) { return true; }
    }
    return false;
  }
}

export class ModelStreamActivityStore {
  private entries: Map<string, ActivityState> = new Map<string, ActivityState>();
  reset(): void { this.entries.clear(); }
  begin(id: string, kind: string, label: string, attempt: number, now: number = Date.now()): void {
    let value: ModelStreamActivity = { id: id, kind: kind, label: label, attempt: attempt, phase: 'waiting', startedAt: now,
      elapsedSeconds: 0, idleSeconds: 0, receivedBytes: 0, contentChars: 0, reasoningChars: 0, responseCode: -1,
      preview: '', repeating: false, buffered: false, finishReason: '' };
    this.entries.set(id, { value: value, lastOutputAt: 0, finishedAt: -1, tail: '', repeatGuard: new ModelStreamRepeatGuard() });
    for (let key of Array.from(this.entries.keys())) {
      if (this.entries.size <= 64) { break; }
      let old = this.entries.get(key);
      if (old && !isModelStreamActive(old.value.phase)) { this.entries.delete(key); }
    }
  }
  update(id: string, progress: CloudChatStreamProgress, debug: boolean, now: number = Date.now()): boolean {
    let state = this.entries.get(id);
    if (!state || state.finishedAt >= 0) { return false; }
    let value = state.value;
    if (progress.contentChars > value.contentChars || progress.reasoningChars > value.reasoningChars) { state.lastOutputAt = now; }
    value.receivedBytes = progress.receivedBytes; value.contentChars = progress.contentChars;
    value.reasoningChars = progress.reasoningChars; value.responseCode = progress.responseCode;
    value.finishReason = progress.finishReason;
    value.buffered = value.buffered || progress.phase === 'buffered';
    value.phase = progress.phase === 'completed' || progress.phase === 'buffered' ? 'validating' : progress.phase;
    let repeated = state.repeatGuard.update(progress);
    value.repeating = value.repeating || repeated;
    if (debug) {
      let delta = progress.contentDelta || progress.reasoningDelta;
      state.tail = (state.tail + delta).slice(-2048);
      value.preview = state.tail.slice(-400);
    } else { this.clearPreview(state); }
    return repeated;
  }
  finish(id: string, phase: string, now: number = Date.now()): void {
    let state = this.entries.get(id);
    if (!state) { return; }
    state.value.phase = phase; state.finishedAt = now;
  }
  snapshots(since: number = 0, debug: boolean = false, now: number = Date.now()): ModelStreamActivity[] {
    let result: ModelStreamActivity[] = [];
    this.entries.forEach((state: ActivityState) => {
      if (!debug) { this.clearPreview(state); }
      if (state.value.startedAt < since) { return; }
      let end = state.finishedAt >= 0 ? state.finishedAt : now;
      let current = state.value;
      let value: ModelStreamActivity = {
        id: current.id, label: current.label, kind: current.kind, attempt: current.attempt,
        phase: current.phase, startedAt: current.startedAt, receivedBytes: current.receivedBytes,
        contentChars: current.contentChars, reasoningChars: current.reasoningChars,
        responseCode: current.responseCode, preview: current.preview, repeating: current.repeating,
        buffered: current.buffered, finishReason: current.finishReason,
        elapsedSeconds: Math.max(0, Math.floor((end - state.value.startedAt) / 1000)),
        idleSeconds: Math.max(0, Math.floor((end - (state.lastOutputAt || state.value.startedAt)) / 1000)) };
      result.push(value);
    });
    return result.sort((left: ModelStreamActivity, right: ModelStreamActivity): number => {
      let active = Number(isModelStreamActive(right.phase)) - Number(isModelStreamActive(left.phase));
      return active || right.startedAt - left.startedAt || right.id.localeCompare(left.id);
    });
  }
  private clearPreview(state: ActivityState): void { state.tail = ''; state.value.preview = ''; }
}

export function modelStreamActivityText(value: ModelStreamActivity): string {
  let count = '正文 ' + value.contentChars + ' 字' + (value.reasoningChars > 0 ? ' · 思考 ' + value.reasoningChars + ' 字' : '');
  if (value.phase === 'succeeded') { return '已完成 · ' + count + ' · ' + value.elapsedSeconds + ' 秒'; }
  if (value.phase === 'invalid') { return '回复校验失败 · ' + count; }
  if (value.phase === 'repeated') { return '重复输出已中断 · ' + count + ' · ' + value.elapsedSeconds + ' 秒'; }
  if (value.phase === 'failed') { return '请求失败 · ' + count + ' · ' + value.elapsedSeconds + ' 秒'; }
  if (value.phase === 'validating') { return '已返回，正在校验 JSON · ' + count; }
  if (value.contentChars + value.reasoningChars === 0) {
    return value.receivedBytes > 0 ? '已收到 ' + value.receivedBytes + ' 字节，等待模型正文 · ' + value.elapsedSeconds + ' 秒' :
      '等待首包 · ' + value.elapsedSeconds + ' 秒';
  }
  return count + ' · ' + (value.idleSeconds >= 20 ? '已 ' + value.idleSeconds + ' 秒无新输出' : '最近输出 ' + value.idleSeconds + ' 秒前');
}
