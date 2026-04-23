import entry from 'libentry.so';
import { router } from '@kit.ArkUI';

// @Entry
// @Component
// struct Index {
//   @State status: string = '未加载模型'
//   @State output: string = ''
//   @State userInput: string = ''
//   @State loading: boolean = false
//   private modelPath: string = ''
//
//   aboutToAppear() {
//     // 获取应用沙箱 files 目录
//     let filesDir = getContext(this).filesDir
//     this.modelPath = filesDir + '/model/config.json'
//     this.output = '沙箱路径: ' + filesDir
//   }
//
//   build() {
//     Column() {
//       Text(this.status)
//         .fontSize(16)
//         .fontColor(this.status.startsWith('error') ? Color.Red : Color.Green)
//         .margin(10)
//
//       Button('拷贝模型到沙箱')
//         .onClick(() => {
//           let filesDir = getContext(this).filesDir
//           let res = entry.copyModel('/data/local/tmp/MNN/model', filesDir + '/model')
//           this.output = '拷贝结果: ' + res + '\n路径: ' + filesDir + '/model'
//         })
//         .margin(10)
//
//       Button('加载模型')
//         .onClick(() => {
//           this.status = '加载中...'
//           this.loading = true
//           let res = entry.loadModel(this.modelPath)
//           this.status = res === 'ok' ? '模型已加载' : res
//           this.loading = false
//         })
//         .margin(10)
//         .enabled(!this.loading)
//
//       TextInput({ placeholder: '输入问题...', text: this.userInput })
//         .onChange((value: string) => { this.userInput = value })
//         .margin(10)
//         .width('90%')
//
//       Row() {
//         Button('单轮推理')
//           .onClick(() => {
//             if (!this.userInput) return
//             this.output = '推理中...'
//             this.output = entry.generate(this.userInput)
//           })
//           .margin(5)
//
//         Button('对话')
//           .onClick(() => {
//             if (!this.userInput) return
//             this.output = '思考中...'
//             let reply = entry.chat(this.userInput)
//             this.output = '> ' + this.userInput + '\n\n' + reply
//             this.userInput = ''
//           })
//           .margin(5)
//
//         Button('重置')
//           .onClick(() => {
//             entry.reset()
//             this.output = '对话已重置'
//           })
//           .margin(5)
//       }
//
//       Scroll() {
//         Text(this.output)
//           .fontSize(14)
//           .margin(10)
//           .width('90%')
//       }
//       .height('50%')
//       .width('100%')
//     }
//     .width('100%')
//     .height('100%')
//     .padding(10)
//   }
// }

// import mnnllm from 'libentry.so';
// import request from '@ohos.request';
// import fs from '@ohos.file.fs';
// import common from '@ohos.app.ability.common';
//
// const MODEL_ID: string = 'doulujiyao/mnn_mobi_gptq_new_sym_e2e_2B_w8a8_half_rl_n64_s512_visual';
//
// const MODEL_FILES: string[] = [
//   'config.json',
//   'llm_config.json',
//   'export_args.json',
//   'tokenizer.mtok',
//   'llm.mnn',
//   'llm.mnn.json',
//   'llm.mnn.weight',
//   'embeddings_bf16.bin',
//   'visual.mnn',
//   'visual.mnn.json',
//   'visual.mnn.weight'
// ];
//
// @Entry
// @Component
// struct Index {
//   @State output: string = '准备就绪';
//   @State chatHistory: string = '';
//   @State userInput: string = '';
//   @State downloading: boolean = false;
//   @State modelLoaded: boolean = false;
//
//   private filesDir: string = '';
//   private modelDir: string = '';
//
//   aboutToAppear() {
//     let ctx = getContext(this) as common.UIAbilityContext;
//     this.filesDir = ctx.filesDir;
//     this.modelDir = this.filesDir + '/model';
//   }
//
//   private getDownloadUrl(filename: string): string {
//     return `https://modelscope.cn/models/${MODEL_ID}/resolve/master/${filename}`;
//   }
//
//   private downloadOneFile(filename: string, index: number, fileCount: number): Promise<boolean> {
//     const url = this.getDownloadUrl(filename);
//     const savePath = `${this.modelDir}/${filename}`;
//
//     // Skip if already downloaded
//     try {
//       let st = fs.statSync(savePath);
//       if (st.size > 0) {
//         this.output = `[${index + 1}/${fileCount}] ${filename} 已存在(${(st.size /
//           1048576).toFixed(1)}MB)，跳过`;
//         return Promise.resolve(true);
//       }
//     } catch (e) {
//       // file doesn't exist, proceed
//     }
//
//     this.output = `[${index + 1}/${fileCount}] 开始下载: ${filename}`;
//
//     let ctx = getContext(this) as common.UIAbilityContext;
//     let self = this;
//
//     return new Promise<boolean>((resolve) => {
//       request.downloadFile(ctx, {
//         url: url,
//         filePath: savePath,
//         enableMetered: true,
//         enableRoaming: true,
//       }).then((task: request.DownloadTask) => {
//         task.on('progress', (receivedSize: number, totalSize: number) => {
//           let pct = totalSize > 0 ? Math.floor(receivedSize * 100 / totalSize) : 0;
//           let recvMB = (receivedSize / 1048576).toFixed(1);
//           let totMB = (totalSize / 1048576).toFixed(1);
//           self.output = `[${index + 1}/${fileCount}] ${filename}\n${recvMB}MB / ${totMB}MB  ${pct}%`;
//         });
//         task.on('complete', () => {
//           self.output = `[${index + 1}/${fileCount}] ${filename} done`;
//           resolve(true);
//         });
//         task.on('fail', (err: number) => {
//           self.output = `[${index + 1}/${fileCount}] ${filename} 失败(err=${err})`;
//           resolve(false);
//         });
//       }).catch((err: Error) => {
//         self.output = `创建下载任务失败: ${filename}\n${err.message}`;
//         resolve(false);
//       });
//     });
//   }
//
//   async downloadModel() {
//     this.downloading = true;
//     this.output = '准备下载...';
//
//     // Create model directory
//     try {
//       fs.mkdirSync(this.modelDir);
//     } catch (e) {
//       // already exists
//     }
//
//     let failed: string[] = [];
//     for (let i = 0; i < MODEL_FILES.length; i++) {
//       let ok = await this.downloadOneFile(MODEL_FILES[i], i, MODEL_FILES.length);
//       if (!ok) {
//         failed.push(MODEL_FILES[i]);
//       }
//     }
//
//     if (failed.length === 0) {
//       this.output = '全部下载完成! 可以加载模型了';
//     } else {
//       this.output = `完成，${failed.length}个失败: ${failed.join(', ')}\n可重新点击下载(已有文件会跳过)`;
//     }
//     this.downloading = false;
//   }
//
//   build() {
//     Column() {
//       Text('MNN LLM').fontSize(20).fontWeight(FontWeight.Bold).margin(10)
//
//       Scroll() {
//         Text(this.output)
//           .fontSize(13)
//           .fontFamily('monospace')
//           .width('100%')
//           .padding(10)
//       }
//       .height('30%')
//       .width('95%')
//       .backgroundColor('#f5f5f5')
//       .borderRadius(8)
//       .margin(5)
//
//       // Download & Load
//       Row() {
//         Button('下载模型')
//           .onClick(() => { this.downloadModel(); })
//           .enabled(!this.downloading)
//           .margin(5)
//         Button('加载模型')
//           .onClick(() => {
//             let configPath = this.modelDir + '/config.json';
//             this.output = '加载中...';
//             this.output = mnnllm.loadModel(configPath);
//             if (this.output.indexOf('success') >= 0) {
//               this.modelLoaded = true;
//             }
//           })
//           .enabled(!this.downloading)
//           .margin(5)
//       }.margin(5)
//
//       // Chat area
//       Scroll() {
//         Text(this.chatHistory)
//           .fontSize(14)
//           .width('100%')
//           .padding(10)
//       }
//       .height('30%')
//       .width('95%')
//       .backgroundColor('#fafafa')
//       .borderRadius(8)
//       .margin(5)
//
//       Row() {
//         TextInput({ placeholder: '输入消息...', text: this.userInput })
//           .onChange((val: string) => { this.userInput = val; })
//           .layoutWeight(1)
//           .margin(5)
//         Button('发送')
//           .onClick(() => {
//             if (!this.modelLoaded || this.userInput.length === 0) return;
//             let msg = this.userInput;
//             this.userInput = '';
//             this.chatHistory += `\nUser: ${msg}\n`;
//             let reply = mnnllm.chat(msg);
//             this.chatHistory += `Assistant: ${reply}\n`;
//           })
//           .margin(5)
//       }.width('95%')
//
//       Row() {
//         Button('单轮推理')
//           .onClick(() => {
//             if (!this.modelLoaded) return;
//             this.output = mnnllm.generate('你好');
//           })
//           .margin(5)
//         Button('重置')
//           .onClick(() => {
//             this.output = mnnllm.reset();
//             this.chatHistory = '';
//           })
//           .margin(5)
//       }.margin(5)
//
//     }
//     .width('100%')
//     .height('100%')
//     .padding(10)
//   }
// }

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import mnnllm from 'libentry.so';
import { LlmServer } from '../utils/LlmServer';
import { promptAction } from '@kit.ArkUI';

interface ServerFile {
  name: string;
  size: number;
}

PersistentStorage.persistProp('wirelessIp', '101.5.155.98:35729');
PersistentStorage.persistProp('serverIp', 'http://166.111.53.96:9123');
PersistentStorage.persistProp('hdcServerIp', 'http://166.111.53.96:9124');

@Entry
@Component
struct Index {
  @State output: string = '请先检查服务器连接';
  @State chatHistory: string = '';
  @State userInput: string = '';
  @State downloading: boolean = false;
  @State modelLoaded: boolean = false;
  @State connected: boolean = false;
  @State autoConfirm: boolean = false;
  @State debugImagePath: string = '';
  @State isModelV2: boolean = false;
  @State threadNumInput: string = '4';
  @State backendTypeInput: string = 'cpu';
  @State mllmBackendTypeInput: string = 'cpu';
  @StorageLink('serverIp') serverIp: string = 'http://166.111.53.96:9123';
  @StorageLink('hdcServerIp') hdcServerIp: string = 'http://166.111.53.96:9124';
  @StorageLink('wirelessIp') wirelessIp: string = '101.5.155.98:35729';
  @State isThinking: boolean = false;
  @State buttonScale: number = 1.0;

  private filesDir: string = '';
  private modelDir: string = '';
  private serverFiles: ServerFile[] = [];
  private totalBytesAll: number = 0;
  
  // 我们将 PC 控制的服务端作为单例保存
  private llmServer: LlmServer = new LlmServer();

  aboutToAppear() {
    let ctx = getContext(this) as common.UIAbilityContext;
    this.filesDir = ctx.filesDir;
    this.modelDir = this.filesDir + '/model';
    try {
      mnnllm.initLogFile(this.filesDir + '/mnn_runtime.log');
    } catch (e) {
      console.error('initLogFile failed: ' + JSON.stringify(e));
    }
  }

  formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes}B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)}KB`;
    if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(1)}MB`;
    return `${(bytes / 1073741824).toFixed(2)}GB`;
  }

  clearScreenshots() {
    try {
      let files = fs.listFileSync(this.filesDir);
      let count = 0;
      for (let f of files) {
        if (f.startsWith('agent_') || f.toLowerCase().endsWith('.jpg') || f.toLowerCase().endsWith('.jpeg')) {
          try { fs.unlinkSync(`${this.filesDir}/${f}`); } catch(e) {}
          count++;
        }
      }
      this.output = `清理成功！删除了 ${count} 张缓存截图。`;
      this.debugImagePath = '';
    } catch(e) {
      this.output = `清理截图失败: ${e}`;
    }
  }

  listScreenshots() {
    try {
      let files = fs.listFileSync(this.filesDir);
      let screenshots = files.filter(f => f.toLowerCase().endsWith('.jpg') || f.toLowerCase().endsWith('.jpeg') || f.startsWith('agent_'));
      if (screenshots.length > 0) {
        this.output = `====== 沙箱内截图文件列表 ======\n${screenshots.join('\n')}`;
      } else {
        this.output = `沙箱内当前没有截图文件。`;
      }
    } catch (e) {
      this.output = `列出截图失败: ${e}`;
    }
  }

  deleteModelFiles() {
    try {
      if (!fs.accessSync(this.modelDir)) {
        this.output = `模型文件夹不存在，无需删除。`;
        return;
      }
      let files = fs.listFileSync(this.modelDir);
      let count = 0;
      for (let f of files) {
        fs.unlinkSync(`${this.modelDir}/${f}`);
        count++;
      }
      this.modelLoaded = false;
      this.output = `成功删除了 ${count} 个模型文件，\n现在可以重新下载了。`;
    } catch (e) {
      this.output = `删除模型文件失败: ${e}`;
    }
  }

  deleteModelConfigJson() {
    let cfgPath = this.modelDir + '/config.json';
    try {
      if (!fs.accessSync(this.modelDir)) {
        this.output = `模型文件夹不存在: ${this.modelDir}`;
        return;
      }
      if (!fs.accessSync(cfgPath)) {
        this.output = `文件不存在: ${cfgPath}\n无需删除。`;
        return;
      }
      fs.unlinkSync(cfgPath);
      this.modelLoaded = false;
      this.output = `已删除 ${this.isModelV2 ? 'modelv2' : 'model'}/config.json。\n其他模型文件保留，可重新下载仅补 config.json。`;
    } catch (e) {
      this.output = `删除 config.json 失败: ${e}`;
    }
  }

  showConfigJson() {
    let cfgPath = this.modelDir + '/config.json';
    try {
      if (!fs.accessSync(cfgPath)) {
        this.output = `文件不存在: ${cfgPath}\n请先下载模型`;
        return;
      }
      let file = fs.openSync(cfgPath, fs.OpenMode.READ_ONLY);
      let stat = fs.statSync(cfgPath);
      let buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      let textDecoder = util.TextDecoder.create('utf-8');
      let content = textDecoder.decodeWithStream(new Uint8Array(buf));
      this.output = `====== ${this.isModelV2 ? 'modelv2' : 'model'}/config.json ======\n${content}`;
    } catch (e) {
      this.output = `读取 config.json 失败: ${e}`;
    }
  }

  updateConfigThreadNum() {
    let num = parseInt(this.threadNumInput);
    if (isNaN(num) || num <= 0) {
      this.output = '请输入有效的线程数 (正整数)';
      return;
    }
    
    let cfgPath = this.modelDir + '/config.json';
    try {
      if (!fs.accessSync(cfgPath)) {
        this.output = `文件不存在: ${cfgPath}`;
        return;
      }
      
      // 读取文件
      let fileRead = fs.openSync(cfgPath, fs.OpenMode.READ_ONLY);
      let stat = fs.statSync(cfgPath);
      let buf = new ArrayBuffer(stat.size);
      fs.readSync(fileRead.fd, buf);
      fs.closeSync(fileRead);
      
      let textDecoder = util.TextDecoder.create('utf-8');
      let content = textDecoder.decodeWithStream(new Uint8Array(buf));
      
      // 修改 JSON (ArkTS 强制类型严谨)
      let configObj = JSON.parse(content) as Record<string, Object>;
      configObj['thread_num'] = num;
      if (configObj['mllm']) {
        let mllmObj = configObj['mllm'] as Record<string, Object>;
        mllmObj['thread_num'] = num;
      }
      
      // 写入文件
      let newStr = JSON.stringify(configObj, null, 4);
      let byteStr = util.TextEncoder.create('utf-8').encodeInto(newStr);
      let fileWrite = fs.openSync(cfgPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(fileWrite.fd, byteStr.buffer);
      fs.closeSync(fileWrite);
      
      this.output = `更新线程数成功: ${num}\n====== 新配置 ======\n${newStr}`;
    } catch (e) {
      this.output = `更新 config.json 失败: ${e}`;
    }
  }

  updateConfigBackendType(target: string) {
    let value = (target === 'mllm') ? this.mllmBackendTypeInput.trim() : this.backendTypeInput.trim();
    if (value.length === 0) {
      this.output = '请输入有效的 backend_type';
      return;
    }

    let cfgPath = this.modelDir + '/config.json';
    try {
      if (!fs.accessSync(cfgPath)) {
        this.output = `文件不存在: ${cfgPath}`;
        return;
      }

      let fileRead = fs.openSync(cfgPath, fs.OpenMode.READ_ONLY);
      let stat = fs.statSync(cfgPath);
      let buf = new ArrayBuffer(stat.size);
      fs.readSync(fileRead.fd, buf);
      fs.closeSync(fileRead);

      let textDecoder = util.TextDecoder.create('utf-8');
      let content = textDecoder.decodeWithStream(new Uint8Array(buf));
      let configObj = JSON.parse(content) as Record<string, Object>;

      if (target === 'mllm') {
        if (configObj['mllm']) {
          let mllmObj = configObj['mllm'] as Record<string, Object>;
          mllmObj['backend_type'] = value;
        } else {
          this.output = 'config.json 中不存在 mllm 字段';
          return;
        }
      } else {
        configObj['backend_type'] = value;
      }

      let newStr = JSON.stringify(configObj, null, 4);
      let byteStr = util.TextEncoder.create('utf-8').encodeInto(newStr);
      let fileWrite = fs.openSync(cfgPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(fileWrite.fd, byteStr.buffer);
      fs.closeSync(fileWrite);

      let label = (target === 'mllm') ? 'mllm.backend_type' : 'backend_type';
      this.output = `更新 ${label} 成功: ${value}\n====== 新配置 ======\n${newStr}`;
    } catch (e) {
      this.output = `更新 config.json 失败: ${e}`;
    }
  }

  async testAndConnectHdc() {
    this.output = `正在请求远端服务执行 HDC 连接测试: ${this.wirelessIp}...`;
    let httpReq = http.createHttp();
    try {
      // 构造 Python 脚本：获取 targets 列表，如果发现其他设备，则使用 hdc tconn IP -rm 断开（或做 hdc kill 清理），随后连接我们指定的 IP
      let pyScript = `import os; targets = os.popen('hdc list targets').read().split(); ` + 
                     `[os.system('hdc kill ' + t) for t in targets if t and t != '${this.wirelessIp}' and '[Empty]' not in t]; ` +
                     `os.system('hdc tconn ${this.wirelessIp}')`;

      let resp = await httpReq.request(`${this.hdcServerIp}/api/run_cmd`, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify({
          cmd: `python -c "${pyScript}"`
        }),
        connectTimeout: 5000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING,
      });
      if (resp.responseCode === 200) {
        this.output = `远端连接测试请求成功!\n${resp.result}`;
      } else {
        this.output = `请求失败: HTTP ${resp.responseCode}`;
      }
    } catch(err) {
      let e = err as BusinessError;
      this.output = `HDC 请求出错: ${e.message}\n请确保远端服务端点(${this.hdcServerIp}/api/run_cmd) 已运行。`;
    } finally {
      httpReq.destroy();
    }
  }

  // ========== Step 1: Check connection, list files ==========
  async checkServer() {
    this.output = `正在连接 ${this.serverIp} ...`;
    // 每一个httpRequest对应一个HTTP请求任务，不可复用
    let httpReq = http.createHttp();
    try {
      let resp = await httpReq.request(`${this.serverIp}/api/files`, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING,
      });
      if (resp.responseCode !== 200) {
        this.output = `连接失败: HTTP ${resp.responseCode}`;
        return;
      }
      let files: ServerFile[] = JSON.parse(resp.result as string);
      this.serverFiles = files.filter((f: ServerFile) => f.name !== 'serve_model.py');
      this.totalBytesAll = 0;

      let listing = '服务器连接成功!\n\n文件列表:\n';
      listing += '────────────────────────────────────────\n';
      for (let f of this.serverFiles) {
        this.totalBytesAll += f.size;
        let pad = ' '.repeat(Math.max(1, 28 - f.name.length));
        listing += `  ${f.name}${pad}${this.formatSize(f.size)}\n`;
      }
      listing += '────────────────────────────────────────\n';
      listing += `共 ${this.serverFiles.length} 个文件, 总大小:
  ${this.formatSize(this.totalBytesAll)}\n\n`;
      listing += '点击"下载全部"开始下载';
      this.output = listing;
      this.connected = true;
    } catch (err) {
      let e = err as BusinessError;
      this.output = `连接失败: code=${e.code} ${e.message}\n\n请检查:\n1. 服务器 python3
  serve_model.py 是否运行\n2. 防火墙是否开放端口\n3. 手机网络是否可达服务器`;
      this.connected = false;
    } finally {
      httpReq.destroy();
    }
  }

  // ========== Step 2: Stream-download one file ==========
  private downloadOneFile(file: ServerFile, index: number, fileCount: number,
    completedBytes: number): Promise<number> {
    const url = `${this.serverIp}/${file.name}`;
    const savePath = `${this.modelDir}/${file.name}`;

    // Skip if exists with correct size
    try {
      let st = fs.statSync(savePath);
      if (st.size === file.size) {
        this.output = `[${index + 1}/${fileCount}] ${file.name}
  已存在(${this.formatSize(st.size)})，跳过\n` +
          `总进度: ${this.formatSize(completedBytes + file.size)} /
  ${this.formatSize(this.totalBytesAll)}`;
        return Promise.resolve(file.size);
      }
    } catch (e) {
      // not exists
    }

    this.output = `[${index + 1}/${fileCount}] 连接: ${file.name}`;
    let self = this;
    let idx = index;
    let completed = completedBytes;

    return new Promise<number>((resolve) => {
      // 每一个httpRequest对应一个HTTP请求任务，不可复用
      let httpReq = http.createHttp();
      let fileHandle: fs.File;
      let failed = false;
      let resolved = false;

      try {
        fileHandle = fs.openSync(savePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY |
        fs.OpenMode.TRUNC);
      } catch (e) {
        self.output = `[${idx + 1}/${fileCount}] 创建文件失败: ${file.name}`;
        httpReq.destroy();
        resolve(-1);
        return;
      }

      // Helper: cleanup and resolve
      let finish = (size: number) => {
        if (resolved) return;
        resolved = true;
        httpReq.off('dataReceive');
        httpReq.off('dataReceiveProgress');
        httpReq.off('dataEnd');
        try { fs.closeSync(fileHandle); } catch (e) {}
        httpReq.destroy();
        resolve(size);
      };

      // Subscribe: stream data -> write to file
      httpReq.on('dataReceive', (data: ArrayBuffer) => {
        if (!failed) {
          try {
            fs.writeSync(fileHandle.fd, data);
          } catch (e) {
            failed = true;
          }
        }
      });

      // Subscribe: download progress
      httpReq.on('dataReceiveProgress', (data: http.DataReceiveProgressInfo) => {
        if (failed) return;
        let filePct = data.totalSize > 0 ? Math.floor(data.receiveSize * 100 / data.totalSize)
          : 0;
        let overallRecv = completed + data.receiveSize;
        let overallPct = self.totalBytesAll > 0
          ? Math.floor(overallRecv * 100 / self.totalBytesAll) : 0;
        self.output =
          `[${idx + 1}/${fileCount}] ${file.name}\n` +
            `文件: ${self.formatSize(data.receiveSize)} / ${self.formatSize(data.totalSize)}
  ${filePct}%\n` +
            `总量: ${self.formatSize(overallRecv)} / ${self.formatSize(self.totalBytesAll)}
  ${overallPct}%`;
      });

      // Subscribe: data receive complete
      httpReq.on('dataEnd', () => {
        if (failed) {
          self.output = `[${idx + 1}/${fileCount}] ${file.name} 写入失败`;
          finish(-1);
        } else {
          let fileSize = 0;
          try {
            fs.closeSync(fileHandle);
            fileSize = fs.statSync(savePath).size;
          } catch (e) {}
          self.output = `[${idx + 1}/${fileCount}] ${file.name} 完成
  (${self.formatSize(fileSize)})`;
          if (resolved) return;
          resolved = true;
          httpReq.off('dataReceive');
          httpReq.off('dataReceiveProgress');
          httpReq.off('dataEnd');
          httpReq.destroy();
          resolve(fileSize);
        }
      });

      // Issue stream request
      httpReq.requestInStream(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 60000,
        readTimeout: 7200000, // 2 hours for large files
      }).then((code: number) => {
        if (code !== 200) {
          failed = true;
          self.output = `[${idx + 1}/${fileCount}] ${file.name} HTTP ${code}`;
          finish(-1);
        }
        // if 200, wait for dataEnd
      }).catch((err: BusinessError) => {
        failed = true;
        self.output = `[${idx + 1}/${fileCount}] ${file.name} 错误: code=${err.code}
  ${err.message}`;
        finish(-1);
      });
    });
  }

  // ========== Step 3: Download all files ==========
  async downloadAll() {
    if (this.serverFiles.length === 0) {
      this.output = '请先检查服务器连接';
      return;
    }
    this.downloading = true;
    try { fs.mkdirSync(this.modelDir); } catch (e) {}

    let completedBytes = 0;
    let failed: string[] = [];

    for (let i = 0; i < this.serverFiles.length; i++) {
      let size = await this.downloadOneFile(this.serverFiles[i], i, this.serverFiles.length,
        completedBytes);
      if (size < 0) {
        failed.push(this.serverFiles[i].name);
      } else {
        completedBytes += size;
      }
    }

    if (failed.length === 0) {
      this.output = `全部下载完成!\n模型总大小:
  ${this.formatSize(completedBytes)}\n\n点击"加载模型"开始使用`;
    } else {
      this.output = `${failed.length}个失败: ${failed.join(', ')}\n已下载:
  ${this.formatSize(completedBytes)}\n再次点击可继续(已有文件跳过)`;
    }
    this.downloading = false;
  }

  // ========== UI ==========
  build() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        Scroll() {
          Column() {
            Text('MobiInfer LLM Chat')
              .fontSize(26)
              .fontWeight(FontWeight.Bolder)
              .fontColor('#0A59F7')
              .margin({ top: 20, bottom: 20 })
              .textShadow({ radius: 5, color: '#A0B9F7', offsetX: 2, offsetY: 2 })

            Scroll() {
              Text(this.output)
                .fontSize(14)
                .fontFamily('monospace')
                .fontColor('#333333')
                .width('100%')
                .padding(15)
            }
            .constraintSize({ minHeight: 120, maxHeight: 200 })
            .width('95%')
            .backgroundColor('#E6F0FF')
            .borderRadius(12)
            .margin(10)
            .border({ width: 1, color: '#B3CFFF', style: BorderStyle.Solid })

            if (this.debugImagePath !== '') {
              Row() {
                Text('Debug 截图预览:')
                  .fontSize(12)
                  .fontColor('#555555')
                  .margin({ right: 10 })
                Image(this.debugImagePath)
                  .width(120).height(180).objectFit(ImageFit.Contain)
                  .backgroundColor(Color.Black)
                  .borderRadius(8)
                  .onClick(() => { this.debugImagePath = ''; })
              }
              .margin({ top: 10, bottom: 10 })
              .width('95%')
              .padding(10)
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .shadow({ radius: 8, color: '#22000000', offsetX: 0, offsetY: 4 })
            }

            Scroll() {
              Text(this.chatHistory)
                .fontSize(15)
                .width('100%')
                .padding(15)
                .lineHeight(22)
                .opacity(this.isThinking ? 0.7 : 1)
                .animation({ duration: 500, curve: Curve.EaseInOut })
            }
            .constraintSize({ minHeight: 200, maxHeight: 350 })
            .width('95%')
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .margin(10)
            .shadow({ radius: 10, color: '#1A0A59F7', offsetX: 0, offsetY: 5 })

            Row() {
              TextInput({ placeholder: '输入消息...', text: this.userInput })
                .onChange((val: string) => { this.userInput = val; })
                .layoutWeight(1)
                .height(45)
                .backgroundColor('#F0F5FF')
                .borderRadius(22)
                .margin({ right: 10 })
                .padding({ left: 15, right: 15 })

              Button('发送')
                .height(45)
                .width(80)
                .backgroundColor(this.isThinking ? '#A0B9F7' : '#0A59F7')
                .borderRadius(22)
                .scale({ x: this.buttonScale, y: this.buttonScale })
                .animation({ duration: 200, curve: Curve.FastOutSlowIn })
                .onTouch((event) => {
                  if (event.type === TouchType.Down) this.buttonScale = 0.95;
                  if (event.type === TouchType.Up) this.buttonScale = 1.0;
                })
                .onClick(async () => {
                  if (!this.modelLoaded || this.userInput.length === 0 || this.isThinking) return;
                  let msg = this.userInput;
                  this.userInput = '';
                  this.chatHistory += `\nUser: ${msg}\nAssistant: 思考中...`;
                  this.isThinking = true;

                  try {
                    let reply = await mnnllm.chat(msg);
                    this.chatHistory = this.chatHistory.replace('Assistant: 思考中...', `Assistant: ${reply}\n`);
                  } catch(err) {
                    this.chatHistory = this.chatHistory.replace('Assistant: 思考中...', `Assistant: [错误] ${err}\n`);
                  } finally {
                    this.isThinking = false;
                  }
                })
            }
            .width('95%')
            .margin({ bottom: 20 })

            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              Button('加载大模型')
                .onClick(async () => {
                  let cfg = this.modelDir + '/config.json';
                  this.output = '加载中，请稍候...';
                  try {
                    this.output = await mnnllm.loadModel(cfg);
                    if (this.output === 'ok') {
                      this.modelLoaded = true;
                    }
                  } catch(err) {
                    this.output = '加载失败: ' + err;
                  }
                })
                .enabled(!this.downloading)
                .height(40)
                .width('30%')
                .backgroundColor(this.modelLoaded ? '#E0E0E0' : '#4CAF50')
                .fontColor(this.modelLoaded ? '#999999' : '#FFFFFF')
                .borderRadius(8)
                
              Button('单轮推理')
                .onClick(async () => {
                  if (!this.modelLoaded) { this.output = '请先加载模型'; return; }
                  this.output = '推理中...';
                  try {
                    this.output = await mnnllm.generate('你好');
                  } catch(err) {
                    this.output = '推理错误: ' + err;
                  }
                })
                .height(40)
                .width('30%')
                .backgroundColor('#2196F3')
                .borderRadius(8)
                
              Button('重置会话')
                .onClick(() => {
                  this.output = mnnllm.reset();
                  this.chatHistory = '';
                })
                .height(40)
                .width('30%')
                .backgroundColor('#FF5722')
                .borderRadius(8)
            }
            .width('95%')
            .margin({ bottom: 15 })

            Button('开始智能体执行 (输入框为任务)')
              .width('95%')
              .height(50)
              .backgroundColor('#FF9800')
              .borderRadius(10)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .margin({ bottom: 15 })
              .shadow({ radius: 8, color: '#4DFF9800', offsetX: 0, offsetY: 4 })
              .onClick(async () => {
                if (!this.modelLoaded) {
                  this.output = "请先加载模型后再运行智能体！";
                  return;
                }
                if (this.userInput.length === 0) {
                  this.output = "请在上方文本框输入任务目标，比如: '去淘宝买手机'";
                  return;
                }
                this.llmServer.currentTask = this.userInput;
                this.output = `====== 等待 PC 截图 ======\n当前任务已设定为: ${this.userInput}\nPC 脚本检测到任务后将自动开始。`;
              })

            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
              Button('启动 PC 控制后端 (HDC)')
                .height(45)
                .backgroundColor('#607D8B')
                .borderRadius(10)
                .margin({ right: 10 })
                .layoutWeight(1)
                .onClick(() => {
                  if (!this.modelLoaded) {
                    this.output = "请先加载模型！";
                    return;
                  }
                  this.llmServer.start(9126, this.filesDir, mnnllm as Record<string, Function>, (msg: string) => {
                    this.output = msg;
                    let match = msg.match(/<img>(.*?)<hw>/);
                    if (match && match[1]) {
                      this.debugImagePath = 'file://' + match[1];
                    }
                  }, async (response: string) => {
                       if (this.autoConfirm) {
                         return true;
                       }
                       return new Promise<boolean>((resolve) => {
                           promptAction.showDialog({
                               title: '大模型返回确认',
                               message: '模型推理结果：\n' + response + '\n\n是否同意执行？',
                               buttons: [
                                   { text: '拒绝', color: '#ff0000' },
                                   { text: '同意', color: '#00cc00' }
                               ]
                           }).then((data) => {
                               resolve(data.index === 1);
                           }).catch(() => {
                               resolve(false);
                           });
                        });
                      }); 
                })

              Row() {
                Checkbox({ name: 'autoConfirm', group: 'settings' })
                  .select(this.autoConfirm)
                  .selectedColor('#0A59F7')
                  .onChange((value: boolean) => {
                    this.autoConfirm = value;
                  })
                Text('自动同意').fontSize(14).fontColor('#333')
              }
              .backgroundColor('#F5F5F5')
              .padding(8)
              .borderRadius(8)
            }
            .width('95%')

            Button('Op Precision Test')
              .width('95%')
              .height(44)
              .backgroundColor('#FF9800')
              .borderRadius(10)
              .fontSize(16)
              .margin({ top: 15 })
              .onClick(() => {
                router.pushUrl({ url: 'pages/OpTest' })
              })

            Button('Runtime Logs')
              .width('95%')
              .height(44)
              .backgroundColor('#607D8B')
              .borderRadius(10)
              .fontSize(16)
              .margin({ top: 10 })
              .onClick(() => {
                router.pushUrl({ url: 'pages/LogView' })
              })

            Blank().height(40)
          }
          .width('100%')
          .backgroundColor('#F7F9FC')
        }.width('100%').height('100%')
      }.tabBar('控制台')

      TabContent() {
        Scroll() {
          Column() {
            Text('高级配置')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#333333')
              .margin({ top: 20, bottom: 15 })

            Scroll() {
              Text(this.output)
                .fontSize(13)
                .fontFamily('monospace')
                .fontColor('#444')
                .width('100%')
                .padding(15)
            }
            .constraintSize({ minHeight: 120, maxHeight: 200 })
            .width('95%')
            .backgroundColor('#E6F0FF')
            .borderRadius(12)
            .margin({ bottom: 20 })

            Column() {
              Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
                Checkbox({ name: 'modelV2', group: 'modelVersion' })
                  .select(this.isModelV2)
                  .selectedColor('#0A59F7')
                  .onChange((value: boolean) => {
                    this.isModelV2 = value;
                    this.modelDir = this.filesDir + (value ? '/modelv2' : '/model');
                    this.output = `模型路径已切换至: ${value ? 'modelv2' : 'model'}`;
                    this.modelLoaded = false;
                  })
                Text('使用 modelv2 文件夹隔离模型').fontSize(15).fontColor('#333')
              }.width('100%').margin({ bottom: 15 })

              Flex({ wrap: FlexWrap.NoWrap, alignItems: ItemAlign.Center }) {
                Text('模型下载 IP:').fontSize(14).fontColor('#666').width(95)
                TextInput({ text: this.serverIp })
                  .layoutWeight(1).height(40).backgroundColor('#F0F5FF').borderRadius(8)
                  .onChange((val: string) => { this.serverIp = val; })
              }.width('100%').margin({ bottom: 10 })

              Flex({ wrap: FlexWrap.NoWrap, alignItems: ItemAlign.Center }) {
                Text('HDC远控 IP:').fontSize(14).fontColor('#666').width(95)
                TextInput({ text: this.hdcServerIp })
                  .layoutWeight(1).height(40).backgroundColor('#F0F5FF').borderRadius(8)
                  .onChange((val: string) => { this.hdcServerIp = val; })
              }.width('100%').margin({ bottom: 10 })

              Flex({ wrap: FlexWrap.NoWrap, alignItems: ItemAlign.Center }) {
                Text('无线调试 IP:').fontSize(14).fontColor('#666').width(95)
                TextInput({ text: this.wirelessIp })
                  .layoutWeight(1).height(40).backgroundColor('#F0F5FF').borderRadius(8)
                  .onChange((val: string) => { this.wirelessIp = val; })
              }.width('100%').margin({ bottom: 15 })

              Button('测试远端 HDC 连接')
                .onClick(() => { this.testAndConnectHdc(); })
                .height(45)
                .width('100%')
                .backgroundColor('#FF9800')
                .borderRadius(8)
                .margin({ bottom: 15 })

              Flex({ wrap: FlexWrap.NoWrap, alignItems: ItemAlign.Center }) {
                Text('线程数:').fontSize(14).fontColor('#666').width(60)
                TextInput({ text: this.threadNumInput })
                  .type(InputType.Number)
                  .width(80).height(40).backgroundColor('#F0F5FF').borderRadius(8)
                  .margin({ right: 10 })
                  .onChange((val: string) => { this.threadNumInput = val; })
                
                Button('修改 Config')
                  .onClick(() => { this.updateConfigThreadNum(); })
                  .height(40).layoutWeight(1).margin({ right: 10 }).backgroundColor('#2196F3').borderRadius(8)
                
                Button('查看 Config')
                  .onClick(() => { this.showConfigJson(); })
                  .height(40).layoutWeight(1).backgroundColor('#607D8B').borderRadius(8)
              }.width('100%').margin({ bottom: 10 })

              Flex({ wrap: FlexWrap.NoWrap, alignItems: ItemAlign.Center }) {
                Text('LLM Backend:').fontSize(14).fontColor('#666').width(100)
                TextInput({ text: this.backendTypeInput })
                  .width(80).height(40).backgroundColor('#F0F5FF').borderRadius(8)
                  .margin({ right: 10 })
                  .onChange((val: string) => { this.backendTypeInput = val; })

                Button('修改')
                  .onClick(() => { this.updateConfigBackendType('llm'); })
                  .height(40).layoutWeight(1).backgroundColor('#3F51B5').borderRadius(8)
              }.width('100%').margin({ bottom: 10 })

              Flex({ wrap: FlexWrap.NoWrap, alignItems: ItemAlign.Center }) {
                Text('MLLM Backend:').fontSize(14).fontColor('#666').width(100)
                TextInput({ text: this.mllmBackendTypeInput })
                  .width(80).height(40).backgroundColor('#F0F5FF').borderRadius(8)
                  .margin({ right: 10 })
                  .onChange((val: string) => { this.mllmBackendTypeInput = val; })

                Button('修改')
                  .onClick(() => { this.updateConfigBackendType('mllm'); })
                  .height(40).layoutWeight(1).backgroundColor('#009688').borderRadius(8)
              }.width('100%')
            }
            .width('95%')
            .padding(15)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .shadow({ radius: 8, color: '#1A000000', offsetX: 0, offsetY: 2 })
            .margin({ bottom: 20 })

            Column() {
              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                Button('检查连接')
                  .onClick(() => { this.checkServer(); })
                  .enabled(!this.downloading)
                  .height(40)
                  .width('30%')
                  .backgroundColor('#4CAF50')
                  .borderRadius(8)
                
                Button('下载全部')
                  .onClick(() => { this.downloadAll(); })
                  .enabled(!this.downloading && this.connected)
                  .height(40)
                  .width('30%')
                  .backgroundColor('#FF5722')
                  .borderRadius(8)
                  
                Button('删除模型')
                  .onClick(() => { this.deleteModelFiles(); })
                  .enabled(!this.downloading)
                  .height(40)
                  .width('30%')
                  .backgroundColor('#F44336')
                  .borderRadius(8)
              }.width('100%').margin({ bottom: 15 })

              Button('仅删当前目录 Config')
                .onClick(() => { this.deleteModelConfigJson(); })
                .enabled(!this.downloading)
                .height(40)
                .width('100%')
                .backgroundColor('#FF7043')
                .borderRadius(8)
                .margin({ bottom: 15 })

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                Button('列出沙箱图片')
                  .onClick(() => { this.listScreenshots(); })
                  .height(40)
                  .width('48%')
                  .backgroundColor('#E91E63')
                  .borderRadius(8)
                  
                Button('清理截图缓存')
                  .onClick(() => { this.clearScreenshots(); })
                  .height(40)
                  .width('48%')
                  .backgroundColor('#9C27B0')
                  .borderRadius(8)
              }.width('100%')
            }
            .width('95%')
            .padding(15)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .shadow({ radius: 8, color: '#1A000000', offsetX: 0, offsetY: 2 })

            Blank().height(40)
          }
          .width('100%')
          .backgroundColor('#F7F9FC')
        }.width('100%').height('100%')
      }.tabBar('网络与设置')
    }.width('100%').height('100%')
  }
}
