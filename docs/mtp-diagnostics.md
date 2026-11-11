# MTP 实际执行诊断

App 使用 MNN 已有算子回调检查 MTP draft 是否执行，不修改 `libMNN.so`，不读取或输出张量内容。诊断只在“我的 → Debug”开启且当前模型配置 `speculative_type=mtp` 时记录。

## 使用

1. 用 DevEco 重新编译、安装包含本次 C++ 桥接改动的 App。
2. 开启 Debug，然后重新加载 Qwen3.5 模型。App 会仅在内存配置中启用 `enable_debug`；模型目录中的配置文件不被改写。
3. 正常发送一条聊天消息，在 Native 运行日志中查找 `[MTP_DIAG]`。也支持单轮生成、本地摘要、Agent prefill/step 和性能分析入口。

请求开始会记录请求编号、入口、draft 长度、KV 复用设置。观察到第一个 MTP 命名空间算子执行后的回调时，会立即记录证据，例如：

```text
[MTP_DIAG] id=1 request=Chat phase=draft_op_observed op=/mtp/fc/Linear
```

结束时会记录本次请求的结果与计数：

```text
[MTP_DIAG] id=1 request=Chat phase=request_end verdict=MTP_OPERATORS_OBSERVED op_callbacks=... draft_op_callbacks=... status=...
```

| verdict | 含义 |
| --- | --- |
| `MTP_OPERATORS_OBSERVED` | 本次请求观察到 MTP 专属算子的执行后回调，证明已执行 draft 图内的计算；请求本身是否成功还须结合 status、返回结果及错误日志。 |
| `NO_MTP_OPERATORS_OBSERVED` | 普通算子回调有效，但没有观察到 MTP 算子。纯 prefill、单 token 续接或其他回退路径可能出现此结果；不能仅凭这条推断具体回退原因。 |
| `CALLBACKS_NOT_OBSERVED` | 没有收到算子回调，无法判断 MTP 是否运行。可能尚未执行模型、提前失败或该图不提供可用回调。 |
| `RELOAD_MODEL_WITH_DEBUG` | 模型加载时没有准备算子回调。先开启 Debug，再重新加载模型后重试。 |

`draft_op_callbacks` 是命中 `mtp/` 或 `mtp_layers.` 命名空间的算子回调次数，不是 draft 预测次数、接受 token 数或接受率。当前诊断不提供精确接受率，也不据此断言加速；Debug 的算子回调有开销，不用于正式性能对照。

每个请求只写开始、首次 MTP 执行证据和结束摘要，不逐算子刷日志。关闭 Debug 后不采集这些计数或写诊断日志；已加载模型的调试会话元数据会保留到重新加载。若在请求中途切换 Debug，计数仅覆盖 Debug 开启的部分，应在开启后发起一条新请求观察。

回调生命周期由请求作用域管理，提前返回或异常时也会清理；已有性能分析回调同时保留。普通自回归、EAGLE 与全图 NPU 不会被本诊断改为 MTP。
