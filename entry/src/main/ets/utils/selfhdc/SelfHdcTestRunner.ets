import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { AppLogger } from '../AppLogger';
import { DebugSettings } from '../DebugSettings';
import { getAppBundleName } from '../AppIdentity';
import { AgentExecutionController } from '../AgentExecutionController';
import { HdcClient } from './HdcClient';
import {
  selfHdcEnsureDirectory, selfHdcExists, selfHdcReadText, selfHdcWrite, selfHdcWriteText, selfHdcWriteAtomicText
} from './SelfHdcFiles';
import {
  parseSelfHdcEndpoint, selfHdcHasCommandFailure, selfHdcShellQuote, selfHdcSwipeForSize
} from './SelfHdcPolicy';
import { selfHdcErrorText } from './SelfHdcError';
import { SelfHdcTaskSettings } from './SelfHdcTaskSettings';

export class SelfHdcTestState {
  running: boolean = false;
  outcome: string = 'idle';
  runId: string = '';
  stage: string = '尚未开始';
  message: string = '';
  endpoint: string = '';
  logPath: string = '';
  beforeImage: string = '';
  afterImage: string = '';
  logs: string[] = [];
}

export interface SelfHdcTestConfig {
  ip: string;
  port: string;
  connectionOnly: boolean;
}

export async function selfHdcLocalIpv4(): Promise<string[]> {
  try {
    let addresses: string[] = [];
    let nets = await connection.getAllNets();
    for (let index = 0; index < nets.length; index++) {
      let properties = await connection.getConnectionProperties(nets[index]);
      properties.linkAddresses.forEach((link: connection.LinkAddress): void => {
        let ip = link.address.address;
        if (/^\d+\.\d+\.\d+\.\d+$/.test(ip) && addresses.indexOf(ip) < 0) { addresses.push(ip); }
      });
    }
    return addresses;
  } catch (e) { throw new Error('SELF_HDC_NETWORK: ' + selfHdcErrorText(e as Error)); }
}

// The runner outlives the page while Alipay is in front. Page disappearance only detaches its observer.
export class SelfHdcTestRunner {
  private static instance: SelfHdcTestRunner = new SelfHdcTestRunner();
  private state: SelfHdcTestState = new SelfHdcTestState();
  private observers: Array<(state: SelfHdcTestState) => void> = [];
  private root: string = '';
  private client: HdcClient | undefined = undefined;
  private cancelled: boolean = false;
  private backgroundExpired: boolean = false;
  private suspendRequest: number = -1;
  private startedAt: number = 0;
  private externalCancel: (() => void) | undefined = undefined;

  static shared(): SelfHdcTestRunner { return SelfHdcTestRunner.instance; }

  initialize(filesDir: string): void {
    if (this.root.length > 0) { return; }
    let root = filesDir + '/self_hdc';
    selfHdcEnsureDirectory(root + '/runs');
    this.root = root;
    let latest = this.root + '/latest.json';
    if (selfHdcExists(latest)) {
      try {
        let saved = ArkJSON.parse(selfHdcReadText(latest, 256 * 1024)) as SelfHdcTestState;
        if (saved.runId && Array.isArray(saved.logs)) {
          this.state = saved;
          if (saved.running) {
            this.startedAt = Date.now();
            this.state.running = false;
            this.state.outcome = 'interrupted';
            this.state.message = '上次测试未结束，App 可能被终止或冻结；请查看最后一个日志阶段。';
            this.record(this.state.message);
            this.persist();
          }
        }
      } catch (e) {
        AppLogger.warnCause('SelfHdc', 'Cannot restore latest run', e as Error);
      }
    }
  }

  snapshot(): SelfHdcTestState {
    let result = new SelfHdcTestState();
    result.running = this.state.running;
    result.outcome = this.state.outcome;
    result.runId = this.state.runId;
    result.stage = this.state.stage;
    result.message = this.state.message;
    result.endpoint = this.state.endpoint;
    result.logPath = DebugSettings.isEnabled() ? this.state.logPath : '';
    result.beforeImage = this.state.beforeImage;
    result.afterImage = this.state.afterImage;
    result.logs = DebugSettings.isEnabled() ? this.state.logs.slice() : [];
    return result;
  }

  subscribe(observer: (state: SelfHdcTestState) => void): void {
    this.observers.push(observer);
    observer(this.snapshot());
  }

  unsubscribe(observer: (state: SelfHdcTestState) => void): void {
    this.observers = this.observers.filter((item: (state: SelfHdcTestState) => void): boolean => item !== observer);
  }

  private publish(): void {
    AppStorage.setOrCreate('selfHdcRunning', this.state.running);
    this.observers.forEach((observer: (state: SelfHdcTestState) => void): void => { observer(this.snapshot()); });
  }

  private record(message: string): void {
    // Progress still reaches observers when Debug is off. No line formatting,
    // in-memory accumulation or disk log writes occur in that case.
    if (!DebugSettings.isEnabled()) { this.publish(); return; }
    if (this.state.logPath.length === 0 && this.state.runId.length > 0) {
      this.state.logPath = this.root + '/runs/' + this.state.runId + '.log';
    }
    let line = new Date().toISOString() + ' +' + String(Date.now() - this.startedAt) + 'ms [' +
      this.state.stage + '] ' + message;
    if (this.state.logPath.length > 0) { selfHdcWriteText(this.state.logPath, line + '\n', true); }
    this.state.logs.push(line);
    if (this.state.logs.length > 160) { this.state.logs.shift(); }
    AppLogger.info('SelfHdc', line);
    this.publish();
  }

  private recordSafely(message: string): void {
    try { this.record(message); } catch (e) {
      this.state.message += '\n日志写入失败：' + (e as Error).message;
      AppLogger.errorCause('SelfHdc', 'Persistent log failed', e as Error);
    }
  }

  private persist(): void {
    let summary = ArkJSON.stringify(this.snapshot());
    selfHdcWriteAtomicText(this.root + '/latest.json', summary);
    if (DebugSettings.isEnabled() && this.state.runId) {
      selfHdcWriteAtomicText(this.root + '/runs/' + this.state.runId + '.json', summary);
    }
  }

  private step(stage: string): void {
    this.checkCancelled();
    this.state.stage = stage;
    this.record('STAGE_BEGIN');
    this.persist();
  }

  private checkCancelled(): void {
    if (this.cancelled) { throw new Error('SELF_HDC_CANCELLED: 用户停止测试'); }
    if (this.backgroundExpired) { throw new Error('SELF_HDC_BACKGROUND: 系统短时后台运行额度已到期'); }
  }

  cancel(): void {
    if (!this.state.running) { return; }
    this.cancelled = true;
    this.recordSafely('CANCEL requested; 已发送的操作不会回滚，不再发送后续动作');
    if (this.externalCancel) { this.externalCancel(); return; }
    this.client?.close();
  }

  beginExternal(filesDir: string, title: string, endpoint: string, cancel: () => void,
    mode: string = 'phone-workflow'): void {
    this.initialize(filesDir);
    if (this.state.running) { throw new Error('SELF_HDC_BUSY: 手机测试或 GUI 任务正在执行'); }
    this.state = new SelfHdcTestState();
    this.state.running = true; this.state.outcome = 'running';
    this.state.runId = String(Date.now()) + '_' + String(Math.floor(Math.random() * 1000000));
    this.state.endpoint = endpoint;
    this.state.stage = mode === 'phone-chat-local' ? '手机本地 Agent' :
      (mode === 'phone-chat-cloud' ? '手机云端 Agent' : '手机 GUI 任务');
    this.state.message = title;
    this.startedAt = Date.now(); this.cancelled = false; this.externalCancel = cancel;
    this.record('RUN mode=' + mode + ' title=' + title + ' transport=direct-device-TCP');
    this.persist();
  }

  recordExternal(message: string): void {
    if (!this.externalCancel) { return; }
    this.record(message.substring(0, 6000));
    if (message.startsWith('ACTION_BEGIN') || message.indexOf('STAGE_BEGIN') >= 0) { this.persist(); }
  }

  setExternalEndpoint(endpoint: string): void {
    if (!this.externalCancel) { return; }
    this.state.endpoint = endpoint;
    this.persist(); this.publish();
  }

  setExternalImage(path: string, first: boolean): void {
    if (!this.externalCancel || !path.startsWith(this.root + '/runs/')) { return; }
    if (first) { this.state.beforeImage = path; } else { this.state.afterImage = path; }
    this.persist(); this.publish();
  }

  finishExternal(outcome: string, message: string): void {
    if (!this.externalCancel) { return; }
    this.state.outcome = outcome; this.state.message = message; this.state.running = false;
    this.recordSafely('RUN_FINISH outcome=' + outcome + ' result=' + message);
    this.externalCancel = undefined;
    this.persist(); this.publish();
  }

  clearLogs(): void {
    if (this.state.running) { throw new Error('SELF_HDC_BUSY: 请先停止当前测试或任务，再清空日志'); }
    if (!this.root) { throw new Error('SELF_HDC_FILE: 日志目录尚未初始化'); }
    // Only files generated by this logger. Leave keys, connection settings, screenshots and workflow outputs intact.
    for (let name of fs.listFileSync(this.root + '/runs')) {
      let path = this.root + '/runs/' + name;
      if (/^\d+_\d+\.log$/.test(name)) { fs.unlinkSync(path); }
      if (/^\d+_\d+\.json$/.test(name)) {
        let saved = ArkJSON.parse(selfHdcReadText(path, 256 * 1024)) as SelfHdcTestState;
        saved.logs = [];
        selfHdcWriteAtomicText(path, ArkJSON.stringify(saved));
      }
    }
    this.state.logs = []; this.state.logPath = '';
    this.persist(); this.publish();
  }

  private async pause(ms: number): Promise<void> {
    let deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      this.checkCancelled();
      await new Promise<void>((resolve): void => { setTimeout(resolve, Math.min(100, deadline - Date.now())); });
    }
    this.checkCancelled();
  }

  private async execute(command: string, timeoutMs: number = 20000, binaryText: boolean = false): Promise<string> {
    this.checkCancelled();
    if (!this.client) { throw new Error('SELF_HDC_INTERNAL: no client'); }
    this.record('SHELL command=' + command);
    let result = await this.client.shell(command, timeoutMs, binaryText);
    this.checkCancelled();
    if (!binaryText) { this.record('SHELL output=' + result.output.substring(0, 3000)); }
    if (result.exitCode !== 0) {
      throw new Error('SELF_HDC_COMMAND: exit=' + String(result.exitCode) +
        (binaryText ? '；截图传输失败（内容未记入日志）' : ' ' + result.output.substring(0, 1500)));
    }
    return result.output;
  }

  private async capture(label: string, remoteFiles: string[]): Promise<string> {
    // snapshot_display's default output requires the .jpeg suffix on the device.
    let remote = '/data/local/tmp/self_hdc_' + this.state.runId + '_' + label + '.jpeg';
    remoteFiles.push(remote);
    this.record('SCREENSHOT request format=JPEG label=' + label + ' remote=' + remote);
    await this.execute('snapshot_display -f ' + selfHdcShellQuote(remote), 20000);
    let encoded = (await this.execute('base64 ' + selfHdcShellQuote(remote), 20000, true)).replace(/\s/g, '');
    if (encoded.length === 0 || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
      throw new Error('SELF_HDC_IMAGE: 截图返回了无效 Base64；未记录图像内容');
    }
    let bytes = new util.Base64Helper().decodeSync(encoded);
    if (bytes.length < 32 || bytes.length > 12 * 1024 * 1024 ||
      bytes[0] !== 0xFF || bytes[1] !== 0xD8 || bytes[2] !== 0xFF ||
      bytes[bytes.length - 2] !== 0xFF || bytes[bytes.length - 1] !== 0xD9) {
      throw new Error('SELF_HDC_IMAGE: 返回文件不是完整 JPEG 或超过大小限制；bytes=' + String(bytes.length));
    }
    let path = this.root + '/runs/' + this.state.runId + '_' + label + '.jpeg';
    selfHdcWrite(path, bytes);
    this.record('SCREENSHOT format=JPEG saved=' + path + ' bytes=' + String(bytes.length));
    return path;
  }

  async run(context: common.UIAbilityContext, config: SelfHdcTestConfig): Promise<void> {
    if (this.state.running) { return; }
    if (AgentExecutionController.isExecutionActive()) { throw new Error('SELF_HDC_BUSY: 请先结束正在执行的 GUI 任务'); }
    this.initialize(context.filesDir);
    this.state = new SelfHdcTestState();
    this.state.running = true;
    this.state.outcome = 'running';
    this.state.runId = String(Date.now()) + '_' + String(Math.floor(Math.random() * 1000000));
    this.startedAt = Date.now();
    this.cancelled = false;
    this.backgroundExpired = false;
    let remoteFiles: string[] = [];
    let alipayLaunched = false;
    let returnCommand = '';
    try {
      this.step('检查手机地址');
      this.record('RUN mode=' + (config.connectionOnly ? 'connection-only' : 'Alipay/screenshot/swipe') +
        ' transport=direct-device-TCP; PC proxy not used');
      this.record('SYSTEM os=' + deviceInfo.osFullName + ' api=' + String(deviceInfo.sdkApiVersion));
      let endpoint = parseSelfHdcEndpoint(config.ip, config.port);
      this.state.endpoint = endpoint.ip + ':' + String(endpoint.port);
      if (endpoint.ip !== '127.0.0.1') {
        let local = await selfHdcLocalIpv4();
        this.record('NETWORK local IPv4=' + local.join(','));
        if (local.indexOf(endpoint.ip) < 0) {
          throw new Error('SELF_HDC_NOT_SELF: 输入的 IP 不属于当前手机网络接口，停止连接');
        }
      } else { this.record('NETWORK using phone loopback 127.0.0.1'); }
      SelfHdcTaskSettings.saveEndpoint(context.filesDir, endpoint.ip, String(endpoint.port));
      this.step('HDC 连接与系统授权');
      this.client = new HdcClient((event: string): void => { this.record(event); });
      await this.client.connect(endpoint.ip, endpoint.port, context.filesDir);
      this.step('验证 HDC Shell');
      let probe = await this.execute('printf SELF_HDC_PHONE_OK; id');
      if (probe.indexOf('SELF_HDC_PHONE_OK') < 0 || probe.indexOf('uid=') < 0) {
        throw new Error('SELF_HDC_PROBE: 未能确认 HDC Shell 执行');
      }
      if (config.connectionOnly) {
        this.state.outcome = 'success';
        this.state.message = '手机直连 HDC 并执行 Shell 成功；未执行支付宝测试。';
      } else {
        await this.execute('command -v aa && command -v snapshot_display && command -v uitest && command -v base64');
        returnCommand = 'aa start -b ' + selfHdcShellQuote(getAppBundleName()) + ' -a EntryAbility';
        this.step('申请短时后台运行');
        let delay = backgroundTaskManager.requestSuspendDelay('手机 HDC 自控测试', (): void => {
          this.backgroundExpired = true;
          this.recordSafely('BACKGROUND quota expiring; stopping subsequent device actions');
          this.client?.close();
        });
        this.suspendRequest = delay.requestId;
        this.record('BACKGROUND request=' + String(delay.requestId) + ' budgetMs=' + String(delay.actualDelayTime));
        if (delay.actualDelayTime < 30000) {
          throw new Error('SELF_HDC_BACKGROUND: 可用后台时长少于30秒，未启动支付宝；稍后重试');
        }
        this.step('通过 HDC 打开支付宝');
        alipayLaunched = true;
        let launch = await this.execute('aa start -b com.alipay.mobile.client -a EntryAbility', 10000);
        if (selfHdcHasCommandFailure(launch)) { throw new Error('SELF_HDC_LAUNCH: ' + launch.substring(0, 1000)); }
        await this.pause(2000);
        this.step('通过 HDC 截图');
        this.state.beforeImage = await this.capture('before', remoteFiles);
        this.persist();
        let source = image.createImageSource(this.state.beforeImage);
        let info: image.ImageInfo;
        try { info = await source.getImageInfo(); } finally { await source.release(); }
        let swipe = selfHdcSwipeForSize(info.size.width, info.size.height);
        this.record('SCREEN size=' + String(info.size.width) + 'x' + String(info.size.height));
        this.step('通过 HDC 向上滑动一次');
        let swipeResult = await this.execute('uitest uiInput swipe ' + String(swipe.x) + ' ' + String(swipe.startY) +
          ' ' + String(swipe.x) + ' ' + String(swipe.endY), 10000);
        if (selfHdcHasCommandFailure(swipeResult)) {
          throw new Error('SELF_HDC_SWIPE: ' + swipeResult.substring(0, 1000));
        }
        this.record('SWIPE command accepted; capturing the resulting screen for comparison');
        await this.pause(700);
        this.step('保存滑动后截图');
        this.state.afterImage = await this.capture('after', remoteFiles);
        this.persist();
        this.state.outcome = 'success';
        this.state.message = '手机端 HDC 已完成打开支付宝、截图、滑动一次。请对照两张截图确认界面变化。';
      }
    } catch (e) {
      let error = e as Error;
      this.state.outcome = this.cancelled ? 'cancelled' : 'failed';
      this.state.message = this.backgroundExpired ? '系统短时后台运行额度已到期，测试中断。' : selfHdcErrorText(error);
      this.recordSafely('RUN ' + this.state.outcome + ' ' + this.state.message);
    } finally {
      // Only clean this run's exact paths. Never retry an action or fall back to the PC service.
      if (this.client && !this.cancelled && !this.backgroundExpired) {
        for (let index = 0; index < remoteFiles.length; index++) {
          try { await this.execute('rm -f ' + selfHdcShellQuote(remoteFiles[index]), 5000); } catch (e) {
            this.recordSafely('CLEANUP remaining=' + remoteFiles[index] + ' error=' + (e as Error).message);
            break;
          }
        }
        if (alipayLaunched && returnCommand) {
          try { await this.execute(returnCommand, 8000); } catch (e) {
            this.recordSafely('RETURN_APP failed: ' + (e as Error).message + '；请手动切回 App');
            this.state.message += '\n未能自动返回本 App，请手动切回。';
          }
        }
      }
      this.client?.close();
      this.client = undefined;
      if (this.suspendRequest >= 0) {
        try { backgroundTaskManager.cancelSuspendDelay(this.suspendRequest); } catch (e) {
          this.recordSafely('BACKGROUND release failed: ' + (e as Error).message);
        }
        this.suspendRequest = -1;
      }
      this.state.running = false;
      this.recordSafely('RUN_FINISH outcome=' + this.state.outcome + ' result=' + this.state.message);
      try { this.persist(); } catch (e) {
        this.state.message += '\n结果文件保存失败：' + (e as Error).message;
      }
      this.publish();
    }
  }
}
