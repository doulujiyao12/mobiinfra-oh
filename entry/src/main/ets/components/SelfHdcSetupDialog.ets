import { ComponentContent, UIContext } from '@kit.ArkUI';
import { AppLogger } from '../utils/AppLogger';
import { showToastSafely } from '../utils/PromptSafe';
import { SelfHdcSetupGuide } from './SelfHdcSetupGuide';

class SelfHdcSetupDialogParams {
  onFinish: (openSettings: boolean) => void = (_openSettings: boolean): void => {};
  onReminderChange: (skipReminder: boolean) => void = (_skipReminder: boolean): void => {};
}

@Component
struct SelfHdcSetupDialogContent {
  params: SelfHdcSetupDialogParams = new SelfHdcSetupDialogParams();
  @State private skipReminder: boolean = false;
  private guideScroller: Scroller = new Scroller();

  private changeReminder(value: boolean): void {
    if (value === this.skipReminder) { return; }
    this.skipReminder = value;
    try {
      this.params.onReminderChange(value);
    } catch (e) {
      this.skipReminder = !value;
      AppLogger.warnCause('SelfHdc', 'Cannot save setup reminder preference', e as Error);
      showToastSafely('提醒设置保存失败，请重试');
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('手机自控设置指南').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#172033').width('100%')
      Text('请按图完成无线调试设置').fontSize(12).fontColor('#667085').width('100%')
      Scroll(this.guideScroller) { SelfHdcSetupGuide() }
        .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      Row({ space: 10 }) {
        Checkbox({ name: 'selfHdcSkipSetupReminder' }).shape(CheckBoxShape.CIRCLE)
          .select(this.skipReminder).width(18).height(18).margin(0)
          .selectedColor('#4F5FEA').unselectedColor('#98A2B3')
          .accessibilityText('不再提醒手机自控设置')
          .onChange((value: boolean): void => { this.changeReminder(value); })
        Text('不再提醒').fontSize(14).fontColor('#667085').layoutWeight(1).height(40)
          .onClick((): void => { this.changeReminder(!this.skipReminder); })
      }.width('100%')
      Row({ space: 12 }) {
        Button('稍后设置').fontSize(15).height(44).layoutWeight(1).backgroundColor('#F0F2F6').fontColor('#475467')
          .onClick((): void => { this.params.onFinish(false); })
        Button('去设置').fontSize(15).height(44).layoutWeight(1).backgroundColor('#4F5FEA').fontColor(Color.White)
          .onClick((): void => { this.params.onFinish(true); })
      }.width('100%')
    }.width('92%').constraintSize({ maxWidth: 420 }).height('80%').padding(20)
      .alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(24)
  }
}

@Builder
function selfHdcSetupDialogBuilder(params: SelfHdcSetupDialogParams) {
  SelfHdcSetupDialogContent({ params: params })
}

export async function showSelfHdcSetupDialog(uiContext: UIContext,
  onReminderChange: (skipReminder: boolean) => void): Promise<boolean> {
  let params = new SelfHdcSetupDialogParams();
  params.onReminderChange = onReminderChange;
  let content: ComponentContent<SelfHdcSetupDialogParams> | null = null;
  let openSettings = false;
  let resolveDismissal: (value: boolean) => void = (_value: boolean): void => {};
  let disappeared = new Promise<boolean>((resolve): void => { resolveDismissal = resolve; });
  params.onFinish = (value: boolean): void => {
    openSettings = value;
    if (content !== null) {
      uiContext.getPromptAction().closeCustomDialog(content).catch((error: Error): void => {
        AppLogger.warnCause('SelfHdc', 'Cannot close setup dialog', error);
        showToastSafely('弹窗关闭失败，请重试');
      });
    }
  };
  content = new ComponentContent(uiContext, wrapBuilder(selfHdcSetupDialogBuilder), params);
  try {
    await uiContext.getPromptAction().openCustomDialog(content, {
      alignment: DialogAlignment.Center, autoCancel: true,
      onDidDisappear: (): void => { resolveDismissal(openSettings); }
    });
    return await disappeared;
  } finally { content.dispose(); }
}
