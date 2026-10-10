import { describe, it, expect } from '@ohos/hypium';
import {
  CHAT_MODE_CLOUD_AGENT,
  CHAT_MODE_LOCAL_INFERENCE,
  chatModeActionLabel,
  chatComposerBarHeight,
  chatComposerPrimaryActionRole,
  chatComposerVoiceReleaseShouldStop,
  chatComposerLineCount,
  chatInputAfterAcceptedSend,
  chatLocalInferenceStateIsStale,
  chatModeLabel,
  chatModePlaceholder,
  chatVoiceStatusBarVisible,
  chatVoiceStatusIsCapturing,
  chatVoiceStatusDetailText,
  chatModeSwitcherVisibleAfterScroll,
  chatTimeGreeting,
  chatDeepThinkingToggleVisible,
  cloudAgentDisplayText,
  hasCloudAgentDisplayOutput,
  isSupportedChatMode
} from '../main/ets/pages/chat/ChatPageTypes';

export default function chatPageTypesUnitTest() {
  describe('chatPageTypesUnitTest', () => {
    it('defaultsToCloudAgentLabels', 0, () => {
      expect(chatModeLabel(CHAT_MODE_CLOUD_AGENT)).assertEqual('云端智能体');
      expect(chatModePlaceholder(CHAT_MODE_CLOUD_AGENT)).assertEqual('发消息或输入任务...');
      expect(chatModeActionLabel(CHAT_MODE_CLOUD_AGENT)).assertEqual('发送');
    });

    it('keepsLocalInferenceAsSecondaryMode', 0, () => {
      expect(chatModeLabel(CHAT_MODE_LOCAL_INFERENCE)).assertEqual('本地推理');
      expect(chatModePlaceholder(CHAT_MODE_LOCAL_INFERENCE)).assertEqual('输入本地模型消息...');
      expect(isSupportedChatMode(CHAT_MODE_LOCAL_INFERENCE)).assertTrue();
      expect(isSupportedChatMode('unknown')).assertFalse();
    });

    it('keepsDefaultCloudStatusOutOfConversation', 0, () => {
      expect(hasCloudAgentDisplayOutput('请先配置 Planner 和 Decider 云端服务')).assertFalse();
      expect(hasCloudAgentDisplayOutput('')).assertFalse();
    });

    it('extractsPlannerResponseAsConversationText', 0, () => {
      let logs = '[23:00:19] 手动调用 Planner，任务：你好\n' +
        '[23:00:22] Planner 手动返回：\n你好！我是 MobiAgent。';
      expect(hasCloudAgentDisplayOutput(logs)).assertTrue();
      expect(cloudAgentDisplayText(logs)).assertEqual('你好！我是 MobiAgent。');
    });

    it('clearsDraftOnlyAfterAcceptedSend', 0, () => {
      expect(chatInputAfterAcceptedSend('请问您做什么呢？', true)).assertEqual('');
      expect(chatInputAfterAcceptedSend('请问您做什么呢？', false)).assertEqual('请问您做什么呢？');
    });

    it('releasesOnlyCompletedSubmittedLocalInferenceState', 0, () => {
      expect(chatLocalInferenceStateIsStale(true, true, false)).assertTrue();
      expect(chatLocalInferenceStateIsStale(true, true, true)).assertFalse();
      expect(chatLocalInferenceStateIsStale(true, false, false)).assertFalse();
      expect(chatLocalInferenceStateIsStale(false, true, false)).assertFalse();
    });

    it('usesOnePrimaryComposerButtonForSendAndVoiceCapture', 0, () => {
      expect(chatComposerPrimaryActionRole(false, false)).assertEqual('send');
      expect(chatComposerPrimaryActionRole(true, false)).assertEqual('busy');
      expect(chatComposerPrimaryActionRole(true, true)).assertEqual('voice_capture');
      expect(chatComposerPrimaryActionRole(false, true)).assertEqual('voice_capture');
      expect(chatComposerVoiceReleaseShouldStop('idle')).assertTrue();
      expect(chatComposerVoiceReleaseShouldStop('listening')).assertTrue();
      expect(chatComposerVoiceReleaseShouldStop('transcribing')).assertTrue();
      expect(chatComposerVoiceReleaseShouldStop('speaking')).assertFalse();
      expect(chatVoiceStatusIsCapturing('listening')).assertTrue();
      expect(chatVoiceStatusIsCapturing('transcribing')).assertFalse();
      expect(chatVoiceStatusIsCapturing('idle')).assertFalse();
    });

    it('keepsVoiceTranscriptOnlyInsideEditableDraft', 0, () => {
      expect(chatVoiceStatusBarVisible('idle')).assertFalse();
      expect(chatVoiceStatusBarVisible('idle', '已经写入输入框')).assertFalse();
      expect(chatVoiceStatusBarVisible('transcribing', '已经写入输入框')).assertTrue();
      expect(chatVoiceStatusBarVisible('speaking')).assertFalse();
      expect(chatVoiceStatusDetailText('transcribing', '已经写入输入框')).assertEqual('');
    });

    it('expandsComposerHeightForMultiLineDrafts', 0, () => {
      expect(chatComposerLineCount('短消息')).assertEqual(1);
      expect(chatComposerBarHeight('短消息')).assertEqual(58);
      expect(chatComposerLineCount('已完成修复审核并且提交')).assertEqual(2);
      expect(chatComposerBarHeight('已完成修复审核并且提交')).assertEqual(80);
      expect(chatComposerLineCount('第一行\n第二行')).assertEqual(2);
      expect(chatComposerBarHeight('第一行\n第二行')).assertEqual(80);
      expect(chatComposerLineCount('请帮我整理今天截图里的关键信息，并按照时间线、待办事项、需要继续跟进的问题分别输出')).assertEqual(4);
      expect(chatComposerBarHeight('请帮我整理今天截图里的关键信息，并按照时间线、待办事项、需要继续跟进的问题分别输出')).assertEqual(124);
    });

    it('usesTimeAwareWelcomeGreeting', 0, () => {
      expect(chatTimeGreeting(2)).assertEqual('夜深了');
      expect(chatTimeGreeting(8)).assertEqual('早上好');
      expect(chatTimeGreeting(12)).assertEqual('中午好');
      expect(chatTimeGreeting(15)).assertEqual('下午好');
      expect(chatTimeGreeting(21)).assertEqual('晚上好');
    });

    it('updatesModeSwitcherVisibilityByScrollDirection', 0, () => {
      expect(chatModeSwitcherVisibleAfterScroll(true, 8)).assertFalse();
      expect(chatModeSwitcherVisibleAfterScroll(false, -8)).assertTrue();
      expect(chatModeSwitcherVisibleAfterScroll(true, 2)).assertTrue();
      expect(chatModeSwitcherVisibleAfterScroll(false, -2)).assertFalse();
    });

    it('showsDeepThinkingToggleOnlyForCloudChat', 0, () => {
      expect(chatDeepThinkingToggleVisible(CHAT_MODE_CLOUD_AGENT)).assertTrue();
      expect(chatDeepThinkingToggleVisible(CHAT_MODE_LOCAL_INFERENCE)).assertFalse();
    });
  });
}
