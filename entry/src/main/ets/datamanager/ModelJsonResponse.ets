import { JSON as ArkJSON } from '@kit.ArkTS';
import { JsonMap } from './DataManagerTypes';

// Repair syntax only. Never invent values, close truncated structures, evaluate
// code or merge multiple answers. The caller still validates the domain schema.
export interface ModelJsonParseOptions { repairMissingCommas?: boolean; }
export function parseModelJsonObject(raw: string, options: ModelJsonParseOptions = {}): JsonMap {
  let text = raw.trim().replace(/^\uFEFF/, '').replace(/^(?:<think>[\s\S]*?<\/think>\s*)+/i, '');
  let fence = /^```(?:json)?\s*\n?([\s\S]*?)\s*```\s*$/i.exec(text);
  if (fence) { text = fence[1].trim(); }
  try { return objectRoot(text); } catch (e) {}
  let start = text.indexOf('{');
  if (start < 0 || text.startsWith('[')) { throw new Error('模型结果不是 JSON 对象'); }
  let repaired = repairTokens(text.substring(start), options.repairMissingCommas === true);
  return objectRoot(repaired);
}

function objectRoot(text: string): JsonMap {
  let value = ArkJSON.parse(text) as JsonMap;
  if (!value || typeof value !== 'object' || Array.isArray(value)) { throw new Error('JSON root is not object'); }
  return value;
}

interface JsonStringToken { text: string; end: number; }

function quotedToken(text: string, start: number): JsonStringToken {
  let opening = text[start];
  let closing = opening === '“' ? '”' : opening === '‘' ? '’' : opening;
  let output = '"';
  for (let i = start + 1; i < text.length; i++) {
    let ch = text[i];
    if (ch === closing) { return { text: output + '"', end: i + 1 }; }
    if (ch === '\\') {
      if (++i >= text.length) { break; }
      let next = text[i];
      if (next === "'" && opening !== '"') { output += "'"; }
      else if ('"\\/bfnrtu'.indexOf(next) >= 0) { output += '\\' + next; }
      else { output += '\\\\' + next; }
    } else if (ch === '"') { output += '\\"'; }
    else if (ch.charCodeAt(0) < 32) { output += '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'); }
    else { output += ch; }
  }
  throw new Error('模型 JSON 字符串未结束，保留已完成事件后重试');
}

function repairTokens(text: string, missingCommas: boolean): string {
  let tokens: string[] = [];
  let stack: string[] = [];
  let end = -1;
  for (let i = 0; i < text.length;) {
    let ch = text[i];
    if (/\s/.test(ch)) { i++; continue; }
    if (ch === '/' && text[i + 1] === '/') {
      let newline = text.indexOf('\n', i + 2); i = newline < 0 ? text.length : newline + 1; continue;
    }
    if (ch === '/' && text[i + 1] === '*') {
      let close = text.indexOf('*/', i + 2);
      if (close < 0) { throw new Error('模型 JSON 注释未结束'); }
      i = close + 2; continue;
    }
    if (ch === '"' || ch === "'" || ch === '“' || ch === '‘') {
      let token = quotedToken(text, i); tokens.push(token.text); i = token.end; continue;
    }
    ch = ch === '：' ? ':' : ch === '，' ? ',' : ch;
    if ('{}[]:,'.indexOf(ch) >= 0) {
      if (ch === '{' || ch === '[') {
        stack.push(ch);
        if (stack.length > 64) { throw new Error('模型 JSON 嵌套过深'); }
      } else if (ch === '}' || ch === ']') {
        if (stack.pop() !== (ch === '}' ? '{' : '[')) { throw new Error('模型 JSON 括号不匹配'); }
        if (tokens[tokens.length - 1] === ',') { tokens.pop(); }
      }
      tokens.push(ch); i++;
      if (stack.length === 0) { end = i; break; }
      continue;
    }
    let atom = /^[A-Za-z_$][A-Za-z0-9_$-]*|^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(text.substring(i));
    if (!atom) { throw new Error('模型 JSON 含无法安全修复的字符'); }
    let value = atom[0];
    let rest = text.substring(i + value.length).trimStart();
    let previous = tokens[tokens.length - 1];
    if ((previous === '{' || previous === ',') && (rest.startsWith(':') || rest.startsWith('：')) &&
      /^[A-Za-z_$]/.test(value)) { value = '"' + value + '"'; }
    else if (value === 'True' || value === 'False' || value === 'None') {
      value = value === 'True' ? 'true' : value === 'False' ? 'false' : 'null';
    }
    tokens.push(value); i += atom[0].length;
  }
  if (end < 0 || stack.length > 0) { throw new Error('模型 JSON 被截断，保留已完成事件后重试'); }
  // A prose/fence suffix is harmless; a second structured answer is ambiguous.
  if (/[\[\]{}]/.test(text.substring(end))) { throw new Error('模型返回了多个 JSON 结构'); }
  if (!missingCommas) { return tokens.join(' '); }
  // Adjacent complete values (or a value followed by an object key) require a
  // comma. Never alter string contents, insert values/colons, or close a prefix.
  let separated: string[] = [];
  for (let token of tokens) {
    let previous = separated[separated.length - 1] || '';
    let endsValue = previous.startsWith('"') || previous === ']' || previous === '}' ||
      /^(?:true|false|null|-?\d)/.test(previous);
    let beginsValue = token.startsWith('"') || token === '[' || token === '{' ||
      /^(?:true|false|null|-?\d)/.test(token);
    if (endsValue && beginsValue) { separated.push(','); }
    separated.push(token);
  }
  return separated.join(' ');
}
