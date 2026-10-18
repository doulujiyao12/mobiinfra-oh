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
export interface CodexItem { id: string; kind: string; text: string; }
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
}
export interface CodexAttachment { id: string; name: string; size: number; image: boolean; }
export interface CodexEnvelope {
  protocol?: number;
  ready?: boolean;
  name?: string;
  workspaces?: CodexWorkspace[];
  models?: CodexModel[];
  tasks?: CodexTaskSummary[];
  task?: CodexTask;
  attachment?: CodexAttachment;
  unchanged?: boolean;
  error?: string;
  token?: string;
  deviceId?: string;
  serverId?: string;
}
export interface CodexCreateBody { workspaceId: string; model: string; effort: string; mode: string; }
export interface CodexTurnBody {
  requestId: string;
  text: string;
  attachments: string[];
  model: string;
  effort: string;
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
  if (bundle.type !== 'clawmate-codex-pairing' || bundle.version !== 1 || typeof bundle.name !== 'string' ||
    bundle.name.length > 80 || normalizeCodexOrigin(bundle.origin) !== bundle.origin || !validCodexToken(bundle.code) ||
    typeof bundle.serverId !== 'string' || bundle.serverId.length > 80 ||
    typeof bundle.expiresAt !== 'number' || bundle.expiresAt < Date.now() ||
    bundle.expiresAt > Date.now() + 10 * 60000 || typeof bundle.caCertificate !== 'string' ||
    (bundle.caCertificate.length > 0 && !validCodexCa(bundle.caCertificate))) {
    throw new Error('配对信息无效或已过期，请在 PC 应用中重新生成');
  }
}
export function codexTaskBusy(status: string): boolean {
  return ['starting', 'running', 'waitingApproval', 'stopping'].includes(status);
}
export function codexStatusLabel(status: string): string {
  switch (status) {
    case 'idle': return '等待任务';
    case 'starting': return '正在提交';
    case 'running': return '执行中';
    case 'waitingApproval': return '等待你的确认';
    case 'stopping': return '正在停止';
    case 'completed': return '已完成';
    case 'interrupted': return '已中断';
    case 'failed': return '执行失败';
    default: return '状态未知';
  }
}
