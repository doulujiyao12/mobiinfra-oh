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
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        Text('采集提醒')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.text('#11182F'))
          .layoutWeight(1)
          .maxLines(1)
        Button(collectionReminderTimeText(this.reminder.hour, this.reminder.minute))
          .height(34)
          .padding({ left: 12, right: 12 })
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.text('#276EF1'))
          .backgroundColor(AppTheme.background('#EAF2FF'))
          .borderRadius(10)
          .enabled(!this.saving)
          .onClick((): void => { this.pickTime(); })
        Toggle({ type: ToggleType.Switch, isOn: this.reminder.enabled })
          .selectedColor('#276EF1')
          .enabled(!this.saving)
          .onChange((enabled: boolean): void => {
            this.changeEnabled(enabled).catch((e: Error): void => {
              AppLogger.errorCause('CollectionReminder', 'Toggle failed', e);
            });
          })
      }
      .width('100%')
      Row({ space: 8 }) {
        Text(this.description())
          .fontSize(12)
          .fontColor(AppTheme.text(this.reminder.errorText.length > 0 ? '#B42318' : '#6F7584'))
          .layoutWeight(1)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.reminder.errorText.length > 0 ||
          (this.reminder.enabled && this.reminder.registeredStamp.length === 0)) {
          Button('重试')
            .height(30)
            .fontSize(12)
            .fontColor(AppTheme.text('#276EF1'))
            .backgroundColor(AppTheme.background('#EAF2FF'))
            .enabled(!this.saving)
            .onClick((): void => {
              this.changeEnabled(true).catch((e: Error): void => {
                AppLogger.errorCause('CollectionReminder', 'Retry failed', e);
              });
            })
        }
      }
      .width('100%')
    }
    .width('86%')
    .padding(14)
    .backgroundColor(AppTheme.background(Color.White))
    .borderRadius(14)
    .margin({ top: 2, bottom: 14 })
  }
}
