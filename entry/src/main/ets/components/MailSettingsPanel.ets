import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { AppTheme, APP_DARK_MODE_KEY } from '../utils/AppTheme';
import { CollectionFormGroup, CollectionFormDivider, CollectionFormInput, CollectionFormSwitch,
  CollectionFormAction } from './CollectionFormControls';
import { MailCredentialStore } from '../utils/mail/MailCredentialStore';
import { MailStore } from '../utils/mail/MailStore';
import { MailService } from '../utils/mail/MailService';
import { MailSettings, MailProvider, MAIL_PROVIDERS, defaultMailSettings, validateMailSettings } from '../utils/mail/MailTypes';

@Component
export struct MailSettingsPanel {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  @Prop memoryRefreshing: boolean = false;
  onChanged: () => void = (): void => {};
  onSync: () => Promise<void> = async (): Promise<void> => {};
  @State private mailEnabled: boolean = false;
  @State private host: string = 'imap.qq.com';
  @State private port: string = '993';
  @State private username: string = '';
  @State private secret: string = '';
  @State private interested: string = '';
  @State private ignored: string = '';
  @State private aiAllowed: boolean = false;
  @State private maxMessages: number = 50;
  @State private busy: boolean = false;
  @State private failed: boolean = false;
  @State private status: string = '';

  private store(): MailStore { return new MailStore((getContext(this) as common.Context).filesDir); }
  aboutToAppear(): void {
    let settings = this.store().settings();
    this.mailEnabled = settings.enabled; this.host = settings.host; this.port = String(settings.port);
    this.username = settings.username; this.interested = settings.interested; this.ignored = settings.ignored;
    this.aiAllowed = settings.aiAllowed; this.maxMessages = settings.maxMessages;
    this.reloadStatus();
  }
  private reloadStatus(): void {
    let snapshot = this.store().current();
    this.failed = snapshot.error.length > 0;
    this.status = snapshot.error || (snapshot.syncedAt ? '近三天已读取' + snapshot.items.length + '封 · ' +
      new Date(snapshot.syncedAt).toLocaleString() + (snapshot.partial ? ' · 部分读取' : '') : '保留近三天邮件，首页展示今天的关注项');
  }
  private draft(): MailSettings {
    let settings = defaultMailSettings();
    settings.enabled = this.mailEnabled; settings.host = this.host.trim().toLowerCase(); settings.port = Number(this.port);
    settings.username = this.username.trim(); settings.interested = this.interested.trim(); settings.ignored = this.ignored.trim();
    settings.aiAllowed = this.aiAllowed; settings.maxMessages = this.maxMessages;
    return settings;
  }
  private async persist(): Promise<void> {
    let store = this.store();
    let settings = this.draft();
    validateMailSettings(settings);
    let oldKey = store.accountKey();
    let key = store.accountKey(settings);
    let changed = store.accountKey(settings) !== store.accountKey();
    if (settings.enabled && changed && !this.secret) { throw new Error('更换邮箱或服务器时，请重新填写客户端授权码'); }
    if (this.secret) { await MailCredentialStore.save(key, this.secret); }
    else if (settings.enabled && !await MailCredentialStore.load(key)) { throw new Error('请填写客户端授权码'); }
    if (changed) { store.clear(); }
    store.saveSettings(settings);
    this.secret = '';
    this.onChanged();
    if (changed) { await MailCredentialStore.remove(oldKey); }
  }
  private async save(sync: boolean): Promise<void> {
    if (this.busy || this.memoryRefreshing || MailService.isBusy()) { return; }
    this.busy = true; this.failed = false;
    try {
      await this.persist();
      if (sync) {
        if (!this.mailEnabled) { throw new Error('请先开启邮件提醒'); }
        this.status = '正在读取并筛选近三天邮件…';
        await this.onSync();
        this.reloadStatus();
      } else { this.status = '设置已保存，下次同步生效'; }
    } catch (e) { this.failed = true; this.status = (e as Error).message; }
    finally { this.busy = false; }
  }
  private async changeAi(value: boolean): Promise<void> {
    if (!value) { this.aiAllowed = false; return; }
    let answer = await promptAction.showDialog({ title: '允许AI筛选邮件？',
      message: '将近三天读取的发件人、主题和正文发送到你配置的云端模型进行摘要与关注筛选；附件和邮箱授权码不会发送。邮件不参与个人画像。',
      buttons: [{ text: '取消', color: AppTheme.dialogText('#7C8496') }, { text: '允许', color: AppTheme.dialogText('#6372D8') }] });
    this.aiAllowed = answer.index === 1;
  }
  private async forget(): Promise<void> {
    if (this.busy || this.memoryRefreshing || MailService.isBusy()) { return; }
    let answer = await promptAction.showDialog({ title: '移除邮箱？', message: '删除本机邮件缓存和授权码。邮箱中的邮件不会被修改。',
      buttons: [{ text: '取消', color: AppTheme.dialogText('#7C8496') }, { text: '移除', color: AppTheme.dialogText('#D54A59') }] });
    if (answer.index !== 1) { return; }
    this.busy = true;
    try {
      await MailCredentialStore.remove();
      this.store().clear(); this.store().saveSettings(defaultMailSettings());
      this.secret = ''; this.aboutToAppear(); this.onChanged(); this.status = '邮箱已移除';
    } catch (e) { this.failed = true; this.status = (e as Error).message; }
    finally { this.busy = false; }
  }

  private providerIndex(): number {
    let index = MAIL_PROVIDERS.findIndex((provider: MailProvider): boolean => provider.host === this.host);
    return index < 0 ? MAIL_PROVIDERS.length - 1 : index;
  }
  private providerOptions(): SelectOption[] {
    return MAIL_PROVIDERS.map((provider: MailProvider): SelectOption => { return { value: provider.label }; });
  }

  @Builder AccountFields() {
    Row({ space: 12 }) {
      Text('邮箱类型').fontSize(16).fontColor(AppTheme.text('#172033')).layoutWeight(1)
      Select(this.providerOptions()).selected(this.providerIndex()).value(MAIL_PROVIDERS[this.providerIndex()].label)
        .font({ size: 15 }).fontColor(AppTheme.text('#60697C')).optionFont({ size: 15 })
        .optionFontColor(AppTheme.text('#172033')).backgroundColor(Color.Transparent)
        .onSelect((index: number): void => { this.host = MAIL_PROVIDERS[index].host; this.port = '993'; })
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
    CollectionFormDivider()
    CollectionFormInput({ label: '邮箱账号', value: this.username, placeholder: 'name@example.com', limit: 254,
      onChangeValue: (value: string): void => { this.username = value; } })
    CollectionFormDivider()
    CollectionFormInput({ label: 'IMAP 加密收信服务器', value: this.host, placeholder: 'imap.example.com', limit: 254,
      onChangeValue: (value: string): void => { this.host = value; } })
    CollectionFormDivider()
    CollectionFormInput({ label: 'TLS 端口', value: this.port, placeholder: '993', inputType: InputType.Number, limit: 5,
      onChangeValue: (value: string): void => { this.port = value; } })
    CollectionFormDivider()
    CollectionFormInput({ label: '客户端授权码', value: this.secret, placeholder: '首次必填；留空保留已存授权码', secret: true,
      onChangeValue: (value: string): void => { this.secret = value; } })
  }
  @Builder AiFields() {
    CollectionFormSwitch({ label: '允许 AI 筛选', selected: this.aiAllowed,
      onChangeValue: (value: boolean): void => { this.changeAi(value); } })
    if (this.aiAllowed) {
      CollectionFormDivider()
      CollectionFormInput({ label: '我关心的', value: this.interested, multiline: true,
        placeholder: '例如：会议变更、研究进展、需要回复的事情',
        onChangeValue: (value: string): void => { this.interested = value; } })
      CollectionFormDivider()
      CollectionFormInput({ label: '我不关心的', value: this.ignored, multiline: true, placeholder: '例如：促销、订阅广告、自动周报',
        onChangeValue: (value: string): void => { this.ignored = value; } })
    }
  }
  @Builder ReadFields() {
    Row({ space: 12 }) {
      Text('每天读取上限').fontSize(16).fontColor(AppTheme.text('#172033')).layoutWeight(1)
      Select([{ value: '20 封' }, { value: '50 封' }, { value: '100 封' }])
        .selected([20, 50, 100].indexOf(this.maxMessages)).value(this.maxMessages + ' 封')
        .font({ size: 15 }).fontColor(AppTheme.text('#60697C')).optionFont({ size: 15 })
        .backgroundColor(Color.Transparent).onSelect((index: number): void => { this.maxMessages = [20, 50, 100][index]; })
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
    CollectionFormDivider()
    CollectionFormAction({ label: this.busy ? '正在读取近三天邮件…' : '保存并读取近三天邮件',
      onAction: (): void => { this.save(true); } })
    CollectionFormDivider()
    CollectionFormAction({ label: '仅保存设置', onAction: (): void => { this.save(false); } })
  }
  @Builder AccessFields() {
    CollectionFormSwitch({ label: '开启邮件提醒', selected: this.mailEnabled,
      onChangeValue: (value: boolean): void => { this.mailEnabled = value; } })
  }

  @Builder RemoveFields() {
    CollectionFormAction({ label: '移除邮箱与本机邮件', destructive: true, centered: true,
      onAction: (): void => { this.forget(); } })
  }

  build() {
    Column() {
      CollectionFormGroup({ footer: '下方保存后生效。跨天后首次打开应用会自动更新；也可点击汇总页“同步”。保留今天和前两天，首页只突出今日邮件。',
        contentBuilder: (): void => { this.AccessFields(); } })
      CollectionFormGroup({ title: '邮箱账号',
        footer: '先在邮箱网页开启 IMAP 并生成客户端授权码。支持 IMAP 加密收信，暂不支持 Outlook、Gmail 的 OAuth 登录。',
        contentBuilder: (): void => { this.AccountFields(); } })
      CollectionFormGroup({ title: '智能筛选',
        footer: 'AI 使用当前云端模型生成总结；关闭后仅在本机阅读。邮件不写入个人画像，附件和授权码不会发送给 AI。',
        contentBuilder: (): void => { this.AiFields(); } })
      CollectionFormGroup({ title: '同步', footer: this.status,
        contentBuilder: (): void => { this.ReadFields(); } })
      if (this.failed) {
        Text('本次操作未完成，请检查上方同步说明。').fontSize(12).lineHeight(20)
          .fontColor(AppTheme.text('#D54A59')).width('100%').padding({ left: 16, right: 16 }).margin({ bottom: 16 })
      }
      CollectionFormGroup({ footer: '仅读取收件箱，不下载附件，不修改邮箱中的邮件或已读状态。',
        contentBuilder: (): void => { this.RemoveFields(); } })
    }.width('100%').alignItems(HorizontalAlign.Start).enabled(!this.busy && !this.memoryRefreshing)
  }
}
