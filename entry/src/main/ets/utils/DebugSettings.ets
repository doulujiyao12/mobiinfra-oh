import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import native from 'libentry.so';

export const DEBUG_ENABLED_STORAGE_KEY: string = 'debugEnabled';
const DEBUG_PREFERENCES_NAME: string = 'debug_settings';

// Default off, including before Ability initialization. Do not use AppLogger here:
// it depends on this setting and must never produce logs while loading it.
export class DebugSettings {
  private static store: preferences.Preferences | undefined = undefined;

  static isEnabled(): boolean {
    return AppStorage.get<boolean>(DEBUG_ENABLED_STORAGE_KEY) === true;
  }

  static initialize(context: common.Context): void {
    if (DebugSettings.store !== undefined) { return; }
    let store = preferences.getPreferencesSync(context, { name: DEBUG_PREFERENCES_NAME });
    let enabled = store.getSync(DEBUG_ENABLED_STORAGE_KEY, false) === true;
    // The native pipe also observes NPU status. It keeps draining when Debug is
    // off, without opening a log file or adding lines to the runtime buffer.
    native.initLogFile(context.filesDir + '/mnn_runtime.log');
    native.setDebugLogging(enabled);
    DebugSettings.publish(enabled);
    DebugSettings.store = store;
  }

  static setEnabled(context: common.Context, enabled: boolean): void {
    DebugSettings.initialize(context);
    let store = DebugSettings.store;
    if (store === undefined) { throw new Error('Debug 设置尚未初始化'); }
    let previous = DebugSettings.isEnabled();
    if (previous === enabled) { return; }
    try {
      store.putSync(DEBUG_ENABLED_STORAGE_KEY, enabled);
      store.flushSync();
      native.setDebugLogging(enabled);
    } catch (e) {
      // Keep the switch and its persisted value consistent after a failed save.
      try { store.putSync(DEBUG_ENABLED_STORAGE_KEY, previous); store.flushSync(); } catch (rollbackError) {}
      throw e as Error;
    }
    DebugSettings.publish(enabled);
  }

  private static publish(enabled: boolean): void {
    if (!enabled) {
      AppStorage.setOrCreate('cloudAgentLogs', '');
      AppStorage.setOrCreate('galleryLogs', '');
    }
    AppStorage.setOrCreate(DEBUG_ENABLED_STORAGE_KEY, enabled);
  }
}
