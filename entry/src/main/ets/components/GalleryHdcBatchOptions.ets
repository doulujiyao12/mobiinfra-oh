import { AppTheme } from '../utils/AppTheme';
import { galleryHdcCount } from '../utils/gallery/GalleryHdcPolicy';

@Component
export struct GalleryHdcBatchOptions {
  @State private countText: string = '20';
  onStart: (count: number) => void = (_count: number): void => {};

  private valid(): boolean {
    try { galleryHdcCount(this.countText); return true; } catch (e) { return false; }
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 10 }) {
        ForEach([20, 50, 100], (count: number) => {
          Button(String(count) + ' 张')
            .layoutWeight(1)
            .height(42)
            .fontSize(15)
            .fontColor(AppTheme.text(this.countText === String(count) ? '#FFFFFF' : '#2F5BEA'))
            .backgroundColor(AppTheme.background(this.countText === String(count) ? '#2F5BEA' : '#EEF3FF'))
            .borderRadius(14)
            .onClick((): void => { this.countText = String(count); })
        }, (count: number): string => String(count))
      }.width('100%')
      Row({ space: 12 }) {
        Text('自定义数量').fontSize(14).fontColor(AppTheme.text('#202636'))
        TextInput({ text: this.countText, placeholder: '1–500' })
          .type(InputType.Number)
          .maxLength(3)
          .layoutWeight(1)
          .height(42)
          .fontSize(16)
          .fontColor(AppTheme.text('#202636'))
          .placeholderColor(AppTheme.text('#7C8494'))
          .backgroundColor(AppTheme.background('#F6F7FA'))
          .borderRadius(12)
          .onChange((value: string): void => { this.countText = value; })
        Text('张').fontSize(14).fontColor(AppTheme.text('#737987'))
      }.width('100%')
      Text('按文件修改时间选取最近图片，不等同于图库加入时间。仅读取本地非隐藏图片。')
        .fontSize(12)
        .fontColor(AppTheme.text('#737987'))
        .width('100%')
      Text('沿用当前图库模型配置，读取后开始分析。')
        .fontSize(12)
        .fontColor(AppTheme.text('#737987'))
        .width('100%')
      Button('读取并分析')
        .width('100%')
        .height(46)
        .fontSize(16)
        .fontColor(Color.White)
        .backgroundColor(AppTheme.background('#2F5BEA'))
        .borderRadius(16)
        .enabled(this.valid())
        .onClick((): void => { if (this.valid()) { this.onStart(galleryHdcCount(this.countText)); } })
    }
    .width('100%')
    .padding({ left: 22, right: 22, top: 10, bottom: 24 })
    .backgroundColor(AppTheme.background('#FFFFFF'))
  }
}
