import { Want, wantConstant } from '@kit.AbilityKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { fileUri } from '@kit.CoreFileKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import fs from '@ohos.file.fs';
import { AppLogger } from './AppLogger';
import { decodeUtf8Compat, encodeUtf8Compat } from './TextEncodingCompat';
import { parseJsonCompat, stringifyJsonCompat } from './JsonCompat';
import { WorkflowStorage } from './WorkflowStorage';

export const PROFILE_KNOCK_SHARE_UTD: string = 'com.mobiinfra.profile-json';
export const PROFILE_KNOCK_SHARE_FILE_EXTENSION: string = '.mobi-profile';
export const PROFILE_KNOCK_SHARE_MIME_TYPE: string = 'application/vnd.mobiinfra.profile+json';
export const PROFILE_SHARE_LAUNCH_PARAM: string = 'mobiinfra.profileShare.launch';
export const PROFILE_SHARE_LAUNCH_PARAM_VALUE: string = '1';

const PROFILE_SHARE_DIR: string = 'profile-share';
const PROFILE_SHARE_OUTBOX_DIR: string = 'outbox';
const PROFILE_SHARE_INBOX_DIR: string = 'inbox';
const MAX_RECEIVED_PROFILE_BYTES: number = 512 * 1024;
const MAX_INBOX_SCAN_FILES: number = 20;
const PROFILE_SHARE_SCHEMA_VERSION: number = 1;
const PROFILE_SHARE_APP_ID: string = 'com.clawmate.app';
const PROFILE_FILE_OPEN_FALLBACK_MIME_TYPES: string[] = [
  'application/octet-stream',
  'application/json',
  'text/plain',
  '*/*'
];

type ShareWantListener = (event: ProfileShareLaunchEvent) => void;

export interface ProfileShareEnvelope {
  schemaVersion: number;
  typeId: string;
  appId: string;
  appName: string;
  generatedAt: string;
  profileText: string;
  profile: Object;
}

export interface ProfileShareReceivedEvent {
  profileText: string;
  rawText: string;
  title: string;
  sourceUri: string;
  source: string;
  generatedAt: string;
  receivedAt: string;
}

export interface ProfileKnockShareOptions {
  filesDir: string;
  windowId: number;
  buildLocalProfile: () => ProfileShareEnvelope;
  onProfileReceived: (event: ProfileShareReceivedEvent) => Promise<void>;
  onLog?: (message: string) => void;
}

interface ParsedProfileShareEnvelope {
  schemaVersion?: number;
  typeId?: string;
  appId?: string;
  appName?: string;
  generatedAt?: string;
  profileText?: string;
  profile?: Object;
}

interface ProfileInboxCandidate {
  path: string;
  mtime: number;
}

interface ProfileShareLaunchEvent {
  want: Want;
  isShareLaunch: boolean;
}

export class ProfileShareLaunchBridge {
  private static pendingWants: ProfileShareLaunchEvent[] = [];
  private static listeners: ShareWantListener[] = [];

  static enqueueWant(want: Want, isShareLaunch: boolean = false): void {
    let event: ProfileShareLaunchEvent = {
      want: want,
      isShareLaunch: isShareLaunch
    };
    ProfileShareLaunchBridge.pendingWants.push(event);
    let listeners = ProfileShareLaunchBridge.listeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      listeners[i](event);
    }
  }

  static drainWants(): ProfileShareLaunchEvent[] {
    let wants = ProfileShareLaunchBridge.pendingWants.slice();
    ProfileShareLaunchBridge.pendingWants = [];
    return wants;
  }

  static addListener(listener: ShareWantListener): void {
    if (ProfileShareLaunchBridge.listeners.indexOf(listener) >= 0) {
      return;
    }
    ProfileShareLaunchBridge.listeners.push(listener);
  }

  static removeListener(listener: ShareWantListener): void {
    ProfileShareLaunchBridge.listeners = ProfileShareLaunchBridge.listeners.filter((item: ShareWantListener) =>
      item !== listener);
  }

  static isProfileShareLaunchWant(want: Want): boolean {
    if (want.parameters === undefined) {
      return false;
    }
    return String(want.parameters[PROFILE_SHARE_LAUNCH_PARAM]) === PROFILE_SHARE_LAUNCH_PARAM_VALUE;
  }

  static isProfileFileOpenWant(want: Want): boolean {
    if (want.action !== 'ohos.want.action.viewData' && want.action !== 'ohos.want.action.sendData' &&
      want.action !== 'ohos.want.action.sendMultipleData') {
      return false;
    }
    if (want.type === PROFILE_KNOCK_SHARE_MIME_TYPE) {
      return true;
    }
    if (want.type !== undefined &&
      PROFILE_FILE_OPEN_FALLBACK_MIME_TYPES.indexOf(want.type.toLowerCase()) >= 0) {
      return true;
    }
    if (want.uri !== undefined && ProfileShareLaunchBridge.isFileOpenUri(want.uri)) {
      return true;
    }
    if (want.parameters !== undefined) {
      let stream = want.parameters[wantConstant.Params.PARAMS_STREAM];
      if (ProfileShareLaunchBridge.hasFileOpenUri(stream)) {
        return true;
      }
      if (ProfileShareLaunchBridge.hasFileOpenUri(want.parameters['uri']) ||
        ProfileShareLaunchBridge.hasFileOpenUri(want.parameters['fileUri']) ||
        ProfileShareLaunchBridge.hasFileOpenUri(want.parameters['path'])) {
        return true;
      }
    }
    return false;
  }

  private static isFileOpenUri(uri: string): boolean {
    return uri.indexOf('file://') === 0 ||
      uri.indexOf('datashare://') === 0 ||
      ProfileShareLaunchBridge.isProfileFileUri(uri);
  }

  private static isProfileFileUri(uri: string): boolean {
    return uri.indexOf(PROFILE_KNOCK_SHARE_FILE_EXTENSION) >= 0 ||
      uri.indexOf('.mobi-profile.json') >= 0 ||
      uri.indexOf(PROFILE_KNOCK_SHARE_UTD) >= 0;
  }

  private static hasFileOpenUri(value: Object | undefined): boolean {
    if (value === undefined || value === null) {
      return false;
    }
    if (typeof value === 'string') {
      return ProfileShareLaunchBridge.isFileOpenUri(value);
    }
    if (Array.isArray(value)) {
      let values = value as Array<Object>;
      for (let i = 0; i < values.length; i++) {
        if (ProfileShareLaunchBridge.hasFileOpenUri(values[i])) {
          return true;
        }
      }
    }
    return false;
  }
}

export class ProfileKnockShareService {
  private options: ProfileKnockShareOptions | null = null;
  private sendCapability: harmonyShare.SendCapabilityRegistry | null = null;
  private recvCapability: harmonyShare.RecvCapabilityRegistry | null = null;
  private knockShareCallback: ((target: harmonyShare.SharableTarget) => void) | null = null;
  private dataReceiveCallback: ((target: harmonyShare.ReceivableTarget) => void) | null = null;
  private wantListener: ShareWantListener | null = null;
  private consumedProfileSignatures: string[] = [];

  configure(options: ProfileKnockShareOptions): void {
    this.dispose();
    this.options = options;
    this.registerKnockShare(options);
    this.registerDataReceive(options);
    this.registerLaunchWantConsumer();
    this.consumePendingLaunchWants();
  }

  dispose(): void {
    if (this.sendCapability !== null && this.knockShareCallback !== null) {
      try {
        harmonyShare.off('knockShare', this.sendCapability, this.knockShareCallback);
      } catch (e) {
        AppLogger.warnCause('ProfileKnockShare', 'unregister knockShare failed', e as Error);
      }
    }
    if (this.recvCapability !== null && this.dataReceiveCallback !== null) {
      try {
        harmonyShare.off('dataReceive', this.recvCapability, this.dataReceiveCallback);
      } catch (e) {
        AppLogger.warnCause('ProfileKnockShare', 'unregister dataReceive failed', e as Error);
      }
    }
    if (this.wantListener !== null) {
      ProfileShareLaunchBridge.removeListener(this.wantListener);
    }
    this.sendCapability = null;
    this.recvCapability = null;
    this.knockShareCallback = null;
    this.dataReceiveCallback = null;
    this.wantListener = null;
    this.options = null;
    this.consumedProfileSignatures = [];
  }

  private registerKnockShare(options: ProfileKnockShareOptions): void {
    this.sendCapability = {
      windowId: options.windowId
    };
    this.knockShareCallback = (target: harmonyShare.SharableTarget): void => {
      this.shareLocalProfile(target).catch((e: Error) => {
        AppLogger.errorCause('ProfileKnockShare', 'share local profile failed', e);
        this.log('一碰分享发送失败：' + e.message);
      });
    };
    harmonyShare.on('knockShare', this.sendCapability, this.knockShareCallback);
    this.log('已注册一碰发送能力，windowId=' + String(options.windowId));
  }

  private registerDataReceive(options: ProfileKnockShareOptions): void {
    this.recvCapability = {
      windowId: options.windowId,
      capabilities: [
        {
          utd: PROFILE_KNOCK_SHARE_UTD,
          maxSupportedCount: 1
        }
      ]
    };
    this.dataReceiveCallback = (target: harmonyShare.ReceivableTarget): void => {
      this.receiveProfileData(target).catch((e: Error) => {
        AppLogger.errorCause('ProfileKnockShare', 'receive profile data failed', e);
        this.log('一碰分享接收失败：' + e.message);
      });
    };
    harmonyShare.on('dataReceive', this.recvCapability, this.dataReceiveCallback);
    this.log('已注册一碰沙箱接收能力，UTD=' + PROFILE_KNOCK_SHARE_UTD +
      '，接收目录=' + this.inboxDir(options.filesDir));
  }

  private registerLaunchWantConsumer(): void {
    this.wantListener = (event: ProfileShareLaunchEvent): void => {
      this.handleShareWant(event).catch((e: Error) => {
        AppLogger.warnCause('ProfileKnockShare', 'handle launch want failed', e);
      });
    };
    ProfileShareLaunchBridge.addListener(this.wantListener);
  }

  private consumePendingLaunchWants(): void {
    let pending = ProfileShareLaunchBridge.drainWants();
    for (let i = 0; i < pending.length; i++) {
      this.handleShareWant(pending[i]).catch((e: Error) => {
        AppLogger.warnCause('ProfileKnockShare', 'handle pending launch want failed', e);
      });
    }
  }

  private async shareLocalProfile(target: harmonyShare.SharableTarget): Promise<void> {
    let options = this.requireOptions();
    try {
      let data = this.createSharedData(options);
      await target.share(data);
      this.log('已通过一碰分享发送画像文件');
    } catch (e) {
      let err = e as Error;
      try {
        await target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR);
      } catch (rejectErr) {
        AppLogger.warnCause('ProfileKnockShare', 'reject share target failed', rejectErr as Error);
      }
      throw err;
    }
  }

  private createSharedData(options: ProfileKnockShareOptions): systemShare.SharedData {
    let envelope = options.buildLocalProfile();
    let content = stringifyJsonCompat(envelope, 2);
    let path = this.nextOutboxFilePath(options.filesDir);
    this.writeText(path, content);
    let uri = fileUri.getUriFromPath(path);
    return new systemShare.SharedData({
      utd: PROFILE_KNOCK_SHARE_UTD,
      uri: uri,
      title: 'MobiInfer 用户画像',
      label: '用户画像',
      description: '用于生成同频报告的个人画像摘要',
      extraData: {
        schemaVersion: PROFILE_SHARE_SCHEMA_VERSION,
        typeId: PROFILE_KNOCK_SHARE_UTD,
        generatedAt: envelope.generatedAt
      }
    });
  }

  private async receiveProfileData(target: harmonyShare.ReceivableTarget): Promise<void> {
    let options = this.requireOptions();
    let inboxDir = this.inboxDir(options.filesDir);
    let receiveUri = this.inboxDirUri(options.filesDir);
    try {
      await target.receive(receiveUri, {
        onDataReceived: (data: systemShare.SharedData): void => {
          this.handleSharedData(data, 'dataReceive').then((consumed: boolean) => {
            if (!consumed) {
              return this.scanInboxForProfile(inboxDir, 'dataReceiveInbox');
            }
            return false;
          }).catch((e: Error) => {
            AppLogger.errorCause('ProfileKnockShare', 'process received SharedData failed', e);
            this.log('解析一碰分享数据失败：' + e.message);
          });
        },
        onResult: (code: harmonyShare.ShareResultCode): void => {
          this.log('一碰分享接收结果：' + String(code));
          setTimeout(() => {
            this.scanInboxForProfile(inboxDir, 'receiveResultInbox').catch((e: Error) => {
              AppLogger.warnCause('ProfileKnockShare', 'scan inbox after receive result failed', e);
            });
          }, 300);
        }
      });
    } catch (e) {
      let err = e as Error;
      try {
        await target.reject(harmonyShare.ReceivableErrorCode.NO_RECEIVABLE_ERROR);
      } catch (rejectErr) {
        AppLogger.warnCause('ProfileKnockShare', 'reject receive target failed', rejectErr as Error);
      }
      throw err;
    }
  }

  private async handleShareWant(event: ProfileShareLaunchEvent): Promise<void> {
    let want = event.want;
    if (event.isShareLaunch) {
      this.log('检测到系统分享/文件打开拉起，开始解析画像 Want：' + this.wantBrief(want));
    }
    try {
      let data = await systemShare.getSharedData(want);
      let consumed = await this.handleSharedData(data, 'want');
      if (!consumed) {
        await this.handleDirectFileWant(want, 'directWant');
      }
    } catch (e) {
      let directConsumed = await this.handleDirectFileWant(want, 'directWant');
      if (directConsumed) {
        return;
      }
      let errorText = ArkJSON.stringify(e);
      if (errorText.indexOf('1003703001') >= 0 || errorText.indexOf('Parse data failed') >= 0) {
        if (event.isShareLaunch) {
          this.log('系统拉起中没有可解析的 SharedData，已尝试直接读取文件 URI：' + this.wantBrief(want));
        }
        return;
      }
      AppLogger.warnCause('ProfileKnockShare', 'systemShare.getSharedData failed', e as Error);
    }
  }

  private async handleSharedData(data: systemShare.SharedData, source: string): Promise<boolean> {
    let options = this.requireOptions();
    let records = data.getRecords();
    for (let i = 0; i < records.length; i++) {
      let event = this.profileEventFromRecord(records[i], source);
      if (event !== null) {
        return await this.emitProfileEvent(options, event);
      }
    }
    this.log('收到分享数据，但没有找到可解析的画像文件');
    return false;
  }

  private async handleDirectFileWant(want: Want, source: string): Promise<boolean> {
    let options = this.requireOptions();
    let uris = this.uriCandidatesFromWant(want);
    for (let i = 0; i < uris.length; i++) {
      try {
        let rawText = this.readText(uris[i]);
        let event = this.profileEventFromText(rawText, '', uris[i], source);
        if (event !== null) {
          return await this.emitProfileEvent(options, event);
        }
      } catch (e) {
        AppLogger.warnCause('ProfileKnockShare', 'read direct want file failed: ' + uris[i], e as Error);
      }
    }
    return false;
  }

  private async scanInboxForProfile(inboxDir: string, source: string): Promise<boolean> {
    let options = this.requireOptions();
    let candidates = this.listInboxCandidates(inboxDir);
    let scanned = 0;
    for (let i = 0; i < candidates.length && scanned < MAX_INBOX_SCAN_FILES; i++) {
      scanned += 1;
      try {
        let rawText = this.readText(candidates[i].path);
        let event = this.profileEventFromText(rawText, '', candidates[i].path, source);
        if (event !== null) {
          return await this.emitProfileEvent(options, event);
        }
      } catch (e) {
        AppLogger.warnCause('ProfileKnockShare', 'read inbox profile candidate failed: ' + candidates[i].path,
          e as Error);
      }
    }
    if (candidates.length > 0) {
      this.log('已扫描接收目录，未发现可解析的画像文件');
    }
    return false;
  }

  private listInboxCandidates(inboxDir: string): ProfileInboxCandidate[] {
    let candidates: ProfileInboxCandidate[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(inboxDir, { recursion: true });
    } catch (e) {
      return candidates;
    }
    for (let i = 0; i < names.length; i++) {
      let path = this.joinInboxPath(inboxDir, names[i]);
      try {
        let stat = fs.statSync(path);
        if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_RECEIVED_PROFILE_BYTES) {
          continue;
        }
        candidates.push({
          path: path,
          mtime: stat.mtime
        });
      } catch (e) {
      }
    }
    candidates.sort((left: ProfileInboxCandidate, right: ProfileInboxCandidate): number => right.mtime - left.mtime);
    return candidates;
  }

  private joinInboxPath(inboxDir: string, name: string): string {
    if (name.indexOf(inboxDir) === 0) {
      return name;
    }
    if (name.indexOf('/') === 0) {
      return inboxDir + name;
    }
    return inboxDir + '/' + name;
  }

  private async emitProfileEvent(options: ProfileKnockShareOptions, event: ProfileShareReceivedEvent): Promise<boolean> {
    let signature = this.profileEventSignature(event);
    if (this.consumedProfileSignatures.indexOf(signature) >= 0) {
      this.log('已忽略重复画像分享：' + event.title);
      return true;
    }
    this.consumedProfileSignatures.push(signature);
    if (this.consumedProfileSignatures.length > 30) {
      this.consumedProfileSignatures = this.consumedProfileSignatures.slice(this.consumedProfileSignatures.length - 30);
    }
    this.log('收到画像分享：' + event.title);
    await options.onProfileReceived(event);
    return true;
  }

  private profileEventSignature(event: ProfileShareReceivedEvent): string {
    let raw = event.rawText;
    let hash = 0;
    for (let i = 0; i < raw.length; i++) {
      hash = (hash * 131 + raw.charCodeAt(i)) % 2147483647;
    }
    return String(raw.length) + '#' + String(hash);
  }

  private profileEventFromRecord(record: systemShare.SharedRecord, source: string): ProfileShareReceivedEvent | null {
    let rawText = '';
    if (record.content !== undefined && record.content.trim().length > 0) {
      rawText = record.content;
    }
    if (rawText.length === 0 && record.uri !== undefined && record.uri.length > 0) {
      rawText = this.readText(record.uri);
    }
    if (rawText.length === 0 && record.extraData !== undefined) {
      let profileText = record.extraData['profileText'];
      if (typeof profileText === 'string') {
        rawText = profileText;
      }
    }
    if (rawText.trim().length === 0) {
      return null;
    }
    return this.profileEventFromText(rawText, record.title === undefined ? '' : record.title,
      record.uri === undefined ? '' : record.uri, source);
  }

  private profileEventFromText(rawText: string, title: string, sourceUri: string,
    source: string): ProfileShareReceivedEvent | null {
    let profileText = rawText;
    let generatedAt = '';
    try {
      let envelope = parseJsonCompat<ParsedProfileShareEnvelope>(rawText);
      if (!this.isProfileShareEnvelope(envelope)) {
        return null;
      }
      if (envelope.profileText !== undefined && envelope.profileText.trim().length > 0) {
        profileText = envelope.profileText;
      }
      if (envelope.generatedAt !== undefined) {
        generatedAt = envelope.generatedAt;
      }
      if (title.length === 0 && envelope.appName !== undefined) {
        title = envelope.appName + ' 用户画像';
      }
    } catch (e) {
      return null;
    }
    return {
      profileText: profileText,
      rawText: rawText,
      title: title.length > 0 ? title : '用户画像',
      sourceUri: sourceUri,
      source: source,
      generatedAt: generatedAt,
      receivedAt: new Date().toISOString()
    };
  }

  private isProfileShareEnvelope(envelope: ParsedProfileShareEnvelope): boolean {
    if (envelope.profileText === undefined || envelope.profileText.trim().length === 0) {
      return false;
    }
    if (envelope.typeId === PROFILE_KNOCK_SHARE_UTD) {
      return true;
    }
    if (envelope.appId === PROFILE_SHARE_APP_ID && envelope.schemaVersion === PROFILE_SHARE_SCHEMA_VERSION) {
      return true;
    }
    return false;
  }

  private uriCandidatesFromWant(want: Want): string[] {
    let candidates: string[] = [];
    if (want.uri !== undefined) {
      this.addUriCandidate(candidates, want.uri);
    }
    if (want.parameters !== undefined) {
      this.addUriCandidateFromObject(candidates, want.parameters[wantConstant.Params.PARAMS_STREAM]);
      this.addUriCandidateFromObject(candidates, want.parameters['uri']);
      this.addUriCandidateFromObject(candidates, want.parameters['fileUri']);
      this.addUriCandidateFromObject(candidates, want.parameters['path']);
    }
    return candidates;
  }

  private addUriCandidateFromObject(candidates: string[], value: Object | undefined): void {
    if (value === undefined || value === null) {
      return;
    }
    if (typeof value === 'string') {
      this.addUriCandidate(candidates, value);
      return;
    }
    if (Array.isArray(value)) {
      let values = value as Array<Object>;
      for (let i = 0; i < values.length; i++) {
        this.addUriCandidateFromObject(candidates, values[i]);
      }
    }
  }

  private addUriCandidate(candidates: string[], uri: string): void {
    if (uri.length === 0 || candidates.indexOf(uri) >= 0) {
      return;
    }
    candidates.push(uri);
  }

  private wantBrief(want: Want): string {
    let streamText = '';
    if (want.parameters !== undefined) {
      let stream = want.parameters[wantConstant.Params.PARAMS_STREAM];
      if (stream !== undefined) {
        streamText = ', stream=' + ArkJSON.stringify(stream);
      }
    }
    return 'action=' + String(want.action) +
      ', type=' + String(want.type) +
      ', uri=' + String(want.uri) +
      streamText;
  }

  private requireOptions(): ProfileKnockShareOptions {
    if (this.options === null) {
      throw new Error('Profile knock share service is not configured.');
    }
    return this.options;
  }

  private nextOutboxFilePath(filesDir: string): string {
    let outboxDir = this.outboxDir(filesDir);
    WorkflowStorage.ensureDirectoryTree(outboxDir);
    let suffix = util.generateRandomUUID().substring(0, 8);
    return outboxDir + '/profile-' + String(new Date().getTime()) + '-' + suffix + PROFILE_KNOCK_SHARE_FILE_EXTENSION;
  }

  private outboxDir(filesDir: string): string {
    return filesDir.replace(/\\/g, '/').replace(/\/+$/g, '') + '/' + PROFILE_SHARE_DIR + '/' +
      PROFILE_SHARE_OUTBOX_DIR;
  }

  private inboxDir(filesDir: string): string {
    return filesDir.replace(/\\/g, '/').replace(/\/+$/g, '') + '/' + PROFILE_SHARE_DIR + '/' +
      PROFILE_SHARE_INBOX_DIR;
  }

  private inboxDirUri(filesDir: string): string {
    let dir = this.inboxDir(filesDir);
    WorkflowStorage.ensureDirectoryTree(dir);
    return fileUri.getUriFromPath(dir);
  }

  private writeText(path: string, content: string): void {
    let encoded = encodeUtf8Compat(content);
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, encoded.buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  private readText(pathOrUri: string): string {
    let file: fs.File | null = null;
    let chunks: Uint8Array[] = [];
    let total = 0;
    try {
      file = fs.openSync(pathOrUri, fs.OpenMode.READ_ONLY);
      while (total < MAX_RECEIVED_PROFILE_BYTES) {
        let buffer = new ArrayBuffer(16 * 1024);
        let readSize = fs.readSync(file.fd, buffer);
        if (readSize <= 0) {
          break;
        }
        let allowed = Math.min(readSize, MAX_RECEIVED_PROFILE_BYTES - total);
        chunks.push(new Uint8Array(buffer.slice(0, allowed)));
        total += allowed;
        if (allowed < readSize) {
          break;
        }
      }
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
    let merged = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      merged.set(chunks[i], offset);
      offset += chunks[i].byteLength;
    }
    return decodeUtf8Compat(merged);
  }

  private log(message: string): void {
    AppLogger.info('ProfileKnockShare', message);
    if (this.options !== null && this.options.onLog !== undefined) {
      this.options.onLog(message);
    }
  }
}
