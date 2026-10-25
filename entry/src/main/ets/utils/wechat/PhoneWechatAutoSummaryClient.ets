import { JSON as ArkJSON } from '@kit.ArkTS';
import { PhoneHdcWorkflowBridge } from '../selfhdc/PhoneHdcWorkflowBridge';
import { PrivacyConsent } from '../PrivacyConsent';
import { DebugSettings } from '../DebugSettings';
import { WorkflowJsonMap } from '../WorkflowTypes';
import { WechatAutoSummaryStorage } from './WechatAutoSummaryStorage';
import { WechatAutoSummaryConversation, WechatAutoSummaryMessage, WechatAutoSummaryRequest, WechatAutoSummaryResponse,
  validateWechatAutoSummaryRequest } from './WechatAutoSummaryTypes';
import { mergeWechatPages, parseWechatTime, parseWechatUi, wechatBounds, wechatChatPage,
  wechatContacts, wechatCutoff, wechatIsHome, wechatList, wechatNodes, wechatPageFingerprint,
  wechatText, wechatTexts, wechatTitle, wechatType, WechatBounds, WechatChatPage,
  WechatContact, WechatEntry, WechatText, WechatUiNode } from './WechatUiParser';

export interface WechatPhoneDevice {
  openWechat(): Promise<void>;
  dump(): Promise<string>;
  action(payload: WorkflowJsonMap): Promise<void>;
}

export class WechatPhoneHdcDevice implements WechatPhoneDevice {
  private bridge: PhoneHdcWorkflowBridge;
  constructor(bridge: PhoneHdcWorkflowBridge) { this.bridge = bridge; }
  async openWechat(): Promise<void> {
    try { await this.bridge.startApp('微信', 'com.tencent.wechat', true); }
    catch (e) {
      // Only retry bundle lookup failures, never an uncertain/failed UI action or a lost connection.
      let error = e as Error;
      if (!error.message.startsWith('PHONE_HDC_APP:')) { throw error; }
      await this.bridge.startApp('微信', 'com.tencent.mm', true);
    }
  }
  async dump(): Promise<string> { return await this.bridge.dumpUiLayout(); }
  async action(payload: WorkflowJsonMap): Promise<void> { await this.bridge.guiAction(payload); }
}

// Deterministic UI automation. Separate device interface makes the actual collection sequence
// testable with PC fixtures, without sending clicks to a real device.
export class PhoneWechatAutoSummaryClient {
  private device: WechatPhoneDevice;
  private record: (message: string) => void;
  private progress: (message: string) => void;
  private checkStopped: () => void;
  private checkpoint: (response: WechatAutoSummaryResponse) => void;
  private storage: WechatAutoSummaryStorage;
  private sequence: number = 0;
  private runId: string = '';
  private request: WechatAutoSummaryRequest | null = null;
  private response: WechatAutoSummaryResponse = { status: 'partial', conversations: [] };
  private conversations: WechatAutoSummaryConversation[] = [];
  private now: Date = new Date();
  private textChars: number = 0;

  constructor(device: WechatPhoneDevice, storage: WechatAutoSummaryStorage,
    record: (message: string) => void, progress: (message: string) => void, checkStopped: () => void,
    checkpoint: (response: WechatAutoSummaryResponse) => void) {
    this.device = device; this.storage = storage; this.record = record;
    this.progress = progress; this.checkStopped = checkStopped; this.checkpoint = checkpoint;
  }

  private check(): void { PrivacyConsent.requireAccepted(); this.checkStopped(); }
  private stage(message: string): void { this.record('WECHAT ' + message); this.progress(message); }
  private async action(payload: WorkflowJsonMap): Promise<void> {
    this.check(); await this.device.action(payload); this.check();
  }
  private async wait(): Promise<void> {
    let payload: WorkflowJsonMap = {};
    payload['action'] = 'wait';
    payload['seconds'] = this.request?.wait || 0;
    await this.action(payload);
  }
  private async dump(label: string): Promise<WechatUiNode> {
    this.check();
    let text = await this.device.dump();
    this.check();
    let sequence = ++this.sequence;
    let root = parseWechatUi(text);
    // Dumps are optional debug evidence, not a requirement for saving business data.
    let artifact = '';
    if (DebugSettings.isEnabled()) { artifact = this.storage.writeRawArtifact(this.runId, 'ui_' + sequence + '.json', text); }
    this.record('WECHAT_DUMP stage=' + label + ' seq=' + sequence + ' chars=' + text.length +
      ' artifact=' + (artifact || 'debug-disabled') + '; contacts/messages omitted');
    return root;
  }
  private async click(bounds: WechatBounds): Promise<void> {
    let payload: WorkflowJsonMap = {};
    payload['action'] = 'click';
    payload['x'] = Math.floor((bounds.left + bounds.right) / 2);
    payload['y'] = Math.floor((bounds.top + bounds.bottom) / 2);
    await this.action(payload);
    await this.wait();
  }
  private async back(): Promise<void> {
    let payload: WorkflowJsonMap = {};
    payload['action'] = 'keyevent';
    payload['key'] = 'BACK';
    await this.action(payload);
    await this.wait();
  }
  private async swipe(root: WechatUiNode, older: boolean): Promise<void> {
    let list = wechatList(root);
    let bounds = list ? wechatBounds(list) : null;
    if (!bounds || bounds.bottom - bounds.top < 100) { throw new Error('WECHAT_SWIPE: 列表可滑动区域无效'); }
    let x = Math.floor((bounds.left + bounds.right) / 2);
    let mid = (bounds.top + bounds.bottom) / 2;
    let distance = (bounds.bottom - bounds.top) * Math.min(0.8, this.request?.history_swipe_ratio || 0.4) / 2;
    let high = Math.floor(mid - distance); let low = Math.floor(mid + distance);
    let payload: WorkflowJsonMap = {};
    payload['action'] = 'swipe_with_coords';
    payload['start_x'] = x;
    payload['end_x'] = x;
    payload['start_y'] = older ? high : low;
    payload['end_y'] = older ? low : high;
    payload['swipe_speed'] = this.request?.swipe_speed || 0;
    await this.action(payload);
    await this.wait();
  }
  private async home(): Promise<WechatUiNode> {
    let root = await this.dump('home');
    for (let step = 0; step < 4; step++) {
      if (wechatIsHome(root)) { return root; }
      // Only navigate back from a recognized chat or an explicit search input.
      let knownSearch = wechatNodes(root).some((node: WechatUiNode): boolean =>
        /^(TextInput|Search|SearchField)$/.test(wechatType(node))) &&
        wechatTexts(root).some((item: WechatText): boolean => item.text === '取消');
      if ((!wechatTitle(root) || !wechatList(root)) && !knownSearch) { break; }
      if (!knownSearch) { wechatChatPage(root, wechatTitle(root)); }
      await this.back(); root = await this.dump('return-home');
    }
    throw new Error('WECHAT_HOME: 未识别到微信聊天首页；请先解锁手机并打开微信“微信”页后重试');
  }
  private async firstRecentPage(root: WechatUiNode, limit: number): Promise<WechatUiNode> {
    let list = wechatList(root);
    if (list?.attributes?.scrollable === 'false' || list?.attributes?.scrollable === false) { return root; }
    let previous = ''; let stable = 0;
    for (let step = 0; step <= limit; step++) {
      this.check();
      let fingerprint = ArkJSON.stringify(wechatContacts(root));
      stable = fingerprint === previous ? stable + 1 : 0;
      if (stable >= 2) { return root; }
      if (step === limit) { throw new Error('WECHAT_LIST_TOP_LIMIT: 未能确认最近会话列表顶部，请手动回到列表顶部后重试'); }
      previous = fingerprint;
      await this.swipe(root, true);
      root = await this.dump('recent-list-top');
      if (!wechatIsHome(root)) { throw new Error('WECHAT_HOME_CHANGED: 会话首页已改变，停止滑动'); }
    }
    return root;
  }

  private visibleContacts(root: WechatUiNode): WechatContact[] {
    let list = wechatList(root); let viewport = list ? wechatBounds(list) : null;
    if (!viewport) { return []; }
    let top = viewport.top; let bottom = viewport.bottom;
    // A partially clipped row may have the neighbouring chat under its nominal centre.
    return wechatContacts(root).filter((contact: WechatContact): boolean =>
      contact.bounds.top >= top && contact.bounds.bottom <= bottom);
  }
  private async target(root: WechatUiNode, name: string): Promise<WechatContact> {
    let visible = this.visibleContacts(root).filter((contact: WechatContact): boolean => contact.name === name);
    if (visible.length === 1) { await this.click(visible[0].bounds); return visible[0]; }
    let search = wechatTexts(root).find((text: WechatText): boolean => text.text === '搜索' && text.bounds !== null);
    if (!search?.bounds) { throw new Error('WECHAT_SEARCH_ENTRY: 未找到搜索入口，拒绝猜测点击坐标'); }
    await this.click(search.bounds);
    let searchRoot = await this.dump('search-field');
    let screen = wechatBounds(searchRoot);
    let fields = wechatNodes(searchRoot).filter((node: WechatUiNode): boolean => {
      let bounds = wechatBounds(node);
      return /^(TextInput|Search|SearchField)$/.test(wechatType(node)) && bounds !== null &&
        screen !== null && bounds.bottom < screen.bottom / 2;
    });
    if (fields.length !== 1) { throw new Error('WECHAT_SEARCH_FOCUS: 无法唯一确定微信搜索框，停止输入'); }
    let field = wechatBounds(fields[0]);
    if (!field) { throw new Error('WECHAT_SEARCH_FOCUS: 搜索框没有有效坐标'); }
    let payload: WorkflowJsonMap = {};
    payload['action'] = 'click_input';
    payload['x'] = Math.floor((field.left + field.right) / 2);
    payload['y'] = Math.floor((field.top + field.bottom) / 2);
    payload['text'] = name;
    payload['submit_enter'] = false;
    await this.action(payload);
    await this.wait();
    let results = await this.dump('search-results');
    let matches: WechatContact[] = [];
    let list = wechatList(results);
    if (list) {
      for (let row of list.children || []) {
        if (wechatType(row) !== 'ListItem') { continue; }
        let texts = wechatTexts(row).map((item: WechatText): string => item.text);
        let first = texts[0] || '';
        let match = first === name || (/^(最常使用|联系人|群聊)$/.test(first) && texts[1] === name);
        let bounds = wechatBounds(row); let viewport = wechatBounds(list);
        if (match && bounds && viewport && bounds.top >= viewport.top && bounds.bottom <= viewport.bottom) {
          matches.push({ name: name, bounds: bounds });
        }
      }
    }
    if (matches.length !== 1) {
      throw new Error('WECHAT_SEARCH_MATCH: 未找到唯一的同名联系人；请使用完整名称或先手动进入对应会话');
    }
    await this.click(matches[0].bounds);
    return matches[0];
  }
  private saveProgress(): void {
    this.check();
    this.response.contacts_collected = this.conversations.length;
    this.response.conversations = this.conversations.slice();
    this.response.finished_at = new Date().toISOString();
    this.checkpoint(this.response);
  }

  private async latest(root: WechatUiNode, contact: WechatContact, limit: number): Promise<WechatUiNode> {
    // WeChat may restore the last scroll position when reopening a conversation. Start at
    // its latest messages, otherwise a second collection could silently begin in old history.
    let previous = ''; let stable = 0;
    for (let step = 0; step <= Math.max(2, limit); step++) {
      let page = wechatChatPage(root, contact.name);
      let fingerprint = wechatPageFingerprint(page);
      stable = fingerprint === previous ? stable + 1 : 0;
      this.record('WECHAT_LATEST swipe=' + step + ' stable=' + stable + '; text omitted');
      if (stable >= 2) { return root; }
      if (step === Math.max(2, limit)) {
        throw new Error('WECHAT_LATEST_LIMIT: 未能确认最新消息位置，请手动将会话滑到最新消息后重试');
      }
      previous = fingerprint;
      await this.swipe(root, false);
      root = await this.dump('latest-messages');
    }
    return root;
  }

  private async conversation(contact: WechatContact, index: number): Promise<void> {
    let pages: WechatChatPage[] = [];
    let reason = '已达到历史滑动上限'; let complete = false;
    let last = ''; let stable = 0;
    let failure: Error | null = null;
    try {
      this.stage('读取第 ' + index + ' 个会话');
      let request = this.request;
      if (!request) { throw new Error('WECHAT_REQUEST: 参数尚未初始化'); }
      let root = await this.dump('chat-' + index);
      this.progress('第 ' + index + ' 个会话 · 定位最新消息');
      root = await this.latest(root, contact, request.max_history_swipes);
      let cutoff = wechatCutoff(request.days, this.now);
      let entries = 0;
      let retainedChars = 0;
      for (let step = 0; step <= request.max_history_swipes; step++) {
        let page = wechatChatPage(root, contact.name);
        let fingerprint = wechatPageFingerprint(page);
        stable = fingerprint === last ? stable + 1 : 0; last = fingerprint;
        // Retain compact parsed pages instead of all potentially multi-MiB UI trees.
        if (stable === 0) {
          let chars = page.entries.reduce((count: number, entry: WechatEntry): number =>
            count + (entry.text?.length || 0), 0);
          if (pages.length > 0 && retainedChars + chars > 2 * 1024 * 1024) {
            reason = '已达到单会话文本安全上限'; break;
          }
          pages.push(page); entries += page.entries.length; retainedChars += chars;
        }
        this.record('WECHAT_HISTORY contactIndex=' + index + ' swipe=' + step + ' entries=' +
          page.entries.length + ' stable=' + stable + '; text omitted');
        this.progress('第 ' + index + ' 个会话 · 已翻阅 ' + (step + 1) + ' 屏');
        if (page.entries.some((entry: WechatEntry): boolean => entry.kind === 'time' &&
          (parseWechatTime(entry.text || '', this.now) ?? Number.MAX_VALUE) < cutoff)) {
          reason = '已读到请求时间边界'; complete = true; break;
        }
        if (stable >= request.stable_swipes) {
          reason = '多次滑动后页面不再变化（可能已到历史顶部）'; break;
        }
        if (entries >= 20000) { reason = '已达到单会话消息安全上限'; break; }
        if (step === request.max_history_swipes) { break; }
        await this.swipe(root, true);
        root = await this.dump('history-' + index + '-' + (step + 1));
      }
    } catch (e) {
      failure = e as Error; reason = '采集中断，已保留读到的部分消息';
    }
    if (pages.length > 0) {
      let messages = mergeWechatPages(pages, this.request?.days || 7, this.now);
      let conversation: WechatAutoSummaryConversation = { title: contact.name, messages: messages,
        history_mode: pages.length > 1 ? 'history_scrolled' : 'visible_page_only',
        collection_stop_reason: reason, coverage_complete: complete };
      this.conversations.push(conversation);
      this.textChars += messages.reduce((count: number, message: WechatAutoSummaryMessage): number =>
        count + (message.text?.length || 0), 0);
      if (!failure && this.textChars >= 8 * 1024 * 1024) {
        failure = new Error('WECHAT_DATA_LIMIT: 已达到本次采集文本安全上限，已读取结果会保存，请减少天数或联系人数量');
      }
      // A user stop/background expiry should preserve the already read data. A privacy
      // revocation must not write any more personal data. Do not perform further HDC here.
      if (PrivacyConsent.isAccepted()) {
        this.response.contacts_collected = this.conversations.length;
        this.response.conversations = this.conversations.slice();
        this.response.finished_at = new Date().toISOString();
        try { this.checkpoint(this.response); }
        catch (e) { if (!failure) { failure = e as Error; } }
      }
      this.record('WECHAT_CONVERSATION index=' + index + ' pages=' + pages.length +
        ' messages=' + messages.length + ' complete=' + complete + ' reason=' + reason);
    }
    if (failure) { throw failure; }
  }

  async collect(request: WechatAutoSummaryRequest): Promise<WechatAutoSummaryResponse> {
    let validation = validateWechatAutoSummaryRequest(request);
    if (validation) { throw new Error(validation); }
    for (let value of [request.days, request.max_contacts, request.swipe_speed, request.stable_swipes,
      request.max_history_swipes, request.max_list_swipes === undefined ? 20 : request.max_list_swipes]) {
      if (!Number.isInteger(value)) { throw new Error('WECHAT_REQUEST: 天数、数量及滑动次数必须为整数'); }
    }
    if (request.target_contact.indexOf('\0') >= 0 || request.target_contact.length > 256) {
      throw new Error('WECHAT_REQUEST: 联系人名称无效或过长');
    }
    this.request = request; this.now = new Date(); this.sequence = 0; this.conversations = []; this.textChars = 0;
    this.runId = 'wechat-phone-' + this.now.getTime();
    this.response = { status: 'partial', run_id: this.runId, started_at: this.now.toISOString(),
      mode: request.mode, days: request.days, target_contact: request.target_contact,
      contacts_requested: request.mode === 'target_contact' ? 1 : request.max_contacts,
      contacts_collected: 0, conversations: [] };
    this.record('WECHAT_RUN runId=' + this.runId + ' mode=' + request.mode + ' days=' + request.days +
      ' maxContacts=' + request.max_contacts + ' maxHistorySwipes=' + request.max_history_swipes +
      ' ratio=' + request.history_swipe_ratio + ' speed=' + request.swipe_speed + ' wait=' + request.wait +
      '; target name omitted');
    this.stage('先关闭再启动微信 · 手机直接 HDC');
    this.check(); await this.device.openWechat(); this.check();
    let root = await this.home();
    let limit = request.max_list_swipes === undefined ? 20 : request.max_list_swipes;
    try {
      if (request.mode === 'target_contact') {
        let contact = await this.target(root, request.target_contact.trim());
        await this.conversation(contact, 1);
      } else {
        root = await this.firstRecentPage(root, limit);
        let seen = new Set<string>(); let swipes = 0; let stable = 0;
        while (seen.size < request.max_contacts) {
          this.check();
          if (!wechatIsHome(root)) { throw new Error('WECHAT_HOME_CHANGED: 会话首页已改变，停止点击'); }
          let contact = this.visibleContacts(root).find((item: WechatContact): boolean => !seen.has(item.name));
          if (contact) {
            stable = 0;
            // Always use the most recent dump. No coordinates from a previous list page are reused.
            await this.click(contact.bounds);
            await this.conversation(contact, seen.size + 1);
            seen.add(contact.name);
            if (seen.size >= request.max_contacts) { break; }
            await this.back(); root = await this.home();
          } else {
            stable++;
            if (stable >= request.stable_swipes || swipes >= limit) { break; }
            this.stage('继续查找最近会话 · 已采集 ' + seen.size + ' 个');
            await this.swipe(root, false); swipes++;
            root = await this.dump('next-contacts');
          }
        }
      }
      if (this.conversations.length === 0) { throw new Error('WECHAT_EMPTY: 未识别到可采集会话，请检查微信界面'); }
      this.response.status = 'ok';
      this.response.message = '已采集 ' + this.conversations.length + ' 个会话；范围以实际读取结果为准';
      this.saveProgress();
      return this.response;
    } catch (e) {
      this.response.status = 'partial';
      this.response.message = '采集中断，已保留 ' + this.conversations.length + ' 个会话的实际读取结果';
      if (this.conversations.length > 0 && PrivacyConsent.isAccepted()) { this.checkpoint(this.response); }
      throw e as Error;
    }
  }
}
