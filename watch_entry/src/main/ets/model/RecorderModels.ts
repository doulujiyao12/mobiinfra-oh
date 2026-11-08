export type RecordingMode = 'sound' | 'speech';

export class RecordingInfo {
  name: string = '';
  path: string = '';
  createdAt: number = 0;
  segment: number = 0;
  durationMs: number = 0;
  bytes: number = 0;
  recovered: boolean = false;
  mode: string = 'manual';
}

export class CaptureCommand {
  kind: string = '';
  filesDir: string = '';
  name: string = '';
  reason: string = '';
  mode: RecordingMode = 'sound';
}

export class CaptureEvent {
  kind: string = '';
  message: string = '';
  durationMs: number = 0;
  level: number = 0;
  segment: number = 0;
  records: RecordingInfo[] = [];
  availableBytes: number = 0;
  recoveredCount: number = 0;
  inputRate: number = 0;
  listeningMs: number = 0;
  saving: boolean = false;
}

export class WatchState {
  status: string = 'loading';
  durationMs: number = 0;
  level: number = 0;
  segment: number = 0;
  records: RecordingInfo[] = [];
  availableBytes: number = 0;
  notice: string = '';
  error: string = '';
  playingName: string = '';
  playbackMs: number = 0;
  playbackDurationMs: number = 0;
  playbackStatus: string = 'idle';
  inputRate: number = 0;
  listeningMs: number = 0;
  saving: boolean = false;
  mode: RecordingMode = 'sound';
}
