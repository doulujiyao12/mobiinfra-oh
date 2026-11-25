import { CodexItem, CodexTask, codexTaskBusy } from './CodexTypes';

const STAGES: string[] = ['正在阅读所选资料', '正在整理与分析内容', '正在生成学习文件', '正在核对交付文件'];
const PREFIX: string = '学伴进度：';
export const STUDY_PROGRESS_REQUEST: string = '\n请在实际开始相应步骤时用一条独立的中间消息报告进度，' +
  '每个步骤最多一次，可跳过不适用的步骤。消息只写以下短句之一：' +
  STAGES.map((stage: string): string => PREFIX + stage).join('、') + '。最终答复单独交付成果。';

export function isStudySession(id: string): boolean {
  return id.startsWith('course:') || id.startsWith('classroom:');
}

function currentItem(item: CodexItem, turnId: string): boolean {
  return !!turnId && (item.turnId || item.id.split(':')[0]) === turnId;
}

function reportedStage(text: string): string {
  const label = text.trim();
  if (!label.startsWith(PREFIX)) { return ''; }
  const stage = label.substring(PREFIX.length);
  return STAGES.includes(stage) ? stage : '';
}

export function studyStage(task: CodexTask, previous: string = ''): string {
  let activity = '';
  let stage = STAGES.includes(previous) ? previous : '';
  for (const item of task.items) {
    if (!currentItem(item, task.turnId)) { continue; }
    if (item.kind === 'assistant') {
      const reported = reportedStage(item.text);
      if (reported) { stage = reported; }
      activity = 'Codex 已更新回复';
    } else if (item.kind === 'plan') { activity = 'Codex 已更新执行计划'; }
    else if (item.kind === 'tool') { activity = 'Codex 正在使用工具处理任务'; }
    else if (item.kind === 'diff') { activity = 'Codex 已更新工作文件'; }
  }
  return stage || activity || previous || '电脑已接收任务，等待进度更新';
}

export function studyExecutionNotice(task: CodexTask, stage: string): string {
  if (!codexTaskBusy(task.status)) { return ''; }
  if (task.desktopConnected === false && task.executionTransport === 'desktop') { return '电脑连接已断开，等待同步'; }
  if (task.status === 'stopping') { return '正在等待电脑确认停止'; }
  if (task.progress?.kind === 'desktopApproval') { return '请在电脑端确认操作'; }
  if (task.status === 'waitingApproval' || task.approvals.length > 0) { return '请查看此卡片中的待确认操作'; }
  if (task.progress?.kind === 'reconnecting') { return '正在重连 Codex 服务'; }
  if (task.progress?.kind === 'reviewing') { return '正在审核操作申请'; }
  if (task.status === 'releasing') { return '电脑正在保存结果'; }
  return stage;
}

export function studyFinalAnswer(task: CodexTask): string {
  if (task.status !== 'completed') { return ''; }
  for (let i = task.items.length - 1; i >= 0; i--) {
    const item = task.items[i];
    if (currentItem(item, task.turnId) && item.kind === 'assistant' && item.text.trim()) {
      return reportedStage(item.text) ? '' : item.text;
    }
  }
  return '';
}
