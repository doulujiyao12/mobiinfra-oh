# 华为账号登录与本地调试配置总结

更新时间：2026-09-03

## 结论

- 本机调试华为账号登录，仍然需要在 AppGallery Connect 中登记或关联应用。
- 不需要申请所谓的“Account Kit 专用签名”。
- 当前工程的自动 debug 签名可以先继续使用，不必立刻改成手动签名。
- 该应用之前已经提交过，因此通常不需要重新创建应用，应直接复用 AppGallery Connect 中已有的应用记录。

## 当前工程情况

当前开发环境与工程配置如下：

- DevEco Studio：`6.1.1.280`
- `compatibleSdkVersion`：`6.0.0(20)`
- `targetSdkVersion`：`6.0.2(22)`
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
5. 不上传、保存或展示用户信息。
6. 仅在本地维护当前登录状态。

登录凭据本身可能仍包含 OpenID 或 UnionID，但应用可以不保存、不使用这些字段。华为官方允许客户端获得这些字段；如果应用存在账号数据、支付或敏感业务，则建议通过服务端使用 Authorization Code 完成安全验证。

参考资料：[Account Kit 登录接口](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/account-api-authentication)

当前应用没有云端账号数据、支付或需要登录保护的敏感业务，因此无服务器方案适合作为最低限度的审核登录流程，但不应将它作为重要业务的安全认证机制。

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

综上，当前确实需要在 AppGallery Connect 中操作，但主要是复用并关联已有应用，而不是申请一个 Account Kit 专用签名。
