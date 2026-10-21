export interface CodexEffort {
  reasoningEffort: string;
  description: string;
}
export interface CodexModel {
  id: string;
  model: string;
  displayName: string;
  defaultReasoningEffort: string;
  supportedReasoningEfforts: CodexEffort[];
  inputModalities?: string[];
  isDefault?: boolean;
}
export interface CodexWorkspace { id: string; name: string; }
export interface CodexConnection { origin: string; token: string; caCertificate?: string; }
export interface CodexSavedConnection { id: string; name: string; origin: string; updatedAt: number; }
export enum CodexScreen { Connections = 0, Setup = 1, Workspace = 2 }
export const CODEX_PAIRING_PREFIX: string = 'CLAWMATE-CODEX-PAIR:';
export function codexConnectionLabel(origin: string): string { return origin.replace(/^https:\/\//, ''); }
export interface CodexPairingBundle {
  type: string;
  version: number;
  name: string;
  origin: string;
  serverId: string;
  caCertificate: string;
  code: string;
  expiresAt: number;
}
export interface CodexPairBody { code: string; deviceName: string; }
export interface CodexItem { id: string; kind: string; text: string; turnId?: string; }
export interface CodexItemPatch extends CodexItem { append?: boolean; }
export interface CodexTaskDelta { baseRevision: number; task: CodexTask; items: CodexItemPatch[]; itemOrder: string[]; }
export interface CodexTimelineEntry { id: string; item?: CodexItem; artifacts: CodexArtifact[]; }
export interface CodexProgress {
  kind: string;
  message: string;
  detail?: string;
  since: number;
  attempt?: number;
  total?: number;
}
export interface CodexQuestionOption { label: string; description: string; }
export interface CodexQuestion {
  id: string;
  header: string;
  question: string;
  options?: CodexQuestionOption[];
  isSecret?: boolean;
}
export interface CodexAnswer { id: string; text: string; }
export interface CodexApproval {
  id: string;
  kind: string;
  title: string;
  detail: string;
  questions: CodexQuestion[];
  canAccept?: boolean;
}
export interface CodexTaskSummary {
  id: string;
  title: string;
  status: string;
  workspaceId: string;
  model: string;
  updatedAt: number;
  source?: string;
  sharedThread?: boolean;
}
export interface CodexTask {
  id: string;
  title: string;
  status: string;
  workspaceId: string;
  model: string;
  effort: string;
  mode: string;
  turnId: string;
  items: CodexItem[];
  approvals: CodexApproval[];
  updatedAt: number;
  revision: number;
  error: string;
  truncated?: boolean;
  lastRequestId?: string;
  artifacts?: CodexArtifact[];
  artifactWarning?: string;
  external?: boolean;
  sourceThreadId?: string;
  sharedThread?: boolean;
  historyCursor?: string;
  approvalMode?: string;
  progress?: CodexProgress;
  startedAt?: number;
  lastActivityAt?: number;
  executionTransport?: string;
  executionSource?: string;
  desktopConnected?: boolean;
  lastRequestConfirmed?: boolean;
}
export interface CodexArtifact {
  id: string;
  turnId: string;
  name: string;
  size: number;
  mimeType: string;
  sha256: string;
  createdAt: number;
}
export interface CodexLocalArtifact extends CodexArtifact { localPath: string; }
export interface CodexArtifactChunk { id: string; offset: number; total: number; sha256: string; base64: string; }
export interface CodexAttachment { id: string; name: string; size: number; image: boolean; }
export interface CodexEnvelope {
  protocol?: number;
  ready?: boolean;
  name?: string;
  workspaces?: CodexWorkspace[];
  models?: CodexModel[];
  tasks?: CodexTaskSummary[];
  task?: CodexTask;
  taskDelta?: CodexTaskDelta;
  attachment?: CodexAttachment;
  unchanged?: boolean;
  error?: string;
  token?: string;
  deviceId?: string;
  serverId?: string;
  artifactsSupported?: boolean;
  artifactChunk?: CodexArtifactChunk;
  existingSessionsSupported?: boolean;
  sameSessionSupported?: boolean;
  permissionSettingsSupported?: boolean;
  taskUpdatesSupported?: boolean;
  healthSupported?: boolean;
  taskDeltaSupported?: boolean;
  artifactChunkBytes?: number;
  desktopSessionSharingSupported?: boolean;
  threads?: CodexTaskSummary[];
  nextThreadCursor?: string;
}

export function codexLinkLabel(lastSuccess: number, lastFailure: number, now: number, checking: boolean = false): string {
  if (lastFailure > 0 && lastFailure >= lastSuccess) { return checking ? '正在重连' : '连接已中断'; }
  if (!lastSuccess || now - lastSuccess > 25000) { return '正在确认连接'; }
  return '已连接';
}

export function mergeCodexTask(current: CodexTask | null, envelope: CodexEnvelope): CodexTask | undefined {
  if (envelope.task !== undefined) { return envelope.task; }
  const delta = envelope.taskDelta;
  if (delta === undefined) { return undefined; }
  if (current === null || current.id !== delta.task.id || current.revision !== delta.baseRevision ||
    delta.task.revision <= current.revision || delta.itemOrder.length > 160 || delta.items.length > 160) {
    throw new Error('会话增量已过期，需要重新同步');
  }
  const records = new Map<string, CodexItem>();
  current.items.forEach((item: CodexItem) => { records.set(item.id, item); });
  delta.items.forEach((patch: CodexItemPatch) => {
    const previous = records.get(patch.id);
    if (patch.append && (previous === undefined || previous.kind !== patch.kind)) { throw new Error('会话增量缺少原始记录'); }
    const item: CodexItem = { id: patch.id, kind: patch.kind,
      text: patch.append ? (previous?.text || '') + patch.text : patch.text, turnId: patch.turnId };
    records.set(item.id, item);
  });
  const items: CodexItem[] = [];
  const seen = new Set<string>();
  delta.itemOrder.forEach((id: string) => {
    const item = records.get(id);
    if (item === undefined || seen.has(id)) { throw new Error('会话增量顺序无效'); }
    seen.add(id); items.push(item);
  });
  const result: CodexTask = delta.task; result.items = items; return result;
}

// Place each delivery after the final visible record of its turn. Legacy files
// whose turn is outside the loaded page stay above the messages, never attached
// to an unrelated new reply at the global bottom.
export function codexTimeline(items: CodexItem[], artifacts: CodexArtifact[]): CodexTimelineEntry[] {
  const result: CodexTimelineEntry[] = items.map((item: CodexItem): CodexTimelineEntry => ({ id: item.id, item: item, artifacts: [] }));
  const older: CodexArtifact[] = [];
  artifacts.forEach((artifact: CodexArtifact) => {
    let target: number = -1;
    for (let i = 0; i < items.length; i++) {
      const turn = items[i].turnId || items[i].id.split(':')[0];
      if (artifact.turnId && turn === artifact.turnId) { target = i; }
    }
    // Older clients did not tag display records. Only an assistant's explicit
    // final-file link is a safe fallback anchor for those existing deliveries.
    if (target < 0) {
      const candidates: number[] = [];
      for (let i = 0; i < items.length; i++) {
        if (items[i].kind === 'assistant' && (items[i].text.includes('[' + artifact.name + '](') ||
          items[i].text.includes('/' + artifact.name + ')') || items[i].text.includes('/' + encodeURIComponent(artifact.name) + ')'))) { candidates.push(i); }
      }
      if (candidates.length === 1) { target = candidates[0]; }
    }
    if (target >= 0) { result[target].artifacts.push(artifact); } else { older.push(artifact); }
  });
  if (older.length > 0) { result.unshift({ id: 'older-deliveries', artifacts: older }); }
  return result;
}
// Force a keyed ArkUI row to refresh when immutable streamed text is replaced,
// including equal-length corrections and newly attached delivery cards.
export function codexTimelineKey(entry: CodexTimelineEntry): string {
  const text = entry.item?.text || '';
  let hash: number = 0;
  for (let i = 0; i < text.length; i++) { hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0; }
  return entry.id + ':' + text.length + ':' + hash + ':' + entry.artifacts.map((item: CodexArtifact) => item.id).join(',');
}
export interface CodexCreateBody { workspaceId: string; model: string; effort: string; mode: string; approvalMode?: string; }
export interface CodexForkBody extends CodexCreateBody { requestId: string; }
export interface CodexResumeBody extends CodexCreateBody { requestId: string; }
export interface CodexTurnBody {
  requestId: string;
  text: string;
  attachments: string[];
  model: string;
  effort: string;
  mode?: string;
  approvalMode?: string;
}
export interface CodexUploadBody { workspaceId: string; name: string; base64: string; image: boolean; }
export interface CodexApprovalBody { id: string; decision: string; answers: CodexAnswer[]; }

export const CODEX_MAX_FILE_BYTES: number = 8 * 1024 * 1024;

// Accept an HTTPS origin only. Tokens never enter a URL, redirect, preference or log.
export function normalizeCodexOrigin(input: string): string {
  const value = input.trim().replace(/\/+$/, '');
  const match = /^https:\/\/(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?)(?::([0-9]{1,5}))?$/.exec(value);
  if (match === null || (match[2] !== undefined && (Number(match[2]) < 1 || Number(match[2]) > 65535))) {
    throw new Error('请填写完整 HTTPS 地址，例如 https://codex.example.com:8787，不含路径或令牌');
  }
  return value.toLowerCase();
}
export function validCodexToken(value: string): boolean { return /^[A-Za-z0-9_-]{43,128}$/.test(value); }
export function validCodexCa(value: string): boolean {
  return value.length <= 2048 && /^-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*$/.test(value);
}
export function validateCodexPairing(bundle: CodexPairingBundle): void {
  if (bundle === null || bundle.type !== 'clawmate-codex-pairing' || bundle.version !== 1 || typeof bundle.name !== 'string' ||
    bundle.name.length > 80 || typeof bundle.origin !== 'string' || typeof bundle.code !== 'string' ||
    normalizeCodexOrigin(bundle.origin) !== bundle.origin || !validCodexToken(bundle.code) ||
    typeof bundle.serverId !== 'string' || bundle.serverId.length > 80 ||
    typeof bundle.expiresAt !== 'number' || bundle.expiresAt < Date.now() ||
    bundle.expiresAt > Date.now() + 10 * 60000 || typeof bundle.caCertificate !== 'string' ||
    (bundle.caCertificate.length > 0 && !validCodexCa(bundle.caCertificate))) {
    throw new Error('配对信息无效或已过期，请在 PC 应用中重新生成');
  }
}
export function codexTaskBusy(status: string): boolean {
  return ['starting', 'running', 'waitingApproval', 'stopping', 'releasing'].includes(status);
}
export function codexApprovalLabel(mode: string): string {
  return mode === 'full' ? '完全访问控制' : mode === 'auto' ? '帮我批准' : '请求批准';
}
export function codexExecutionNotice(task: CodexTask | null, now: number): string {
  if (task === null) { return ''; }
  if (task.executionTransport === 'desktop' && task.desktopConnected === false) {
    return task.error || '桌面共享连接已断开，请刷新确认任务状态';
  }
  if (!codexTaskBusy(task.status)) { return task.desktopConnected === true ? '与电脑实时共享当前会话' : ''; }
  if (task.progress?.kind === 'desktopApproval') { return task.progress.message; }
  if (task.status === 'waitingApproval') { return '有操作等待你的确认，请查看对话中的申请'; }
  if (task.status === 'releasing') { return '正在保存记录并释放会话'; }
  if (task.status === 'stopping') { return '正在停止任务，等待电脑端确认'; }
  if (task.progress?.message) {
    const seconds = Math.max(0, Math.floor((now - task.progress.since) / 1000));
    return task.progress.message + (seconds >= 3 && task.progress.kind !== 'reviewResult' ? ' · 已等待 ' + seconds + ' 秒' : '');
  }
  const lastActivity = task.lastActivityAt || task.startedAt || 0;
  const seconds = Math.max(0, Math.floor((now - lastActivity) / 1000));
  if (lastActivity > 0 && seconds >= 8) { return '电脑端仍在执行，已有 ' + seconds + ' 秒没有新输出，可继续等待或停止'; }
  return task.desktopConnected === true ? (task.executionSource === 'phone' ? '手机已下发，电脑与手机同步执行状态' : '电脑正在执行，手机同步显示；可在任一端确认或停止') : '';
}
export function codexStatusLabel(status: string): string {
  switch (status) {
    case 'idle': return '等待任务';
    case 'starting': return '正在提交';
    case 'running': return '执行中';
    case 'waitingApproval': return '等待你的确认';
    case 'stopping': return '正在停止';
    case 'releasing': return '正在保存并释放会话';
    case 'completed': return '已完成';
    case 'interrupted': return '已中断';
    case 'failed': return '执行失败';
    case 'history': return '电脑历史';
    case 'unknown': return '等待同步状态';
    default: return '状态未知';
  }
}
