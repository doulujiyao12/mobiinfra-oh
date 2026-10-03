# 小艺 A2A 双向接入调研与版本兼容方案

更新日期：2026-09-29。本文基于华为公开文档和当前仓库源码做静态调研，尚未接入小艺开放平台，也未在设备上验证。

## 目标与结论

目标有两个方向，接入方式不同：

| 方向 | 官方开放路径 | 对本项目的意义 |
| --- | --- | --- |
| 小艺调用本应用 | 小艺开放平台的**端 A2A Agent**，应用提供 `AgentExtensionAbility`、AgentCard 和消息处理；若能力已部署在服务器，可选云 A2A | 优先用端 A2A 读取手机沙箱中的个人记忆。云 A2A 无法天然访问本机记忆，需要另建授权同步链路。 |
| 本应用调用小艺 | Agent Framework Kit 的 `FunctionComponent` 可在应用内拉起指定智能体，并可配置 `agentId`、`queryText` | 适合让用户进入小艺对话。已核查的公开接口尚不足以确认第三方 App 能在后台调用通用小艺并取得机器可读结果。此需求应向华为确认开放范围。 |

端 A2A 和云 A2A 是华为列出的不同接入模式。[华为 Harmony Intelligence 概览](https://developer.huawei.com/consumer/cn/harmonyos-ai)；[端 A2A 平台配置步骤](https://developer.huawei.com/consumer/cn/doc/service/device-a2a-0000002640106106)；[Agent Framework Kit 接口变更说明](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/js-apidiff-agentframeworkkit-6003)。

## 当前项目可复用的部分

- `entry/src/main/ets/datamanager/DataManagerQueryEventsTool.ets`：已有 `query_events` 检索工具，可作为个人记忆查询的业务入口。
- `entry/src/main/ets/utils/ChatToolRegistry.ets`：已有聊天工具定义与执行封装，但其 OpenAI 工具调用格式不是小艺 A2A 报文，需新增协议适配层。
- `entry/src/main/ets/pages/Index.ets`：注册了 `query_events` 与手机 GUI 任务工具；GUI 操作已有用户确认流程。A2A 入口不应绕过现有授权与确认。
- `entry/src/main/ets/utils/CloudModelClient.ets`：现有云模型客户端使用聊天模型接口，不能仅替换 URL 就用于小艺 A2A。
- `entry/src/main/module.json5`：目前未注册 Agent Extension。

## 推荐接入流程

1. **限定首批技能。**先开放“查询某段时间的个人记录”和“总结上周记录”等只读能力。返回必要摘要和来源，不默认返回身份证号、家庭住址等高敏感字段。写入、分享和手机 GUI 操作要另行授权并保留逐次确认。
2. **实现端 A2A 入口。**注册 Agent Extension、配置 AgentCard，并增加独立的消息适配层。该层校验请求、身份和技能范围，将请求转换为内部业务调用，再按平台协议返回状态和结果。API 24 的 `AgentExtensionAbility` 提供 `onData`、`onAuth` 等回调，`AgentHostProxy` 提供 `sendData` 与 `authorize`；新版本 Agent Framework Kit 还提供 `createA2AServer`、任务状态与 Artifact 封装。具体选型以目标 SDK 和小艺开放平台当前技术规范为准。[AgentExtensionAbility API 变更清单](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/js-apidiff-abilitykit-6111)、[AgentHostProxy API](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/js-apis-inner-application-agenthostproxy)、[Agent Framework Kit A2A API 变更清单](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/js-apidiff-agentframeworkkit-7002)。
3. **在小艺开放平台注册。**创建端 A2A Agent、关联此应用和模块、填写服务名称、导入 AgentCard、配置示例问题，之后按平台流程调试和上架。[端 A2A 模式文档](https://developer.huawei.com/consumer/cn/doc/service/device-a2a-0000002640106106)。
4. **按需增加应用内的小艺入口。**`FunctionComponent` 可拉起已上线的指定智能体；这属于用户可见对话，不应当作现有 Agent 的后台问答工具。[Agent Framework Kit 接口变更说明](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/js-apidiff-agentframeworkkit-6003)。
5. **需要远程服务时再评估云 A2A。**云端 Remote Agent 要处理平台协议、会话、消息、鉴权与任务结果。AK/SK 应留在服务器；若需访问个人记忆，应设计单独的用户授权与同步机制。[华为云 A2A 开发课程说明](https://developer.huawei.com/consumer/cn/monthly/202608)。

协议报文和 AgentCard 字段应以小艺开放平台最新《AgentCard 定义规范》《端 A2A 协议技术规范》为准，不要直接把现有 OpenAI Chat Completions 工具格式或通用开源 A2A SDK 格式当作小艺协议。平台文档仍有更新。[小艺开放平台文档变更记录](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/update1-0000001238499957)。

## SDK 与手机系统兼容性

当前 `build-profile.json5` 配置：

| 配置 | 当前值 | 作用 |
| --- | --- | --- |
| `targetSdkVersion` | `6.1.1(24)` | 应用声明适配的目标 API，影响部分系统行为和兼容策略。 |
| `compatibleSdkVersion` | `6.0.0(20)` | 应用声明支持的最低系统 API。 |
| `compileSdkVersion` | 未显式指定 | 使用构建工具配套的 SDK；不能仅凭仓库配置推断所有开发机的实际编译版本。 |

本机 DevEco SDK 清单中的 OpenHarmony/HMS ETS 均为 **6.1.1.125、API 24 Release**。这是本机检查结果，不代表项目已经升级或编译成功。

2026-09-30 已将本机工程的目标 API 调整为 24，最低兼容 API 仍为 20。根目录 `build-profile.json5` 含本机签名配置并被 Git 忽略，其他开发机需要在各自的本地配置中应用相同版本设置。

**结论：要在应用中使用 API 24 的 `AgentExtensionAbility`，编译所用 SDK 至少需要提供 API 24 声明。**当前目标 API 24、最低兼容 API 20；后续仍需验证 API 24 SDK 下的编译与平台接入。API 24 的 AgentCard、AgentHostProxy 等类型与接口均标明从 API 24 起支持。[华为 Ability 公共类型参考](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/js-apis-app-ability-common)、[AgentHostProxy API](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/js-apis-inner-application-agenthostproxy)。

**提高编译 SDK 或目标 API，不必自动提高最低兼容 API。**华为升级指南说明，可用 `compatibleSdkVersion` 保留对较早系统的支持；但新 API 在未升级的设备上可能不可用，需要做兼容处理，并在新旧系统设备上验证。[华为应用升级与适配指南](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/upgrade-adaptation)。因此可研究保持最低兼容 API 20：API 24 以下继续运行原有聊天和记忆功能，隐藏或禁用端 A2A 入口；API 24 及以上才启用端 A2A。**这需要实际验证新 Agent Extension 注册在同一应用包内时，API 20～23 系统仍能安装、启动、使用旧功能**，不能只依赖代码中的版本判断作保证。

如果直接把 `compatibleSdkVersion` 提高到 API 24，则 API 20～23 手机不再处于该安装包声明的兼容范围，旧系统用户需要升级手机系统才能安装或更新该版本。现有已安装版本是否继续可用与更新分发是不同问题，应在发布策略中分别处理。旧手机能否升级到 API 24 则取决于其设备型号和系统更新支持。

另需区分 API 24 的底层 Agent Extension 与较新的 `createA2AServer` 封装；后者不能反推前者一定要求 API 26。小艺开放平台的实际端 A2A 准入版本、可调用范围及设备侧支持，仍需在平台配置与目标手机上确认。若平台要求更高系统版本，旧手机仍可保留普通 App 功能，但不能使用相应的小艺端侧能力。

## 建议验证清单

1. 确认小艺开放平台当前端 A2A 技术规范和最低设备系统要求。
2. 用 API 24 SDK 做独立的 Agent Extension 最小样例，保持最低兼容 API 20，检查编译告警与打包结果。
3. 在 API 20～23 与 API 24+ 设备上分别验证安装、冷启动、原有聊天和记忆查询；在支持的设备上验证小艺调用、身份校验与撤销授权。
4. 对身份证号、地址等敏感记忆做逐项授权、结果脱敏和调用记录；对 GUI 副作用继续执行现有确认流程。

本调研没有修改 SDK 配置、安装应用或运行构建。

## 2026-09-30：个人记忆端 A2A 代码接入

本次已在 `entry` 注册 `PersonalMemoryAgentAbility`（`type: agent`，元数据名 `ohos.extension.agent`），并新增 `resources/base/profile/agent_config.json`。Agent ID 是 `clawmate_personal_memory`，技能 ID 是 `read_personal_memory`。这是**手机本机记忆**的只读入口，不需要把索引上传到开发者服务器。扩展在 `onData` 中处理 `tasks/send` 和 `message/send` 文本消息，并在 2026-10-01 增加了小艺端消息结构的适配；`onAuth` 返回开关状态，实际查询时再次校验授权。代码基于 API 24 的 Agent Extension 与 AgentHostProxy 声明实现。[OpenHarmony Agent Extension 开发说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-models/agent-extension-ability.md)、[AgentCard 配置说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-models/agent-extension-configuration.md)。

用户必须先同意应用隐私声明，再到**我的 → 个人与隐私 → 小艺读取个人记忆**开启开关。开关默认关闭；关闭或撤回隐私同意后不再返回记忆。查询复用现有记忆索引，不再固定到个人信息场景 `scene_id=12`；外卖、购物、微信消息及其他已索引事件均可按问题读取。每次最多返回五条摘要，证件号码、手机号、详细住址等记录不经此入口返回。外卖类问题使用外卖场景索引；微信类问题使用已有的正文或来源关键词索引。只读查询仍依赖应用现有的**手动同步**与关键词索引；未同步的聊天内容、微信原始消息 JSON/Markdown 和完整聊天记录不经此入口读取。本次不改变应用内 Agent 的入口和检索策略。
隐私声明版本已更新到 `2026-09-30-v2`，旧版同意会失效，用户需重新阅读并选择。小艺开关也增加了授权范围版本；之前只授权个人信息的设备必须再次主动打开开关，才能开放所有已索引记忆。

### 你需要在浏览器与手机完成的操作

1. 在华为开发者联盟 / AppGallery Connect 确认应用所属账号与包名。当前工作区 `AppScope/app.json5` 的包名是 `com.example.mnnllmchat`，模块名是 `entry`，扩展服务名是 `PersonalMemoryAgentAbility`。以准备发布的实际签名应用为准，平台关联时务必完全一致。
2. 登录[小艺开放平台](https://developer.huawei.com/consumer/cn/doc/service/device-a2a-0000002640106106)，新建**端 A2A 模式** Agent，关联上述应用与模块，填写服务名称 `PersonalMemoryAgentAbility`，导入项目里的 `entry/src/main/resources/base/profile/agent_config.json`。按平台页面提示设置示例问题和发布资料；若导入器不接受本地图标引用 `$media:Icon`，需替换为平台支持的正式图标 URL。华为页面列出的顺序是创建、关联应用、导入 AgentCard、配置输入文件与快捷指令。[端 A2A 创建步骤](https://developer.huawei.com/consumer/cn/doc/service/device-a2a-0000002640106106)。
3. 在平台打开最新《AgentCard 定义规范》和《端 A2A 协议技术规范》，核对 `tasks/send`、认证握手和返回字段。这些文档的具体报文正文当前公开检索页面未完整提供，**本次协议适配尚未通过小艺真机互通验证**。平台若要求不同字段，需要按真机测试报文调整 `PersonalMemoryA2aProtocol.ets` 和 `PersonalMemoryAgentAbility.ets`；不能仅凭 AgentCard 导入成功认定协议打通。
4. 在支持端 A2A 的 API 24 或更新系统手机上安装对应签名的应用，先在应用中同步可测试的个人信息、外卖和微信消息摘要，再同意新版隐私声明并开启授权开关。通过小艺开放平台真机测试发送“我之前说过的生日是什么？”、“我上次点了什么外卖？”、“我最近的微信聊天里提到了什么？”，核对回复。再测试旧授权迁移、开关关闭、隐私撤回、身份证号或住址询问均不泄露个人内容。[真机测试说明](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/list-of-user-groups-for-real-machine-testing-0000002471264273)。
5. 确认真机互通、隐私说明和审核资料后，在小艺开放平台发起上架审核；平台上架和 AppGallery Connect 的应用版本分发分别操作。[智能体上架流程](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/process-introduction-0000002509696971)。

当前只做了静态核对，**未运行 DevEco/Hvigor 编译、安装或真机测试**。本机配置的目标 API 24 与最低兼容 API 20 没有因本次代码改动改变；API 20–23 设备安装新包的兼容性仍须真机验证。

## 2026-10-01：根据小艺真机超时日志修正消息格式

手机侧日志显示，小艺发出的是包含 `messageId`、数字角色 `role: 1` 和 `parts: [{ text, mediaType: "text/plain" }]` 的消息，随后报 `-32101 timeout was reached`。此前端侧解析器只识别带 `method` 的请求，且文本消息只接受字符串角色和带 `kind` / `type` 的 part。现已兼容日志中的端消息结构，无论它直接到达 `onData`，还是包在 `message/send` 请求里，答复均使用数字角色 `role: 0` 和 `text/plain` 文本 part，并沿用请求中的 `contextId`；原有 `tasks/send` 与字符串角色的 `message/send` 处理仍保留。普通“我做了哪些事”问题现在读取最近的已索引摘要。新增的 `XiaoyiA2A` 日志只记录生命周期、授权和发送状态，不记录用户问题或记忆正文。[华为 Agent Framework Kit 消息与角色声明](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/js-apidiff-agentframeworkkit-7002)。

这次**没有改 AgentCard、Agent ID、包名、模块名或扩展服务名**。小艺开放平台上已关联的端 A2A 智能体通常不需要重新导入 AgentCard 或重填应用信息。需要把修改后的应用重新构建、签名并安装到测试手机，再以已启用的真机调试用户重试。如果平台的真机测试发布已过有效期，应按平台流程重新发布测试版本。若仍超时，请读取 App `MobiInfra` 标签下的 `[XiaoyiA2A]` 日志：是否出现 `Agent Extension created`、`authorization requested`、`request received`、`response sent`，可区分未连接、授权未完成、请求未到达以及回包未送出。客户端日志只能证明小艺发起了消息，不能证明 `onData` 收到的字节与客户端显示的结构完全相同；协议格式仍须以实际真机互通结果为准。

### 2026-10-01 真机复测后的进一步处理

09:56:07 的手机 HiLog 显示 `[XiaoyiA2A] request received` 后约 2 毫秒出现 `request parsing or authorization failed`。这证明请求已到达 ClawMate 的 Agent Extension；现有日志仍无法区分解析异常与读取授权偏好异常。代码现已分别记录 `parse failed` 的固定错误类别与报文外层结构，以及 `authorization preference read failed`。诊断日志不包含用户问题、消息 part 文本、请求 ID、metadata 或记忆内容。

解析器进一步支持 `tasks/send` 的 `params.message` 文本问题（原先仅支持 `params.task.query`）。解析失败时，如输入是带请求编号的 JSON-RPC，回退错误也会带原 `id` 和 `jsonrpc: "2.0"`，避免旧版无编号错误无法与请求对应。此修改未改变 AgentCard 和小艺平台配置。需要重新构建并安装后，再在小艺中发送问题，读取新的 `MobiInfra` / `XiaoyiA2A` 日志，以实际 `onData` 字段结构确认剩余协议差异；本次未编译或安装。

### 2026-10-01 10:13 再次真机复测

新版 App 已在手机注册 `PersonalMemoryAgentAbility`。10:13:32 的 HiLog 依次记录扩展创建、连接、`request received`、`parse failed reason=unsupported-method`，报文外层为 JSON 对象，含 `method` 与 `params.message`；随后发送了兜底错误。因此这次没有回答的直接原因是消息方法未被解析器接受，尚未进入本机记忆查询。日志没有记录该方法的具体值，不能声称已确认它是哪一个方法。

解析器现补充 `message/stream` 和旧式 `tasks/sendSubscribe` 两种带用户消息的只读查询方法，保留请求编号和消息角色格式，并把已解析请求的授权/查询失败转成可显示的文字答复。拒绝其他动作方法。对于仍不支持的方法，诊断日志会记录长度受限、仅由 ASCII 标识字符组成的方法名；不会记录问题正文、消息分片、请求编号或记忆内容。该改动不涉及 AgentCard、小艺开放平台配置或记忆索引。需重新构建并安装 App 后重试，核对 `[XiaoyiA2A] response sent` 及小艺显示结果；如果仍为 `unsupported-method`，按新日志里的具体方法名继续适配。当前未编译或安装，互通效果尚未验证。

### 2026-10-01 10:30 真机报文方法已确认

更新后的 App 在 10:30:26 收到小艺请求，诊断日志明确显示 `method=SendStreamingMessage`、`paramsMessage=true`，随即因 `unsupported-method` 回退。可确定本轮无答复发生在请求解析阶段，记忆查询没有运行。`SendStreamingMessage` 是新版 A2A 的消息流方法名，响应可包含单条 `Message`，JSON-RPC 结果使用 `result.message` 包装。[A2A v1 方法变更](https://github.com/a2aproject/A2A/blob/main/docs/whats-new-v1.md)、[A2A v1 协议说明](https://github.com/a2aproject/A2A/blob/main/docs/specification.md)。华为 Agent Framework Kit 当前 `Role.AGENT = 0`、`Role.USER = 1`，故返回数字角色仍为 0。[华为接口变更清单](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/js-apidiff-agentframeworkkit-7002)。

代码现接受 `SendStreamingMessage` 与 `SendMessage` 的 `params.message`，沿用原有用户角色、文本和本地授权校验，并按 `result.message` 返回一条代理消息；其他动作方法仍拒绝。AgentCard 的 `capabilities.streaming` 改为 `true`，与实际支持能力一致。因此重新构建、安装 App 之外，还应在小艺开放平台重新导入更新后的 `agent_config.json`，并按平台真机调试发布流程刷新测试版本。当前只做静态检查，尚未验证新版答复能否在小艺展示。

### 2026-10-01 10:50 小艺回包解析错误

更新 App 与平台 AgentCard 后，10:47 与 10:50 的真机日志显示请求已进入本机索引查询（候选记录 9 条），ClawMate 调用 `sendData` 成功。但小艺在 10:50:00 对 `SendStreamingMessage` 报 `-32700`：`type must be string, but is number`。这说明 `sendData` 只证明 IPC 调用没有同步抛错，不能证明小艺已成功解析或显示答复。

小艺进程的同一时刻日志显示请求 `id` 为字符串，返回 `-32700` 且标记 `NO_TASK_CREATE`。当前新版答复中唯一明确的数字字段是 `role: 0`，因此角色类型是这次报错的直接原因。A2A v1 的消息 JSON 示例使用字符串 `"ROLE_AGENT"`；现将 `SendStreamingMessage` / `SendMessage` 的回复角色改为该字符串，同时原样保留请求 `id`。[A2A v1 消息与响应格式](https://github.com/a2aproject/A2A/blob/main/docs/specification.md)。旧式 `message/send` 和无封装本机消息回复暂不改变。新增日志仅记录解析成功时的方法名、`id` 的类型和请求角色是否为数字，不记录取值或个人记忆内容。更新后的真机互通仍需重新验证。

### 2026-10-01 10:58 流式请求未完成

10:55 安装新版后，10:58:17 的请求已成功解析为 `SendStreamingMessage`，`idType=string`，索引查询仍返回 9 条候选记录，并调用 `sendData`。小艺没有报之前的 `-32700`，但其 IPC 将请求继续保持约 100 秒，到 10:59:57 报 `-32101 timeout`。11:02 的小艺客户端日志进一步将收到的单条 Message 标为 `Received unknown event type`；日志中的消息正文含个人记忆，故不复制到文档。这证实消息已进入小艺客户端，但未被它当作可显示的流式任务结果。

现对 `SendStreamingMessage` 改用 `result.task`，其中包含唯一任务 ID、会话 ID、带文字 Part 的 Artifact，以及终态 `status.state = "TASK_STATE_COMPLETED"`；`SendMessage` 继续返回直接消息。A2A 协议允许流以 Task 开始，并在任务进入完成状态时结束。[A2A v1 流式任务语义](https://github.com/a2aproject/A2A/blob/main/docs/specification.md)。这是基于公开协议与真机超时日志作出的适配，仍须安装后验证小艺端是否接受。AgentCard 未改变，平台无需重新导入。

### 2026-10-01 按华为端 A2A 对话示例调整回复结束流程

用户提供的华为官方离线 HTML《[对话交互](https://developer.huawei.com/consumer/cn/doc/doccenter-celia/agent2agent-chat-0000002660585429)》明确给出流式回复顺序：先以 `result.task` 建立 `TASK_STATE_SUBMITTED` 任务，再以 `result.artifactUpdate` 发送正文并标记 `lastChunk: true`，最后以 `result.statusUpdate` 发送 `TASK_STATE_COMPLETED`。单轮示例虽允许一次返回已完成的 Task，但该方式在当前小艺真机上曾出现答复可见、输入框仍为中断按钮的现象。因此本机查询改用该文档的三帧流程。三帧沿用同一 JSON-RPC 请求 ID、任务 ID、会话 ID；状态带 ISO 时间戳，`result.metadata` 带 Agent ID 和版本，若请求带 `traceId` 则回传。`sendData` 日志只记录帧序号，不记录记忆正文。

该文档请求方法示例为 `MessageStream`，之前手机日志实际为 `SendStreamingMessage`，解析器同时支持两者。华为示例中不同帧的 JSON-RPC `id` 有不一致之处；代码统一沿用实际请求的 `id`，以便小艺关联同一次请求。文档示例没有 `final` 字段，本实现也不添加。此前的两帧回复仍使小艺保持接收状态，因此已由本节的华为示例流程取代。AgentCard 未改，开放平台无需重新导入；需要重新构建、安装 App 后在真机确认按钮是否恢复为发送状态。本次仅做静态检查，没有编译或安装。

### 2026-10-01 小艺记忆查询接入聊天 Agent

当前小艺入口复用 App 云端聊天的 `ChatReactAgent` 和 `query_events` 工具，处理链路为：小艺用户问题 → 本机授权与登录检查 → 云端 Planner 理解问题并调用记忆查询工具 → 本机索引返回符合限制的记录 → 同一模型整理回答 → 小艺内容帧与完成帧。`PersonalMemoryChatAgent.ets` 为每次请求建立独立的工具注册表，只注册只读的 `query_events`；不注册手机 GUI 操作工具。

模型可以选择关键词、`keyword_operator`、领域、实体、`date`、`month` 或 `start_date` / `end_date` 等参数，并在结果为空时调整条件重试。系统消息提供手机当前日期、星期、本周与上周（周一至周日）的范围；例如手机日期为 2026-10-01 时，“上周”对应 2026-09-21 至 2026-09-27。时间范围由 Agent 生成工具参数，经过现有工具的格式校验后传给索引，不再使用旧入口的固定关键词规则。回答只根据已同步记录；未调用查询工具或查询没有可提供的记录时，不返回模型猜测的个人经历。

`ChatCloudConfig.ets` 让聊天页面与 Agent Extension 共用同一组持久化的 Planner 地址、模型和密钥，并保留旧共享密钥的回退规则。小艺入口使用配置的 Planner，不依赖聊天页面打开，也不依赖页面中的临时 PC Server 通道。由于复用的云模型客户端要求有效的 App 登录会话，使用前应先打开 ClawMate、登录、同意隐私声明、同步记忆并开启小艺读取开关。`HuaweiAccountSession.ets` 将登录返回的 OpenID 与会话版本保存在应用级沙箱；扩展读取该标识后，使用华为官方 `getHuaweiIDState` 核验授权状态，再更新本运行时的登录标记。退出登录会清空共享标识；不使用持久化布尔值模拟登录。该查询需要联网，必要提问和经过过滤的匹配记录会发送给已配置的模型整理回答；账号标识不发送给模型。

敏感信息过滤在工具结果交给模型之前执行，涵盖摘要、补充事实、实体、来源和待办文本；模型最终回答也按相同规则检查。过滤仍是规则判断，可能排除包含敏感词的整条记录。A2A 日志只记录阶段、轮数、结果数量；本入口关闭云模型客户端的回答正文预览日志，不加载完整个人画像或 App 聊天历史。

沿用华为官方《对话交互》的报文结构，现将 `TASK_STATE_SUBMITTED` 帧提前到 Agent 开始处理之前发送；最终正文仍通过 `artifactUpdate`、`lastChunk: true` 返回，并以 `TASK_STATE_COMPLETED` 结束，三帧共享相同的请求、任务与会话 ID。单次查询最多 6 轮、每轮模型 HTTP 读取超时 30 秒、整体 Agent 超时 75 秒；75 秒是本应用的处理预算，不是对华为平台超时规则的声明。模型失败、无索引、无记录、未登录、授权撤回或超时都会返回文字说明并结束已建立的任务；连接断开或扩展销毁时取消对应请求。

本次未改变 AgentCard、技能 ID、Extension 注册和对外消息格式，因此小艺开放平台无需重新导入配置。需要在 DevEco 构建并更新手机 App，之后验证“我上周做了哪些事”“我最近点过什么外卖”“我之前说过的生日是什么”，并检查收到回答后中断按钮是否恢复。新增 Hypium 用例覆盖模型工具参数传递、关键词重试、敏感字段过滤、无检索时的事实限制、授权撤回、超时及分阶段任务结束；当前仅做静态核对，未执行构建、设备测试或 Hypium。

### 2026-10-01 App 已登录但小艺提示未登录

原因是旧账号卡片仅写入 `AppStorage` 的内存标记，并丢弃 Account Kit 返回的凭据；A2A 直接检查本运行时的内存标记，无法可靠读取 App 页面中的登录状态。现将成功登录返回的 `openID` 保存在共享沙箱，并按[华为账号登录状态管理](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/account-login-state)通过 `HuaweiIDProvider.getHuaweiIDState` 验证。官方状态必须为 `AUTHORIZED`，且校验前后的本地会话版本一致才放行。记忆读取和回答发送前重新核验；App 本地退出登录、系统账号退出或撤销华为授权后不返回记忆。账号服务失败与超时返回专门的状态确认提示，并仍发送任务完成帧。

旧版本未保存账号标识，更新 App 后须在“我的”中重新登录一次。此修复不涉及 AgentCard 或小艺开放平台配置，无需重新导入平台配置。静态核对依据还包括本机华为 API 24 SDK 的 `@hms.core.authentication.d.ts` 与登录按钮凭据声明；状态接口始于 API 12，不提高 API 20 的最低兼容版本。本次未编译、安装或运行设备验证。

### 2026-10-01 A2A 智能体显示名称调整

`entry/src/main/resources/base/profile/agent_config.json` 中的 AgentCard 显示名称现为 `ClawMate`。内部 Agent ID 仍为 `clawmate_personal_memory`，扩展服务仍为 `PersonalMemoryAgentAbility`，平台继续关联现有智能体。

在小艺开放平台同步将现有智能体名称设置为 `ClawMate`；需要导入 AgentCard 时使用上述更新后的 JSON 文件，并按当前发布状态更新真机测试或正式版本。手机端配置需通过构建、签名并安装更新后的 App 生效。改名本身不能保证主入口按名称唤起可用，仍需平台确认相应入口支持情况。本次仅静态检查，未编译或安装。
