# Tailscale 组网教程

[返回下载与指南](README.md) · ClawMate Codex 1.1.15

把手机和电脑、云服务器加入同一个虚拟局域网，即使不在同一个 Wi-Fi 下，也能互相连接。

> 鸿蒙手机可以通过卓易通安装 Tailscale，使用微软或 Apple 账号登录，无需翻墙。

## 1. 电脑安装 Tailscale

Windows / macOS 从 Tailscale 官网下载安装。Linux 服务器可使用下方命令安装并启动，或查看 Linux 官方安装指南。

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

## 2. 手机通过卓易通安装

在鸿蒙手机上打开卓易通，搜索并安装 Tailscale，安装后打开。

## 3. 两端登录同一个账号

电脑和手机都选择微软或 Apple 登录，并使用同一个账号。手机按提示允许 VPN 连接，保持 Tailscale 开启。两端请选择相同的登录方式。

## 4. 确认已加入同一网络

登录后，在 Tailscale 设备列表中能看到电脑和手机，且两台设备都显示在线，即表示已加入同一个虚拟局域网。设备地址通常以 100. 开头。

## 相关链接

- [Tailscale 官方下载与安装](https://tailscale.com/docs/install)
- [Linux 官方安装指南](https://tailscale.com/docs/install/linux)

<!-- 内容源：entry/src/main/ets/pages/codex/CodexHelpContent.ets；通过 scripts/check_codex_help.cjs --write-docs 同步。 -->
