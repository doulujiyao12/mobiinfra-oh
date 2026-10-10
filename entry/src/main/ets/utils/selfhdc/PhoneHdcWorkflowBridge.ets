import { common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { HdcWorkflowBridge } from '../HdcWorkflowBridge';
import { HdcBridgeResponse, WorkflowJsonMap } from '../WorkflowTypes';
import { AgentExecutionController } from '../AgentExecutionController';
import { getAppBundleName } from '../AppIdentity';
import { HdcClient } from './HdcClient';
import { SelfHdcTestRunner, selfHdcLocalIpv4 } from './SelfHdcTestRunner';
import { SelfHdcTaskSettings } from './SelfHdcTaskSettings';
import { parseSelfHdcEndpoint, selfHdcHasCommandFailure, selfHdcShellQuote } from './SelfHdcPolicy';
import { selfHdcWrite } from './SelfHdcFiles';
import { PhoneHdcActions, phoneHdcString } from './PhoneHdcActions';
import { phoneHdcBundle, phoneHdcMainAbility } from './PhoneHdcApp';
import { parsePhoneHdcUiInputHelp } from './PhoneHdcCapabilities';

// Independent device backend. No method falls through to the inherited HTTP transport.
export class PhoneHdcWorkflowBridge extends HdcWorkflowBridge {
  private context: common.UIAbilityContext;
  private settings: SelfHdcTaskSettings;
  private phoneLog: (message: string) => void;
  private phoneClient: HdcClient;
  private actions: PhoneHdcActions = new PhoneHdcActions();
  private cancelled: boolean = false;
  private expired: boolean = false;
  private geometryReady: boolean = false;
  private suspendId: number = -1;
  private deadline: number = 0;
  private shotSequence: number = 0;
  private actionSequence: number = 0;
  private dataPackets: number = 0;
  private dataBytes: number = 0;
  private quotaExpired: () => void;
  private respectAgentExecution: boolean;
  private closed: boolean = false;
  private opened: boolean = false;

  constructor(context: common.UIAbilityContext, settings: SelfHdcTaskSettings, log: (message: string) => void,
    quotaExpired: () => void = (): void => {}, respectAgentExecution: boolean = true) {
    super('', log);
    this.context = context; this.settings = settings; this.phoneLog = log;
    this.quotaExpired = quotaExpired;
    this.respectAgentExecution = respectAgentExecution;
    this.phoneClient = new HdcClient((event: string): void => {
      let match = /^RX channel=\d+ command=10 bytes=(\d+)$/.exec(event);
      if (match) { this.dataPackets++; this.dataBytes += Number(match[1]); return; }
      if (this.dataPackets > 0 && event.startsWith('SHELL completed')) {
        this.phoneLog('RX DATA summary packets=' + this.dataPackets + ' bytes=' + this.dataBytes);
        this.dataPackets = 0; this.dataBytes = 0;
      }
      this.phoneLog(event);
    });
  }

  async open(): Promise<void> {
    this.check();
    let endpoint = parseSelfHdcEndpoint(this.settings.ip, this.settings.port);
    this.phoneLog('PHONE transport=direct-device-TCP; os=' + deviceInfo.osFullName + ' api=' + deviceInfo.sdkApiVersion);
    if (endpoint.ip !== '127.0.0.1') {
      let addresses = await selfHdcLocalIpv4();
      this.phoneLog('PHONE localIPv4=' + addresses.join(','));
      if (addresses.indexOf(endpoint.ip) < 0) { throw new Error('PHONE_HDC_NOT_SELF: IP is not this phone'); }
    }
    this.check();
    await this.phoneClient.connect(endpoint.ip, endpoint.port, this.context.filesDir);
    this.check();
    let probe = await this.execute('printf SELF_HDC_PHONE_OK; id', 'shell-probe', false, false);
    if (probe.indexOf('SELF_HDC_PHONE_OK') < 0 || probe.indexOf('uid=') < 0) {
      throw new Error('PHONE_HDC_PROBE: could not verify shell identity');
    }
    await this.execute('command -v aa && command -v bm && command -v snapshot_display && command -v uitest && command -v base64',
      'tool-preflight', false, false);
    await this.probeUiInputCapabilities();
    let delay = backgroundTaskManager.requestSuspendDelay('手机 HDC GUI 任务', (): void => {
      if (this.closed) { return; }
      this.expired = true;
      this.phoneLog('PHONE_HDC_BACKGROUND_EXPIRED: system quota expiring; stop subsequent actions');
      this.phoneClient.close();
      this.quotaExpired();
    });
    this.suspendId = delay.requestId; this.deadline = Date.now() + delay.actualDelayTime;
    this.phoneLog('BACKGROUND request=' + delay.requestId + ' budgetMs=' + delay.actualDelayTime);
    if (delay.actualDelayTime < 30000) { throw new Error('PHONE_HDC_BACKGROUND: less than 30 seconds available'); }
    SelfHdcTaskSettings.saveEndpoint(this.context.filesDir, endpoint.ip, String(endpoint.port));
    this.opened = true;
  }

  hasExpired(): boolean { return this.expired || (this.deadline > 0 && Date.now() >= this.deadline); }

  private check(): void {
    if (this.hasExpired()) { throw new Error('PHONE_HDC_BACKGROUND_EXPIRED: background budget exhausted'); }
    if (this.closed || this.cancelled || (this.respectAgentExecution && AgentExecutionController.isCancelRequested())) {
      throw new Error('PHONE_HDC_CANCELLED: stop requested; no further action sent');
    }
  }

  cancel(): void { this.cancelled = true; this.phoneClient.close(); }

  async returnHost(): Promise<void> {
    await this.context.startAbility({ bundleName: getAppBundleName(), abilityName: 'EntryAbility' });
  }

  close(): void {
    this.closed = true;
    this.phoneClient.close();
    if (this.suspendId >= 0) {
      try { backgroundTaskManager.cancelSuspendDelay(this.suspendId); } catch (e) {
        this.phoneLog('BACKGROUND release failed: ' + (e as Error).message);
      }
      this.suspendId = -1;
    }
  }

  private async pause(ms: number): Promise<void> {
    let end = Date.now() + ms;
    while (Date.now() < end) {
      this.check();
      await new Promise<void>((resolve): void => { setTimeout(resolve, Math.min(100, end - Date.now())); });
    }
    this.check();
  }

  private async probeUiInputCapabilities(): Promise<void> {
    this.check();
    this.phoneLog('DEVICE_COMMAND label=uiInput-capabilities command=uitest uiInput help');
    let result = await this.phoneClient.shell('uitest uiInput help', 20000);
    this.check();
    this.phoneLog('DEVICE_OUTPUT label=uiInput-capabilities exit=' + result.exitCode +
      ' text=' + result.output.substring(0, 3000));
    try {
      let help = parsePhoneHdcUiInputHelp(result.exitCode, result.output);
      this.phoneLog('CAPABILITIES uiInput verified=' + help.commands.join(',') + ' helpExit=' + result.exitCode +
        ' acceptedNonzeroUsage=' + help.acceptedNonzeroExit + '; device actions still require exit=0');
    } catch (e) {
      this.phoneLog('CAPABILITIES uiInput rejected exit=' + result.exitCode + ' error=' + (e as Error).message);
      throw e as Error;
    }
  }

  private async execute(command: string, label: string, sensitive: boolean = false,
    checkOutput: boolean = true): Promise<string> {
    this.check();
    this.phoneLog('DEVICE_COMMAND label=' + label + ' command=' + (sensitive ? '(text omitted)' : command));
    let result = await this.phoneClient.shell(command, 20000, sensitive, sensitive);
    this.check();
    let failed = result.exitCode !== 0 || (checkOutput && selfHdcHasCommandFailure(result.output));
    this.phoneLog('DEVICE_OUTPUT label=' + label + ' exit=' + result.exitCode + ' failed=' + failed +
      (sensitive ? ' (contents omitted)' : ' text=' + result.output.substring(0, 3000)));
    if (failed) {
      throw new Error('PHONE_HDC_COMMAND: ' + label + ' exit=' + result.exitCode +
        (sensitive ? ' (contents omitted)' : ' ' + result.output.substring(0, 1500)));
    }
    return result.output;
  }

  async request(action: string, _payload?: WorkflowJsonMap): Promise<HdcBridgeResponse> {
    throw new Error('PHONE_HDC_UNSUPPORTED: bridge request=' + action + '; PC fallback disabled');
  }

  async health(): Promise<boolean> { this.check(); return true; }

  async agentConfig(): Promise<HdcBridgeResponse> {
    this.check();
    return { status: 'ok', no_reason: false, message: 'phone Agent uses model prompt files or built-in defaults' };
  }

  async prepareAgentRun(): Promise<void> {
    this.check();
    if (!this.opened) { throw new Error('PHONE_HDC_NOT_READY: open phone session before starting Agent'); }
    this.actions.reset(); this.geometryReady = false;
    this.phoneLog('AGENT_PREPARE phone HDC ready; PC driver/config/port forwarding not used');
  }

  async startApp(appName: string, packageName: string, resetFirst: boolean = true): Promise<void> {
    let bundle = phoneHdcBundle(appName, packageName);
    if (bundle === getAppBundleName() && (this.cancelled || this.hasExpired() ||
      (this.respectAgentExecution && AgentExecutionController.isCancelRequested()))) {
      await this.returnHost(); return;
    }
    this.check(); this.actions.reset(); this.geometryReady = false;
    let ability = phoneHdcMainAbility(await this.execute('bm dump -n ' + selfHdcShellQuote(bundle), 'resolve-main-ability', false, false));
    this.phoneLog('APP bundle=' + bundle + ' mainAbility=' + ability + ' reset=' + resetFirst);
    if (resetFirst && bundle !== getAppBundleName()) {
      await this.execute('aa force-stop ' + selfHdcShellQuote(bundle), 'app-stop');
    }
    await this.execute('aa start -b ' + selfHdcShellQuote(bundle) + ' -a ' + selfHdcShellQuote(ability), 'app-start');
    await this.pause(2000);
  }

  async screenshot(): Promise<HdcBridgeResponse> {
    return await this.screenshotWithFactor(0.5);
  }

  async screenshotWithFactor(factor: number): Promise<HdcBridgeResponse> {
    if (!Number.isFinite(factor) || factor <= 0 || factor > 1) {
      throw new Error('PHONE_HDC_IMAGE: screenshot factor must be >0 and <=1');
    }
    this.check();
    let token = await AgentExecutionController.hideCaptureOverlay();
    let runId = SelfHdcTestRunner.shared().snapshot().runId;
    let remote = '/data/local/tmp/self_hdc_' + runId + '_gui_' + String(++this.shotSequence) + '.jpeg';
    try {
      if (token) { await this.pause(120); }
      await this.execute('snapshot_display -f ' + selfHdcShellQuote(remote), 'screenshot');
      let encoded = (await this.execute('base64 ' + selfHdcShellQuote(remote), 'screenshot-transfer', true, false)).replace(/\s/g, '');
      if (!encoded || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
        throw new Error('PHONE_HDC_IMAGE: invalid Base64 (contents omitted)');
      }
      let bytes = new util.Base64Helper().decodeSync(encoded);
      if (bytes.length < 32 || bytes.length > 12 * 1024 * 1024 || bytes[0] !== 255 || bytes[1] !== 216 ||
        bytes[2] !== 255 || bytes[bytes.length - 2] !== 255 || bytes[bytes.length - 1] !== 217) {
        throw new Error('PHONE_HDC_IMAGE: incomplete JPEG or over size limit');
      }
      let source = image.createImageSource(bytes.buffer);
      let info: image.ImageInfo;
      let resized: ArrayBuffer;
      let modelWidth = 0; let modelHeight = 0;
      try {
        info = await source.getImageInfo();
        modelWidth = Math.max(1, Math.floor(info.size.width * factor));
        modelHeight = Math.max(1, Math.floor(info.size.height * factor));
        let pixels = await source.createPixelMap({ desiredSize: { width: modelWidth, height: modelHeight } });
        let packer = image.createImagePacker();
        try { resized = await packer.packToData(pixels, { format: 'image/jpeg', quality: 90 }); }
        finally { await packer.release(); await pixels.release(); }
      } finally { await source.release(); }
      this.actions.setScreen(info.size.width, info.size.height); this.geometryReady = true;
      let label = this.shotSequence === 1 ? 'before' : 'after';
      let path = this.context.filesDir + '/self_hdc/runs/' + runId + '_' + label + '.jpeg';
      selfHdcWrite(path, bytes);
      SelfHdcTestRunner.shared().setExternalImage(path, this.shotSequence === 1);
      this.phoneLog('SCREENSHOT saved=' + path + ' size=' + info.size.width + 'x' + info.size.height + ' bytes=' + bytes.length +
        ' modelSize=' + modelWidth + 'x' + modelHeight + ' factor=' + factor + '; image data omitted');
      return { status: 'ok', image_b64: new util.Base64Helper().encodeToStringSync(new Uint8Array(resized)),
        width: modelWidth, height: modelHeight, screen_width: info.size.width, screen_height: info.size.height,
        message: 'phone JPEG screenshot' };
    } finally {
      try { await this.execute('rm -f ' + selfHdcShellQuote(remote), 'screenshot-cleanup'); } catch (e) {
        this.phoneLog('CLEANUP remaining=' + remote + ' error=' + (e as Error).message);
      }
      await AgentExecutionController.restoreCaptureOverlay(token);
    }
  }

  async guiAction(payload: WorkflowJsonMap): Promise<HdcBridgeResponse> {
    this.check();
    let action = phoneHdcString(payload, 'action');
    let sequence = ++this.actionSequence;
    this.phoneLog('ACTION_BEGIN seq=' + sequence + ' action=' + action);
    try {
      if (action === 'app_start') {
        await this.startApp(phoneHdcString(payload, 'app_name'), phoneHdcString(payload, 'package_name'), payload['reset_first'] !== false);
      } else if (action === 'app_stop') {
        this.actions.reset(); this.geometryReady = false;
        let bundle = phoneHdcBundle('', phoneHdcString(payload, 'package_name'));
        if (bundle === getAppBundleName()) { throw new Error('PHONE_HDC_APP: refusing to stop this controller App'); }
        await this.execute('aa force-stop ' + selfHdcShellQuote(bundle), 'app-stop');
      } else {
        if (!this.geometryReady) { await this.screenshot(); }
        let plan = this.actions.plan(payload);
        for (let item of plan.commands) {
          this.check();
          if (this.respectAgentExecution) { await AgentExecutionController.waitIfPaused(); }
          this.check();
          if (item.command) { await this.execute(item.command, item.label, item.sensitive); }
          if (item.delayMs > 0) { await this.pause(item.delayMs); }
        }
        this.actions.commit(plan);
      }
      this.phoneLog('ACTION_END seq=' + sequence + ' action=' + action + ' status=ok');
      return { status: 'ok', action: action, message: 'phone ' + action + ' accepted; verify next screenshot' };
    } catch (e) {
      this.actions.reset();
      this.phoneLog('ACTION_FAILED seq=' + sequence + ' action=' + action + ' error=' + (e as Error).message);
      throw e as Error;
    }
  }
}
