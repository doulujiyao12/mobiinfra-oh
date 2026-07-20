import {
  MarkdownBlock,
  MarkdownInline,
  MarkdownListItem,
  parseMarkdown
} from '../utils/markdown/MarkdownParser';

export type MarkdownViewVariant = 'chat_assistant' | 'chat_user' | 'collection_detail' | 'file_preview';

// MarkdownView 只渲染 parser 产出的安全结构化文本，不执行 HTML，也不加载远程资源。
// 页面仍保留原文数据，预览层仅负责把常见 Markdown 语法转成原生 ArkUI 排版。
@Component
export struct MarkdownView {
  @Prop text: string = '';
  @Prop variant: MarkdownViewVariant = 'file_preview';

  private blocks(): MarkdownBlock[] {
    return parseMarkdown(this.text);
  }

  private baseFontSize(): number {
    if (this.variant === 'chat_assistant' || this.variant === 'chat_user') {
      return 15;
    }
    if (this.variant === 'collection_detail') {
      return 13;
    }
    return 12;
  }

  private baseLineHeight(): number {
    if (this.variant === 'chat_assistant' || this.variant === 'chat_user') {
      return 22;
    }
    if (this.variant === 'collection_detail') {
      return 20;
    }
    return 18;
  }

  private primaryColor(): string {
    if (this.variant === 'chat_user') {
      return '#FFFFFF';
    }
    if (this.variant === 'collection_detail') {
      return '#4D5566';
    }
    return '#2F3645';
  }

  private secondaryColor(): string {
    if (this.variant === 'chat_user') {
      return '#E5E7EB';
    }
    if (this.variant === 'collection_detail') {
      return '#697386';
    }
    return '#6B7280';
  }

  private accentColor(): string {
    if (this.variant === 'chat_user') {
      return '#DBEAFE';
    }
    if (this.variant === 'collection_detail') {
      return '#8066FF';
    }
    return '#5968FF';
  }

  private codeBackgroundColor(): string {
    if (this.variant === 'chat_user') {
      return '#273449';
    }
    if (this.variant === 'collection_detail') {
      return '#EDF1F7';
    }
    return '#EEF2F7';
  }

  private quoteBorderColor(): string {
    if (this.variant === 'chat_user') {
      return '#93C5FD';
    }
    if (this.variant === 'collection_detail') {
      return '#B9A8FF';
    }
    return '#CBD5E1';
  }

  private blockTopMargin(index: number): number {
    return index === 0 ? 0 : 8;
  }

  private headingSize(level: number): number {
    if (level <= 1) {
      return this.baseFontSize() + 4;
    }
    if (level === 2) {
      return this.baseFontSize() + 3;
    }
    if (level === 3) {
      return this.baseFontSize() + 2;
    }
    return this.baseFontSize() + 1;
  }

  @Builder InlineText(inlines: MarkdownInline[], fallback: string, color: string, fontSize: number, lineHeight: number,
    bold: boolean = false) {
    if (inlines.length === 0) {
      Text(fallback)
        .fontSize(fontSize)
        .fontWeight(bold ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(color)
        .lineHeight(lineHeight)
        .copyOption(CopyOptions.LocalDevice)
        .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        .width('100%')
    } else {
      Text() {
        ForEach(inlines, (inline: MarkdownInline, index?: number) => {
          Span(inline.text)
            .fontSize(fontSize)
            .fontWeight(bold || inline.type === 'strong' ? FontWeight.Bold : FontWeight.Regular)
            .fontColor(inline.type === 'link' ? this.accentColor() : color)
            .fontFamily(inline.type === 'code' ? 'monospace' : 'HarmonyOS Sans')
        }, (inline: MarkdownInline, index?: number) => String(index === undefined ? 0 : index) + inline.type + inline.text)
      }
      .fontSize(fontSize)
      .fontColor(color)
      .lineHeight(lineHeight)
      .copyOption(CopyOptions.LocalDevice)
      .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
      .width('100%')
    }
  }

  @Builder HeadingBlock(block: MarkdownBlock, index: number) {
    Column() {
      this.InlineText(block.inlines, block.text, this.primaryColor(), this.headingSize(block.level),
        this.headingSize(block.level) + 6, true)
    }
    .width('100%')
    .margin({ top: this.blockTopMargin(index) })
  }

  @Builder ParagraphBlock(block: MarkdownBlock, index: number) {
    Column() {
      this.InlineText(block.inlines, block.text, this.primaryColor(), this.baseFontSize(), this.baseLineHeight())
    }
    .width('100%')
    .margin({ top: this.blockTopMargin(index) })
  }

  @Builder QuoteBlock(block: MarkdownBlock, index: number) {
    Column() {
      this.InlineText(block.inlines, block.text, this.secondaryColor(), this.baseFontSize(), this.baseLineHeight())
    }
    .width('100%')
    // 引用块处在内容自适应容器中，不能用子组件 height('100%')，否则会按外层可用高度撑出大段空白。
    .padding({ left: 10 })
    .border({
      width: { left: 3, right: 0, top: 0, bottom: 0 },
      color: this.quoteBorderColor()
    })
    .margin({ top: this.blockTopMargin(index) })
  }

  @Builder ListBlock(block: MarkdownBlock, index: number) {
    Column() {
      ForEach(block.items, (item: MarkdownListItem, itemIndex?: number) => {
        Row() {
          Text(block.ordered && item.marker.length > 0 ? item.marker : '•')
            .fontSize(this.baseFontSize())
            .fontColor(this.secondaryColor())
            .width(22)
            .lineHeight(this.baseLineHeight())
          Column() {
            this.InlineText(item.inlines, item.text, this.primaryColor(), this.baseFontSize(), this.baseLineHeight())
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ top: itemIndex === 0 || itemIndex === undefined ? 0 : 5 })
      }, (item: MarkdownListItem, itemIndex?: number) => String(itemIndex === undefined ? 0 : itemIndex) + item.text)
    }
    .width('100%')
    .margin({ top: this.blockTopMargin(index) })
  }

  @Builder CodeBlock(block: MarkdownBlock, index: number) {
    Column() {
      if (block.language.length > 0) {
        Text(block.language)
          .fontSize(10)
          .fontColor(this.secondaryColor())
          .width('100%')
          .margin({ bottom: 6 })
      }
      Text(block.text.length > 0 ? block.text : ' ')
        .fontSize(this.baseFontSize() - 1)
        .fontFamily('monospace')
        .fontColor(this.primaryColor())
        .lineHeight(this.baseLineHeight())
        .copyOption(CopyOptions.LocalDevice)
        .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        .width('100%')
    }
    .width('100%')
    .padding(10)
    .backgroundColor(this.codeBackgroundColor())
    .borderRadius(8)
    .margin({ top: this.blockTopMargin(index) })
  }

  @Builder DividerBlock(index: number) {
    Column()
      .width('100%')
      .height(1)
      .backgroundColor(this.variant === 'chat_user' ? '#4B5563' : '#E5E7EB')
      .margin({ top: this.blockTopMargin(index) + 3, bottom: 3 })
  }

  @Builder TableRow(cells: string[], isHeader: boolean, keyPrefix: string) {
    Row() {
      ForEach(cells, (cell: string, index?: number) => {
        Text(cell.length > 0 ? cell : ' ')
          .fontSize(this.baseFontSize() - 1)
          .fontWeight(isHeader ? FontWeight.Bold : FontWeight.Regular)
          .fontColor(isHeader ? this.primaryColor() : this.secondaryColor())
          .lineHeight(this.baseLineHeight())
          .copyOption(CopyOptions.LocalDevice)
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
          .layoutWeight(1)
          .padding({ left: 6, right: 6, top: 5, bottom: 5 })
      }, (cell: string, index?: number) => keyPrefix + '_' + String(index === undefined ? 0 : index) + cell)
    }
    .width('100%')
    .backgroundColor(isHeader ? this.codeBackgroundColor() : '#00000000')
  }

  @Builder TableBlock(block: MarkdownBlock, index: number) {
    Column() {
      this.TableRow(block.headers, true, 'header')
      ForEach(block.rows, (row: string[], rowIndex?: number) => {
        this.TableRow(row, false, 'row_' + String(rowIndex === undefined ? 0 : rowIndex))
      }, (row: string[], rowIndex?: number) => String(rowIndex === undefined ? 0 : rowIndex) + row.join('|'))
    }
    .width('100%')
    .border({ width: 1, color: this.variant === 'chat_user' ? '#4B5563' : '#E5E7EB' })
    .borderRadius(8)
    .clip(true)
    .margin({ top: this.blockTopMargin(index) })
  }

  @Builder MarkdownBlockView(block: MarkdownBlock, index: number) {
    if (block.type === 'heading') {
      this.HeadingBlock(block, index)
    } else if (block.type === 'list') {
      this.ListBlock(block, index)
    } else if (block.type === 'quote') {
      this.QuoteBlock(block, index)
    } else if (block.type === 'code') {
      this.CodeBlock(block, index)
    } else if (block.type === 'table') {
      this.TableBlock(block, index)
    } else if (block.type === 'divider') {
      this.DividerBlock(index)
    } else {
      this.ParagraphBlock(block, index)
    }
  }

  build() {
    Column() {
      ForEach(this.blocks(), (block: MarkdownBlock, index?: number) => {
        this.MarkdownBlockView(block, index === undefined ? 0 : index)
      }, (block: MarkdownBlock, index?: number) => String(index === undefined ? 0 : index) + block.type + block.text)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
