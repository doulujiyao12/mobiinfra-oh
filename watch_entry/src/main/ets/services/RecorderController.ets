import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { worker, MessageEvents } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { audio } from '@kit.AudioKit';
import { media } from '@kit.MediaKit';
import { preferences } from '@kit.ArkData';
import { CaptureCommand, CaptureEvent, RecordingInfo, RecordingMode, WatchState } from '../model/RecorderModels';
import { backgroundTasks } from './BackgroundTasks';
import { phoneSyncController } from './PhoneSyncController';
type StateListener = (state: WatchState) => void;

class RecorderController {
  private context: common.UIAbilityContext | undefined = undefined;
  private captureWorker: worker.ThreadWorker | undefined = undefined;
  private listener: StateListener | undefined = undefined;
  private state: WatchState = new WatchState();
  private foreground: boolean = false;
  private backgroundActive: boolean = false;
  private player: media.AVPlayer | undefined = undefined;
  private playbackFile: fs.File | undefined = undefined;
  private playbackGeneration: number = 0;
  private shuttingDown: boolean = false;
  private taskCallbackRegistered: boolean = false;
  private transitionTimer: number = -1;
  private settings: preferences.Preferences | undefined = undefined;

  private onTaskCancel = (): void => {
    this.backgroundActive = false;
    if (this.state.status === 'recording' || this.state.status === 'starting') {
      this.stop('后台录音任务已被系统取消，已有内容已保存');
    }
  };

  initialize(context: common.UIAbilityContext): void {
    if (this.captureWorker !== undefined) { return; }
    this.context = context;
    this.shuttingDown = false;
    try {
      this.settings = preferences.getPreferencesSync(context, { name: 'recorder_settings' });
      this.state.mode = this.settings.getSync('mode', 'sound') === 'speech' ? 'speech' : 'sound';
    } catch (_) { this.state.notice = '已使用默认的声音模式'; }
    try {
      const instance: worker.ThreadWorker = new worker.ThreadWorker('watch_entry/ets/workers/RecorderWorker.ets', {
        name: 'ClawMateAudio'
      });
      this.captureWorker = instance;
      instance.onmessage = (event: MessageEvents): void => {
        this.handleCaptureEvent(event.data as CaptureEvent).catch((error: BusinessError) => {
          this.state.error = this.describe(error);
          this.stop('录音状态异常，已有内容将保留');
          this.emit();
        });
      };
      instance.onerror = (): void => { this.workerFailed('录音线程异常，请重新打开应用恢复文件'); };
      instance.onexit = (): void => {
        if (!this.shuttingDown) { this.workerFailed('录音线程已退出，请重新打开应用恢复文件'); }
      };
      if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
        backgroundTasks.initialize(context);
        backgroundTasks.onCancel(this.onTaskCancel);
        this.taskCallbackRegistered = true;
      }
      const command: CaptureCommand = new CaptureCommand();
      command.kind = 'init';
      command.filesDir = context.filesDir;
      instance.postMessage(command);
    } catch (error) {
      this.workerFailed(this.describe(error as BusinessError));
    }
  }

  subscribe(listener: StateListener): void {
    this.listener = listener;
    this.emit();
  }

  unsubscribe(): void { this.listener = undefined; }

  setForeground(value: boolean): void {
    this.foreground = value;
    if (!value) {
      this.stopPlayback().catch(() => {});
      if (this.state.status === 'starting') {
        this.stop('启动时应用离开前台，请打开应用重新开始');
      }
    }
  }

  private emit(): void {
    if (this.listener === undefined) { return; }
    const snapshot: WatchState = new WatchState();
    snapshot.status = this.state.status;
    snapshot.durationMs = this.state.durationMs;
    snapshot.level = this.state.level;
    snapshot.segment = this.state.segment;
    snapshot.records = this.state.records.slice();
    snapshot.availableBytes = this.state.availableBytes;
    snapshot.notice = this.state.notice;
    snapshot.error = this.state.error;
    snapshot.playingName = this.state.playingName;
    snapshot.playbackMs = this.state.playbackMs;
    snapshot.playbackDurationMs = this.state.playbackDurationMs;
    snapshot.playbackStatus = this.state.playbackStatus;
    snapshot.inputRate = this.state.inputRate;
    snapshot.listeningMs = this.state.listeningMs;
    snapshot.saving = this.state.saving;
    snapshot.mode = this.state.mode;
    this.listener(snapshot);
  }

  private describe(error: BusinessError): string {
    return `${error.message || '系统操作失败'}${error.code ? ` (${error.code})` : ''}`;
  }

  private post(kind: string, reason: string = '', name: string = ''): void {
    const command: CaptureCommand = new CaptureCommand();
    command.kind = kind;
    command.reason = reason;
    command.name = name;
    command.mode = this.state.mode;
    this.captureWorker?.postMessage(command);
  }

  private clearTransitionTimer(): void {
    if (this.transitionTimer !== -1) { clearTimeout(this.transitionTimer); this.transitionTimer = -1; }
  }

  async selectMode(mode: RecordingMode): Promise<void> {
    if (this.state.status !== 'ready' || (mode !== 'sound' && mode !== 'speech')) { return; }
    this.state.mode = mode;
    this.state.error = '';
    this.emit();
    try {
      if (this.settings === undefined) { throw new Error('模式设置不可用'); }
      this.settings.putSync('mode', mode);
      await this.settings.flush();
    } catch (_) {
      this.state.error = '模式已切换，但未能记住选择；下次打开请检查模式';
      this.emit();
    }
  }

  async start(): Promise<void> {
    if (this.state.status !== 'ready' || this.context === undefined || this.captureWorker === undefined) { return; }
    if (!this.foreground) { this.state.error = '请在手表上打开应用后开始录音'; this.emit(); return; }
    if (!canIUse('SystemCapability.Multimedia.Audio.Capturer') ||
      !canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      this.state.error = '当前设备缺少音频采集或后台录音能力'; this.emit(); return;
    }
    this.state.status = 'starting';
    this.state.error = '';
    this.state.notice = '';
    this.state.durationMs = 0;
    this.state.listeningMs = 0;
    this.state.saving = false;
    this.state.segment = 0;
    this.emit();
    try {
      await this.stopPlayback();
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context,
        ['ohos.permission.MICROPHONE']);
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        throw new Error('麦克风权限未开启，请在手表的应用权限设置中允许录音');
      }
      if (!this.foreground || this.state.status !== 'starting') {
        throw new Error('请保持应用在前台完成录音启动');
      }
      this.transitionTimer = setTimeout(() => {
        this.stop('录音启动超时，请重新打开应用');
      }, 15000);
      this.post('start');
    } catch (error) {
      this.state.status = 'ready';
      this.state.error = this.describe(error as BusinessError);
      this.emit();
    }
  }

  stop(reason: string = '监听已结束'): void {
    if (this.state.status !== 'recording' && this.state.status !== 'starting') { return; }
    this.clearTransitionTimer();
    this.state.status = 'stopping';
    this.state.level = 0;
    this.emit();
    this.post('stop', reason);
  }

  refresh(): void { this.post('list'); }

  async deleteRecording(record: RecordingInfo): Promise<void> {
    if (this.state.status !== 'ready') { return; }
    if (phoneSyncController.isFileInUse(record.name)) {
      this.state.error = '该录音正在同步，请完成或取消后再删除'; this.emit(); return;
    }
    if (this.state.playingName === record.name) { await this.stopPlayback(); }
    if (phoneSyncController.isFileInUse(record.name)) { return; }
    this.post('delete', '', record.name);
  }

  private async beginBackgroundTask(): Promise<void> {
    await backgroundTasks.setMode('audioRecording', true);
    this.backgroundActive = true;
  }

  private async endBackgroundTask(): Promise<void> {
    if (!this.backgroundActive || this.context === undefined) { return; }
    this.backgroundActive = false;
    try { await backgroundTasks.setMode('audioRecording', false); } catch (_) {}
  }

  private async handleCaptureEvent(event: CaptureEvent): Promise<void> {
    if (this.shuttingDown) { return; }
    if (event.kind === 'ready') {
      this.state.status = 'ready';
      if (event.message.length > 0) { this.state.error = event.message; }
    } else if (event.kind === 'library') {
      this.state.records = event.records;
      this.state.availableBytes = event.availableBytes;
      if (event.recoveredCount > 0) { this.state.notice = `已恢复 ${event.recoveredCount} 个未完成录音片段`; }
    } else if (event.kind === 'started') {
      this.clearTransitionTimer();
      if (this.state.status !== 'starting' || !this.foreground) {
        this.post('stop', '应用已离开前台，请重新开始录音');
        return;
      }
      try {
        await this.beginBackgroundTask();
        // A home-key press or task cancellation can race the asynchronous task request.
        if (this.state.status !== 'starting' || !this.foreground) {
          this.post('stop', '录音启动被中断，已有内容已保存');
          return;
        }
        this.state.status = 'recording';
        this.state.inputRate = event.inputRate;
      } catch (error) {
        this.state.error = `后台录音启动失败：${this.describe(error as BusinessError)}`;
        this.stop('无法启用后台录音，已停止采集');
      }
    } else if (event.kind === 'meter' || event.kind === 'activity' || event.kind === 'segment') {
      if (this.state.status === 'recording' || this.state.status === 'starting') {
        this.state.durationMs = event.durationMs;
        if (event.kind === 'meter') { this.state.level = event.level; }
        this.state.segment = event.segment;
        this.state.listeningMs = event.listeningMs;
        this.state.saving = event.saving;
      }
    } else if (event.kind === 'stopped') {
      this.clearTransitionTimer();
      this.state.status = 'stopping';
      await this.endBackgroundTask();
      this.state.status = 'ready';
      this.state.level = 0;
      this.state.durationMs = event.durationMs;
      this.state.listeningMs = event.listeningMs;
      this.state.segment = event.segment;
      this.state.saving = false;
      this.state.notice = event.message;
    } else if (event.kind === 'error') {
      this.state.error = event.message;
      if (this.state.status === 'loading') { this.state.status = 'failed'; }
    } else if (event.kind === 'deleted') {
      this.state.notice = event.message;
    }
    this.emit();
  }

  private workerFailed(message: string): void {
    this.clearTransitionTimer();
    this.state.status = 'failed';
    this.state.error = message;
    this.state.level = 0;
    this.state.saving = false;
    // If the capture thread crashed, its incomplete .part file is recovered on next launch.
    this.endBackgroundTask().catch(() => {});
    this.emit();
  }

  async play(record: RecordingInfo): Promise<void> {
    if (this.state.status !== 'ready' || !this.foreground) { return; }
    await this.stopPlayback();
    if (this.state.status !== 'ready' || !this.foreground) { return; }
    const generation: number = ++this.playbackGeneration;
    this.state.playingName = record.name;
    this.state.playbackStatus = 'loading';
    this.state.playbackDurationMs = record.durationMs;
    this.state.playbackMs = 0;
    this.state.error = '';
    this.emit();
    let instance: media.AVPlayer | undefined = undefined;
    try {
      instance = await media.createAVPlayer();
      if (generation !== this.playbackGeneration) { await instance.release(); return; }
      this.player = instance;
      const active: media.AVPlayer = instance;
      active.on('stateChange', (state: string): void => {
        if (generation !== this.playbackGeneration) { return; }
        if (state === 'initialized') {
          active.audioRendererInfo = { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 };
          active.prepare().catch((error: BusinessError) => this.playerFailed(error, generation));
        } else if (state === 'prepared') {
          active.play().catch((error: BusinessError) => this.playerFailed(error, generation));
        } else if (state === 'playing') {
          this.state.playbackStatus = 'playing';
          this.emit();
        } else if (state === 'completed') {
          this.stopPlayback().catch(() => {});
        }
      });
      active.on('timeUpdate', (time: number): void => {
        if (generation !== this.playbackGeneration) { return; }
        this.state.playbackMs = time;
        this.emit();
      });
      active.on('error', (error: BusinessError): void => this.playerFailed(error, generation));
      this.playbackFile = fs.openSync(record.path, fs.OpenMode.READ_ONLY);
      active.fdSrc = { fd: this.playbackFile.fd, offset: 0, length: record.bytes };
    } catch (error) {
      this.playerFailed(error as BusinessError, generation);
    }
  }

  private playerFailed(error: BusinessError, generation: number): void {
    if (generation !== this.playbackGeneration) { return; }
    this.state.error = `无法播放：${this.describe(error)}`;
    this.stopPlayback().catch(() => {});
  }

  async stopPlayback(): Promise<void> {
    this.playbackGeneration++;
    const current: media.AVPlayer | undefined = this.player;
    const handle: fs.File | undefined = this.playbackFile;
    this.player = undefined;
    this.playbackFile = undefined;
    this.state.playingName = '';
    this.state.playbackStatus = 'idle';
    this.state.playbackMs = 0;
    this.emit();
    if (current !== undefined) {
      try { await current.release(); } catch (_) {}
    }
    if (handle !== undefined) {
      try { fs.closeSync(handle.fd); } catch (_) {}
    }
  }

  async destroy(): Promise<void> {
    this.clearTransitionTimer();
    await this.stopPlayback();
    if (this.taskCallbackRegistered) {
      backgroundTasks.offCancel(this.onTaskCancel);
    }
    // Allow the worker to stop, finalize its file and release audio before termination.
    if (this.captureWorker !== undefined) {
      this.post('stop', '应用已关闭，录音已保存');
      await new Promise<void>((resolve: () => void) => {
        const timer: number = setInterval(() => {
          if (this.state.status === 'ready' || this.state.status === 'failed') {
            clearInterval(timer); clearTimeout(timeout); resolve();
          }
        }, 50);
        const timeout: number = setTimeout(() => { clearInterval(timer); resolve(); }, 2500);
      });
      this.shuttingDown = true;
      this.captureWorker.terminate();
      this.captureWorker = undefined;
    }
    await this.endBackgroundTask();
    this.listener = undefined;
  }
}

export const recorderController: RecorderController = new RecorderController();
