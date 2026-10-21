# Tailscale 组网教程

[返回下载与指南](README.md) · ClawMate Codex 1.1.11

让异地的手机和电脑通过私有网络互访。组网成功后，ClawMate 使用电脑的 Tailscale 地址连接，无需把桥接端口开放到公网。

> 手机需有适配当前系统的 Tailscale 兼容客户端。官方安装文档目前未列出鸿蒙 NEXT；不能把 Android APK 当作鸿蒙原生安装包。没有兼容客户端时，先使用同一 Wi-Fi 连接。

## 1. 电脑安装 Tailscale

Windows / macOS 从 Tailscale 官网下载安装并登录。Linux 有管理员权限时可使用下方官方命令，或按官方文档用软件包安装。没有权限或没有 TUN 的服务器，需参考官方用户态模式文档配置。

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

## 2. 手机加入同一网络

在兼容客户端登录同一 Tailscale 网络的账号，或由该网络管理员邀请加入。按系统提示允许 VPN，确认手机和目标电脑均在线。可在控制台的设备列表核对。

## 3. 记下电脑的私有 IP

使用目标电脑的 Tailscale IPv4，例如 100.101.102.103。Linux 可运行下方命令；Windows / Mac 可在客户端复制地址。这个地址属于电脑，不能填成本机手机的 IP。

```bash
tailscale status
tailscale ip -4
```

## 4. 启动连接器并生成新配对

先启动 Tailscale，再启动 ClawMate 连接器，选择自动安全配对并允许远程设备访问。在「手机配对」选 100 开头地址。Linux 使用 pair --origin 指定该地址；默认端口 8787。

```bash
./bin/clawmate-codex pair --origin https://100.101.102.103:8787 --output phone.clawmate-codex-pair.json
```

## 5. 手机用新地址连接

扫描新二维码，或粘贴完整配对信息。原先保存的 192.168 开头连接不会自动切换，请回「我的连接」使用新连接。连接器应与 Tailscale 位于可互访的网络环境中。

## 6. 不通时逐层确认

先确认两端 Tailscale 在线且能互访，再检查连接器 status。网络访问策略及电脑防火墙需允许手机访问桥接 TCP 端口。下方命令在能使用 Tailscale CLI 的设备执行，目标应换成另一端 IP；单向 ping 成功也不能代替手机到桥接端口的检查。

```bash
tailscale ping <另一台设备的Tailscale-IP>
./bin/clawmate-codex status
```

## 常见问题与注意事项

- 两端直接加入同一个 Tailscale 网络时，一般不需要出口节点、子网路由或公网端口映射。公司或学校网络的管理策略仍可能限制连接。
- Linux 用户态模式可能没有 tailscale0 网卡。连接器 1.1.11 可读取本机 Tailscale socket 获取地址；必要时在后台启动前指定 CLAWMATE_TAILSCALE_SOCKET。它不会替你安装、登录 Tailscale 或更改网络策略。
- Tailscale 负责网络互访，连接器仍负责 Codex 任务和独立配对。电脑休眠、服务退出或 VPN 断开时，手机无法继续连接。

## 相关链接

- [Tailscale 官方下载与安装](https://tailscale.com/docs/install)
- [Linux 官方安装指南](https://tailscale.com/docs/install/linux)
- [无 TUN：用户态模式](https://tailscale.com/docs/concepts/userspace-networking)

<!-- 内容源：entry/src/main/ets/pages/codex/CodexHelpContent.ets；通过 scripts/check_codex_help.cjs --write-docs 同步。 -->
