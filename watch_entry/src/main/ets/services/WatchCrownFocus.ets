import { FrameCallback, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

// Scroll already handles rotations when focused. Only forward events bubbled up from another control.
export function scrollFromWatchAction(event: CrownEvent, scroller: Scroller, scrollFocused: boolean): void {
  if (!scrollFocused && event.action === CrownAction.UPDATE) {
    scroller.scrollBy(0, -event.degree * 2);
    event.stopPropagation();
  }
}

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

  request(context: UIContext, target: () => string, retries: number = 2): void {
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
          // A newly mounted overlay may still be waiting for window focus.
          if (retries > 0) { this.request(context, target, retries - 1); return; }
          hilog.warn(0x0000, 'WatchCrownFocus', 'Focus target unavailable: %{public}s', id);
        }
      }));
    } catch (_) {
      this.queued = false;
      hilog.warn(0x0000, 'WatchCrownFocus', 'Unable to schedule focus on this UI context');
    }
  }
}
