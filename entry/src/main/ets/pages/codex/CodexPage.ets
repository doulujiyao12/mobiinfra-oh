import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { AppTheme } from '../../utils/AppTheme';
import { PrivacyConsent, PRIVACY_STATE_KEY } from '../../utils/PrivacyConsent';
import { AppHeader } from '../../components/AppHeader';
import { FrostedPage } from '../../components/FrostedPage';
import { MarkdownView } from '../../components/MarkdownView';
import { PrivacyConsentDialog } from '../../components/PrivacyConsentDialog';
import { CodexClient } from './CodexClient';
import { CodexCredentialStore } from './CodexCredentialStore';
import { CodexApprovalCard } from './CodexApprovalCard';
import {
  CODEX_MAX_FILE_BYTES, CodexConnection, CodexModel, CodexWorkspace, CodexTask, CodexTaskSummary,
  CodexAttachment, CodexItem, CodexApproval, CodexAnswer, CodexEffort,
  normalizeCodexOrigin, codexTaskBusy, codexStatusLabel, CodexPairingBundle, validateCodexPairing
} from './CodexTypes';

@Component
export struct CodexPage {
  @Prop @Watch('activeChanged') active: boolean = false;
  @Prop navigationBottomInset: number = 0;
  @StorageProp(PRIVACY_STATE_KEY) @Watch('privacyChanged') private privacyState: string = 'unselected';
  @State private originInput: string = '';
  @State private tokenInput: string = '';
  @State private pairingInput: string = '';
  @State private remember: boolean = true;
  @State private hasSavedConnection: boolean = false;
  @State private connected: boolean = false;
  @State private serverName: string = '';
  @State private connectionOpen: boolean = true;
  @State private historyOpen: boolean = false;
  @State private workspaces: CodexWorkspace[] = [];
  @State private models: CodexModel[] = [];
  @State private workspaceId: string = '';
  @State private modelId: string = '';
  @State private effort: string = '';
  @State private mode: string = 'read-only';
  @State private tasks: CodexTaskSummary[] = [];
  @State private task: CodexTask | null = null;
  @State private draft: string = '';
  @State private attachments: CodexAttachment[] = [];
  @State private busy: boolean = false;
  @State private errorText: string = '';
  @State private networkText: string = '';
  @State private expandedTools: string[] = [];
  @State private followOutput: boolean = true;
  private client: CodexClient = new CodexClient();
  private scroller: Scroller = new Scroller();
  private timer: number = -1;
  private epoch: number = 0;
  private polling: boolean = false;
  private pollCount: number = 0;
  private retryDelay: number = 2000;
  private pendingRequestId: string = '';
  private pairedConnection: CodexConnection | null = null;

  aboutToAppear(): void { this.restoreAddress(); }
  aboutToDisappear(): void { this.disconnect(); }

  private async restoreAddress(): Promise<void> {
    try {
      const saved = await CodexCredentialStore.load();
      if (saved !== null) { this.originInput = saved.origin; this.hasSavedConnection = true; }
    } catch (e) { this.errorText = (e as Error).message; }
  }
  private activeChanged(): void {
    this.clearTimer();
    if (this.active && this.connected) { this.schedulePoll(10); }
  }
  private privacyChanged(): void {
    if (this.privacyState !== 'accepted') { this.disconnect(); }
  }
  private clearTimer(): void { if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; } }
  private schedulePoll(delay: number = 2000): void {
    this.clearTimer();
    if (this.active && this.connected) {
      this.timer = setTimeout(() => { this.poll(); }, delay);
    }
  }
  private disconnect(): void {
    this.epoch++; this.clearTimer(); this.client.close();
    this.connected = false; this.connectionOpen = true; this.task = null;
    this.tasks = []; this.attachments = []; this.tokenInput = ''; this.pendingRequestId = '';
    this.pairedConnection = null; this.pairingInput = '';
    this.draft = ''; this.models = []; this.workspaces = []; this.serverName = ''; this.expandedTools = [];
    this.networkText = ''; this.busy = false; this.polling = false;
  }
  private async connect(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.errorText = '';
    const epoch = ++this.epoch;
    try {
      PrivacyConsent.requireAccepted();
      const origin = normalizeCodexOrigin(this.originInput);
      let token = this.tokenInput.trim();
      let caCertificate = '';
      if (this.pairedConnection !== null && this.pairedConnection.origin === origin && !token) {
        token = this.pairedConnection.token; caCertificate = this.pairedConnection.caCertificate || '';
      }
      if (!token) {
        const saved = await CodexCredentialStore.load();
        if (saved === null || saved.origin !== origin) { throw new Error('请输入此服务器的桥接令牌'); }
        token = saved.token; caCertificate = saved.caCertificate || '';
      }
      const connection: CodexConnection = { origin: origin, token: token, caCertificate: caCertificate };
      if (epoch !== this.epoch) { return; }
      this.client.configure(connection);
      const info = await this.client.call('/v1/info');
      if (epoch !== this.epoch) { return; }
      if (info.protocol !== 1 || !info.ready || !info.models?.length || !info.workspaces?.length) {
        throw new Error('桥接协议不兼容，或服务器没有可用模型/工作目录');
      }
      if (this.remember) {
        await CodexCredentialStore.save(connection); this.hasSavedConnection = true;
      } else {
        await CodexCredentialStore.forget(); this.hasSavedConnection = false;
      }
      if (epoch !== this.epoch) { return; }
      this.originInput = origin; this.tokenInput = ''; this.serverName = info.name || 'Codex';
      this.models = info.models; this.workspaces = info.workspaces;
      this.workspaceId = this.workspaces[0].id;
      this.chooseModel((this.models.find((m: CodexModel) => m.isDefault) ?? this.models[0]).model);
      this.task = null; this.attachments = []; this.connected = true; this.connectionOpen = false;
      await this.refreshTasks(); this.retryDelay = 2000; this.schedulePoll();
    } catch (e) {
      if (epoch === this.epoch) {
        this.client.close(); this.connected = false;
        this.errorText = '连接失败：' + ((e as Error).message || '请检查网络、HTTPS 证书和电脑端服务');
      }
    } finally { if (epoch === this.epoch) { this.busy = false; } }
  }
  private async forget(): Promise<void> {
    this.disconnect();
    try {
      await CodexCredentialStore.forget(); this.hasSavedConnection = false; this.originInput = '';
      this.errorText = '';
    } catch (e) { this.errorText = '未能删除安全凭据，请重试'; }
  }
  private async importPairingFile(): Promise<void> {
    if (this.busy) { return; }
    let file: fileIo.File | null = null;
    try {
      const options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 1;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const uris = await new picker.DocumentViewPicker(context).select(options);
      if (!uris.length) { return; }
      file = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      const size = (await fileIo.stat(file.fd)).size;
      if (size <= 0 || size > 8192) { throw new Error('配对文件无效，文件上限为 8 KiB'); }
      const bytes = new ArrayBuffer(size);
      if (await fileIo.read(file.fd, bytes) !== size) { throw new Error('配对文件读取不完整'); }
      this.pairingInput = new util.TextDecoder().decodeWithStream(new Uint8Array(bytes));
      await this.pairFromInput();
    } catch (e) { this.errorText = (e as Error).message; }
    finally { if (file !== null) { try { await fileIo.close(file); } catch (e) { } } }
  }
  private async pairFromInput(): Promise<void> {
    if (this.busy) { return; }
    this.errorText = '';
    try {
      let raw = this.pairingInput.trim();
      if (raw.startsWith('CLAWMATE-CODEX-PAIR:')) {
        let encoded = raw.substring('CLAWMATE-CODEX-PAIR:'.length).replace(/-/g, '+').replace(/_/g, '/');
        while (encoded.length % 4 !== 0) { encoded += '='; }
        raw = new util.TextDecoder().decodeWithStream(new util.Base64Helper().decodeSync(encoded));
      }
      if (raw.length > 8192) { throw new Error('配对内容过长'); }
      const bundle = JSON.parse(raw) as CodexPairingBundle;
      validateCodexPairing(bundle);
      PrivacyConsent.requireAccepted();
      const confirmed = await new Promise<boolean>((resolve) => {
        this.getUIContext().showAlertDialog({ title: '连接自己的电脑',
          message: bundle.name + '\n' + bundle.origin + '\n\n请确认这份配对信息来自你自己的 PC 应用。连接后可以向该电脑下发任务。',
          autoCancel: false,
          primaryButton: { value: '取消', action: () => { resolve(false); } },
          secondaryButton: { value: '确认配对', action: () => { resolve(true); } }
        });
      });
      if (!confirmed) { return; }
      this.busy = true;
      this.pairedConnection = await this.client.pair(bundle);
      this.originInput = bundle.origin; this.tokenInput = ''; this.pairingInput = '';
      this.busy = false;
      await this.connect();
    } catch (e) { this.errorText = (e as Error).message || '配对失败，请在 PC 应用中重新生成'; }
    finally { this.busy = false; }
  }
  private chooseModel(id: string): void {
    this.modelId = id;
    this.effort = this.models.find((m: CodexModel) => m.model === id)?.defaultReasoningEffort ?? '';
  }
  private efforts(): CodexEffort[] {
    return this.models.find((m: CodexModel) => m.model === this.modelId)?.supportedReasoningEfforts ?? [];
  }
  private running(): boolean { return this.task !== null && codexTaskBusy(this.task.status); }
  private taskItems(): CodexItem[] { return this.task?.items ?? []; }
  private approvals(): CodexApproval[] { return this.task?.approvals ?? []; }
  private selectIndex(values: string[], selected: string): number { return Math.max(0, values.indexOf(selected)); }
  private async refreshTasks(): Promise<void> {
    const epoch = this.epoch;
    const result = await this.client.call('/v1/tasks');
    if (epoch === this.epoch) { this.tasks = result.tasks ?? []; }
  }
  private applyTask(task: CodexTask): void {
    if (this.task !== null && this.task.id === task.id && task.revision < this.task.revision) { return; }
    this.task = task;
    if (this.pendingRequestId && task.lastRequestId === this.pendingRequestId) {
      this.pendingRequestId = ''; this.draft = ''; this.attachments = [];
    }
    if (this.followOutput) {
      setTimeout(() => { if (this.active) { this.scroller.scrollEdge(Edge.Bottom); } }, 50);
    }
  }
  private async poll(): Promise<void> {
    if (!this.active || !this.connected || this.polling) { return; }
    if (this.busy) { this.schedulePoll(); return; }
    this.polling = true;
    const epoch = this.epoch;
    const taskId = this.task?.id ?? '';
    try {
      if (taskId) {
        const result = await this.client.call('/v1/tasks/' + taskId + '?revision=' + this.task!.revision);
        if (epoch === this.epoch && !this.busy && this.task?.id === taskId && result.task !== undefined) { this.applyTask(result.task); }
      }
      if (++this.pollCount % 5 === 0 || !taskId) { await this.refreshTasks(); }
      if (epoch === this.epoch) { this.networkText = ''; this.retryDelay = 2000; }
    } catch (e) {
      if (epoch === this.epoch) {
        this.networkText = '连接暂时中断，正在重试。电脑端任务会继续运行。';
        this.retryDelay = Math.min(this.retryDelay * 2, 30000);
      }
    } finally {
      this.polling = false;
      if (epoch === this.epoch) { this.schedulePoll(this.retryDelay); }
    }
  }
  private newTask(): void {
    if (this.busy) { return; }
    this.task = null; this.attachments = []; this.pendingRequestId = ''; this.errorText = '';
    this.draft = '';
    this.expandedTools = []; this.historyOpen = false;
  }
  private async selectTask(id: string): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.errorText = '';
    const epoch = this.epoch;
    try {
      const result = await this.client.call('/v1/tasks/' + id);
      if (epoch === this.epoch && result.task !== undefined) {
        this.task = result.task; this.workspaceId = result.task.workspaceId;
        this.modelId = result.task.model; this.effort = result.task.effort; this.mode = result.task.mode;
        this.attachments = []; this.pendingRequestId = ''; this.expandedTools = []; this.historyOpen = false;
      }
    } catch (e) { if (epoch === this.epoch) { this.errorText = (e as Error).message; } }
    finally { if (epoch === this.epoch) { this.busy = false; } }
  }
  private async send(): Promise<void> {
    if (this.busy || this.running() || (!this.draft.trim() && !this.attachments.length)) { return; }
    this.busy = true; this.errorText = '';
    const epoch = this.epoch;
    try {
      if (this.task === null) {
        const result = await this.client.call('/v1/tasks', { workspaceId: this.workspaceId,
          model: this.modelId, effort: this.effort, mode: this.mode });
        if (epoch !== this.epoch || result.task === undefined) { return; }
        this.task = result.task;
      }
      if (!this.pendingRequestId) { this.pendingRequestId = util.generateRandomUUID(true); }
      const result = await this.client.call('/v1/tasks/' + this.task.id + '/turns', {
        requestId: this.pendingRequestId, text: this.draft, attachments: this.attachments.map((a: CodexAttachment) => a.id),
        model: this.modelId, effort: this.effort
      });
      if (epoch === this.epoch && result.task !== undefined) {
        this.draft = ''; this.attachments = []; this.pendingRequestId = ''; this.applyTask(result.task);
        await this.refreshTasks();
      }
    } catch (e) {
      if (epoch === this.epoch) { this.errorText = ((e as Error).message || '发送失败') + '。请刷新任务状态确认；重试会沿用同一请求编号。'; }
    } finally { if (epoch === this.epoch) { this.busy = false; this.schedulePoll(500); } }
  }
  private async stop(): Promise<void> {
    if (this.task === null || this.busy) { return; }
    await this.taskAction('interrupt');
  }
  private async taskAction(action: string, approvalId: string = '', decision: string = '', answers: CodexAnswer[] = []): Promise<void> {
    if (this.task === null || this.busy) { return; }
    this.busy = true; this.errorText = '';
    const epoch = this.epoch;
    try {
      const result = await this.client.call('/v1/tasks/' + this.task.id + '/' + action,
        { id: approvalId, decision: decision, answers: answers });
      if (epoch === this.epoch && result.task !== undefined) { this.applyTask(result.task); }
    } catch (e) { if (epoch === this.epoch) { this.errorText = (e as Error).message; } }
    finally { if (epoch === this.epoch) { this.busy = false; this.schedulePoll(500); } }
  }
  private async pickAttachment(image: boolean): Promise<void> {
    if (this.busy || !this.connected || this.running() || this.attachments.length >= 6) { return; }
    this.busy = true; this.errorText = '';
    const epoch = this.epoch;
    let file: fileIo.File | null = null;
    try {
      let uris: string[] = [];
      if (image) {
        const options = new photoAccessHelper.PhotoSelectOptions();
        options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE; options.maxSelectNumber = 1;
        uris = (await new photoAccessHelper.PhotoViewPicker().select(options)).photoUris;
      } else {
        const options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 1;
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        uris = await new picker.DocumentViewPicker(context).select(options);
      }
      if (!uris.length || epoch !== this.epoch) { return; }
      PrivacyConsent.requireAccepted();
      file = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      const size = (await fileIo.stat(file.fd)).size;
      if (size <= 0 || size > CODEX_MAX_FILE_BYTES) { throw new Error('单个附件需大于 0 且不超过 8 MiB'); }
      const buffer = new ArrayBuffer(size);
      let offset = 0;
      while (offset < size) {
        const chunk = new ArrayBuffer(Math.min(256 * 1024, size - offset));
        const count = await fileIo.read(file.fd, chunk, { offset: offset, length: chunk.byteLength });
        if (count <= 0) { throw new Error('文件读取不完整，请重新选择'); }
        new Uint8Array(buffer).set(new Uint8Array(chunk, 0, count), offset); offset += count;
      }
      const name = new fileUri.FileUri(uris[0]).name || (image ? 'image' : 'file');
      const result = await this.client.call('/v1/uploads', { workspaceId: this.workspaceId, name: name,
        base64: new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer)), image: image });
      if (epoch === this.epoch && result.attachment !== undefined) {
        this.attachments = this.attachments.concat([result.attachment]);
      }
    } catch (e) { if (epoch === this.epoch) { this.errorText = (e as Error).message || '附件选择或上传失败'; } }
    finally {
      if (file !== null) { try { await fileIo.close(file); } catch (e) { } }
      if (epoch === this.epoch) { this.busy = false; this.schedulePoll(); }
    }
  }
  private toggleTool(id: string): void {
    this.expandedTools = this.expandedTools.includes(id) ? this.expandedTools.filter((v: string) => v !== id) : this.expandedTools.concat([id]);
  }

  @Builder private ConnectionForm() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('⌘').fontSize(30).fontColor(AppTheme.text('#5968FF'))
        Column({ space: 4 }) {
          Text('把电脑上的 Codex 带到手机').fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
          Text('局域网 PC · 云端服务器').fontSize(12).fontColor(AppTheme.text('#747B87'))
        }.alignItems(HorizontalAlign.Start)
      }.width('100%')
      Text('安装 ClawMate Codex 电脑端，登录并选择项目，再导入电脑端生成的配对文件。无需 npm、域名或手工证书。')
        .fontSize(13).lineHeight(20).fontColor(AppTheme.text('#697386')).width('100%')
      Button('导入电脑配对文件').width('100%').enabled(!this.busy)
        .onClick(() => { this.importPairingFile(); })
      TextArea({ placeholder: '也可粘贴电脑端的一次性配对信息', text: this.pairingInput })
        .height(60).maxLength(8192).onChange((v: string) => { this.pairingInput = v; })
      if (this.pairingInput.trim().length > 0) {
        Button('使用配对信息连接').enabled(!this.busy).onClick(() => { this.pairFromInput(); })
      }
      Text('已有服务器：也可手动填写 HTTPS 地址和桥接令牌').fontSize(11).fontColor(AppTheme.text('#747B87'))
      TextInput({ placeholder: 'https://codex.example.com:8787', text: this.originInput })
        .type(InputType.Normal).maxLength(255).onChange((v: string) => { this.originInput = v; })
      TextInput({ placeholder: this.hasSavedConnection ? '留空使用此地址已保存的令牌' : '服务器生成的桥接 token', text: this.tokenInput })
        .type(InputType.Password).maxLength(128).onChange((v: string) => { this.tokenInput = v; })
      Row({ space: 10 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.remember }).onChange((v: boolean) => { this.remember = v; })
        Text('在系统安全存储中记住连接').fontSize(13).fontColor(AppTheme.text('#697386'))
      }.width('100%')
      if (this.privacyState !== 'accepted') {
        Button('阅读并选择隐私声明').fontSize(12).fontColor(AppTheme.text('#5968FF'))
          .backgroundColor(AppTheme.background('#EEF0FF'))
          .onClick(() => { PrivacyConsentDialog.show(this.getUIContext()); })
      }
      Button(this.busy ? '正在连接…' : '安全连接').width('100%').height(44)
        .backgroundColor(AppTheme.filledBackground('#5968FF')).enabled(!this.busy)
        .onClick(() => { this.connect(); })
      if (this.hasSavedConnection) {
        Button('忘记已保存连接').fontSize(12).backgroundColor(Color.Transparent).fontColor(AppTheme.text('#A34C4C'))
          .enabled(!this.busy).onClick(() => { this.forget(); })
      }
      Text('只接受 HTTPS；配对证书仅用于这台电脑，不安装到系统信任库。OpenAI 登录和密钥保留在电脑。')
        .fontSize(11).lineHeight(18).fontColor(AppTheme.text('#747B87')).width('100%')
    }.padding(20).backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20).width('100%')
  }

  @Builder private TaskSettings() {
    Column({ space: 8 }) {
      Row() {
        Text('工作目录').fontSize(12).fontColor(AppTheme.text('#747B87')).width(64)
        Select(this.workspaces.map((w: CodexWorkspace): SelectOption => ({ value: w.name })))
          .selected(this.selectIndex(this.workspaces.map((w: CodexWorkspace) => w.id), this.workspaceId))
          .onSelect((index: number) => { this.workspaceId = this.workspaces[index].id; this.attachments = []; })
          .enabled(this.task === null && !this.busy).layoutWeight(1)
      }
      Row() {
        Text('模型').fontSize(12).fontColor(AppTheme.text('#747B87')).width(64)
        Select(this.models.map((m: CodexModel): SelectOption => ({ value: m.displayName || m.model })))
          .selected(this.selectIndex(this.models.map((m: CodexModel) => m.model), this.modelId))
          .onSelect((index: number) => { this.chooseModel(this.models[index].model); })
          .enabled(!this.running() && !this.busy).layoutWeight(1)
      }
      if (this.efforts().length > 0) {
        Row() {
          Text('思考强度').fontSize(12).fontColor(AppTheme.text('#747B87')).width(64)
          Select(this.efforts().map((e: CodexEffort): SelectOption => ({ value: e.reasoningEffort })))
            .selected(this.selectIndex(this.efforts().map((e: CodexEffort) => e.reasoningEffort), this.effort))
            .onSelect((index: number) => { this.effort = this.efforts()[index].reasoningEffort; })
            .enabled(!this.running() && !this.busy).layoutWeight(1)
        }
      }
      Row() {
        Text('执行权限').fontSize(12).fontColor(AppTheme.text('#747B87')).width(64)
        Select([{ value: '只读分析' }, { value: '允许工作目录内修改' }])
          .selected(this.mode === 'workspace-write' ? 1 : 0)
          .onSelect((index: number) => { this.mode = index === 1 ? 'workspace-write' : 'read-only'; })
          .enabled(this.task === null && !this.busy).layoutWeight(1)
      }
      Text('模型切换在下一条消息生效。权限和目录在新任务时设置。').fontSize(11).fontColor(AppTheme.text('#747B87'))
    }.padding(14).width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(16)
  }

  @Builder private History() {
    Column({ space: 8 }) {
      if (this.tasks.length === 0) { Text('还没有远程任务').fontColor(AppTheme.text('#747B87')).fontSize(13) }
      ForEach(this.tasks, (summary: CodexTaskSummary) => {
        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text(summary.title).fontSize(14).fontColor(AppTheme.text('#172033')).maxLines(2)
            Text(codexStatusLabel(summary.status) + ' · ' + summary.model)
              .fontSize(11).fontColor(AppTheme.text('#747B87')).maxLines(1)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('›').fontSize(22).fontColor(AppTheme.text('#5968FF'))
        }.padding(12).width('100%').borderRadius(12).backgroundColor(AppTheme.background('#FFFFFF'))
        .enabled(!this.busy).onClick(() => { this.selectTask(summary.id); })
      }, (summary: CodexTaskSummary) => summary.id)
    }.width('100%')
  }

  @Builder private Message(item: CodexItem) {
    Column({ space: 8 }) {
      Text(item.kind === 'user' ? '你' : item.kind === 'assistant' ? 'CODEX' : item.kind === 'diff' ? '文件变更' : item.kind === 'plan' ? '任务计划' : '执行记录')
        .fontSize(10).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#697386'))
        .onClick(() => { this.toggleTool(item.id); })
      if (item.kind === 'user' || item.kind === 'assistant' || item.kind === 'plan') {
        MarkdownView({ text: item.text, variant: 'file_preview' })
      } else {
        Text(this.expandedTools.includes(item.id) ? item.text : item.text.slice(0, 160) + (item.text.length > 160 ? '\n点击展开…' : ''))
          .fontSize(12).fontFamily('monospace').fontColor(AppTheme.text('#293248'))
          .copyOption(CopyOptions.LocalDevice).onClick(() => { this.toggleTool(item.id); })
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start).borderRadius(16)
    .backgroundColor(AppTheme.background(item.kind === 'user' ? '#EEF0FF' : '#FFFFFF'))
  }

  @Builder private Composer() {
    Column({ space: 8 }) {
      if (this.attachments.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.attachments, (a: CodexAttachment) => {
              Button((a.image ? '▧ ' : '▤ ') + a.name + ' ×').fontSize(11)
                .backgroundColor(AppTheme.background('#EEF0FF')).fontColor(AppTheme.text('#5968FF'))
                .enabled(!this.busy).onClick(() => { this.attachments = this.attachments.filter((v: CodexAttachment) => v.id !== a.id); })
            }, (a: CodexAttachment) => a.id)
          }
        }.scrollable(ScrollDirection.Horizontal).width('100%')
      }
      TextArea({ placeholder: this.running() ? '任务执行中，可查看输出或停止任务' : '描述任务，或继续追问…', text: this.draft })
        .height(82).fontSize(14).maxLength(20000).backgroundColor(AppTheme.inputBackground())
        .enabled(!this.busy && !this.running()).onChange((v: string) => { this.draft = v; })
      Row({ space: 8 }) {
        Button('图片').fontSize(12).onClick(() => { this.pickAttachment(true); })
          .enabled(!this.busy && !this.running() && this.attachments.length < 6)
        Button('文件').fontSize(12).onClick(() => { this.pickAttachment(false); })
          .enabled(!this.busy && !this.running() && this.attachments.length < 6)
        Blank()
        if (this.running()) {
          Button('停止').fontSize(13).backgroundColor(AppTheme.filledBackground('#B94D4D'))
            .enabled(!this.busy).onClick(() => { this.stop(); })
        } else {
          Button(this.busy ? '处理中…' : '发送任务').fontSize(13).backgroundColor(AppTheme.filledBackground('#5968FF'))
            .enabled(!this.busy && (this.draft.trim().length > 0 || this.attachments.length > 0))
            .onClick(() => { this.send(); })
        }
      }.width('100%')
      Text('每项 ≤ 8 MiB，最多 6 项；附件会上传至所选电脑。图片支持 PNG / JPEG / WebP。')
        .fontSize(10).fontColor(AppTheme.text('#747B87')).width('100%')
    }.padding(12).backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(18)
    .margin({ left: 16, right: 16, bottom: this.navigationBottomInset + 8 })
  }

  @Builder private Header() {
    AppHeader({ title: 'Codex', actionLabel: this.connected ? '连接' : '',
      onActionClick: () => { this.connectionOpen = !this.connectionOpen; } })
  }
  @Builder private Content() {
    Column({ space: 0 }) {
      Scroll(this.scroller) {
        Column({ space: 14 }) {
          if (this.connected) {
            Row({ space: 10 }) {
              Column({ space: 4 }) {
                Text('● ' + this.serverName).fontSize(14).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#21855A'))
                Text(this.originInput).fontSize(10).fontColor(AppTheme.text('#747B87')).maxLines(1)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Button('历史').fontSize(12).onClick(() => { this.historyOpen = !this.historyOpen; this.refreshTasks().catch(() => {}); })
              Button('新任务').fontSize(12).enabled(!this.busy).onClick(() => { this.newTask(); })
            }.width('100%')
            if (this.connectionOpen) {
              Text('断开连接不会停止电脑端任务。').fontSize(12).fontColor(AppTheme.text('#747B87'))
              Button('断开连接 / 修改地址').onClick(() => { this.disconnect(); })
            }
            if (this.networkText) {
              Text(this.networkText).fontSize(12).fontColor(AppTheme.text('#AD6500')).width('100%')
            }
            if (this.historyOpen) { this.History() }
            this.TaskSettings()
            Row() {
              Text(this.task === null ? '准备开始' : codexStatusLabel(this.task.status))
                .fontSize(12).fontColor(AppTheme.text('#5968FF'))
              Blank()
              Text(this.followOutput ? '自动跟随 ✓' : '自动跟随').fontSize(11).fontColor(AppTheme.text('#747B87'))
                .onClick(() => { this.followOutput = !this.followOutput; })
            }.width('100%')
            if (this.task === null) {
              Column({ space: 10 }) {
                Text('从一个清晰的任务开始').fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
                Text('分析项目 · 修复问题 · 根据截图实现界面').fontSize(12).fontColor(AppTheme.text('#747B87'))
                Text('离开页面后任务继续运行。需要审批时会等待你返回。').fontSize(11).fontColor(AppTheme.text('#747B87'))
              }.width('100%').padding({ top: 28, bottom: 28 })
            }
            if (this.task?.truncated) { Text('当前展示最近 160 条记录；完整历史保留在电脑 Codex 中。').fontSize(11).fontColor(AppTheme.text('#747B87')) }
            ForEach(this.taskItems(), (item: CodexItem) => { this.Message(item) }, (item: CodexItem) => item.id + ':' + item.text.length)
            ForEach(this.approvals(), (approval: CodexApproval) => {
              CodexApprovalCard({ approval: approval, busy: this.busy,
                onAnswer: (id: string, decision: string, answers: CodexAnswer[]) => { this.taskAction('approvals', id, decision, answers); } })
            }, (approval: CodexApproval) => approval.id)
            if (this.task?.error) { Text(this.task.error).fontSize(12).fontColor(AppTheme.text('#B94D4D')).width('100%') }
          } else { this.ConnectionForm() }
          if (this.errorText) {
            Text(this.errorText).fontSize(12).lineHeight(19).fontColor(AppTheme.text('#B94D4D')).width('100%')
          }
        }.padding({ left: 16, right: 16, top: 16, bottom: 20 }).width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      if (this.connected) { this.Composer() }
      else { Blank().height(this.navigationBottomInset) }
    }.width('100%').height('100%')
  }
  build() {
    FrostedPage({ pageBackgroundColor: '#F4F7FB', scrollers: [this.scroller],
      headerBuilder: () => { this.Header(); }, contentBuilder: () => { this.Content(); } })
  }
}
