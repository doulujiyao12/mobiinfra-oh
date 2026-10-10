import { APP_HEADER_CONTENT_GAP, AppHeader } from '../components/AppHeader';
import { FrostedPage } from '../components/FrostedPage';
import native from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { router } from '@kit.ArkUI';
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';

const PROFILE_MODEL_CONFIG_PATH_KEY: string = 'profileModelConfigPath';
const MODEL_SCOPE_ROOT_DIR_NAME: string = 'modelscope';
const LEGACY_MODEL_DIRS: string[] = ['model', 'modelv2', 'modelv3', 'modelv4', 'model_omc'];

interface ProfileCpuPreset {
  label: string;
  threadNum: number;
  power: string;
  llmCpuCoreIds: number[];
  visionCpuCoreIds: number[];
}

const PROFILE_CPU_PRESETS: ProfileCpuPreset[] = [
  { label: 'auto x4 normal', threadNum: 4, power: 'normal', llmCpuCoreIds: [], visionCpuCoreIds: [] },
  { label: 'auto x4 high', threadNum: 4, power: 'high', llmCpuCoreIds: [], visionCpuCoreIds: [] },
  { label: 'auto x8 normal', threadNum: 8, power: 'normal', llmCpuCoreIds: [], visionCpuCoreIds: [] },
  { label: 'auto x8 high', threadNum: 8, power: 'high', llmCpuCoreIds: [], visionCpuCoreIds: [] },
  { label: 'llm11 vision11+10 x2', threadNum: 2, power: 'normal', llmCpuCoreIds: [11], visionCpuCoreIds: [11, 10] },
  { label: 'llm11+10 vision11+10 x2', threadNum: 2, power: 'normal', llmCpuCoreIds: [11, 10], visionCpuCoreIds: [11, 10] },
  { label: 'llm11+10+7 vision11+10+7 x3', threadNum: 3, power: 'normal', llmCpuCoreIds: [11, 10, 7], visionCpuCoreIds: [11, 10, 7] }
];

type JsonMap = Record<string, Object | string | number | boolean | number[] | null>;

@Entry
@Component
struct ProfileTest {
  private pageScroller: Scroller = new Scroller();
  @State modelConfigPath: string = '';
  @State prompt: string = '你好，简单介绍一下你自己。';
  @State topK: string = '30';
  @State selectedPresetIndex: number = 0;
  @State running: boolean = false;
  @State loaded: boolean = false;
  @State result: string = 'Load a model, then run profile.';

  aboutToAppear() {
    const ctx = getContext(this) as common.UIAbilityContext;
    let configured = AppStorage.get(PROFILE_MODEL_CONFIG_PATH_KEY) as string;
    if (this.isConfigUsable(configured)) {
      this.modelConfigPath = configured;
      return;
    }
    this.modelConfigPath = this.defaultModelConfigPath(ctx.filesDir);
    AppStorage.setOrCreate(PROFILE_MODEL_CONFIG_PATH_KEY, this.modelConfigPath);
  }

  private isConfigUsable(path: string): boolean {
    if (path === undefined || path === null || path.length === 0) {
      return false;
    }
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private hasModelWeightFile(path: string, depth: number = 0): boolean {
    if (depth > 4) {
      return false;
    }
    try {
      let stat = fs.statSync(path);
      if (stat.isFile()) {
        let lower = path.toLowerCase();
        return stat.size > 0 && (lower.endsWith('.mnn') || lower.endsWith('.om') ||
          lower.endsWith('.safetensors') || lower.endsWith('.weight'));
      }
      if (!stat.isDirectory()) {
        return false;
      }
      let children = fs.listFileSync(path);
      for (let child of children) {
        if (this.hasModelWeightFile(path + '/' + child, depth + 1)) {
          return true;
        }
      }
    } catch (e) {
    }
    return false;
  }

  private firstUsableConfigInDir(path: string): string {
    let config = path + '/config.json';
    if (this.isConfigUsable(config) && this.hasModelWeightFile(path)) {
      return config;
    }
    return '';
  }

  private defaultModelConfigPath(filesDir: string): string {
    for (let name of LEGACY_MODEL_DIRS) {
      let config = this.firstUsableConfigInDir(filesDir + '/' + name);
      if (config.length > 0) {
        return config;
      }
    }
    let root = filesDir + '/' + MODEL_SCOPE_ROOT_DIR_NAME;
    try {
      let dirs = fs.listFileSync(root);
      dirs.sort();
      for (let dir of dirs) {
        let config = this.firstUsableConfigInDir(root + '/' + dir);
        if (config.length > 0) {
          return config;
        }
      }
    } catch (e) {
    }
    return filesDir + '/model/config.json';
  }


  private readTextFile(path: string): string {
    let file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      let stat = fs.statSync(path);
      let buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      return util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(buf));
    } finally {
      fs.closeSync(file);
    }
  }

  private writeTextFile(path: string, content: string): void {
    let bytes = util.TextEncoder.create('utf-8').encodeInto(content);
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  private profileConfigDir(baseConfigPath: string): string {
    let slash = baseConfigPath.lastIndexOf('/');
    let modelDir = slash >= 0 ? baseConfigPath.substring(0, slash) : baseConfigPath;
    return modelDir + '/profile_configs';
  }

  private presetSummary(preset: ProfileCpuPreset): string {
    let llmIds = preset.llmCpuCoreIds.length > 0 ? '[' + preset.llmCpuCoreIds.join(',') + ']' : 'auto';
    let visionIds = preset.visionCpuCoreIds.length > 0 ? '[' + preset.visionCpuCoreIds.join(',') + ']' : 'auto';
    return preset.label + ' threads=' + preset.threadNum.toString() + ' power=' + preset.power +
      ' llm=' + llmIds + ' vision=' + visionIds;
  }

  private configNameFromPreset(label: string): string {
    let out = '';
    for (let i = 0; i < label.length; i++) {
      let ch = label.charAt(i);
      if ((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
        out += ch;
      } else {
        out += '_';
      }
    }
    return out;
  }

  private writePresetConfig(baseConfigPath: string, preset: ProfileCpuPreset): string {
    let slash = baseConfigPath.lastIndexOf('/');
    let modelDir = slash >= 0 ? baseConfigPath.substring(0, slash + 1) : '';
    let raw = this.readTextFile(baseConfigPath);
    let parsed = ArkJSON.parse(raw) as JsonMap;
    let cfg: JsonMap = {};
    Object.keys(parsed).forEach((key: string) => {
      if (key !== 'cpu_core_ids' && key !== 'mllm_cpu_core_ids') {
        cfg[key] = parsed[key];
      }
    });
    cfg['base_dir'] = modelDir;
    cfg['backend_type'] = 'cpu';
    cfg['thread_num'] = preset.threadNum;
    cfg['power'] = preset.power;
    if (preset.llmCpuCoreIds.length > 0) {
      cfg['cpu_core_ids'] = preset.llmCpuCoreIds;
    }
    if (cfg['mllm'] !== undefined && cfg['mllm'] !== null) {
      let mllm = cfg['mllm'] as JsonMap;
      mllm['backend_type'] = 'cpu';
      mllm['thread_num'] = preset.threadNum;
      mllm['power'] = preset.power;
    }
    if (preset.visionCpuCoreIds.length > 0) {
      cfg['mllm_cpu_core_ids'] = preset.visionCpuCoreIds;
    }
    cfg['profile_preset'] = this.presetSummary(preset);

    let dir = this.profileConfigDir(baseConfigPath);
    try {
      fs.mkdirSync(dir);
    } catch (e) {
    }
    let name = this.configNameFromPreset(preset.label);
    let path = dir + '/config_' + name + '.json';
    this.writeTextFile(path, ArkJSON.stringify(cfg, null, 4));
    return path;
  }

  private async loadAndProfile(configPath: string, label: string, topK: number): Promise<string> {
    let loadRes: string = await native.loadModel(configPath);
    let profileRes: string = await native.profileGenerate(this.prompt, topK);
    return '\n\n######## ' + label + ' ########\nconfig=' + configPath + '\nload=' + loadRes + '\n' + profileRes;
  }

  private loadModel() {
    if (this.running) {
      return;
    }
    this.running = true;
    this.result = 'Loading model...\n' + this.modelConfigPath;
    native.loadModel(this.modelConfigPath)
      .then((res: string) => {
        this.loaded = true;
        this.result = 'loadModel: ' + res;
        this.running = false;
      })
      .catch((e: Error) => {
        this.loaded = false;
        this.result = 'loadModel error: ' + e.message;
        this.running = false;
      });
  }

  private runProfile() {
    if (this.running) {
      return;
    }
    const k = Math.max(1, parseInt(this.topK || '30') || 30);
    let preset = PROFILE_CPU_PRESETS[this.selectedPresetIndex];
    this.running = true;
    this.result = 'Profiling ' + this.presetSummary(preset) + '...';
    let configPath = this.writePresetConfig(this.modelConfigPath, preset);
    this.loadAndProfile(configPath, this.presetSummary(preset), k)
      .then((res: string) => {
        this.loaded = true;
        this.result = res;
        this.running = false;
      })
      .catch((e: Error) => {
        this.result = 'profileGenerate error: ' + e.message;
        this.running = false;
      });
  }

  private runPresetSweep() {
    if (this.running) {
      return;
    }
    const k = Math.max(1, parseInt(this.topK || '30') || 30);
    this.running = true;
    this.result = 'Running preset sweep...';
    let reports: string[] = [];
    let chain = Promise.resolve();
    for (let i = 0; i < PROFILE_CPU_PRESETS.length; i++) {
      let preset = PROFILE_CPU_PRESETS[i];
      chain = chain.then(async () => {
        this.result = 'Running ' + this.presetSummary(preset) + ' (' + (i + 1).toString() + '/' + PROFILE_CPU_PRESETS.length.toString() + ')...\n' + reports.join('\n');
        let configPath = this.writePresetConfig(this.modelConfigPath, preset);
        let report = await this.loadAndProfile(configPath, this.presetSummary(preset), k);
        reports.push(report);
        this.result = reports.join('\n');
      });
    }
    chain
      .then(() => {
        this.loaded = true;
        this.running = false;
      })
      .catch((e: Error) => {
        this.result = reports.join('\n') + '\n\nSweep error: ' + e.message;
        this.running = false;
      });
  }

  private runCpuCoreBench() {
    if (this.running) {
      return;
    }
    this.running = true;
    this.result = 'Running CPU core benchmark...';
    native.cpuCoreBench()
      .then((res: string) => {
        this.result = res;
        this.running = false;
      })
      .catch((e: Error) => {
        this.result = 'cpuCoreBench error: ' + e.message;
        this.running = false;
      });
  }

  // 顶部返回栏与设置页调试工具入口配套，提供首屏可见的返回路径。
  @Builder PageHeader() {
    AppHeader({ title: 'LLM Op Profile', showBackButton: true,
      onBackClick: (): void => { router.back(); } })
  }

  @Builder PageContent() {
    Scroll(this.pageScroller) {
      Column() {
        Text('Profile real generate path with MNN Executor callbacks.').fontSize(13).fontColor('#666666').width('90%').margin({ top: 14, bottom: 12 })

        Text('Model config path')
          .fontSize(12)
          .fontColor('#666666')
          .alignSelf(ItemAlign.Start)
          .margin({ left: '5%', bottom: 4 })
        TextInput({ text: this.modelConfigPath, placeholder: '/data/storage/el2/base/files/model/config.json' })
          .width('90%')
          .height(42)
          .backgroundColor('#F0F0F0')
          .borderRadius(8)
          .enabled(!this.running)
          .onChange((value: string) => { this.modelConfigPath = value; })

        Text('Prompt')
          .fontSize(12)
          .fontColor('#666666')
          .alignSelf(ItemAlign.Start)
          .margin({ left: '5%', top: 12, bottom: 4 })
        TextArea({ text: this.prompt, placeholder: 'Prompt for profiling' })
          .width('90%')
          .height(96)
          .backgroundColor('#F0F0F0')
          .borderRadius(8)
          .enabled(!this.running)
          .onChange((value: string) => { this.prompt = value; })

        Row() {
          Text('Top ops')
            .fontSize(12)
            .fontColor('#666666')
          TextInput({ text: this.topK, placeholder: '30' })
            .width(90)
            .height(36)
            .type(InputType.Number)
            .backgroundColor('#F0F0F0')
            .borderRadius(8)
            .enabled(!this.running)
            .onChange((value: string) => { this.topK = value; })
        }
        .width('90%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ top: 12, bottom: 12 })

        Text('CPU preset')
          .fontSize(12)
          .fontColor('#666666')
          .alignSelf(ItemAlign.Start)
          .margin({ left: '5%', bottom: 6 })
        Column() {
          ForEach(PROFILE_CPU_PRESETS, (preset: ProfileCpuPreset, index: number) => {
            Button(this.presetSummary(preset))
              .height(34)
              .width('100%')
              .fontSize(12)
              .backgroundColor(this.selectedPresetIndex === index ? '#1565C0' : '#CFD8DC')
              .fontColor(this.selectedPresetIndex === index ? '#FFFFFF' : '#263238')
              .borderRadius(6)
              .enabled(!this.running)
              .margin({ bottom: 6 })
              .onClick(() => { this.selectedPresetIndex = index; })
          }, (preset: ProfileCpuPreset) => preset.label)
        }
        .width('90%')
        .margin({ bottom: 10 })

        Row() {
          Button(this.running ? 'Running...' : 'Load Model')
            .height(42)
            .layoutWeight(1)
            .fontSize(14)
            .backgroundColor('#1565C0')
            .borderRadius(8)
            .enabled(!this.running)
            .onClick(() => { this.loadModel(); })
          Button(this.running ? 'Running...' : 'Run Profile')
            .height(42)
            .layoutWeight(1)
            .fontSize(14)
            .backgroundColor(this.loaded ? '#2E7D32' : '#78909C')
            .borderRadius(8)
            .margin({ left: 10 })
            .enabled(!this.running)
            .onClick(() => { this.runProfile(); })
        }
        .width('90%')
        .margin({ bottom: 12 })

        Button(this.running ? 'Running...' : 'Run All CPU Presets')
          .height(42)
          .width('90%')
          .fontSize(14)
          .backgroundColor(this.running ? '#B0BEC5' : '#00838F')
          .borderRadius(8)
          .enabled(!this.running)
          .margin({ bottom: 12 })
          .onClick(() => { this.runPresetSweep(); })

        Button(this.running ? 'Running...' : 'CPU Core Bench')
          .height(42)
          .width('90%')
          .fontSize(14)
          .backgroundColor(this.running ? '#B0BEC5' : '#6A1B9A')
          .borderRadius(8)
          .enabled(!this.running)
          .margin({ bottom: 12 })
          .onClick(() => { this.runCpuCoreBench(); })

        Button('Copy Log')
          .height(40)
          .width('90%')
          .fontSize(14)
          .backgroundColor('#FF9800')
          .borderRadius(8)
          .enabled(this.result.length > 0)
          .margin({ bottom: 12 })
          .onClick(() => {
            let pb = pasteboard.getSystemPasteboard();
            let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.result);
            pb.setData(data).then(() => {
              promptAction.showToast({ message: 'Copied!', duration: 1500 });
            }).catch(() => {
              promptAction.showToast({ message: 'Copy failed', duration: 1500 });
            });
          })

        Text(this.result)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor('#263238')
          .width('94%')
          .padding(10)
          .backgroundColor('#ECEFF1')
          .borderRadius(6)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: APP_HEADER_CONTENT_GAP, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .clip(false)
  }

  build() {
    Column() {
      FrostedPage({
        pageBackgroundColor: '#FFFFFF',
        scrollers: [this.pageScroller],
        headerBuilder: (): void => { this.PageHeader(); },
        contentBuilder: (): void => { this.PageContent(); }
      })
    }
    .width('100%')
    .height('100%')
  }
}
