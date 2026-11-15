import { unifiedDataChannel } from '@kit.ArkData';
import { HomeCategoryIcon } from '../../components/HomeCategoryIcon';
import { HomeNote, homeIdeaArt } from './HomeSecretary';
import { homeTaskSuggestionCategoryLabel } from './HomeTaskSuggestion';

@Component
export struct SecretaryNoteCard {
  @Require @Prop note: HomeNote = { key: '', title: '', body: '', meta: '', completed: false, canDelegate: false };
  @Prop status: string = '';
  onOpen: () => void = (): void => {};
  onLift: () => void = (): void => {};
  onRelease: () => void = (): void => {};

  private lift(event: DragEvent): DragItemInfo {
    const marker = new unifiedDataChannel.PlainText();
    marker.textContent = 'clawmate-note';
    const data = new unifiedDataChannel.UnifiedData(marker);
    const properties = data.properties;
    properties.shareOptions = unifiedDataChannel.ShareOptions.IN_APP;
    data.properties = properties;
    event.setData(data);
    this.onLift();
    return { extraInfo: 'clawmate-note' };
  }

  private caption(): string {
    if (this.status || this.note.completed) { return this.status || '已完成'; }
    if (this.note.meta) { return this.note.meta; }
    return this.note.suggestion ? homeTaskSuggestionCategoryLabel(this.note.suggestion.category) :
      (this.note.reminder?.tag || '');
  }

  @Builder Face() {
    Column() {
      if (this.note.suggestion) {
        Row() {
          HomeCategoryIcon({ iconIndex: homeIdeaArt(this.note.suggestion.category), iconSize: 34 })
          Blank()
          SymbolGlyph($r('sys.symbol.paperclip')).fontSize(16).fontColor([$r('app.color.ui_accent_purple')])
            .rotate({ angle: -18 })
        }.width('100%').accessibilityLevel('no-hide-descendants').hitTestBehavior(HitTestMode.None)
      } else {
        SymbolGlyph($r('sys.symbol.bookmark_fill')).fontSize(23).fontColor([$r('app.color.ui_accent_gold')])
          .accessibilityLevel('no')
      }
      Blank().layoutWeight(1)
      Text(this.note.title).fontSize(17).fontWeight(FontWeight.Medium).lineHeight(23).maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.ui_text_primary'))
      if (this.caption()) {
        Text(this.caption()).fontSize(12).lineHeight(16).maxLines(1).margin({ top: 6 })
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.ui_text_secondary'))
      }
    }.alignItems(HorizontalAlign.Start).width('100%').height('100%')
      .padding({ left: 15, right: this.note.suggestion ? 13 : 19, top: 12, bottom: 14 })
      .linearGradient({ angle: 145, colors: [
        [this.note.suggestion ? $r('app.color.ui_soft_purple') : $r('app.color.ui_soft_gold'), 0],
        [$r('app.color.ui_surface'), 0.46], [$r('app.color.ui_surface'), 1]
      ] })
      .borderRadius({ topLeft: 6, topRight: 14, bottomLeft: 14, bottomRight: 6 })
      .border({ width: 0.5, color: $r('app.color.ui_border') })
      .shadow({ radius: 5, color: '#0B20283A', offsetY: 3 })
  }

  @Builder Paper() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      this.Face()
      if (!this.note.suggestion) {
        // Two faces of the turned corner: paper on top, page visible underneath.
        Stack() {
          Path().commands('M 0 14 L 14 0 L 14 14 Z').width(14).height(14).fill($r('app.color.ui_page_white'))
          Path().commands('M 0 14 L 0 4 Q 0 0 4 0 L 14 0 Z').width(14).height(14).fill($r('app.color.ui_soft_gold'))
            .stroke($r('app.color.ui_border')).strokeWidth(0.5)
        }.width(14).height(14).accessibilityLevel('no-hide-descendants').hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height('100%')
  }

  build() {
    if (this.note.canDelegate && !this.note.completed) {
      Column() { this.Paper() }
        .width('100%').height('100%').draggable(true)
        .onDragStart((event: DragEvent): DragItemInfo => this.lift(event))
        .onDragEnd((): void => { this.onRelease(); })
        .accessibilityGroup(true).accessibilityText((this.note.suggestion ? '猜你喜欢，' : '为你提醒，') +
          this.note.title + '，' + this.caption() + '，轻点查看或长按交办')
        .onClick((): void => { this.onOpen(); })
    } else {
      Column() { this.Paper() }
        .width('100%').height('100%').accessibilityGroup(true).accessibilityText(this.note.title + '，查看详情')
        .onClick((): void => { this.onOpen(); })
    }
  }
}
