import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { AppTheme } from '../../utils/AppTheme';
import { AppHeader } from '../../components/AppHeader';
import { FrostedPage } from '../../components/FrostedPage';
import { MarkdownView } from '../../components/MarkdownView';
import { CodexClient } from './CodexClient';
import { CodexCredentialStore } from './CodexCredentialStore';
import { CodexApprovalCard } from './CodexApprovalCard';
import { CodexArtifactStore } from './CodexArtifactStore';
import { CodexArtifactCard } from './CodexArtifactCard';
import { openCodexArtifact, exportCodexArtifact } from './CodexArtifactActions';
import { CodexConnectionsView, CodexConnectionSetup } from './CodexConnectionViews';
import { CodexWorkspaceHeader, CodexHistoryDrawer } from './CodexChatViews';
import { chatComposerBarHeight, chatComposerTextAreaHeight } from '../chat/ChatPageTypes';
import { parseCodexPairingInput } from './CodexPairingInput';
import { CodexHelpParams, CodexHelpSection } from './CodexHelpContent';
import {
  CODEX_MAX_FILE_BYTES, CodexConnection, CodexModel, CodexWorkspace, CodexTask, CodexTaskSummary,
  CodexAttachment, CodexItem, CodexApproval, CodexAnswer, CodexEffort, CodexArtifact, CodexLocalArtifact,
  normalizeCodexOrigin, codexTaskBusy, codexStatusLabel, CodexSavedConnection, CodexScreen, CODEX_PAIRING_PREFIX,
  codexApprovalLabel, codexExecutionNotice, codexLinkLabel, mergeCodexTask, codexTimeline, codexTimelineKey, CodexTimelineEntry
} from './CodexTypes';

@Component
export struct CodexPage {
  @Prop @Watch('activeChanged') active: boolean = false;
  @Prop navigationBottomInset: number = 0;
  @Link @Watch('screenChanged') screen: number;
  @Link taskSettingsOpen: boolean;
  @Link historyOpen: boolean;
  @State private originInput: string = '';
  @State private tokenInput: string = '';
  @State private pairingInput: string = '';
  @State private remember: boolean = true;
  @State private savedConnections: CodexSavedConnection[] = [];
  @State private connectionsLoading: boolean = true;
  @State private connectedOrigin: string = '';
  @State private connectingOrigin: string = '';
  // A configured conversation can survive a network outage; only linkLabel()
  // represents current reachability in the UI.
  @State private connected: boolean = false;
  @State private lastNetworkSuccess: number = 0;
  @State private lastNetworkFailure: number = 0;
  @State private healthChecking: boolean = false;
  private healthSupported: boolean = false;
  private taskDeltaSupported: boolean = false;
  private healthTimer: number = -1;
  private healthRun: number = 0;
  private scrollGeneration: number = 0;
  private bottomUntil: number = 0;
  @State private serverName: string = '';
  @State private workspaces: CodexWorkspace[] = [];
  @State private models: CodexModel[] = [];
  @State private workspaceId: string = '';
  @State private modelId: string = '';
  @State private effort: string = '';
  @State private mode: string = 'workspace-write';
  @State private approvalMode: string = 'ask';
  @State private tasks: CodexTaskSummary[] = [];
  @State private task: CodexTask | null = null;
  @State private draft: string = '';
  @State private attachments: CodexAttachment[] = [];
  @State private busy: boolean = false;
  @State private errorText: string = '';
  @State private networkText: string = '';
  @State private expandedTools: string[] = [];
  @State private followOutput: boolean = true;
  @State private artifactsSupported: boolean = false;
  @State private existingSessionsSupported: boolean = false;
  @State private sameSessionSupported: boolean = false;
  @State private permissionSettingsSupported: boolean = false;
  @State private taskUpdatesSupported: boolean = false;
  @State private statusNow: number = Date.now();
  @State private historyScope: string = 'phone';
  @State private computerTasks: CodexTaskSummary[] = [];
  @State private computerCursor: string = '';
  @State private computerLoading: boolean = false;
  @State private historyError: string = '';
  @State private olderItems: CodexItem[] = [];
  @State private historyCursor: string = '';
  private pendingResumeRequestId: string = '';
  private pendingResumeFingerprint: string = '';
  @State private localArtifacts: CodexLocalArtifact[] = [];
  @State private receivingArtifactId: string = '';
  @State private artifactProgress: string = '';
  @State private artifactError: string = '';
  private artifactSyncRunning: boolean = false;
  private artifactRetryAt: number = 0;
  private client: CodexClient = new CodexClient();
  private scroller: Scroller = new Scroller();
  private timer: number = -1;
  private statusTimer: number = -1;
  private pollGeneration: number = 0;
  private epoch: number = 0;
  private polling: boolean = false;
  private pollCount: number = 0;
  private retryDelay: number = 2000;
  private pendingRequestId: string = '';
  private pairedConnection: CodexConnection | null = null;
  private pendingClient: CodexClient | null = null;
  private connectionOperation: boolean = false;
  private connectionListRevision: number = 0;

  aboutToAppear(): void { this.restoreConnections(); }
  aboutToDisappear(): void { this.disconnect(); }

  private async restoreConnections(): Promise<void> {
    const revision = ++this.connectionListRevision;
    this.connectionsLoading = true;
    try {
      const saved = await CodexCredentialStore.list();
      if (revision === this.connectionListRevision) { this.savedConnections = saved; }
    } catch (e) { if (revision === this.connectionListRevision) { this.errorText = (e as Error).message; } }
    finally { if (revision === this.connectionListRevision) { this.connectionsLoading = false; } }
  }
  private screenChanged(): void {
    this.clearTimer(); this.cancelTaskPoll();
    this.historyOpen = false; this.taskSettingsOpen = false;
    if (this.screen !== CodexScreen.Setup) {
      this.cancelConnectionWork();
      this.tokenInput = ''; this.pairingInput = ''; this.pairedConnection = null;
    }
    if (this.screen === CodexScreen.Workspace && this.connected) { this.schedulePoll(10); }
    if (this.screen === CodexScreen.Workspace && this.task !== null) { this.scrollToLatest(true); }
    else if (this.screen !== CodexScreen.Workspace) { setTimeout(() => { try { this.scroller.scrollEdge(Edge.Top); } catch (e) { } }, 0); }
  }
  private cancelConnectionWork(): void {
    if (!this.connectionOperation) { return; }
    this.epoch++; this.pendingClient?.close(); this.pendingClient = null;
    this.connectionOperation = false; this.busy = false; this.connectingOrigin = '';
  }
  private openConnectionSetup(): void {
    if (this.busy) { return; }
    this.errorText = ''; this.originInput = ''; this.tokenInput = ''; this.pairingInput = '';
    this.pairedConnection = null; this.remember = true; this.screen = CodexScreen.Setup;
  }
  private openSavedConnection(item: CodexSavedConnection): void {
    if (this.busy) { return; }
    this.errorText = '';
    if (this.connected && this.connectedOrigin === item.origin) {
      this.screen = CodexScreen.Workspace; this.checkConnection(); this.scrollToLatest(true); return;
    }
    this.connectingOrigin = item.origin;
    this.connect(item.id, item.name);
  }
  private activeChanged(): void {
    this.clearTimer(); this.cancelTaskPoll();
    if (!this.active) { this.historyOpen = false; this.taskSettingsOpen = false; }
    if (this.active && this.connected && this.screen === CodexScreen.Workspace) { this.schedulePoll(10); }
    this.startHeartbeat();
  }
  private clearTimer(): void {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    if (this.statusTimer >= 0) { clearInterval(this.statusTimer); this.statusTimer = -1; }
  }
  private cancelTaskPoll(): void {
    this.pollGeneration++; this.client.cancelTaskUpdates(); this.polling = false;
  }
  private schedulePoll(delay: number = 2000): void {
    this.clearTimer();
    if (this.active && this.connected && this.screen === CodexScreen.Workspace) {
      this.timer = setTimeout(() => { this.poll(); }, delay);
      this.statusTimer = setInterval(() => { this.statusNow = Date.now(); }, 1000);
    }
  }
  private disconnect(): void {
    this.epoch++; this.clearTimer(); this.cancelTaskPoll(); this.client.close(); this.pendingClient?.close(); this.pendingClient = null;
    this.connectionOperation = false; this.connected = false; this.connectedOrigin = ''; this.connectingOrigin = ''; this.task = null;
    if (this.healthTimer >= 0) { clearInterval(this.healthTimer); this.healthTimer = -1; }
    this.healthRun++; this.healthChecking = false; this.lastNetworkSuccess = 0; this.lastNetworkFailure = 0;
    this.scrollGeneration++; this.bottomUntil = 0;
    this.tasks = []; this.attachments = []; this.tokenInput = ''; this.pendingRequestId = '';
    this.pairedConnection = null; this.pairingInput = '';
    this.draft = ''; this.models = []; this.workspaces = []; this.serverName = ''; this.expandedTools = [];
    this.networkText = ''; this.busy = false; this.polling = false;
    this.localArtifacts = []; this.receivingArtifactId = ''; this.artifactProgress = ''; this.artifactError = '';
    this.artifactsSupported = false; this.artifactRetryAt = 0;
    this.resetComputerHistory();
    this.taskSettingsOpen = false; this.historyOpen = false; this.screen = CodexScreen.Connections;
  }
  private async connect(savedId: string = '', name: string = ''): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.errorText = '';
    const epoch = ++this.epoch;
    this.connectionOperation = true;
    const candidate = new CodexClient();
    this.pendingClient = candidate;
    try {
      let connection: CodexConnection;
      if (savedId) {
        const saved = await CodexCredentialStore.load(savedId);
        if (saved === null) { throw new Error('此连接已被删除，请重新配对'); }
        connection = saved;
      } else if (this.pairedConnection !== null) {
        connection = this.pairedConnection;
      } else {
        const origin = normalizeCodexOrigin(this.originInput);
        if (!this.tokenInput.trim()) { throw new Error('请填写服务器生成的 token，或使用扫码配对'); }
        connection = { origin: origin, token: this.tokenInput.trim() };
      }
      if (epoch !== this.epoch) { return; }
      this.connectingOrigin = connection.origin;
      candidate.configure(connection);
      const info = await candidate.call('/v1/info');
      if (epoch !== this.epoch) { return; }
      if (info.protocol !== 1 || !info.ready || !info.models?.length || !info.workspaces?.length) {
        throw new Error('桥接协议不兼容，或服务器没有可用模型/工作目录');
      }
      const serverName = info.name || name || '我的电脑';
      if (savedId || this.remember) {
        await CodexCredentialStore.save(connection, serverName);
      }
      if (epoch !== this.epoch) { return; }
      this.clearTimer(); this.client.close(); this.client = candidate; this.pendingClient = null;
      this.connectedOrigin = connection.origin; this.tokenInput = ''; this.serverName = serverName;
      this.models = info.models; this.workspaces = info.workspaces;
      this.artifactsSupported = info.artifactsSupported === true;
      this.resetComputerHistory(); this.existingSessionsSupported = info.existingSessionsSupported === true;
      this.sameSessionSupported = info.sameSessionSupported === true;
      this.permissionSettingsSupported = info.permissionSettingsSupported === true;
      this.taskUpdatesSupported = info.taskUpdatesSupported === true;
      this.healthSupported = info.healthSupported === true; this.taskDeltaSupported = info.taskDeltaSupported === true;
      candidate.setArtifactChunkBytes(info.artifactChunkBytes || 1048576);
      candidate.onReachability = (reachable: boolean, message: string): void => {
        if (this.client !== candidate || !this.connected) { return; }
        this.statusNow = Date.now();
        if (reachable) { this.lastNetworkSuccess = this.statusNow; this.lastNetworkFailure = 0; this.networkText = ''; }
        else { this.lastNetworkFailure = this.statusNow; this.networkText = message || '连接已中断，正在重试'; }
      };
      this.workspaceId = this.workspaces[0].id;
      this.mode = 'workspace-write'; this.approvalMode = 'ask';
      this.chooseModel((this.models.find((m: CodexModel) => m.isDefault) ?? this.models[0]).model);
      this.task = null; this.tasks = []; this.attachments = []; this.draft = ''; this.pendingRequestId = '';
      this.expandedTools = []; this.historyOpen = false; this.taskSettingsOpen = false;
      this.localArtifacts = []; this.artifactError = ''; this.artifactRetryAt = 0;
      this.connected = true; this.connectionOperation = false; this.screen = CodexScreen.Workspace;
      this.lastNetworkSuccess = Date.now(); this.lastNetworkFailure = 0; this.startHeartbeat();
      await this.restoreConnections();
      if (epoch !== this.epoch) { return; }
      try { await this.refreshTasks(); } catch (e) {
        if (epoch === this.epoch) { this.networkText = '任务列表暂未加载，稍后自动重试'; }
      }
      if (epoch === this.epoch) { this.retryDelay = 2000; this.schedulePoll(); }
    } catch (e) {
      if (epoch === this.epoch) {
        this.errorText = '连接失败：' + ((e as Error).message || '请检查网络、HTTPS 证书和电脑端服务');
      }
    } finally {
      if (this.client !== candidate) { candidate.close(); }
      if (epoch === this.epoch) {
        this.pendingClient = null; this.connectionOperation = false; this.connectingOrigin = ''; this.busy = false;
      }
    }
  }
  private async forgetSavedConnection(item: CodexSavedConnection): Promise<void> {
    if (this.busy) { return; }
    const confirmed = await new Promise<boolean>((resolve) => {
      this.getUIContext().showAlertDialog({ title: '删除连接',
        message: '从此手机删除「' + item.name + '」？电脑上的任务会继续运行。',
        primaryButton: { value: '取消', action: () => { resolve(false); } },
        secondaryButton: { value: '删除', action: () => { resolve(true); } } });
    });
    if (!confirmed || this.busy) { return; }
    if (this.connectedOrigin === item.origin) { this.disconnect(); }
    this.busy = true; this.errorText = '';
    try {
      await CodexCredentialStore.forget(item.id); await this.restoreConnections();
    } catch (e) { this.errorText = '未能删除安全凭据，请重试'; }
    finally { this.busy = false; }
  }
  private async scanPairingCode(): Promise<void> {
    if (this.busy) { return; }
    const epoch = ++this.epoch;
    this.busy = true; this.connectionOperation = true; this.errorText = '';
    try {
      if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
        throw new Error('此设备暂不支持扫码，请导入配对文件或粘贴配对信息');
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true
      };
      const result = await scanBarcode.startScanForResult(context, options);
      if (epoch !== this.epoch || this.screen !== CodexScreen.Setup) { return; }
      if (!result.originalValue.startsWith(CODEX_PAIRING_PREFIX)) {
        throw new Error('这不是 ClawMate 配对二维码，请扫描电脑端「手机配对」中的二维码');
      }
      this.pairingInput = result.originalValue;
      this.connectionOperation = false; this.busy = false;
      await this.pairFromInput();
    } catch (e) {
      if (epoch === this.epoch && (e as BusinessError).code !== 1000500002) {
        this.errorText = (e as Error).message || '扫码失败，请重试或导入配对文件';
      }
    } finally {
      if (epoch === this.epoch) { this.connectionOperation = false; this.busy = false; }
    }
  }
  private async importPairingFile(): Promise<void> {
    if (this.busy) { return; }
    const epoch = ++this.epoch;
    this.busy = true; this.connectionOperation = true; this.errorText = '';
    let file: fileIo.File | null = null;
    try {
      const options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 1;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const uris = await new picker.DocumentViewPicker(context).select(options);
      if (!uris.length || epoch !== this.epoch) { return; }
      file = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      const size = (await fileIo.stat(file.fd)).size;
      if (size <= 0 || size > 8192) { throw new Error('配对文件无效，文件上限为 8 KiB'); }
      const bytes = new ArrayBuffer(size);
      if (await fileIo.read(file.fd, bytes) !== size) { throw new Error('配对文件读取不完整'); }
      if (epoch !== this.epoch) { return; }
      this.pairingInput = new util.TextDecoder().decodeWithStream(new Uint8Array(bytes));
      this.connectionOperation = false; this.busy = false;
      await this.pairFromInput();
    } catch (e) { if (epoch === this.epoch) { this.errorText = (e as Error).message; } }
    finally {
      if (file !== null) { try { await fileIo.close(file); } catch (e) { } }
      if (epoch === this.epoch) { this.connectionOperation = false; this.busy = false; }
    }
  }
  private async pairFromInput(): Promise<void> {
    if (this.busy) { return; }
    const epoch = ++this.epoch;
    this.busy = true; this.connectionOperation = true; this.errorText = '';
    try {
      const bundle = parseCodexPairingInput(this.pairingInput);
      const confirmed = await new Promise<boolean>((resolve) => {
        this.getUIContext().showAlertDialog({ title: '连接自己的电脑',
          message: bundle.name + '\n' + bundle.origin + '\n\n请确认这份配对信息来自你自己的 PC 应用。连接后可以向该电脑下发任务。',
          autoCancel: false,
          primaryButton: { value: '取消', action: () => { resolve(false); } },
          secondaryButton: { value: '确认配对', action: () => { resolve(true); } }
        });
      });
      if (!confirmed || epoch !== this.epoch || this.screen !== CodexScreen.Setup) { return; }
      const candidate = new CodexClient(); this.pendingClient = candidate;
      const connection = await candidate.pair(bundle);
      candidate.close();
      if (epoch !== this.epoch) { return; }
      this.pendingClient = null; this.pairedConnection = connection;
      this.originInput = bundle.origin; this.tokenInput = ''; this.pairingInput = '';
      this.connectionOperation = false; this.busy = false;
      await this.connect('', bundle.name);
    } catch (e) {
      if (epoch === this.epoch) { this.errorText = (e as Error).message || '配对失败，请在电脑端重新生成'; }
    } finally {
      if (epoch === this.epoch) {
        this.pendingClient?.close(); this.pendingClient = null; this.connectionOperation = false; this.busy = false;
      }
    }
  }
  private chooseModel(id: string): void {
    this.modelId = id;
    this.effort = this.models.find((m: CodexModel) => m.model === id)?.defaultReasoningEffort ?? '';
  }
  private efforts(): CodexEffort[] {
    return this.models.find((m: CodexModel) => m.model === this.modelId)?.supportedReasoningEfforts ?? [];
  }
  private running(): boolean { return this.task !== null && codexTaskBusy(this.task.status); }
  private linkLabel(): string { return codexLinkLabel(this.lastNetworkSuccess, this.lastNetworkFailure, this.statusNow, this.healthChecking); }
  private startHeartbeat(): void {
    if (this.healthTimer >= 0) { clearInterval(this.healthTimer); this.healthTimer = -1; }
    if (!this.connected || !this.active) { return; }
    this.statusNow = Date.now();
    this.healthTimer = setInterval(() => { this.statusNow = Date.now(); this.checkConnection(); }, 10000);
    this.checkConnection();
  }
  private async checkConnection(): Promise<void> {
    if (!this.active || !this.connected || this.healthChecking || Date.now() - this.lastNetworkSuccess < 8000 && !this.lastNetworkFailure) { return; }
    const epoch = this.epoch; const run = ++this.healthRun; this.healthChecking = true;
    try {
      const result = await this.client.call(this.healthSupported ? '/v1/health' : '/v1/info');
      if (epoch !== this.epoch) { return; }
      this.lastNetworkSuccess = Date.now(); this.lastNetworkFailure = 0; this.statusNow = Date.now();
      this.networkText = result.ready === false ? '电脑连接正常，Codex 后台尚未就绪' : '';
    } catch (e) {
      if (epoch === this.epoch) {
        this.lastNetworkFailure = Date.now(); this.statusNow = Date.now();
        this.networkText = (e as Error).message || '连接已中断，正在重试';
      }
    } finally { if (run === this.healthRun) { this.healthChecking = false; } }
  }
  private scrollToLatest(force: boolean = false): void {
    const id = this.task?.id || '';
    if (!id || !force && !this.followOutput && this.bottomUntil <= Date.now()) { return; }
    if (force) { this.bottomUntil = Date.now() + 5000; }
    const generation = ++this.scrollGeneration; const epoch = this.epoch;
    [0, 120, 350].forEach((delay: number) => {
      setTimeout(() => {
        if (epoch === this.epoch && generation === this.scrollGeneration && this.task?.id === id &&
          this.screen === CodexScreen.Workspace && this.active) { try { this.scroller.scrollEdge(Edge.Bottom); } catch (e) { } }
      }, delay);
    });
  }
  private contentSizeChanged(): void {
    if (this.bottomUntil > Date.now() || this.followOutput && this.running()) { this.scrollToLatest(); }
  }
  private timeline(): CodexTimelineEntry[] { return codexTimeline(this.taskItems(), this.task?.artifacts || []); }
  private taskItems(): CodexItem[] {
    const recent = this.task?.items ?? [];
    return this.olderItems.filter((item: CodexItem) => !recent.some((entry: CodexItem) => entry.id === item.id)).concat(recent);
  }
  private approvals(): CodexApproval[] { return this.task?.approvals ?? []; }
  private selectIndex(values: string[], selected: string): number { return Math.max(0, values.indexOf(selected)); }
  private workspaceName(): string {
    return this.workspaces.find((w: CodexWorkspace) => w.id === this.workspaceId)?.name || '选择工作目录';
  }
  private modelName(): string {
    const model = this.models.find((m: CodexModel) => m.model === this.modelId);
    return model?.displayName || this.modelId || '选择模型';
  }
  private chooseApprovalMode(mode: string): void {
    if (this.busy || this.running() || !this.permissionSettingsSupported) { return; }
    this.approvalMode = mode;
    if (mode === 'full') { this.mode = 'danger-full-access'; }
    else if (this.mode === 'danger-full-access') { this.mode = 'workspace-write'; }
  }
  private permissionDescription(): string {
    if (this.approvalMode === 'full') { return '完全访问：可操作电脑上的文件和网络，执行前不再请求批准。'; }
    if (this.approvalMode === 'auto') { return '帮我批准：由 Codex 自动审核越界申请；无法自动处理的操作仍可能需要你确认。'; }
    return '请求批准：在所选范围内工作，访问外部文件或网络时向你申请。';
  }
  private openHistory(): void {
    this.taskSettingsOpen = false; this.historyOpen = true;
    const epoch = this.epoch;
    this.refreshTasks().catch(() => {
      if (epoch === this.epoch) { this.networkText = '历史暂未刷新，请稍后重试'; }
    });
    if (this.historyScope === 'computer') { this.loadComputerHistory(true); }
  }
  private resetComputerHistory(): void {
    this.existingSessionsSupported = false; this.historyScope = 'phone'; this.computerTasks = [];
    this.sameSessionSupported = false;
    this.permissionSettingsSupported = false; this.taskUpdatesSupported = false;
    this.computerCursor = ''; this.computerLoading = false; this.historyError = '';
    this.olderItems = []; this.historyCursor = ''; this.pendingResumeRequestId = ''; this.pendingResumeFingerprint = '';
  }
  private changeHistoryScope(scope: string): void {
    if (this.busy) { return; }
    this.historyScope = scope; this.historyError = '';
    if (scope === 'computer') { this.loadComputerHistory(true); }
  }
  private async loadComputerHistory(reset: boolean = false): Promise<void> {
    if (!this.connected || !this.existingSessionsSupported || this.computerLoading) { return; }
    const epoch = this.epoch;
    this.computerLoading = true; this.historyError = '';
    try {
      const route = '/v1/threads' + (!reset && this.computerCursor ? '?cursor=' + encodeURIComponent(this.computerCursor) : '');
      const result = await this.client.call(route);
      if (epoch !== this.epoch) { return; }
      const base: CodexTaskSummary[] = reset ? [] : this.computerTasks;
      this.computerTasks = base.concat((result.threads ?? []).filter((item: CodexTaskSummary) =>
        !base.some((entry: CodexTaskSummary) => entry.id === item.id)));
      this.computerCursor = result.nextThreadCursor || '';
      if (this.computerTasks.length >= 1000) {
        this.computerTasks = this.computerTasks.slice(0, 1000); this.computerCursor = '';
        this.historyError = '当前显示最近 1000 个会话，更早记录可在电脑查看。';
      }
    } catch (e) { if (epoch === this.epoch) { this.historyError = (e as Error).message || '电脑历史读取失败，请点击刷新'; } }
    finally { if (epoch === this.epoch) { this.computerLoading = false; } }
  }
  private async loadOlderHistory(): Promise<void> {
    if (this.busy || this.task === null || !this.historyCursor) { return; }
    this.busy = true; this.errorText = '';
    const epoch = this.epoch; const id = this.task.id;
    try {
      const result = await this.client.call('/v1/threads/' + id + '?cursor=' + encodeURIComponent(this.historyCursor));
      if (epoch !== this.epoch || this.task?.id !== id || result.task === undefined) { return; }
      const current = this.taskItems();
      const older = result.task.items.filter((item: CodexItem) => !current.some((entry: CodexItem) => entry.id === item.id));
      const combined = older.concat(this.olderItems);
      if (combined.length > 320 || combined.reduce((size: number, item: CodexItem) => size + item.text.length, 0) > 500000) {
        this.historyCursor = ''; this.errorText = '手机已加载较多历史，完整记录仍可在电脑查看。'; return;
      }
      this.olderItems = combined; this.historyCursor = result.task.historyCursor || '';
    } catch (e) { if (epoch === this.epoch) { this.errorText = (e as Error).message || '更早记录读取失败'; } }
    finally { if (epoch === this.epoch) { this.busy = false; } }
  }
  private async refreshTasks(): Promise<void> {
    const epoch = this.epoch;
    const result = await this.client.call('/v1/tasks');
    if (epoch === this.epoch) { this.tasks = result.tasks ?? []; }
  }
  private applyTask(task: CodexTask): void {
    if (this.task !== null && this.task.id === task.id && task.revision < this.task.revision) { return; }
    this.task = task;
    this.statusNow = Date.now();
    this.receiveArtifacts(task);
    if (this.pendingRequestId && task.lastRequestId === this.pendingRequestId &&
      (task.executionTransport !== 'desktop' || task.lastRequestConfirmed === true)) {
      this.pendingRequestId = ''; this.draft = ''; this.attachments = [];
    }
    this.scrollToLatest();
  }
  private async poll(): Promise<void> {
    if (!this.active || !this.connected || this.screen !== CodexScreen.Workspace || this.polling) { return; }
    if (this.busy) { this.schedulePoll(); return; }
    this.polling = true;
    const epoch = this.epoch;
    const generation = this.pollGeneration;
    const taskId = this.task?.id ?? '';
    try {
      if (taskId && !this.task?.external) {
        const wait = this.taskUpdatesSupported && this.running() ? '&waitMs=12000' : '';
        let result = await this.client.call('/v1/tasks/' + taskId + '?revision=' + this.task!.revision + wait +
          (this.taskDeltaSupported ? '&sync=delta' : ''));
        if (epoch !== this.epoch || generation !== this.pollGeneration) { return; }
        if (!this.busy && this.task?.id === taskId) {
          let next: CodexTask | undefined;
          try { next = mergeCodexTask(this.task, result); }
          catch (e) {
            result = await this.client.call('/v1/tasks/' + taskId + (this.taskDeltaSupported ? '?sync=delta' : ''));
            if (epoch !== this.epoch || generation !== this.pollGeneration || this.task?.id !== taskId) { return; }
            next = result.task;
          }
          if (next !== undefined) { this.applyTask(next); }
        }
      }
      if (++this.pollCount % 5 === 0 || !taskId) { await this.refreshTasks(); }
      if (epoch !== this.epoch || generation !== this.pollGeneration) { return; }
      if (this.task !== null && epoch === this.epoch) { this.receiveArtifacts(this.task); }
      if (epoch === this.epoch) { this.networkText = ''; this.retryDelay = 2000; }
    } catch (e) {
      if (epoch === this.epoch && generation === this.pollGeneration) {
        this.networkText = (e as Error).message || '读取暂时失败，正在重试。电脑端任务会继续运行。';
        this.retryDelay = Math.min(this.retryDelay * 2, 15000) + Math.floor(Math.random() * 500);
      }
    } finally {
      if (generation === this.pollGeneration) {
        this.polling = false;
        if (epoch === this.epoch) { this.schedulePoll(this.taskUpdatesSupported && this.running() && !this.networkText ? 750 : this.retryDelay); }
      }
    }
  }
  private newTask(): void {
    if (this.busy) { return; }
    this.cancelTaskPoll();
    this.task = null; this.attachments = []; this.pendingRequestId = ''; this.errorText = '';
    this.draft = '';
    this.localArtifacts = []; this.artifactError = ''; this.artifactRetryAt = 0;
    this.expandedTools = []; this.historyOpen = false;
    this.olderItems = []; this.historyCursor = ''; this.pendingResumeRequestId = ''; this.pendingResumeFingerprint = '';
    this.historyScope = 'phone';
    this.mode = 'workspace-write'; this.approvalMode = 'ask'; this.schedulePoll(10);
  }
  private async selectTask(id: string, external: boolean = false): Promise<void> {
    if (this.busy) { return; }
    this.cancelTaskPoll();
    this.busy = true; this.errorText = '';
    const epoch = this.epoch;
    try {
      const result = await this.client.call((external ? '/v1/threads/' : '/v1/tasks/') + id +
        (!external && this.taskDeltaSupported ? '?sync=delta' : ''));
      if (epoch === this.epoch && result.task !== undefined) {
        this.task = result.task; this.workspaceId = result.task.workspaceId;
        this.modelId = result.task.model; this.effort = result.task.effort; this.mode = result.task.mode;
        this.approvalMode = result.task.approvalMode || 'ask';
        this.attachments = []; this.pendingRequestId = ''; this.expandedTools = []; this.historyOpen = false;
        this.localArtifacts = []; this.artifactError = ''; this.artifactRetryAt = 0;
        this.olderItems = []; this.historyCursor = result.task.historyCursor || '';
        this.pendingResumeRequestId = ''; this.pendingResumeFingerprint = '';
        this.receiveArtifacts(result.task);
        this.scrollToLatest(true);
      }
    } catch (e) { if (epoch === this.epoch) { this.errorText = (e as Error).message; } }
    finally { if (epoch === this.epoch) { this.busy = false; this.schedulePoll(10); } }
  }
  private async send(): Promise<void> {
    if (this.busy || this.running() || (!this.draft.trim() && !this.attachments.length)) { return; }
    this.busy = true; this.errorText = '';
    const epoch = this.epoch;
    try {
      if (!this.permissionSettingsSupported && this.approvalMode !== 'ask') { throw new Error('请升级电脑端至 1.1.5 或更高版本，以修改审批方式'); }
      if (this.task === null) {
        const result = await this.client.call('/v1/tasks', { workspaceId: this.workspaceId,
          model: this.modelId, effort: this.effort, mode: this.mode, approvalMode: this.approvalMode });
        if (epoch !== this.epoch || result.task === undefined) { return; }
        this.task = result.task;
      }
      if (this.task.external) {
        if (!this.sameSessionSupported) { throw new Error('请升级电脑端至 1.1.4 或更高版本，以继续原会话'); }
        const originalId = this.task.id;
        const fingerprint = this.task.id + '/' + this.workspaceId + '/' + this.modelId + '/' + this.effort + '/' + this.mode + '/' + this.approvalMode;
        if (!this.pendingResumeRequestId || this.pendingResumeFingerprint !== fingerprint) {
          this.pendingResumeRequestId = util.generateRandomUUID(true); this.pendingResumeFingerprint = fingerprint;
        }
        const resumed = await this.client.call('/v1/threads/' + originalId + '/resume', {
          requestId: this.pendingResumeRequestId, workspaceId: this.workspaceId,
          model: this.modelId, effort: this.effort, mode: this.mode, approvalMode: this.approvalMode
        });
        if (epoch !== this.epoch || resumed.task === undefined) { return; }
        if (resumed.task.id !== originalId || resumed.task.sharedThread !== true || resumed.task.external === true ||
          resumed.task.workspaceId !== this.workspaceId || resumed.task.mode !== this.mode || (resumed.task.approvalMode || 'ask') !== this.approvalMode) {
          throw new Error('接力会话或权限与请求不符，已停止发送');
        }
        this.task = resumed.task; this.olderItems = []; this.historyCursor = resumed.task.historyCursor || '';
        this.pendingResumeRequestId = ''; this.pendingResumeFingerprint = '';
        this.historyScope = 'computer';
      }
      if (!this.pendingRequestId) { this.pendingRequestId = util.generateRandomUUID(true); }
      const result = await this.client.call('/v1/tasks/' + this.task.id + '/turns', {
        requestId: this.pendingRequestId, text: this.draft, attachments: this.attachments.map((a: CodexAttachment) => a.id),
        model: this.modelId, effort: this.effort, mode: this.mode, approvalMode: this.approvalMode
      });
      if (epoch === this.epoch && result.task !== undefined) {
        this.applyTask(result.task);
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
  private async pickAttachment(source: 'album' | 'camera' | 'file'): Promise<void> {
    if (this.busy || !this.connected || this.running() || this.attachments.length >= 6) { return; }
    this.busy = true; this.errorText = '';
    const epoch = this.epoch;
    const workspaceId = this.workspaceId;
    const image = source !== 'file';
    let file: fileIo.File | null = null;
    let cameraPath: string = '';
    try {
      let uris: string[] = [];
      if (source === 'camera') {
        const context = this.getUIContext().getHostContext();
        if (context === undefined) { throw new Error('页面已关闭，请返回对话后重试拍照'); }
        cameraPath = context.cacheDir + '/codex-camera-' + util.generateRandomUUID(true) + '.jpg';
        const output = await fileIo.open(cameraPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
        await fileIo.close(output);
        const saveUri = fileUri.getUriFromPath(cameraPath);
        const profile: cameraPicker.PickerProfile = {
          cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK, saveUri: saveUri
        };
        const result = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], profile);
        if (result.resultCode !== 0 || result.mediaType !== cameraPicker.PickerMediaType.PHOTO) { return; }
        uris = [result.resultUri.trim() || saveUri];
      } else if (source === 'album') {
        const options = new photoAccessHelper.PhotoSelectOptions();
        options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE; options.maxSelectNumber = 1;
        uris = (await new photoAccessHelper.PhotoViewPicker().select(options)).photoUris;
      } else {
        const options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 1;
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        uris = await new picker.DocumentViewPicker(context).select(options);
      }
      if (!uris.length || epoch !== this.epoch || this.screen !== CodexScreen.Workspace) { return; }
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
      if (epoch !== this.epoch || this.screen !== CodexScreen.Workspace) { return; }
      const name = new fileUri.FileUri(uris[0]).name || (image ? 'image' : 'file');
      const result = await this.client.call('/v1/uploads', { workspaceId: workspaceId, name: name,
        base64: new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer)), image: image });
      if (epoch === this.epoch && result.attachment !== undefined) {
        this.attachments = this.attachments.concat([result.attachment]);
      }
    } catch (e) { if (epoch === this.epoch) { this.errorText = (e as Error).message || '附件选择或上传失败'; } }
    finally {
      if (file !== null) { try { await fileIo.close(file); } catch (e) { } }
      if (cameraPath) { try { await fileIo.unlink(cameraPath); } catch (e) { } }
      if (epoch === this.epoch) { this.busy = false; this.schedulePoll(); }
    }
  }
  private toggleTool(id: string): void {
    this.expandedTools = this.expandedTools.includes(id) ? this.expandedTools.filter((v: string) => v !== id) : this.expandedTools.concat([id]);
  }

  private localArtifact(id: string): CodexLocalArtifact | undefined {
    return this.localArtifacts.find((item: CodexLocalArtifact) => item.id === id);
  }

  private async receiveArtifacts(task: CodexTask): Promise<void> {
    if (!task.artifacts?.length || !this.artifactsSupported || !this.connected || !this.active || this.screen !== CodexScreen.Workspace ||
      this.artifactSyncRunning || Date.now() < this.artifactRetryAt) { return; }
    const missing = task.artifacts.filter((item: CodexArtifact) => this.localArtifact(item.id) === undefined);
    if (!missing.length) { return; }
    const epoch = this.epoch;
    const current = (): boolean => epoch === this.epoch && this.connected && this.active &&
      this.screen === CodexScreen.Workspace && this.task?.id === task.id;
    this.artifactSyncRunning = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) { throw new Error('页面已关闭'); }
      const store = await CodexArtifactStore.create(context.filesDir, this.connectedOrigin, task.id);
      const failures: string[] = [];
      for (const artifact of missing) {
        if (!current()) { return; }
        this.receivingArtifactId = artifact.id; this.artifactProgress = '准备接收';
        try {
          const received = await store.receive(task.id, artifact, this.client, current, (count: number, total: number) => {
            if (current()) { this.artifactProgress = '接收中 ' + Math.floor(count * 100 / total) + '%'; }
          });
          if (!current()) { return; }
          this.localArtifacts = this.localArtifacts.concat([received]);
        } catch (e) {
          if (!current()) { return; }
          failures.push(artifact.name + '：' + ((e as Error).message || '接收失败'));
        }
      }
      this.artifactError = failures.join('\n');
      if (failures.length) { this.artifactRetryAt = Date.now() + 15000; }
    } catch (e) {
      if (current()) { this.artifactError = (e as Error).message || '文件接收失败，请稍后重试'; this.artifactRetryAt = Date.now() + 15000; }
    } finally {
      this.artifactSyncRunning = false;
      if (epoch === this.epoch) { this.receivingArtifactId = ''; this.artifactProgress = ''; }
    }
  }

  private async openArtifact(artifact: CodexArtifact): Promise<void> {
    const saved = this.localArtifact(artifact.id);
    if (saved === undefined) { return; }
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('此设备暂不支持系统预览，请使用“另存为”打开');
      }
      await openCodexArtifact(context as common.UIAbilityContext, saved);
    } catch (e) { this.artifactError = (e as Error).message || '文件预览失败，可另存为后打开'; }
  }

  private async exportArtifact(artifact: CodexArtifact): Promise<void> {
    const saved = this.localArtifact(artifact.id);
    if (saved === undefined) { return; }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (await exportCodexArtifact(context, saved)) {
        this.getUIContext().getPromptAction().showToast({ message: '文件已另存，原件保留在此会话中' });
      }
    } catch (e) { this.artifactError = (e as Error).message || '文件另存失败'; }
  }

  private async openHelp(section: CodexHelpSection): Promise<void> {
    const params: CodexHelpParams = { section: section };
    try {
      await router.pushUrl({ url: 'pages/codex/CodexHelpPage', params: params });
    } catch (e) {
      this.errorText = '无法打开连接指南，请稍后重试';
    }
  }

  @Builder private ConnectionForm() {
    CodexConnectionSetup({ origin: $originInput, token: $tokenInput, pairing: $pairingInput, remember: $remember,
      busy: this.busy, onScan: () => { this.scanPairingCode(); }, onImport: () => { this.importPairingFile(); },
      onPair: () => { this.pairFromInput(); }, onManualConnect: () => { this.connect(); } })
  }

  @Builder private TaskSettings() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('工作目录').fontSize(14).fontColor(AppTheme.text('#172033')).width(72)
        Select(this.workspaces.map((w: CodexWorkspace): SelectOption => ({ value: w.name })))
          .selected(this.selectIndex(this.workspaces.map((w: CodexWorkspace) => w.id), this.workspaceId))
          .value(this.workspaceName()).font({ size: 14 }).fontColor(AppTheme.text('#172033'))
          .optionFontColor(AppTheme.text('#172033')).selectedOptionFontColor(AppTheme.text('#5968FF'))
          .menuBackgroundColor(AppTheme.background('#FFFFFF')).backgroundColor(AppTheme.inputBackground())
          .height(44).borderRadius(12).padding({ left: 12, right: 12 })
          .onSelect((index: number) => {
            if (index >= 0 && index < this.workspaces.length) {
              this.workspaceId = this.workspaces[index].id; this.attachments = [];
            }
          })
          .enabled(this.task === null && !this.busy).layoutWeight(1)
      }.width('100%')
      Row({ space: 10 }) {
        Text('模型').fontSize(14).fontColor(AppTheme.text('#172033')).width(72)
        Select(this.models.map((m: CodexModel): SelectOption => ({ value: m.displayName || m.model })))
          .selected(this.selectIndex(this.models.map((m: CodexModel) => m.model), this.modelId))
          .value(this.modelName()).font({ size: 14 }).fontColor(AppTheme.text('#172033'))
          .optionFontColor(AppTheme.text('#172033')).selectedOptionFontColor(AppTheme.text('#5968FF'))
          .menuBackgroundColor(AppTheme.background('#FFFFFF')).backgroundColor(AppTheme.inputBackground())
          .height(44).borderRadius(12).padding({ left: 12, right: 12 })
          .onSelect((index: number) => { if (index >= 0 && index < this.models.length) { this.chooseModel(this.models[index].model); } })
          .enabled(!this.running() && !this.busy).layoutWeight(1)
      }.width('100%')
      if (this.efforts().length > 0) {
        Row({ space: 10 }) {
          Text('思考强度').fontSize(14).fontColor(AppTheme.text('#172033')).width(72)
          Select(this.efforts().map((e: CodexEffort): SelectOption => ({ value: e.reasoningEffort })))
            .selected(this.selectIndex(this.efforts().map((e: CodexEffort) => e.reasoningEffort), this.effort))
            .value(this.effort || '默认').font({ size: 14 }).fontColor(AppTheme.text('#172033'))
            .optionFontColor(AppTheme.text('#172033')).selectedOptionFontColor(AppTheme.text('#5968FF'))
            .menuBackgroundColor(AppTheme.background('#FFFFFF')).backgroundColor(AppTheme.inputBackground())
            .height(44).borderRadius(12).padding({ left: 12, right: 12 })
            .onSelect((index: number) => {
              if (index >= 0 && index < this.efforts().length) { this.effort = this.efforts()[index].reasoningEffort; }
            })
            .enabled(!this.running() && !this.busy).layoutWeight(1)
        }.width('100%')
      }
      Row({ space: 10 }) {
        Text('批准方式').fontSize(14).fontColor(AppTheme.text('#172033')).width(72)
        Select([{ value: '请求批准' }, { value: '帮我批准' }, { value: '完全访问控制' }])
          .selected(this.selectIndex(['ask', 'auto', 'full'], this.approvalMode))
          .value(codexApprovalLabel(this.approvalMode))
          .font({ size: 14 }).fontColor(AppTheme.text('#172033'))
          .optionFontColor(AppTheme.text('#172033')).selectedOptionFontColor(AppTheme.text('#5968FF'))
          .menuBackgroundColor(AppTheme.background('#FFFFFF')).backgroundColor(AppTheme.inputBackground())
          .height(44).borderRadius(12).padding({ left: 12, right: 12 })
          .onSelect((index: number) => { this.chooseApprovalMode(['ask', 'auto', 'full'][index] || 'ask'); })
          .enabled(this.permissionSettingsSupported && !this.running() && !this.busy).layoutWeight(1)
      }.width('100%')
      if (this.approvalMode !== 'full') {
        Row({ space: 10 }) {
          Text('文件访问').fontSize(14).fontColor(AppTheme.text('#172033')).width(72)
          Select([{ value: '只读分析' }, { value: '允许工作目录内修改' }])
            .selected(this.mode === 'workspace-write' ? 1 : 0)
            .value(this.mode === 'workspace-write' ? '允许目录内修改' : '只读分析')
            .font({ size: 14 }).fontColor(AppTheme.text('#172033'))
            .optionFontColor(AppTheme.text('#172033')).selectedOptionFontColor(AppTheme.text('#5968FF'))
            .menuBackgroundColor(AppTheme.background('#FFFFFF')).backgroundColor(AppTheme.inputBackground())
            .height(44).borderRadius(12).padding({ left: 12, right: 12 })
            .onSelect((index: number) => { this.mode = index === 1 ? 'workspace-write' : 'read-only'; })
            .enabled(!this.running() && !this.busy && (this.permissionSettingsSupported || this.task === null || this.task.external === true)).layoutWeight(1)
        }.width('100%')
      }
      Text(this.permissionDescription()).fontSize(12).lineHeight(19).fontColor(AppTheme.text('#747B87')).width('100%')
      if (!this.permissionSettingsSupported) {
        Text('升级电脑端至 1.1.5 或更高版本后，可修改已有对话的权限与批准方式。')
          .fontSize(12).lineHeight(19).fontColor(AppTheme.text('#AD6500')).width('100%')
      }
    }.padding(16).width('100%').backgroundColor(AppTheme.background('#F6F7FA')).borderRadius(20)
  }

  @Builder private SettingsSheet() {
    Scroll() {
      Column({ space: 18 }) {
        this.TaskSettings()
        Text('空闲时可修改设置，从下一条消息生效；正在执行或等待确认时不能更改。')
          .fontSize(12).lineHeight(19).fontColor(AppTheme.text('#747B87')).width('100%')
        if (this.task?.executionTransport === 'desktop') {
          Text('此会话与电脑实时共享。这里的权限设置用于下一次由手机发起的执行；电脑发起的任务使用电脑端设置，桌面运行目录与组织策略仍然生效。')
            .fontSize(12).lineHeight(19).fontColor(AppTheme.text('#747B87')).width('100%')
        }
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('自动跟随输出').fontSize(15).fontColor(AppTheme.text('#172033'))
            Text('新消息出现时滚动到底部').fontSize(12).fontColor(AppTheme.text('#747B87'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.followOutput }).selectedColor(AppTheme.filledBackground('#5968FF'))
            .onChange((value: boolean) => { this.followOutput = value; })
        }.width('100%').padding(16).backgroundColor(AppTheme.background('#F6F7FA')).borderRadius(20)
        Column({ space: 8 }) {
          Text(this.serverName).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
          Text(this.connectedOrigin).fontSize(12).fontColor(AppTheme.text('#747B87')).maxLines(2)
          Button('断开当前连接').width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
            .backgroundColor(AppTheme.filledBackground('#B94D4D')).fontColor(AppTheme.text(Color.White))
            .margin({ top: 10 }).onClick(() => { this.disconnect(); })
          Text('断开后，电脑上的任务仍会继续运行').fontSize(11).fontColor(AppTheme.text('#747B87'))
        }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 8 })
      }.width('100%').padding({ left: 20, right: 20, top: 16, bottom: 32 })
    }.width('100%').height('100%').align(Alignment.Top)
  }

  @Builder private MessageBody(item: CodexItem) {
    if (item.kind === 'user' || item.kind === 'assistant' || item.kind === 'plan') {
      MarkdownView({ text: item.text, variant: 'file_preview' })
    } else {
      Text(this.expandedTools.includes(item.id) ? item.text : item.text.slice(0, 160) + (item.text.length > 160 ? '\n点击展开…' : ''))
        .fontSize(12).fontFamily('monospace').fontColor(AppTheme.text('#293248'))
        .copyOption(CopyOptions.LocalDevice).onClick(() => { this.toggleTool(item.id); })
    }
  }

  @Builder private Message(item: CodexItem) {
    Column() {
      if (item.kind === 'user' || item.kind === 'assistant') {
        Column({ space: 0 }) {
          Row({ space: 8 }) {
            if (item.kind === 'user') {
              Text('我').fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#697386'))
            }
            Stack() {
              Image(item.kind === 'user' ? $r('app.media.codex_user') : $r('app.media.codex_openai'))
                .width(21).height(21).fillColor(AppTheme.text(item.kind === 'user' ? '#5968FF' : '#172033'))
            }.width(32).height(32).borderRadius(16).backgroundColor(AppTheme.background('#F4F6FA'))
            if (item.kind === 'assistant') {
              Text('Codex').fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#697386'))
            }
          }.width('100%').justifyContent(item.kind === 'user' ? FlexAlign.End : FlexAlign.Start).margin({ bottom: 8 })
          Column() {
            this.MessageBody(item)
          }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
            .borderRadius(18)
            .backgroundColor(AppTheme.background(item.kind === 'user' ? '#EEF0FF' : '#FFFFFF'))
        }.width(item.kind === 'user' ? '88%' : '94%')
      } else {
        Column({ space: 8 }) {
          Text(item.kind === 'diff' ? '文件变更' : item.kind === 'plan' ? '任务计划' : '执行记录')
            .fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#697386'))
            .onClick(() => { this.toggleTool(item.id); })
          this.MessageBody(item)
        }.width('94%').padding(16).alignItems(HorizontalAlign.Start).borderRadius(16)
          .backgroundColor(AppTheme.background('#FFFFFF'))
      }
    }.width('100%').alignItems(item.kind === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
      .padding({ bottom: 6 })
  }

  @Builder private Deliveries(artifacts: CodexArtifact[]) {
    Column({ space: 10 }) {
      Text('交付文件').fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#747B87')).width('100%')
      ForEach(artifacts, (artifact: CodexArtifact) => {
        CodexArtifactCard({ artifact: artifact, localPath: this.localArtifact(artifact.id)?.localPath || '',
          receiving: this.receivingArtifactId === artifact.id, progress: this.artifactProgress,
          onOpen: () => { this.openArtifact(artifact); }, onExport: () => { this.exportArtifact(artifact); },
          onRetry: () => { this.artifactRetryAt = 0; this.artifactError = ''; if (this.task !== null) { this.receiveArtifacts(this.task); } } })
      }, (artifact: CodexArtifact) => artifact.id)
    }.width('94%').alignItems(HorizontalAlign.Start).margin({ bottom: 8 })
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
      Row({ space: 8 }) {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.codex_plus')).width(24).height(24).fillColor(AppTheme.text('#172033'))
        }.width(40).height(40).padding(0).backgroundColor(Color.Transparent).accessibilityText('添加照片、拍照或文件')
          .bindMenu([{ value: '照片', action: () => { this.pickAttachment('album'); } },
            { value: '相机', action: () => { this.pickAttachment('camera'); } },
            { value: '文件', action: () => { this.pickAttachment('file'); } }])
          .enabled(!this.busy && !this.running() && this.attachments.length < 6)
        TextArea({ placeholder: this.running() ? '正在执行，可随时停止' : '发消息或描述任务…', text: this.draft })
          .layoutWeight(1).height(chatComposerTextAreaHeight(this.draft)).barState(BarState.Auto)
          .fontSize(15).lineHeight(22).maxLength(20000).backgroundColor(Color.Transparent)
          .padding({ left: 0, right: 0, top: 11, bottom: 11 })
          .fontColor(AppTheme.text('#172033')).placeholderColor($r('app.color.ui_text_placeholder'))
          .enabled(!this.busy && !this.running()).onChange((v: string) => { this.draft = v; })
        if (this.running()) {
          Button('停止').fontSize(13).height(40).width(58).padding(0).backgroundColor(AppTheme.filledBackground('#B94D4D'))
            .fontColor(AppTheme.text(Color.White))
            .enabled(!this.busy).onClick(() => { this.stop(); })
        } else {
          Button({ type: ButtonType.Circle }) {
            if (this.busy) {
              LoadingProgress().width(20).height(20).color(Color.White)
            } else {
              Image($r('app.media.codex_send')).width(22).height(22).fillColor(Color.White)
            }
          }.width(40).height(40).padding(0).accessibilityText(this.busy ? '正在处理' : '发送消息')
            .backgroundColor(AppTheme.filledBackground('#172033'))
            .enabled(!this.busy && (this.draft.trim().length > 0 || this.attachments.length > 0))
            .onClick(() => { this.send(); })
        }
      }.width('100%').height(chatComposerBarHeight(this.draft)).alignItems(VerticalAlign.Center)
      if (this.attachments.length > 0) {
        Text('附件上传至当前电脑，每项不超过 8 MiB，最多 6 项')
          .fontSize(10).fontColor(AppTheme.text('#747B87')).width('100%')
      }
    }.padding({ left: 8, right: 8, top: 2, bottom: 2 }).backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(28)
    .border({ width: 1, color: AppTheme.border('#ECEEF3') })
    .margin({ left: 16, right: 16, bottom: this.navigationBottomInset + 8 })
  }

  @Builder private Header() {
    if (this.screen === CodexScreen.Workspace && this.connected) {
      CodexWorkspaceHeader({ serverName: this.serverName, workspaceName: this.workspaceName(), connectionStatus: this.linkLabel(),
        onHistory: () => { this.openHistory(); },
        onSettings: () => { this.historyOpen = false; this.taskSettingsOpen = true; } })
    } else {
      AppHeader({ title: this.screen === CodexScreen.Setup ? '创建连接' : 'Codex',
        showBackButton: this.screen === CodexScreen.Setup,
        onBackClick: () => { this.errorText = ''; this.screen = CodexScreen.Connections; } })
    }
  }
  @Builder private Content() {
    Column({ space: 0 }) {
      if (this.connected && this.screen === CodexScreen.Workspace && (this.networkText || codexExecutionNotice(this.task, this.statusNow))) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color(AppTheme.text('#AD6500'))
          Text(this.networkText || codexExecutionNotice(this.task, this.statusNow))
            .fontSize(12).lineHeight(18).fontColor(AppTheme.text('#AD6500')).layoutWeight(1)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .backgroundColor(AppTheme.background('#FFF7E8'))
      }
      Scroll(this.scroller) {
        Column({ space: 14 }) {
          if (this.screen === CodexScreen.Setup) {
            this.ConnectionForm()
          } else if (this.screen === CodexScreen.Connections) {
            CodexConnectionsView({ connections: this.savedConnections, loading: this.connectionsLoading,
              currentOrigin: this.connected ? this.connectedOrigin : '', currentName: this.serverName, currentStatus: this.linkLabel(),
              connectingOrigin: this.connectingOrigin, busy: this.busy,
              onCreate: () => { this.openConnectionSetup(); },
              onHelp: (section: CodexHelpSection) => { this.openHelp(section); },
              onConnect: (item: CodexSavedConnection) => { this.openSavedConnection(item); },
              onForget: (item: CodexSavedConnection) => { this.forgetSavedConnection(item); },
              onDisconnect: () => { this.disconnect(); },
              onResume: () => { this.screen = CodexScreen.Workspace; } })
          } else if (this.connected) {
            if (this.task === null) {
              Column({ space: 14 }) {
                Image($r('app.media.codex_openai')).width(42).height(42).fillColor(AppTheme.text('#172033'))
                Text('今天一起做点什么？').fontSize(23).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
                Text('聊聊想法，或发张截图给 Codex').fontSize(14).fontColor(AppTheme.text('#747B87'))
              }.width('100%').padding({ top: 72, bottom: 48 })
            }
            if (this.task?.external) {
              Text(this.sameSessionSupported ? '发送消息将继续此电脑会话。请先在电脑释放该会话；手机执行结束后自动交还。' :
                '升级电脑端至 1.1.4 或更高版本后，可在此继续原会话。')
                .fontSize(12).lineHeight(18).fontColor(AppTheme.text('#747B87')).width('100%')
            } else if (this.task?.sharedThread) {
              Text('与电脑共用此会话 · 接力执行').fontSize(11).fontColor(AppTheme.text('#747B87')).width('100%')
            } else if (this.task?.sourceThreadId) {
              Text('由电脑会话继续 · 手机副本').fontSize(11).fontColor(AppTheme.text('#747B87')).width('100%')
            }
            if (this.task?.truncated) { Text('部分历史已精简显示，完整上下文保留在电脑 Codex 中。').fontSize(11).fontColor(AppTheme.text('#747B87')) }
            if (this.historyCursor) {
              Button('查看更早记录').fontSize(12).height(36).backgroundColor(Color.Transparent)
                .fontColor(AppTheme.text('#5968FF')).enabled(!this.busy).onClick(() => { this.loadOlderHistory(); })
            }
            ForEach(this.timeline(), (entry: CodexTimelineEntry) => {
              Column({ space: 10 }) {
                if (entry.item !== undefined) { this.Message(entry.item) }
                else { Text('更早对话的文件 · 加载历史可查看原对话').fontSize(11).fontColor(AppTheme.text('#747B87')) }
                if (entry.artifacts.length > 0) { this.Deliveries(entry.artifacts) }
              }.width('100%').alignItems(HorizontalAlign.Start)
            }, (entry: CodexTimelineEntry) => codexTimelineKey(entry))
            if (this.artifactError || this.task?.artifactWarning) {
              Text(this.artifactError || this.task?.artifactWarning || '').fontSize(12).lineHeight(18)
                .fontColor(AppTheme.text('#B94D4D')).width('100%')
            }
            if (!this.artifactsSupported) {
              Text('当前电脑端不支持文件回传，请升级 ClawMate Codex 电脑端。').fontSize(11)
                .fontColor(AppTheme.text('#747B87')).width('100%')
            }
            ForEach(this.approvals(), (approval: CodexApproval) => {
              CodexApprovalCard({ approval: approval, busy: this.busy,
                onAnswer: (id: string, decision: string, answers: CodexAnswer[]) => { this.taskAction('approvals', id, decision, answers); } })
            }, (approval: CodexApproval) => approval.id)
            if (this.task !== null) {
              Text(codexStatusLabel(this.task.status)).fontSize(11).fontColor(AppTheme.text('#747B87')).width('100%')
            }
            if (this.task?.error) { Text(this.task.error).fontSize(12).fontColor(AppTheme.text('#B94D4D')).width('100%') }
          }
          if (this.errorText) {
            Text(this.errorText).fontSize(12).lineHeight(19).fontColor(AppTheme.text('#B94D4D')).width('100%')
            if (this.screen === CodexScreen.Setup && this.pairedConnection !== null) {
              Button('重试连接').fontSize(13).backgroundColor(Color.Transparent).fontColor(AppTheme.text('#5968FF'))
                .enabled(!this.busy).onClick(() => { this.connect(); })
            }
            if (this.screen === CodexScreen.Connections) {
              Button('重新读取连接').fontSize(13).backgroundColor(Color.Transparent).fontColor(AppTheme.text('#5968FF'))
                .enabled(!this.busy).onClick(() => { this.errorText = ''; this.restoreConnections(); })
            }
          }
        }.padding({ left: 20, right: 20, top: 16, bottom: 24 }).width('100%')
          .onAreaChange(() => { this.contentSizeChanged(); })
      }.layoutWeight(1).width('100%').align(Alignment.Top)
        .clip(true).onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { this.bottomUntil = 0; this.scrollGeneration++; } })
      if (this.connected && this.screen === CodexScreen.Workspace) { this.Composer() }
      else { Blank().height(this.navigationBottomInset) }
    }.width('100%').height('100%')
  }
  build() {
    Stack({ alignContent: Alignment.Start }) {
      FrostedPage({ pageBackgroundColor: '#F6F7FA', scrollers: [this.scroller], titleFadeHeight: 0,
        headerBuilder: () => { this.Header(); }, contentBuilder: () => { this.Content(); } })
      if (this.historyOpen && this.connected && this.screen === CodexScreen.Workspace) {
        CodexHistoryDrawer({ tasks: this.historyScope === 'computer' ? this.computerTasks : this.tasks, workspaces: this.workspaces,
          selectedId: this.task?.id || '', serverName: this.serverName,
          scope: this.historyScope, supportsComputerHistory: this.existingSessionsSupported,
          loading: this.computerLoading, hasMore: this.computerCursor.length > 0,
          busy: this.busy, notice: this.historyError || this.errorText || this.networkText, bottomInset: this.navigationBottomInset,
          onClose: () => { this.historyOpen = false; }, onNewTask: () => { this.newTask(); },
          onScope: (scope: string) => { this.changeHistoryScope(scope); },
          onRefresh: () => { this.loadComputerHistory(true); }, onMore: () => { this.loadComputerHistory(false); },
          onSelect: (id: string) => { this.selectTask(id, this.historyScope === 'computer'); },
          onConnections: () => { this.historyOpen = false; this.screen = CodexScreen.Connections; } })
      }
    }.width('100%').height('100%')
    .bindSheet($$this.taskSettingsOpen, this.SettingsSheet(), {
      height: SheetSize.LARGE, title: { title: '对话设置' }, showClose: true,
      backgroundColor: AppTheme.background('#FFFFFF')
    })
  }
}
