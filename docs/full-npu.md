# 全图 NPU（实验）

此模式独立于原来的全 CPU、在线 NPU 和离线 OM（ViT）模式。需重新构建并安装
包含本次源码的 App；`libMNN.so` 不需要替换。x86_64 云端 UI 构建不执行本地推理。

模型仓库：
https://www.modelscope.cn/models/fengerhu1/mobi_2B_full_npu_kirin9030_w4a16_g64_kv8

在设置的模型下载地址中清空旧内容，填写上述仓库地址，下载到独立模型目录。
保持原模型目录，以便切回原来的三种模式。新包约 3.18 GiB，包含 25 个 `.omc`
文件、tokenizer 和静态视觉常量，不包含 CPU `.mnn` 模型。请勿混用两类模型包。

1. 在 App 设置中开启 **Debug**，然后选择新下载的全图模型和 **全图 NPU**。
2. 加载模型。初次加载逐图检查兼容性和实际 tensor 描述，会比较慢；失败直接报错，
   不会转到 CPU 或在线编译。日志包含 `[FULL_NPU]`、实际 dtype/shape、KV 字节数。
3. 新建聊天，先发“请简单介绍一下你自己”，再分别用几张明显不同的图片新建聊天，
   询问“这张照片中是什么内容”。检查主要对象和场景是否与图片有关。
4. 观察流式输出、停止生成、清空聊天，再重新发送。测试完成后用 **Runtime Logs**
   查看/导出日志；重点保留从模型加载到回答完成的完整记录。
5. 日志应有 embedding、vision_pre、vision_blocks、vision_post、llm_prefill、
   llm_decode、lm_head 的 `level=exec_ok`，以及 `level=request_complete`。
   同时核对 `cpu_fallback=0`、`npu_error=0`。模型加载时的 descriptor 或兼容性
   错误也很重要。`graph_ready` 随卸载/重载会累加，不是固定 25。
6. 切回旧模型与旧执行模式，确认原来的 CPU/在线/ViT 离线推理仍正常。

模型结构的 embedding、ViT、LLM、LM head 全部由离线 NPU 图计算；CPU 负责
tokenizer、图片解码/缩放、位置/mask、KV 编码和贪心采样。完整模型被拆为静态
图调度，prefill 每块 128 token，decode 每次 1 token。先释放视觉图，再运行
prefill；切换 decode 前释放 prefill，避免两阶段权重同时常驻。实际 NPU 内存
峰值、速度和设备 tensor 接口仍需要真机日志确认。

权重为 W4A16/group64/GPTQ；KV 为 INT8/group32、FP32 scale，首 4 和最近 128
token 另存 FP16。KV 常驻存储约 140.44 MiB。固定最大上下文 **2048 token**，
包括历史、角色模板、图片和生成内容；每图固定缩放为 256×608，使用 152 token。
默认最多生成 256 token，可在 `config.json` 的 `runtime.max_new_tokens` 修改。
超出容量时明确报错，不截断图片或静默改变位置。文本和静态图片可用，音视频不支持。

当前模式每次请求重建完整聊天 KV；Agent 保存 prefix 文本，每步拼接变量并重新
prefill，不复用或擦写旧 prefix KV。保留了旧模式的 Agent KV 复用实现。

主机 C++ 调度已与相同冻结权重的 ONNX 参考检查 token、M-RoPE、mask、DeepStack
和实际 INT8/FP16 KV 输入；短文本和图片通过。JPEG 解码/缩放与 PIL 有小差异。
原 INT8 KV 长上下文相对 L2 门槛 0.05 **没有通过**，发布包保留原始失败报告。
这次没有真机测试，不能把主机检查或编译成功当作设备精度已对齐。

源文件位于 `entry/src/main/cpp/full_npu/`；来自 MobiInfer 的同步清单在
`sources.json`。修改 MobiInfer 的 portable runtime 后可运行：

```bash
python transformers/llm/export/kirin_llm_offline/sync_app_runtime.py \
  --app /path/to/mobiinfra-oh
```

该命令只同步 `full_npu/`，不会改 App 的旧执行器、配置入口或 `libMNN.so`。

## 加载错误 `Offline NNRT build failed: 1`

这份旧错误信息把设备设置、执行设备/回退选项和 Build 的失败合并成了同一句话。
不能据此判断量化参数错误。按源码顺序第一张检查的是约 594 MiB 的
`embedding_decode` 浮点图；实际失败图须以更新后的日志为准。

更新源码后重新构建安装 App，保留现有下载的模型，开启 Debug 再加载。
保留从 `level=probe_begin` / `level=load_begin` 到错误的整段记录：新日志包含
图名、文件大小、HiAI 版本、各 API 返回码、以及 Build 前后内存信息。
例如 `graph=embedding_decode step=OH_NNCompilation_Build ret=OH_NN_FAILED(1)`
才明确表示该图在 Build 步骤失败；如果是选项设置失败，会记录对应 API。

初始化增加与原 ViT 执行器一致的 NORMAL 带宽设置，KV 存储延后到图检查完成后
分配。这些调整尚未在设备验证，不能宣称已经解决加载问题。不需要重新下载模型。

## 源码复核补充（2026-10-16）

全图运行时现在在调用 NNRT 前检查配置与全部图接口的一致性，包括 KV/视觉输出
尺寸、DeepStack 和端口顺序，避免配置不一致时特征拷贝越界。流式输出补充 UTF-8
续字节检查和结束时残留字节处理。NNRT 输入还会检查元素数及 dtype，拒绝 FP16
溢出。Agent 若生成空响应会明确报错。

LLM Op Profile 页面会按模型格式选择全图模式，直接加载原始 `config.json`，
不再写入 CPU 预设副本。全图模型不参与 CPU 线程预设扫描；单次 Profile 的分图
耗时需开启 Debug 并查看 Runtime Logs，没有 OMC 内部逐算子的排名。

这些修正需要重新构建 App，不需要重新编译或下载模型。固定图片尺寸可能拉伸
横图；本地聊天没有自动压缩历史，达到 2048 token 后请新建/清空聊天。
此前 `ret=1` 仍待设备日志确认，源码检查与主机参考测试不能证明设备加载已修复。
