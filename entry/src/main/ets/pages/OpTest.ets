import native from 'libentry.so';
import { router } from '@kit.ArkUI';
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';

@Entry
@Component
struct OpTest {
  @State testResult: string = 'Click a button to start testing'
  @State running: boolean = false
  @State customConfig: string = '608,1024,1024,1,1,1,1,1,1,1'
  // HiAI conv-op mode: 'auto' | 'matmul' | 'conv'
  @State convMode: string = 'auto'

  private runWithMode(cfg: string, banner: string) {
    this.running = true
    native.setConvMode(this.convMode)
    this.testResult = '[HiAI mode=' + this.convMode + ']\n' + banner
    let p: Promise<string> = native.opTest(cfg)
    p.then((result: string) => {
      this.testResult = '[HiAI mode=' + this.convMode + ']\n' + result
      this.running = false
    }).catch((e: Error) => {
      this.testResult = 'Error: ' + e.message
      this.running = false
    })
  }

  @Builder ModeBtn(label: string, value: string) {
    Button(label)
      .width('32%')
      .height(36)
      .backgroundColor(this.convMode === value ? '#00796B' : '#CFD8DC')
      .fontColor(this.convMode === value ? '#FFFFFF' : '#333333')
      .borderRadius(8)
      .fontSize(14)
      .enabled(!this.running)
      .onClick(() => { this.convMode = value })
  }

  build() {
    Column() {
      Text('Conv Op Precision Test')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 15, bottom: 5 })

      Text('CPU vs HiAI Delegate (USER_1)')
        .fontSize(13)
        .fontColor('#666666')
        .margin({ bottom: 10 })

      // HiAI conv path selector (applies to subsequent test runs)
      Text('HiAI path:')
        .fontSize(12)
        .fontColor('#666666')
        .alignSelf(ItemAlign.Start)
        .margin({ left: '5%', bottom: 4 })
      Row() {
        this.ModeBtn('Auto', 'auto')
        this.ModeBtn('MatMul', 'matmul')
        this.ModeBtn('Conv', 'conv')
      }
      .width('90%')
      .justifyContent(FlexAlign.SpaceBetween)
      .margin({ bottom: 12 })

      // Preset test button
      Button(this.running ? 'Running...' : 'Run Preset Tests')
        .width('90%')
        .height(48)
        .backgroundColor(this.running ? '#BBBBBB' : '#2196F3')
        .borderRadius(10)
        .fontSize(16)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          this.runWithMode('preset', 'Running preset test suite...\n')
        })

      // Qwen3VL visual encoder test button
      Button(this.running ? 'Running...' : 'Run Qwen3VL Visual (N=608)')
        .width('90%')
        .height(48)
        .backgroundColor(this.running ? '#BBBBBB' : '#9C27B0')
        .borderRadius(10)
        .fontSize(16)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          this.runWithMode('qwen3vl', 'Running Qwen3VL visual encoder ops (N=608, 1x1 conv)...\n')
        })

      // Custom test section
      Row() {
        TextInput({ placeholder: 'N,ic,oc,ih,iw,kh,kw,sh,sw,group', text: this.customConfig })
          .width('65%')
          .height(40)
          .borderRadius(8)
          .backgroundColor('#F0F0F0')
          .onChange((value: string) => { this.customConfig = value })

        Button('Run')
          .width('30%')
          .height(40)
          .backgroundColor(this.running ? '#BBBBBB' : '#4CAF50')
          .borderRadius(8)
          .enabled(!this.running)
          .margin({ left: '3%' })
          .onClick(() => {
            this.runWithMode(this.customConfig, 'Running: ' + this.customConfig + '\n')
          })
      }
      .width('90%')
      .margin({ bottom: 15 })

      // Result display - white text on dark background
      Scroll() {
        Text(this.testResult)
          .fontSize(13)
          .fontColor('#E0E0E0')
          .width('100%')
          .padding(12)
      }
      .width('90%')
      .layoutWeight(1)
      .backgroundColor('#1A1A2E')
      .borderRadius(10)
      .margin({ bottom: 8 })

      // Action row: Copy + Back
      Row() {
        Button('Copy Log')
          .width('48%')
          .height(40)
          .backgroundColor('#FF9800')
          .borderRadius(8)
          .fontSize(15)
          .onClick(() => {
            let pb = pasteboard.getSystemPasteboard();
            let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.testResult);
            pb.setData(data).then(() => {
              promptAction.showToast({ message: 'Copied!', duration: 1500 });
            }).catch(() => {
              promptAction.showToast({ message: 'Copy failed', duration: 1500 });
            });
          })

        Button('Back')
          .width('48%')
          .height(40)
          .backgroundColor('#757575')
          .borderRadius(8)
          .fontSize(15)
          .margin({ left: '4%' })
          .onClick(() => {
            router.back()
          })
      }
      .width('90%')
      .margin({ bottom: 15 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F9FC')
  }
}
