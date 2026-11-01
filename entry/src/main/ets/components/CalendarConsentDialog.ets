import { ComponentContent, UIContext } from '@kit.ArkUI';
import { AppTheme, APP_DARK_MODE_KEY } from '../utils/AppTheme';
import { AppLogger } from '../utils/AppLogger';
import { showToastSafely } from '../utils/PromptSafe';

class CalendarConsentParams {
  onSkipChange: (skip: boolean) => void = (_skip: boolean): void => {};
  onFinish: (enable: boolean) => void = (_enable: boolean): void => {};
}

@Component
struct CalendarConsentContent {
  @StorageProp(APP_DARK_MODE_KEY) private darkMode: boolean = false;
  params: CalendarConsentParams = new CalendarConsentParams();
  @State private skipReminder: boolean = false;
  @State private closing: boolean = false;

  private setSkip(skip: boolean): void {
    try { this.params.onSkipChange(skip); this.skipReminder = skip; }
    catch (e) { showToastSafely('提醒偏好未保存，请重试'); }
  }

  private finish(enable: boolean): void {
    if (this.closing) { return; }
    this.closing = true;
    this.params.onFinish(enable);
  }

  build() {
    Column({ space: 16 }) {
      Text('把日程也交给我记住吧').fontSize(21).fontWeight(FontWeight.Bold)
        .fontColor(AppTheme.text('#172033')).width('100%')
      Text('在首页查看明天和未来7天的安排，也可以在聊天里问我你的日程。')
        .fontSize(15).lineHeight(23).fontColor(AppTheme.text('#4E586C')).width('100%')
      Text('由系统申请日历读取权限。开启后，跨天首次打开应用会更新日历，并按当前记忆模型配置分析日程。可选择来源及是否参与画像。')
        .fontSize(12).lineHeight(19).fontColor(AppTheme.text('#7C8496')).width('100%')
      Row({ space: 9 }) {
        Checkbox({ name: 'calendarSkipStartupReminder' }).shape(CheckBoxShape.CIRCLE)
          .select(this.skipReminder).width(18).height(18).margin(0)
          .selectedColor(AppTheme.filledBackground('#6372D8'))
          .unselectedColor(AppTheme.border('#98A2B3')).enabled(!this.closing)
          .onChange((skip: boolean): void => { this.setSkip(skip); })
        Text('不再提醒').fontSize(14).fontColor(AppTheme.text('#60697C')).layoutWeight(1)
          .onClick(() => { if (!this.closing) { this.setSkip(!this.skipReminder); } })
      }.width('100%').height(32)
      Text(this.skipReminder ? '之后想开启：汇总 → 日历分析，打开开关即可。' :
        '本次暂不开启后，不再自动弹出；可到“汇总 → 日历分析”开启。')
        .fontSize(12).lineHeight(19).fontColor(AppTheme.text(this.skipReminder ? '#6372D8' : '#7C8496')).width('100%')
      Row({ space: 10 }) {
        Button('暂不开启').fontSize(15).height(44).layoutWeight(1).borderRadius(14)
          .backgroundColor(AppTheme.background('#F0F2F6')).fontColor(AppTheme.text('#60697C'))
          .enabled(!this.closing).onClick(() => { this.finish(false); })
        Button('授权并开启').fontSize(15).height(44).layoutWeight(1).borderRadius(14)
          .backgroundColor(AppTheme.filledBackground('#6372D8')).fontColor(Color.White)
          .enabled(!this.closing).onClick(() => { this.finish(true); })
      }.width('100%')
    }.width('90%').constraintSize({ maxWidth: 420 }).padding(24)
      .alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.background(Color.White)).borderRadius(26)
  }
}

@Builder
function calendarConsentBuilder(params: CalendarConsentParams) { CalendarConsentContent({ params: params }) }

export async function showCalendarConsentDialog(uiContext: UIContext,
  onSkipChange: (skip: boolean) => void): Promise<boolean> {
  let params = new CalendarConsentParams();
  params.onSkipChange = onSkipChange;
  let content: ComponentContent<CalendarConsentParams> | null = null;
  let enable = false;
  let finish: (value: boolean) => void = (_value: boolean): void => {};
  let disappeared = new Promise<boolean>((resolve): void => { finish = resolve; });
  params.onFinish = (value: boolean): void => {
    enable = value;
    if (content !== null) {
      uiContext.getPromptAction().closeCustomDialog(content).catch((error: Error): void => {
        AppLogger.warnCause('Calendar', 'Cannot close consent dialog', error);
        showToastSafely('弹窗关闭失败，请点击外部关闭后重试');
      });
    }
  };
  content = new ComponentContent(uiContext, wrapBuilder(calendarConsentBuilder), params);
  try {
    await uiContext.getPromptAction().openCustomDialog(content, {
      alignment: DialogAlignment.Center, autoCancel: true,
      onDidDisappear: (): void => { finish(enable); }
    });
    return await disappeared;
  } finally { content.dispose(); }
}
