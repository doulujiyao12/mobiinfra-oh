import { AgentExecutionController } from '../utils/AgentExecutionController';
import { AiGeneratedBadge } from '../components/AiGeneratedBadge';

// 后台浮窗页面：展示 AppStorage.floatText 中的实时模型输出/Agent 状态，
// 并提供暂停/继续、终止入口通知 AgentExecutionController 控制当前任务。
// 注意：全屏边缘流光由 pages/EdgeFlowWindow 承载，本页面只保留小型控制面板。
@Entry
@Component
struct FloatWindow {
  @StorageLink('floatText') @Watch('onFloatTextChanged') floatText: string = 'AI Agent 运行中...'
  @StorageLink('agentPauseRequested') pauseRequested: boolean = false
  @StorageLink('agentFloatPanelExpanded') panelExpanded: boolean = false
  // 截图隐藏状态由 EntryAbility 切换；页面保留透明根节点，只停止渲染可见控制面板。
  @StorageLink('agentCaptureOverlayHidden') captureOverlayHidden: boolean = false
  private textScroller: Scroller = new Scroller()
  private autoScrollText: boolean = true
  private lastToggleAt: number = 0

  private statusLabel(): string {
    return this.pauseRequested ? '暂停' : '执行';
  }

  private togglePanel(): void {
    let now = Date.now();
    if (now - this.lastToggleAt < 180) {
      return;
    }
    this.lastToggleAt = now;
    this.autoScrollText = true;
    AgentExecutionController.toggleFloatPanelExpanded();
    this.scrollTextToLatest();
  }

  private onFloatTextChanged(): void {
    if (this.panelExpanded && this.autoScrollText) {
      this.scrollTextToLatest();
    }
  }

  private scrollTextToLatest(): void {
    setTimeout(() => {
      this.textScroller.scrollEdge(Edge.Bottom);
    }, 0);
  }

  private touchScreenX(event: TouchEvent): number {
    return event.touches.length > 0 ? event.touches[0].screenX : 0;
  }

  private touchScreenY(event: TouchEvent): number {
    return event.touches.length > 0 ? event.touches[0].screenY : 0;
  }

  private handleMoveTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      AgentExecutionController.startFloatPanelMove(this.touchScreenX(event), this.touchScreenY(event));
      return;
    }
    if (event.type === TouchType.Move) {
      AgentExecutionController.moveFloatPanel(this.touchScreenX(event), this.touchScreenY(event));
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      AgentExecutionController.endFloatPanelMove();
    }
  }

  build() {
    Stack({ alignContent: Alignment.End }) {
      // captureOverlayHidden=true 时不要销毁窗口或页面，只让内容为空，避免窗口重建影响前台输入法。
      if (!this.captureOverlayHidden && this.panelExpanded) {
        Row() {
          Column() {
            Row() {
              Text(this.statusLabel())
                .layoutWeight(1)
                .fontSize(9)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.pauseRequested ? '#FDE68A' : '#86EFAC')
                .textAlign(TextAlign.Start)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              AiGeneratedBadge({ compact: true, tone: 'overlay' })
            }
              .width('100%')
              .height(16)
              .alignItems(VerticalAlign.Center)

            Scroll(this.textScroller) {
              Text(this.floatText)
                .width('100%')
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor('#F0F8FAFC')
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .height(30)
            .scrollable(ScrollDirection.Vertical)
            .scrollBar(BarState.Auto)
            .onClick(() => {
              this.togglePanel();
            })
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.autoScrollText = false;
              }
              this.handleMoveTouch(event);
            })
          }
          .layoutWeight(1)
          .height(46)
          .constraintSize({ minWidth: 96 })
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 9, right: 8 })
          .backgroundColor('#24101827')
          .borderRadius(16)
          .onClick(() => {
            this.togglePanel();
          })
          .onTouch((event: TouchEvent) => {
            this.handleMoveTouch(event);
          })

          Column() {
            Text(this.pauseRequested ? '▶' : 'Ⅱ')
              .height(17)
              .fontSize(this.pauseRequested ? 12 : 11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F8FAFC')
              .textAlign(TextAlign.Center)

            Text(this.pauseRequested ? '继续' : '暂停')
              .height(14)
              .fontSize(8)
              .fontWeight(FontWeight.Medium)
              .fontColor('#DDE5E7EB')
              .textAlign(TextAlign.Center)
          }
          .width(50)
          .height(46)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.pauseRequested ? '#704B8BFF' : '#4A475569')
          .borderRadius(16)
          .margin({ left: 6 })
          .hitTestBehavior(HitTestMode.Default)
          .onClick(() => {
            AgentExecutionController.togglePause();
          })

          Column() {
            Text('×')
              .height(17)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F8FAFC')
              .textAlign(TextAlign.Center)

            Text('终止')
              .height(14)
              .fontSize(8)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FEE2E2')
              .textAlign(TextAlign.Center)
          }
          .width(52)
          .height(46)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor('#666B2530')
          .borderRadius(16)
          .margin({ left: 6 })
          .hitTestBehavior(HitTestMode.Default)
          .onClick(() => {
            AgentExecutionController.requestCancellation();
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.End)
        .padding({ left: 12, right: 18, top: 10, bottom: 10 })
        .backgroundColor('#00000000')
        .shadow({ radius: 10, color: '#18000000', offsetX: 0, offsetY: 2 })
      } else if (!this.captureOverlayHidden) {
        Row() {
          Text(this.statusLabel())
            .width(36)
            .height(42)
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pauseRequested ? '#FDE68A' : '#86EFAC')
            .textAlign(TextAlign.Center)

          Text('‹')
            .width(14)
            .height(42)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F8FAFC')
            .textAlign(TextAlign.Center)
        }
        .width(58)
        .height(42)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .backgroundColor('#4A475569')
        .borderRadius(16)
        .shadow({ radius: 10, color: '#18000000', offsetX: 0, offsetY: 2 })
        .onClick(() => {
          this.togglePanel();
        })
        .onTouch((event: TouchEvent) => {
          this.handleMoveTouch(event);
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000000')
  }
}
