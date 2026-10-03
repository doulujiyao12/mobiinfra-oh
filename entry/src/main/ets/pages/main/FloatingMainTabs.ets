import { deviceInfo } from '@kit.BasicServicesKit';
import { HdsTabs, HdsTabsFloatingStyle, SystemMaterialParams, hdsMaterial } from '@kit.UIDesignKit';
import { MainTabIndex } from './MainTabConfig';

const TAB_BAR_HEIGHT: number = 64;
const TAB_BAR_BOTTOM_MARGIN: number = 12;
const TAB_BAR_SIDE_MARGIN: number = 20;
const TAB_BAR_LIGHT_COLOR: string = '#805B5CE2';
// 滚动内容和固定输入区都要避让胶囊，再留 12vp 的操作间隙。
export const FLOATING_MAIN_TABS_INSET: number = TAB_BAR_HEIGHT + TAB_BAR_BOTTOM_MARGIN + 12;

export function supportsFloatingMainTabs(): boolean {
  return deviceInfo.sdkApiVersion >= 23 && canIUse('SystemCapability.UIDesign.HDSComponent.Core');
}

@Component
export struct FloatingMainTabs {
  @Link selectedIndex: number;
  @Prop floating: boolean = false;
  @Prop pageBackgroundColor: string = '#FFFFFF';
  @BuilderParam contentBuilder: () => void = this.EmptyContent;
  @State private availableWidth: number = 360;
  private materialEffect: SystemMaterialParams = {};

  aboutToAppear(): void {
    // API 20–22 只走普通 Tabs，不能调用 API 23 的材质探测接口。
    if (!this.floating) {
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
      // 无可用系统材质时，仍使用半透明背景和基础模糊。
    }
    this.materialEffect = {
      materialType: materialType,
      // 支持沉浸材质时使用精细档增强原生交互光效，温控仍由 HdsTabs 管理。
      materialLevel: materialType === hdsMaterial.MaterialType.IMMERSIVE ?
        hdsMaterial.MaterialLevel.EXQUISITE : hdsMaterial.MaterialLevel.ADAPTIVE
    };
  }

  private floatingStyle(): HdsTabsFloatingStyle {
    const width: number = Math.max(0, this.availableWidth - TAB_BAR_SIDE_MARGIN * 2);
    return {
      barWidth: { smallWidth: width, mediumWidth: Math.min(width, 480), largeWidth: Math.min(width, 560) },
      barSideMargin: TAB_BAR_SIDE_MARGIN,
      barBottomMargin: TAB_BAR_BOTTOM_MARGIN,
      gradientMask: {
        maskColor: this.selectedIndex === MainTabIndex.Chat ?
          '#66' + this.pageBackgroundColor.substring(1) : '#66FFFFFF',
        maskHeight: FLOATING_MAIN_TABS_INSET
      },
      systemMaterialEffect: this.materialEffect,
      // 原生 BottomTabBarStyle 的点击光效使用此颜色。
      lightColor: TAB_BAR_LIGHT_COLOR,
      thermoCtrl: true
    };
  }

  @Builder EmptyContent() {
  }

  build() {
    if (this.floating) {
      HdsTabs({ barPosition: BarPosition.End, index: this.selectedIndex }) {
        this.contentBuilder()
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barHeight(TAB_BAR_HEIGHT)
      .barOverlap(true)
      .barBackgroundColor('#B3FFFFFF')
      .barBackgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
      .barFloatingStyle(this.floatingStyle())
      .onChange((index: number) => { this.selectedIndex = index; })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const width: number = parseFloat(newArea.width.toString());
        if (width > 0 && Math.abs(width - this.availableWidth) >= 1) {
          this.availableWidth = width;
        }
      })
      .width('100%')
      .height('100%')
      // 顶部允许页签内的导航材质延伸到状态栏；保留 Tabs 原有的底部拓展。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .backgroundColor(this.pageBackgroundColor)
    } else {
      Tabs({ barPosition: BarPosition.End, index: this.selectedIndex }) {
        this.contentBuilder()
      }
      .barMode(BarMode.Fixed)
      .barHeight(TAB_BAR_HEIGHT)
      .barBackgroundColor(this.selectedIndex === MainTabIndex.Chat ? this.pageBackgroundColor : '#FFFFFF')
      .onChange((index: number) => { this.selectedIndex = index; })
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .backgroundColor(this.pageBackgroundColor)
    }
  }
}
