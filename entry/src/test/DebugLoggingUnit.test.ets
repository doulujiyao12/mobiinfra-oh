import { describe, it, expect } from '@ohos/hypium';
import { DEBUG_ENABLED_STORAGE_KEY, DebugSettings } from '../main/ets/utils/DebugSettings';
import { ChatSessionController } from '../main/ets/pages/chat/ChatSessionController';
import { CHAT_MESSAGE_KIND_TASK_TRACE, createChatMessage } from '../main/ets/pages/chat/ChatSessionTypes';

export default function debugLoggingUnitTest(): void {
  describe('DebugLoggingUnitTest', () => {
    it('requiresExplicitBooleanOptIn', 0, () => {
      let previous = AppStorage.get<boolean>(DEBUG_ENABLED_STORAGE_KEY);
      try {
        AppStorage.delete(DEBUG_ENABLED_STORAGE_KEY);
        expect(DebugSettings.isEnabled()).assertFalse();
        AppStorage.setOrCreate(DEBUG_ENABLED_STORAGE_KEY, false);
        expect(DebugSettings.isEnabled()).assertFalse();
        AppStorage.setOrCreate(DEBUG_ENABLED_STORAGE_KEY, true);
        expect(DebugSettings.isEnabled()).assertTrue();
        AppStorage.setOrCreate(DEBUG_ENABLED_STORAGE_KEY, false);
        expect(DebugSettings.isEnabled()).assertFalse();
      } finally {
        if (previous === undefined) { AppStorage.delete(DEBUG_ENABLED_STORAGE_KEY); }
        else { AppStorage.setOrCreate(DEBUG_ENABLED_STORAGE_KEY, previous); }
      }
    });

    it('doesNotTouchSessionFilesForDisabledTraces', 0, () => {
      let previous = AppStorage.get<boolean>(DEBUG_ENABLED_STORAGE_KEY);
      try {
        AppStorage.setOrCreate(DEBUG_ENABLED_STORAGE_KEY, false);
        let state = ChatSessionController.emptyState();
        // Invalid paths deliberately ensure an accidental storage read/write
        // cannot silently pass this test. Normal conversation storage is kept.
        let filesDir = '/debug-test-no-session-storage';
        let message = createChatMessage('trace', 'task', CHAT_MESSAGE_KIND_TASK_TRACE, '执行过程', 1, []);
        expect(ChatSessionController.appendMessage(filesDir, state, state.mode, message) === state).assertTrue();
        expect(ChatSessionController.appendMessageToSession(filesDir, state, 'session', message) === state).assertTrue();
        expect(ChatSessionController.appendTaskTraceLineToSession(filesDir, state, 'session', 'sensitive log', 'trace')
          === state).assertTrue();
        expect(state.activeMessages.length).assertEqual(0);
      } finally {
        if (previous === undefined) { AppStorage.delete(DEBUG_ENABLED_STORAGE_KEY); }
        else { AppStorage.setOrCreate(DEBUG_ENABLED_STORAGE_KEY, previous); }
      }
    });
  });
}
