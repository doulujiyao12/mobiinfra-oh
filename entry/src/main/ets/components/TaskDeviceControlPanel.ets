import { common } from '@kit.AbilityKit';
import { showToastSafely } from '../utils/PromptSafe';
import { SelfHdcTaskSettings } from '../utils/selfhdc/SelfHdcTaskSettings';
import { SelfHdcSetupGuard } from '../utils/selfhdc/SelfHdcSetupGuard';

@Component
export struct TaskDeviceControlPanel {
  @Prop mode: string = 'phone';
  @Prop busy: boolean = false;
  onModeChanged: (mode: string) => void = (_mode: string): void => {};
  private filesDir: string = '';

  aboutToAppear(): void {
    this.filesDir = (getContext(this) as common.UIAbilityContext).filesDir;
  }

  private save(mode: string): boolean {
    try {
      SelfHdcTaskSettings.saveMode(this.filesDir, mode);
      return true;
    } catch (e) { showToastSafely('连接配置保存失败：' + (e as Error).message, 2200); return false; }
  }

  private async select(mode: string): Promise<void> {
    if (this.busy || !this.save(mode)) { return; }
    this.onModeChanged(mode);
    if (mode === 'phone') { await SelfHdcSetupGuard.ensure(this.getUIContext(), this.filesDir, 'select-phone-control'); }
  }

  build() {
    Column({ space: 10 }) {
      Text('任务控制方式').fontSize(15).fontWeight(FontWeight.Bold).width('100%')
      Row({ space: 10 }) {
        Button('电脑控制').layoutWeight(1).height(40).fontSize(14)
          .backgroundColor(this.mode === 'pc' ? '#276EF1' : '#EEF1FF')
          .fontColor(this.mode === 'pc' ? Color.White : '#276EF1').enabled(!this.busy)
          .onClick(() => { this.select('pc'); })
        Button('手机自己控制').layoutWeight(1).height(40).fontSize(14)
          .backgroundColor(this.mode === 'phone' ? '#276EF1' : '#EEF1FF')
          .fontColor(this.mode === 'phone' ? Color.White : '#276EF1').enabled(!this.busy)
          .onClick(() => { this.select('phone'); })
      }.width('100%')
    }.width('86%').padding(14).backgroundColor(Color.White).borderRadius(14).margin({ bottom: 16 })
  }
}
