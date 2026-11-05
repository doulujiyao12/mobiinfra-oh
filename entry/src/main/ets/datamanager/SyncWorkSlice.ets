// A resolved Promise only drains microtasks. Yield to the event loop so input,
// rendering and the system watchdog can run during local index preparation.
export class SyncWorkSlice {
  private started: number = 0;

  async checkpoint(): Promise<void> {
    if (Date.now() - this.started < 16) { return; }
    await new Promise<void>((resolve): void => { setTimeout(resolve, 0); });
    this.started = Date.now();
  }
}
