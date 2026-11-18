// Read only the summary's message metadata, never the message body or image.
// This is a one-way consistency check for the existing today-capture contract:
// an explicit non-today label stops collection; absent evidence changes nothing.
export function nonTodayWechatTimeLabel(summary: string): string {
  for (let line of summary.split(/\r?\n/)) {
    let fields = /^\s*(?:-\s*)?位置\s*[:：]\s*(?:左侧|右侧)\s*[｜|]\s*发送人\s*[:：][^｜|\r\n]+[｜|]\s*聊天对象\s*[:：][^｜|\r\n]+[｜|]\s*时间原文\s*[:：]([^｜|\r\n]+)[｜|]\s*原文\s*[:：]/.exec(line);
    if (fields === null) { continue; }
    let label = fields[1].trim();
    let normalized = label.replace(/\s+/g, '').replace(/：/g, ':');
    // Full-label matching prevents misfiled chat sentences such as
    // "昨天的材料看了吗" from being treated as a WeChat time separator.
    let dated = /^(?:昨天|前天|上周(?:[一二三四五六日天]|(?:星期|周)[一二三四五六日天])?|(?:星期|周|礼拜)[一二三四五六日天]|(?:\d{4}年)?(?:1[0-2]|0?[1-9])月(?:3[01]|[12]\d|0?[1-9])日|\d{4}[-/.](?:1[0-2]|0?[1-9])[-/.](?:3[01]|[12]\d|0?[1-9]))(?:(?:凌晨|早上|上午|中午|下午|晚上)?(?:[01]?\d|2[0-3]):[0-5]\d)?$/.test(normalized);
    if (dated) { return label; }
  }
  return '';
}
