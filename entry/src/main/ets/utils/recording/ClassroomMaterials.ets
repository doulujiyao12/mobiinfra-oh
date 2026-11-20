import { RecordingRecord, RecordingSummary, recordingTime } from './RecordingTypes';

export const CLASSROOM_SOURCE: string = '课堂';
export interface RecordingRouteParams { classroom?: boolean; }
export interface ClassroomPhoto { name: string; seconds: number; }
export function classroomPhoto(name: string): ClassroomPhoto | null {
  const match = /^photo-(\d{1,9})-([\da-f-]{36})\.jpg$/.exec(name);
  return match ? { name: name, seconds: Number(match[1]) / 1000 } : null;
}
export function classroomOwner(id: string): string {
  if (!/^[a-f0-9-]{36}$/.test(id)) { throw new Error('课堂编号无效'); }
  return 'classroom:' + id;
}

function summaryLines(summary: RecordingSummary): string[] {
  let lines: string[] = [summary.title, summary.overview];
  const groups: string[][] = [summary.keyPoints, summary.decisions, summary.actionItems, summary.openQuestions];
  const labels: string[] = ['要点', '结论', '待办', '待解问题'];
  groups.forEach((items: string[], index: number): void => {
    if (items && items.length > 0) { lines.push(labels[index]); }
    for (const text of items || []) { lines.push('- ' + text); }
  });
  return lines.filter((line: string): boolean => !!line);
}

export function classroomText(record: RecordingRecord, photos: ClassroomPhoto[]): string {
  if (record.source !== CLASSROOM_SOURCE || record.capturing || !record.analysis ||
    record.transcriptionComplete === false || !record.analysis.segments.some(segment => !!segment.text.trim())) {
    throw new Error('请先完成这节课的转写');
  }
  if (!record.summary || record.summary.complete === false) { throw new Error('请先完成课堂摘要'); }
  let lines: string[] = ['# ' + record.title, record.createdAt + ' · ' + recordingTime(record.duration), '', '## 课堂摘要'];
  lines = lines.concat(summaryLines(record.summary));
  for (const section of record.summary.sections || []) {
    lines.push('', '### ' + recordingTime(section.start) + '–' + recordingTime(section.end));
    lines = lines.concat(summaryLines(section.summary));
  }
  lines.push('', '## 随堂照片');
  photos.forEach((photo: ClassroomPhoto): void => { lines.push(recordingTime(photo.seconds) + '  ' + photo.name); });
  lines.push('', '## 完整转写');
  for (const segment of record.analysis.segments) {
    if (!segment.text.trim()) { continue; }
    const speaker = record.analysis.speakers.find(item => item.id === segment.speaker);
    lines.push('[' + recordingTime(segment.start) + '–' + recordingTime(segment.end) + '] ' +
      (speaker?.name ? speaker.name + '：' : '') + segment.text);
  }
  return lines.join('\n');
}

export const CLASSROOM_TASK: string = '请根据所附课堂资料包交付三份可打开的 Word（.docx）文件：' +
  '①课堂笔记，按授课主题整理，结合转写时间将相关随堂照片实际嵌入对应段落，添加图注；' +
  '②知识要点，归纳核心概念、联系与易错点；③模拟试题，覆盖本课重点，题目在前，参考答案和解析另起一页。' +
  '资料包包含完整转写、摘要及用户选中的照片。按 ZIP 读取附件，若为 .001 等分卷，先按编号顺序拼接再解压。' +
  '区分课堂原话与归纳，模糊的板书和听不清的内容不要猜测。没有照片时按文字整理。仅返回三份最终 Word 文件。';
