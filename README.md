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
- **汇总**：按 Workflow 场景展示已整理记录，支持查看分组详情和来源信息。
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
* **图形化编辑器**：编辑 `open_app`、`gui_task`、`shot_summary`、`if`、`for_loop`、`until_loop` 等节点。
* **文件管理**：查看和清理 Workflow 配置、daily-log 与运行文件。
* **场景切换**：按购物、聊天、外卖、娱乐、生活、社交、差旅等采集场景管理任务。

### 「设置」页面
* **个人与隐私**：配置确认策略、隐私守护和数字分身相关选项。
* **数据采集**：配置图库、OCR、Embedding 与地图服务。
* **模型与智能体**：配置云端 Planner/Decider、本地模型下载、HDC Server 和模型调试工具。
* **任务与自动化**：配置 Agent 执行、Workflow 和运行日志入口。
* **存储与关于**：管理模型文件、调试产物、截图缓存、版本和说明。

---

## 🔁 四、Workflow / 云端 Agent / MNN Agent 执行链路

当前 App 有三种自动化执行入口，它们共享同一台手机和同一个 PC HDC 服务，但任务下发方式不同：

| 执行方式 | App 侧入口 | PC 侧入口 | 模型推理位置 | 设备控制方式 |
| --- | --- | --- | --- | --- |
| Workflow 任务 | 「任务」页任务卡片 | `hdc_server.py` 的 `/api/workflow` | App 侧 `CloudModelClient` 调云端 Planner/Decider/Summary | PC 侧 `harmony_agent.py` 执行 HDC/hmdriver2 截图与动作 |
| 云端 Agent | 「聊天」页切换到“云端智能体”后下发任务 | `harmony_agent.py` 后台轮询 App `9126` | App 侧 `AgentRouterServer` 转发到 `CloudModelClient` | PC 侧 `harmony_agent.py` 截图、解析动作并执行 |
| MNN 本地 Agent | 「聊天」页切换到“本地推理”后下发任务 | `harmony_agent.py` 后台轮询 App `9126` | App 侧 `AgentRouterServer` 转发到 `libentry.so`/MNN | PC 侧 `harmony_agent.py` 截图、解析动作并执行 |

关键端口：

- `9123`：PC 模型文件下载服务，通常由 `serve_model.py` 提供。
- `9124`：PC HDC HTTP 服务，通常由 `hdc_server.py` 提供。
- `9126`：App 内 TCP Agent Router。PC 侧通过 `hdc fport tcp:9126 tcp:9126` 映射到手机 App。

Workflow 不依赖 `9126` 轮询。它由 App 内 `WorkflowRunner` 编排，每一步通过 `HdcWorkflowBridge` 调用 PC 的 `/api/workflow`，PC 只负责启动 App、截图和执行 GUI 动作。Planner、Decider 和图片总结请求仍由 App 侧直接调用云端模型配置。

云端 Agent 和 MNN 本地 Agent 共享 `9126` 轮询链路。在聊天页下发任务前，App 会切换 `AgentRouterServer` 到 cloud 或 local 模式，确保 `9126` 正在监听，并调用 PC 的 `/api/agent_loop/ensure` 让 `hdc_server.py` 确认后台 `harmony_agent.run_agent_loop()` 存活且刷新端口映射。随后 PC 侧轮询 `poll` 拿到任务，再按 Planner -> 截图 -> Decider -> 执行动作的循环运行。

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
