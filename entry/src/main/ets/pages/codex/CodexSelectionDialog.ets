import { ComponentContent, UIContext } from '@kit.ArkUI';
import { AppTheme } from '../../utils/AppTheme';
import { showToastSafely } from '../../utils/PromptSafe';

export interface CodexSelectionOption { id: string; title: string; subtitle: string; }

class CodexSelectionParams {
  title: string = '';
  description: string = '';
  options: CodexSelectionOption[] = [];
  folder: boolean = false;
  onFinish: (index: number) => void = (_index: number): void => {};
}

@Component
struct CodexSelectionContent {
  params: CodexSelectionParams = new CodexSelectionParams();
  @State private selectedIndex: number = -1;

  @Builder private OptionRow(option: CodexSelectionOption, index: number) {
    Row({ space: 12 }) {
      Image(this.params.folder ? $r('app.media.codex_folder') : $r('app.media.codex_computer'))
        .width(26).height(26).fillColor(AppTheme.text('#5968FF'))
      Column({ space: 5 }) {
        // Horizontal scrolling preserves the same font size for every option.
        Scroll() {
          Text(option.title).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.text('#172033')).maxLines(1)
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          .align(Alignment.Start).width('100%')
        if (option.subtitle) {
          Scroll() {
            Text(option.subtitle).fontSize(12).fontColor(AppTheme.text('#747B87')).maxLines(1)
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
            .align(Alignment.Start).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Radio({ value: option.id, group: 'codex-delegation-target' })
        .checked(this.selectedIndex === index).width(22).height(22).margin(0)
        .radioStyle({ checkedBackgroundColor: AppTheme.filledBackground('#5968FF'),
          uncheckedBorderColor: AppTheme.border('#B7BECC'), indicatorColor: AppTheme.text(Color.White) })
        .accessibilityText(option.title)
        .onChange((checked: boolean): void => { if (checked) { this.selectedIndex = index; } })
    }.width('100%').height(80).padding({ left: 14, right: 14 })
      .backgroundColor(AppTheme.background(this.selectedIndex === index ? '#EEF0FF' : '#F8FAFD'))
      .borderRadius(16).border({ width: this.selectedIndex === index ? 1.5 : 1,
        color: AppTheme.border(this.selectedIndex === index ? '#5968FF' : '#E2E6EE') })
      .onClick((): void => { this.selectedIndex = index; })
  }

  build() {
    Column({ space: 14 }) {
      Column({ space: 7 }) {
        Text(this.params.title).fontSize(22).fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text('#172033')).width('100%')
        Text(this.params.description).fontSize(13).fontColor(AppTheme.text('#747B87')).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
      List({ space: 10 }) {
        ForEach(this.params.options, (option: CodexSelectionOption, index: number) => {
          ListItem() { this.OptionRow(option, index) }
        }, (option: CodexSelectionOption) => option.id)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      Text('上下滑动列表 · 左右滑动查看完整名称').fontSize(11).fontColor(AppTheme.text('#747B87')).width('100%')
      Row({ space: 12 }) {
        Button('取消').fontSize(15).height(44).layoutWeight(1)
          .backgroundColor(AppTheme.background('#F0F2F6')).fontColor(AppTheme.text('#475467'))
          .onClick((): void => { this.params.onFinish(-1); })
        Button('继续').fontSize(15).height(44).layoutWeight(1).enabled(this.selectedIndex >= 0)
          .backgroundColor(AppTheme.filledBackground(this.selectedIndex >= 0 ? '#5968FF' : '#A0A6B2'))
          .fontColor(AppTheme.text(Color.White))
          .onClick((): void => { if (this.selectedIndex >= 0) { this.params.onFinish(this.selectedIndex); } })
      }.width('100%')
    }.width('92%').height(this.params.options.length > 3 ? '72%' : this.params.options.length * 90 + 196)
      .constraintSize({ maxWidth: 440, maxHeight: '82%' }).padding(20)
      .alignItems(HorizontalAlign.Start).backgroundColor(AppTheme.background(Color.White)).borderRadius(26)
  }
}

@Builder
function codexSelectionBuilder(params: CodexSelectionParams) {
  CodexSelectionContent({ params: params })
}

export async function showCodexSelectionDialog(uiContext: UIContext, title: string, description: string,
  options: CodexSelectionOption[], folder: boolean = false): Promise<number | null> {
  if (options.length === 0) { throw new Error('没有可选项目'); }
  const params = new CodexSelectionParams();
  params.title = title; params.description = description; params.options = options; params.folder = folder;
  let selectedIndex: number = -1;
  let closing: boolean = false;
  let content: ComponentContent<CodexSelectionParams> | null = null;
  let resolveDismissal: (value: number | null) => void = (_value: number | null): void => {};
  const disappeared = new Promise<number | null>((resolve): void => { resolveDismissal = resolve; });
  params.onFinish = (index: number): void => {
    if (closing || content === null) { return; }
    selectedIndex = index; closing = true;
    uiContext.getPromptAction().closeCustomDialog(content).catch((): void => {
      closing = false; selectedIndex = -1;
      showToastSafely('弹窗关闭失败，请重试');
    });
  };
  content = new ComponentContent(uiContext, wrapBuilder(codexSelectionBuilder), params);
  try {
    await uiContext.getPromptAction().openCustomDialog(content, {
      alignment: DialogAlignment.Center, autoCancel: true,
      onDidDisappear: (): void => { resolveDismissal(selectedIndex >= 0 ? selectedIndex : null); }
    });
    return await disappeared;
  } finally { content.dispose(); }
}
