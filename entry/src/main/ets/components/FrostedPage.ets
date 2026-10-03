import { LengthMetrics, window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  BlurStrategy,
  DividerShowType,
  HdsNavigation,
  HdsNavigationBackgroundStyle,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  ScrollEffectType,
  SystemMaterialParams,
  hdsMaterial,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { APP_HEADER_HEIGHT } from './AppHeader';

const TITLE_GLASS_TINT: string = '#26FFFFFF';
const TITLE_GLASS_BLUR_RADIUS: number = 24;
const TITLE_GLASS_FADE_HEIGHT: number = 32;

// 标题高度和系统安全区由导航容器统一避让，页面内容仅预留额外间距。
// 根滚动容器关闭裁剪后，可从固定标题及透明状态栏的背景后方经过。
@Component
export struct FrostedPage {
  @Prop pageBackgroundColor: string = '#FFFFFF';
  scrollers: Scroller[] = [];
  @BuilderParam headerBuilder: () => void = this.EmptyContent;
  @BuilderParam contentBuilder: () => void = this.EmptyContent;
  private hdsAvailable: boolean = canIUse('SystemCapability.UIDesign.HDSComponent.Core');
  private statusBarStyle: window.SystemBarStyle = { statusBarContentColor: '#172033' };
  private titleMaterial: SystemMaterialParams = {};

  aboutToAppear(): void {
    // 与底部胶囊采用相同的材质策略；旧系统不调用 API 23 的材质探测接口。
    if (!this.hdsAvailable || deviceInfo.sdkApiVersion < 23) {
      return;
    }
    let materialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.NONE;
    try {
      const supported: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
      if (supported.includes(hdsMaterial.MaterialType.IMMERSIVE)) {
        materialType = hdsMaterial.MaterialType.IMMERSIVE;
      } else if (supported.includes(hdsMaterial.MaterialType.ADAPTIVE)) {
        materialType = hdsMaterial.MaterialType.ADAPTIVE;
      }
    } catch (e) {
      // 无沉浸材质时仍保留渐变模糊，避免退回不透明的白色标题块。
    }
    this.titleMaterial = {
      materialType: materialType,
      materialLevel: materialType === hdsMaterial.MaterialType.IMMERSIVE ?
        hdsMaterial.MaterialLevel.EXQUISITE : hdsMaterial.MaterialLevel.ADAPTIVE
    };
  }

  private titleOptions(): HdsNavigationTitleBarOptions {
    let scrollBackground: HdsNavigationBackgroundStyle = {
      backgroundColor: TITLE_GLASS_TINT,
      maskExtraHeight: TITLE_GLASS_FADE_HEIGHT
    };
    let scrollEffect: ScrollEffectType = ScrollEffectType.GRADIENT_BLUR;
    if (deviceInfo.sdkApiVersion >= 23) {
      scrollBackground.blurRadius = TITLE_GLASS_BLUR_RADIUS;
      if (this.titleMaterial.materialType === hdsMaterial.MaterialType.IMMERSIVE) {
        scrollEffect = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
      }
    }
    let style: TitleBarStyleOptions = {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: scrollEffect,
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(8)
      },
      originalStyle: { backgroundStyle: { backgroundColor: Color.Transparent } },
      // 以模糊和系统材质保证标题可读，保留下方内容的颜色与轮廓。
      scrollEffectStyle: { backgroundStyle: scrollBackground },
      blurStrategy: BlurStrategy.ADAPTIVE
    };
    if (deviceInfo.sdkApiVersion >= 23) {
      style.thermoCtrl = true;
      style.systemMaterialEffect = this.titleMaterial;
    }
    return {
      padding: { start: LengthMetrics.vp(0), end: LengthMetrics.vp(0) },
      enableComponentSafeArea: true,
      style: style,
      content: {
        stackBuilder: (): void => { this.headerBuilder(); },
        divider: { showType: DividerShowType.OFF }
      }
    };
  }

  @Builder EmptyContent() {
  }

  build() {
    if (this.hdsAvailable) {
      HdsNavigation() {
        Column() {
          this.contentBuilder()
        }
        .width('100%')
        .height('100%')
        // 保留标题组件安全区，不再手工抵消标题高度，避免首屏内容覆盖标题。
        .clip(false)
      }
      .titleMode(HdsNavigationTitleMode.MINI)
      .titleBar(this.titleOptions())
      .hideBackButton(true)
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .bindToScrollable(this.scrollers)
      .systemBarStyle(this.statusBarStyle, this.statusBarStyle)
      // 只拓展顶部背景，标题文字仍位于系统安全区内；底部与键盘避让保持原布局。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBackgroundColor)
      .clip(true)
    } else {
      // 无 HDS 能力的设备使用 ArkUI 的固定标题、安全区避让及基础背景模糊。
      Navigation() {
        this.contentBuilder()
      }
      .title({ builder: (): void => { this.headerBuilder(); }, height: APP_HEADER_HEIGHT }, {
        barStyle: BarStyle.STANDARD,
        backgroundColor: TITLE_GLASS_TINT,
        backgroundBlurStyle: BlurStyle.COMPONENT_THIN
      })
      .hideBackButton(true)
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .systemBarStyle(this.statusBarStyle)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBackgroundColor)
      .clip(true)
    }
  }
}
