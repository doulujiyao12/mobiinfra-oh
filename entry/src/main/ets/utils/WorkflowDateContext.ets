import { normalizeChatMessageTimes } from './ChatMessageTime';

export class WorkflowDateContext {
  private readonly startedAt: Date;

  constructor(startedAt: Date) {
    this.startedAt = new Date(startedAt.getTime());
  }

  datePrompt(): string {
    let recent = [0, -1, -2, -3, -4, -5, -6].map((offset: number): string => {
      let day = this.addDays(offset);
      return this.formatDateIso(day) + ' ' + this.weekdayCn(day);
    }).join('；');
    return '今天的日期是: ' + this.formatDateCn(this.startedAt) + ' ' + this.weekdayCn(this.startedAt) + '\n' +
      '当前本地时间是: ' + this.runTimestamp() + '\n' +
      '规则说明：任务执行时间只作为默认参考；如果图片或文本中存在内容自身时间锚点，例如聊天日期分隔符、消息时间、截图拍摄时间、OCR 日期、文档日期等，必须优先以最近的内容时间锚点解析相对时间；只有完全无法确定内容时间锚点时，才使用任务执行日期兜底；写入总结或日志时保留原始表达，并在相对时间短语后用方括号[]补充绝对日期或时间；无法确定时不要编造。\n' +
      '聊天采集日期参考（今天至前六天）：' + recent + '。昨天/前天相对采集日期；聊天分隔符单写星期几时取采集日及之前最近的那一天；明确写上周/本周时按自然周。日期无法确定用采集日期，时分也不确定用采集时间并标明兜底，不借用示例日期。';
  }

  runDate(): string {
    return this.formatDateIso(this.startedAt);
  }

  runTimestamp(): string {
    return this.formatDateCn(this.startedAt) + ' ' + this.pad2(this.startedAt.getHours()) + ':' +
      this.pad2(this.startedAt.getMinutes()) + ':' + this.pad2(this.startedAt.getSeconds());
  }

  withDatePrompt(prompt: string, sectionTitle: string): string {
    let dateReferenceBlock = '【任务执行时间参考】\n' + this.datePrompt();
    let trimmedPrompt = prompt.trim();
    return dateReferenceBlock + '\n\n【' + sectionTitle + '】\n' + trimmedPrompt;
  }

  withDatePromptAsTask(task: string): string {
    let dateReferenceBlock = '【任务执行时间参考】\n' + this.datePrompt();
    return dateReferenceBlock + '\n\n' + task.trim();
  }

  normalizeDailyLogText(text: string): string {
    text = normalizeChatMessageTimes(text, this.startedAt);
    let output = '';
    let lineStart = 0;
    let skipNextBodyLine = false;
    for (let index = 0; index < text.length; index++) {
      if (text.substring(index, index + 1) === '\n') {
        let result = this.normalizeDailyLogLineWithContext(text.substring(lineStart, index), skipNextBodyLine);
        output += result.text + '\n';
        skipNextBodyLine = result.skipNextBodyLine;
        lineStart = index + 1;
      }
    }
    let result = this.normalizeDailyLogLineWithContext(text.substring(lineStart), skipNextBodyLine);
    output += result.text;
    return output;
  }

  private normalizeDailyLogLineWithContext(line: string, skipNextBodyLine: boolean): NormalizeDailyLogLineResult {
    if (line.trim().length === 0) {
      return { text: line, skipNextBodyLine: false };
    }
    if (this.hasContentTimeAnchor(line)) {
      return { text: line, skipNextBodyLine: this.hasMessageTimeAnchor(line) };
    }
    if (skipNextBodyLine && !this.startsNewListItem(line)) {
      return { text: line, skipNextBodyLine: false };
    }
    return { text: this.normalizeRelativeDatesAgainstExecutionDate(line), skipNextBodyLine: false };
  }

  private normalizeRelativeDatesAgainstExecutionDate(text: string): string {
    let normalized = this.annotateRelativeDateTimePhrases(text);
    normalized = this.annotateRelativeDayPeriodPhrases(normalized);
    let weekendRange = this.weekendRange();
    normalized = this.annotateLiteral(normalized, '近一周', this.formatRangeCn(this.addDays(-6), this.startedAt));
    normalized = this.annotateLiteral(normalized, '近3天', this.formatRangeCn(this.addDays(-2), this.startedAt));
    normalized = this.annotateLiteral(normalized, '下周一', this.formatDateCn(this.nextWeekday(1)));
    normalized = this.annotateLiteral(normalized, '周末', this.formatRangeCn(weekendRange.start, weekendRange.end));
    normalized = this.annotateLiteral(normalized, '后天', this.formatDateCn(this.addDays(2)));
    normalized = this.annotateLiteral(normalized, '明天', this.formatDateCn(this.addDays(1)));
    normalized = this.annotateLiteral(normalized, '今天', this.formatDateCn(this.startedAt));
    return normalized;
  }

  private annotateRelativeDateTimePhrases(text: string): string {
    let normalized = text;
    let days: RelativeDaySpec[] = [
      { literal: '今天', offsetDays: 0 },
      { literal: '明天', offsetDays: 1 },
      { literal: '后天', offsetDays: 2 }
    ];
    let periods: string[] = this.relativePeriods();
    let hourSpecs = this.relativeHourSpecs();

    for (let dayIndex = 0; dayIndex < days.length; dayIndex++) {
      for (let periodIndex = 0; periodIndex < periods.length; periodIndex++) {
        for (let hourIndex = 0; hourIndex < hourSpecs.length; hourIndex++) {
          let hourSpec = hourSpecs[hourIndex];
          let phrase = days[dayIndex].literal + periods[periodIndex] + hourSpec.literal + '点';
          let date = this.addDays(days[dayIndex].offsetDays);
          normalized = this.annotateLiteral(
            normalized,
            phrase,
            this.formatDateHourCn(date, this.resolveHour(periods[periodIndex], hourSpec.hour))
          );
        }
      }
    }
    return normalized;
  }

  private annotateRelativeDayPeriodPhrases(text: string): string {
    let normalized = text;
    let days: RelativeDaySpec[] = [
      { literal: '今天', offsetDays: 0 },
      { literal: '明天', offsetDays: 1 },
      { literal: '后天', offsetDays: 2 }
    ];
    let periods: string[] = this.relativePeriods();

    for (let dayIndex = 0; dayIndex < days.length; dayIndex++) {
      for (let periodIndex = 0; periodIndex < periods.length; periodIndex++) {
        let phrase = days[dayIndex].literal + periods[periodIndex];
        let date = this.addDays(days[dayIndex].offsetDays);
        normalized = this.annotateDayPeriodLiteral(normalized, phrase, this.formatDateCn(date));
      }
    }
    return normalized;
  }

  private annotateDayPeriodLiteral(text: string, literal: string, annotation: string): string {
    let output = '';
    let searchStart = 0;
    let matchStart = text.indexOf(literal, searchStart);
    while (matchStart >= 0) {
      let matchEnd = matchStart + literal.length;
      output += text.substring(searchStart, matchEnd);
      if (!this.hasImmediateAnnotation(text, matchEnd) && !this.isFollowedByHourExpression(text, matchEnd)) {
        output += '[' + annotation + ']';
      }
      searchStart = matchEnd;
      matchStart = text.indexOf(literal, searchStart);
    }
    output += text.substring(searchStart);
    return output;
  }

  private annotateLiteral(text: string, literal: string, annotation: string): string {
    let output = '';
    let searchStart = 0;
    let matchStart = text.indexOf(literal, searchStart);
    while (matchStart >= 0) {
      let matchEnd = matchStart + literal.length;
      output += text.substring(searchStart, matchEnd);
      if (!this.hasImmediateAnnotation(text, matchEnd) && !this.isFollowedByRelativeTimePhrase(literal, text, matchEnd)) {
        output += '[' + annotation + ']';
      }
      searchStart = matchEnd;
      matchStart = text.indexOf(literal, searchStart);
    }
    output += text.substring(searchStart);
    return output;
  }

  private hasImmediateAnnotation(text: string, startIndex: number): boolean {
    return text.substring(startIndex, startIndex + 1) === '[';
  }

  private isFollowedByRelativeTimePhrase(literal: string, text: string, matchEnd: number): boolean {
    if (literal !== '今天' && literal !== '明天' && literal !== '后天') {
      return false;
    }
    let periods: string[] = this.relativePeriods();
    for (let periodIndex = 0; periodIndex < periods.length; periodIndex++) {
      let period = periods[periodIndex];
      if (text.substring(matchEnd, matchEnd + period.length) === period) {
        return true;
      }
      let hourSpecs = this.relativeHourSpecs();
      for (let hourIndex = 0; hourIndex < hourSpecs.length; hourIndex++) {
        let suffix = period + hourSpecs[hourIndex].literal + '点';
        if (text.substring(matchEnd, matchEnd + suffix.length) === suffix) {
          return true;
        }
      }
    }
    return false;
  }

  private isFollowedByHourExpression(text: string, matchEnd: number): boolean {
    let hourSpecs = this.relativeHourSpecs();
    for (let hourIndex = 0; hourIndex < hourSpecs.length; hourIndex++) {
      let suffix = hourSpecs[hourIndex].literal + '点';
      if (text.substring(matchEnd, matchEnd + suffix.length) === suffix) {
        return true;
      }
    }
    return false;
  }

  private hasContentTimeAnchor(line: string): boolean {
    let normalized = this.stripBracketedAbsoluteTimes(line).trim();
    if (normalized.length === 0) {
      return false;
    }
    if (this.hasMessageTimeAnchor(normalized)) {
      return true;
    }
    if (/\d{4}年\s*\d{1,2}月\s*\d{1,2}日/.test(normalized)) {
      return true;
    }
    if (/\d{4}[-/]\d{1,2}[-/]\d{1,2}/.test(normalized)) {
      return true;
    }
    if (/\d{1,2}月\s*\d{1,2}日/.test(normalized)) {
      return true;
    }
    return /^\s*(?:[-*]\s*)?(?:昨天|今天|明天)\s*(?:凌晨|早上|上午|中午|下午|晚上)\s*(?:[一二三四五六七八九十两]{1,3}|[0-2]?\d)\s*点\s*[：:]/.test(normalized);
  }

  private hasMessageTimeAnchor(line: string): boolean {
    let normalized = this.stripBracketedAbsoluteTimes(line).trim();
    if (normalized.length === 0) {
      return false;
    }
    if (/^\s*(?:[-*•]\s*)?(?:\[[^\]]+\]\s*)?(?:[01]?\d|2[0-3])[:：][0-5]\d(?:$|\s|[：:])/.test(normalized)) {
      return true;
    }
    if (/^\s*(?:[-*•]\s*)?\d{4}年\s*\d{1,2}月\s*\d{1,2}日(?:\s*(?:[01]?\d|2[0-3])[:：][0-5]\d)?(?:$|\s|[：:])/.test(normalized)) {
      return true;
    }
    if (/^\s*(?:[-*•]\s*)?\d{4}[-/]\d{1,2}[-/]\d{1,2}(?:\s*(?:[01]?\d|2[0-3])[:：][0-5]\d)?(?:$|\s|[：:])/.test(normalized)) {
      return true;
    }
    if (/^\s*(?:[-*•]\s*)?(?:昨天|今天|明天)\s*(?:凌晨|早上|上午|中午|下午|晚上)?\s*(?:[01]?\d|2[0-3])[:：][0-5]\d(?:$|\s|[：:])/.test(normalized)) {
      return true;
    }
    if (/^\s*(?:[-*•]\s*)?(?:星期|周)[一二三四五六日天]\s*(?:[01]?\d|2[0-3])[:：][0-5]\d(?:$|\s|[：:])/.test(normalized)) {
      return true;
    }
    if (/^\s*(?:[-*•]\s*)?\d{1,2}月\s*\d{1,2}日\s*(?:[01]?\d|2[0-3])[:：][0-5]\d(?:$|\s|[：:])/.test(normalized)) {
      return true;
    }
    if (/^\s*(?:[-*•]\s*)?\d{1,2}\/\d{1,2}\s*(?:[01]?\d|2[0-3])[:：][0-5]\d(?:$|\s|[：:])/.test(normalized)) {
      return true;
    }
    return /^\s*(?:[-*•]\s*)?(?:昨天|今天|明天)\s*(?:凌晨|早上|上午|中午|下午|晚上)\s*(?:[一二三四五六七八九十两]{1,3}|[0-2]?\d)\s*点\s*[：:]/.test(normalized);
  }

  private startsNewListItem(line: string): boolean {
    return /^\s*(?:[-*•]|\d+[.)、])\s+/.test(line);
  }

  private stripBracketedAbsoluteTimes(text: string): string {
    let output = '';
    let searchStart = 0;
    let openIndex = text.indexOf('[', searchStart);
    while (openIndex >= 0) {
      let closeIndex = text.indexOf(']', openIndex + 1);
      if (closeIndex < 0) {
        break;
      }
      let candidate = text.substring(openIndex, closeIndex + 1);
      if (this.containsBracketedAbsoluteTime(candidate)) {
        output += text.substring(searchStart, openIndex);
        searchStart = closeIndex + 1;
      }
      openIndex = text.indexOf('[', closeIndex + 1);
    }
    output += text.substring(searchStart);
    return output;
  }

  private containsBracketedAbsoluteTime(text: string): boolean {
    return /^\[\d{4}年\s*\d{1,2}月\s*\d{1,2}日(?:\d{1,2}:\d{2})?(?:-\d{4}年\s*\d{1,2}月\s*\d{1,2}日(?:\d{1,2}:\d{2})?)?\]$/.test(text);
  }

  private relativePeriods(): string[] {
    return ['凌晨', '早上', '上午', '中午', '下午', '晚上'];
  }

  private relativeHourSpecs(): RelativeHourSpec[] {
    let specs: RelativeHourSpec[] = [];
    for (let hour = 0; hour <= 24; hour++) {
      specs.push({ literal: hour.toString(), hour: hour });
    }
    let chineseHours: string[] = ['一', '二', '三', '四', '五', '六', '七', '八', '九', '十', '十一', '十二'];
    for (let index = 0; index < chineseHours.length; index++) {
      specs.push({ literal: chineseHours[index], hour: index + 1 });
    }
    specs.push({ literal: '两', hour: 2 });
    return specs;
  }

  private addDays(days: number): Date {
    let date = new Date(this.startedAt.getTime());
    date.setDate(date.getDate() + days);
    return date;
  }

  private nextWeekday(day: number): Date {
    let current = this.startedAt.getDay();
    let offset = day - current;
    if (offset <= 0) {
      offset += 7;
    }
    return this.addDays(offset);
  }

  private weekendRange(): WeekendRange {
    let current = this.startedAt.getDay();
    if (current === 6) {
      return { start: this.startedAt, end: this.addDays(1) };
    }
    if (current === 0) {
      return { start: this.addDays(-1), end: this.startedAt };
    }
    let saturdayOffset = 6 - current;
    return { start: this.addDays(saturdayOffset), end: this.addDays(saturdayOffset + 1) };
  }

  private formatRangeCn(start: Date, end: Date): string {
    return this.formatDateCn(start) + '-' + this.formatDateCn(end);
  }

  private formatDateIso(date: Date): string {
    return date.getFullYear().toString() + '-' + this.pad2(date.getMonth() + 1) + '-' + this.pad2(date.getDate());
  }

  private formatDateCn(date: Date): string {
    return date.getFullYear().toString() + '年' + this.pad2(date.getMonth() + 1) + '月' + this.pad2(date.getDate()) + '日';
  }

  private formatDateHourCn(date: Date, hour: number): string {
    return this.formatDateCn(date) + this.pad2(hour) + ':00';
  }

  private resolveHour(period: string, hour: number): number {
    if ((period === '下午' || period === '晚上') && hour < 12) {
      return hour + 12;
    }
    if (period === '中午' && hour > 0 && hour < 11) {
      return hour + 12;
    }
    return hour;
  }

  private weekdayCn(date: Date): string {
    let weekdays: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
    return weekdays[date.getDay()];
  }

  private pad2(value: number): string {
    if (value < 10) {
      return '0' + value.toString();
    }
    return value.toString();
  }
}

interface WeekendRange {
  start: Date;
  end: Date;
}

interface RelativeDaySpec {
  literal: string;
  offsetDays: number;
}

interface RelativeHourSpec {
  literal: string;
  hour: number;
}

interface NormalizeDailyLogLineResult {
  text: string;
  skipNextBodyLine: boolean;
}
