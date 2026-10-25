import { common } from '@kit.AbilityKit';
import { ComponentContent, UIContext } from '@kit.ArkUI';
import { AppTheme, APP_DARK_MODE_KEY } from '../utils/AppTheme';
import { MailStore } from '../utils/mail/MailStore';
import { MailItem, MailSnapshot, emptyMailSnapshot, mailDay } from '../utils/mail/MailTypes';
import { visibleMail } from '../utils/mail/MailReminderPolicy';
import { showToastSafely } from '../utils/PromptSafe';

class MailTodayParams {
  onChanged: () => void = (): void => {};
  onFinish: (settings: boolean) => void = (_settings: boolean): void => {};
}

@Component
struct MailTodayContent {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  params: MailTodayParams = new MailTodayParams();
  @State private snapshot: MailSnapshot = emptyMailSnapshot();
  @State private all: boolean = false;
  @State private completed: boolean = false;
  @State private expanded: string = '';
  @State private original: string = '';
  private timer: number = -1;
  private store(): MailStore { return new MailStore((getContext(this) as common.Context).filesDir); }
  aboutToAppear(): void {
    this.snapshot = this.store().current();
    this.timer = setInterval((): void => {
      if (this.snapshot.day && this.snapshot.day !== mailDay()) { this.snapshot = this.store().current(); this.params.onChanged(); }
    }, 60000);
  }
  aboutToDisappear(): void { if (this.timer !== -1) { clearInterval(this.timer); } }
  private items(): MailItem[] { return visibleMail(this.snapshot.items, this.all, this.completed); }
  private receivedTime(item: MailItem): string {
    let date = new Date(item.receivedAt);
    return String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0');
  }
  private complete(item: MailItem, completed: boolean): void {
    try {
      if (!this.store().setCompleted(item.id, completed)) { throw new Error('邮件缓存已更新'); }
      this.snapshot = this.store().current();
      this.params.onChanged();
    } catch (e) { showToastSafely('标记未保存，请重新打开后重试'); }
  }
  @Builder MailRow(item: MailItem) {
    Column({ space: 12 }) {
      Column({ space: 9 }) {
        Row() {
          Text(item.analysisKey && item.summary ? 'AI 总结' : '邮件原文 · 待总结')
            .fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#007AFF')).layoutWeight(1)
          Text(this.receivedTime(item)).fontSize(12).fontColor(AppTheme.text('#7C8496'))
        }.width('100%')
        if (this.expanded === item.id) {
          // Do not ellipsize the saved summary in the expanded view.
          Text(item.analysisKey && item.summary ? item.summary : item.subject).fontSize(16).lineHeight(26)
            .fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033')).width('100%')
            .copyOption(CopyOptions.LocalDevice)
        } else {
          Text(item.analysisKey && item.summary ? item.summary : item.subject).fontSize(16).lineHeight(25)
            .fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033')).width('100%')
            .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 8 }) {
          Text(item.from || '发件人未知').fontSize(12).fontColor(AppTheme.text('#7C8496')).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.expanded === item.id ? '收起' : '展开').fontSize(12).fontColor(AppTheme.text('#007AFF'))
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start).opacity(item.completed ? 0.6 : 1)
        .onClick((): void => {
          this.expanded = this.expanded === item.id ? '' : item.id;
          this.original = item.analysisKey && item.summary ? '' : this.expanded;
        })
      if (this.expanded === item.id) {
        if (item.analysisKey && item.reason) {
          Text('关注理由 · ' + item.reason).fontSize(13).lineHeight(21).fontColor(AppTheme.text('#60697C')).width('100%')
        }
        Divider().strokeWidth(0.5).color(AppTheme.border('#E5E5EA'))
        Text(item.subject).fontSize(14).lineHeight(22).fontColor(AppTheme.text('#273148')).width('100%')
          .copyOption(CopyOptions.LocalDevice)
        Text('发件人：' + (item.from || '未知')).fontSize(12).lineHeight(20)
          .fontColor(AppTheme.text('#7C8496')).width('100%').copyOption(CopyOptions.LocalDevice)
        Text(this.original === item.id ? '收起原邮件 ⌃' : '查看原邮件 ›').fontSize(14)
          .fontColor(AppTheme.text('#007AFF')).width('100%').padding({ top: 8, bottom: 8 })
          .onClick((): void => { this.original = this.original === item.id ? '' : item.id; })
        if (this.original === item.id) {
          if (item.bodyError || item.truncated || item.body.length > 12000) {
            Text(item.bodyError || (item.truncated ? '长正文仅保留前段，请到邮箱查看完整内容。' : 'AI仅分析正文前12000字，以下为已获取的正文。'))
              .fontSize(12).lineHeight(20).fontColor(AppTheme.text('#D54A59')).width('100%')
          }
          Text(item.body || '暂无可展示的正文').fontSize(15).lineHeight(25).fontColor(AppTheme.text('#273148'))
            .copyOption(CopyOptions.LocalDevice).width('100%')
        }
        Row({ space: 8 }) {
          Checkbox({ name: item.id }).select(item.completed).width(18).height(18).margin(0)
            .selectedColor(AppTheme.filledBackground('#6372D8')).onChange((value: boolean): void => { this.complete(item, value); })
          Text('已处理').fontSize(13).fontColor(AppTheme.text('#7C8496')).layoutWeight(1)
        }.width('100%').padding({ top: 4, bottom: 12 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(18)
      .backgroundColor(AppTheme.background(Color.White)).borderRadius(18)
  }
  build() {
    Column({ space: 14 }) {
      Row() {
        Text('今日邮件').fontSize(21).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Text('关闭').fontSize(14).fontColor(AppTheme.text('#7C8496')).padding(8).onClick(() => { this.params.onFinish(false); })
      }.width('100%')
      Text('已读取' + this.snapshot.items.length + '封 · 仅收件箱 · 附件暂不读取').fontSize(12).fontColor(AppTheme.text('#7C8496')).width('100%')
      Row({ space: 16 }) {
        Text(this.all ? '全部邮件 ▾' : '关心与待判断 ▾').fontSize(13).fontColor(AppTheme.text('#6372D8')).layoutWeight(1)
          .onClick(() => { this.all = !this.all; })
        Text(this.completed ? '含已处理 ✓' : '未处理').fontSize(13).fontColor(AppTheme.text('#7C8496'))
          .onClick(() => { this.completed = !this.completed; })
      }.width('100%')
      if (this.snapshot.error) {
        Text(this.snapshot.error + (this.snapshot.stale && this.snapshot.syncedAt ? ' 当前显示上次成功读取的缓存。' : ''))
          .fontSize(12).lineHeight(20).fontColor(AppTheme.text('#D54A59')).width('100%')
      }
      if (this.snapshot.notice) {
        Text(this.snapshot.notice).fontSize(12).lineHeight(20).fontColor(AppTheme.text('#7C8496')).width('100%')
      }
      Scroll() {
        Column({ space: 14 }) {
          if (this.items().length === 0) {
            Text(this.snapshot.syncedAt ? '暂时没有符合当前筛选的邮件～\n可以切换全部邮件，或在邮箱设置中调整关注偏好。' : '还没有读取今天的邮件，去邮箱设置中同步一下吧～')
              .fontSize(14).lineHeight(24).fontColor(AppTheme.text('#7C8496')).width('100%').margin({ top: 30 })
          }
          ForEach(this.items(), (item: MailItem) => { this.MailRow(item) },
            (item: MailItem): string => item.id + ':' + String(item.completed))
        }.width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      Text('管理邮箱与关注偏好').fontSize(13).fontColor(AppTheme.text('#6372D8')).width('100%')
        .padding({ top: 8, bottom: 8 }).onClick(() => { this.params.onFinish(true); })
    }.width('100%').constraintSize({ maxWidth: 600 }).height('86%').padding(20)
      .alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.pageBackground()).borderRadius(28)
  }
}
@Builder
function mailTodayBuilder(params: MailTodayParams) { MailTodayContent({ params: params }) }

export async function showMailTodayDialog(uiContext: UIContext, onChanged: () => void): Promise<boolean> {
  let params = new MailTodayParams(); params.onChanged = onChanged;
  let content: ComponentContent<MailTodayParams> | null = null;
  let settings = false;
  let finish: (value: boolean) => void = (_value: boolean): void => {};
  let disappeared = new Promise<boolean>((resolve): void => { finish = resolve; });
  params.onFinish = (openSettings: boolean): void => {
    settings = openSettings;
    if (content !== null) {
      uiContext.getPromptAction().closeCustomDialog(content).catch((): void => { showToastSafely('请点击外部关闭后重试'); });
    }
  };
  content = new ComponentContent(uiContext, wrapBuilder(mailTodayBuilder), params);
  try {
    await uiContext.getPromptAction().openCustomDialog(content, { alignment: DialogAlignment.Bottom, autoCancel: true,
      onDidDisappear: (): void => { finish(settings); } });
    return await disappeared;
  } finally { content.dispose(); }
}
