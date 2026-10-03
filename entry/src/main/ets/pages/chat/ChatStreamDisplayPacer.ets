export const CHAT_STREAM_DISPLAY_TICK_MS: number = 45;
export const CHAT_STREAM_DISPLAY_MIN_CHARS_PER_TICK: number = 2;
export const CHAT_STREAM_DISPLAY_MAX_CHARS_PER_TICK: number = 16;
export const CHAT_STREAM_DISPLAY_FINISH_MAX_TICKS: number = 8;

export interface ChatStreamDisplaySnapshot {
  sessionId: string;
  messageId: string;
  targetContentLength: number;
  visibleContent: string;
  visibleTrace: string[];
  active: boolean;
  complete: boolean;
}

export function createEmptyChatStreamDisplaySnapshot(): ChatStreamDisplaySnapshot {
  return {
    sessionId: '',
    messageId: '',
    targetContentLength: 0,
    visibleContent: '',
    visibleTrace: [],
    active: false,
    complete: true
  };
}

// 将模型返回的不均匀 chunk 转换成稳定的 UI 展示节奏。
// 该类只维护内存态，不负责持久化，避免打字动画 tick 触发高频会话文件写入。
export class ChatStreamDisplayPacer {
  private sessionId: string = '';
  private messageId: string = '';
  private targetContent: string = '';
  private visibleContent: string = '';
  private visibleTrace: string[] = [];
  private active: boolean = false;
  private finishing: boolean = false;
  private finishTicksRemaining: number = CHAT_STREAM_DISPLAY_FINISH_MAX_TICKS;

  setTarget(sessionId: string, messageId: string, targetContent: string, trace: string[]): ChatStreamDisplaySnapshot {
    if (this.sessionId !== sessionId || this.messageId !== messageId) {
      this.sessionId = sessionId;
      this.messageId = messageId;
      this.visibleContent = '';
      this.finishing = false;
      this.finishTicksRemaining = CHAT_STREAM_DISPLAY_FINISH_MAX_TICKS;
    }
    this.targetContent = targetContent;
    this.visibleTrace = trace.slice();
    if (this.targetContent.indexOf(this.visibleContent) !== 0) {
      this.visibleContent = this.commonPrefix(this.visibleContent, this.targetContent);
    }
    this.active = this.visibleContent.length < this.targetContent.length;
    return this.snapshot();
  }

  beginFinish(sessionId: string, messageId: string, targetContent: string, trace: string[]): ChatStreamDisplaySnapshot {
    this.setTarget(sessionId, messageId, targetContent, trace);
    this.finishing = true;
    this.finishTicksRemaining = CHAT_STREAM_DISPLAY_FINISH_MAX_TICKS;
    this.active = this.visibleContent.length < this.targetContent.length;
    return this.snapshot();
  }

  advanceFrame(): ChatStreamDisplaySnapshot {
    let backlog = this.targetContent.length - this.visibleContent.length;
    if (backlog <= 0) {
      this.active = false;
      this.finishing = false;
      return this.snapshot();
    }

    let step = this.nextStepLength(backlog);
    let nextLength = Math.min(this.targetContent.length, this.visibleContent.length + step);
    this.visibleContent = this.targetContent.substring(0, nextLength);
    if (this.finishing && this.finishTicksRemaining > 0) {
      this.finishTicksRemaining -= 1;
    }
    this.active = this.visibleContent.length < this.targetContent.length;
    if (!this.active) {
      this.finishing = false;
    }
    return this.snapshot();
  }

  shouldScheduleFrame(): boolean {
    return this.active && this.visibleContent.length < this.targetContent.length;
  }

  reset(): ChatStreamDisplaySnapshot {
    this.sessionId = '';
    this.messageId = '';
    this.targetContent = '';
    this.visibleContent = '';
    this.visibleTrace = [];
    this.active = false;
    this.finishing = false;
    this.finishTicksRemaining = CHAT_STREAM_DISPLAY_FINISH_MAX_TICKS;
    return this.snapshot();
  }

  snapshot(): ChatStreamDisplaySnapshot {
    return {
      sessionId: this.sessionId,
      messageId: this.messageId,
      targetContentLength: this.targetContent.length,
      visibleContent: this.visibleContent,
      visibleTrace: this.visibleTrace.slice(),
      active: this.active,
      complete: this.visibleContent.length >= this.targetContent.length
    };
  }

  private nextStepLength(backlog: number): number {
    if (this.finishing) {
      let remainingTicks = Math.max(1, this.finishTicksRemaining);
      return Math.max(CHAT_STREAM_DISPLAY_MAX_CHARS_PER_TICK, Math.ceil(backlog / remainingTicks));
    }
    if (backlog >= 64) {
      return CHAT_STREAM_DISPLAY_MAX_CHARS_PER_TICK;
    }
    if (backlog >= 32) {
      return 10;
    }
    if (backlog >= 12) {
      return 6;
    }
    return Math.min(backlog, CHAT_STREAM_DISPLAY_MIN_CHARS_PER_TICK);
  }

  private commonPrefix(left: string, right: string): string {
    let limit = Math.min(left.length, right.length);
    let length = 0;
    while (length < limit && left.charAt(length) === right.charAt(length)) {
      length += 1;
    }
    return left.substring(0, length);
  }
}
