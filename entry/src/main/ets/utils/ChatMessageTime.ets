// Resolve transcribed chat separators once, while saving the screenshot summary.
// Later stages consume this text and never need the source image again.
interface MessageTimeResolution { date: string; text: string; basis: string; }

function pad(value: number): string { return value < 10 ? '0' + value : String(value); }
function dateKey(date: Date): string { return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()); }
function calendarDate(year: number, month: number, day: number): Date | undefined {
  let date = new Date(year, month - 1, day);
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day ? date : undefined;
}
function parseDate(value: string): Date | undefined {
  let match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  return match ? calendarDate(Number(match[1]), Number(match[2]), Number(match[3])) : undefined;
}
function shiftedDate(date: Date, days: number): Date {
  let shifted = new Date(date.getTime()); shifted.setDate(shifted.getDate() + days); return shifted;
}
function captureFallback(capturedAt: Date): MessageTimeResolution {
  return { date: dateKey(capturedAt), text: dateKey(capturedAt) + ' ' + pad(capturedAt.getHours()) + ':' + pad(capturedAt.getMinutes()), basis: '采集时间兜底' };
}

function resolveMessageTime(raw: string, capturedAt: Date, previousDate: string): MessageTimeResolution {
  let fallback = captureFallback(capturedAt);
  if (!raw || /未显示|不确定|无法|看不清|未知/.test(raw)) { return fallback; }
  let date: Date | undefined = undefined;
  let basis = '截图日期';
  let full = raw.match(/(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?/);
  let partial = raw.match(/(?:^|\D)(\d{1,2})月(\d{1,2})日/);
  let weekday = raw.match(/(上上周|上周|本周|这周|星期|礼拜|周)([一二三四五六日天])/);
  if (full) {
    date = calendarDate(Number(full[1]), Number(full[2]), Number(full[3]));
    if (!date) { return fallback; }
  } else if (/前天|昨天|昨日|今天|今日/.test(raw)) {
    date = shiftedDate(capturedAt, /前天/.test(raw) ? -2 : /昨天|昨日/.test(raw) ? -1 : 0);
    basis = '截图相对日期';
  } else if (partial) {
    date = calendarDate(capturedAt.getFullYear(), Number(partial[1]), Number(partial[2]));
    if (!date) { return fallback; }
    if (dateKey(date) > fallback.date) { date = calendarDate(capturedAt.getFullYear() - 1, Number(partial[1]), Number(partial[2])); }
  } else if (weekday) {
    let day = '日一二三四五六'.indexOf(weekday[2] === '天' ? '日' : weekday[2]);
    let prefix = weekday[1];
    let offset = -((capturedAt.getDay() - day + 7) % 7);
    if (prefix === '上周' || prefix === '上上周' || prefix === '本周' || prefix === '这周') {
      let monday = -((capturedAt.getDay() + 6) % 7);
      offset = monday + ((day + 6) % 7) - (prefix === '上上周' ? 14 : prefix === '上周' ? 7 : 0);
    }
    date = shiftedDate(capturedAt, offset); basis = '截图星期';
  } else {
    date = parseDate(previousDate) || parseDate(fallback.date);
    basis = previousDate ? '继承同页日期' : '采集日期兜底';
  }
  if (!date || dateKey(date) > fallback.date) { return fallback; }
  if (full && weekday && date.getDay() !== '日一二三四五六'.indexOf(weekday[2] === '天' ? '日' : weekday[2])) { return fallback; }
  let clock = raw.match(/(凌晨|早上|上午|中午|下午|傍晚|晚上)?\s*(\d{1,2})[:：](\d{2})(?:[:：](\d{2}))?/);
  if (!clock && !full && !partial && !weekday && !/前天|昨天|昨日|今天|今日/.test(raw)) { return fallback; }
  let text = dateKey(date);
  if (clock) {
    let hour = Number(clock[2]), minute = Number(clock[3]);
    if (hour > 23 || minute > 59 || (clock[4] && Number(clock[4]) > 59)) { return fallback; }
    if (/下午|傍晚|晚上/.test(clock[1] || '') && hour < 12) { hour += 12; }
    if (/凌晨|早上|上午/.test(clock[1] || '') && hour === 12) { hour = 0; }
    if (text === fallback.date && hour * 60 + minute > capturedAt.getHours() * 60 + capturedAt.getMinutes()) { return fallback; }
    text += ' ' + pad(hour) + ':' + pad(minute);
  }
  return { date: dateKey(date), text: text, basis: basis };
}

export function normalizeChatMessageTimes(text: string, capturedAt: Date): string {
  let previousDate = '';
  return text.split('\n').map((line: string): string => {
    if (/^\s*会话(?:类型|名称)[：:]/.test(line)) { previousDate = ''; }
    let bodyAt = line.search(/[｜|]\s*原文[：:]/);
    if (bodyAt < 0) { return line; }
    let header = line.substring(0, bodyAt), body = line.substring(bodyAt);
    let raw = header.match(/(?:^|[｜|])\s*时间原文[：:]\s*([^｜|]*)/);
    if (!raw || !/发送人[：:]/.test(header) || !/聊天对象[：:]/.test(header)) { return line; }
    let resolved = resolveMessageTime(raw[1].trim(), capturedAt, previousDate);
    previousDate = resolved.date;
    header = header.replace(/[｜|]\s*时间(?:依据)?[：:][^｜|]*/g, '').trim();
    return header + '｜时间：' + resolved.text + '｜时间依据：' + resolved.basis + body;
  }).join('\n');
}

// Only accept an extracted message date that the saved summary actually supports.
// Ordinary GUI summaries without this transcript format keep their existing dates.
export function supportedFactDate(proposed: string, sourceDate: string, sourceText: string): string {
  let date = parseDate(proposed);
  if (!date || proposed > sourceDate) { return sourceDate; }
  let supported: string[] = [];
  // Consolidation may fold whitespace; message field boundaries remain intact.
  sourceText.split(/\n|(?=(?:-\s*)?位置[：:])/).forEach((line: string) => {
    let bodyAt = line.search(/[｜|]\s*原文[：:]/);
    if (bodyAt < 0) { return; }
    let header = line.substring(0, bodyAt);
    if (!/时间原文[：:]/.test(header)) { return; }
    let match = header.match(/[｜|]\s*时间[：:]\s*(\d{4}-\d{2}-\d{2})/);
    if (match && parseDate(match[1])) { supported.push(match[1]); }
  });
  return supported.length === 0 || supported.indexOf(proposed) >= 0 ? proposed : sourceDate;
}

// An action date can be in the future. It is different from the timestamp of
// the message that announces it. Natural weeks start on Monday.
export function resolveActionDate(expression: string, referenceDate: string): string {
  let reference = parseDate(referenceDate);
  if (!reference || !expression) { return ''; }
  if (!actionDateExpression(expression) || /(?:至|到|~|～|—)\s*\d{1,2}(?:日|号)/.test(expression)) { return ''; }
  let date: Date | undefined = undefined;
  let full = expression.match(/(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})(?:日|号)?/);
  let monthDay = expression.match(/(今年|明年|后年)?\s*(\d{1,2})月(\d{1,2})(?:日|号)/);
  let nextMonthDay = expression.match(/(下个月|本月|这个月)(\d{1,2})(?:日|号)/);
  let relative = expression.match(/大后天|后天|明天|明早|明晚|今天|今晚|今早|昨天|前天/);
  let weekday = expression.match(/(下下周|下周|下星期|下礼拜|本周|这周|上周|星期|礼拜|周)([一二三四五六日天])/);
  let weekend = expression.match(/下下周末|下周末|本周末|这周末|周末/);
  if (full) {
    date = calendarDate(Number(full[1]), Number(full[2]), Number(full[3]));
  } else if (monthDay) {
    date = calendarDate(reference.getFullYear() + (monthDay[1] === '明年' ? 1 : monthDay[1] === '后年' ? 2 : 0),
      Number(monthDay[2]), Number(monthDay[3]));
  } else if (nextMonthDay) {
    let month = new Date(reference.getFullYear(), reference.getMonth() + (nextMonthDay[1] === '下个月' ? 1 : 0), 1);
    date = calendarDate(month.getFullYear(), month.getMonth() + 1, Number(nextMonthDay[2]));
  } else if (relative) {
    let word = relative[0];
    date = shiftedDate(reference, word === '大后天' ? 3 : word === '后天' ? 2 : /明/.test(word) ? 1 : word === '昨天' ? -1 : word === '前天' ? -2 : 0);
  } else if (weekday) {
    let day = '日一二三四五六'.indexOf(weekday[2] === '天' ? '日' : weekday[2]);
    let prefix = weekday[1];
    let offset = (day - reference.getDay() + 7) % 7;
    if (/^下|本周|这周|上周/.test(prefix)) {
      offset = -((reference.getDay() + 6) % 7) + ((day + 6) % 7) +
        (prefix === '下下周' ? 14 : prefix.startsWith('下') ? 7 : prefix === '上周' ? -7 : 0);
    }
    date = shiftedDate(reference, offset);
  } else if (weekend) {
    let monday = -((reference.getDay() + 6) % 7);
    let offset = weekend[0] === '周末' ? ((6 - reference.getDay() + 7) % 7 || 7) :
      monday + 5 + (weekend[0] === '下下周末' ? 14 : weekend[0] === '下周末' ? 7 : 0);
    date = shiftedDate(reference, offset);
  }
  return date ? dateKey(date) : '';
}

export function actionDateExpression(text: string): string {
  // A missing time_text from an older response can be recovered only when the
  // event itself contains one unambiguous date expression, never from all pages.
  let values = text.match(/\d{4}[-/年]\d{1,2}[-/月]\d{1,2}(?:日|号)?|(?:今年|明年|后年)?\d{1,2}月\d{1,2}(?:日|号)|(?:下个月|本月|这个月)\d{1,2}(?:日|号)|(?:下下周|下周|下星期|下礼拜|本周|这周|上周|星期|礼拜|周)[一二三四五六日天]|下下周末|下周末|本周末|这周末|周末|大后天|后天|明天|明早|明晚|今天|今晚|今早|昨天|前天/g) || [];
  let unique: string[] = [];
  values.forEach((value: string) => { if (unique.indexOf(value) < 0) { unique.push(value); } });
  return unique.length === 1 ? unique[0] : '';
}

export function actionReferenceDate(expression: string, fallback: string, sourceText: string): string {
  let dates: string[] = [];
  sourceText.split(/\n|(?=(?:-\s*)?位置[：:])/).forEach((line: string) => {
    let bodyAt = line.search(/[｜|]\s*原文[：:]/);
    if (bodyAt < 0 || line.substring(bodyAt).indexOf(expression) < 0) { return; }
    let match = line.substring(0, bodyAt).match(/[｜|]\s*时间[：:]\s*(\d{4}-\d{2}-\d{2})/);
    if (match && parseDate(match[1]) && dates.indexOf(match[1]) < 0) { dates.push(match[1]); }
  });
  return dates.length === 1 ? dates[0] : fallback;
}

export function eventTimeTextSupported(expression: string, factText: string, sourceText: string): boolean {
  if (!expression || factText.indexOf(expression) < 0) { return false; }
  let bodies: string[] = [];
  sourceText.split(/\n|(?=(?:-\s*)?位置[：:])/).forEach((line: string) => {
    let bodyAt = line.search(/[｜|]\s*原文[：:]/);
    if (bodyAt >= 0 && /发送人[：:]/.test(line.substring(0, bodyAt))) { bodies.push(line.substring(bodyAt)); }
  });
  // A screenshot separator is not a date explicitly mentioned by the speaker.
  return (bodies.length > 0 ? bodies.join('\n') : sourceText).indexOf(expression) >= 0;
}
