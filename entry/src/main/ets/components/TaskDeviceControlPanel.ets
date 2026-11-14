import { common } from '@kit.AbilityKit';
import { showToastSafely } from '../utils/PromptSafe';
import { SelfHdcTaskSettings } from '../utils/selfhdc/SelfHdcTaskSettings';

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

  private select(mode: string): void {
    if (this.busy || !this.save(mode)) { return; }
    this.onModeChanged(mode);
  }

  @Builder ModeOption(label: string, value: string) {
    Button({ type: ButtonType.Normal }) {
      Text(label).fontSize(14)
        .fontWeight(this.mode === value ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.mode === value ? $r('app.color.ui_text_primary') : $r('app.color.ui_text_secondary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1).height(36).padding({ left: 8, right: 8 }).borderRadius(10)
    .backgroundColor(this.mode === value ? $r('app.color.ui_surface') : Color.Transparent)
    .enabled(!this.busy).accessibilityText(label + (this.mode === value ? '，已选择' : ''))
    .onClick((): void => { this.select(value); })
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        Image($r('app.media.settings_phone')).width(24).height(24).objectFit(ImageFit.Contain)
        Text('控制方式').fontSize(17).fontColor($r('app.color.ui_text_primary')).layoutWeight(1)
      }.width('100%')
      Row({ space: 4 }) {
        this.ModeOption('手机自己控制', 'phone')
        this.ModeOption('电脑控制', 'pc')
      }.width('100%').padding(4).borderRadius(14).backgroundColor($r('app.color.ui_surface_soft'))
    }.width('100%').padding({ left: 18, right: 18, top: 16, bottom: 16 })
  }
}
