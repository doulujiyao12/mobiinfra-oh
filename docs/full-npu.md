# 全图 NPU（实验）

## 2026-10-17：缓存恢复与稳定数学候选

保存的手机请求日志显示，25 tokens 生成耗时 59.17 秒，其中图加载/切换 54.52 秒，
缓存命中为零。虽然模型配置是四图、2048 MiB 模型预算和 256 MiB KV 池，实际
表现为单图循环淘汰，每次完整同步 224 MiB KV。最初的退让触发日志没有保留。

修复后的后端在资源失败时逐图淘汰并重试，优先保留整个 decoder；KV 池只在
释放模型仍不足时才清除。新请求和 prefill→decode 切换恢复配置预算，避免此前
一次压力永久影响后续请求。张量格式查询失败时禁止跨 executor 共享，但同一个
executor 的 KV 输入继续增量同步。诊断新增实际预算、KV 格式查询及 sample token ID。

图与权重已经分离：OMC 与独立 `.weight` 文件通过 InitWeights 配对加载。
主干矩阵保持 W4/group64/GPTQ，KV 为 FP16；设备权重共享没有被假定为已实现。

稳定数学模型候选在 RMSNorm 平方前缩放，在 QK MatMul 前分配缩放，并显式
稳定 Softmax。对应数学/溢出单元测试通过；其目的是规避 FP16 中间值风险，
尚未证明已消除手机上的全部数值偏差。需新 App 配合新模型包；旧包不会自动
得到模型图内的修复。本轮未连接手机，没有安装 App 或执行新模型。

候选模型：
https://www.modelscope.cn/models/fengerhu1/mobi_2B_full_npu_kirin9030_w4a16_g64_kv16_stablemath_v1

37 个文件（2,785,113,131 字节）已核对远端 SHA256 和大小。请在 App 设置中
使用该地址并下载到独立目录；需在 DevEco 重新构建 App，源码更新不会自动
升级手机应用。本轮没有构建 HAP、安装 App 或连接手机。

13 张图完成纯 NPU 编译，301 个主干矩阵的 W4 编码核对通过。35 项 Python/SDK
测试和九组 C++ 测试通过；实际 App C++ 调度器在三条文本和一张图片的 CPU
ONNX 回放中通过 2928 项独立张量检查。回放未执行 OMC，端侧速度与正确性未验收。
新旧 CPU 首 token logits 最大 relative L2 为 0.0929；新候选逐图 Torch/ONNX
最大 relative L2 为 0.01555，二者比较对象不同。此前 W4 质量和长上下文 FP16 KV
检查的失败没有被宣称解决。

## 上一版候选：外置 W4 权重与 FP16 KV

### 首图提示 InitWeights 接口未找到

用户日志在首张 `embedding_decode` 的 Build 前失败，尚未执行模型或 KV。
旧代码只查 `RTLD_DEFAULT` 全局符号表，不能据此确定设备库没有该函数。
已改为先打开 `libhiai_foundation.so`，从库句柄查符号，再尝试全局兼容路径，
并将句柄保留到 executor/compilation 都销毁后。模型包、量化参数无需更换。

重新构建并安装本次 App。Debug 日志会新增：
`step=resolve_HMS_HiAIExecutor_InitWeights`，包含 `hiai_version`、`dlopen`、
`lookup`、`provider` 和动态加载器错误。若找到接口，继续观察
`step=HMS_HiAIExecutor_InitWeights ret=OH_NN_SUCCESS(0)`。
若仍是 `result=unresolved`，需要保留该行和后续错误；显式库查找也失败后，
当前 App 可访问的库无法初始化该外置权重模型，不会通过跳过 API 假装加载成功。

主机使用真实 RTLD_LOCAL 共享库复现了旧实现失败、新实现通过；包含局部库、
缺符号、缺库场景的九组 C++ 检查通过，另编译验证 App 中同步的源文件。
手机是否真正导出接口仍待新日志确认；没有执行真机或 HAP 构建。


2026-10-16 新增 `kirin_full_npu_runtime_v2` 加载支持。它需要**重新构建 App，
并使用新的外置权重模型包**；下面的 ModelScope `embsplit` 地址属于旧包，
仅更新 App 后继续打开旧包，不会自动变成此结构。

新模型仓库：
https://www.modelscope.cn/models/fengerhu1/mobi_2B_full_npu_kirin9030_w4a16_g64_kv16_external

远端 40 个文件已校验大小及 SHA256，完整模型约 2.59 GiB。在 App 设置中将
模型下载地址换成该仓库，下载到独立目录，再选择 **全图 NPU** 并加载。
本工作区 App 源码已包含新格式、外置权重初始化和 FP16 增量 KV 支持；需要在
DevEco 重新构建并安装，手机上的现有 App 不会因源码更新而自动升级。

新构建采用 13 张 OMC：28 层主干 prefill/decode 各一张，embedding 各一张，
共用 head 及八张视觉图。OMC 本体与 `SubGraph_0.weight` 分离；顺序参考
MindSpore Lite 的 Build → Construct executor → `HMS_HiAIExecutor_InitWeights`
→ tensor 接口检查。缺少该设备 API 会明确报错；不能仅凭本机编译推定设备库支持。

主要矩阵权重仍为 SDK W4/group64 GPTQ，embedding、位置表等保留 FP16。
不是将浮点权重改名为 `.weight`。量化使用 SDK INT16 激活；新候选只扩大输出
范围 4 倍以缓解已复现的截断，输入和 W4 权重的量化范围不变。

解码目标为 embedding、整段 LLM、head 三个模型常驻，热身之后不再每 token
重建图。最多四图、模型文件与外置权重总预算 2048 MiB；该预算不是设备实际
内存占用。prefill 转 decode 时释放旧阶段。只按文件名及 SHA256 完全一致的
权重做磁盘去重，不宣称跨 executor 共享设备权重。

FP16 KV 宿主 224 MiB，独立 NNRT 输入池另需 224 MiB，配置池上限 256 MiB。
首次同步整份；随后 28 层每新增 token 写入约 112 KiB。`run_timing` 的字节数
只反映宿主写 NNRT 缓冲区，固定容量 attention 和设备内部开销仍存在。

文本十条和非校准图片三张已做 CPU 参考审计，相关性有改善，仍存在事实、OCR
及细节错误。三张图片首 token logits 相对浮点参考的 L2 约 0.53–0.57，不能
称为精度对齐。FP16 KV 长上下文检查中逐层 KV L2 约 0.2759，原门槛 0.05
**未通过**，即使此例九次贪心 token 都一致也保留失败状态。

需要同时检查正确性及速度。新包日志应出现 `external_weight_bytes`、
`step=HMS_HiAIExecutor_InitWeights ret=OH_NN_SUCCESS(0)`，热身后三个解码
组件均为 `cache_hit`。若 `cache_backoff` 出现，已退回单图/完整同步，不能
按三图常驻评价性能。初始化逐图 probe 与首次切换阶段仍有加载开销。

主机完整验证：13/13 图纯 NPU 编译、301 个矩阵 UINT4/LUT 逐值核对、
32 项 Python（含 SDK）和六组 C++ 测试通过。实际 App 复制源码构建的主机
调度器在五个文本/图片场景中通过 2985 项独立 tensor 检查；该检查使用 CPU
ONNX 参考，不是 OMC 数值或端侧速度验收。

模型审计和复现命令见 MobiInfer 的
`transformers/llm/export/kirin_llm_offline/README.md` 与
`evidence_external_w4_kv16/`。本机未构建 HAP、未操作手机，真机 InitWeights、
常驻峰值内存、吞吐和数值结果待验证；`libMNN.so` 未替换。

## 旧内嵌权重包与既往验证记录

此模式独立于原来的全 CPU、在线 NPU 和离线 OM（ViT）模式。需重新构建并安装
包含本次源码的 App；`libMNN.so` 不需要替换。x86_64 云端 UI 构建不执行本地推理。

模型仓库：
https://www.modelscope.cn/models/fengerhu1/mobi_2B_full_npu_kirin9030_w4a16_g64_kv8_embsplit

此为 embedding 分片包，必须使用包含 `embedding_slices` 支持的新 App。
用户最新日志确认全部图逐图加载通过，实际推理在 `llm_prefill_5` 创建 executor
失败；单图版本已能继续生成，但用户反馈速度很慢、回答不相关。
当前改用有界常驻及 KV 增量同步，方案及验证见文末。
原始未分片全图包在用户设备的第一张 `embedding_decode` Build 时失败。

在设置的模型下载地址中清空旧内容，填写上述仓库地址，下载到独立模型目录。
保持原模型目录，以便切回原来的三种模式。新包约 3.18 GiB，包含 39 个 `.omc`
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
图调度，prefill 每块 128 token，decode 每次 1 token。当前后端按数量及模型文件
预算保留部分图，KV 输入张量独立持有并按新增行同步；资源压力时退回单图及完整
同步。不改变 OMC、量化参数或上下文容量，速度和正确性须真机复验。

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
用户真机已通过逐图加载并执行部分 prefill，尚未完成回答；不能据此认定设备精度已对齐。

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

## embedding 分片加载候选

用户新日志已确认：HiAI `109.636.120.010` 上，622337527 字节的
`embedding_decode` 通过兼容性检查和全部选项设置，随后
`OH_NNCompilation_Build` 返回 `OH_NN_FAILED(1)`。此时尚未运行 KV、LLM 或 ViT。

OpenHarmony NNRT 公开源码在模型超过 200 MiB 时会进入额外鉴权路径；这提供了
大 embedding 失败的具体线索，不能代替本机私有 HiAI 后端的系统日志。
没有修改、跳过系统鉴权，也没有启用 CPU embedding fallback。

修复候选将原 embedding 表按 hidden 切成 8 片，prefill/decode 各 8 张 NPU
Gather 图，每张约 74.20 MiB。CPU 按行拼接结果，每片用后单独释放；当前修正
同时限制 decoder/head 的常驻数量。其余 23 张 OMC 和量化参数不变，最大图为约 177.44 MiB 的
LM head。代价是每个 decode token 会多次加载 embedding 子图，设备速度待测。

每片全部权重核对一致、Torch/ORT 相对 L2 为 0，16 图均编译成纯 NPU；新包
短文本/图片主机回放通过 4484 项张量检查，5 组 C++ 测试通过。主机测试使用
NNRT 调用替身；用户已确认逐图加载通过，完整执行、精度和性能仍未确认；本机未构建 HAP。

这次必须同时重建安装 App，并从页首的新仓库下载到独立目录。不要覆盖旧包的
已下载文件；只更新 App 再打开旧包仍会加载原来的 594 MiB 图。无需更换 libMNN。
开启 Debug，加载日志应出现 `embedding_decode_slice_0` 到 `_7`，之后继续检查
其余模型。若仍失败，请导出 App Runtime Logs，并在 DevEco 的 HiLog 窗口取消
仅本 App/PID 的过滤，保留相同时间的 NNRT、HiAI、dllite 等系统日志；重点查找
`AuthenticateModel`、`Authentication failed`、`CheckExceedRamLimit`、内存分配失败。

本次没有操控手机，原有 CPU/在线/ViT 离线执行分支不变。


## 推理时 `llm_prefill_5: Cannot construct NNRT executor`

最新用户日志中全部 39 张 OMC 逐图检查成功；实际请求的 ViT、embedding、
`llm_prefill_0` 至 `_4` 执行成功，第五号图的 Build 也成功，但 executor 创建失败。
这与之前大 embedding 在 Build 失败不同，当前证据指向多图常驻的资源压力或
服务调度限制，具体系统原因还需 HiLog。App RSS/CmaFree 不能代表全部 NPU 占用。

上一版修正 `NnrtBackend.cpp`：切换图时先释放上一张图的设备 tensors/executor，
再 Build/创建新图，prefill/decode/embedding/head 都最多常驻一张。宿主 KV 和
中间输出保留，W4A16、KV8 和模型文件均未改变。此方式会增加模型加载耗时。
新增 `resident_evict`、`resident_policy=single_graph` 和
`step=OH_NNExecutor_Construct result=success/nullptr` 日志；失败记录资源快照。

主机 5 组 C++ 测试通过，新增 NNRT 替身测试在只允许一个 executor 的条件下
连续完成两块 prefill、四步 decode（每块 7 段）；也检查创建失败清理与重试。
这不代表真实 SDK 或真机已经修复。本机没有构建 HAP，也没有操控手机。

这次只需重新编译安装 App，继续选择已下载的 `embsplit` 模型，无需重新下载。

1. 完全关闭旧 App，再启动新构建的 App，开启 Debug，选择全图 NPU 并加载模型。
2. 新建聊天，先测短文本；再新建聊天，测试图片问题，等待完整回答。
3. 日志中切换 LLM 图前应有 `resident_evict`；加载时应有
   `resident_models=0 resident_policy=single_graph`，随后 executor 创建成功。
4. 检查 `llm_prefill_5` 和 `_6` 的 `exec_ok`、图片请求后续 `past=128` 的 prefill、
   decode 和 `lm_head`，最终应出现 `level=request_complete`，`npu_error=0`。
5. 如果仍失败，导出完整 App Runtime Logs，并保留同一时刻不按 App/PID 过滤的
   NNRT、HiAI、dllite 系统日志，重点关注 executor 创建/准备、调度及内存分配失败。


## 有界常驻与 KV 增量同步（当前版本）

单图版本已由用户运行到 `past=198` 的 decode，并反馈能生成、但很慢且答非所问。
当前改动仅优化调度和 KV 输入拷贝，原有量化精度问题仍未解决。已更新 MobiInfer
和 App 的 full_npu 源码，模型文件及 libMNN.so 未改变；重新构建安装 App 即可，
继续使用现有 embsplit 包，不必重新下载。

默认最多保留 4 个 executor、模型文件总量预算 640 MiB。优先保留 LM head 和
靠前的 LLM 段，给其余图留出流式加载位置；当前模型稳态可保留 head、decode_0、
decode_1，模型加载从每 token 16 次降至 13 次。此为调用次数，真实速度尚待实测。
文件预算不是实际 NPU 内存；另有 KV 输入、激活和驱动工作区。

KV 输入张量独立于 executor 持有，上限默认 192 MiB；本模型约需 140.44 MiB，
宿主仍保留原压缩 KV，因此这会增加常驻内存。首次完整同步；随后只复制新增历史
行及 recent 环形槽位。prefill/decode 的 KV 端口在设备、格式、dtype、shape
一致时复用。完整请求结束、重置及取消会释放池，缓存世代变化和错误重试会重新同步。

稳态每个 4 层 LLM 图的 `kv_copied_bytes` 应约为 25600（25 KiB），7 段合计
179200（175 KiB），而 `kv_full_bytes` 每段约为 21037056。首次同步和 prefill
尾块追赶会更大。此数值是宿主写入 NNRT 缓冲区的字节数，不是 SDK 内部总流量。
固定长度 attention 和图内反量化没有改变。

Build、executor 创建或 tensor 分配在已有资源时失败，会清理模型及 KV 输入池，
退回单图/完整同步后重试一次；有 `level=cache_backoff` 记录，并持续到模型重新
加载。此回退始终使用离线 NPU，不转 CPU；永久错误仍返回，不会无限重试。

运行配置的 `runtime` 可选参数（旧包缺省即采用以下配置）：

```json
"npu_max_resident_graphs": 4,
"npu_resident_model_mib": 640,
"npu_persistent_kv_mib": 192,
"npu_incremental_kv": true
```

可用 `1 / 640 / 0 / false` 做单图完整同步对照。修改测试配置时保留下载包校验要求，
避免原地修改受下载清单管理的文件；默认配置测试不需要改模型包。

复验步骤：

1. 重新构建并安装 App，开启 Debug，选择现有全图模型并加载。
2. 新建短文本聊天，再新建图片聊天，先确认完整请求结束及记录实际回答。
3. 稳态应看到 `level=cache_hit`，尤其 head、decode_0、decode_1；同时看
   `level=run_timing` 的 `input_copy_ms`、`run_sync_ms` 和 KV 字节数。
4. 若出现 `cache_backoff`，保留其前后完整日志：该请求后续可能已恢复单图模式，
   不能再按 4 图命中或 175 KiB 评价性能。未发生回退但部分端口不能持久化时，
   `kv_copied_bytes` 也会更大，应结合 `persistent_kv_bytes` 判断。
5. 测试停止、清空聊天后重试，确认缓存没有串用；关闭 Debug 再测端到端速度。
6. 测速和回答相关性分别记录；本次优化不代表此前答非所问已经修复。

6 组 C++ 检查和短文本/图片共 4484 项 CPU 参考回放通过；包含受限 executor、
创建/分配失败、不同 tensor 格式隔离、窗口环绕、长跳、重置及完整缓冲区逐字节
对照。调用替身验证不能代替真实 HiAI SDK；本机未构建 HAP，也未操作手机。
