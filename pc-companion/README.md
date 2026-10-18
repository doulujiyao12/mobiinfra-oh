# ClawMate Codex PC companion

面向用户的说明：[使用指南](USER-GUIDE.md)。最终用户安装桌面版或解压终端版，不运行 npm，也不需要源码。

桌面版使用 Electron 的隔离界面；终端版通过 Go 编译的本机入口启动随包附带的 Node 与官方 Codex。两者共用仅在本机提供的有鉴权控制通道和同一套配置。手机仍通过 HTTPS 调用既有任务接口。

## 维护者构建

以下命令只用于开发和发行。需要 Node.js 22.12+、Go 1.23+、curl、tar，以及目标平台的打包工具。

```bash
npm ci --prefix pc-companion
node pc-companion/build/prepare-runtime.mjs linux-x64
node pc-companion/build/stage.mjs linux-x64
node pc-companion/build/distribute.mjs linux-x64
```

`linux-x64` 可替换为 `linux-arm64`、`win32-x64`、`win32-arm64`、`darwin-x64`、`darwin-arm64`。桌面安装包由对应平台构建；终端包可以交叉构建。

`runtime-lock.json` 固定官方运行时的版本与哈希。构建必须匹配已提交的校验值，不读取运行时的 latest 标签。维护者升级运行时版本时，先调整 `build/resolve-runtime-lock.mjs`，生成新锁文件并审查后再构建。

```bash
node pc-companion/build/resolve-runtime-lock.mjs
```

构建结果在 `pc-companion/dist/<目标>/`，包括桌面安装包、终端压缩包和 `SHA256SUMS.txt`。终端版保留 `bin/`、`runtime/`、`host/` 和许可文件，可安装到任意固定目录。

Linux 桌面版使用 `.deb` 或完整 `.tar.gz`，避免后台服务依赖退出后即卸载的 AppImage 临时挂载目录。macOS 提供 `.dmg` 和 `.zip`，Windows 提供 NSIS 安装程序。

## 测试

```bash
npm test --prefix bridge/codex
npm test --prefix pc-companion
go test -C pc-companion/launcher ./...
```

手机端逻辑检查继续使用仓库的 `scripts/check_codex_logic.cjs`。PC 配对信任使用 RCP `SecurityConfiguration.remoteValidation.content`，手机把公开 CA 放入 Asset Store 的完整性保护标签，避免超过 SECRET 的 1024 字节上限。参考 [华为安全传输配置](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/remote-communication-customsecurityconfig)。

本次 Linux 构建环境已通过 21 个桥接测试、6 个电脑端集成测试、Go 证书测试、ArkTS 逻辑检查，以及实际 Electron 窗口的配置显示、启动和配对检查。打包后的原生入口已实际启动随包 Node 和官方 Codex，完成账户状态读取及 HTTPS 配对；没有提交模型任务。生产 JS 依赖审计为 0 个已知漏洞。Windows/macOS 安装运行与鸿蒙真机仍需要在对应平台验证，逻辑检查不能替代 DevEco SDK 的完整编译。

云端终端配置使用 `clawmate-codex setup --config pc-config.json`。配置示例（所有路径替换为本机绝对路径）：

```json
{
  "name": "我的云端开发机",
  "host": "0.0.0.0",
  "port": 8787,
  "networkMode": "public",
  "publicOrigin": "https://codex.example.com:8787",
  "certFile": "/private/tls/fullchain.pem",
  "keyFile": "/private/tls/privkey.pem",
  "workspaces": [{ "name": "我的项目", "path": "/srv/projects/my-app" }]
}
```

随后运行 `clawmate-codex login`、`clawmate-codex start` 和 `clawmate-codex pair --output phone.clawmate-codex-pair.json`。私钥必须位于项目目录以外；终端配对文件包含短期秘密，不应公开发布。

## 发行

`.github/workflows/codex-companion.yml` 提供多平台构建和独立安装包的冒烟检查。默认只上传 CI 构建产物，不发布公共版本。生产模式要求维护者提供 Windows 代码签名与 Apple Developer ID / notarization 凭据，随后以受保护的发行渠道提供下载。

本地 Linux 交叉构建的 Windows 评估安装包启用 `CLAWMATE_UNSIGNED_TEST=1`，使用独立的 Development 安装目录与卸载项，并在安装时生成未签名卸载程序，因此无需 Wine。原生 Windows CI 和生产构建继续使用标准 NSIS 安装、签名流程。Linux 上生成的 Mac 测试包为包含 `.app` 的 zip；DMG、签名和公证在 macOS CI 完成。

CI 的 Windows 签名使用 `WINDOWS_CSC_LINK`、`WINDOWS_CSC_KEY_PASSWORD`；macOS 使用 `MAC_CSC_LINK`、`MAC_CSC_KEY_PASSWORD`，并需要 `APPLE_ID`、`APPLE_APP_SPECIFIC_PASSWORD`、`APPLE_TEAM_ID`。本机 electron-builder 构建仍使用标准 `CSC_LINK` / `CSC_KEY_PASSWORD`。这些是发行者的签名凭据，不是用户的 OpenAI 凭据。未签名开发包不能冒充可直接上架的正式发行包。

对外上架鸿蒙 App 前，先完成 Windows/macOS 签名发行、下载地址配置、各平台干净机器验证、真机配对及 App 隐私声明核对。源码中不会放置发行证书或凭据。

依赖边界：生产 JS 只使用二维码库；证书生成和验证使用 Go/Node 标准加密库。Codex、Node、Electron 和生产 JS 依赖的许可与声明随安装包提供。上游登录、模型套餐和账号权益由 OpenAI 决定，本应用不承诺任何模型调用权益。
