import { common } from '@kit.AbilityKit';
import { AppTheme } from '../utils/AppTheme';
import { AppLogger } from '../utils/AppLogger';
import { showToastSafely } from '../utils/PromptSafe';
import {
  CollectionReminderState, collectionReminderMissedDays, collectionReminderTimeText
} from '../utils/CollectionReminderPolicy';
import {
  COLLECTION_REMINDER_VERSION_KEY, CollectionReminderService
} from '../utils/CollectionReminderService';

@Component
export struct CollectionReminderPanel {
  @State private reminder: CollectionReminderState = new CollectionReminderState();
  @State private saving: boolean = false;
  @StorageProp(COLLECTION_REMINDER_VERSION_KEY) @Watch('reload') private version: number = 0;

  aboutToAppear(): void {
    try {
      CollectionReminderService.initialize(getContext(this) as common.UIAbilityContext);
      this.reload();
    } catch (e) { AppLogger.errorCause('CollectionReminder', 'Settings load failed', e as Error); }
  }

  private reload(): void {
    try { this.reminder = CollectionReminderService.load(); }
    catch (e) { AppLogger.errorCause('CollectionReminder', 'Settings reload failed', e as Error); }
  }

  private async changeEnabled(enabled: boolean): Promise<void> {
    if (this.saving || (enabled === this.reminder.enabled && this.reminder.errorText.length === 0)) { return; }
    this.saving = true;
    try {
      await CollectionReminderService.setEnabled(enabled);
      showToastSafely(enabled ? '每日采集提醒已开启' : '采集提醒已关闭', 1500);
    } catch (e) { showToastSafely('提醒设置失败，请查看下方说明', 2000); }
    finally { this.saving = false; this.reload(); }
  }

  private pickTime(): void {
    let selected = new Date();
    selected.setHours(this.reminder.hour, this.reminder.minute, 0, 0);
    this.getUIContext().showTimePickerDialog({
      selected: selected,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult): void => {
        this.saveTime(value.hour, value.minute).catch((e: Error): void => {
          AppLogger.errorCause('CollectionReminder', 'Time update failed', e);
        });
      }
    });
  }

  private async saveTime(hour: number, minute: number): Promise<void> {
    if (this.saving) { return; }
    this.saving = true;
    try { await CollectionReminderService.setTime(hour, minute); }
    catch (e) { showToastSafely('时间已保存，但提醒尚未生效，请查看下方说明', 2400); }
    finally { this.saving = false; this.reload(); }
  }

  private description(): string {
    if (this.reminder.errorText.length > 0) { return this.reminder.errorText; }
    if (this.saving) { return '正在更新提醒…'; }
    if (!this.reminder.enabled) { return '每天提醒，点击通知并解锁后采集。'; }
    if (this.reminder.registeredStamp.length === 0) { return '提醒尚未注册成功，请点击重试。'; }
    if (this.reminder.lastCollectedAt > 0) {
      let days = collectionReminderMissedDays(this.reminder.lastCollectedAt, Date.now());
      return days > 0 ? '已连续' + days + '天未采集，点击一键执行开始收集' : '今天已采集 · 每天到点提醒';
    }
    return '提醒已生效 · 采集你的第一份足迹吧';
  }

  build() {
    Row({ space: 12 }) {
      Image($r('app.media.settings_automation')).width(24).height(24)
        .objectFit(ImageFit.Contain).margin({ top: 6 })
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text('采集提醒').fontSize(17).fontColor($r('app.color.ui_text_primary'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('每天 ' + collectionReminderTimeText(this.reminder.hour, this.reminder.minute))
            .height(36).padding({ left: 10, right: 10 }).fontSize(13)
            .fontColor($r('app.color.ui_accent_blue'))
            .backgroundColor($r('app.color.ui_surface_soft')).borderRadius(18)
            .flexShrink(0).enabled(!this.saving)
            .accessibilityText('修改提醒时间，每天 ' + collectionReminderTimeText(this.reminder.hour, this.reminder.minute))
            .onClick((): void => { this.pickTime(); })
        }.width('100%')
        if (this.reminder.enabled || this.saving || this.reminder.errorText.length > 0) {
          Row({ space: 8 }) {
            Text(this.description()).fontSize(12)
              .fontColor(AppTheme.text(this.reminder.errorText.length > 0 ? '#B42318' : '#6F7584'))
              .layoutWeight(1).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.reminder.errorText.length > 0 ||
              (this.reminder.enabled && this.reminder.registeredStamp.length === 0)) {
              Button('重试').height(30).fontSize(12).padding({ left: 10, right: 10 })
                .fontColor($r('app.color.ui_accent_blue'))
                .backgroundColor($r('app.color.ui_surface_soft')).flexShrink(0)
                .enabled(!this.saving)
                .onClick((): void => {
                  this.changeEnabled(true).catch((e: Error): void => {
                    AppLogger.errorCause('CollectionReminder', 'Retry failed', e);
                  });
                })
            }
          }.width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.reminder.enabled })
        .selectedColor($r('app.color.ui_accent_blue')).width(44).height(28).flexShrink(0)
        .margin({ top: 4 }).accessibilityText('采集提醒').enabled(!this.saving)
        .onChange((enabled: boolean): void => {
          this.changeEnabled(enabled).catch((e: Error): void => {
            AppLogger.errorCause('CollectionReminder', 'Toggle failed', e);
          });
        })
    }
    .width('100%').alignItems(VerticalAlign.Top)
    .padding({ left: 18, right: 18, top: 12, bottom: 14 })
  }
}
