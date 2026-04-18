export const loadModel: (configPath: string) => string;
export const generate: (prompt: string) => string;
export const chat: (userMessage: string) => string;
export const reset: () => string;
export const copyModel: (src: string, dst: string) => string;

// Agent mode (prefix KV cache reuse)
export const agentPrefill: (prefix: string) => Promise<string>;
export const agentStep: (variablePart: string, onToken?: (token: string) => void) => Promise<string>;
export const agentReset: () => Promise<string>;

// Op precision test (CPU vs HiAI delegate)
// config: "preset" for built-in test suite, or "ic,oc,ih,iw,kh,kw,sh,sw,group" for custom
export const opTest: (config: string) => Promise<string>;

// HiAI conv-path override for A/B testing: 'auto' | 'matmul' | 'conv'
// Must be called before opTest (read during HiAI compileHiAIModel via HIAI_CONV_MODE env).
export const setConvMode: (mode: string) => string;

// HiAI int8 quant-path override for A/B testing: 'auto' | 'on' | 'off'
//   auto / on (default): build hiai::op::QuantizedConvolution with DT_INT8
//                        filter + per-OC scales when the op is symmetric
//                        per-channel int8 (real NPU int8 CUBE MAC).
//   off:                 legacy path — dequantize to fp32 at compile time and
//                        use the plain Convolution/MatMul float graph.
// Must be called before opTest (read during HiAI compileHiAIModel via HIAI_CONV_QUANT env).
export const setConvQuant: (mode: string) => string;

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

