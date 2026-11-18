import { FrameCallback, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

class FocusAfterLayout extends FrameCallback {
  private action: () => void;

  constructor(action: () => void) {
    super();
    this.action = action;
  }

  onIdle(_timeLeftInNano: number): void { this.action(); }
}

// State observers run before ArkUI mounts/enables the new content. Resolve the
// current target at frame end, and invalidate queued work when the page leaves.
export class WatchCrownFocus {
  private queued: boolean = false;
  private revision: number = 0;

  cancel(): void {
    this.revision++;
    this.queued = false;
  }

  request(context: UIContext, target: () => string): void {
    if (this.queued) { return; }
    this.queued = true;
    const revision = this.revision;
    try {
      context.postFrameCallback(new FocusAfterLayout((): void => {
        if (revision !== this.revision) { return; }
        this.queued = false;
        const id = target();
        if (!id) { return; }
        try {
          context.getFocusController().requestFocus(id);
        } catch (_) {
          // A window may disappear between layout and focus. Focus failure must
          // never abort recording or application startup; the next show retries.
          hilog.warn(0x0000, 'WatchCrownFocus', 'Focus target unavailable: %{public}s', id);
        }
      }));
    } catch (_) {
      this.queued = false;
      hilog.warn(0x0000, 'WatchCrownFocus', 'Unable to schedule focus on this UI context');
    }
  }
}
