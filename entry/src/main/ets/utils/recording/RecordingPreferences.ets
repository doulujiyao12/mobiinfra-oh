export const DEFAULT_RECORDING_TRANSCRIPTION_ENGINE: string = 'system';
export const DEFAULT_RECORDING_SUMMARY_SOURCE: string = 'cloud';
export const DEFAULT_RECORDING_LIVE_TRANSCRIBE: boolean = true;
export const DEFAULT_RECORDING_AI_SEARCH: boolean = true;
export const RECORDING_LANGUAGE_LABELS: string[] = ['自动识别', '普通话', '英语', '日语', '韩语', '粤语'];

let initialized: boolean = false;
export function initializeRecordingPreferences(): void {
  if (initialized) { return; }
  // Defaults apply only to unset preferences; saved user choices remain valid.
  PersistentStorage.persistProp('recordingAutoSummary', true);
  PersistentStorage.persistProp('recordingAudioSource', 'environment');
  PersistentStorage.persistProp('recordingSummarySource', DEFAULT_RECORDING_SUMMARY_SOURCE);
  PersistentStorage.persistProp('recordingLiveTranscribe', DEFAULT_RECORDING_LIVE_TRANSCRIBE);
  PersistentStorage.persistProp('recordingSpeakerSeparation', false);
  PersistentStorage.persistProp('recordingTranscriptionEngine', DEFAULT_RECORDING_TRANSCRIPTION_ENGINE);
  PersistentStorage.persistProp('recordingLanguageIndex', 0);
  PersistentStorage.persistProp('recordingAiSearch', DEFAULT_RECORDING_AI_SEARCH);
  initialized = true;
}
