import { common } from '@kit.AbilityKit';
import { AppTheme } from '../../utils/AppTheme';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import { CodexChatService } from './CodexChatService';
import { CodexChatRun, codexChatStatus } from './CodexChatTypes';
import { CodexAnswer, CodexApproval, CodexArtifact, CodexLocalArtifact } from './CodexTypes';
import { CodexArtifactCard } from './CodexArtifactCard';
import { CodexApprovalCard } from './CodexApprovalCard';
import { openCodexArtifact, exportCodexArtifact } from './CodexArtifactActions';

@Component
export struct CodexChatRunCard {
  @Prop @Watch('reload') runId: string = '';
  @StorageProp('codexChatRevision') @Watch('reload') revision: number = 0;
  @State run: CodexChatRun | null = null;
  @State busy: boolean = false;
  @State answering: boolean = false;
  @State expanded: boolean = false;
  @State error: string = '';
  private filesDir: string = '';

  aboutToAppear(): void { this.filesDir = (getContext(this) as common.UIAbilityContext).filesDir; this.reload(); }
  private service(): CodexChatService { return CodexChatService.get(this.filesDir); }
  private reload(): void {
    if (!this.filesDir || !this.runId) { return; }
    try { this.run = this.service().load(this.runId); }
    catch (e) { this.error = (e as Error).message; }
  }
  private files(): CodexArtifact[] { return this.run?.artifacts || []; }
  private approvals(): CodexApproval[] { return this.service().isActive(this.runId) ? this.run?.task?.approvals || [] : []; }
  private local(id: string): CodexLocalArtifact | undefined { return this.run?.files.find((item: CodexLocalArtifact) => item.id === id); }
  private status(): string {
    const status = this.run?.status || '';
    if (status === 'completed' && (this.run?.files.length || 0) < (this.run?.artifacts.length || 0)) {
      return '执行完成 · 部分文件待接收';
    }
    if (['starting', 'running', 'waitingApproval', 'stopping', 'receiving'].includes(status) && !this.service().isActive(this.runId)) {
      return '等待同步 · 远端可能仍在执行';
    }
    return codexChatStatus(status);
  }
  private canStop(): boolean {
    return this.run?.submitted === true && !['completed', 'cancelled', 'failed'].includes(this.run?.status || '');
  }
  private answerText(): string { return this.expanded ? this.run?.answer || '' : (this.run?.answer || '').slice(0, 1000); }
  private async sync(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.error = '';
    try { await this.service().synchronize(this.runId); }
    catch (e) { this.error = (e as Error).message; }
    finally { this.busy = false; this.reload(); }
  }
  private async stop(): Promise<void> {
    this.error = '';
    try { await this.service().stop(this.runId); }
    catch (e) { this.error = (e as Error).message; }
    finally { this.reload(); }
  }
  private async answer(id: string, decision: string, answers: CodexAnswer[]): Promise<void> {
    if (this.answering || (this.busy && !this.service().isActive(this.runId))) { return; }
    this.answering = true;
    this.error = '';
    try { await this.service().answer(this.runId, id, decision, answers); }
    catch (e) { this.error = (e as Error).message + '。请同步确认，勿重复批准。'; }
    finally { this.answering = false; this.reload(); }
  }
  private async open(artifact: CodexArtifact, exportFile: boolean): Promise<void> {
    const saved = this.local(artifact.id);
    if (saved === undefined) { return; }
    this.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (exportFile) {
        if (await exportCodexArtifact(context, saved)) { this.getUIContext().getPromptAction().showToast({ message: '文件已另存' }); }
      } else { await openCodexArtifact(context, saved); }
    } catch (e) { this.error = (e as Error).message || '无法打开文件'; }
  }
  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Image($r('app.media.codex_document')).width(24).height(24).fillColor(AppTheme.text('#5968FF'))
        Column({ space: 4 }) {
          Text('Codex · ' + (this.run?.computerName || '电脑委托')).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#172033')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.status()).fontSize(12).fontColor(AppTheme.text('#5968FF'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.canStop()) {
          Button('停止').fontSize(13).fontColor(AppTheme.text('#D34A54')).backgroundColor(Color.Transparent)
            .height(36).onClick(() => { this.stop(); })
        }
      }.width('100%')
      Text(this.run?.taskText || '').fontSize(13).fontColor(AppTheme.text('#747B87')).maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      if (this.run?.workspaceName) {
        Text(this.run?.workspaceName || '').fontSize(12).fontColor(AppTheme.text('#747B87')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      if (this.run?.notice) {
        Text(this.run?.notice || '').fontSize(12).fontColor(AppTheme.text('#747B87')).width('100%')
      }
      if (this.run?.answer) {
        AiGeneratedBadge({ compact: true })
        Text(this.answerText()).fontSize(14).fontColor(AppTheme.text('#172033')).copyOption(CopyOptions.LocalDevice).width('100%')
        if ((this.run?.answer.length || 0) > 1000) {
          Button(this.expanded ? '收起结果' : '展开结果').fontSize(12).height(30).backgroundColor(Color.Transparent)
            .fontColor(AppTheme.text('#5968FF')).onClick(() => { this.expanded = !this.expanded; })
        }
      }
      ForEach(this.approvals(), (approval: CodexApproval) => {
        CodexApprovalCard({ approval: approval, busy: this.answering,
          onAnswer: (id: string, decision: string, answers: CodexAnswer[]): void => { this.answer(id, decision, answers); } })
      }, (approval: CodexApproval) => approval.id)
      ForEach(this.files(), (artifact: CodexArtifact) => {
        CodexArtifactCard({ artifact: artifact, localPath: this.local(artifact.id)?.localPath || '',
          receiving: this.run?.status === 'receiving', progress: this.run?.notice || '',
          onOpen: (): void => { this.open(artifact, false); }, onExport: (): void => { this.open(artifact, true); },
          onRetry: (): void => { this.sync(); } })
      }, (artifact: CodexArtifact) => artifact.id)
      if (this.error || this.run?.error) {
        Text(this.error || this.run?.error || '').fontSize(12).fontColor(AppTheme.text('#D34A54')).width('100%')
      }
      if (this.run?.submitted && !this.service().isActive(this.runId)) {
        Button(this.busy ? '正在同步' : '同步结果').fontSize(13).height(36).enabled(!this.busy)
          .backgroundColor(AppTheme.background('#EEF0FF')).fontColor(AppTheme.text('#5968FF')).onClick(() => { this.sync(); })
      }
    }.width('96%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(20)
      .backgroundColor(AppTheme.background('#F6F7FB')).border({ width: 1, color: AppTheme.border('#ECEEF3') })
      .margin({ top: 20, bottom: 12 })
  }
}
