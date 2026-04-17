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

// Runtime log capture (stdout/stderr redirected to file + in-memory ring buffer)
export const initLogFile: (path: string) => string;
export const getLogs: () => string;
export const clearLogs: () => string;

