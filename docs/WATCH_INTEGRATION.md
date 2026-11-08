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
- `watch_entry` 保留默认声音触发保存、可选 WebRTC VAD 人声检测、WAV 分段恢复、列表播放删除和 Wear Engine 文件发送。采集和同步 IO 分别在模块自己的 Worker 中执行。
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

手机现有录音页面负责发现手表、接收并校验 WAV、导入手机录音库。原始音频仍保留在手表，手机已有的本地删除标记仍被尊重，不会因同步重新下载。

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
