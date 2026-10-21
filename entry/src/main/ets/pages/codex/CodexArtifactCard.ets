import { fileUri } from '@kit.CoreFileKit';
import { AppTheme } from '../../utils/AppTheme';
import { CodexArtifact } from './CodexTypes';

@Component
export struct CodexArtifactCard {
  @Prop artifact: CodexArtifact = { id: '', turnId: '', name: '', size: 0, mimeType: '', sha256: '', createdAt: 0 };
  @Prop localPath: string = '';
  @Prop receiving: boolean = false;
  @Prop progress: string = '';
  onOpen: () => void = () => {};
  onExport: () => void = () => {};
  onRetry: () => void = () => {};

  private sizeLabel(): string {
    if (this.artifact.size < 1024 * 1024) { return Math.max(1, Math.round(this.artifact.size / 1024)) + ' KB'; }
    return (this.artifact.size / (1024 * 1024)).toFixed(1) + ' MB';
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Image($r('app.media.codex_document')).width(28).height(28).fillColor(AppTheme.text('#5968FF'))
        Column({ space: 5 }) {
          Text(this.artifact.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.sizeLabel() + ' · ' + (this.localPath ? '已保存到此会话' : this.receiving ? this.progress : '等待接收'))
            .fontSize(11).fontColor(AppTheme.text('#747B87'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').onClick(() => { if (this.localPath) { this.onOpen(); } })
      if (this.localPath && this.artifact.mimeType.startsWith('image/')) {
        Image(fileUri.getUriFromPath(this.localPath)).width('100%').height(160).objectFit(ImageFit.Contain).borderRadius(12)
          .onClick(() => { this.onOpen(); })
      }
      Row({ space: 10 }) {
        if (this.localPath) {
          Button('打开').fontSize(13).height(36).padding({ left: 18, right: 18 })
            .backgroundColor(AppTheme.background('#EEF0FF')).fontColor(AppTheme.text('#5968FF')).onClick(() => { this.onOpen(); })
          Button('另存为').fontSize(13).height(36).padding({ left: 18, right: 18 })
            .backgroundColor(Color.Transparent).fontColor(AppTheme.text('#747B87')).onClick(() => { this.onExport(); })
        } else if (!this.receiving) {
          Button('重试接收').fontSize(13).height(36).padding({ left: 18, right: 18 })
            .backgroundColor(AppTheme.background('#EEF0FF')).fontColor(AppTheme.text('#5968FF')).onClick(() => { this.onRetry(); })
        }
      }.width('100%')
    }.width('100%').padding(16).backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(18)
      .border({ width: 1, color: AppTheme.border('#ECEEF3') })
  }
}
