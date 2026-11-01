// Versioned transport snapshots. Full native/model history is never modified.
// Only snapshots actually sent to clients are retained; bounded global memory.
export class TaskSync {
  entries = new Map(); bytes = 0;
  constructor({ maxBytes = 16 * 1024 * 1024, versions = 4 } = {}) { this.maxBytes = maxBytes; this.versions = versions; }
  envelope(task, revision, enabled) {
    if (!enabled) return { task };
    const prior = this.entries.get(task.id)?.find(item => String(item.task.revision) === revision)?.task;
    const snapshot = { ...task, items: task.items.map(item => ({ ...item })) };
    // The caller serializes immediately; copy non-item fields to detach mutable approvals/artifacts too.
    const saved = JSON.parse(JSON.stringify(snapshot));
    const bytes = Buffer.byteLength(JSON.stringify(saved));
    let versions = this.entries.get(task.id) || [];
    if (!versions.some(item => item.task.revision === task.revision)) {
      versions.push({ task: saved, bytes }); this.bytes += bytes;
      while (versions.length > this.versions) this.bytes -= versions.shift().bytes;
    }
    this.entries.delete(task.id); this.entries.set(task.id, versions);
    while (this.bytes > this.maxBytes && this.entries.size) {
      const oldest = this.entries.keys().next().value;
      for (const item of this.entries.get(oldest)) this.bytes -= item.bytes;
      this.entries.delete(oldest);
    }
    if (!prior || prior.revision >= task.revision) return { task };
    const previous = new Map(prior.items.map(item => [item.id, item])); const changed = [];
    for (const item of task.items) {
      const before = previous.get(item.id);
      if (JSON.stringify(before) === JSON.stringify(item)) continue;
      if (before && before.kind === item.kind && item.text.startsWith(before.text)) changed.push({ ...item, text: item.text.slice(before.text.length), append: true });
      else changed.push({ ...item, append: false });
    }
    return { taskDelta: { baseRevision: prior.revision, task: { ...task, items: [] },
      items: changed, itemOrder: task.items.map(item => item.id) } };
  }
}
