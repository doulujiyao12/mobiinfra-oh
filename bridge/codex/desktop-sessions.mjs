import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { DesktopIpc } from './desktop-ipc.mjs';
import { BridgeError } from './errors.mjs';
import { reconnectProgress } from './progress.mjs';
import { DELIVERY_INSTRUCTIONS } from './artifacts.mjs';

const active = status => ['starting', 'running', 'waitingApproval', 'stopping'].includes(status);
const samePath = (a, b) => process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
const bound = (value, length = 48000) => String(value ?? '').slice(-length);
const forbidden = key => ['__proto__', 'prototype', 'constructor'].includes(String(key));

// Follower requests enter the desktop's in-memory turn before app-server
// deserialization. Its renderer requires text_elements even on plain text.
// Keep this normalization on the desktop boundary; the standalone wire path
// remains unchanged. Adjacent text is separated because desktop joins it raw.
export function desktopInputs(input) {
  if (!Array.isArray(input) || !input.length) throw new BridgeError(400, '桌面输入不能为空');
  const result = [];
  for (const item of input) {
    if (item?.type === 'text' && typeof item.text === 'string') {
      const previous = result.at(-1);
      if (previous?.type === 'text') previous.text += '\n\n' + item.text;
      else result.push({ type: 'text', text: item.text, text_elements: [] });
    } else if (item?.type === 'localImage' && typeof item.path === 'string' && item.path) {
      result.push({ type: 'localImage', path: item.path });
    } else throw new BridgeError(400, '不支持的桌面输入格式');
  }
  return result;
}

// Desktop uses Immer paths (arrays), not JSON Pointer. Reject prototype paths,
// sparse arrays and unsupported operations; a revision gap requires a new snapshot.
export function applyDesktopPatches(state, patches) {
  if (!Array.isArray(patches) || patches.length > 20000) throw new Error('桌面增量消息不兼容');
  for (const patch of patches) {
    if (!['add', 'replace', 'remove'].includes(patch.op) || !Array.isArray(patch.path) || !patch.path.length ||
        patch.path.length > 64 || patch.path.some(key => forbidden(key) || !['number', 'string'].includes(typeof key))) throw new Error('桌面增量路径不安全');
    let parent = state;
    for (const key of patch.path.slice(0, -1)) {
      if (!parent || !Object.hasOwn(parent, key)) throw new Error('桌面增量路径已失效');
      parent = parent[key];
    }
    const key = patch.path.at(-1);
    if (!parent || typeof parent !== 'object') throw new Error('桌面增量目标不兼容');
    if (Array.isArray(parent)) {
      if (!Number.isSafeInteger(key) || key < 0 || key > parent.length || (patch.op !== 'add' && key === parent.length)) throw new Error('桌面数组增量不兼容');
      if (patch.op === 'remove') parent.splice(key, 1);
      else if (patch.op === 'add') parent.splice(key, 0, patch.value);
      else parent[key] = patch.value;
    } else if (patch.op === 'remove') delete parent[key];
    else Object.defineProperty(parent, key, { value: patch.value, enumerable: true, configurable: true, writable: true });
  }
  return state;
}
export function desktopTurns(state) {
  const history = state.turnHistory?.kind === 'canonical' ? state.turnHistory.history : null;
  if (history) {
    const turns = [];
    for (const island of history.islands || []) for (const entry of island.entries || []) {
      const turn = history.entitiesByKey?.[entry.value]; if (turn) turns.push(turn);
    }
    return turns.slice(-100);
  }
  return Array.isArray(state.turns) ? state.turns.slice(-100) : [];
}
function renderTurns(turns) {
  const result = [];
  for (const turn of turns) {
    const prefix = String(turn.turnId || turn.params?.clientUserMessageId || 'pending');
    const input = turn.params?.input || [];
    let user = input.filter(item => item.type === 'text').map(item => item.text).join('\n');
    if (user.endsWith(DELIVERY_INSTRUCTIONS)) user = user.slice(0, -DELIVERY_INSTRUCTIONS.length).trimEnd();
    if (user) result.push({ id: prefix + ':user', kind: 'user', text: bound(user) });
    for (const item of turn.items || []) {
      const id = prefix + ':' + item.id;
      if (item.type === 'agentMessage' && typeof item.text === 'string') result.push({ id, kind: 'assistant', text: bound(item.text) });
      else if (item.type === 'plan' && typeof item.text === 'string') result.push({ id, kind: 'plan', text: bound(item.text) });
      else if (item.type === 'commandExecution') result.push({ id, kind: 'tool', text: bound(String(item.command || '') + '\n' + (item.aggregatedOutput || '')) });
      else if (item.type === 'fileChange') result.push({ id, kind: 'diff', text: bound((item.changes || []).map(change => change.path + '\n' + (change.diff || '')).join('\n')) });
      // Never serialize reasoning, tool authentication or unknown UI objects.
    }
  }
  for (const item of result) item.turnId = item.id.split(':')[0];
  return result.slice(-160);
}
function approvals(state, owner) {
  return (state.requests || []).flatMap(request => {
    const kind = request.method === 'item/commandExecution/requestApproval' ? 'command' :
      request.method === 'item/fileChange/requestApproval' ? 'file' : request.method === 'item/tool/requestUserInput' ? 'question' : '';
    if (!kind || request.completed || request.completedAtMs != null || !['string', 'number'].includes(typeof request.id)) return [];
    const params = request.params || {}; const detail = JSON.stringify(params, null, 2);
    const id = createHash('sha256').update(owner + ':' + String(request.id) + ':' + detail).digest('hex');
    return [{ id, rpcId: request.id, kind, desktopOwner: owner,
      canAccept: detail.length <= 16000 && (!params.availableDecisions || params.availableDecisions.includes('accept')),
      title: kind === 'command' ? '执行命令申请' : kind === 'file' ? '修改文件申请' : 'Codex 需要补充信息',
      detail: bound(detail, 16000), questions: params.questions || [] }];
  }).slice(0, 30);
}

export class DesktopSessions {
  entries = new Map(); attaching = new Map(); closed = false;
  constructor(core, dependencies = {}) {
    this.core = core; this.ipc = dependencies.desktopIpc || new DesktopIpc();
    this.ipc.on('broadcast', message => this.onBroadcast(message));
    this.ipc.on('disconnected', () => { for (const entry of [...this.entries.values()]) this.unavailable(entry, '桌面连接已断开；任务可能仍在电脑执行，请刷新状态后再发送'); });
  }
  has(id) { return this.entries.has(id); }
  synchronized(id) { return this.entries.get(id)?.synchronized === true; }
  validate(task, state) {
    if (state.id !== task.id || state.hostId !== 'local' || state.parentThreadId || state.workspaceKind === 'projectless' ||
        (state.environments || []).some(environment => environment.environmentId !== 'local')) throw new Error('桌面会话不属于当前本地项目');
    const workspace = this.core.workspace(task.workspaceId);
    if (!samePath(realpathSync(state.cwd), workspace.path) || !samePath(task.cwd, workspace.path)) throw new Error('桌面会话目录与手机授权项目不一致');
  }
  async attach(task) {
    if (this.attaching.has(task.id)) return this.attaching.get(task.id);
    const operation = this.attachOnce(task); this.attaching.set(task.id, operation);
    try { return await operation; } finally { if (this.attaching.get(task.id) === operation) this.attaching.delete(task.id); }
  }
  async attachOnce(task) {
    if (!this.core.config.desktopCoordination || !task.sharedThread || this.closed) return false;
    if (this.core.sharedSessions.entries.has(task.id)) return false;
    const current = this.entries.get(task.id);
    if (current) {
      try { this.validate(task, current.state); }
      catch (error) { this.unavailable(current, error.message); throw new BridgeError(409, error.message); }
      current.lastAccess = Date.now(); return true;
    }
    const { workspace } = await this.core.history.metadata(task.id);
    if (!samePath(workspace.path, task.cwd)) throw new BridgeError(409, '会话目录已经改变');
    const owner = await this.ipc.owner(task.id); if (!owner) return false;
    if (this.closed || this.core.closed) return false;
    if (this.entries.size >= 20) {
      const oldest = [...this.entries.values()].filter(entry => !active(entry.task.status) && !this.core.locks.has(entry.task.id))
        .sort((a, b) => a.lastAccess - b.lastAccess)[0];
      if (!oldest) throw new BridgeError(409, '同时运行的共享会话较多，请等待部分任务完成');
      oldest.task.desktopConnected = false; this.detach(oldest.task.id);
    }
    let ready; let reject;
    const promise = new Promise((resolve, fail) => { ready = resolve; reject = fail; });
    const entry = { task, owner, revision: -1, state: null, ready, reject, completed: new Set(), submitted: new Set(),
      approvalInFlight: new Set(), synchronized: false, lastAccess: Date.now() };
    this.entries.set(task.id, entry);
    const timer = setTimeout(() => reject(new Error('未收到桌面会话快照，请确认桌面或 IDE 客户端版本兼容')), 15000);
    let attempts = 0;
    const retry = setInterval(() => {
      if (entry.state || ++attempts > 2) return;
      // Following is read-only and idempotent. Recover a lost initial snapshot,
      // never retry a turn, approval or stop request automatically.
      try { this.ipc.follow(task.id, owner, true); } catch (error) { reject(error); }
    }, 3000);
    try { this.ipc.follow(task.id, owner, true); await promise; return true; }
    catch (error) { this.detach(task.id); throw new BridgeError(503, error.message); }
    finally { clearTimeout(timer); clearInterval(retry); }
  }
  onBroadcast(message) {
    if (message.method === 'client-status-changed' && message.params?.status === 'disconnected') {
      for (const entry of [...this.entries.values()]) if (entry.owner === message.params.clientId) this.unavailable(entry, '持有会话的桌面客户端已退出；请刷新后继续');
      return;
    }
    if (message.method === 'ipc-connection-reset') { for (const entry of [...this.entries.values()]) this.unavailable(entry, '桌面协调服务已重连，请刷新后继续'); return; }
    const params = message.params || {}; const entry = this.entries.get(params.conversationId);
    if (!entry || params.hostId !== 'local' || message.sourceClientId !== entry.owner) return;
    if (message.method === 'thread-stream-following-status-requested') {
      try { this.ipc.follow(entry.task.id, entry.owner, true); } catch (error) { this.unavailable(entry, error.message); }
      return;
    }
    if (message.method !== 'thread-stream-state-changed') return;
    try {
      if (message.version !== 11) throw new Error('桌面共享协议版本不兼容，已停止转发');
      const change = params.change;
      if (!Number.isSafeInteger(change?.revision) || change.revision < 0) throw new Error('桌面快照版本无效');
      if (change.revision <= entry.revision) return;
      const initial = !entry.state;
      if (change.type === 'snapshot') entry.state = change.conversationState;
      else if (change.type === 'patches' && entry.state && change.baseRevision === entry.revision) {
        entry.state = applyDesktopPatches(entry.state, change.patches);
      } else {
        entry.synchronized = false; entry.task.desktopConnected = false; entry.task.status = 'unknown'; entry.task.approvals = [];
        entry.task.error = '桌面增量记录有缺失，正在重新同步；同步完成前不会下发操作'; this.core.touch(entry.task);
        this.ipc.follow(entry.task.id, entry.owner, true); return;
      }
      if (Buffer.byteLength(JSON.stringify(entry.state)) > 16 * 1024 * 1024) throw new Error('桌面共享状态过大，已停止同步');
      this.validate(entry.task, entry.state); entry.revision = change.revision; entry.synchronized = true;
      this.apply(entry, initial); entry.ready();
    } catch (error) { entry.reject(error); this.unavailable(entry, error.message); }
  }
  apply(entry, initial) {
    const task = entry.task; const state = entry.state; const turns = desktopTurns(state); const latest = turns.at(-1);
    if (initial) for (const turn of turns) if (turn.status !== 'inProgress') entry.completed.add(turn.turnId);
    const pendingRequests = (state.requests || []).filter(request => !request.completed && request.completedAtMs == null);
    task.executionTransport = 'desktop'; task.desktopConnected = true;
    task.title = bound(state.title || task.title, 200); task.items = renderTurns(turns);
    task.approvals = approvals(state, entry.owner); task.turnId = latest?.turnId || '';
    task.startedAt = latest?.turnStartedAtMs || task.startedAt; task.lastActivityAt = Date.now();
    task.executionSource = entry.submitted.has(task.turnId) || (!!task.lastRequestId && latest?.params?.clientUserMessageId === task.lastRequestId) ? 'phone' : 'desktop';
    if (task.lastRequestId && latest?.params?.clientUserMessageId === task.lastRequestId) task.lastRequestConfirmed = true;
    const runtimeActive = state.threadRuntimeStatus?.type === 'active';
    task.status = pendingRequests.length ? 'waitingApproval' : runtimeActive || latest?.status === 'inProgress' ? 'running' :
      latest ? ({ completed: 'completed', interrupted: 'interrupted', failed: 'failed' })[latest.status] || 'idle' : 'idle';
    if (entry.stoppingTurnId === task.turnId && active(task.status)) task.status = 'stopping';
    else delete entry.stoppingTurnId;
    task.error = bound(latest?.error?.message || '', 2000); delete task.progress;
    const retry = [...(latest?.items || [])].reverse().find(item => item.type === 'error' && item.willRetry);
    if (active(task.status) && retry) {
      const key = JSON.stringify([retry.id, retry.message]); const output = JSON.stringify(task.items);
      if (entry.retryKey !== key) {
        entry.retryKey = key; entry.retryOutput = output; entry.retryResolved = false;
        entry.retryProgress = reconnectProgress({ message: retry.message }, undefined);
      } else if (entry.retryOutput !== output) entry.retryResolved = true;
      if (!entry.retryResolved) task.progress = entry.retryProgress;
    }
    if (pendingRequests.some(request => !['item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/tool/requestUserInput'].includes(request.method))) {
      task.progress = { kind: 'desktopApproval', message: '电脑有手机暂不支持的确认项，请在电脑端处理', since: Date.now() };
    }
    if (latest?.turnId && latest.status === 'completed' && !entry.completed.has(latest.turnId)) {
      entry.completed.add(latest.turnId);
      const final = [...(latest.items || [])].reverse().find(item => item.type === 'agentMessage' && item.phase === 'final_answer');
      if (final?.text) try {
        const result = this.core.artifacts.publish(task, final.text); task.artifacts = (task.artifacts || []).concat(result.artifacts);
        task.artifactWarning = result.warnings.join('\n');
      } catch { task.artifactWarning = '共享会话成品收集失败，请在电脑检查成品链接'; }
    }
    this.core.touch(task);
  }
  async start(task, params) {
    const entry = this.entries.get(task.id); if (!entry?.state || !entry.synchronized) throw new BridgeError(409, '桌面会话未同步，请刷新');
    this.validate(task, entry.state);
    const latest = desktopTurns(entry.state).at(-1);
    if (entry.state.threadRuntimeStatus?.type === 'active' || latest?.status === 'inProgress') throw new BridgeError(409, '电脑正在执行本轮任务，可在手机停止，或等待完成后继续发送');
    const input = desktopInputs(params.input);
    // Explicit null avoids inheriting a desktop full-access permission profile.
    const response = await this.request('thread-follower-start-turn', { conversationId: task.id,
      turnStart: { request: { ...params, input, permissions: null, runtimeWorkspaceRoots: [task.cwd], clientUserMessageId: task.lastRequestId },
        context: { inheritThreadSettings: false, useAppServerPermissionDefault: false, usePermissionSelection: false } } }, entry.owner);
    const result = response.result?.result;
    if (!result?.turn?.id) throw Object.assign(new Error('桌面执行结果尚未确认，请刷新会话，不要重复下发'), { outcomeUnknown: true });
    entry.submitted.add(result.turn.id); task.lastRequestConfirmed = true; return result;
  }
  async interrupt(task) {
    const entry = this.entries.get(task.id); if (!entry) throw new BridgeError(409, '桌面会话已断开');
    if (!entry.synchronized || !task.turnId) throw new BridgeError(409, '执行轮次尚未同步，请刷新确认后再停止');
    if (task.status === 'stopping') return task;
    if (entry.interrupting) throw new BridgeError(409, '停止请求正在提交，请等待桌面确认');
    this.validate(task, entry.state);
    const turnId = task.turnId;
    entry.interrupting = true;
    try {
      const response = await this.request('thread-follower-interrupt-turn', { conversationId: task.id,
        mode: 'user-stop', expectedTurnId: turnId }, entry.owner);
      if (response.result?.ok !== true || (response.result.interruptedTurnId && response.result.interruptedTurnId !== turnId)) throw new BridgeError(409, '电脑执行已切换，请刷新后再停止');
      if (task.turnId === turnId && active(task.status)) {
        entry.stoppingTurnId = turnId; task.status = 'stopping'; delete task.progress; this.core.touch(task);
      }
      return task;
    } finally { entry.interrupting = false; }
  }
  async answer(task, approval, result) {
    const entry = this.entries.get(task.id);
    if (!entry?.synchronized || approval.desktopOwner !== entry.owner || !task.approvals.some(item => item.id === approval.id) || entry.approvalInFlight.has(approval.id)) throw new BridgeError(409, '审批已经失效或正在提交，请刷新');
    this.validate(task, entry.state);
    const method = approval.kind === 'command' ? 'thread-follower-command-approval-decision' :
      approval.kind === 'file' ? 'thread-follower-file-approval-decision' : 'thread-follower-submit-user-input';
    entry.approvalInFlight.add(approval.id);
    try {
      const response = await this.request(method, { conversationId: task.id, requestId: approval.rpcId,
        ...(approval.kind === 'question' ? { response: result } : { decision: result.decision }) }, entry.owner);
      if (response.result?.ok !== true) throw new BridgeError(409, '桌面未确认审批，请刷新');
      task.approvals = task.approvals.filter(item => item.id !== approval.id); this.core.touch(task); return task;
    } finally { entry.approvalInFlight.delete(approval.id); }
  }
  async request(method, params, owner) {
    try { return await this.ipc.request(method, params, owner); }
    catch (error) { throw Object.assign(new BridgeError(503, error.message), { outcomeUnknown: error.outcomeUnknown }); }
  }
  unavailable(entry, message) {
    entry.reject(new Error(message)); this.detach(entry.task.id);
    const task = entry.task; task.desktopConnected = false; task.approvals = [];
    // A disconnected observer cannot declare the desktop task failed or stopped.
    task.status = 'unknown'; task.error = message; this.core.touch(task);
  }
  detach(id) {
    const entry = this.entries.get(id); if (!entry) return;
    this.entries.delete(id); try { this.ipc.follow(id, entry.owner, false); } catch {}
  }
  close() {
    this.closed = true;
    for (const entry of [...this.entries.values()]) { entry.reject(new Error('桥接已关闭')); this.detach(entry.task.id); }
    this.ipc.close();
  }
}
