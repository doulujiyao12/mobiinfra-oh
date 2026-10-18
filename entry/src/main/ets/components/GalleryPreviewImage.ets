import { AppTheme } from '../utils/AppTheme';
import { GalleryImageStore } from '../utils/gallery/GalleryImageStore';

@Component
export struct GalleryPreviewImage {
  @Prop @Watch('sourceChanged') source: string = '';
  @Prop imageId: string = '';
  @Prop fit: ImageFit = ImageFit.Cover;
  @State private failed: boolean = false;

  private sourceChanged(): void { this.failed = false; }

  build() {
    Stack() {
      if (this.source.length > 0 && !this.failed) {
        Image(this.source)
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
          .onError((error) => {
            this.failed = true;
            GalleryImageStore.report('DISPLAY_FAILED id=' + this.imageId +
              ' message=' + (error ? error.message : '图片加载失败'));
          })
      } else {
        Text('图片暂不可用')
          .fontSize(11)
          .fontColor(AppTheme.text('#7F8592'))
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .padding(6)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.background('#F2F4F7'))
    .clip(true)
  }
}
