import native from 'libentry.so';
import { router } from '@kit.ArkUI';

@Entry
@Component
struct OpTest {
  @State testResult: string = ''
  @State running: boolean = false
  @State customConfig: string = '64,128,7,7,1,1,1,1,1'

  build() {
    Column() {
      // Title
      Text('Conv Op Precision Test')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 15, bottom: 10 })

      Text('CPU vs HiAI Delegate (MNN_FORWARD_USER_1)')
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
        .onClick(async () => {
          this.running = true
          this.testResult = 'Running preset test suite...\n'
          try {
            let result: string = await native.opTest('preset')
            this.testResult = result
          } catch (e) {
            this.testResult = 'Error: ' + JSON.stringify(e)
          }
          this.running = false
        })

      // Custom test section
      Row() {
        TextInput({ placeholder: 'ic,oc,ih,iw,kh,kw,sh,sw,group', text: this.customConfig })
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
          .onClick(async () => {
            this.running = true
            this.testResult = 'Running custom test: ' + this.customConfig + '\n'
            try {
              let result: string = await native.opTest(this.customConfig)
              this.testResult = result
            } catch (e) {
              this.testResult = 'Error: ' + JSON.stringify(e)
            }
            this.running = false
          })
      }
      .width('90%')
      .margin({ bottom: 15 })

      // Result display
      Scroll() {
        Text(this.testResult)
          .fontSize(12)
          .fontFamily('monospace')
          .width('100%')
          .padding(12)
      }
      .width('90%')
      .layoutWeight(1)
      .backgroundColor('#1A1A2E')
      .borderRadius(10)
      .margin({ bottom: 15 })

      // Back button
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
