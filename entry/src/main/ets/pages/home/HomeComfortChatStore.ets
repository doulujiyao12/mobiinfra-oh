import { HomeComfortChatMessage, HomeComfortConcern } from './HomeEmotionalSupport';

export interface HomeComfortChatSession {
  id: number;
  concernId: string;
  messages: HomeComfortChatMessage[];
  sending: boolean;
  error: string;
}

// Owned by Index, with the same lifetime as the current concern batch, rather than the chat cover.
@Observed
export class HomeComfortChatStore {
  sessions: HomeComfortChatSession[] = [];
  private sessionSequence: number = 0;
  private messageSequence: number = 0;

  get(concernId: string): HomeComfortChatSession | undefined {
    return this.sessions.find((session: HomeComfortChatSession): boolean => session.concernId === concernId);
  }

  open(concern: HomeComfortConcern): HomeComfortChatSession {
    return this.get(concern.id) || this.restart(concern);
  }

  restart(concern: HomeComfortConcern): HomeComfortChatSession {
    this.sessionSequence++;
    let session: HomeComfortChatSession = {
      id: this.sessionSequence,
      concernId: concern.id,
      messages: [this.message('assistant', concern.opening)],
      sending: false,
      error: ''
    };
    this.replace(session);
    return session;
  }

  clear(): void {
    // Keep the generation counter: a late response must not match a new casual-chat session after refresh.
    this.sessions = [];
  }

  async send(concern: HomeComfortConcern, text: string,
    request: (concern: HomeComfortConcern, history: HomeComfortChatMessage[]) => Promise<string>): Promise<void> {
    let content = text.trim();
    let session = this.get(concern.id);
    if (!session || session.sending || content.length === 0) {
      return;
    }
    let pending: HomeComfortChatSession = {
      id: session.id,
      concernId: session.concernId,
      messages: session.messages.concat([this.message('user', content)]),
      sending: true,
      error: ''
    };
    this.replace(pending);
    try {
      let reply = await request(concern, pending.messages.slice());
      if (!this.isPending(pending)) {
        return;
      }
      this.replace({
        id: pending.id,
        concernId: pending.concernId,
        messages: pending.messages.concat([this.message('assistant', reply)]),
        sending: false,
        error: ''
      });
    } catch (e) {
      if (!this.isPending(pending)) {
        return;
      }
      let error = e as Error;
      this.replace({
        id: pending.id,
        concernId: pending.concernId,
        messages: pending.messages,
        sending: false,
        error: error.message.length > 0 ? error.message : '回复生成失败，请稍后再试'
      });
    }
  }

  private isPending(session: HomeComfortChatSession): boolean {
    let current = this.get(session.concernId);
    return current !== undefined && current.id === session.id && current.sending;
  }

  private replace(session: HomeComfortChatSession): void {
    this.sessions = this.sessions.filter((item: HomeComfortChatSession): boolean =>
      item.concernId !== session.concernId).concat([session]);
  }

  private message(role: 'user' | 'assistant', content: string): HomeComfortChatMessage {
    this.messageSequence++;
    let now = Date.now();
    return {
      id: 'comfort-message-' + String(now) + '-' + String(this.messageSequence),
      role: role,
      content: content,
      createdAt: now
    };
  }
}
