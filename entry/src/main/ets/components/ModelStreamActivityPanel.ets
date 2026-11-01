import { AppTheme } from '../utils/AppTheme';
import { ModelStreamActivity, isModelStreamActive, modelStreamActivityText } from '../datamanager/ModelStreamActivity';

@Component
export struct ModelStreamActivityPanel {
  @Prop activities: ModelStreamActivity[] = [];
  @Prop debugEnabled: boolean = false;
  @State private expandedId: string = '';

  private activeCount(): number { return this.activities.filter((value: ModelStreamActivity): boolean => isModelStreamActive(value.phase)).length; }
  private doneCount(): number { return this.activities.filter((value: ModelStreamActivity): boolean => value.phase === 'succeeded').length; }
  private phaseColor(value: ModelStreamActivity): ResourceColor {
    return AppTheme.text(value.phase === 'failed' || value.phase === 'invalid' || value.phase === 'repeated' ? '#B63E3E' : '#657086');
  }
  private activityKey(value: ModelStreamActivity): string {
    // Snapshots are plain interface objects. ForEach reuses an unchanged key's
    // builder closure, so include displayed state to replace stale row content.
    return value.id + ':' + value.label + ':' + value.attempt + ':' + value.phase + ':' +
      value.elapsedSeconds + ':' + value.idleSeconds + ':' + value.receivedBytes + ':' +
      value.contentChars + ':' + value.reasoningChars + ':' + value.buffered + ':' +
      value.repeating + ':' + this.debugEnabled + ':' + value.preview;
  }

  build() {
    Column({ space: 8 }) {
      Text('最近请求 · 进行中 ' + this.activeCount() + ' · 完成 ' + this.doneCount())
        .fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#414D65')).width('100%')
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.activities, (value: ModelStreamActivity) => {
            Column({ space: 5 }) {
              Text(value.label + ' · 第 ' + value.attempt + ' 次')
                .fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#151A28'))
                .width('100%').maxLines(2)
              Text(modelStreamActivityText(value)).fontSize(11).fontColor(this.phaseColor(value)).width('100%')
              if (value.buffered) {
                Text('服务端返回整包内容，未逐段输出').fontSize(11).fontColor(AppTheme.text('#657086')).width('100%')
              }
              if (this.debugEnabled) {
                if (value.repeating) {
                  Text(value.phase === 'repeated' ? '该请求已停止，已完成的结果已保留' : '检测到重复片段')
                    .fontSize(11).fontColor(AppTheme.text('#A16A18')).width('100%')
                }
                Text(this.expandedId === value.id ? '收起输出' : '查看实时输出')
                  .fontSize(11).fontColor(AppTheme.text('#4F68FF')).width('100%')
                  .onClick(() => { this.expandedId = this.expandedId === value.id ? '' : value.id; })
                if (this.expandedId === value.id) {
                  Text(value.preview || '尚未收到模型输出')
                    .fontSize(11).fontFamily('monospace').fontColor(AppTheme.text('#414D65'))
                    .copyOption(CopyOptions.InApp).width('100%')
                }
              }
            }
            .width('100%').padding(10).borderRadius(10).backgroundColor(AppTheme.background('#F3F5FA'))
          }, (value: ModelStreamActivity): string => this.activityKey(value))
        }.width('100%')
      }
      .width('100%').height(this.expandedId.length > 0 && this.debugEnabled ? 220 : 150)
    }.width('100%')
  }
}
