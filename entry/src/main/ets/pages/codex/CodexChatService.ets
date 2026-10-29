import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { ChatSessionStorage } from '../../utils/ChatSessionStorage';
import { CodexClient } from './CodexClient';
import { CodexCredentialStore } from './CodexCredentialStore';
import { CodexArtifactStore, validateCodexArtifact } from './CodexArtifactStore';
import { CodexChatStore } from './CodexChatStore';
import { CodexChatExecution, CodexChatRequest, CodexChatResult, CodexChatRun, CodexChatTarget, codexChatResult,
  codexChatFinalAnswer, validCodexChatRunId } from './CodexChatTypes';
import { CodexAnswer, CodexApproval, CodexArtifact, CodexEnvelope, CodexLocalArtifact, CodexModel, CodexWorkspace,
  CODEX_MAX_FILE_BYTES, codexTaskBusy, codexExecutionNotice, mergeCodexTask } from './CodexTypes';

class CodexChatOperation {
  client: CodexClient = new CodexClient();
  run: CodexChatRun;
  info: CodexEnvelope = {};
  paused: boolean = false;
  stopRequested: boolean = false;
  stopSent: boolean = false;
  stopAt: number = 0;
  answering: boolean = false;
  constructor(run: CodexChatRun) { this.run = run; }
}

function safeTaskId(value: string): boolean { return /^[A-Za-z0-9_-]{1,128}$/.test(value); }

// A delegation owns a separate remote session. Models never choose connection
// secrets, arbitrary task IDs, filesystem upload paths or execution permissions.
export class CodexChatService {
  private static instances: Map<string, CodexChatService> = new Map();
  private filesDir: string;
  private store: CodexChatStore;
  private active: Map<string, CodexChatOperation> = new Map();
  private sessions: Set<string> = new Set();

  private constructor(filesDir: string) { this.filesDir = filesDir; this.store = new CodexChatStore(filesDir); }
  static get(filesDir: string): CodexChatService {
    let service = CodexChatService.instances.get(filesDir);
    if (service === undefined) { service = new CodexChatService(filesDir); CodexChatService.instances.set(filesDir, service); }
    return service;
  }
  isActive(id: string): boolean { return this.active.has(id); }
  load(id: string): CodexChatRun | null { return this.store.load(id); }
  private save(operation: CodexChatOperation): void { this.store.save(operation.run); }
  private requireCurrent(operation: CodexChatOperation): void {
    if (operation.paused || !ChatSessionStorage.sessionExists(this.filesDir, operation.run.sessionId)) {
      throw new Error('聊天已关闭或删除，远端状态待同步');
    }
  }
  private async connect(operation: CodexChatOperation): Promise<void> {
    this.requireCurrent(operation);
    const connection = await CodexCredentialStore.load(operation.run.connectionId);
    if (connection === null || (operation.run.origin && operation.run.origin !== connection.origin)) {
      throw new Error('原电脑连接已删除或身份已变更，请先在 Codex 页重新配对');
    }
    operation.client.configure(connection);
    operation.run.origin = connection.origin;
    operation.info = await operation.client.call('/v1/info');
    this.requireCurrent(operation);
    if (!operation.info.ready || operation.info.permissionSettingsSupported !== true ||
      operation.info.artifactsSupported !== true) { throw new Error('请更新并启动 PC Codex 连接器，需支持权限设置和文件回传'); }
    operation.client.setArtifactChunkBytes(operation.info.artifactChunkBytes || 0);
  }

  async execute(request: CodexChatRequest, execution: CodexChatExecution): Promise<CodexChatResult> {
    if (this.sessions.has(execution.sessionId)) { throw new Error('本聊天已有 Codex 委托，请等待或停止后再试'); }
    this.sessions.add(execution.sessionId);
    let operation: CodexChatOperation | null = null;
    try {
      const previous = request.continueRunId ? this.store.load(request.continueRunId) : null;
      if (request.continueRunId && (previous === null || previous.sessionId !== execution.sessionId ||
        previous.status !== 'completed' || !previous.submitted || !safeTaskId(previous.taskId))) {
        throw new Error('只能继续本聊天中已完成的 Codex 委托；状态不明时请先同步原卡片');
      }
      const target: CodexChatTarget | null = previous !== null ? { connectionId: previous.connectionId, workspaceId: previous.workspaceId } :
        await execution.selectTarget(request.task, execution.imagePaths.length);
      if (execution.isCancelled() || target === null) {
        return { ok: false, status: 'rejected', runId: '', computer: '', summary: '', files: [], received: 0, error: '用户取消委托' };
      }
      const run: CodexChatRun = { version: 1, id: util.generateRandomUUID(true), sessionId: execution.sessionId,
        connectionId: target.connectionId, computerName: previous?.computerName || '', origin: previous?.origin || '',
        workspaceId: target.workspaceId, workspaceName: previous?.workspaceName || '', model: '', effort: '',
        taskText: request.task, taskId: previous?.taskId || '', requestId: util.generateRandomUUID(true), submitted: false,
        turnId: '', status: 'starting', notice: '正在连接所选电脑', answer: '', error: '',
        createdAt: Date.now(), updatedAt: Date.now(), artifacts: [], files: [] };
      operation = new CodexChatOperation(run); this.active.set(run.id, operation);
      this.save(operation); execution.onCreated(run);
      await this.connect(operation);
      const workspace = operation.info.workspaces?.find((item: CodexWorkspace) => item.id === run.workspaceId);
      if (workspace === undefined) { throw new Error('电脑端已移除此工作目录，请重新选择'); }
      run.workspaceName = workspace.name; run.computerName = operation.info.name || run.computerName || 'Codex 电脑';
      const models = operation.info.models || [];
      const model: CodexModel | undefined = models.find((item: CodexModel) => item.isDefault === true) || models[0];
      if (model === undefined) { throw new Error('电脑端尚未提供可用的 Codex 模型'); }
      run.model = model.model || model.id; run.effort = model.defaultReasoningEffort || '';
      this.requireCurrent(operation);
      if (execution.isCancelled() || operation.stopRequested) { run.status = 'cancelled'; this.save(operation); return codexChatResult(run); }
      if (previous !== null) {
        const envelope = await operation.client.call('/v1/tasks/' + run.taskId);
        const task = envelope.task;
        if (task === undefined || task.id !== run.taskId || task.workspaceId !== run.workspaceId ||
          task.lastRequestId !== previous.requestId || task.turnId !== previous.turnId || task.status !== 'completed') {
          throw new Error('原会话已被其他端更新或仍在执行，请同步原结果或新建委托');
        }
      } else {
        const envelope = await operation.client.call('/v1/tasks', { workspaceId: run.workspaceId,
          model: run.model, effort: run.effort, mode: 'workspace-write', approvalMode: 'ask' });
        if (envelope.task === undefined || !safeTaskId(envelope.task.id)) { throw new Error('电脑未返回有效的新会话'); }
        run.taskId = envelope.task.id;
      }
      this.save(operation);
      const attachments = await this.uploadImages(operation, execution.imagePaths);
      this.requireCurrent(operation);
      if (execution.isCancelled() || operation.stopRequested) { run.status = 'cancelled'; this.save(operation); return codexChatResult(run); }
      // Persist the request ID BEFORE POST. An ambiguous response is reconciled
      // by reads only; never automatically resend a turn or create a replacement.
      run.submitted = true; run.notice = '任务正在下发，若断线将同步原任务'; this.save(operation);
      try {
        const envelope = await operation.client.call('/v1/tasks/' + run.taskId + '/turns', {
          requestId: run.requestId, text: request.task + '\n\n交付要求：完成后简述结果和验证情况；只为最终交付文件提供绝对路径 Markdown 链接，成品优先保存到工作目录 outputs/。不要链接临时文件、凭据或依赖。',
          attachments: attachments, model: run.model, effort: run.effort, mode: 'workspace-write', approvalMode: 'ask' });
        this.acceptTask(operation, envelope);
      } catch (e) {
        run.notice = '下发响应未确认，正在查询原任务'; this.save(operation);
        this.requireCurrent(operation);
        this.acceptTask(operation, await operation.client.call('/v1/tasks/' + run.taskId));
      }
      await this.follow(operation, execution.isCancelled);
      return codexChatResult(run);
    } catch (e) {
      if (operation !== null) {
        operation.run.status = operation.run.submitted ? 'disconnected' : operation.stopRequested ? 'cancelled' : 'failed';
        operation.run.error = (e as Error).message || 'Codex 委托失败';
        try { this.save(operation); } catch (storageError) { operation.run.error += '（手机状态保存失败）'; }
        return codexChatResult(operation.run);
      }
      return { ok: false, status: 'failed', runId: '', computer: '', summary: '', files: [], received: 0, error: (e as Error).message };
    } finally {
      if (operation !== null) {
        operation.client.close(); this.active.delete(operation.run.id);
        try { this.save(operation); } catch (e) { /* The returned outcome must survive a full local disk. */ }
      }
      this.sessions.delete(execution.sessionId);
    }
  }

  private acceptTask(operation: CodexChatOperation, envelope: CodexEnvelope): void {
    const run = operation.run;
    const task = mergeCodexTask(run.task || null, envelope);
    if (task === undefined) {
      if (envelope.unchanged && run.task !== undefined) {
        const notice = codexExecutionNotice(run.task, Date.now());
        if (notice !== run.notice) { run.notice = notice; this.save(operation); }
        return;
      }
      throw new Error('未收到任务状态');
    }
    if (task.id !== run.taskId || task.workspaceId !== run.workspaceId || task.lastRequestId !== run.requestId ||
      task.status === 'unknown' || (run.turnId && task.turnId !== run.turnId)) {
      throw new Error('远端执行状态尚未确认或会话已变化，请手动同步，勿重复下发');
    }
    if (run.task !== undefined && task.revision < run.task.revision) { return; }
    run.task = task; run.turnId = task.turnId || run.turnId;
    run.status = task.status === 'interrupted' ? 'cancelled' : task.status;
    run.notice = codexExecutionNotice(task, Date.now()); run.error = task.error || '';
    run.answer = codexChatFinalAnswer(task, run.turnId);
    const artifacts = (task.artifacts || []).filter((item: CodexArtifact) => !!run.turnId && item.turnId === run.turnId);
    artifacts.forEach((artifact: CodexArtifact): void => {
      validateCodexArtifact(artifact);
      if (typeof artifact.mimeType !== 'string' || artifact.mimeType.length > 200) { throw new Error('交付文件类型无效'); }
    });
    if (artifacts.length > 24 || artifacts.reduce((sum: number, file: CodexArtifact) => sum + file.size, 0) > 512 * 1024 * 1024) {
      throw new Error('本次交付超过 24 个文件或 512 MB，请在电脑端检查');
    }
    run.artifacts = artifacts;
    this.save(operation);
  }

  private async follow(operation: CodexChatOperation, cancelled: () => boolean): Promise<void> {
    const deadline = Date.now() + 30 * 60000;
    let failures: number = 0;
    while (true) {
      this.requireCurrent(operation);
      if (cancelled()) { operation.stopRequested = true; }
      if (operation.stopRequested && !operation.stopSent) { await this.sendStop(operation); }
      const run = operation.run;
      if (run.task !== undefined && !codexTaskBusy(run.task.status)) {
        if (!['completed', 'failed', 'interrupted'].includes(run.task.status) || !run.turnId) {
          throw new Error('远端尚未返回本次执行的明确结束状态，请稍后同步');
        }
        if (run.task.status === 'completed') { await this.receiveFiles(operation); }
        return;
      }
      if (Date.now() > deadline || (operation.stopAt > 0 && Date.now() - operation.stopAt > 20000)) {
        throw new Error('远端任务尚未确认结束，可在本条卡片继续同步或请求停止');
      }
      try {
        const suffix = operation.info.taskUpdatesSupported === true && run.task !== undefined ?
          '?revision=' + run.task.revision + '&waitMs=12000' + (operation.info.taskDeltaSupported === true ? '&sync=delta' : '') : '';
        const envelope = await operation.client.call('/v1/tasks/' + run.taskId + suffix);
        this.requireCurrent(operation);
        try { this.acceptTask(operation, envelope); }
        catch (e) {
          if (envelope.taskDelta === undefined) { throw e as Error; }
          this.acceptTask(operation, await operation.client.call('/v1/tasks/' + run.taskId));
        }
        failures = 0;
        if (!suffix) { await this.delay(1200); }
      } catch (e) {
        this.requireCurrent(operation);
        if (operation.stopRequested && !operation.stopSent) { continue; }
        failures++;
        if (failures >= 3) { throw e as Error; }
        run.notice = '连接不稳定，正在同步原任务（' + failures + '/3）'; this.save(operation);
        await this.delay(failures * 1500);
      }
    }
  }

  private async uploadImages(operation: CodexChatOperation, paths: string[]): Promise<string[]> {
    if (paths.length > 6) { throw new Error('一次最多委托 6 张当前消息的图片'); }
    const ids: string[] = [];
    const root = ChatSessionStorage.sessionAssetsDir(this.filesDir, operation.run.sessionId) + '/';
    for (const uri of paths) {
      const path = uri.startsWith('file://') ? uri.substring(7) : uri;
      this.requireCurrent(operation);
      if (operation.stopRequested) { throw new Error('已取消图片发送'); }
      const name = path.substring(root.length);
      if (!path.startsWith(root) || !name || name.includes('/') || name.includes('\\') || name === '.' || name === '..') {
        throw new Error('只能发送当前聊天中由用户附加的图片');
      }
      const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
      try {
        const size = (await fileIo.stat(file.fd)).size;
        if (size < 1 || size > CODEX_MAX_FILE_BYTES) { throw new Error('单张图片需小于 8 MB'); }
        const buffer = new ArrayBuffer(size); let offset: number = 0;
        while (offset < size) {
          const part = new ArrayBuffer(size - offset);
          const count = await fileIo.read(file.fd, part, { offset: offset, length: part.byteLength });
          if (count <= 0) { throw new Error('图片读取不完整'); }
          new Uint8Array(buffer).set(new Uint8Array(part, 0, count), offset); offset += count;
        }
        this.requireCurrent(operation);
        const envelope = await operation.client.call('/v1/attachments', { workspaceId: operation.run.workspaceId,
          name: name, image: true, base64: new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer)) });
        if (envelope.attachment === undefined) { throw new Error('电脑未确认图片上传'); }
        ids.push(envelope.attachment.id);
      } finally { await fileIo.close(file); }
    }
    return ids;
  }

  private async receiveFiles(operation: CodexChatOperation): Promise<void> {
    const run = operation.run;
    run.status = 'receiving'; this.save(operation);
    const store = await CodexArtifactStore.create(this.filesDir, run.origin, run.taskId);
    const failures: string[] = [];
    for (const artifact of run.artifacts) {
      this.requireCurrent(operation);
      if (operation.stopRequested) { throw new Error('文件接收已停止，可稍后同步结果'); }
      try {
        const saved = await store.receive(run.taskId, artifact, operation.client,
          (): boolean => !operation.paused && !operation.stopRequested,
          (received: number, total: number): void => {
            run.notice = '接收 ' + artifact.name + ' · ' + Math.floor(received * 100 / total) + '%'; this.save(operation);
          });
        run.files = run.files.filter((item: CodexLocalArtifact) => item.id !== saved.id).concat([saved]); this.save(operation);
      } catch (e) { failures.push(artifact.name + '：' + (e as Error).message); }
    }
    run.status = 'completed'; run.notice = '';
    run.error = [run.task?.artifactWarning || '', failures.join('\n')].filter((item: string) => !!item).join('\n');
    this.save(operation);
  }
  private delay(ms: number): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve, ms); }); }

  private async sendStop(operation: CodexChatOperation): Promise<void> {
    if (!operation.run.submitted || !operation.run.taskId) { return; }
    this.requireCurrent(operation);
    operation.stopSent = true; operation.stopAt = Date.now(); operation.run.status = 'stopping'; this.save(operation);
    try {
      this.acceptTask(operation, await operation.client.call('/v1/tasks/' + operation.run.taskId + '/interrupt', { id: '', decision: '', answers: [] }));
    } catch (e) { throw new Error('停止请求未确认，远端可能仍在运行，请同步后重试停止'); }
  }
  async stop(id: string): Promise<void> {
    const operation = this.active.get(id);
    if (operation !== undefined) { operation.stopRequested = true; operation.client.cancelTaskUpdates(); return; }
    await this.synchronize(id, true);
  }
  stopSession(sessionId: string): void {
    this.active.forEach((operation: CodexChatOperation) => {
      if (operation.run.sessionId === sessionId) { operation.stopRequested = true; operation.client.cancelTaskUpdates(); }
    });
  }
  detach(): void {
    this.active.forEach((operation: CodexChatOperation) => { operation.paused = true; operation.client.close(); });
  }
  async answer(id: string, approvalId: string, decision: string, answers: CodexAnswer[]): Promise<void> {
    const operation = this.active.get(id);
    if (operation === undefined || operation.answering || operation.paused || operation.stopRequested) { throw new Error('请先同步当前委托，再处理审批'); }
    this.requireCurrent(operation);
    if (!operation.run.task?.approvals.some((item: CodexApproval) => item.id === approvalId)) { throw new Error('此审批已过期，请同步'); }
    operation.answering = true;
    try {
      const envelope = await operation.client.call('/v1/tasks/' + operation.run.taskId + '/approvals', { id: approvalId, decision: decision, answers: answers });
      // A concurrent long poll may already have applied a newer revision.
      if ((envelope.task?.revision || 0) >= (operation.run.task?.revision || 0)) { this.acceptTask(operation, envelope); }
    } finally { operation.answering = false; }
  }
  async synchronize(id: string, stop: boolean = false): Promise<void> {
    if (!validCodexChatRunId(id) || this.active.has(id)) { return; }
    const run = this.store.load(id);
    if (run === null || !run.submitted || !safeTaskId(run.taskId)) { throw new Error('此委托尚未下发，无法同步'); }
    if (this.sessions.has(run.sessionId)) { throw new Error('本聊天已有委托执行中，请稍后同步'); }
    this.sessions.add(run.sessionId);
    const operation = new CodexChatOperation(run); this.active.set(id, operation);
    try {
      await this.connect(operation);
      this.acceptTask(operation, await operation.client.call('/v1/tasks/' + run.taskId));
      operation.stopRequested = stop && codexTaskBusy(run.task?.status || '');
      await this.follow(operation, (): boolean => false);
    } catch (e) { run.status = 'disconnected'; run.error = (e as Error).message; this.save(operation); throw e as Error; }
    finally { operation.client.close(); this.active.delete(id); this.sessions.delete(run.sessionId); this.save(operation); }
  }
}
