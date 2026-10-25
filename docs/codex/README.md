# ClawMate Codex 连接器

在手机中继续自己电脑或服务器上的 Codex 工作。电脑运行连接器，手机扫码或粘贴一次性配对信息。

## 下载 1.1.13

| 平台 | 适用设备 | 安装包 |
| --- | --- | --- |
| Windows | x64 · 安装向导 | [下载](https://github.com/doulujiyao12/mobiinfra-oh/releases/download/codex-bridge-v1.1.13/ClawMate-Codex-1.1.13-win-x64.exe) |
| macOS | Apple Silicon（M 系列）· 解压后移入应用程序 | [下载](https://github.com/doulujiyao12/mobiinfra-oh/releases/download/codex-bridge-v1.1.13/ClawMate-Codex-1.1.13-darwin-arm64-unsigned.zip) |
| Linux · CLI | x64 · 适合云服务器和无桌面环境 | [下载](https://github.com/doulujiyao12/mobiinfra-oh/releases/download/codex-bridge-v1.1.13/ClawMate-Codex-Terminal-1.1.13-linux-x64.tar.gz) |
| Linux · 桌面 | x64 · 解压后启动，需要图形环境 | [下载](https://github.com/doulujiyao12/mobiinfra-oh/releases/download/codex-bridge-v1.1.13/ClawMate-Codex-1.1.13-linux-x64-unsigned.tar.gz) |
| Windows · CLI | x64 · 终端便携版 | [下载](https://github.com/doulujiyao12/mobiinfra-oh/releases/download/codex-bridge-v1.1.13/ClawMate-Codex-Terminal-1.1.13-win32-x64.zip) |

[Release 与 SHA256 校验清单](https://github.com/doulujiyao12/mobiinfra-oh/releases/tag/codex-bridge-v1.1.13)

安装包未签名，Mac 未公证；Mac 仅提供 M 系列版本。

Windows 是安装向导；macOS ZIP 内为应用，解压后移入「应用程序」；Linux 为解压使用的便携包，服务器优先选 CLI。当前没有 Intel Mac、Linux ARM64、DMG、DEB 或 RPM 安装包。

## 连接指南

- [Windows](windows.md)
- [macOS · Apple Silicon](macos.md)
- [Linux · CLI](linux.md)
- [Tailscale：异地手机与服务器组网](tailscale.md)

手机入口：**Codex → 我的连接 → 下载 PC 端的 Codex 连接器 / 连接指南 / Tailscale 组网教程**。内置指南无需加载网页；下载文件和打开外部资料需要网络。

## 校验与升级

从同一 Release 下载 SHA256SUMS.txt，核对对应文件的哈希，再安装或解压。

- Windows PowerShell：`Get-FileHash .\ClawMate-Codex-1.1.13-win-x64.exe -Algorithm SHA256`
- macOS：`shasum -a 256 ClawMate-Codex-1.1.13-darwin-arm64-unsigned.zip`
- Linux：`sha256sum ClawMate-Codex-Terminal-1.1.13-linux-x64.tar.gz`

升级前先结束任务并退出旧后台；不要覆盖正在运行的解压目录。配置、手机配对和任务数据位于用户配置目录，替换程序通常无需重新配对。

更完整的能力及维护说明见 [电脑端使用指南](../../pc-companion/USER-GUIDE.md)。

<!-- 平台内容源：entry/src/main/ets/pages/codex/CodexHelpContent.ets；通过 scripts/check_codex_help.cjs --write-docs 同步。 -->
