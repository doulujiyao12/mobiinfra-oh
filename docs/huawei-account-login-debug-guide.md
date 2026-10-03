# 华为账号登录与本地调试配置总结

更新时间：2026-10-01

## 结论

- 本机调试华为账号登录，仍然需要在 AppGallery Connect 中登记或关联应用。
- 不需要申请所谓的“Account Kit 专用签名”。
- 当前工程的自动 debug 签名可以先继续使用，不必立刻改成手动签名。
- 该应用之前已经提交过，因此通常不需要重新创建应用，应直接复用 AppGallery Connect 中已有的应用记录。

## 当前工程情况

当前开发环境与工程配置如下：

- DevEco Studio：`6.1.1.280`
- `compatibleSdkVersion`：`6.0.0(20)`
- `targetSdkVersion`：`6.1.1(24)`
- 当前签名：DevEco Studio 自动生成的 debug 签名
- 当前包名：以 `AppScope/app.json5` 中的 `app.bundleName` 为准

华为当前文档指出，Account Kit 因自动签名导致证书校验失败的限制，主要针对运行在 HarmonyOS `6.0.0(20)` 以下的应用。当前应用的最低兼容版本已经是 `6.0.0(20)`。官方也说明，当 `compatibleSdkVersion >= 20` 或基于 HarmonyOS 6.0 以上 ROM 开发调试时，不再要求手动配置公钥指纹。

参考资料：

- [Account Kit 指纹校验 FAQ](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/account-faq-1)
- [华为开发者月刊相关说明](https://developer.huawei.com/consumer/cn/monthly/202511)

因此建议先采用以下最短路径：

1. 保留当前自动 debug 签名。
2. 将工程关联到 AppGallery Connect 中已有的应用。
3. 配置正确的应用 Client ID。
4. 在真机上测试普通华为账号登录。
5. 只有出现 `1001500001` 指纹证书校验失败时，才考虑配置手动 debug 签名。

## 本地调试是否必须登记 AppGallery Connect

必须登记或关联应用。

即使应用尚未上架、只在本机调试，Account Kit 仍需要确认：

- 应用属于哪个华为开发者；
- 应用的包名；
- 对应的 APP ID 和 Client ID；
- 当前安装包是否具有合法的应用身份。

这里进行的是“登记开发应用”，不等于再次提交审核，也不要求应用已经上架。

由于该应用之前已经提交过，推荐按以下方式操作：

1. 登录原来提交应用使用的华为开发者账号。
2. 进入 AppGallery Connect 的“我的项目”。
3. 找到之前提交过的应用。
4. 确认登记的包名是否与 `AppScope/app.json5` 中的 `app.bundleName` 完全一致。
5. 在项目设置中找到该应用的 APP ID 和 Client ID。
6. 在 DevEco Studio 的签名配置中保留自动签名，并关联这个已注册应用。

不要为了调试再创建一个相同包名的新应用。如果 AppGallery Connect 中登记的包名与当前工程包名不一致，需要先确定最终上架使用的包名。

## 登录方式选择

应选择普通“华为账号登录”，不要选择需要手机号的“华为账号一键登录”。

### 普通华为账号登录

- 对应 `LoginType.ID`；
- 不需要获取手机号；
- 不需要申请手机号权限；
- 个人和企业开发者均可使用；
- 适合当前仅为了满足审核登录要求的场景。

### 华为账号一键登录

- 对应 `LoginType.QUICK_LOGIN`；
- 主要用于获取手机号；
- 通常面向企业开发者；
- 涉及额外权限申请和服务端交互；
- 当前应用不需要使用该方式。

华为官方说明，普通账号登录可以使用标准登录按钮，并且无需额外申请用户资料权限。

参考资料：[Account Kit 官方介绍](https://developer.huawei.com/consumer/cn/sdk/account-kit)

## 无服务器的最小登录方案

如果不提供服务器，可以实现一个最低限度的本地登录流程：

1. 显示官方“华为账号登录”按钮。
2. 用户点击后拉起系统华为账号登录页面。
3. Account Kit 返回登录成功后进入应用主页。
4. 不申请头像、昵称、手机号等 scope。
5. 仅在应用本地保存登录返回的 OpenID 与会话版本，用于查询华为账号状态；不保存授权码或身份令牌，不向云端模型发送 OpenID。
6. App 与小艺扩展从应用级沙箱读取同一账号标识，使用 `HuaweiIDProvider.getHuaweiIDState` 确认状态；仅 `AUTHORIZED` 放行。App 退出登录同时清空共享账号标识。

当前实现使用登录按钮凭据中的 `openID`，并以 `IdType.OPEN_ID` 调用官方状态接口。不将持久化的“已登录”布尔值当作有效登录，也不把手机系统已登录自动当作用户已登录本应用。若官方状态接口失败或超时，说明“暂时无法确认登录状态”，不直接说用户没有登录。

参考资料：[Account Kit 登录接口](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/account-api-authentication)

状态查询依据：[华为账号登录状态管理](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/account-login-state)。本机 API 24 SDK 的 `@hms.core.authentication.d.ts` 已核对 `getHuaweiIDState(StateRequest): Promise<StateResult>`、`IdType.OPEN_ID` 与三种状态枚举，该接口从 API 12 起提供。

该方案用于本机 App 与小艺扩展共享登录状态。个人记忆读取仍需独立的隐私同意和小艺读取开关；若未来增加服务端账号数据或支付，应通过服务端使用 Authorization Code 验证身份。

## 推荐实施顺序

### 当前开发调试阶段

1. 复用 AppGallery Connect 中之前提交的应用。
2. 确认包名与当前工程完全一致。
3. 保留自动 debug 签名。
4. 接入普通华为账号登录。
5. 不请求任何额外用户资料。
6. 使用登录成功结果放行进入应用主页。

### 正式再次提交前

1. 配置正式 release 签名，或使用华为云管理签名。
2. 使用 release 包重新测试登录流程。
3. 从 debug 签名切换到 release 签名时增加 `versionCode`，避免相同版本使用不同证书引发校验问题。
4. 在隐私政策中说明应用使用华为账号服务完成登录，同时说明不获取头像、昵称和手机号等资料。

## 2026-10-01：修复小艺提示未登录

旧实现只在 `AppStorage` 保存本次运行时的登录标记，登录按钮回调丢弃了返回的账号标识。小艺扩展读不到该标记时，即使 App“我的”页面显示已登录，也会返回登录提示。现由 `HuaweiAccountSession.ets` 保存并核验共享会话；应用回到前台与账号卡片显示时也会恢复状态。校验后再次读取会话版本，防止校验期间退出登录后旧回调恢复授权。

旧版本没有保存 OpenID，更新后需要在 App“我的”中重新登录一次，让新版写入共享会话。之后扩展重建可以通过官方状态接口核验，无需每次重新登录。小艺开放平台、AgentCard、包名、签名及 Client ID 无需为本修复调整。当前仅完成静态检查，未编译或真机验证。

综上，当前确实需要在 AppGallery Connect 中操作，但主要是复用并关联已有应用，而不是申请一个 Account Kit 专用签名。
