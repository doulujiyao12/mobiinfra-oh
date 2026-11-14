import { JSON as ArkJSON } from '@kit.ArkTS';
import { WorkflowJsonMap, WorkflowJsonValue } from './WorkflowTypes';

export interface WorkflowStructuredRecovery {
  output: WorkflowJsonMap;
  fields: string[];
}

interface TailFields {
  values: WorkflowJsonMap;
  keys: string[];
}

function fieldType(schema: WorkflowJsonValue): string {
  if (schema === null || typeof schema !== 'object' || Array.isArray(schema)) {
    return '';
  }
  let type = (schema as WorkflowJsonMap)['type'];
  return typeof type === 'string' ? type.toLowerCase().trim() : '';
}

function normalizedName(name: string): string {
  return name.replace(/[\s_-]/g, '').toLowerCase();
}

function matchingKey(keys: string[], name: string): string {
  let normalized = normalizedName(name);
  let matches = keys.filter((key: string): boolean => normalizedName(key) === normalized);
  return matches.length === 1 ? matches[0] : '';
}

function scalarValue(value: WorkflowJsonValue, type: string): WorkflowJsonValue {
  if (type === 'boolean') {
    if (typeof value === 'boolean') {
      return value;
    }
    if (typeof value === 'string' && /^(true|false)$/i.test(value.trim())) {
      return value.trim().toLowerCase() === 'true';
    }
  }
  if (type === 'number' || type === 'integer') {
    let number = typeof value === 'number' ? value :
      (typeof value === 'string' && /^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$/.test(value.trim()) ? Number(value) : NaN);
    if (Number.isFinite(number) && (type !== 'integer' || Number.isInteger(number))) {
      return number;
    }
  }
  return null;
}

function parseTail(block: string, schema: WorkflowJsonMap): TailFields | null {
  let raw: WorkflowJsonMap = {};
  if (block.startsWith('{') && block.endsWith('}')) {
    try {
      raw = ArkJSON.parse(block) as WorkflowJsonMap;
      let names = block.match(/"(?:\\.|[^"\\])*"\s*:/g);
      if (names === null || names.length !== Object.keys(raw).length) {
        return null;
      }
    } catch (e) {
      return null;
    }
  } else {
    let lines = block.split('\n');
    for (let line of lines) {
      let match = /^\s*(?:"([A-Za-z_][\w-]*)"|'([A-Za-z_][\w-]*)'|([A-Za-z_][\w-]*))\s*[:：]\s*(.*?)\s*[,;；]?\s*$/.exec(line);
      if (match === null) {
        return null;
      }
      let name = match[1] || match[2] || match[3];
      if (Object.keys(raw).indexOf(name) >= 0) {
        return null;
      }
      let value: WorkflowJsonValue = match[4];
      if (typeof value === 'string' && value.startsWith('"') && value.endsWith('"')) {
        try { value = ArkJSON.parse(value) as WorkflowJsonValue; } catch (e) { return null; }
      }
      raw[name] = value;
    }
  }
  let result: TailFields = { values: {}, keys: [] };
  let schemaKeys = Object.keys(schema);
  for (let key of Object.keys(raw)) {
    let target = matchingKey(schemaKeys, key);
    if (target.length === 0 || result.keys.indexOf(target) >= 0) {
      return null;
    }
    let value = scalarValue(raw[key], fieldType(schema[target]));
    if (value === null) {
      return null;
    }
    result.keys.push(target);
    result.values[target] = value;
  }
  return result.keys.length > 0 ? result : null;
}

// Recover only a complete, separate final metadata paragraph with schema-declared
// scalar fields. Never search message sentences, guess values, or replace an existing field.
export function recoverWorkflowStructuredFields(source: WorkflowJsonMap, schema: WorkflowJsonMap): WorkflowStructuredRecovery {
  let unchanged: WorkflowStructuredRecovery = { output: source, fields: [] };
  let schemaKeys = Object.keys(schema);
  let sourceKeys = Object.keys(source);
  let missing = schemaKeys.filter((key: string): boolean =>
    !sourceKeys.some((sourceKey: string): boolean => normalizedName(sourceKey) === normalizedName(key)));
  if (missing.length === 0) {
    return unchanged;
  }
  let candidate: WorkflowStructuredRecovery | null = null;
  for (let key of schemaKeys) {
    let sourceKey = matchingKey(sourceKeys, key);
    let value = source[sourceKey];
    if (sourceKey.length === 0 || fieldType(schema[key]) !== 'string' || typeof value !== 'string') {
      continue;
    }
    let text = value.replace(/\r\n/g, '\n').trimEnd();
    let separator = /\n[ \t]*\n/g;
    let split = -1;
    let start = -1;
    let match: RegExpExecArray | null = separator.exec(text);
    while (match !== null) {
      split = match.index;
      start = match.index + match[0].length;
      match = separator.exec(text);
    }
    if (split < 0 || text.substring(0, split).trim().length === 0) {
      continue;
    }
    let body = text.substring(0, split).trimEnd();
    if (body.split('```').length % 2 === 0 || /[:：]\s*$/.test(body)) {
      continue;
    }
    let tail = parseTail(text.substring(start).trim(), schema);
    if (tail === null || tail.keys.some((field: string): boolean => missing.indexOf(field) < 0)) {
      continue;
    }
    if (candidate !== null) {
      return unchanged;
    }
    let output: WorkflowJsonMap = {};
    for (let sourceField of sourceKeys) {
      output[sourceField] = source[sourceField];
    }
    output[sourceKey] = body;
    for (let field of tail.keys) {
      output[field] = tail.values[field];
    }
    candidate = { output: output, fields: tail.keys };
  }
  return candidate === null ? unchanged : candidate;
}
