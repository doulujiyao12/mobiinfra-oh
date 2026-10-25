import { AppTheme } from '../utils/AppTheme';
import { CollectionFormGroup, CollectionFormDivider, CollectionFormInput } from './CollectionFormControls';
import { galleryHdcCount } from '../utils/gallery/GalleryHdcPolicy';

@Component
export struct GalleryHdcBatchOptions {
  @State private countText: string = '20';
  onStart: (count: number) => void = (_count: number): void => {};

  private valid(): boolean {
    try { galleryHdcCount(this.countText); return true; } catch (e) { return false; }
  }

  @Builder PictureCountOptions() {
    ForEach([20, 50, 100], (count: number) => {
      Row({ space: 12 }) {
        Text(count + ' 张').fontSize(16).fontColor(AppTheme.text('#172033')).layoutWeight(1)
        Text(this.countText === String(count) ? '✓' : '').fontSize(20).fontColor(AppTheme.text('#007AFF')).width(26)
      }.width('100%').height(52).padding({ left: 16, right: 16 })
        .onClick((): void => { this.countText = String(count); })
      CollectionFormDivider()
    }, (count: number): string => String(count))
    CollectionFormInput({ label: '自定义数量', value: this.countText, placeholder: '1–500 张', inputType: InputType.Number, limit: 3,
      onChangeValue: (value: string): void => { this.countText = value; } })
  }

  build() {
    Column({ space: 4 }) {
      CollectionFormGroup({ title: '选取最近的图片', footer: '按文件修改时间选取本地非隐藏图片。沿用当前图库模型配置，读取后开始分析。',
        contentBuilder: (): void => { this.PictureCountOptions(); } })
      Button('读取并分析').width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#007AFF')).borderRadius(24)
        .enabled(this.valid()).onClick((): void => { if (this.valid()) { this.onStart(galleryHdcCount(this.countText)); } })
    }.width('100%').padding({ left: 20, right: 20, top: 10, bottom: 28 })
      .backgroundColor(AppTheme.pageBackground())
  }
}
