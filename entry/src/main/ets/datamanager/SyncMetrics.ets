import { dataManagerInfo } from './DataManagerLog';

export class SyncMetrics {
  private started: number = Date.now();
  private stageStarted: number = this.started;
  private stage: string = '';
  private run: string = String(this.started);
  mark(stage: string): void {
    if (stage === this.stage) { return; }
    if (this.stage.length > 0) { this.endStage(); }
    this.stage = stage; this.stageStarted = Date.now();
    dataManagerInfo('SYNC_STAGE_BEGIN run=' + this.run + ' stage=' + stage);
  }
  finish(success: boolean): void {
    if (this.stage.length > 0) { this.endStage(); this.stage = ''; }
    dataManagerInfo('SYNC_FINISH run=' + this.run + ' success=' + success + ' elapsedMs=' + (Date.now() - this.started));
  }
  private endStage(): void {
    dataManagerInfo('SYNC_STAGE_END run=' + this.run + ' stage=' + this.stage + ' elapsedMs=' + (Date.now() - this.stageStarted));
  }
}
