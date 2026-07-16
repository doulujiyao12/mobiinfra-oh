
<p align="center">
  <img src="https://github.com/yydhYYDH/mobiinfra-oh/releases/download/media-assets/icon-128.jpg" width="128" alt="ClawMate">
</p>

<h3 align="center">
ClawMate:主动式端侧智能体系统
</h3>

<h3 align="center">
ClawMate: A Proactive On-Device Agent System
</h3>


<p align="center">
| <a href="https://arxiv.org/abs/2509.00531"><b>MobiAgent Paper</b></a> | <a href="https://arxiv.org/abs/2512.15784"><b>MobiMem Paper</b></a> | <a href="https://huggingface.co/collections/IPADS-SAI/mobimind-68b2aad150ccafd9d9e10e4d"><b>Huggingface</b></a> | <a href="https://github.com/IPADS-SAI/ClawMate/releases"><b>ClawMate Desktop</b></a> |
</p> 

<p align="center">
</p>

<p align="center">
 <a href="README_en.md">English</a> | <a href="README.md">中文</a>
</p> 


---

## 关于

ClawMate 是一款面向 HarmonyOS NEXT 的端侧智能体应用，支持图库分析、个人画像、推荐事项、数字分身、云端智能体、本地推理和 GUI 自动化 Workflow，形成从“理解个人数据”到“执行真实手机操作”的移动智能体体验。本地模型推理能力由 [MobiInfer](https://github.com/doulujiyao12/mobiinfer) 提供。

本仓库是 ClawMate 的 HarmonyOS App 源码工程。当前不提供预构建安装包，必须从源码构建并安装到 HarmonyOS NEXT 设备。桌面端源码见 [ClawMate](https://github.com/IPADS-SAI/ClawMate)。

## 新闻

- [2026.7.18] 🔥 我们开源了 ClawMate HarmonyOS App 和 ClawMate Desktop ！

## 演示视频

<table>
  <tr>
    <td align="center" width="25%">
      <video src="https://github.com/user-attachments/assets/399e4dea-b28c-4051-b684-85521a3b4800" controls width="220"></video>
      <br><small>自动采集并整理手机数据</small>
    </td>
    <td align="center" width="25%">
      <video src="https://github.com/user-attachments/assets/80949978-e29e-48e0-91b1-14f60c2701c7" controls width="220"></video>
      <br><small>“碰一碰”快速交换个人画像</small>
    </td>
    <td align="center" width="25%">
      <video src="https://github.com/user-attachments/assets/91e84083-a8b8-4cfe-b3ee-f4426d0ce1e7" controls width="220"></video>
      <br><small>让千问帮你买东西</small>
    </td>
    <td align="center" width="25%">
      <video src="https://github.com/user-attachments/assets/c46ef03b-58b2-4f3a-98ae-bda7f20890ab" controls width="220"></video>
      <br><small>Agent自动操作手机点奶茶</small>
    </td>
  </tr>
</table>


## 安装


## 目录结构

```text
AppScope/                         应用级配置和图标资源
entry/                            HarmonyOS entry 模块
entry/src/main/ets/               ArkTS 页面、组件和业务逻辑
entry/src/main/cpp/               Native C++、N-API 和 MNN/MobiInfer 头文件
entry/src/main/python/            HDC bridge 和 Agent 执行辅助脚本
entry/src/main/resources/         App 图片、profile、rawfile Workflow 配置
entry/src/test/                   本地单元测试
docs/                             功能文档
mock/                             本地 mock 说明和配置
```

## 开发环境

需要准备：

1. 安装[DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)，建议使用支持 HarmonyOS NEXT / API 20+ 的版本。
2. 在 DevEco Studio 的 `Settings/Preferences > SDK > HarmonyOS > SDK Platforms` 中勾选并安装对应 API 版本的 Native SDK。
3. 把`hdc` 对应目录加入 `PATH` 后，确认命令行可执行 `hdc list targets`。`hdc` 通常随 DevEco Studio / HarmonyOS SDK 的 `toolchains` 提供
4. Python 3.8+，用于运行 App 仓库内的 HDC bridge 辅助脚本。也可以直接下载[ClawMate-Desktop](https://github.com/IPADS-SAI/ClawMate)来替代。

Python 依赖按需安装：

```bash
pip install Pillow hmdriver2 fastapi uvicorn pydantic
```

## 编译运行

使用 DevEco Studio：

1. 打开本仓库根目录。
2. 首次构建时让 DevEco Studio 生成根目录 `build-profile.json5`，并配置 HarmonyOS 自动签名或本机调试签名。
3. 选择 `entry` 模块和目标设备。
4. 点击 Run / Debug 安装到 HarmonyOS NEXT 手机（需要手机打开开发者模式）。


## PC Server
App 需要配合PC Server来使用GUI自动化能力，有以下两种方式启动：
- 安装[ClawMate-Desktop](https://github.com/IPADS-SAI/ClawMate/releases)来启动PC Server（推荐）。
- 使用仓库的 Python 脚本。

只使用聊天、图库分析等 App 内能力时，可先跳过 PC Server 启动。



在电脑上启动 PC Server：

```bash
python entry/src/main/python/hdc_server.py
```

如果只需要 Workflow 功能，不需要聊天页 Agent 轮询：

```bash
python entry/src/main/python/hdc_server.py --workflow_only
```

- `entry/src/main/python/hdc_server.py`：PC Server，负责设备连接、截图、App 启动和 GUI 动作执行。
- `entry/src/main/python/harmony_agent.py`：PC 侧 Agent 执行循环，通过 HDC / hmdriver2 控制手机。


常用端口：

| Port | 说明 |
| --- | --- |
| `9124` | PC HDC bridge HTTP 服务 |
| `9126` | App 内 Agent Router，本地/云端 Agent 轮询链路使用 |


## 常见问题

### HDC 连接检测无响应

确认手机和 PC 在同一局域网，PC 防火墙放行 `9124` 端口，并检查 `hdc list targets` 是否能看到设备。

### `TCP Port listen failed at 9126`

重启 `entry/src/main/python/hdc_server.py`，重新连接无线调试；聊天页或设置页触发 Agent/HDC 检测时会刷新 `hdc fport tcp:9126 tcp:9126` 映射。

### 本地模型输出异常或崩溃

检查模型权重是否完整下载，必要时在“设置 > 模型与智能体”降低线程数后重新加载模型。

### 自动化任务截图失败

确认手机未锁屏，HDC 调试授权仍有效；如果反复失败，可改用 USB 连接重新授权一次。
