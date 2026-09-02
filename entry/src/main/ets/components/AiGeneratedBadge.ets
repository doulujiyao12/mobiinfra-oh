import { AI_GENERATED_LABEL_TEXT } from '../utils/AiGeneratedContent';

export type AiGeneratedBadgeTone = 'surface' | 'overlay';

@Component
export struct AiGeneratedBadge {
  @Prop compact: boolean = false;
  @Prop tone: AiGeneratedBadgeTone = 'surface';

  private resolveBadgeFontSize(): number {
    return this.compact ? 10 : 11;
  }

  private resolveHorizontalPadding(): number {
    return this.compact ? 5 : 7;
  }

  private resolveVerticalPadding(): number {
    return this.compact ? 2 : 3;
  }

  private resolveBadgeTextColor(): string {
    return this.tone === 'overlay' ? '#FFFFFF' : '#5B50C7';
  }

  private resolveBadgeBackgroundColor(): string {
    return this.tone === 'overlay' ? '#B3000000' : '#EEEAFE';
  }

  build() {
    Text(AI_GENERATED_LABEL_TEXT)
      .fontSize(this.resolveBadgeFontSize())
      .fontWeight(FontWeight.Bold)
      .fontColor(this.resolveBadgeTextColor())
      .maxLines(1)
      .padding({
        left: this.resolveHorizontalPadding(),
        right: this.resolveHorizontalPadding(),
        top: this.resolveVerticalPadding(),
        bottom: this.resolveVerticalPadding()
      })
      .backgroundColor(this.resolveBadgeBackgroundColor())
      .borderRadius(7)
  }
}
