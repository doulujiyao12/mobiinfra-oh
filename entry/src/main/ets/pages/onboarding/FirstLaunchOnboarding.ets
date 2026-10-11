import { AppTheme } from '../../utils/AppTheme';
import {
  FIRST_LAUNCH_ONBOARDING_SLIDE_AGENT,
  FIRST_LAUNCH_ONBOARDING_SLIDE_AVATAR,
  FIRST_LAUNCH_ONBOARDING_SLIDE_DATA_HOME,
  FIRST_LAUNCH_ONBOARDING_SLIDES,
  FIRST_LAUNCH_USAGE_GUIDE_ITEMS,
  FirstLaunchOnboardingSlideKind,
  FirstLaunchOnboardingSlide,
  FirstLaunchUsageGuideItem,
  clampFirstLaunchOnboardingIndex,
  firstLaunchOnboardingButtonText,
  isFirstLaunchOnboardingLastPage
} from './OnboardingTypes';

const ONBOARDING_PAGE_BACKGROUND: string = '#F4F8FF';
const ONBOARDING_TEXT_PRIMARY: string = '#101B3D';
const ONBOARDING_TEXT_SECONDARY: string = '#768197';
const ONBOARDING_CARD_BACKGROUND: string = '#FFFFFFFF';
const ONBOARDING_DOT_INACTIVE: string = '#DCE3F0';

/**
 * 首次安装核心能力与使用路径引导页。
 *
 * 组件只负责展示产品介绍、使用配置清单和完成回调，不读写持久化状态。
 * 完成状态由 Index 统一写入，避免引导页组件和应用 Shell 形成隐式耦合。
 */
@Component
export struct FirstLaunchOnboarding {
  onComplete: () => void = () => {};
  @State private currentIndex: number = 0;

  private currentSlide(): FirstLaunchOnboardingSlide {
    return FIRST_LAUNCH_ONBOARDING_SLIDES[clampFirstLaunchOnboardingIndex(this.currentIndex)];
  }

  private handlePrimaryAction(): void {
    if (isFirstLaunchOnboardingLastPage(this.currentIndex)) {
      this.onComplete();
      return;
    }
    this.currentIndex = clampFirstLaunchOnboardingIndex(this.currentIndex + 1);
  }

  @Builder
  private SlideHero(slide: FirstLaunchOnboardingSlide) {
    Stack() {
      Column() {
        Row()
          .width(148)
          .height(148)
          .borderRadius(74)
          .backgroundColor(AppTheme.background(slide.softBackgroundColor))
          .opacity(0.78)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)

      if (slide.id === FIRST_LAUNCH_ONBOARDING_SLIDE_DATA_HOME) {
        Image($r('app.media.onboarding_data_home'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
      } else if (slide.id === FIRST_LAUNCH_ONBOARDING_SLIDE_AVATAR) {
        Image($r('app.media.onboarding_avatar'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
      } else if (slide.id === FIRST_LAUNCH_ONBOARDING_SLIDE_AGENT) {
        Image($r('app.media.onboarding_agent'))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
      }
    }
    .width('100%')
    .aspectRatio(1)
    .padding(10)
    .backgroundColor(AppTheme.background(ONBOARDING_CARD_BACKGROUND))
    .borderRadius(28)
  }

  @Builder
  private PreviewSlidePage(slide: FirstLaunchOnboardingSlide) {
    Column() {
      this.SlideHero(slide)

      Text(slide.title)
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppTheme.text(ONBOARDING_TEXT_PRIMARY))
        .textAlign(TextAlign.Center)
        .margin({ top: 30 })

      Text(slide.description)
        .fontSize(18)
        .lineHeight(28)
        .fontColor(AppTheme.text(ONBOARDING_TEXT_SECONDARY))
        .textAlign(TextAlign.Center)
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 14 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 30, right: 30, top: 4, bottom: 4 })
  }

  @Builder
  private UsageGuideCard(item: FirstLaunchUsageGuideItem) {
    Row({ space: 14 }) {
      Row() {
        Text(item.iconText)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text(item.accentColor))
      }
      .width(42)
      .height(42)
      .borderRadius(14)
      .backgroundColor(AppTheme.background(item.softBackgroundColor))
      .justifyContent(FlexAlign.Center)

      Column({ space: 5 }) {
        Text(item.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text(ONBOARDING_TEXT_PRIMARY))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(item.entryLabel)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.text(item.accentColor))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(item.configLabel)
          .fontSize(14)
          .lineHeight(20)
          .fontColor(AppTheme.text(ONBOARDING_TEXT_SECONDARY))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(item.description)
          .fontSize(14)
          .lineHeight(20)
          .fontColor(AppTheme.text(ONBOARDING_TEXT_SECONDARY))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 15, bottom: 15 })
    .backgroundColor(AppTheme.background(ONBOARDING_CARD_BACKGROUND))
    .borderRadius(22)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private UsageGuidePage(slide: FirstLaunchOnboardingSlide) {
    Scroll() {
      Column() {
        Text(slide.title)
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text(ONBOARDING_TEXT_PRIMARY))
          .textAlign(TextAlign.Center)
          .width('100%')

        Text(slide.description)
          .fontSize(17)
          .lineHeight(25)
          .fontColor(AppTheme.text(ONBOARDING_TEXT_SECONDARY))
          .textAlign(TextAlign.Center)
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 12 })

        Column({ space: 12 }) {
          ForEach(FIRST_LAUNCH_USAGE_GUIDE_ITEMS, (item: FirstLaunchUsageGuideItem) => {
            this.UsageGuideCard(item)
          }, (item: FirstLaunchUsageGuideItem) => item.id)
        }
        .width('100%')
        .margin({ top: 22 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 8, bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  private SlidePage(slide: FirstLaunchOnboardingSlide) {
    if (slide.kind === FirstLaunchOnboardingSlideKind.UsageGuide) {
      this.UsageGuidePage(slide)
    } else {
      this.PreviewSlidePage(slide)
    }
  }

  @Builder
  private ProgressDot(index: number, slide: FirstLaunchOnboardingSlide) {
    Row()
      .width(this.currentIndex === index ? 24 : 8)
      .height(8)
      .borderRadius(4)
      .backgroundColor(AppTheme.background(this.currentIndex === index ? slide.accentColor : ONBOARDING_DOT_INACTIVE))
      .margin({ left: 4, right: 4 })
  }

  @Builder
  private ProgressDots() {
    Row() {
      ForEach(FIRST_LAUNCH_ONBOARDING_SLIDES, (slide: FirstLaunchOnboardingSlide, index: number) => {
        this.ProgressDot(index, slide)
      }, (slide: FirstLaunchOnboardingSlide) => slide.id)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        Text('ClawMate')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text(ONBOARDING_TEXT_PRIMARY))

        Blank()

        Text(String(this.currentIndex + 1) + '/' + String(FIRST_LAUNCH_ONBOARDING_SLIDES.length))
          .fontSize(15)
          .fontColor(AppTheme.text(ONBOARDING_TEXT_SECONDARY))
      }
      .width('100%')
      .padding({ left: 30, right: 30, top: 28 })

      Swiper() {
        ForEach(FIRST_LAUNCH_ONBOARDING_SLIDES, (slide: FirstLaunchOnboardingSlide) => {
          this.SlidePage(slide)
        }, (slide: FirstLaunchOnboardingSlide) => slide.id)
      }
      .index(this.currentIndex)
      .indicator(false)
      .loop(false)
      .onChange((index: number) => {
        this.currentIndex = clampFirstLaunchOnboardingIndex(index);
      })
      .layoutWeight(1)
      .width('100%')

      this.ProgressDots()

      Button(firstLaunchOnboardingButtonText(this.currentIndex))
        .width('84%')
        .height(56)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppTheme.text(Color.White))
        .backgroundColor(AppTheme.filledBackground(this.currentSlide().accentColor))
        .borderRadius(18)
        .margin({ top: 26, bottom: 34 })
        .onClick(() => {
          this.handlePrimaryAction();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.background(ONBOARDING_PAGE_BACKGROUND))
  }
}
