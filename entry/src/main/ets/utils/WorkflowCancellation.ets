// One signal belongs to one run/batch. It stays cancelled across individual
// workflows, even when the shared Agent controller resets during cleanup.
export class WorkflowCancellation {
  private cancelled: boolean = false;
  private handler: (() => void) | null = null;

  isCancelled(): boolean { return this.cancelled; }

  cancel(): void {
    if (this.cancelled) { return; }
    this.cancelled = true;
    this.handler?.();
  }

  setHandler(handler: (() => void) | null): void {
    this.handler = handler;
    if (this.cancelled) { this.handler?.(); }
  }

  throwIfCancelled(): void {
    if (this.cancelled) { throw new Error('用户取消 workflow，停止下发后续任务和动作'); }
  }
}
