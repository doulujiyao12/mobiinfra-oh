import { DaemonRpc } from './daemon-rpc.mjs';
import { discoverDaemons } from './daemon-discovery.mjs';
import { BridgeError } from './errors.mjs';
import { renderHistoryItem } from './history.mjs';

const busy = task => ['starting', 'running', 'waitingApproval', 'stopping'].includes(task.status);
const activeTurn = turns => turns.find(turn => turn.status === 'inProgress');

export class DaemonSessions {
  entries = new Map(); attaching = new Map(); closed = false;
  constructor(core, dependencies = {}) {
    this.core = core;
    this.discover = dependencies.discoverDaemons || (() => discoverDaemons(core.rpc.environment));
    this.connect = dependencies.daemonRpc || (socket => new DaemonRpc(socket));
  }
  has(id) { return this.entries.has(id); }
  rpc(id) {
    const entry = this.entries.get(id);
    if (!entry?.ready || entry.rpc.closed) throw new BridgeError(409, '共享后台已断开，请刷新会话状态');
    return entry.rpc;
  }
  validate(task, thread) {
    if (thread?.id !== task.id || this.core.history.workspace(thread).id !== task.workspaceId ||
        this.core.workspace(task.workspaceId).path !== task.cwd) throw new BridgeError(409, '共享后台会话目录与授权项目不一致');
  }
  async attach(task) {
    if (this.attaching.has(task.id)) return this.attaching.get(task.id);
    const operation = this.attachOnce(task); this.attaching.set(task.id, operation);
    try { return await operation; } finally { this.attaching.delete(task.id); }
  }
  async attachOnce(task) {
    if (!this.core.config.desktopCoordination || !task.sharedThread || this.closed ||
        this.core.sharedSessions.entries.has(task.id) || this.core.desktopSessions.has(task.id)) return false;
    const current = this.entries.get(task.id);
    if (current) {
      try {
        const result = await current.rpc.request('thread/read', { threadId: task.id, includeTurns: false });
        this.validate(task, result.thread);
        if (result.thread.status?.type === 'notLoaded') throw new BridgeError(409, '共享后台已释放会话，请重新打开');
        return true;
      } catch (error) { this.unavailable(current, error.message); throw error; }
    }
    const metadata = await this.core.history.metadata(task.id);
    this.validate(task, metadata.thread);
    if (this.entries.size >= 8) throw new BridgeError(409, '共享连接已达上限，请重启桥接以释放未使用的连接');
    const candidates = [];
    try {
      for (const socket of await this.discover()) {
        const rpc = this.connect(socket); let owns = false;
        try {
          await rpc.initialize(); let cursor, count = 0;
          do {
            const page = await rpc.request('thread/loaded/list', { limit: 100, cursor });
            owns ||= (page.data || []).includes(task.id); cursor = page.nextCursor;
            if ((count += (page.data || []).length) >= 2000) break;
          } while (cursor && !owns);
          if (owns) candidates.push(rpc); else rpc.close();
        } catch { rpc.close(); }
      }
      if (!candidates.length) return false;
      if (candidates.length !== 1) throw new BridgeError(409, '多个后台声明持有此会话，未下发任务');
      const rpc = candidates[0]; const entry = { rpc, task, ready: false, queued: [], observedTurns: new Set() };
      this.entries.set(task.id, entry);
      rpc.on('message', message => {
        if (this.entries.get(task.id) !== entry) return;
        if (!entry.ready) entry.queued.push(message); else this.onMessage(entry, message);
        if (entry.queued.length > 2000) this.unavailable(entry, '共享后台消息积压，请刷新会话');
      });
      rpc.on('stopped', () => this.unavailable(entry, '共享后台连接已断开，原任务可能仍在运行；请刷新后再发送'));
      try {
        // No cwd/model/permission overrides on attach: leave the CLI's current
        // execution policy intact. Pending requests are replayed by App Server.
        const resumed = await rpc.request('thread/resume', { threadId: task.id, excludeTurns: true });
        this.validate(task, resumed.thread);
        if (resumed.thread.status?.type === 'notLoaded') throw new BridgeError(409, '共享会话已卸载，请刷新');
        const page = await rpc.request('thread/turns/list', { threadId: task.id, limit: 2, sortDirection: 'desc', itemsView: 'full' });
        const turns = [...(page.data || [])].reverse();
        const items = turns.flatMap(turn => (turn.items || []).map(item => renderHistoryItem({ turnId: turn.id, item }))).filter(Boolean);
        task.items = items.slice(-160); task.historyCursor = page.nextCursor ? 'turns:' + page.nextCursor : '';
        task.truncated = items.length > 160; task.approvals = [];
        const running = activeTurn(turns); const last = turns.at(-1);
        task.turnId = running?.id || last?.id || '';
        task.status = running ? 'running' : last ? ({ completed: 'completed', interrupted: 'interrupted', failed: 'failed' })[last.status] || 'idle' : 'idle';
        if (resumed.thread.status?.type === 'active' && !running) task.status = 'running';
        task.executionTransport = 'desktop'; // Existing phone wire contract for live shared execution.
        task.executionBackend = 'daemon'; task.desktopConnected = true; task.executionSource = 'computer'; task.error = '';
        this.core.tasks.set(task.id, task); entry.ready = true;
        for (const message of entry.queued.splice(0)) this.onMessage(entry, message);
        this.core.touch(task); return true;
      } catch (error) { this.unavailable(entry, error.message); throw error; }
    } finally {
      for (const rpc of candidates) if (![...this.entries.values()].some(entry => entry.rpc === rpc)) rpc.close();
    }
  }
  onMessage(entry, message) {
    if (message.params?.threadId !== entry.task.id) return; // Other threads and global authentication remain on the PC.
    const task = entry.task; const p = message.params;
    if (message.method === 'thread/closed' || (message.method === 'thread/status/changed' && p.status?.type === 'notLoaded')) {
      this.unavailable(entry, '共享后台已释放会话，请刷新后继续'); return;
    }
    if (message.method === 'turn/started') {
      entry.observedTurns.add(p.turn.id);
      if (entry.observedTurns.size > 20) entry.observedTurns.delete(entry.observedTurns.values().next().value);
      if (p.turn.id !== task.turnId) {
        task.approvals = []; this.core.finalReplies.delete(task.id); delete task.progress;
        task.executionSource = entry.submitting ? 'phone' : 'computer'; task.error = '';
      }
    }
    // Never auto-reject another client's OAuth, MCP elicitation or unknown
    // interactive request. Only the three supported approval types reach phones.
    if (message.id !== undefined && message.method && ![
      'item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/tool/requestUserInput'
    ].includes(message.method)) {
      task.error = '此交互需在电脑端处理：' + String(message.method).slice(0, 160); this.core.touch(task); return;
    }
    this.core.onMessage(message, entry.rpc);
  }
  async start(task, params) {
    const entry = this.entries.get(task.id); const rpc = this.rpc(task.id);
    // Refresh from the same runtime immediately before submission. Common
    // backend arbitrates turn/start; never create a second thread writer.
    const result = await rpc.request('thread/read', { threadId: task.id, includeTurns: false });
    this.validate(task, result.thread);
    if (!['idle', 'systemError'].includes(result.thread.status?.type)) {
      task.status = 'running';
      const error = new BridgeError(409, '电脑端正在执行或等待确认，请刷新后继续');
      error.beforeSubmission = true; throw error;
    }
    entry.submitting = true; task.executionSource = 'phone';
    try {
      const response = await rpc.request('turn/start', { ...params, clientUserMessageId: task.lastRequestId });
      if (!response.turn?.id) { const error = new Error('共享后台未确认本轮编号，请刷新'); error.outcomeUnknown = true; throw error; }
      // The native response can precede its actual start (especially just after
      // an interrupt). Do not let Stop target a merely allocated turn id.
      const deadline = Date.now() + 10000;
      while (!entry.observedTurns.has(response.turn.id) && !rpc.closed && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
      if (!entry.observedTurns.has(response.turn.id)) {
        const error = new Error('后台已受理但尚未确认开始，请刷新执行状态，勿重复发送'); error.outcomeUnknown = true; throw error;
      }
      task.lastRequestConfirmed = true; return response;
    } finally { entry.submitting = false; }
  }
  async interrupt(task) {
    if (!task.turnId) throw new BridgeError(409, '共享任务仍在启动，请刷新后停止');
    const turnId = task.turnId;
    const rpc = this.rpc(task.id);
    const { thread } = await rpc.request('thread/read', { threadId: task.id, includeTurns: false }); this.validate(task, thread);
    if (task.turnId !== turnId) throw new BridgeError(409, '原轮次已结束，请刷新后选择要停止的任务');
    await rpc.request('turn/interrupt', { threadId: task.id, turnId });
    if (busy(task) && task.turnId === turnId) task.status = 'stopping'; this.core.touch(task); return task;
  }
  async answer(task, approval, result) {
    const rpc = this.rpc(task.id);
    const { thread } = await rpc.request('thread/read', { threadId: task.id, includeTurns: false }); this.validate(task, thread);
    // A PC decision can arrive while the metadata request is in flight.
    if (!task.approvals.includes(approval)) throw new BridgeError(409, 'Approval already resolved or expired');
    rpc.send({ id: approval.rpcId, result });
    task.approvals = task.approvals.filter(item => item.id !== approval.id);
    task.status = task.approvals.length ? 'waitingApproval' : 'running'; this.core.touch(task); return task;
  }
  unavailable(entry, reason) {
    if (this.entries.get(entry.task.id) !== entry) return;
    this.entries.delete(entry.task.id); entry.rpc.close();
    const task = entry.task; task.desktopConnected = false; task.approvals = [];
    task.status = 'unknown'; task.error = reason; delete task.progress;
    this.core.finalReplies.delete(task.id); this.core.touch(task);
  }
  close() {
    this.closed = true;
    for (const entry of [...this.entries.values()]) this.unavailable(entry, '桥接已断开，任务仍由共享后台管理');
  }
}
