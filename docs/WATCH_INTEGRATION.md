# ClawMate 手机与手表多端工程

手机和手表使用同一应用身份，按设备分别构建入口 HAP，正式发布合成一个 App Pack。

| 项目 | 值 |
| --- | --- |
| 包名 | `com.coevomind.clawmate`，以 `AppScope/app.json5` 为准 |
| AGC APP ID | `6917613102135452205` |
| 手机模块 | `entry`，`phone`，入口 `EntryAbility` |
| 手表模块 | `watch_entry`，`wearable`，入口 `HiWearMainAbility` |
| 手机接收库 | `phonebridge` / `@clawmate/watch-bridge`，仅手机入口依赖 |

## 模块边界

- `entry` 保留手机 UI、本地 MNN/HiAI 推理、录音管理及转写流程。
- 手表“录音模式”中，环境声音和人声各自支持“灵敏 / 正常 / 严格”，独立保存，已有用户默认保持正常。人声使用 WebRTC VAD 1 / 2 / 3；环境声音开始阈值分别为背景噪声 +6 / +10 / +14 dB，限制在 −48～−30 / −42～−24 / −36～−18 dBFS，维持阈值更低以避免频繁开关。三档均保持 200 ms 窗口内至少 6 帧触发、1 秒预录和 2 秒无人声/声音尾音；仅在未录音时可调整。
- `watch_entry` 保留默认声音触发保存、可选 WebRTC VAD 人声检测、WAV 异常恢复、列表播放删除和 Wear Engine 文件发送。一次开始到结束只生成一条录音，静音暂停写入后继续追加同一文件，不再按五分钟分段；单次六小时、空间不足和系统中断的保护仍保留。录音库支持按本地日期筛选，以及对当前列表多选、全选和确认批量删除；正在同步的录音会保留，部分文件删除失败不阻断其他已选择文件。采集和同步 IO 分别在模块自己的 Worker 中执行。
- 手机默认对本次成功接收的全部录音依次用 SenseVoice 转写、生成摘要，复用已完成结果；不改变手机现场录音的系统/SenseVoice 选择。SenseVoice 模型未就绪时，先保存本批录音并打开模型下载界面，下载或导入成功后继续处理；离开页面或停止可取消待处理队列。单条失败会保留结果并继续下一条，可手动停止。后续阶段使用实际完成并保存的记录，避免依赖 UI 选中对象是否仍是原引用。新版手机和手表同步时使用文件大小和 WAV 文件头检查，跳过 SHA-256 的整文件计算。手机接收上限与录音库一致（小于 2 GiB）。历史分段录音保留原样，不推测归属后自动合并。
- 手表首次启动显示应用 `clawmate`、开发者 `冯二虎` 的隐私提示。完整政策入口和二维码均指向开发者在应用市场提交的同一托管网址；主界面保留隐私政策入口。同意并保存前不初始化录音 Worker、Wear Engine 连接与同步；不同意退出。隐私确认独立保存在手表本机，只在政策版本改变时重新确认，普通应用升级不重置。同意提示与删除确认使用圆屏安全区域弹层，正文可滚动，按钮固定在弹层内。送审前应同步核对托管政策对实际手表录音、手机同步处理范围的说明。
- `phonebridge` 是接收端唯一实现。手机原来的 `utils/recording/WatchRecordingClient.ets` 是兼容导出，既有页面和存储逻辑无需迁移。
- 两端入口不互相依赖，手机原生推理库不会作为手表依赖。人声检测库仅在手表模块编译。
- 共享应用名已从旧的“数据归家”统一为 `ClawMate`，与手机和手表启动入口名称一致。
- 公共版本号由根 `AppScope/app.json5` 管理。此次合入保留手机当前版本号，不擅自提高版本。
- 根产品保留手机的 API 24 目标 SDK、API 20 最低兼容版本和本机签名配置。迁入的手表模块继承这一产品设置；原独立手表工程的 API 18 最低版本不再单独生效。当前集成目标为 WATCH 6 Pro，不代表支持 GT/FIT 或所有旧款手表。

## 首次打开

1. DevEco Studio 打开本仓库根目录。已有的本机 `build-profile.json5` 已登记 `entry`、`watch_entry`、`phonebridge`；首次克隆可复制 `build-profile.example.json5` 为 `build-profile.json5`，再配置自己的签名。
2. 执行工程依赖同步 / Sync Now，让 OHPM 解析 `entry -> file:../phonebridge` 和手表模块的 `libvoicevad.so` 本地类型依赖。锁文件由 OHPM 在同步时更新，本次迁入未手写依赖解析结果。
3. 在 File → Project Structure → Signing Configs 中确认调试签名。两端调试包均须使用现有 ClawMate 应用对应的 Profile；手动维护调试 Profile 时包含两台设备的 UDID。
4. 共享配置位于 `.run/ClawMate_Phone.run.xml` 和 `.run/ClawMate_Watch.run.xml`，使用本机 DevEco 已有的 `OhosDebugTask` 配置类型。若 IDE 尚未显示，重新同步或在 Run → Edit Configurations 中按下表添加。

## 分别下发与调试

| 运行配置 | General → Module | Launch | 工具栏目标设备 |
| --- | --- | --- | --- |
| ClawMate Phone | `entry` | Default Ability（`EntryAbility`） | 手机，通常 USB 连接 |
| ClawMate Watch | `watch_entry` | Default Ability（`HiWearMainAbility`） | WATCH 6 Pro，WLAN/HDC 连接 |

先选运行配置，再选对应设备，点击 Run 或 Debug。每个配置只部署本端入口及其依赖，不勾选另一端入口进行多 HAP 部署。运行前检查 Keep Application Data 设置，按需要保留设备上的已有数据。

修改手表代码时选择 ClawMate Watch；修改手机代码时选择 ClawMate Phone。构建完整 App Pack 是发布操作，日常调试不需要每次同时部署两端。

此前出现的 `Required device type: phone, current module device type: wearable` 属于模块与目标设备不匹配，应该切换运行配置/目标设备。手表模块保持 `wearable`。

从原独立手表版本升级前，先备份重要录音。此次模块名从 `entry` 改为 `watch_entry`，签名身份也统一到手机应用，旧版覆盖安装与旧模块沙箱数据访问尚未真机验证。Keep Application Data 不代表已经完成旧数据迁移；不要直接通过卸载或清数据处理签名安装错误。

## 同一身份与同步

两端对端包名都是 `com.coevomind.clawmate`，对端 APP ID 都是 `6917613102135452205`。Wear Engine 使用设备 ID 区分手机和手表；同一 APP ID 不会自动完成录音同步，仍由现有协议实现。

- 手表配置：`watch_entry/src/main/ets/config/PhonePeer.ts`。
- 手机客户端默认对端：`phonebridge/src/main/ets/WatchRecordingClient.ets`。
- 同步协议：[WATCH_SYNC_PROTOCOL.md](WATCH_SYNC_PROTOCOL.md)。

代码常量不能改变真实签名身份。原独立手表调试 Profile 中的 `6918741287274941281` 不用于这个集成版本；使用 AGC 现有手机应用对应的 Profile，不复制独立工程的签名材料。

手机现有录音页面负责发现手表、接收并还原 WAV、导入手机录音库。原始音频仍保留在手表，手机已有的本地删除标记仍被尊重，不会因同步重新下载。

### 录音传输编码

新版手机协商 AAC 接收能力后，手表优先使用系统 AAC-LC 编码器，单声道 48 kbps，采样率保持原录音的 16/48 kHz。AAC 使用标准 ADTS 文件传输，手机依据文件头识别 AAC、gzip 或 WAV。录音结束后在原生异步任务中预先编码，重新开始录音会取消预编码。编码结果按源文件大小、修改时间缓存，同步和重试可直接复用。目录锁协调录音 Worker 与同步线程，防止同一条录音重复转码；删除原录音时清理缓存，重启时清理中断的临时文件和锁。

手机接收 AAC 后还原为单声道 16 位 WAV，现有播放、SenseVoice 转写、摘要流程继续读取 WAV。AAC 是有损传输，原始 WAV 保留在手表。解码保留编码器的首尾填充，以免截掉语音，允许最多 8192 字节的附加 PCM。单独保存来源大小与还原大小，使这部分填充不会导致重复下载。新版两端不计算整文件 SHA-256。

系统不具备 AAC 编码能力、编码失败或编码后文件更大时，按双方能力回退为 gzip/WAV。手机解码 AAC 失败会取消当前传输，并关闭本连接的 AAC 协商后自动重试一次。旧客户端不协商 AAC，继续使用既有传输方式。同步界面分别显示压缩、传输、还原和保存阶段。

选型比较采用源码与官方 API 评估。Opus 适合更低码率的人声传输，但本工程目标设备的系统 Opus 编码能力与封装版本尚未验证。FLAC 可无损还原，但文件大小取决于噪声和录音内容。AAC 通过现有系统编解码接口接入，避免引入独立编解码器发行包。以十分钟单声道 16 kHz/16 bit 录音计算，原始 WAV 音频约 19.2 MB，48 kbps AAC 音频数据约 3.6 MB，均不含额外封装开销；这是码率计算值。实际编码耗时、耗电、传输时间及识别准确率需要真机测量。

系统音频能力依据 [音频编解码支持格式](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/avcodec-support-formats/) 与 [音频编码指导](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/audio-encoding/)。AAC 默认带 ADTS 输出，配置 ADTS 参数仅应用于解码器，参见 [AVCodec 常见问题](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/avcodec-kit-faq-0001/)。

## 静态检查与后续验证

本次合入不执行 Hvigor 构建、签名、安装、设备运行或 SDK 转译测试。可执行不产生编译产物的静态集成检查：

```powershell
$env:DEVECO_HOME = 'D:\download\deveco\DevEco Studio'
node scripts/check-watch-integration.mjs
```

脚本检查模块登记、设备范围、本地 HAR 依赖、导出兼容性、两端 APP ID、Worker 路径、资源、原生依赖边界和运行配置，并核对本机 Profile 中可读取的公开 APP ID。不会打印签名材料。

独立手表工程的主机测试与音频样本已迁至 `tests/watch`，并调整为加载 `watch_entry` 和 `phonebridge`。这批测试在本次合入中未执行。得到明确构建授权后，可先分别编译手机和手表，再生成完整 `.app`，最后进行真实蓝牙、熄屏、长时功耗和文件校验联调。历史独立工程测试结果不代表本次集成已经验收。

## 发布与备案

1. 在现有 ClawMate 应用中保留手机支持并增加“智能手表”，无需为此新建 `.watch` 包名或新 APP ID。审核中的版本不能直接修改；等待现有版本完成后创建升级草稿，或自行决定撤销当前提审后修改。
2. 使用该应用对应的有效发布证书和发布 Profile，构建同时包含手机、手表入口的 Release `.app`。本机现有配置不等于已经配置好正式发布签名，提交前自行核对。
3. 同一 App Pack 的版本号和完整包需统一维护。华为当前规则下，已上架手表品类后，每次更新会按已上架品类进入审核，手机/手表发布可能互相影响。
4. 信息一致时通常可沿用现有鸿蒙备案；包名、应用名称、主体、公钥/签名或其他备案字段有变化时，按原接入商要求变更。合并代码不会代为修改备案或发布后台。
5. 手表的录音触发模式仍持续占用麦克风。此次已修正权限文案中的“仅保存在手表”，但完整隐私政策入口、首用告知、Wear Engine 能力开通和正式签名联调仍需在上架前核对。

官方参考：[多设备工程部署与发布](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-multi-device-ide/)、[运行调试配置](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-run-debug-configurations/)、[审核与备案 FAQ](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/appgallery-kit-faq-0013/)、[备案指引](https://developer.huawei.com/consumer/cn/doc/app/50130/)。
