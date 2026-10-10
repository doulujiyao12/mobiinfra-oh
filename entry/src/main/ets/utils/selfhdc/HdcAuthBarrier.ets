// Every AUTH_OK (including an unauthorized notification) is followed by a channel-0 close.
// A close ACK on channel 0 calls ClearOwnTasks(session, 0) on the daemon: it clears ALL tasks.
// Do not release shell work until the SUCCESS close and all preceding closes have been ACKed.
export class HdcAuthBarrier {
  private pendingCloses: number = 0;
  private successSeen: boolean = false;
  private ready: boolean = false;

  authOk(success: boolean): void {
    if (this.ready) { throw new Error('HDC_AUTH: unexpected handshake after shell session became ready'); }
    this.pendingCloses++;
    if (success) { this.successSeen = true; }
  }

  // Call only AFTER awaiting the channel-0 close ACK write, never when AUTH_OK first arrives.
  closeAcknowledged(): boolean {
    if (this.ready) { throw new Error('HDC_AUTH: unexpected channel-0 close after session became ready'); }
    if (this.pendingCloses === 0) { return false; }
    this.pendingCloses--;
    this.ready = this.successSeen && this.pendingCloses === 0;
    return this.ready;
  }

  hasSuccess(): boolean { return this.successSeen; }
  isReady(): boolean { return this.ready; }
}
