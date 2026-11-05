import { common, Want, wantConstant } from '@kit.AbilityKit';
import { RecordingStore } from './RecordingStore';

export const RECORDING_INBOX_KEY: string = 'recordingAnalysisInbox';
export class RecordingInbox {
  private static uris(want: Want): string[] {
    let values: string[] = [];
    if (want.uri) { values.push(want.uri); }
    let streams = want.parameters?.[wantConstant.Params.PARAMS_STREAM];
    if (typeof streams === 'string') { values.push(streams); }
    else if (Array.isArray(streams)) {
      for (let value of streams as Object[]) { if (typeof value === 'string') { values.push(value); } }
    }
    return values.filter((value: string, index: number): boolean => value.startsWith('file://') && values.indexOf(value) === index).slice(0, 8);
  }
  static accepts(want: Want): boolean {
    if (['ohos.want.action.viewData', 'ohos.want.action.sendData', 'ohos.want.action.sendMultipleData'].indexOf(want.action || '') < 0) { return false; }
    let type = (want.type || '').toLowerCase();
    return RecordingInbox.uris(want).some((uri: string): boolean => /\.wav(?:[?#]|$)/i.test(uri)) ||
      ['audio/wav', 'audio/x-wav', 'audio/wave', 'audio/vnd.wave'].indexOf(type) >= 0;
  }
  static async receive(context: common.UIAbilityContext, want: Want): Promise<void> {
    let uris = RecordingInbox.uris(want);
    if (uris.length === 0) { throw new Error('未收到可读取的 WAV 文件，请从录音分析页面导入'); }
    let store = new RecordingStore(context.filesDir);
    // Copy while the temporary incoming URI grant is still valid.
    for (let uri of uris) {
      let record = await store.importWav(uri);
      AppStorage.setOrCreate(RECORDING_INBOX_KEY, record.id);
    }
  }
}
