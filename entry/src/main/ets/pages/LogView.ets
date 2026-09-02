import native from 'libentry.so';
import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { AppLogger } from '../utils/AppLogger';
import { AiGeneratedBadge } from '../components/AiGeneratedBadge';
import { ensureAiGeneratedTextNotice } from '../utils/AiGeneratedContent';

// 运行日志页：可在原生日志 ring buffer、云端 Agent 日志和图库分析日志之间切换，
// 用于调试模型加载、推理、HDC 通信、云端 Decider 输入输出和图库入库状态。
@Entry
@Component
struct LogView {
  @State logs: string = '(no logs yet - tap Refresh)'
  @State logSource: number = 1
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

  private containsAiGeneratedContent(): boolean {
    return this.logSource === 1 || this.logSource === 2
  }

  private copyText(): string {
    return this.containsAiGeneratedContent() ? ensureAiGeneratedTextNotice(this.logs) : this.logs
  }

  reload() {
    // Native 日志来自 libentry.so 的 getLogs；Cloud/Gallery 日志来自 AppStorage。
    try {
      if (this.logSource === 0) {
        const text: string = native.getLogs() || '(empty native runtime logs)'
        this.logs = text
      } else if (this.logSource === 1) {
        const text = AppStorage.get('cloudAgentLogs') as string
        this.logs = text && text.length > 0 ? text : '(empty cloud agent logs)'
      } else {
        const text = AppStorage.get('galleryLogs') as string
        this.logs = text && text.length > 0 ? text : '(empty gallery logs)'
      }
      if (this.autoScroll) {
        this.scroller.scrollEdge(Edge.Bottom)
      }
    } catch (e) {
      AppLogger.errorCause('LogView', 'getLogs failed source=' + String(this.logSource), e as Error)
      this.logs = 'getLogs error: ' + JSON.stringify(e)
    }
  }

  build() {
    Column() {
      Row() {
        Button('Back')
          .fontSize(14).height(36)
          .onClick(() => router.back())
        Blank()
        Text(this.logTitle())
          .fontSize(18).fontWeight(FontWeight.Bold)
        if (this.containsAiGeneratedContent()) {
          AiGeneratedBadge({ compact: true })
            .margin({ left: 8 })
        }
        Blank()
        Button(this.autoRefresh ? 'Auto ON' : 'Auto OFF')
          .fontSize(12).height(36)
          .backgroundColor(this.autoRefresh ? '#4CAF50' : '#888888')
          .onClick(() => { this.autoRefresh = !this.autoRefresh })
      }
      .width('100%').padding(10)

      Row() {
        Button('Native')
          .fontSize(12).height(34).flexGrow(1)
          .backgroundColor(this.logSource === 0 ? '#5B68FF' : '#888888')
          .onClick(() => {
            this.logSource = 0
            this.reload()
          })
        Button('Cloud')
          .fontSize(12).height(34).flexGrow(1).margin({ left: 8 })
          .backgroundColor(this.logSource === 1 ? '#5B68FF' : '#888888')
          .onClick(() => {
            this.logSource = 1
            this.reload()
          })
        Button('Gallery')
          .fontSize(12).height(34).flexGrow(1).margin({ left: 8 })
          .backgroundColor(this.logSource === 2 ? '#5B68FF' : '#888888')
          .onClick(() => {
            this.logSource = 2
            this.reload()
          })
      }
      .width('95%').margin({ bottom: 8 })

      Row() {
        Button('Refresh').fontSize(14).height(36).flexGrow(1)
          .onClick(() => this.reload())
        Button(this.autoScroll ? 'Scroll ON' : 'Scroll OFF')
          .fontSize(12).height(36).flexGrow(1).margin({ left: 8 })
          .backgroundColor(this.autoScroll ? '#2196F3' : '#888888')
          .onClick(() => {
            this.autoScroll = !this.autoScroll
            if (this.autoScroll) this.scroller.scrollEdge(Edge.Bottom)
          })
        Button('Copy').fontSize(14).height(36).flexGrow(1).margin({ left: 8 })
          .backgroundColor('#FF9800')
          .onClick(() => {
            const pb = pasteboard.getSystemPasteboard()
            pb.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.copyText()))
              .then(() => { promptAction.showToast({ message: 'Copied!', duration: 1500 }) })
              .catch((e: Error) => {
                AppLogger.warnCause('LogView', 'copy logs failed', e)
                promptAction.showToast({ message: 'Copy failed', duration: 1500 })
              })
          })
        Button('Clear').fontSize(14).height(36).flexGrow(1).margin({ left: 8 })
          .backgroundColor('#F44336')
          .onClick(() => {
            try {
              if (this.logSource === 0) {
                native.clearLogs()
              } else if (this.logSource === 1) {
                AppStorage.setOrCreate('cloudAgentLogs', '')
              } else {
                AppStorage.setOrCreate('galleryLogs', '')
              }
              this.logs = '(cleared)'
            } catch (e) {
              AppLogger.errorCause('LogView', 'clearLogs failed source=' + String(this.logSource), e as Error)
              this.logs = 'clearLogs error: ' + JSON.stringify(e)
            }
          })
      }
      .width('95%').margin({ bottom: 8 })

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

  private logTitle(): string {
    if (this.logSource === 0) {
      return 'Runtime Logs'
    }
    if (this.logSource === 1) {
      return 'Cloud Agent Logs'
    }
    return 'Gallery Logs'
  }
}
