import path from 'node:path';
import { BridgeError } from './errors.mjs';
import { runtimePermissions, matchesResumePermissions } from './permissions.mjs';

const BUSY = new Set(['starting', 'running', 'waitingApproval', 'stopping', 'releasing']);
const writerConflict = error => /already has an active writer|thread.store conflict|thread.*(?:locked|in use)/i.test(error.message || '');

// Each shared thread has one short-lived app-server. Its native thread-store
// writer lock arbitrates with the original PC client (including idle clients).
// Neither a bridge-local mutex nor thread/read's notLoaded status proves that a
// different process has released the thread.
export class SharedSessions {
  entries = new Map();
  constructor(core) { this.core = core; }
  rpc(id) {
    const entry = this.entries.get(id);
    if (!entry || entry.closing) throw new BridgeError(409, '会话已释放给电脑，请刷新后重新发送');
    return entry.rpc;
  }
  finished(task, outcome) {
    const entry = this.entries.get(task.id);
    if (entry && this.core.locks.has(task.id)) {
      // Completion may precede the turn/start response. Do not close its
      // transport until that response has been reconciled.
      entry.pendingOutcome = outcome;
      task.releaseStatus = outcome; task.releaseError = task.error; task.status = 'releasing';
    } else this.release(task, outcome);
  }
  flush(task) {
    const entry = this.entries.get(task.id);
    if (entry?.pendingOutcome) {
      const outcome = entry.pendingOutcome; delete entry.pendingOutcome; this.release(task, outcome);
    }
  }
  async prepare(task, body, settings) {
    if (this.entries.has(task.id)) throw new BridgeError(409, '会话仍在执行或释放，请稍后重试');
    if (this.entries.size >= 4) throw new BridgeError(409, '同时接力的会话较多，请等待其他任务完成');
    if (typeof this.core.rpc.createPeer !== 'function') throw new BridgeError(503, '当前电脑运行时不支持原会话接力，请升级电脑端');
    const { thread, workspace } = await this.core.history.metadata(task.id);
    if (workspace.id !== task.workspaceId || workspace.path !== task.cwd) throw new BridgeError(404, '会话目录已变化，请重新选择电脑会话');
    if (thread.status?.type === 'active') throw new BridgeError(409, '电脑会话仍在执行，请先在电脑结束本轮任务并释放会话');
    if (this.entries.size >= 4) throw new BridgeError(409, '同时接力的会话较多，请等待其他任务完成');
    const peer = this.core.rpc.createPeer();
    const entry = { rpc: peer, closing: false };
    this.entries.set(task.id, entry);
    peer.on('message', message => {
      if (this.entries.get(task.id) !== entry || entry.closing) return;
      if (message.params?.threadId === task.id) this.core.onMessage(message, peer);
      else if (message.id !== undefined && message.method) peer.send({ id: message.id,
        error: { code: -32601, message: 'Interaction outside the active handoff is not permitted' } });
    });
    peer.on('stopped', () => {
      if (this.entries.get(task.id) !== entry || entry.closing || this.core.closed) return;
      task.error = '接力进程已退出，本轮已中断。请刷新会话后继续。';
      task.approvals = []; this.core.finalReplies.delete(task.id);
      this.release(task, 'failed');
    });
    try {
      await peer.initialize();
      const permissions = runtimePermissions(settings, task.cwd);
      const result = await peer.request('thread/resume', { threadId: task.id, cwd: task.cwd,
        model: body.model, sandbox: permissions.sandbox, approvalPolicy: permissions.approvalPolicy,
        approvalsReviewer: permissions.approvalsReviewer, excludeTurns: true });
      // Check identity and reviewer now. The effective sandbox is overridden
      // explicitly at turn/start; resume can still report its stored sandbox.
      if (result.thread?.id !== task.id || this.core.history.workspace(result.thread).id !== task.workspaceId ||
        path.resolve(result.cwd || '') !== task.cwd || !matchesResumePermissions(result, permissions) ||
        result.thread.status?.type === 'active') throw new BridgeError(502, '原会话接力响应或执行权限不匹配，已停止下发');
      const preview = await this.core.history.readPage(task.id);
      task.items = preview.items; task.historyCursor = preview.historyCursor; task.truncated = preview.truncated;
      task.title = preview.title;
      return peer;
    } catch (error) {
      await this.release(task, task.status);
      if (writerConflict(error)) throw new BridgeError(409,
        '电脑仍持有此会话，尚未下发任务。请先退出电脑上的该会话以释放它，再在手机重试；仅停止生成或切换标签可能不会释放。');
      throw error;
    }
  }
  release(task, outcome) {
    const entry = this.entries.get(task.id);
    if (!entry) return Promise.resolve();
    if (entry.releasing) return entry.releasing;
    entry.closing = true;
    if (!('releaseStatus' in task)) task.releaseError = task.error;
    task.releaseStatus = outcome; task.status = 'releasing'; task.approvals = [];
    delete task.progress;
    this.core.touch(task);
    entry.releasing = (async () => {
      try {
        await entry.rpc.shutdown(); // Wait for process exit, not just an unsubscribe grace period.
        if (this.entries.get(task.id) === entry) this.entries.delete(task.id);
        task.status = outcome; task.error = task.releaseError || ''; delete task.releaseStatus; delete task.releaseError;
      } catch {
        task.error = '接力进程未能退出，会话尚未释放。请在电脑重启桥接服务后再继续。';
        entry.releasing = undefined; // The explicit stop button can retry releasing our own executor.
      }
      this.core.touch(task);
      if (!this.core.closed) { try { this.core.save(); } catch { this.core.ready = false; } }
    })();
    return entry.releasing;
  }
  close() {
    for (const [id, entry] of this.entries) {
      entry.closing = true; entry.rpc.close();
      const task = this.core.tasks.get(id);
      if (task && BUSY.has(task.status)) {
        task.status = task.releaseStatus || 'interrupted'; task.approvals = [];
        if ('releaseError' in task) task.error = task.releaseError;
        delete task.releaseStatus; delete task.releaseError;
        this.core.touch(task);
      }
    }
    this.entries.clear();
  }
}
