import { HomeRecommendationViewModel } from '../../datamanager/DataManagerTypes';
import { HomeCodexRequest } from '../../datamanager/HomeCodexContext';
import { homeReminderCodexRequest, homeReminderSupportsCodex, homeSuggestionCodexRequest } from './HomeCodexHandoff';
import { HomeTaskSuggestion, buildHomeTaskExecutionRequest, homeTaskSupportsQwen } from './HomeTaskSuggestion';

export type HomeNoteFilter = 'all' | 'reminder' | 'suggestion';
export type SecretaryRoute = 'phone' | 'qwen' | 'codex';

export interface HomeNote {
  key: string;
  title: string;
  body: string;
  meta: string;
  completed: boolean;
  canDelegate: boolean;
  reminder?: HomeRecommendationViewModel;
  suggestion?: HomeTaskSuggestion;
}

export function homeReminderNote(item: HomeRecommendationViewModel): HomeNote {
  return { key: 'reminder/' + item.id, title: item.title, body: item.desc, meta: item.meta,
    completed: item.completed, canDelegate: homeReminderSupportsCodex(item), reminder: item };
}

export function homeSuggestionNote(item: HomeTaskSuggestion): HomeNote {
  return { key: 'suggestion/' + item.id, title: item.title, body: item.reason, meta: '',
    completed: false, canDelegate: true, suggestion: item };
}

// Cell numbers in the shared home_category_icons atlas.
const ideaArt = new Map<string, number>([
  ['food', 0], ['shopping', 1], ['news', 2], ['social', 3],
  ['travel', 4], ['work', 5], ['learning', 11]
]);

export function homeIdeaArt(category: string): number {
  return ideaArt.get(category) ?? 6;
}

export interface HomeNoteSource {
  title: string;
  text: string;
  meta: string;
}

export function homeNoteSources(note: HomeNote): HomeNoteSource[] {
  if (note.suggestion) {
    return note.suggestion.evidence.map((item): HomeNoteSource => ({
      title: item.title, text: item.summary === item.title ? '' : item.summary, meta: item.meta
    }));
  }
  const reminder = note.reminder;
  if (!reminder) { return []; }
  // Older view models combined the description, metadata and source excerpts in one string.
  const facts = reminder.relatedFacts ?? (reminder.detail || '').split('\n');
  const seen = new Set<string>([note.title.trim(), ...note.body.trim().split('\n'), note.meta.trim(),
    '信息：' + note.meta.trim(), '相关记录', '']);
  const sources: HomeNoteSource[] = [];
  for (const fact of facts) {
    const text = fact.trim();
    if (!seen.has(text)) {
      seen.add(text);
      sources.push({ title: '', text: text, meta: '' });
    }
  }
  return sources;
}

// Keep the upstream order within each source. Give both sources space on the first spread.
export function homeNoteBoard(reminders: HomeRecommendationViewModel[], suggestions: HomeTaskSuggestion[],
  filter: HomeNoteFilter, includeCompleted: boolean): HomeNote[] {
  const notes = reminders.filter((r: HomeRecommendationViewModel): boolean =>
    !r.id.startsWith('calendar:') && r.id !== 'mail:overview').map(homeReminderNote);
  const open = notes.filter((n: HomeNote): boolean => !n.completed);
  const pending = open.filter((n: HomeNote): boolean => !!n.meta)
    .concat(open.filter((n: HomeNote): boolean => !n.meta));
  const finished = includeCompleted ? notes.filter((n: HomeNote): boolean => n.completed) : [];
  const ideas = suggestions.map(homeSuggestionNote);
  if (filter === 'reminder') { return pending.concat(finished); }
  if (filter === 'suggestion') { return ideas; }
  const board: HomeNote[] = [];
  for (let i = 0; i < Math.max(pending.length, ideas.length); i++) {
    if (i < pending.length) { board.push(pending[i]); }
    if (i < ideas.length) { board.push(ideas[i]); }
  }
  return board.concat(finished);
}

export interface SecretaryAssignment {
  route: SecretaryRoute;
  goal: string;
  task: string;
  context?: HomeCodexRequest;
}

export function homeNoteTask(note: HomeNote): HomeTaskSuggestion {
  if (note.suggestion) { return note.suggestion; }
  const reminder = note.reminder;
  return {
    id: reminder?.id || '', title: note.title, task: reminder?.agentTask || '', reason: note.body,
    category: reminder?.domain === 'eat' ? 'food' : (reminder?.domain || 'life'), evidence: []
  };
}

export function recommendedHomeRoute(note: HomeNote): SecretaryRoute {
  const reminder = note.reminder;
  const item = homeNoteTask(note);
  const intent = item.task;
  const device = /通讯录|聊天记录|验证码|相册|收件箱|我的收藏|系统设置|(?:打开|进入|读取|登录|查找|查看).{0,8}(?:微信|京东|美团|小红书|日历|账单)/.test(intent);
  const research = reminder?.tag === '值得研究' ||
    /调研|研究报告|对比分析|制定方案|撰写|汇报材料|制作.{0,8}(?:文档|表格|演示|PPT)/i.test(item.title + ' ' + intent);
  const contextual = !!reminder && reminder.sourceEventIds.length > 0 && /聊天|邀约|见面|约定|改期|回复/.test(
    note.title + ' ' + note.body + ' ' + intent);
  if (reminder && contextual && /回复|发消息|确认时间地点/.test(intent)) {
    return 'codex';
  }
  if (!device && !research && !contextual && intent && homeTaskSupportsQwen(item)) {
    return 'qwen';
  }
  if (intent && (device || (!research && !contextual && /打开|进入|点按|点击|登录|滑动/.test(intent)))) {
    return 'phone';
  }
  return 'codex';
}

export function planHomeNote(note: HomeNote, route: SecretaryRoute, draft: string): SecretaryAssignment {
  if (!note.canDelegate || (note.reminder && !homeReminderSupportsCodex(note.reminder))) {
    throw new Error('请打开本机详情查看');
  }
  if (route === 'codex') {
    const context = note.reminder ? homeReminderCodexRequest(note.reminder) :
      (note.suggestion ? homeSuggestionCodexRequest(note.suggestion) : undefined);
    if (!context) { throw new Error('事项已更新，请重新打开'); }
    if (draft.trim()) { context.userGoal = draft.trim(); }
    return { route: route, goal: draft.trim(), task: '', context: context };
  }
  const request = buildHomeTaskExecutionRequest(homeNoteTask(note), route, draft);
  return { route: route, goal: draft.trim(), task: request.taskDescription };
}

export function secretaryRouteLabel(route: SecretaryRoute): string {
  return route === 'codex' ? 'Codex' : (route === 'qwen' ? '千问' : '手机');
}

export type SecretaryJobState = 'running' | 'finished' | 'failed' | 'review' | 'cancelled';
export interface SecretaryJob {
  key: string;
  title: string;
  state: SecretaryJobState;
  sessionId: string;
  message: string;
  route?: SecretaryRoute;
}

export function canReassignJob(job: SecretaryJob): boolean {
  if (job.state === 'review') { return !job.sessionId || job.route === 'phone' || job.route === 'qwen'; }
  return job.state === 'finished' || job.state === 'failed' || job.state === 'cancelled';
}

export function secretaryStatus(state: SecretaryJobState): string {
  if (state === 'running') { return '正在办理'; }
  if (state === 'finished') { return '查看结果'; }
  if (state === 'review') { return '查看进度'; }
  if (state === 'cancelled') { return '已取消'; }
  return '交办失败';
}
