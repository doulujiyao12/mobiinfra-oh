import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { AppTheme } from '../../utils/AppTheme';
import { AppHeader, APP_HEADER_CONTENT_GAP } from '../../components/AppHeader';
import { FrostedPage } from '../../components/FrostedPage';
import { applyPageStatusBar } from '../../utils/PageStatusBar';
import { showToastSafely } from '../../utils/PromptSafe';
import {
  CODEX_BRIDGE_VERSION, CODEX_DOWNLOAD_NOTICE, CODEX_RELEASE_URL, CodexDownload, CodexGuide,
  CodexGuideStep, CodexHelpLink, CodexHelpParams, CodexHelpSection, CodexPlatform,
  codexConnectionGuide, codexDownloads, codexHelpSection, codexTailscaleGuide
} from './CodexHelpContent';

@Entry
@Component
struct CodexHelpPage {
  @State private section: CodexHelpSection = CodexHelpSection.Connect;
  @State private platform: CodexPlatform = CodexPlatform.Windows;
  private pageScroller: Scroller = new Scroller();
  private platforms: CodexPlatform[] = [CodexPlatform.Windows, CodexPlatform.Mac, CodexPlatform.Linux];
  private downloads: CodexDownload[] = codexDownloads();

  aboutToAppear(): void {
    const params = router.getParams() as CodexHelpParams | undefined;
    this.section = codexHelpSection(params?.section ?? 'connect');
  }

  onPageShow(): void { applyPageStatusBar(this.getUIContext(), '#F6F8FC'); }
  onPageHide(): void { applyPageStatusBar(this.getUIContext(), '#FFFFFF'); }

  private title(): string {
    if (this.section === CodexHelpSection.Download) { return '下载连接器'; }
    return this.section === CodexHelpSection.Tailscale ? 'Tailscale 组网' : '连接指南';
  }

  private guide(): CodexGuide {
    return this.section === CodexHelpSection.Tailscale ? codexTailscaleGuide() : codexConnectionGuide(this.platform);
  }

  private platformName(value: CodexPlatform): string {
    if (value === CodexPlatform.Windows) { return 'Windows'; }
    return value === CodexPlatform.Mac ? 'macOS' : 'Linux · CLI';
  }

  private async openLink(url: string): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await context.openLink(url);
    } catch (e) {
      showToastSafely('无法打开浏览器，可复制链接后访问', 2200);
    }
  }

  private async copyText(value: string, message: string): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
      await pasteboard.getSystemPasteboard().setData(data);
      showToastSafely(message, 1500);
    } catch (e) {
      showToastSafely('复制失败，请稍后重试', 1800);
    }
  }

  @Builder private Header() {
    AppHeader({ title: this.title(), showBackButton: true, onBackClick: (): void => { router.back(); } })
  }

  @Builder private PlatformPicker() {
    Row({ space: 4 }) {
      ForEach(this.platforms, (value: CodexPlatform) => {
        Button(this.platformName(value)).type(ButtonType.Normal).layoutWeight(1).height(36).fontSize(13)
          .fontWeight(this.platform === value ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(AppTheme.text(this.platform === value ? '#172033' : '#747B87'))
          .backgroundColor(this.platform === value ? AppTheme.background('#FFFFFF') : Color.Transparent)
          .borderRadius(10).padding({ left: 4, right: 4 })
          .onClick(() => { this.platform = value; this.pageScroller.scrollEdge(Edge.Top); })
      }, (value: CodexPlatform) => value)
    }.padding(4).width('100%').backgroundColor(AppTheme.background('#EEF0F5')).borderRadius(14)
  }

  @Builder private DownloadRow(item: CodexDownload) {
    Row({ space: 10 }) {
      Column({ space: 5 }) {
        Text(item.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
        Text(item.detail).fontSize(12).lineHeight(18).fontColor(AppTheme.text('#747B87')).maxLines(2)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        .onClick(() => { this.openLink(item.url); })
      Button('下载').fontSize(13).height(36).padding({ left: 14, right: 14 })
        .fontColor(AppTheme.text('#5968FF')).backgroundColor(AppTheme.background('#EEF0FF'))
        .accessibilityText('下载 ' + item.title).onClick(() => { this.openLink(item.url); })
      Button('复制').fontSize(12).height(36).padding({ left: 8, right: 8 })
        .fontColor(AppTheme.text('#747B87')).backgroundColor(Color.Transparent)
        .accessibilityText('复制 ' + item.title + ' 下载链接')
        .onClick(() => { this.copyText(item.url, '下载链接已复制，可发送到电脑'); })
    }.width('100%').padding({ left: 18, right: 12, top: 16, bottom: 16 })
  }

  @Builder private DownloadContent() {
    Column({ space: 8 }) {
      Text('把 Codex 带到手机').fontSize(25).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
      Text('在电脑安装连接器，再用手机配对。也可以复制下载链接，发送到电脑打开。')
        .fontSize(14).lineHeight(22).fontColor(AppTheme.text('#747B87'))
    }.width('100%').alignItems(HorizontalAlign.Start)
    Column() {
      ForEach(this.downloads, (item: CodexDownload, index: number) => {
        if (index > 0) { Divider().color(AppTheme.border('#E9EBF0')).margin({ left: 18, right: 18 }) }
        this.DownloadRow(item)
      }, (item: CodexDownload) => item.id)
    }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20).clip(true)
    Text('版本 ' + CODEX_BRIDGE_VERSION + ' · ' + CODEX_DOWNLOAD_NOTICE).fontSize(12).lineHeight(20)
      .fontColor(AppTheme.text('#747B87')).width('100%')
    Button('查看 Release 与校验清单').height(42).fontSize(14).backgroundColor(Color.Transparent)
      .fontColor(AppTheme.text('#5968FF')).onClick(() => { this.openLink(CODEX_RELEASE_URL); })
    Button('如何连接？').height(42).fontSize(14).backgroundColor(Color.Transparent)
      .fontColor(AppTheme.text('#5968FF')).onClick(() => {
        this.section = CodexHelpSection.Connect; this.pageScroller.scrollEdge(Edge.Top);
      })
  }

  @Builder private Step(item: CodexGuideStep, index: number) {
    Row({ space: 14 }) {
      Text((index + 1).toString()).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.text('#5968FF')).width(28).height(28).textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.background('#EEF0FF')).borderRadius(14)
      Column({ space: 9 }) {
        Text(item.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
        Text(item.body).fontSize(14).lineHeight(23).fontColor(AppTheme.text('#626B7C')).width('100%')
        if (item.command) {
          Column({ space: 8 }) {
            Text(item.command).fontSize(12).fontFamily('monospace').lineHeight(20)
              .fontColor(AppTheme.text('#34405A')).width('100%').copyOption(CopyOptions.LocalDevice)
            Button('复制命令').fontSize(12).height(32).padding({ left: 10, right: 10 })
              .backgroundColor(Color.Transparent).fontColor(AppTheme.text('#5968FF'))
              .onClick(() => { this.copyText(item.command, '命令已复制，请先替换示例路径和 IP'); })
          }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
            .backgroundColor(AppTheme.background('#F4F6FA')).borderRadius(12)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top).padding(18)
  }

  @Builder private GuideContent() {
    if (this.section === CodexHelpSection.Connect) { this.PlatformPicker() }
    Column({ space: 10 }) {
      Text(this.guide().title).fontSize(24).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
      Text(this.guide().intro).fontSize(14).lineHeight(23).fontColor(AppTheme.text('#747B87'))
      Text(this.guide().notice).fontSize(12).lineHeight(20).fontColor(AppTheme.text('#747B87'))
    }.width('100%').alignItems(HorizontalAlign.Start)
    Column() {
      ForEach(this.guide().steps, (item: CodexGuideStep, index: number) => {
        if (index > 0) { Divider().color(AppTheme.border('#E9EBF0')).margin({ left: 60, right: 18 }) }
        this.Step(item, index)
      }, (item: CodexGuideStep) => this.guide().id + ':' + item.title)
    }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20).clip(true)
    if (this.guide().notes.length > 0) {
      Column({ space: 14 }) {
        Text('你可能还想知道').fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
        ForEach(this.guide().notes, (note: string) => {
          Text(note).fontSize(13).lineHeight(22).fontColor(AppTheme.text('#747B87')).width('100%')
        }, (note: string) => note)
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 4, right: 4 })
    }
    Column() {
      ForEach(this.guide().links, (link: CodexHelpLink, index: number) => {
        if (index > 0) { Divider().color(AppTheme.border('#E9EBF0')).margin({ left: 18, right: 18 }) }
        Row() {
          Text(link.title).fontSize(14).fontColor(AppTheme.text('#5968FF')).layoutWeight(1)
          Text('↗').fontSize(16).fontColor(AppTheme.text('#9198A5'))
        }.width('100%').padding(18).onClick(() => { this.openLink(link.url); })
      }, (link: CodexHelpLink) => link.url)
    }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(18)
  }

  @Builder private Content() {
    Scroll(this.pageScroller) {
      Column({ space: 24 }) {
        if (this.section === CodexHelpSection.Download) { this.DownloadContent() }
        else { this.GuideContent() }
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, top: APP_HEADER_CONTENT_GAP, bottom: 36 })
    }.width('100%').height('100%').clip(false).align(Alignment.Top)
  }

  build() {
    Column() {
      FrostedPage({ pageBackgroundColor: '#F6F8FC', scrollers: [this.pageScroller],
        headerBuilder: (): void => { this.Header(); }, contentBuilder: (): void => { this.Content(); } })
    }.width('100%').height('100%')
  }
}
