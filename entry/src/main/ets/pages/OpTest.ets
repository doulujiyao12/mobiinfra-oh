import native from 'libentry.so';
import { router } from '@kit.ArkUI';
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct OpTest {
  @State testResult: string = 'Click a button to start testing'
  @State running: boolean = false
  @State customConfig: string = '608,1024,1024,1,1,1,1,1,1,1'
  @State modelDir: string = ''
  @State visualSeqLen: string = '608'
  // LayerNorm A/B test custom shape (independent of visualSeqLen so the LN
  // can be debugged at smaller sizes without affecting the chunk test).
  @State lnSeqLen: string = '608'
  @State lnHiddenDim: string = '1024'
  // HiAI conv-op mode: 'auto' | 'matmul' | 'conv'
  @State convMode: string = 'auto'
  // HiAI int8 quant mode: 'auto' (on) | 'off' — use real hiai::op::QuantizedConvolution when eligible
  @State convQuant: string = 'auto'
  // CPU precision: 'normal' (fp32) | 'high' (fp32) | 'low' (fp16/ARM82) | 'low_bf16'
  @State cpuPrecision: string = 'normal'
  // CPU memory: 'normal' | 'high' | 'low' (int8 test needs 'low')
  @State cpuMemory: string = 'normal'

  aboutToAppear() {
    let ctx = getContext(this) as common.UIAbilityContext
    this.modelDir = ctx.filesDir + '/model'
    try {
      const res = native.prepareCustomOpp(ctx.resourceManager, ctx.filesDir + '/custom_opp')
      if (res !== 'ok') {
        this.testResult = 'prepare custom opp failed: ' + res
      }
    } catch (e) {
      this.testResult = 'prepare custom opp exception: ' + JSON.stringify(e)
    }
  }

  private runWithMode(cfg: string, banner: string) {
    this.running = true
    native.setConvMode(this.convMode)
    native.setConvQuant(this.convQuant)
    native.setCpuPrecision(this.cpuPrecision)
    native.setCpuMemory(this.cpuMemory)
    const header = '[HiAI=' + this.convMode
      + ' quant=' + this.convQuant
      + ' | CPU prec=' + this.cpuPrecision
      + ' mem=' + this.cpuMemory + ']\n'
    this.testResult = header + banner
    let p: Promise<string> = native.opTest(cfg)
    p.then((result: string) => {
      this.testResult = header + result
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

  @Builder QuantBtn(label: string, value: string) {
    Button(label)
      .width('32%')
      .height(34)
      .backgroundColor(this.convQuant === value ? '#00695C' : '#CFD8DC')
      .fontColor(this.convQuant === value ? '#FFFFFF' : '#333333')
      .borderRadius(8)
      .fontSize(11)
      .enabled(!this.running)
      .margin({ bottom: 8 })
      .onClick(() => { this.convQuant = value })
  }

  @Builder PrecBtn(label: string, value: string) {
    Button(label)
      .width('24%')
      .height(34)
      .backgroundColor(this.cpuPrecision === value ? '#1565C0' : '#CFD8DC')
      .fontColor(this.cpuPrecision === value ? '#FFFFFF' : '#333333')
      .borderRadius(8)
      .fontSize(13)
      .enabled(!this.running)
      .onClick(() => { this.cpuPrecision = value })
  }

  @Builder MemBtn(label: string, value: string) {
    Button(label)
      .width('32%')
      .height(34)
      .backgroundColor(this.cpuMemory === value ? '#6A1B9A' : '#CFD8DC')
      .fontColor(this.cpuMemory === value ? '#FFFFFF' : '#333333')
      .borderRadius(8)
      .fontSize(13)
      .enabled(!this.running)
      .onClick(() => { this.cpuMemory = value })
  }

  build() {
    Scroll() {
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
      .margin({ bottom: 8 })

      // HiAI int8 path selector — real hiai::op::QuantizedConvolution vs dequant-to-fp32
      Text('HiAI int8 path (affects int8 tests only):')
        .fontSize(12)
        .fontColor('#666666')
        .alignSelf(ItemAlign.Start)
        .margin({ left: '5%', bottom: 4 })
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        this.QuantBtn('w-only',    'auto')
        this.QuantBtn('full',      'full')
        this.QuantBtn('mm_int8',   'matmul_int8')
        this.QuantBtn('fc_int8',   'fc_int8')
        this.QuantBtn('off',       'off')
      }
      .width('90%')
      .margin({ bottom: 8 })

      // CPU precision selector (fp32 normal/high, fp16 via ARM82, bf16)
      Text('CPU precision:')
        .fontSize(12)
        .fontColor('#666666')
        .alignSelf(ItemAlign.Start)
        .margin({ left: '5%', bottom: 4 })
      Row() {
        this.PrecBtn('Normal', 'normal')
        this.PrecBtn('High',   'high')
        this.PrecBtn('Low(fp16)', 'low')
        this.PrecBtn('BF16',   'low_bf16')
      }
      .width('90%')
      .justifyContent(FlexAlign.SpaceBetween)
      .margin({ bottom: 8 })

      // CPU memory selector (Low keeps int8 weights for the int8 test)
      Text('CPU memory:')
        .fontSize(12)
        .fontColor('#666666')
        .alignSelf(ItemAlign.Start)
        .margin({ left: '5%', bottom: 4 })
      Row() {
        this.MemBtn('Normal', 'normal')
        this.MemBtn('High',   'high')
        this.MemBtn('Low',    'low')
      }
      .width('90%')
      .justifyContent(FlexAlign.SpaceBetween)
      .margin({ bottom: 12 })

      Text('Visual chunk model dir:')
        .fontSize(12)
        .fontColor('#666666')
        .alignSelf(ItemAlign.Start)
        .margin({ left: '5%', bottom: 4 })
      TextInput({ placeholder: '/data/storage/el2/base/files/model', text: this.modelDir })
        .width('90%')
        .height(40)
        .borderRadius(8)
        .backgroundColor('#F0F0F0')
        .margin({ bottom: 8 })
        .onChange((value: string) => { this.modelDir = value })

      Row() {
        Text('Visual seq len:')
          .fontSize(12)
          .fontColor('#666666')
        TextInput({ placeholder: '608', text: this.visualSeqLen })
          .width('35%')
          .height(36)
          .margin({ left: 10 })
          .borderRadius(8)
          .backgroundColor('#F0F0F0')
          .type(InputType.Number)
          .onChange((value: string) => { this.visualSeqLen = value })
      }
      .width('90%')
      .justifyContent(FlexAlign.Start)
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

      // Qwen3VL visual encoder test button (FP32)
      Button(this.running ? 'Running...' : 'Run Qwen3VL Visual FP32 (N=608)')
        .width('90%')
        .height(48)
        .backgroundColor(this.running ? '#BBBBBB' : '#9C27B0')
        .borderRadius(10)
        .fontSize(16)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          this.runWithMode('qwen3vl', 'Running Qwen3VL visual encoder ops (fp32, 1x1 conv, N=608)...\n')
        })

      // Qwen3VL visual encoder test button (Int8 per-channel)
      Button(this.running ? 'Running...' : 'Run Qwen3VL Visual Int8 PerChannel (N=608)')
        .width('90%')
        .height(48)
        .backgroundColor(this.running ? '#BBBBBB' : '#E91E63')
        .borderRadius(10)
        .fontSize(15)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          this.runWithMode('qwen3vl_int8', 'Running Qwen3VL visual encoder ops (int8 per-channel, N=608)...\n')
        })

      // Qwen3VL visual encoder Attention precision test (FP32)
      // Q/K/V=[1,608,16,64] mask=[1,608,608] — shape comes from the
      // real on-device NPUAttention.onResize log for blocks.0/self_attn.
      Button(this.running ? 'Running...' : 'Run Qwen3VL Attention FP32 (B=1 S=608 H=16 D=64)')
        .width('90%')
        .height(48)
        .backgroundColor(this.running ? '#BBBBBB' : '#00BCD4')
        .borderRadius(10)
        .fontSize(14)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          this.runWithMode('qwen3vl_attn',
            'Running Qwen3VL visual encoder attention (fp32, B=1 S=608 H=16 D=64, with/without mask)...\n')
        })

      Button(this.running ? 'Running...' : 'Run Qwen3VL RoPE Gather Test (CPU vs HiAI)')
        .width('90%')
        .height(48)
        .backgroundColor(this.running ? '#BBBBBB' : '#26A69A')
        .borderRadius(10)
        .fontSize(14)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          this.runWithMode('qwen3vl_rope',
            'Running Qwen3VL RoPE Gather/Mul/Add test (q=[1,608,16,64], rotary=[2,1,608,1,64])...\n')
        })

      // ===== LayerNorm A/B custom shape inputs =====
      Row() {
        Text('LN seqLen:')
          .fontSize(12)
          .fontColor('#666666')
        TextInput({ placeholder: '608', text: this.lnSeqLen })
          .width('22%')
          .height(36)
          .margin({ left: 6 })
          .borderRadius(8)
          .backgroundColor('#F0F0F0')
          .type(InputType.Number)
          .onChange((value: string) => { this.lnSeqLen = value })
        Text('hiddenDim:')
          .fontSize(12)
          .fontColor('#666666')
          .margin({ left: 12 })
        TextInput({ placeholder: '1024', text: this.lnHiddenDim })
          .width('22%')
          .height(36)
          .margin({ left: 6 })
          .borderRadius(8)
          .backgroundColor('#F0F0F0')
          .type(InputType.Number)
          .onChange((value: string) => { this.lnHiddenDim = value })
      }
      .width('90%')
      .justifyContent(FlexAlign.Start)
      .margin({ bottom: 8 })

      Button(this.running ? 'Running...' : 'Run Qwen3VL LayerNorm A/B (CPU ref axis=-1 vs HiAI)')
        .width('90%')
        .height(48)
        .backgroundColor(this.running ? '#BBBBBB' : '#7CB342')
        .borderRadius(10)
        .fontSize(13)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          const seqLen = Math.max(1, parseInt(this.lnSeqLen || '608') || 608)
          const hiddenDim = Math.max(1, parseInt(this.lnHiddenDim || '1024') || 1024)
          // Payload format: qwen3vl_ln_ab|<modelDir>|<seqLen>|<hiddenDim>
          // (modelDir is ignored by the synthetic test but kept for back-compat
          // with the existing parser in napi_init.cpp.)
          const cfg = 'qwen3vl_ln_ab|' + this.modelDir + '|' + seqLen + '|' + hiddenDim
          this.runWithMode(cfg,
            'Running LayerNorm A/B test (synthetic, x=[1,' + seqLen + ',' + hiddenDim + '])...\n')
        })

      Button(this.running ? 'Running...' : 'Run LN A/B  gamma=0 (diagnose: HiAI eats gamma?)')
        .width('90%')
        .height(48)
        .backgroundColor(this.running ? '#BBBBBB' : '#FFA726')
        .borderRadius(10)
        .fontSize(13)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          const seqLen = Math.max(1, parseInt(this.lnSeqLen || '608') || 608)
          const hiddenDim = Math.max(1, parseInt(this.lnHiddenDim || '1024') || 1024)
          const cfg = 'qwen3vl_ln_ab_g0|' + seqLen + '|' + hiddenDim
          this.runWithMode(cfg,
            'Running LayerNorm A/B with gamma=0 / beta=real, x=[1,' + seqLen + ',' + hiddenDim + ']. ' +
            'If NPU output ≡ beta in BOTH this and the normal A/B, HiAI LayerNorm is ignoring gamma.\n')
        })

      Button(this.running ? 'Running...' : 'Run Qwen3VL Visual Chunks (real .mnn, CPU vs NPU)')
        .width('90%')
        .height(52)
        .backgroundColor(this.running ? '#BBBBBB' : '#4DB6AC')
        .borderRadius(10)
        .fontSize(14)
        .enabled(!this.running)
        .margin({ bottom: 10 })
        .onClick(() => {
          let seq = this.visualSeqLen.trim().length > 0 ? this.visualSeqLen.trim() : '608'
          this.runWithMode(
            'qwen3vl_chunks|' + this.modelDir + '|' + seq,
            'Running real Qwen3VL visual chunk models from: ' + this.modelDir + '\nseq_len=' + seq + '\n'
          )
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
      .height(400)
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
    .backgroundColor('#F7F9FC')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F7F9FC')
  }
}
