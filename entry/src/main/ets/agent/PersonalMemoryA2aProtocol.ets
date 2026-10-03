import { parseJsonCompat, stringifyJsonCompat } from '../utils/JsonCompat';
import { PersonalMemoryAnswer } from './PersonalMemoryQuery';

interface TextPart {
  kind?: string;
  type?: string;
  text?: string;
  mediaType?: string;
}

interface IncomingMessage {
  messageId?: string;
  contextId?: string | null;
  taskId?: string;
  role?: string | number;
  parts?: TextPart[];
}

interface IncomingTask {
  taskId?: string;
  query?: string;
  skillId?: string;
}

interface IncomingParams {
  task?: IncomingTask;
  message?: IncomingMessage;
  metadata?: IncomingMetadata;
  id?: string;
  taskId?: string;
}

interface IncomingMetadata {
  traceId?: string;
  agentId?: string;
}

interface IncomingRequest {
  jsonrpc?: string;
  id?: string | number;
  method?: string;
  params?: IncomingParams;
  message?: IncomingMessage;
  messageId?: string;
  contextId?: string | null;
  role?: string | number;
  parts?: TextPart[];
}

export interface PersonalMemoryA2aRequest {
  method: string;
  id?: string | number;
  taskId: string;
  question: string;
  contextId?: string;
  numericRole?: boolean;
  traceId?: string;
  agentId?: string;
}

interface NativeMessageTextPart {
  text: string;
  mediaType: string;
}

interface NativeMessageReply {
  messageId: string;
  contextId: string;
  role: number;
  parts: NativeMessageTextPart[];
}

interface OutgoingMessageTextPart {
  kind: string;
  text: string;
}

interface OutgoingTaskTextPart {
  type: string;
  text: string;
}

interface OutgoingMessageResult {
  role: string;
  messageId: string;
  parts: OutgoingMessageTextPart[];
}

interface V1MessageResult {
  message: V1AgentMessage;
}

interface V1AgentMessage {
  messageId: string;
  contextId: string;
  role: string;
  parts: NativeMessageTextPart[];
}

interface V1TaskStatus {
  state: string;
  timestamp?: string;
}

interface V1Artifact {
  artifactId: string;
  parts: NativeMessageTextPart[];
}

interface V1Task {
  id: string;
  contextId: string;
  status: V1TaskStatus;
  artifacts?: V1Artifact[];
}

interface V1ResponseMetadata {
  traceId?: string;
  agentId: string;
  agentVersion: string;
}

interface V1TaskResult {
  task: V1Task;
  metadata?: V1ResponseMetadata;
}

interface V1TaskStatusUpdateEvent {
  taskId: string;
  contextId: string;
  status: V1TaskStatus;
}

interface V1StatusUpdateResult {
  statusUpdate: V1TaskStatusUpdateEvent;
  metadata: V1ResponseMetadata;
}

interface V1TaskArtifactUpdateEvent {
  taskId: string;
  contextId: string;
  artifact: V1Artifact;
  append: boolean;
  lastChunk: boolean;
}

interface V1ArtifactUpdateResult {
  artifactUpdate: V1TaskArtifactUpdateEvent;
  metadata: V1ResponseMetadata;
}

interface OutgoingTaskResult {
  contextId: string;
  taskId: string;
  artifactId: string;
  parts: OutgoingTaskTextPart[];
  state: string;
}

interface MessageReply {
  jsonrpc: string;
  id: string | number | null;
  result: OutgoingMessageResult | NativeMessageReply | V1MessageResult | V1TaskResult |
    V1StatusUpdateResult | V1ArtifactUpdateResult;
}

interface JsonRpcTaskReply {
  jsonrpc: string;
  id: string | number;
  method: string;
  result: OutgoingTaskResult;
}

interface TaskReply {
  method: string;
  result: OutgoingTaskResult;
}

interface ReplyError {
  code: number;
  message: string;
}

interface ErrorReply {
  method: string;
  error: ReplyError;
}

interface JsonRpcErrorReply {
  jsonrpc: string;
  id: string | number | null;
  error: ReplyError;
}

function incomingMessageQuestion(message: IncomingMessage): string {
  if (message.role !== undefined && message.role !== 1 && message.role !== 'user' &&
    message.role !== 'ROLE_USER') {
    throw new Error('仅接受用户问题');
  }
  let parts: TextPart[] = message.parts || [];
  for (let part of parts) {
    if (typeof part.text === 'string' && (part.kind === undefined || part.kind === 'text') &&
      (part.type === undefined || part.type === 'text') &&
      (part.mediaType === undefined || part.mediaType === '' || part.mediaType.startsWith('text/'))) {
      return part.text;
    }
  }
  return '';
}

function validateQuestion(question: string): string {
  let trimmed = question.trim();
  if (trimmed.length === 0 || trimmed.length > 200) {
    throw new Error('问题不能为空且不能超过 200 字');
  }
  return trimmed;
}

export function parsePersonalMemoryA2aRequest(data: string): PersonalMemoryA2aRequest {
  if (data.length === 0 || data.length > 8192) {
    throw new Error('请求长度无效');
  }
  let request = parseJsonCompat<IncomingRequest>(data);
  if (!request || typeof request !== 'object' || Array.isArray(request)) {
    throw new Error('请求必须是 JSON 对象');
  }
  if (request.jsonrpc !== undefined && request.jsonrpc !== '2.0') {
    throw new Error('不支持的协议版本');
  }
  if (request.id !== undefined && typeof request.id !== 'string' && typeof request.id !== 'number') {
    throw new Error('请求编号无效');
  }
  if (request.method === undefined && (request.parts !== undefined || request.message !== undefined)) {
    let message: IncomingMessage;
    if (request.message !== undefined) {
      message = request.message;
    } else {
      message = {
        messageId: request.messageId,
        contextId: request.contextId,
        role: request.role,
        parts: request.parts
      };
    }
    let question = validateQuestion(incomingMessageQuestion(message));
    let contextId = typeof message.contextId === 'string' ? message.contextId : '';
    return { method: 'native-message', taskId: '', question: question, contextId: contextId,
      numericRole: message.role === 1 };
  }
  if (request.method !== 'tasks/send' && request.method !== 'tasks/sendSubscribe' &&
    request.method !== 'message/send' && request.method !== 'message/stream' &&
    request.method !== 'SendMessage' && request.method !== 'SendStreamingMessage' &&
    request.method !== 'MessageStream') {
    throw new Error('仅支持只读记忆查询');
  }
  let params = request.params;
  if (!params || typeof params !== 'object' || Array.isArray(params)) {
    throw new Error('缺少请求参数');
  }
  let question = '';
  let taskId = '';
  if (request.method === 'tasks/send' || request.method === 'tasks/sendSubscribe') {
    let task = params.task;
    if (task?.skillId !== undefined && task.skillId !== 'read_personal_memory') {
      throw new Error('不支持的技能');
    }
    if (params.message !== undefined) {
      question = incomingMessageQuestion(params.message);
      taskId = typeof params.taskId === 'string' ? params.taskId :
        (typeof params.id === 'string' ? params.id : '');
    } else if (task && typeof task.query === 'string') {
      question = task.query;
      taskId = typeof task.taskId === 'string' ? task.taskId : '';
    }
  } else {
    if (params.message !== undefined) {
      question = incomingMessageQuestion(params.message);
      taskId = typeof params.message.taskId === 'string' ? params.message.taskId : '';
    }
  }
  question = validateQuestion(question);
  if (taskId.length > 128) {
    throw new Error('任务编号过长');
  }
  let contextId = params.message !== undefined && typeof params.message.contextId === 'string' ?
    params.message.contextId : '';
  let traceId = params.metadata !== undefined && typeof params.metadata.traceId === 'string' &&
    params.metadata.traceId.length <= 128 ? params.metadata.traceId : undefined;
  let agentId = params.metadata !== undefined && typeof params.metadata.agentId === 'string' &&
    params.metadata.agentId.length > 0 && params.metadata.agentId.length <= 128 ?
    params.metadata.agentId : undefined;
  return { method: request.method, id: request.id, taskId: taskId, question: question,
    contextId: contextId, numericRole: params.message?.role === 1,
    traceId: traceId, agentId: agentId };
}

// Log only the envelope structure. Questions, parts, IDs, and metadata can contain private data.
export function personalMemoryA2aInputShape(data: string): string {
  if (data.length > 8192) {
    return 'too-long';
  }
  let request: IncomingRequest;
  try {
    request = parseJsonCompat<IncomingRequest>(data);
  } catch (e) {
    return 'not-json';
  }
  if (request === null || typeof request !== 'object' || Array.isArray(request)) {
    return 'json-nonobject';
  }
  // A protocol method is an ASCII identifier. Do not log arbitrary field contents.
  let method = 'other';
  if (request.method === undefined) {
    method = 'absent';
  } else if (request.method.length <= 64 && /^[A-Za-z][A-Za-z0-9/_-]*$/.test(request.method)) {
    method = request.method;
  }
  let params = request.params;
  return 'json-object method=' + method +
    ' rootParts=' + String(Array.isArray(request.parts)) +
    ' rootMessage=' + String(request.message !== undefined) +
    ' params=' + String(params !== undefined) +
    ' paramsMessage=' + String(params?.message !== undefined) +
    ' paramsTask=' + String(params?.task !== undefined);
}

function nativeMessageReply(request: PersonalMemoryA2aRequest, text: string, stamp: string): NativeMessageReply {
  let part: NativeMessageTextPart = { text: text, mediaType: 'text/plain' };
  let parts: NativeMessageTextPart[] = [part];
  return {
    messageId: 'memory_' + stamp,
    contextId: request.contextId !== undefined && request.contextId.length > 0 ?
      request.contextId : 'memory_' + stamp,
    role: 0,
    parts: parts
  };
}

function v1MessageReply(request: PersonalMemoryA2aRequest, text: string, stamp: string): V1AgentMessage {
  let message = nativeMessageReply(request, text, stamp);
  return {
    messageId: message.messageId,
    contextId: message.contextId,
    role: 'ROLE_AGENT',
    parts: message.parts
  };
}

function v1TaskId(request: PersonalMemoryA2aRequest, stamp: string): string {
  return request.taskId.length > 0 ? request.taskId : 'memory_task_' + stamp;
}

function v1ContextId(request: PersonalMemoryA2aRequest, stamp: string): string {
  return request.contextId !== undefined && request.contextId.length > 0 ?
    request.contextId : 'memory_context_' + stamp;
}

function v1ResponseMetadata(request: PersonalMemoryA2aRequest): V1ResponseMetadata {
  return {
    traceId: request.traceId,
    agentId: request.agentId !== undefined ? request.agentId : 'clawmate_personal_memory',
    agentVersion: '1.0.0'
  };
}

function v1TaskReply(request: PersonalMemoryA2aRequest, text: string, stamp: string,
  state: string): V1TaskResult {
  let part: NativeMessageTextPart = { text: text, mediaType: 'text/plain' };
  let parts: NativeMessageTextPart[] = [part];
  let artifact: V1Artifact = { artifactId: 'memory_artifact_' + stamp, parts: parts };
  let artifacts: V1Artifact[] = [artifact];
  let status: V1TaskStatus = { state: state, timestamp: new Date().toISOString() };
  let task: V1Task = {
    id: v1TaskId(request, stamp),
    contextId: v1ContextId(request, stamp),
    status: status,
    artifacts: artifacts
  };
  return { task: task, metadata: v1ResponseMetadata(request) };
}

function buildPersonalMemoryA2aReply(request: PersonalMemoryA2aRequest, answer: PersonalMemoryAnswer,
  stamp: string, streamState: string): string {
  if (request.method === 'native-message') {
    let reply: NativeMessageReply = nativeMessageReply(request, answer.text, stamp);
    return stringifyJsonCompat(reply);
  }
  if (request.method === 'SendStreamingMessage' || request.method === 'MessageStream') {
    let result: V1TaskResult = v1TaskReply(request, answer.text, stamp, streamState);
    let reply: MessageReply = {
      jsonrpc: '2.0',
      id: request.id === undefined ? null : request.id,
      result: result
    };
    return stringifyJsonCompat(reply);
  }
  if (request.method === 'SendMessage') {
    let result: V1MessageResult = { message: v1MessageReply(request, answer.text, stamp) };
    let reply: MessageReply = {
      jsonrpc: '2.0',
      id: request.id === undefined ? null : request.id,
      result: result
    };
    return stringifyJsonCompat(reply);
  }
  if (request.method === 'message/send' || request.method === 'message/stream') {
    if (request.numericRole === true) {
      let reply: MessageReply = {
        jsonrpc: '2.0',
        id: request.id === undefined ? null : request.id,
        result: nativeMessageReply(request, answer.text, stamp)
      };
      return stringifyJsonCompat(reply);
    }
    let textPart: OutgoingMessageTextPart = { kind: 'text', text: answer.text };
    let parts: OutgoingMessageTextPart[] = [textPart];
    let result: OutgoingMessageResult = {
      role: 'agent',
      messageId: 'memory_' + stamp,
      parts: parts
    };
    let reply: MessageReply = {
      jsonrpc: '2.0',
      id: request.id === undefined ? null : request.id,
      result: result
    };
    return stringifyJsonCompat(reply);
  }
  let textPart: OutgoingTaskTextPart = { type: 'text', text: answer.text };
  let parts: OutgoingTaskTextPart[] = [textPart];
  let result: OutgoingTaskResult = {
    contextId: 'memory_' + stamp,
    taskId: request.taskId.length > 0 ? request.taskId : 'memory_' + stamp,
    artifactId: 'memory_artifact_' + stamp,
    parts: parts,
    state: 'completed'
  };
  if (request.id !== undefined) {
    let reply: JsonRpcTaskReply = { jsonrpc: '2.0', id: request.id, method: request.method, result: result };
    return stringifyJsonCompat(reply);
  }
  let reply: TaskReply = { method: request.method, result: result };
  return stringifyJsonCompat(reply);
}

export function personalMemoryA2aReply(request: PersonalMemoryA2aRequest, answer: PersonalMemoryAnswer): string {
  return buildPersonalMemoryA2aReply(request, answer, String(Date.now()), 'TASK_STATE_COMPLETED');
}

export function personalMemoryA2aReplies(request: PersonalMemoryA2aRequest, answer: PersonalMemoryAnswer): string[] {
  let session = new PersonalMemoryA2aReplySession(request);
  return session.start().concat(session.finish(answer));
}

// Keep IDs stable while the agent awaits model/tool rounds. Send start before doing that work.
export class PersonalMemoryA2aReplySession {
  private request: PersonalMemoryA2aRequest;
  private stamp: string;
  private startedAt: number;
  private started: boolean = false;
  private finished: boolean = false;

  constructor(request: PersonalMemoryA2aRequest) {
    this.request = request;
    this.startedAt = Date.now();
    this.stamp = String(this.startedAt);
  }

  private isStreaming(): boolean {
    return this.request.method === 'SendStreamingMessage' || this.request.method === 'MessageStream';
  }

  start(): string[] {
    if (this.started || this.finished) {
      return [];
    }
    this.started = true;
    if (!this.isStreaming()) {
      return [];
    }
    let status: V1TaskStatus = {
      state: 'TASK_STATE_SUBMITTED', timestamp: new Date(this.startedAt).toISOString()
    };
    let task: V1Task = {
      id: v1TaskId(this.request, this.stamp), contextId: v1ContextId(this.request, this.stamp), status: status
    };
    let result: V1TaskResult = { task: task, metadata: v1ResponseMetadata(this.request) };
    let reply: MessageReply = {
      jsonrpc: '2.0', id: this.request.id === undefined ? null : this.request.id, result: result
    };
    return [stringifyJsonCompat(reply)];
  }

  finish(answer: PersonalMemoryAnswer): string[] {
    if (this.finished) {
      return [];
    }
    this.finished = true;
    if (!this.isStreaming()) {
      return [buildPersonalMemoryA2aReply(this.request, answer, this.stamp, 'TASK_STATE_COMPLETED')];
    }
    let taskId = v1TaskId(this.request, this.stamp);
    let contextId = v1ContextId(this.request, this.stamp);
    let metadata = v1ResponseMetadata(this.request);
    let part: NativeMessageTextPart = { text: answer.text, mediaType: 'text/plain' };
    let parts: NativeMessageTextPart[] = [part];
    let artifact: V1Artifact = { artifactId: 'memory_artifact_' + this.stamp, parts: parts };
    let artifactUpdate: V1TaskArtifactUpdateEvent = {
      taskId: taskId, contextId: contextId, artifact: artifact, append: false, lastChunk: true
    };
    let artifactResult: V1ArtifactUpdateResult = { artifactUpdate: artifactUpdate, metadata: metadata };
    let artifactReply: MessageReply = {
      jsonrpc: '2.0', id: this.request.id === undefined ? null : this.request.id, result: artifactResult
    };
    let status: V1TaskStatus = { state: 'TASK_STATE_COMPLETED', timestamp: new Date().toISOString() };
    let update: V1TaskStatusUpdateEvent = { taskId: taskId, contextId: contextId, status: status };
    let result: V1StatusUpdateResult = { statusUpdate: update, metadata: metadata };
    let finalReply: MessageReply = {
      jsonrpc: '2.0', id: this.request.id === undefined ? null : this.request.id, result: result
    };
    return [stringifyJsonCompat(artifactReply), stringifyJsonCompat(finalReply)];
  }
}

export function personalMemoryA2aError(message: string, request?: PersonalMemoryA2aRequest): string {
  if (request !== undefined) {
    return personalMemoryA2aReply(request, { text: message, count: 0 });
  }
  let error: ReplyError = { code: -32602, message: message };
  let reply: ErrorReply = {
    method: 'tasks/send',
    error: error
  };
  return stringifyJsonCompat(reply);
}

export function personalMemoryA2aFallbackError(data: string, message: string): string {
  try {
    let request = parseJsonCompat<IncomingRequest>(data);
    if (request !== null && typeof request === 'object' && !Array.isArray(request)) {
      if (request.method !== undefined && request.jsonrpc === '2.0' &&
        (typeof request.id === 'string' || typeof request.id === 'number')) {
        let error: ReplyError = { code: -32602, message: message };
        let reply: JsonRpcErrorReply = { jsonrpc: '2.0', id: request.id, error: error };
        return stringifyJsonCompat(reply);
      }
      if (request.parts !== undefined || request.message !== undefined) {
        let contextId = typeof request.contextId === 'string' ? request.contextId : '';
        let nativeRequest: PersonalMemoryA2aRequest = {
          method: 'native-message', taskId: '', question: '', contextId: contextId
        };
        return personalMemoryA2aReply(nativeRequest, { text: message, count: 0 });
      }
    }
  } catch (e) {
    // Return the legacy error for an unrecognized payload, without exposing the payload.
  }
  return personalMemoryA2aError(message);
}
