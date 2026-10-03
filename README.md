# MobiInfer LLM Chat (MNN 大模型端侧智能体应用)

本项目是一个在鸿蒙 (HarmonyOS NEXT) 设备上运行端侧大语言模型（基于 MNN 推理引擎），并结合 PC 辅助端实现“多模态智能体操作 (视觉 UI 自动化 Agent)”的完整解决方案。

---

## 🏗 架构简介

系统由两个主要部分组成：
1. **鸿蒙 App 端 (MobiInfer LLM Chat)**
   - 运行端侧模型（MobiInfer LLM），提供离线聊天和指令推理。
   - 负责任务的下发与用户授权交互。
2. **PC 服务器端 (Python)**
   - **模型静态服务**：提供大模型权重文件的局域网下载 (`serve_model.py`)。
   - **HDC 服务端**：提供局域网内的 HDC 代理和前置状态检测 (`hdc_server.py`)。
   - **Agent 引擎**：负责获取手机截图、运行大模型规划、通过 `hmdriver2` 模拟点击滑动等自动化操作 (`harmony_agent.py`)。

   > **注意**： 每次需要更新mobiinfra-oh/entry/src/main/cpp/include 下面两个头文件，以及mobiinfra-oh/entry/libs/arm64-v8a/libMNN.so 动态链接库

---

## 🛠 一、准备与安装

### 1. 环境依赖
- **PC 端**：
  - Windows / macOS / Linux。
  - Python 3.8+。
  - 配置好鸿蒙系统 `hdc` 环境变量（确保在命令行可以直接执行 `hdc list targets`）。
  - 安装 Python 依赖：
    ```bash
    pip install Pillow hmdriver2
    ```
- **手机端**：
  - 升级到支持的 HarmonyOS 操作系统。
  - 在开发者选项中开启并获取 **“无线调试”** 的 IP 与端口（例如：`192.168.1.100:35729`）。

### 2. PC 服务器端启动
你需要启动两个服务端脚本（推荐开启两个终端环境）：

1. **大模型下载服务**（如果没有模型文件需要先下载）：
   ```bash
   # 进入模型所在目录，启动 HTTP 文件服务（默认 9123 端口）
   python serve_model.py
   ```
2. **HDC 代理服与执行后端**：
   ```bash
   # 在 PC 端运行 HDC 服务（默认 9124 端口），它负责拉起并守护 harmony_agent.py 进程
   python entry/src/main/python/hdc_server.py
   ```

### 3. App 编译与安装
1. 使用 **DevEco Studio** 打开本项目 (MnnLlmChat)。
2. 配置好自动签名。
3. 点击 **Run** 或 **Debug** 编译打包，将 App 安装至手机。

### 4. 修改应用包名

应用包名只需在 `AppScope/app.json5` 的 `app.bundleName` 中修改。App 运行时的自启动/回跳、画像碰一碰分享标识、PC 侧 Agent 以及设备导入脚本都会自动读取该值；`entry/src/main/module.json5` 的 `shareBundleName` 由 Hvigor 在构建时自动注入，无需手工维护。

包名改变后，HarmonyOS 会把它识别为一个新应用，因此旧包名的沙箱数据不会自动迁移；Account Kit、Map Kit 等已在 AppGallery Connect 开通的服务也需要登记新的包名并匹配相应签名。

---

## 📱 二、App 使用指南

App 当前采用五个底部标签页：**首页**、**汇总**、**聊天**、**任务**、**设置**。`聊天` 是中心入口，负责云端智能体、本地推理和历史会话；`任务` 负责 Workflow 配置和运行；`设置` 通过模块列表进入具体配置页。

### 📌 第一次使用的配置流程（设置页）
如果你是初次打开该 App，请切换到 **“设置”** 页，按模块完成以下配置：

1. **模型与智能体**
   - **模型下载服务**：PC 模型拉取服务器，如 `http://192.168.1.50:9123`。
   - **HDC Server**：PC HDC 服务，如 `http://192.168.1.50:9124`。
   - **云端 Planner / Decider 配置**：填写 OpenAI-compatible 的 base URL、API Key 和模型名。
   - 本地 MNN 模型仍使用沙箱中的 `model` 或版本化模型目录。
   - **NPU 图运行方式**：可选“在线编译”或“离线 OM”。在线模式按 chunk 和输入 shape 复用 App 沙箱缓存；离线模式严格加载模型目录 `om/` 中与 NPU chunk 同名的 Kirin 预编译图，缺失、shape 不匹配或芯片不兼容时直接报错，不回退在线编译。
2. **任务与自动化**
   - 配置 Agent 执行确认策略、Workflow 运行相关选项和运行日志入口。
   - 点击 HDC/Agent 后端相关按钮前，请确认 PC 端已启动 `hdc_server.py`。
3. **数据采集**
   - 配置图库、OCR、Embedding 和地图服务，用于图库分析、数据归家和推荐生成。
4. **存储与关于**
   - 管理模型文件、调试产物、截图缓存和应用说明。

本地模型文件请使用 `mobiinfer llmexport` 导出。需要通过局域网下载时，将 `entry/src/main/python/serve_model.py` 放在导出后的模型目录下并启动服务，再回到 App 内执行模型下载。

离线 NPU 模型仍需保留完整的 MNN 权重、视觉 pre/post、CPU chunk、tokenizer 与配置文件；`.om` 只替代配置为 `npu` 的视觉 chunk。当前 Kirin 9030 离线图固定为 `seq_len=608`，App 会把相册图片和本地 Agent 截图统一映射到 `600×270`（横屏交换）的视觉提示尺寸。其他视觉 token shape 需要重新生成并编译对应 OM。

### 🎙 聊天、会话与 Agent 控制（聊天页）
切换到 **“聊天”** 页后，可以使用顶部模式切换：

1. **云端智能体**
   - 发送普通消息时，App 会按当前会话历史构造上下文并调用云端模型。
   - 输入可执行任务后点击 **下发任务**，App 会通过 PC 侧 `hdc_server.py` 和 `harmony_agent.py` 控制手机完成 GUI 操作。
   - 执行过程会以折叠卡片展示关键步骤；最终结果和调试截图会保存到当前会话。
2. **本地推理**
   - 加载 MNN 模型后，可进行端侧本地对话。
   - 本地 Agent 任务会通过 App 内 `AgentRouterServer` 转发到 `libentry.so`/MNN 推理，再由 PC 侧执行动作。
3. **历史会话**
   - 点击左上角菜单可展开会话列表。
   - 云端智能体和本地推理分别保存上下文，切换会话时会恢复对应聊天记录。
   - 删除会话会同时删除该会话对应的记录文件和截图资产。

### 🧭 首页、汇总、任务和设置

- **首页**：展示数据归家后的个人画像、推荐事项和数字分身；推荐事项可直接下发为云端 Agent 任务。
- **汇总**：按场景展示已整理记录，支持查看分组详情和来源信息。“个人信息”栏目收录用户在云端或端侧聊天中明确说出的生日、住址、工作单位等可长期复用的本人资料，不需要预先填写固定字段；普通云端聊天可通过现有事件查询工具按关键词检索。打开 App 时，若距上次同步（或首次使用）已满 3 天且检测到新保存的记录，会询问是否同步，可选择“暂时不用”或勾选“不再提醒”。手动点击“同步”时，按消息发送时间仅处理最近 7 × 24 小时内尚未处理的内容，已检查但没有相关信息的消息也不会重复处理。聊天提取使用现有 Planner 整理服务，以用户明确表达或确认的信息为依据，AI 回答只作为上下文。处理失败的批次可在下次同步时重试。
- **任务**：管理 Workflow 配置、图形化编辑节点、运行任务，并查看配置文件、daily-log 和运行产物。
- **设置**：按模块进入个人与隐私、数据采集、模型与智能体、任务与自动化、存储与关于等配置。

---

## 🖱 三、主要功能说明

### 「聊天」页面
* **模式切换**：在云端智能体和本地推理之间切换；聊天记录和上下文按模式与会话隔离。
* **会话管理**：左上角展开历史会话列表，可新建、切换和删除会话。
* **发送**：发送普通消息；发送后输入框会清空并收起输入法。
* **深度思考 / 下发任务**：作为快捷操作入口，支持让云端或本地 Agent 处理复杂任务。
* **执行过程折叠**：中间步骤默认折叠展示，展开后查看格式化 reasoning、动作和目标。
* **截图预览**：任务结果截图按会话保存，点击后可放大查看。

### 「任务」页面
* **Workflow 任务卡片**：运行已配置的 GUI 自动化任务。
* **任务控制方式**：只保留“电脑控制”和“手机自己控制”两个选项，新用户默认“手机自己控制”，已有用户保留已保存的选择。选择同时作用于任务页 Workflow、聊天云端/本地 Agent 和聊天 `mobile_gui_task` 工具。手机连接地址统一在「我的 → 手机 HDC」设置；只有选择电脑控制时才弹出桌面端下载提醒。
* **图形化编辑器**：编辑 `open_app`、`gui_task`、`shot_summary`、`if`、`for_loop`、`until_loop` 等节点。
* **文件管理**：查看和清理 Workflow 配置、daily-log 与运行文件。
* **场景切换**：按购物、聊天、外卖、娱乐、生活、社交、差旅等采集场景管理任务。

### 「设置」页面
* **个人与隐私**：配置确认策略、隐私守护和数字分身相关选项。
* **数据采集**：配置图库、OCR、Embedding 与地图服务。
* **模型与智能体**：配置云端 Planner/Decider、本地模型下载、HDC Server 和模型调试工具。
* **任务与自动化**：配置 Agent 执行、Workflow 和运行日志入口。
* **存储与关于**：管理模型文件、调试产物、截图缓存、版本和说明。

### 手机 HDC 连接设置与自控测试（实验功能）

在「我的 → 手机 HDC」中设置**当前手机**的无线调试连接地址。Wi-Fi IPv4 默认自动检测，HDC 调试连接端口仍需从系统无线调试页面填写；修改即保存，任务页与测试共用这份设置。App 会直接连接手机的调试守护进程，使用 App 自己生成并保存在私有沙箱的 RSA3072 密钥完成公开 HDC 协议握手，不调用 PC 的 HTTP 服务，也不复用 PC 的授权密钥。不需要先由 PC 执行配置命令；首次系统授权仍需在手机弹窗中手动允许 `MobiInfra-SelfHdc`。

1. 保持手机解锁，在开发者选项中手动开启无线调试，填写当前 HDC 连接端口。App 在每次启动、回到前台、进入手机 HDC 设置页及手机任务/测试连接前检测 Wi-Fi IPv4，只更新 IP，保留端口与控制方式。无可用 Wi-Fi 地址或检测失败时保留上次配置并显示原因，不用蜂窝网络、VPN、回环或链路本地地址覆盖。可点击「立即检测手机 IP」；需要手填 IP 或尝试 `127.0.0.1` 时关闭「自动更新手机 Wi-Fi IP」（守护进程是否接受回环连接由系统决定）。
2. 点击「仅测试连接」，验证 TCP、系统授权和 HDC Shell；授权等待最长90秒。该按钮不会打开支付宝。
3. 点击「开始完整测试」，依次通过 HDC Shell 执行：打开 `com.alipay.mobile.client / EntryAbility` → 截图 → 按截图尺寸向上滑动一次 → 再截图 → 返回本 App。测试期间不要手动切换应用。截图以 HDC Shell 的 `base64` 输出传回本 App，不依赖 PC 文件传输。
4. 返回后查看阶段日志与前后截图，点击「复制完整日志」提供调试信息。页面保留最近160行，完整日志在 `filesDir/self_hdc/runs/<runId>.log`，阶段及结果在同目录的 `.json`，截图为 `_before.jpeg` / `_after.jpeg`。截图命令使用 `snapshot_display` 的默认 JPEG 格式，接收端检查 JPEG 起止标记及大小限制。`latest.json` 用于恢复最近一次结果；若进程被终止，下次打开会标记上次测试中断。Hilog 模块名为 `SelfHdc`。

这是验证“手机能否用 HDC 控制自己”的实验实现。用户已反馈此前手机自控测试通过，但这不能证明所有 HarmonyOS 6/7 版本或完整 GUI Workflow 都兼容。当前支持公开协议的 RSA 公钥授权、RSA-PSS/SHA512 签名和兼容的 PKCS1 原始签名；不支持 TLS-PSK、企业设备连接验证及厂商专有认证。如果系统拒绝 App 访问调试端口、拒绝自授权、校验专有 SDK 版本/哈希，或要求未实现的认证，测试会停止并记录阶段及系统反馈。打开支付宝后依靠系统短时后台运行额度继续测试，额度不足或到期也会停止。失败不会改走 PC 后端；停止不会回滚已经发送的动作。截图可用于对照，但命令成功不自动等同于界面产生了预期变化。

2026-10-02 用户提供的 `OpenHarmony-7.0.0.105 / API26` 最新复测日志已确认：手机直连自身 HDC 端口、RSA 认证、Shell 探测、支付宝启动及首张 JPEG 截图成功；首张截图为 `1080x2444`、`220705` 字节。滑动命令返回 `exit=0` 和 `No Error`，但原来的错误关键字检查误将此成功提示判为失败，因而未执行第二张截图。现已改为逐行判断，只豁免完整的 `No Error` 成功提示；非零退出码与其他错误行仍会停止测试。滑动后截图及完整流程结束仍需复测；命令成功不自动等同于画面变化，需对照前后截图。截图 Base64 不写入日志。

客户端身份文件 `filesDir/self_hdc/identity.json` 含私钥，日志和“复制完整日志”均不会包含该文件；调试时只提供 `runs` 下的日志、结果和必要截图。App 清除数据或重新安装可能生成新的密钥，需要重新允许系统授权。

协议核对来源：[OpenHarmony HDC 会话与报文定义](https://github.com/openharmony/developtools_hdc/blob/master/src/common/session.h)、[设备认证状态机](https://github.com/openharmony/developtools_hdc/blob/master/src/daemon/daemon.cpp)、[主机 RSA 签名](https://github.com/openharmony/developtools_hdc/blob/master/src/common/auth.cpp)。商业 HarmonyOS 的实际行为以运行日志为准。

端口自动发现并非理论上不可行：[OpenHarmony HDC TCP 守护进程源码](https://github.com/openharmony/developtools_hdc/blob/master/src/daemon/daemon_tcp.cpp)包含 UDP 发现服务，会回复实际 TCP 监听端口；回复使用固定发现端口，手机 App 与本机守护进程同时绑定/接收存在需要实测的条件。商业 HarmonyOS 是否保留并开放同机发现能力尚未验证，因此当前实现不自动探测端口，仍使用系统无线调试页面显示的 HDC 连接端口。重新开启无线调试后端口可能变化，需要在「我的 → 手机 HDC」更新。

### 任务页使用手机自己控制

1. 默认使用“手机自己控制”，在「我的 → 手机 HDC」填写 **HDC 连接端口**，保留默认的自动 Wi-Fi IP。启动时检查一次；选择手机控制或执行任务前若未检测到 Wi-Fi IP、未填写端口或地址格式不正确，会弹窗提示并提供直达设置页的按钮。进入开发者模式：打开“设置 > 关于手机”，连续快速点击“软件版本号”7次，再在设置中搜索并开启“无线调试”，记录 IP 和连接端口。IP 探测只读取网络地址，不能确认开发者模式或无线调试已开启。设置保存在 `filesDir/self_hdc/task_connection.json`，不会修改 PC HDC Server 地址或密钥。任务页切换控制方式只修改模式，不覆盖已保存的 IP、端口或自动更新开关。
2. 首次使用新增输入能力时，进入「手机 HDC → 验证点击 / 聚焦 / 文本输入」。先点测试输入框一次校准物理屏幕坐标，再点开始。诊断使用与任务相同的手机桥接，依次检查实际点击、激活并替换 ASCII 输入、记忆焦点后替换中文与 shell 特殊字符、回车提交及截图。`INPUT_ASSERT ... PASS` 表示控件实际收到预期事件/文字；仅有 HDC 的 `No Error` 不算验证通过。诊断不需要云端模型，也不调用 PC。
3. 保留已配置的云端 Planner / Decider / Summary，在任务页运行原有 Workflow。编排、循环、分支、总结和 daily-log 仍由 App 原有执行器负责，仅设备操作切换到 `PhoneHdcWorkflowBridge`。手机分支不会探测 PC HTTP 服务，也不会在失败时改用 PC。批量手机任务遇到失败或取消会停止后续任务。
4. 所有连接、认证、Workflow 步骤、动作序号、HDC 命令退出码、截图尺寸及失败信息汇总到「我的 → 手机 HDC」。`CONNECTION / IP_STATUS` 记录本次地址和自动检测状态，Hilog 的 `IP_REFRESH` 记录更新前后 IP 与检测来源。`ACTION_BEGIN / ACTION_END / ACTION_FAILED` 可定位动作，`DEVICE_OUTPUT` 可对照设备响应，`WORKFLOW_SUMMARY` 指向原有 Workflow 运行目录。新增“清空日志”按钮清除手机测试和任务日志，保留授权密钥、连接配置、截图与 Workflow 产物；运行期间不可清空。截图 Base64 和 HDC 输入命令中的文本不写入桥接日志，Workflow 模型响应仍沿用原有日志内容。

| 原有任务设备能力 | 手机分支实现 |
| --- | --- |
| 启动 / 重置 / 停止目标应用 | `bm dump` 查询真实启动 Ability，`aa start` / `aa force-stop`；拒绝停止控制器自身 |
| 截图、截图总结、Decider 图片输入 | HDC Shell 截图并传回 JPEG；向模型提供半尺寸图片，保持现有执行器的坐标乘二约定，动作使用实际屏幕尺寸 |
| 点击与激活输入框 | `uitest uiInput click`，检查坐标边界，成功后才记录输入目标 |
| 输入 / 点击并输入 | 明确坐标或此前输入框点击 → 激活 → Ctrl+A → DEL → 带 shell 引号保护的文本 → ENTER，与 PC 默认驱动输入流程一致；缺少焦点时拒绝盲输 |
| 四向滑动 / 指定坐标滑动 | `uitest uiInput swipe`，按实际屏幕尺寸计算或使用明确物理坐标 |
| BACK / HOME / ENTER / 数字键码、等待 | `uitest uiInput keyEvent`、可取消的等待；返回、切换应用和滑动会清理记忆焦点 |
| 暂停、取消和返回控制器 | 沿用任务控制 UI，手机取消关闭自身 HDC 会话与云端请求，收尾尝试返回本 App |

开始执行前会检查 HDC Shell 身份和设备上 `aa`、`bm`、`snapshot_display`、`base64`、`uitest` 及所需 `uiInput` 子命令。缺失能力时停止并报告具体名称。未知动作同样明确失败，不会冒充执行成功。

部分 API26 设备的 `uitest uiInput help` 会打印 `Missing parameter.` 和完整 `USAGE` 后返回退出码 1。手机分支仅在这个只读帮助探测中兼容该结果，必须确认完整命令声明包含 `click`、`swipe`、`text`、`keyEvent`，且无权限或其他实际错误。日志 `CAPABILITIES uiInput verified=... helpExit=1 acceptedNonzeroUsage=true` 表示通过这项兼容检查；实际启动、点击、输入、滑动、截图等命令仍要求退出码 0。

手机切到其他应用后依赖系统授予的短时后台额度，日志会记录实际 `budgetMs`；不足 30 秒时拒绝开始，额度到期报告 `PHONE_HDC_BACKGROUND_EXPIRED` 并取消后续执行。额度是系统限制，较长的 GUI Workflow 仍可能无法连续完成；本次没有引入持续后台保活能力。本次新增 GUI 集成与输入诊断只完成源码、SDK 类型及 ArkTS 静态核对，未编译、安装或执行真机验证。

输入命令参考：[OpenHarmony UiTest 指南](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md)。诊断坐标按 [ClickEvent 文档](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-universal-events-click.md)将 `displayX/displayY` 的 vp 单位转换为物理像素。

### 聊天云端 / 本地 Agent 使用手机自控

1. 在「我的 → 手机 HDC」保存连接端口，在「任务」页选择「手机自己控制」，再到聊天页下发云端或本地 Agent 任务。两种 Agent 及聊天 `mobile_gui_task` 都读取同一选择；本次任务开始后固定执行方式，不在失败时切换 PC。
2. 云端 Agent 使用设置中的 Planner / Decider 云端地址与各自密钥，直接复用 `CloudModelClient` 的 Planner 和 Qwen Decider；手机分支不使用“PC Server 云端接口”的自动覆盖地址。端侧 Agent 先按原流程加载本地 MNN 模型，再复用本地 Planner 快速匹配、`chat`、`agentPrefill`、`agentStep` 和 `agentReset`。模型目录中的提示词及无推理提示词优先规则保持一致。
3. `AgentLoopRunner` 的模型循环、同屏 JSON 重试、动作解析、历史记录、动作确认及暂停继续复用。云端 Agent 截图比例为 0.5，端侧为 0.25；模型仍收到原有图片路径/`<hw>` 标签，手机动作使用截图中附带的真实物理尺寸，避免缩小图取整后的坐标误差。点击、输入、按键、滑动、启动应用和返回宿主复用任务页手机桥接。聊天 GUI 工具继续复用 Workflow 编排、业务结果提取与会话运行目录。
4. 在「我的 → 手机 HDC」查看、复制或清空日志。`RUN mode=phone-chat-local / phone-chat-cloud / phone-chat-workflow` 区分入口，`STAGE_BEGIN` 区分模型准备、HDC 连接与执行，`AGENT_SCREEN` 核对模型/物理尺寸，`LOCAL_RESET_BEGIN / LOCAL_RESET_END / LOCAL_RESET_FAILED` 定位本地推理收尾。长提示词日志分段为 `AGENT_LOG_PART`，截图 Base64 不写入日志。

手机会话与任务、诊断互斥。取消会立即关闭 HDC 连接，云端销毁请求；本地推理仍按现有原生接口等待当前推理结束，再重置上下文，期间保留 busy 状态，不接受新的设备任务。模型输出 `done: failed/suspended`、`stop/terminate/abort` 或到达 15 步上限不会报告成功。保持现有系统后台额度限制，到期明确记录 `PHONE_HDC_BACKGROUND_EXPIRED` 并停止后续动作；本地模型加载安排在申请额度之前。本次新增聊天集成只完成静态检查及聚焦用例编写，未构建或执行真机测试。

---

## 🔁 四、Workflow / 云端 Agent / MNN Agent 执行链路

Workflow、云端 Agent、本地 Agent 和聊天 GUI 工具共享「任务」页的控制方式选择：

| 执行方式 | App 侧入口 | PC 侧入口 | 模型推理位置 | 设备控制方式 |
| --- | --- | --- | --- | --- |
| Workflow 任务 | 「任务」页任务卡片 | `hdc_server.py` 的 `/api/workflow` | App 侧 `CloudModelClient` 调云端 Planner/Decider/Summary | PC 侧 `harmony_agent.py` 执行 HDC/hmdriver2 截图与动作 |
| Workflow 手机自控 | 「任务」页选择“手机自己控制” | 无 | App 侧 `CloudModelClient` 调云端 Planner/Decider/Summary | App 自身 HDC 客户端直连本机无线调试守护进程 |
| 云端 Agent（电脑控制） | 「聊天」页下发云端 Agent 任务 | `hdc_server.py` 的 `/api/workflow` | App 侧 `AgentLoopRunner` 调用 `CloudModelClient` | PC HDC bridge 提供截图与动作 |
| MNN 本地 Agent（电脑控制） | 「聊天」页下发本地 Agent 任务 | `hdc_server.py` 的 `/api/workflow` | App 侧 `AgentLoopRunner` 调用 `libentry.so`/MNN | PC HDC bridge 提供截图与动作 |
| 云端 / MNN Agent（手机自控） | 「聊天」页下发 Agent 任务 | 无 | 复用同一 App Agent 循环和云端 / 端侧模型 | 复用任务页手机 HDC bridge |
| 聊天 GUI 工具（手机自控） | 聊天 `mobile_gui_task` 确认后执行 | 无 | 临时 Workflow 调用云端 Planner / Decider / Summary | 复用任务页手机 HDC bridge |

关键端口：

- `9123`：PC 模型文件下载服务，通常由 `serve_model.py` 提供。
- `9124`：PC HDC HTTP 服务，通常由 `hdc_server.py` 提供。
- `9126`：App 内 TCP Agent Router。PC 侧通过 `hdc fport tcp:9126 tcp:9126` 映射到手机 App。

Workflow 不依赖 `9126` 轮询。它由 App 内 `WorkflowRunner` 编排；电脑模式通过 `HdcWorkflowBridge` 调用 PC 的 `/api/workflow`，手机模式注入独立的 `PhoneHdcWorkflowBridge`。桥接负责启动 App、截图和执行 GUI 动作。Planner、Decider 和图片总结请求仍由 App 侧直接调用云端模型配置。

当前聊天 Agent 按钮的循环在 `AgentLoopRunner` 中执行；电脑模式先检查 PC HDC 服务，手机模式通过 `PhoneHdcRunSession` 管理连接、互斥、后台额度、日志与收尾，随后把手机桥接注入同一循环。原有 `9126`、`AgentRouterServer` 与 Python `harmony_agent.run_agent_loop()` 调试/轮询通路保留，手机分支不启动该通路。

执行方式可以串行切换：一个 workflow 完成后，可以直接启动云端 Agent 或 MNN Agent；一个 Agent 任务完成后，也可以直接切换到 workflow。切换时不需要重启 PC server。仍建议同一时间只运行一个自动化任务，避免多个入口同时控制同一台手机。

`hdc_server.py` 默认会启动 `9126` 轮询 loop。如果只需要运行 workflow bridge，可以使用：

```bash
python entry/src/main/python/hdc_server.py --workflow_only
```

注意：使用 `--workflow_only` 时，云端 Agent 和 MNN 本地 Agent 不会收到 PC 轮询任务。

## ❓ 五、常见问题与排错 (FAQ)

**如果... 端口冲突导致 `TCP Port listen failed at 9126` 怎么办？**
答：最新的代码已经自带防呆机制。聊天页或设置页触发 Agent/HDC 后端检测时，PC 侧会刷新端口映射并清理残留的 `hdc fport tcp:9126 tcp:9126`。如果仍然复现，请重启 `hdc_server.py` 并重新连接无线调试。

**如果... HDC 连接检测一直无响应？**
答：检查你的 PC 防火墙是否放行了 `9123` 与 `9124` 端口，验证手机端是否和 PC 端处于同一公共局域网。

**如果... 模型输出是一堆乱码或崩溃退出？**
答：可能是线程数设置过大或者本地沙箱内的 `.weight` 权重文件在下载中断层或不全。请尝试：
1. 于“设置 > 模型与智能体”中将线程数（如 8）调小至 4。
2. 在模型文件管理区域删除模型后重新下载。

**如果... 智能体开始执行了，但是 PC 端拉取截图失败报错？**
答：确保手机并未锁屏，息屏状态下无法通过 HDC 获取图层。若反复报 "Fail"，请插拔尝试 USB 连接模式重新赋权一次调试信任。
