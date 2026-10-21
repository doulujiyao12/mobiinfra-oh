# Linux CLI 连接指南

[返回下载与指南](README.md) · ClawMate Codex 1.1.11

适用于 x64 Linux 服务器，无需桌面环境。下面命令在服务器执行；把项目目录和示例 IP 换成自己的实际值。

> 请以持有项目和原 Codex 会话的普通用户运行。保留解压后的 bin、runtime 和 host 目录，不要只移动启动文件。

## 1. 下载并解压

下载终端版，先比对 Release 的 SHA256 校验清单，再解压到用户目录。目标目录应为空；升级时先结束任务并退出旧服务。

```bash
curl -fL --retry 3 -o ClawMate-Codex-Terminal-1.1.11-linux-x64.tar.gz \
  https://github.com/doulujiyao12/mobiinfra-oh/releases/download/codex-bridge-v1.1.11/ClawMate-Codex-Terminal-1.1.11-linux-x64.tar.gz
mkdir -p "$HOME/ClawMate-Codex"
tar -xzf ClawMate-Codex-Terminal-1.1.11-linux-x64.tar.gz -C "$HOME/ClawMate-Codex"
cd "$HOME/ClawMate-Codex"
```

## 2. 配置工作目录

将 /absolute/project 替换为服务器已有项目的绝对路径，电脑名称可自定义。该步骤只配置桥接，不会新建或克隆项目。

```bash
./bin/clawmate-codex setup --project /absolute/project --name MyServer --host 0.0.0.0 --port 8787
```

## 3. 登录 Codex

终端会显示官方验证网址和一次性登录码。在自己的手机或电脑浏览器打开该网址，输入码并完成授权，等待终端显示登录成功。不要把登录码发给其他人。

```bash
./bin/clawmate-codex login
```

## 4. 启动并查看地址

确认服务器和手机网络可互访；异地服务器先完成 Tailscale 组网。启动后用 status 查看实际监听地址和网络状态。

```bash
./bin/clawmate-codex start
./bin/clawmate-codex status
```

## 5. 导出一次性配对信息

将下方示例 100.101.102.103 替换为 status 中服务器本机的 Tailscale IPv4；同一 Wi-Fi 可用局域网 IP。这里填写服务器地址，不是手机地址。

```bash
./bin/clawmate-codex pair --origin https://100.101.102.103:8787 --output phone.clawmate-codex-pair.json
cat phone.clawmate-codex-pair.json
```

## 6. 手机完成配对

复制上一步输出的完整 JSON，手机打开 Codex → 创建连接 → 粘贴配对信息，粘贴后连接。也可把配对文件安全传到自己的手机，再「导入配对文件」。过期则重新运行 pair。

## 7. 开始任务与维护

手机选择项目并发送任务。用 devices 查看已配对设备；stop 在任务执行或待审批时会拒绝停服，先在手机结束任务。quit 会退出后台并中断独立任务。仅关闭 SSH 窗口不会主动停止已经启动的后台。

```bash
./bin/clawmate-codex status
./bin/clawmate-codex devices
# 空闲时停止连接服务
./bin/clawmate-codex stop
# 确认要退出后台时
./bin/clawmate-codex quit
```

## 常见问题与注意事项

- 配对码 5 分钟内有效，只能使用一次。请粘贴完整配对信息或导入配对文件；证书指纹不是 token。不要公开配对码和文件。
- 手机查看原电脑会话时，桥接需与原 Codex 使用相同 OS 用户和 CODEX_HOME，且配置该会话的实际项目目录。兼容的原生 daemon 在线时可实时共享；其他用户、容器或 no-daemon 独占会话不一定支持。
- Tailscale 使用用户态模式且未显示 100 开头地址时，可在首次启动后台前设置 CLAWMATE_TAILSCALE_SOCKET=/实际路径/tailscaled.sock。已有后台须在空闲时先退出，才会继承新环境变量。
- 新任务默认允许工作目录内修改并请求批准。超时检查网络、status、服务端口与 Tailscale 策略；不要通过关闭 TLS 校验解决证书错误。

## 相关链接

- [下载连接器](https://github.com/doulujiyao12/mobiinfra-oh/releases/tag/codex-bridge-v1.1.11)

<!-- 内容源：entry/src/main/ets/pages/codex/CodexHelpContent.ets；通过 scripts/check_codex_help.cjs --write-docs 同步。 -->
