import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { CodexChatRun, validCodexChatRunId } from './CodexChatTypes';
import { CodexTask } from './CodexTypes';

export const CODEX_CHAT_REVISION_KEY: string = 'codexChatRevision';
export interface CodexChatRunStorage {
  load(id: string): CodexChatRun | null;
  save(run: CodexChatRun): void;
}

export class CodexChatStore implements CodexChatRunStorage {
  private root: string;
  private storage: DataManagerStorage = new DataManagerStorage();
  constructor(filesDir: string) { this.root = filesDir + '/codex/chat-tools'; }
  private path(id: string): string {
    if (!validCodexChatRunId(id)) { throw new Error('Codex 委托编号无效'); }
    return this.root + '/' + id + '.json';
  }
  load(id: string): CodexChatRun | null {
    const run = this.storage.readJson<CodexChatRun | null>(this.path(id), null);
    if (run === null) { return null; }
    if (run.version !== 1 || run.id !== id || !run.sessionId || !run.connectionId ||
      !Array.isArray(run.artifacts) || !Array.isArray(run.files)) { throw new Error('Codex 委托记录损坏'); }
    return run;
  }
  save(run: CodexChatRun): void {
    run.updatedAt = Date.now();
    // Keep delivery/recovery state, not the remote transcript, reasoning or
    // command output. Full items remain in the live delta accumulator only.
    const persisted: CodexChatRun = { version: run.version, id: run.id, sessionId: run.sessionId,
      connectionId: run.connectionId, computerName: run.computerName, origin: run.origin,
      workspaceId: run.workspaceId, workspaceName: run.workspaceName, model: run.model, effort: run.effort,
      taskText: run.taskText, taskId: run.taskId, requestId: run.requestId, submitted: run.submitted,
      turnId: run.turnId, status: run.status, notice: run.notice, answer: run.answer, error: run.error,
      createdAt: run.createdAt, updatedAt: run.updatedAt, artifacts: run.artifacts, files: run.files };
    if (run.task !== undefined) {
      const task: CodexTask = run.task;
      persisted.task = { id: task.id, title: task.title, status: task.status, workspaceId: task.workspaceId,
        model: task.model, effort: task.effort, mode: task.mode, turnId: task.turnId, items: [], approvals: task.approvals,
        updatedAt: task.updatedAt, revision: task.revision, error: task.error, lastRequestId: task.lastRequestId,
        approvalMode: task.approvalMode, progress: task.progress, artifactWarning: task.artifactWarning };
    }
    this.storage.writeJsonAtomic(this.path(run.id), persisted as Object);
    AppStorage.setOrCreate(CODEX_CHAT_REVISION_KEY, (AppStorage.get<number>(CODEX_CHAT_REVISION_KEY) || 0) + 1);
  }
}
