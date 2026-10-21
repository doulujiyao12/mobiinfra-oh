import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import path from 'node:path';
import { BridgeError } from './errors.mjs';
import { DELIVERY_INSTRUCTIONS } from './artifacts.mjs';
import { executionSettings } from './permissions.mjs';

const SOURCES = ['cli', 'vscode', 'appServer', 'exec', 'unknown'];
const validId = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value);
const cursorValue = value => {
  if (value === undefined || value === null || value === '') return undefined;
  if (typeof value !== 'string' || value.length > 8192 || /[\x00-\x1f]/.test(value)) throw new BridgeError(400, 'Invalid history cursor');
  return value;
};
const bounded = (text, length = 48000) => String(text || '').slice(0, length);
const samePath = (a, b) => process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
const title = thread => bounded(thread.name || thread.preview || '电脑会话', 200).trim() || '电脑会话';
const updatedAt = thread => Number.isFinite(thread.updatedAt) ? thread.updatedAt * 1000 : 0;
const unavailable = () => new BridgeError(404, '会话不可用，或不属于电脑端已授权的项目');
const unsupported = error => /method not found|unknown method|unsupported.method|does not support.*pagination|item pagination.*(?:not supported|unsupported)|legacy.*(?:pagination|items)|thread\/items\/list.*(?:not supported|unsupported|requires paginated)/i.test(error.message || '');
const busy = task => ['starting', 'running', 'waitingApproval', 'stopping', 'releasing'].includes(task.status);

export function renderHistoryItem(entry) {
  const item = entry.item;
  if (!item || !validId(item.id)) return null;
  let kind; let value;
  if (item.type === 'userMessage') {
    kind = 'user'; value = (item.content || []).filter(input => input.type !== 'text' || input.text !== DELIVERY_INSTRUCTIONS).map(input => input.type === 'text' ? input.text :
      ['image', 'localImage'].includes(input.type) ? '[图片]' : '[附件]').join('\n');
    // Legacy rollouts concatenate adjacent text inputs into a single field.
    if (value.endsWith(DELIVERY_INSTRUCTIONS)) value = value.slice(0, -DELIVERY_INSTRUCTIONS.length);
    if (!value) return null;
  } else if (item.type === 'agentMessage') { kind = 'assistant'; value = item.text; }
  else if (item.type === 'plan') { kind = 'plan'; value = item.text; }
  else if (item.type === 'commandExecution') { kind = 'tool'; value = item.command + '\n' + (item.aggregatedOutput || ''); }
  else if (item.type === 'fileChange') { kind = 'diff'; value = (item.changes || []).map(change => change.path + '\n' + (change.diff || '')).join('\n'); }
  else if (['reasoning', 'contextCompaction', 'subAgentActivity'].includes(item.type)) return null;
  else { kind = 'tool'; value = '历史操作：' + bounded(item.type, 80); }
  return { id: bounded(entry.turnId, 128) + ':' + item.id, turnId: bounded(entry.turnId, 128), kind, text: bounded(value) };
}

export class CodexHistory {
  requests = new Map();
  constructor(core) { this.core = core; }
  workspace(thread) {
    if (!thread || !validId(thread.id) || thread.ephemeral || thread.parentThreadId || !SOURCES.includes(thread.source)) throw unavailable();
    let cwd;
    try { cwd = realpathSync(thread.cwd); } catch { throw unavailable(); }
    const workspace = this.core.workspaces.find(item => samePath(cwd, item.path));
    if (!workspace) throw unavailable();
    this.core.workspace(workspace.id); return workspace;
  }
  async metadata(id) {
    this.core.requireReady();
    if (!validId(id)) throw new BridgeError(400, 'Invalid thread ID');
    const result = await this.core.rpc.request('thread/read', { threadId: id, includeTurns: false });
    if (result.thread?.id !== id) throw unavailable();
    return { thread: result.thread, workspace: this.workspace(result.thread) };
  }
  async list(cursor) {
    this.core.requireReady();
    for (const workspace of this.core.workspaces) this.core.workspace(workspace.id);
    const result = await this.core.rpc.request('thread/list', { limit: 25, cursor: cursorValue(cursor),
      cwd: this.core.workspaces.map(item => item.path), sourceKinds: SOURCES,
      archived: false, sortKey: 'updated_at', sortDirection: 'desc' });
    const threads = [];
    for (const thread of result.data || []) {
      const managed = this.core.tasks.get(thread.id);
      if (managed && !managed.sharedThread) continue;
      let workspace;
      try { workspace = this.workspace(thread); } catch { continue; }
      threads.push({ id: thread.id, title: title(thread), workspaceId: workspace.id,
        status: managed && busy(managed) ? managed.status : thread.status?.type === 'active' ? 'running' : 'history', model: bounded(thread.model, 200),
        updatedAt: updatedAt(thread), source: thread.source, sharedThread: managed?.sharedThread || undefined });
    }
    return { threads, nextThreadCursor: cursorValue(result.nextCursor) || '' };
  }
  async read(id, cursor) {
    const task = this.core.tasks.get(id);
    if (!cursor && task?.sharedThread) {
      if (await this.core.attachShared(task)) return task;
      if (!busy(task) && !this.core.locks.has(id)) await this.refresh(task);
      return task;
    }
    const preview = await this.readPage(id, cursor);
    if (!cursor && !task && this.core.config.desktopCoordination && this.core.tasks.size < 200) {
      const workspace = this.core.workspace(preview.workspaceId);
      const observed = { ...preview, external: false, sharedThread: true, cwd: workspace.path, status: 'idle' };
      if (await this.core.attachShared(observed)) {
        const shared = this.core.desktopSessions.entries.get(id)?.task || observed;
        this.core.tasks.set(id, shared); this.core.save(); return shared;
      }
    }
    return preview;
  }
  async refresh(task) {
    if (this.core.desktopSessions.has(task.id) || this.core.daemonSessions.has(task.id)) return;
    const revision = task.revision;
    const preview = await this.readPage(task.id);
    if (task.revision !== revision || busy(task) || this.core.locks.has(task.id)) return;
    const fields = { items: preview.items, title: preview.title, historyCursor: preview.historyCursor, truncated: preview.truncated };
    if (Object.entries(fields).some(([key, value]) => JSON.stringify(task[key]) !== JSON.stringify(value))) {
      Object.assign(task, fields); this.core.touch(task);
    }
  }
  async readPage(id, cursor) {
    const { thread, workspace } = await this.metadata(id);
    cursor = cursorValue(cursor);
    let mode = 'items'; let position;
    if (cursor) {
      const split = cursor.indexOf(':'); mode = cursor.slice(0, split); position = cursor.slice(split + 1);
      if (!['items', 'turns'].includes(mode) || !position) throw new BridgeError(400, 'Invalid history cursor');
    }
    let result;
    if (mode === 'items') {
      try { result = await this.core.rpc.request('thread/items/list', { threadId: id, limit: 40,
        cursor: position, sortDirection: 'desc' }); }
      catch (error) { if (cursor || !unsupported(error)) throw error; mode = 'turns'; }
    }
    if (mode === 'turns') result = await this.core.rpc.request('thread/turns/list', {
      threadId: id, limit: 2, cursor: position, sortDirection: 'desc', itemsView: 'full' });
    // Recheck metadata before returning any content: permissions/cwd may have changed during paging.
    const current = await this.metadata(id);
    if (current.workspace.id !== workspace.id || current.thread.cwd !== thread.cwd) throw unavailable();
    const entries = mode === 'items' ? [...(result.data || [])].reverse() :
      [...(result.data || [])].reverse().flatMap(turn => (turn.items || []).map(item => ({ turnId: turn.id, item })));
    const items = []; let characters = 0; let clipped = false;
    // Keep the latest display records when a legacy turn contains many tool calls.
    for (const entry of entries.reverse()) {
      const item = renderHistoryItem(entry); if (!item) continue;
      if (items.length >= 160 || characters + item.text.length > 1000000) { clipped = true; break; }
      items.unshift(item); characters += item.text.length;
    }
    const next = cursorValue(result.nextCursor);
    const model = this.core.models.find(item => item.model === thread.model) || this.core.models.find(item => item.isDefault) || this.core.models[0];
    const effort = model.supportedReasoningEfforts?.some(item => item.reasoningEffort === thread.reasoningEffort) ? thread.reasoningEffort : model.defaultReasoningEffort || '';
    return { id, title: title(thread), workspaceId: workspace.id, model: model.model, effort, mode: 'workspace-write', approvalMode: 'ask',
      status: 'history', turnId: '', items, approvals: [], artifacts: [], artifactWarning: '', revision: 0,
      updatedAt: updatedAt(thread), error: '', external: true,
      historyCursor: next ? mode + ':' + next : '', truncated: clipped };
  }
  async resume(id, body) {
    this.core.requireReady();
    if (!validId(id) || !validId(body.requestId) || body.requestId.length < 16) throw new BridgeError(400, 'requestId required');
    this.core.model(body.model, body.effort);
    const settings = executionSettings(body);
    // Registration does not load the thread or start inference. A fresh native
    // executor acquires the original writer lock at each turn/start.
    if (this.core.locks.has(id)) throw new BridgeError(409, '会话正在接入或提交，请稍后重试');
    this.core.locks.add(id);
    try {
      const { workspace } = await this.metadata(id);
      if (workspace.id !== body.workspaceId) throw unavailable();
      const existing = this.core.tasks.get(id);
      if (existing) {
        if (!existing.sharedThread || existing.mode !== settings.mode || (existing.approvalMode || 'ask') !== settings.approvalMode || existing.workspaceId !== body.workspaceId) {
          throw new BridgeError(409, '此会话已按其他权限接入，请刷新后按当前配置继续');
        }
        return existing;
      }
      if (this.core.tasks.size >= 200) throw new BridgeError(400, 'Task limit reached (200)');
      const preview = await this.readPage(id);
      const task = { ...preview, external: false, sharedThread: true, cwd: workspace.path,
        model: body.model, effort: body.effort || '', ...settings, status: 'idle', error: '' };
      this.core.tasks.set(id, task); this.core.touch(task); this.core.save(); return task;
    } finally { this.core.locks.delete(id); }
  }
  async fork(id, body) {
    this.core.requireReady();
    if (!validId(id) || !validId(body.requestId) || body.requestId.length < 16) throw new BridgeError(400, 'requestId required');
    const fingerprint = createHash('sha256').update(JSON.stringify({ id, workspaceId: body.workspaceId,
      model: body.model, effort: body.effort, mode: body.mode })).digest('hex');
    const existing = [...this.core.tasks.values()].find(task => task.forkRequestId === body.requestId);
    if (existing) {
      if (existing.forkFingerprint !== fingerprint) throw new BridgeError(409, '导入编号已用于其他配置，请重新选择会话');
      return existing;
    }
    const prior = this.requests.get(body.requestId);
    if (prior) throw new BridgeError(409, prior.fingerprint !== fingerprint ? '导入编号已用于其他配置，请重新选择会话' :
      '此次导入尚未确认，请刷新手机会话并在电脑检查，避免重复创建副本');
    if (this.core.locks.has('fork:' + id) || this.core.locks.has('fork-request:' + body.requestId)) throw new BridgeError(409, '会话正在导入，请稍后重试');
    if (this.core.tasks.size >= 200) throw new BridgeError(400, 'Task limit reached (200)');
    if (this.requests.size >= 2000) throw new BridgeError(400, 'History import limit reached (2000)');
    this.core.model(body.model, body.effort);
    if (!['read-only', 'workspace-write'].includes(body.mode)) throw new BridgeError(400, 'Invalid sandbox mode');
    this.core.locks.add('fork:' + id);
    this.core.locks.add('fork-request:' + body.requestId);
    try {
      const { thread, workspace } = await this.metadata(id);
      if (workspace.id !== body.workspaceId) throw unavailable();
      const request = { id: body.requestId, fingerprint, state: 'starting' };
      this.requests.set(request.id, request); this.core.save();
      // Forking retains context and leaves any PC-side turn under its original owner's control.
      let result;
      try {
        result = await this.core.rpc.request('thread/fork', { threadId: id, cwd: workspace.path,
          model: body.model, sandbox: body.mode, approvalPolicy: 'on-request', approvalsReviewer: 'user', excludeTurns: true });
      } catch (error) { request.state = 'uncertain'; this.core.save(); throw error; }
      if (!validId(result.thread?.id) || result.thread.id === id || this.core.tasks.has(result.thread.id) ||
        !samePath(path.resolve(result.cwd || result.thread.cwd || ''), workspace.path) ||
        result.approvalPolicy !== 'on-request' || result.approvalsReviewer !== 'user' ||
        result.sandbox?.type !== (body.mode === 'read-only' ? 'readOnly' : 'workspaceWrite')) {
        request.state = 'uncertain'; this.core.save();
        throw new BridgeError(502, '导入响应或执行权限不匹配，请在电脑检查会话');
      }
      const task = { id: result.thread.id, title: title(thread), workspaceId: workspace.id, cwd: workspace.path,
        model: body.model, effort: body.effort || '', mode: body.mode, status: 'idle', turnId: '', items: [],
        approvals: [], artifacts: [], artifactWarning: '', updatedAt: Date.now(), revision: 0, error: '',
        sourceThreadId: id, forkRequestId: body.requestId, forkFingerprint: fingerprint };
      request.state = 'completed';
      this.core.tasks.set(task.id, task); this.core.loaded.add(task.id); this.core.touch(task); this.core.save();
      try {
        const preview = await this.read(task.id);
        task.items = preview.items; task.historyCursor = preview.historyCursor; task.truncated = preview.truncated;
      } catch { task.error = '完整上下文已保留，历史显示暂未加载；可重新打开此会话重试。'; }
      this.core.touch(task); this.core.save(); return task;
    } finally { this.core.locks.delete('fork:' + id); this.core.locks.delete('fork-request:' + body.requestId); }
  }
}
