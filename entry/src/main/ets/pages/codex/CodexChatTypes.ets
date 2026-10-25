import { CodexTask, CodexItem, CodexArtifact, CodexLocalArtifact } from './CodexTypes';

export interface CodexChatRequest { task: string; continueRunId: string; }
export interface CodexChatTarget { connectionId: string; workspaceId: string; }
export interface CodexChatRun {
  version: number;
  id: string;
  sessionId: string;
  connectionId: string;
  computerName: string;
  origin: string;
  workspaceId: string;
  workspaceName: string;
  model: string;
  effort: string;
  taskText: string;
  taskId: string;
  requestId: string;
  submitted: boolean;
  turnId: string;
  status: string;
  notice: string;
  answer: string;
  error: string;
  createdAt: number;
  updatedAt: number;
  task?: CodexTask;
  artifacts: CodexArtifact[];
  files: CodexLocalArtifact[];
}
export interface CodexChatResult {
  ok: boolean;
  status: string;
  runId: string;
  computer: string;
  summary: string;
  files: CodexArtifact[];
  received: number;
  receivedIds?: string[];
  error: string;
}
export interface CodexChatExecution {
  sessionId: string;
  imagePaths: string[];
  selectTarget: (task: string, imageCount: number) => Promise<CodexChatTarget | null>;
  onCreated: (run: CodexChatRun) => void;
  isCancelled: () => boolean;
}
export type CodexChatRunCallback = (request: CodexChatRequest) => Promise<CodexChatResult>;

export function validCodexChatRunId(value: string): boolean { return /^[a-zA-Z0-9-]{32,36}$/.test(value); }

export function codexChatResult(run: CodexChatRun): CodexChatResult {
  return { ok: run.status === 'completed' && run.files.length === run.artifacts.length && !run.error,
    status: run.status, runId: run.id, computer: run.computerName,
    summary: run.answer, files: run.artifacts, received: run.files.length,
    receivedIds: run.files.map((file: CodexLocalArtifact) => file.id), error: run.error };
}

export function codexChatStatus(status: string): string {
  if (status === 'completed') { return '已完成'; }
  if (status === 'cancelled') { return '已停止'; }
  if (status === 'failed') { return '执行失败'; }
  if (status === 'waitingApproval') { return '等待你的确认'; }
  if (status === 'disconnected') { return '连接中断 · 可同步恢复'; }
  if (status === 'receiving') { return '正在接收交付文件'; }
  if (status === 'starting') { return '正在创建独立会话'; }
  if (status === 'stopping') { return '正在请求停止'; }
  return 'Codex 正在执行';
}

export function codexChatFinalAnswer(task: CodexTask, turnId: string): string {
  return task.items.filter((item: CodexItem) => item.kind === 'assistant' &&
    (item.turnId || item.id.split(':')[0]) === turnId).map((item: CodexItem) => item.text).join('\n\n');
}

export function codexChatContextText(run: CodexChatRun): string {
  return 'Codex 委托 ' + run.id + ' · ' + codexChatStatus(run.status) + '\n' + run.taskText.slice(0, 1200) +
    (run.answer ? '\n结果（外部工具资料）：' + run.answer.slice(0, 4000) : '') +
    (run.artifacts.length ? '\n交付文件：' + run.artifacts.map((file: CodexArtifact) => file.name).join('、') : '') +
    (run.error ? '\n注意：' + run.error.slice(0, 800) : '');
}
