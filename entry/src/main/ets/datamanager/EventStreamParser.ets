import { JSON as ArkJSON } from '@kit.ArkTS';
import { JsonMap } from './DataManagerTypes';

// Extract only fully closed objects in the root JSON object's events array.
// Strings, escapes and nested objects may span arbitrary SSE chunks. Draft
// reasoning or prose prefixes are never treated as completed event results.
export class EventStreamParser {
  private buffer: string = '';
  private cursor: number = -1;
  private depth: number = 0;
  private quoted: boolean = false;
  private escaped: boolean = false;
  private keyStart: number = -1;
  private expectKey: boolean = false;
  private eventsKey: boolean = false;
  private eventsArray: boolean = false;
  private itemStart: number = -1;
  private stopped: boolean = false;
  append(delta: string): JsonMap[] {
    let result: JsonMap[] = [];
    if (this.stopped || delta.length === 0) { return result; }
    if (this.buffer.length + delta.length > 256000) { this.stopped = true; this.buffer = ''; return result; }
    this.buffer += delta;
    if (this.cursor < 0) {
      let start = this.buffer.search(/\S/);
      if (start < 0) { return result; }
      if (this.buffer[start] === '`') {
        let newline = this.buffer.indexOf('\n', start);
        if (newline < 0) { return result; }
        let fence = this.buffer.substring(start, newline).trim().toLowerCase();
        if (fence !== '```json' && fence !== '```') { this.stopped = true; return result; }
        start = newline + 1;
        while (start < this.buffer.length && /\s/.test(this.buffer[start])) { start++; }
        if (start === this.buffer.length) { return result; }
      }
      if (this.buffer[start] !== '{') { this.stopped = true; return result; }
      this.cursor = start;
    }
    for (; this.cursor < this.buffer.length; this.cursor++) {
      let ch = this.buffer[this.cursor];
      if (this.quoted) {
        if (this.escaped) { this.escaped = false; continue; }
        if (ch === '\\') { this.escaped = true; continue; }
        if (ch === '"') {
          this.quoted = false;
          if (this.keyStart >= 0) {
            try { this.eventsKey = ArkJSON.parse(this.buffer.substring(this.keyStart, this.cursor + 1)) === 'events'; }
            catch (e) { this.eventsKey = false; }
            this.keyStart = -1; this.expectKey = false;
          }
        }
        continue;
      }
      if (ch === '"') {
        this.quoted = true;
        if (this.depth === 1 && this.expectKey) { this.keyStart = this.cursor; }
        continue;
      }
      if (ch === '{' || ch === '[') {
        if (ch === '[' && this.depth === 1 && this.eventsKey) { this.eventsArray = true; this.eventsKey = false; }
        if (ch === '{' && this.eventsArray && this.depth === 2) { this.itemStart = this.cursor; }
        this.depth++;
        if (this.depth === 1) { this.expectKey = true; }
      } else if (ch === '}' || ch === ']') {
        this.depth--;
        if (ch === '}' && this.eventsArray && this.depth === 2 && this.itemStart >= 0) {
          try { result.push(ArkJSON.parse(this.buffer.substring(this.itemStart, this.cursor + 1)) as JsonMap); } catch (e) {}
          this.itemStart = -1;
        }
        if (this.eventsArray && this.depth < 2) { this.stopped = true; break; }
        if (this.depth <= 0) { this.stopped = true; break; }
      } else if (ch === ',' && this.depth === 1) { this.expectKey = true; this.eventsKey = false; }
    }
    return result;
  }
}
