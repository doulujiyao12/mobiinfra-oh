# 签名与已保存的授权信息

邮箱授权码和 Codex 配对令牌存储在 HarmonyOS ASSET 中，没有写入任务配置、日志或普通文件。当前使用的是按应用属主隔离的安全存储。

ASSET 使用系统提供的应用 `appId` 与别名定位数据。`appId` 含包名和签名证书公钥；它不同于 AGC 分配的稳定 `appIdentifier`（APP ID）。重新生成签名私钥，即使包名不变，也可能改变安全存储属主，导致旧授权码和配对令牌无法读取。业务代码不能自行指定旧属主来取回它们。

- 正常开发、覆盖安装和升级请复用原签名密钥；不要为每次编译生成一套新密钥。
- 只更新 Profile、设备列表或证书有效期，与更换签名私钥不是同一件事。关键是最终安装包的签名身份是否保持一致。
- 更换包名是另一套应用沙箱和安全身份，不会自动继承原包名下的授权信息。
- 已更换签名且无法读取旧凭据时，使用原签名身份恢复，或重新填写邮箱授权码、重新配对 Codex。重新配对无需删除电脑上的项目或会话。
- 不把授权码或令牌改存明文来规避身份隔离，也不使用稳定 APP ID 伪造 ASSET 的属主。群组共享、受支持的证书轮换等平台方案需要额外的签名/Profile 配置，不能靠修改普通应用别名恢复既有属主数据。

官方说明：

- [Asset Store Kit 简介与身份隔离](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/asset-store-kit-overview/)
- [appId 与应用签名的关系](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/common-problem-of-application/)
- [稳定的 appIdentifier 与 SignatureInfo](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-v5/js-apis-bundlemanager-bundleinfo-V5/)
