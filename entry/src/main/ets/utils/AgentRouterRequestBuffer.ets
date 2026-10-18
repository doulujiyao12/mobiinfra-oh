import { decodeUtf8Compat } from './TextEncodingCompat';

const MAX_ROUTER_MESSAGE_BYTES: number = 32 * 1024 * 1024;
const ROUTER_DELIMITER: number[] = [60, 60, 69, 79, 70, 62, 62]; // <<EOF>>

// TCP callbacks contain arbitrary byte fragments, not whole UTF-8 strings or JSON messages.
export class AgentRouterRequestBuffer {
  private pending: Uint8Array = new Uint8Array(0);

  feed(bytes: Uint8Array): string[] {
    if (this.pending.length + bytes.length > MAX_ROUTER_MESSAGE_BYTES) {
      throw new Error('Agent router request exceeds 32 MiB');
    }
    let data = new Uint8Array(this.pending.length + bytes.length);
    data.set(this.pending); data.set(bytes, this.pending.length);
    let messages: string[] = [];
    let start = 0;
    for (let i = 0; i <= data.length - ROUTER_DELIMITER.length; i++) {
      let delimiter = true;
      for (let j = 0; j < ROUTER_DELIMITER.length; j++) {
        if (data[i + j] !== ROUTER_DELIMITER[j]) { delimiter = false; break; }
      }
      if (!delimiter) { continue; }
      if (messages.length >= 64) { throw new Error('Too many queued agent router requests'); }
      messages.push(decodeUtf8Compat(data.slice(start, i)));
      i += ROUTER_DELIMITER.length - 1;
      start = i + 1;
    }
    this.pending = data.slice(start);
    return messages;
  }
}
