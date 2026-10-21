const clip = (value, limit = 1000) => String(value || '').slice(0, limit);

export function reconnectProgress(error, previous, now = Date.now()) {
  const detail = clip(error?.message || '连接中断');
  const counter = /(?:reconnect(?:ing)?|retry(?:ing)?|重连|重试)[^\d]{0,24}(\d{1,3})\s*\/\s*(\d{1,3})/i.exec(detail);
  const attempt = counter ? Number(counter[1]) : undefined;
  const total = counter ? Number(counter[2]) : undefined;
  return { kind: 'reconnecting', message: '正在重连 Codex 服务' + (counter ? `（${attempt}/${total}）` : '') + '，任务仍在继续',
    detail, since: previous?.kind === 'reconnecting' ? previous.since : now, attempt, total };
}

export function approvalReviewProgress(review, now = Date.now()) {
  const labels = { inProgress: '正在自动审核操作申请', approved: '自动审核已批准，继续执行',
    denied: '自动审核未批准该操作，等待 Codex 处理', timedOut: '自动审核超时，等待 Codex 处理', aborted: '自动审核已取消' };
  return { kind: review?.status === 'inProgress' ? 'reviewing' : 'reviewResult',
    message: labels[review?.status] || '自动审核状态已更新', detail: clip(review?.rationale), since: now };
}
