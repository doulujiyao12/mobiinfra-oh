# ClawMate 录音同步协议 v1

## 通道与身份

- 通信使用 `@kit.WearEngine`，UTF-8 JSON 消息，每条最多 4096 字节；音频使用原生 `transferFile`，不将 WAV 转为 JSON/Base64。
- 手表对端：包名 `com.coevomind.clawmate`，手机 AGC APP ID `6917613102135452205`。
- 手机对端：包名 `com.coevomind.clawmate`，手表与手机共用 AGC APP ID `6917613102135452205`。正式包与调试包均需使用该应用对应的 Profile；修改代码常量不能替代签名身份。
- 接收器按“已配对设备 randomId + 对端包名 + APP ID”注册。不同配对手机分别记录接收确认。
- `sourceId` 是手表 App 首次初始化同步存储时生成并持久化的 UUID。手机应使用 `sourceId + recordingId` 定位音频，避免不同手表或重装后的数据混淆。

## 公共信封

```json
{
  "protocol": "clawmate.recordings",
  "version": 1,
  "type": "HELLO",
  "requestId": "phone_1"
}
```

请求 ID 为 1–64 位字母、数字、下划线或连字符。响应携带相同 `requestId` 和手表 `sourceId`。主动状态通知/传输错误的 `requestId` 为空。客户端应忽略不匹配的消息和未支持的版本。

## 请求与响应

| 请求 | 参数 | 成功响应 |
| --- | --- | --- |
| `HELLO` | 无 | `HELLO_RESULT`，必须首先完成握手 |
| `LIST_RECORDINGS` | `cursor`，默认空；`limit`，1–8，默认 6 | `RECORDINGS_LIST`：`recordings`、`nextCursor` |
| `GET_RECORDING` | `recordingId` | `RECORDING_OFFER`：录音信息、`transferId`、`sha256`、`bytes` |
| `READY_RECORDING` | `transferId` | `TRANSFER_STATE`，随后通过文件通道发送完整 WAV |
| `ACK_RECORDING` | `recordingId`、`transferId`、`sha256`、`bytes` | `RECORDING_ACKED`，已持久化确认 |
| `CANCEL_TRANSFER` | `transferId` | `TRANSFER_CANCELLED`，音频不删除 |
| `GET_STATUS` | 无 | `TRANSFER_STATE`：当前 ID、阶段、进度 |

列表只包含完成的 `.wav`，不包含采集中/待恢复的 `.wav.part`。`recordingId` 是本 App 自己生成并严格校验的文件名，不接受任意路径。列表使用时间和 ID 的稳定游标；新增录音不会使后续分页偏移，游标对应文件被删除后仍可继续。

录音元数据包括 `id`、`createdAt`（Unix 毫秒）、`durationMs`、`bytes`、`sampleRate`、`channels=1`、`bitsPerSample=16`、`mimeType=audio/wav`、`mode`（sound/speech/manual）、`synced`。响应不包含沙箱路径或文件描述符。SHA256 在请求该录音时由独立 Worker 计算，不在列表查询时遍历哈希所有音频。

## 文件接收闭环

1. 手机先注册消息和文件接收器，再拉起手表应用并发送 `HELLO`。
2. 手机分页查询，选定 ID 发送 `GET_RECORDING`。
3. 手表验证文件头与长度，计算 SHA256，持久化待确认票据，返回 `RECORDING_OFFER`。此时尚未发文件。
4. 手机安装好“等待该文件”的处理逻辑后，发送 `READY_RECORDING`。同时只允许一项传输。
5. 手表打开只读描述符并调用原生 `transferFile`，描述符保持到终态/取消。SDK 进度 100% 不能替代终态成功码 207。
6. 手机将收到的文件复制到自己的 `.part`，比对完整文件大小与 SHA256，fsync 后重命名为正式 WAV。
7. 手机发送 `ACK_RECORDING`。手表校验配对手机、票据、ID、哈希与大小，原子替换并 fsync 同步记录后返回 `RECORDING_ACKED`。
8. 手表原始 WAV 始终保留，删除仍由用户操作。

手机已持有大小和哈希均相符的正式副本时，可直接对 OFFER 确认而不发送 READY，从而避免重复传输。手机不能仅根据列表 `synced=true` 跳过文件：手机 App 数据可能被清除。

## 故障与重试

- 消息发送失败最多重试三次。手机请求重试使用同一请求 ID。
- 重复 GET 在同一待发送任务中返回相同票据；重复 READY 不会启动第二个文件发送；重复 ACK 幂等。
- 同步确认落盘前失败不会标记“已同步”。确认落盘但回复丢失后，重复 ACK 会再次返回成功。
- 重连后先 HELLO，再 GET 同一文件，可重用同手机、同文件、同 SHA256 的待确认票据。若手机文件已保存，可直接重新确认。
- 提供文件传输取消、60 秒 READY/ACK 等待超时、180 秒无传输进度超时，以及 5–60 秒的连接重试退避。应用被系统挂起时不保证定时重连，重新打开应用会继续连接。
- 当前为整文件重传，不支持按字节偏移断点续传。最多发送 100 MiB；应用正常五分钟录音约 9.6 MB（16 kHz）或 28.8 MB（48 kHz）。
- 本地确认日志最多保留最近 8000 条，淘汰只影响状态显示，不删除录音；手机已有副本仍可校验去重。

错误统一返回 `type=ERROR`，常见 `code`：`HELLO_REQUIRED`、`BAD_REQUEST`、`UNSUPPORTED_PROTOCOL`、`BUSY`、`INVALID_RECORDING`、`NOT_FOUND`、`FILE_CHANGED`、`ACK_MISMATCH`、`UNKNOWN_TRANSFER`、`TRANSFER_FAILED`、`TRANSFER_TIMEOUT`、`STORAGE_ERROR`。错误不等于录音已丢失。

## 已验证与未验证

本次多端迁入只完成静态检查，尚未对合入后的工程重新构建或执行测试。以下为独立手表工程的历史验证记录，不代表合入版本已经通过。

已通过主机上的双方真实源代码、真实文件系统和模拟 Wear Engine 传输测试，以及 HarmonyOS SDK 的 HAP/HAR 编译。无线传输、华为服务审批、签名身份校验、真机熄屏/后台限制和实际吞吐仍需手机与 WATCH 6 Pro 联调。
