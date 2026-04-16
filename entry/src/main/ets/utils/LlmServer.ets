import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent } from '@kit.AbilityKit';
import { AppStorage } from '@kit.ArkUI';

export class LlmServer {
  private server: socket.TCPSocketServer | null = null;
  private isRunning: boolean = false;
  public currentTask: string = "";

  start(port: number, filesDir: string, mnnllm: Record<string, Function>, onLog: (msg: string) => void, onRequireApproval?: (response: string) => Promise<boolean>) {
    if (this.isRunning) {
      onLog("服务已经运行中");
      return;
    }

    this.server = socket.constructTCPSocketServerInstance();
    let ipAddress: socket.NetAddress = { address: '0.0.0.0', port: port, family: 1 };
    
    this.server.listen(ipAddress, (err) => {
      if (err) {
        onLog(`【ERROR】服务启动失败，请检查端口是否被占用: ${JSON.stringify(err)}`);
        return;
      }
      this.isRunning = true;
      onLog(`====== PC 投屏控制端后台开启 ======\n监听端口：TCP ${port}，可使用 hdc fport 打通！\n现在可以在 APP 端输入任务并开始了。`);
    });

    this.server.on('connect', (client: socket.TCPSocketConnection) => {
      let bufferStr = "";
      
      client.on('message', async (data) => {
        let textDecoder = util.TextDecoder.create('utf-8');
        let str = textDecoder.decodeWithStream(new Uint8Array(data.message));
        bufferStr += str;
        
        // 我们以 <<EOF>> 作为通信帧截断符
        let eofIdx = bufferStr.indexOf("<<EOF>>");
        if (eofIdx !== -1) {
          let payload = bufferStr.substring(0, eofIdx);
          bufferStr = bufferStr.substring(eofIdx + 7);
          
          try {
            let req: Record<string, Object> = JSON.parse(payload);
            let reqType = req['type'] as string;

            if (reqType === "poll") {
              // PC 端轮询获取任务
              client.send({ data: JSON.stringify({ task: this.currentTask }) + "<<EOF>>" });
              return;
            } else if (reqType === "clear") {
               // PC 端要求清除任务（达到步数或手动终止）
               this.currentTask = "";
               // Reset agent mode if active, then normal reset
               if (mnnllm && typeof mnnllm['agentReset'] === 'function') {
                 try { await mnnllm.agentReset(); } catch(e) {}
               } else if (mnnllm && typeof mnnllm['reset'] === 'function') {
                 mnnllm['reset']();
               }
               onLog(`>> [任务被PC端终止] 当前任务已清空，并已重置大模型上下文。`);
               client.send({ data: `{"status": "ok"}` + "<<EOF>>" });
               return;
            } else if (reqType === "error") {
               this.currentTask = "";
               let errMsg = req['message'] as string || "未知错误";
               onLog(`>> [PC端执行异常] ${errMsg}`);
               client.send({ data: `{"status": "ok"}` + "<<EOF>>" });
               return;
            } else if (reqType === "agent_prefill") {
              // Agent mode: prefill fixed prefix for KV cache reuse
              let prefix = req['prefix'] as string;
              onLog(`>> [Agent Prefill] 固定前缀 Prompt (${prefix.length} chars):\n${prefix}`);
              AppStorage.set('floatText', 'Prefill 中...');
              try {
                let result = await mnnllm.agentPrefill(prefix) as string;
                AppStorage.set('floatText', 'AI Agent 运行中...');
                onLog(`>> [Agent Prefill 完成] ${result}`);
                client.send({ data: JSON.stringify({ status: "ok", result: result }) + "<<EOF>>" });
              } catch(e) {
                onLog(`>> [Agent Prefill ERROR] ${e}`);
                client.send({ data: JSON.stringify({ status: "error", message: String(e) }) + "<<EOF>>" });
              }
            } else if (reqType === "agent_step") {
              // Agent mode: erase previous step, prefill variable, generate
              let variable = req['variable'] as string;
              if (req['image_b64']) {
                // Clean up previous snapshots
                try {
                  let fList = fs.listFileSync(filesDir);
                  for (let f of fList) {
                    if (f.startsWith('agent_snapshot_')) {
                      fs.unlinkSync(filesDir + '/' + f);
                    }
                  }
                } catch(e) {}

                let ts = new Date().getTime();
                let imgPath = filesDir + `/agent_snapshot_${ts}.jpg`;
                let base64Helper = new util.Base64Helper();
                let imgBuffer = base64Helper.decodeSync(req['image_b64'] as string);

                let file = fs.openSync(imgPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
                fs.writeSync(file.fd, imgBuffer.buffer);
                fs.closeSync(file);

                let w = req['width'];
                let h = req['height'];
                let imgTag = `<img>${imgPath}<hw>${h},${w}</hw></img>`;
                onLog(`>> [Agent Step] image saved: ${imgPath} (${w}x${h})`);

                if (variable.indexOf('<image_placeholder>') !== -1) {
                  variable = variable.replace('<image_placeholder>', imgTag);
                } else {
                  variable = imgTag + variable;
                }
              }

              onLog(`>> [Agent Step] 本步变量 Prompt:\n${variable}`);
              AppStorage.set('floatText', '思考中...');
              let streamedText = '';
              try {
                let response = await mnnllm.agentStep(variable, (token: string) => {
                  streamedText += token;
                  AppStorage.set('floatText', streamedText);
                }) as string;
                AppStorage.set('floatText', 'AI Agent 运行中...');
                onLog(`>> [Agent Step] 模型推理返回结果:\n${response}`);

                if (onRequireApproval) {
                  let isApproved = await onRequireApproval(response);
                  if (!isApproved) {
                    onLog(`>> [Agent Step] User rejected action.`);
                    this.currentTask = "";
                    client.send({ data: `{"action": "error", "reason": "User rejected"}` + "<<EOF>>" });
                    return;
                  }
                }

                if (response.indexOf('"done"') !== -1 || response.indexOf('"stop"') !== -1) {
                  this.currentTask = "";
                  onLog(`>> [Agent] Task completed.`);
                }

                client.send({ data: response + "<<EOF>>" });
              } catch(e) {
                onLog(`>> [Agent Step ERROR] ${e}`);
                client.send({ data: JSON.stringify({ action: "error", reason: String(e) }) + "<<EOF>>" });
              }
            } else if (reqType === "agent_reset") {
              // Agent mode: exit and restore LLM defaults
              try {
                if (mnnllm && typeof mnnllm['agentReset'] === 'function') {
                  await mnnllm.agentReset();
                }
              } catch(e) {}
              this.currentTask = "";
              AppStorage.set('floatText', 'AI Agent 运行中...');
              onLog(`>> [Agent Reset] Agent mode disabled, LLM restored.`);
              client.send({ data: `{"status": "ok"}` + "<<EOF>>" });
            } else if (reqType === "action") {
              // PC 端发来截图，要求推理（原有 chat 模式）
              let prompt = req['prompt'] as string;
              if (req['image_b64']) {
                // 先清理之前的缓存截图，避免占满存储
                try {
                  let fList = fs.listFileSync(filesDir);
                  for (let f of fList) {
                    if (f.startsWith('agent_snapshot_')) {
                      fs.unlinkSync(filesDir + '/' + f);
                    }
                  }
                } catch(e) {}

                // 生成带有时间戳的文件名，防止 C++ 模型底层因路径相同而缓存不刷新图片
                let ts = new Date().getTime()
                let imgPath = filesDir + `/agent_snapshot_${ts}.jpg`;
                let base64Helper = new util.Base64Helper();
                let imgBuffer = base64Helper.decodeSync(req['image_b64'] as string);

                let file = fs.openSync(imgPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
                fs.writeSync(file.fd, imgBuffer.buffer);
                fs.closeSync(file);

                let w = req['width'];
                let h = req['height'];
                let imgTag = `<img>${imgPath}<hw>${h},${w}</hw></img>`;
                onLog(`>> [Debug] req['width']: ${w}, req['height']: ${h}, imgPath: ${imgPath}`);

                if (prompt.indexOf('<image_placeholder>') !== -1) {
                  prompt = prompt.replace('<image_placeholder>', imgTag);
                } else {
                  // 如果 prompt 中没有占位符，作为兜底依然加在最前面
                  prompt = imgTag + '\n' + prompt;
                }
              }

              onLog(`>> [接收到 PC 发来的推理请求(含图片)]\n原始文本任务: ${req['prompt'] as string}\n构造给大模型的完整 Prompt:\n${prompt}`);
              AppStorage.set('floatText', '正在推理...');
              let response = await mnnllm.chat(prompt) as string;
              AppStorage.set('floatText', 'AI Agent 运行中...');
              onLog(`>> [模型推理返回结果]: \n${response}`);

              if (onRequireApproval) {
                 onLog(`>> [等待用户确认] 弹窗已展现...`);
                 let isApproved = await onRequireApproval(response);
                 if (!isApproved) {
                    onLog(`>> [用户拒绝] 已丢弃该动作并通知 PC 端终止。`);
                    this.currentTask = "";
                    client.send({ data: `{"action": "error", "reason": "User rejected"}` + "<<EOF>>" });
                    return;
                 }
                 onLog(`>> [用户同意] 动作已放行。`);
              }

              // 简单的正则检查，如果是 done 或者 stop，就自动清空任务停止
              if (response.indexOf('"done"') !== -1 || response.indexOf('"stop"') !== -1) {
                 this.currentTask = "";
                 onLog(`>> [任务完成] Agent 停止。`);
              }

              onLog(`>> [下发至 PC]: \n${response}`);
              client.send({ data: response + "<<EOF>>" });
            }
          } catch(e) {
            onLog(`【ERROR】处理请求失败: ${e}`);
            client.send({ data: `{"error": "Failed"}` + "<<EOF>>" });
          }
        }
      });
    });
  }
}
