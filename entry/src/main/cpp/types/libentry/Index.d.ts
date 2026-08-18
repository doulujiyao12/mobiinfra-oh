// Agent Loop 所需的 native API 子集，供 AgentLoopRunner 等工具类按接口引用。
export interface AgentLoopNativeApi {
  chat(userMessage: string, onToken?: (token: string) => void): Promise<string>;
  reset(): string;
  unloadModel(): string;
  agentPrefill(prefix: string): Promise<string>;
  agentStep(variablePart: string, onToken?: (token: string) => void): Promise<string>;
  agentReset(): Promise<string>;
}

// ArkTS 侧引用 libentry.so 的类型声明。这里的函数名必须和 napi_init.cpp Init() 导出保持一致。
export interface LibEntryNative extends AgentLoopNativeApi {
  loadModel: (configPath: string, npuMode?: 'online' | 'offline') => Promise<string>;
  generate: (prompt: string) => Promise<string>;
  profileGenerate: (prompt: string, topK?: number) => Promise<string>;
  cancelChat: () => string;
  copyModel: (src: string, dst: string) => string;
  prepareCustomOpp: (resMgr: Object, sandboxRoot: string) => string;

  omcTest: (modelDir: string) => Promise<string>;
  opTest: (config: string) => Promise<string>;
  cpuCoreBench: () => Promise<string>;

  setConvMode: (mode: string) => string;
  setConvQuant: (mode: string) => string;
  setInt8XScale: (scale: number) => string;
  setCpuPrecision: (mode: string) => string;
  setCpuMemory: (mode: string) => string;

  initLogFile: (path: string) => string;
  getLogs: () => string;
  clearLogs: () => string;
}

declare const native: LibEntryNative;
export default native;

export const loadModel: (configPath: string, npuMode?: 'online' | 'offline') => Promise<string>;
export const generate: (prompt: string) => Promise<string>;
export const profileGenerate: (prompt: string, topK?: number) => Promise<string>;
export const chat: (userMessage: string, onToken?: (token: string) => void) => Promise<string>;
export const cancelChat: () => string;
export const reset: () => string;
export const unloadModel: () => string;
export const copyModel: (src: string, dst: string) => string;
export const prepareCustomOpp: (resMgr: Object, sandboxRoot: string) => string;

// Agent 模式：先 agentPrefill 固定 prefix，再多次 agentStep 复用 KV，最后 agentReset 释放上下文。
export const agentPrefill: (prefix: string) => Promise<string>;
export const agentStep: (variablePart: string, onToken?: (token: string) => void) => Promise<string>;
export const agentReset: () => Promise<string>;

// OMC 视觉分块 NPU 测试入口。
export const omcTest: (modelDir: string) => Promise<string>;

// 算子精度测试（CPU vs HiAI delegate）。
// config: "preset" 使用内置测试集；或 "ic,oc,ih,iw,kh,kw,sh,sw,group" 指定单个卷积形状。
export const opTest: (config: string) => Promise<string>;
export const cpuCoreBench: () => Promise<string>;

// HiAI conv-path override for A/B testing: 'auto' | 'matmul' | 'conv'
// Must be called before opTest (read during HiAI compileHiAIModel via HIAI_CONV_MODE env).
export const setConvMode: (mode: string) => string;

// HiAI int8 quant-path override: 'auto' | 'on' | 'off' | 'full' | 'matmul_int8'
//   auto / on (default): weight-only int8 — filter int8 per-OC, x stays fp32,
//                        CUBE MAC is fp16. int8 just compresses weight storage.
//   full:                int8×int8 CUBE MAC inside QuantizedConvolution.
//                        NPU quantizes input with a fixed x_scale (see
//                        setInt8XScale). Accuracy rough, perf A/B only.
//   matmul_int8:         single hiai::op::QuantizedMatMul. x1 fp32 in (NPU
//                        quantizes internally via x1_quant_scale from
//                        setInt8XScale, x1_quant_offset=0), x2 int8 const with
//                        per-OC x2_quant_scales (LIST_FLOAT, length=OC), int32
//                        bias, fp32 out. Real int8×int8 CUBE MAC through the
//                        MatMul engine and per-channel weight quant preserved.
//                        Replaces the earlier QuantizeV2 → MatMul(int8) →
//                        DequantizeV2 chain — that chain is illegal on current
//                        DDK because frontend hiai::op::MatMul x1 TensorType
//                        is {FLOAT, UINT8} (math_defs.h:454) while backend
//                        ge::op::MatMulV2 x1 list has no UINT8, and
//                        DequantizeV2 alone also fails BuildIRModel.
//                        Only active when op shape is 1×1 linear; others
//                        auto-degrade to weight-only. Requires HiAI firmware
//                        >= 100.500.010.010.
//   off:                 legacy — dequantize to fp32 at compile time.
// Must be called before opTest (read during HiAI compileHiAIModel via HIAI_CONV_QUANT env).
export const setConvQuant: (mode: string) => string;

// Set the static x_scale used by 'full' int8 mode. Default = 1/127 when unset
// or non-positive. Written to HIAI_INT8_X_SCALE env and read at compile time.
export const setInt8XScale: (scale: number) => string;

// CPU BackendConfig overrides for the op precision test (applied to runConvTest
// and runConvTestInt8 when they create the CPU Executor).
//   precision: 'normal' (fp32) | 'high' (fp32) | 'low' (fp16/ARM82) | 'low_bf16'
//   memory:    'normal' | 'high' | 'low'  (int8 test needs 'low' to keep int8 weights)
export const setCpuPrecision: (mode: string) => string;
export const setCpuMemory:    (mode: string) => string;

// Runtime log capture (stdout/stderr redirected to file + in-memory ring buffer)
export const initLogFile: (path: string) => string;
export const getLogs: () => string;
export const clearLogs: () => string;
