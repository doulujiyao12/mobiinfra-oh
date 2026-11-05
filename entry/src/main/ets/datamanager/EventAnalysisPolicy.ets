// A single budget owns event retries; the transport/JSON layer must not multiply it.
export const EVENT_ANALYSIS_ATTEMPTS: number = 3;
export const EVENT_ANALYSIS_POLICY: string = 'event-analysis-v3';

export function isFatalEventAnalysisError(message: string): boolean {
  return /保存事件检查点失败|Cloud HTTP (400|401|403|404|405|429)|登录|请先配置|取消|终止|已撤回|cancel|abort/i.test(message);
}
