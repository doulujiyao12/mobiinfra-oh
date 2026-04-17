import native from 'libentry.so';
import { router } from '@kit.ArkUI';

@Entry
@Component
struct LogView {
  @State logs: string = '(no logs yet — tap Refresh)'
  @State autoRefresh: boolean = true
  @State autoScroll: boolean = true
  private timerId: number = -1
  private scroller: Scroller = new Scroller()

  aboutToAppear() {
    this.reload()
    this.startTimer()
  }

  aboutToDisappear() {
    this.stopTimer()
  }

  startTimer() {
    if (this.timerId !== -1) return
    this.timerId = setInterval(() => {
      if (this.autoRefresh) this.reload()
    }, 2000)
  }

  stopTimer() {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
  }

  reload() {
    try {
      const text = native.getLogs() || '(empty)'
      this.logs = text
      if (this.autoScroll) {
        this.scroller.scrollEdge(Edge.Bottom)
      }
    } catch (e) {
      this.logs = 'getLogs error: ' + JSON.stringify(e)
    }
  }

  build() {
    Column() {
      // Title bar
      Row() {
        Button('Back')
          .fontSize(14).height(36)
          .onClick(() => router.back())
        Blank()
        Text('Runtime Logs')
          .fontSize(18).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.autoRefresh ? 'Auto ON' : 'Auto OFF')
          .fontSize(12).height(36)
          .backgroundColor(this.autoRefresh ? '#4CAF50' : '#888888')
          .onClick(() => { this.autoRefresh = !this.autoRefresh })
      }
      .width('100%').padding(10)

      // Action bar
      Row() {
        Button('Refresh').fontSize(14).height(36).flexGrow(1)
          .onClick(() => this.reload())
        Button(this.autoScroll ? 'Scroll↓ ON' : 'Scroll↓ OFF')
          .fontSize(12).height(36).flexGrow(1).margin({ left: 8 })
          .backgroundColor(this.autoScroll ? '#2196F3' : '#888888')
          .onClick(() => {
            this.autoScroll = !this.autoScroll
            if (this.autoScroll) this.scroller.scrollEdge(Edge.Bottom)
          })
        Button('Clear').fontSize(14).height(36).flexGrow(1).margin({ left: 8 })
          .backgroundColor('#F44336')
          .onClick(() => {
            try {
              native.clearLogs()
              this.logs = '(cleared)'
            } catch (e) {
              this.logs = 'clearLogs error: ' + JSON.stringify(e)
            }
          })
      }
      .width('95%').margin({ bottom: 8 })

      // Log area — dark terminal style
      Scroll(this.scroller) {
        Text(this.logs)
          .fontSize(11)
          .fontColor('#E0E0E0')
          .fontFamily('monospace')
          .textAlign(TextAlign.Start)
          .width('100%')
          .padding(8)
      }
      .scrollable(ScrollDirection.Vertical)
      .backgroundColor('#0D1117')
      .borderRadius(8)
      .width('95%')
      .flexGrow(1)
      .margin({ bottom: 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F0F0F0')
  }
}
