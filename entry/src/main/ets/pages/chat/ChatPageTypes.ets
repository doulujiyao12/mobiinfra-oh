export const CHAT_MODE_CLOUD_AGENT: string = 'cloud_agent';
export const CHAT_MODE_LOCAL_INFERENCE: string = 'local_inference';
export const CLOUD_AGENT_DEFAULT_OUTPUT: string = '请先配置 Planner 和 Decider 云端服务';
export const CHAT_COMPOSER_MIN_HEIGHT: number = 58;
export const CHAT_COMPOSER_LINE_HEIGHT: number = 22;
export const CHAT_COMPOSER_MAX_LINES: number = 4;
export const CHAT_COMPOSER_CHARS_PER_LINE: number = 10;

export function isSupportedChatMode(mode: string): boolean {
  return mode === CHAT_MODE_CLOUD_AGENT || mode === CHAT_MODE_LOCAL_INFERENCE;
}

export function chatModeLabel(mode: string): string {
  if (mode === CHAT_MODE_LOCAL_INFERENCE) {
    return '本地推理';
  }
  return '云端智能体';
}

export function chatModePlaceholder(mode: string): string {
  if (mode === CHAT_MODE_LOCAL_INFERENCE) {
    return '输入本地模型消息...';
  }
  return '发消息或输入任务...';
}

export function chatModeActionLabel(mode: string): string {
  if (mode === CHAT_MODE_LOCAL_INFERENCE) {
    return '发送';
  }
  return '发送';
}

export function chatDeepThinkingToggleVisible(mode: string): boolean {
  return mode !== CHAT_MODE_LOCAL_INFERENCE;
}

export function chatInputAfterAcceptedSend(currentInput: string, accepted: boolean): string {
  return accepted ? '' : currentInput;
}

// 原生请求已经结束、但 Promise 完成回调尚未清理 UI 时，允许主动释放陈旧的忙碌状态。
// nativeRequestSubmitted 可防止模型加载阶段因尚未创建原生请求而被误判为已完成。
export function chatLocalInferenceStateIsStale(uiRunning: boolean, nativeRequestSubmitted: boolean,
  nativeRunning: boolean): boolean {
  return uiRunning && nativeRequestSubmitted && !nativeRunning;
}

export type ChatComposerPrimaryActionRole = 'send' | 'busy' | 'voice_capture';

// 输入栏只有一个主操作按钮：短按发送，长按语音；语音采集中优先展示麦克风状态。
export function chatComposerPrimaryActionRole(isBusy: boolean, voiceCapturing: boolean): ChatComposerPrimaryActionRole {
  if (voiceCapturing) {
    return 'voice_capture';
  }
  return isBusy ? 'busy' : 'send';
}

export function chatComposerVoiceReleaseShouldStop(voiceStatus: string): boolean {
  return voiceStatus === 'idle' || voiceStatus === 'listening' || voiceStatus === 'transcribing';
}

export function chatVoiceStatusIsCapturing(voiceStatus: string): boolean {
  return voiceStatus === 'listening';
}

// 播放态已由头像动效和气泡按钮表达，输入栏上方只保留录音、转写、合成等过程提示。
export function chatVoiceStatusBarVisible(voiceStatus: string, _transcript: string = ''): boolean {
  return voiceStatus !== 'idle' && voiceStatus !== 'speaking';
}

// ASR 结果已经实时写入可编辑输入框，状态栏只承担状态提示，不再重复展示转写文本。
export function chatVoiceStatusDetailText(_voiceStatus: string, _transcript: string): string {
  return '';
}

export function chatTimeGreeting(hour: number): string {
  if (hour >= 6 && hour < 11) {
    return '早上好';
  }
  if (hour >= 11 && hour < 14) {
    return '中午好';
  }
  if (hour >= 14 && hour < 18) {
    return '下午好';
  }
  if (hour >= 18 && hour < 24) {
    return '晚上好';
  }
  return '夜深了';
}

function chatComposerSegmentLineCount(segment: string, charsPerLine: number): number {
  if (segment.length <= 0) {
    return 1;
  }
  return Math.ceil(segment.length / charsPerLine);
}

// 聊天输入栏高度由草稿内容派生：短文本保持单行，长文本/换行扩展到最多 4 行，避免遮挡页面主体。
export function chatComposerLineCount(text: string, charsPerLine: number = CHAT_COMPOSER_CHARS_PER_LINE,
  maxLines: number = CHAT_COMPOSER_MAX_LINES): number {
  let normalizedCharsPerLine = Math.max(1, charsPerLine);
  let normalizedMaxLines = Math.max(1, maxLines);
  let lines = 0;
  let segmentStart = 0;
  for (let i = 0; i <= text.length; i++) {
    if (i === text.length || text.charAt(i) === '\n') {
      let segment = text.substring(segmentStart, i);
      lines += chatComposerSegmentLineCount(segment, normalizedCharsPerLine);
      segmentStart = i + 1;
    }
  }
  return Math.min(lines, normalizedMaxLines);
}

export function chatComposerBarHeight(text: string): number {
  return CHAT_COMPOSER_MIN_HEIGHT + (chatComposerLineCount(text) - 1) * CHAT_COMPOSER_LINE_HEIGHT;
}

export function chatComposerTextAreaHeight(text: string): number {
  return chatComposerBarHeight(text) - 12;
}

export function chatModeSwitcherVisibleAfterScroll(currentVisible: boolean, yOffset: number,
  threshold: number = 4): boolean {
  if (yOffset > threshold) {
    return false;
  }
  if (yOffset < -threshold) {
    return true;
  }
  return currentVisible;
}

export function hasCloudAgentDisplayOutput(output: string): boolean {
  let text = output.trim();
  return text.length > 0 && text !== CLOUD_AGENT_DEFAULT_OUTPUT && text !== '云端智能体准备就绪';
}

export function cloudAgentDisplayText(output: string): string {
  let text = output.trim();
  if (!hasCloudAgentDisplayOutput(text)) {
    return '';
  }
  let markers: string[] = [
    'Planner 手动返回：\n',
    'Planner 测试返回：\n'
  ];
  for (let i = 0; i < markers.length; i++) {
    let marker = markers[i];
    let idx = text.lastIndexOf(marker);
    if (idx >= 0) {
      return text.substring(idx + marker.length).trim();
    }
  }
  return text;
}
