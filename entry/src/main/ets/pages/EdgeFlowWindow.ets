import { AppTheme } from '../utils/AppTheme';
import { hdsEffect } from '@kit.UIDesignKit';
import {
  buildTransparentEdgeFlowEffect,
  createEdgeFlowShaderController
} from '../components/HdsVisualComponent';

const EDGE_FLOW_SCALE_X = 1.34;
const EDGE_FLOW_SCALE_Y = 1.16;
const EDGE_FLOW_OPACITY = 0.85;

// Agent 执行期间的全屏透明流光浮窗。
// 使用不带背景蒙版的 DUAL_EDGE_FLOW_LIGHT，只绘制边缘光效，中心区域保持透明。
@Entry
@Component
struct EdgeFlowWindow {
  // 截图期间保留透明浮窗本身，只移除 HDS 流光效果，避免窗口重建影响前台焦点和键盘。
  @StorageLink('agentCaptureOverlayHidden') captureOverlayHidden: boolean = false
  @State shaderController: hdsEffect.ShaderEffectController = createEdgeFlowShaderController()

  build() {
    Stack() {
      // 使用条件渲染从合成树移除 visualEffect；仅暂停动画仍会保留最后一帧流光。
      if (!this.captureOverlayHidden) {
        // 添加Column作为中间层，因为Blank只能作为Row/Column/Flex的子组件
        Column() {
          // 空内容承载 visualEffect，避免 HdsVisualComponent 的背景蒙版遮挡前台应用。
          Blank()
            .width('100%')
            .height('100%')
            .visualEffect(buildTransparentEdgeFlowEffect(this.shaderController))
            .opacity(EDGE_FLOW_OPACITY)
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')
        .clip(true)
        // HDS 双边流光会从承载组件边界向屏幕内扩散；放大承载层并裁剪，
        // 等价于把真实发光边界推到屏幕外，只留下贴近屏幕边缘的余光。
        .scale({
          x: EDGE_FLOW_SCALE_X,
          y: EDGE_FLOW_SCALE_Y,
          centerX: '50%',
          centerY: '50%'
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.background('#00000000'))
    .hitTestBehavior(HitTestMode.None)
  }
}
