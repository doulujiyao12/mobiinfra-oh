import native from 'libentry.so';
import { router } from '@kit.ArkUI';

@Entry
@Component
struct OpTest {
  @State testResult: string = 'Click a button to start testing'
  @State running: boolean = false
  @State customConfig: string = '608,1024,1024,1,1,1,1,1,1,1'

  build() {
    Column() {
      Text('Conv Op Precision Test')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 15, bottom: 5 })

      Text('CPU vs HiAI Delegate (USER_1)')
        .fontSize(13)
        .fontColor('#666666')
        .margin({ bottom: 15 })

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
          this.running = true
          this.testResult = 'Running preset test suite...\n'
          let p: Promise<string> = native.opTest('preset')
          p.then((result: string) => {
            this.testResult = result
            this.running = false
          }).catch((e: Error) => {
            this.testResult = 'Error: ' + e.message
            this.running = false
          })
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
          this.running = true
          this.testResult = 'Running Qwen3VL visual encoder ops (N=608, 1x1 conv)...\n'
          let p: Promise<string> = native.opTest('qwen3vl')
          p.then((result: string) => {
            this.testResult = result
            this.running = false
          }).catch((e: Error) => {
            this.testResult = 'Error: ' + e.message
            this.running = false
          })
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
            this.running = true
            this.testResult = 'Running: ' + this.customConfig + '\n'
            let p: Promise<string> = native.opTest(this.customConfig)
            p.then((result: string) => {
              this.testResult = result
              this.running = false
            }).catch((e: Error) => {
              this.testResult = 'Error: ' + e.message
              this.running = false
            })
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
      .margin({ bottom: 15 })

      Button('Back')
        .width('90%')
        .height(40)
        .backgroundColor('#757575')
        .borderRadius(8)
        .margin({ bottom: 15 })
        .onClick(() => {
          router.back()
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F9FC')
  }
}
