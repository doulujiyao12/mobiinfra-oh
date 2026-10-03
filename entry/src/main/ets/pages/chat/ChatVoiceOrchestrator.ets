import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { ChatSessionController, ChatSessionViewState } from './ChatSessionController';
import {
  ChatVoiceMetadata,
  VoiceSessionController,
  VoiceSessionSnapshot,
  appendVoiceTranscriptToInput,
  createTtsVoiceMetadata,
  createTtsVoiceRuntimeMetadata,
  createVoiceErrorMetadata
} from './VoiceInteractionTypes';
import { ChatMessage, chatMessageVoiceMetadata } from './ChatSessionTypes';
import { ChatSessionStorage } from '../../utils/ChatSessionStorage';
import { HarmonyAudioPlayback } from '../../utils/voice/HarmonyAudioPlayback';
import { HarmonyPcmStreamPlayback } from '../../utils/voice/HarmonyPcmStreamPlayback';
import { HarmonySpeechRecognizerAsrProvider } from '../../utils/voice/HarmonySpeechRecognizerAsrProvider';
import { MimoTtsStreamRequestControl, MimoVoiceClient } from '../../utils/voice/MimoVoiceClient';
import { buildPcm16WavBytes, concatPcmChunks } from '../../utils/voice/PcmWav';
import { showToastSafely } from '../../utils/PromptSafe';
import { AiServiceAccess } from '../../utils/AiServiceAccess';

export interface ChatVoiceTtsConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  voice: string;
  stylePrompt: string;
  streamingEnabled: boolean;
}

export interface ChatVoiceInputDraftTarget {
  id: string;
  text: string;
}

export interface ChatVoiceOrchestratorHost {
  filesDir: () => string;
  abilityContext: () => common.UIAbilityContext;
  activeSessionId: () => string;
  isBusy: () => boolean;
  activeInputDraftTarget: () => ChatVoiceInputDraftTarget;
  setInputDraftForTarget: (targetId: string, text: string) => void;
  currentChatSessionViewState: () => ChatSessionViewState;
  applyChatSessionViewState: (state: ChatSessionViewState) => void;
  ttsConfig: () => ChatVoiceTtsConfig;
  onSnapshot: (snapshot: VoiceSessionSnapshot) => void;
}

export function nextVoiceInputStartGeneration(currentGeneration: number): number {
  return currentGeneration + 1;
}

export function voiceInputStopGeneration(latestStartGeneration: number, previousStoppedGeneration: number): number {
  return Math.max(latestStartGeneration, previousStoppedGeneration);
}

export function voiceInputStartCanProceed(startGeneration: number, latestStartGeneration: number,
  stoppedGeneration: number): boolean {
  return startGeneration === latestStartGeneration && startGeneration > stoppedGeneration;
}

const VOICE_INPUT_STOP_FALLBACK_MS: number = 1500;

export class ChatVoiceOrchestrator {
  private host: ChatVoiceOrchestratorHost;
  private voiceController: VoiceSessionController = new VoiceSessionController();
  private asrProvider: HarmonySpeechRecognizerAsrProvider = new HarmonySpeechRecognizerAsrProvider();
  private voiceTtsClient: MimoVoiceClient = new MimoVoiceClient();
  private voiceAudioPlayback: HarmonyAudioPlayback = new HarmonyAudioPlayback();
  private voicePcmStreamPlayback: HarmonyPcmStreamPlayback = new HarmonyPcmStreamPlayback();
  private handledVoiceTurnId: string = '';
  private voiceDraftTargetId: string = '';
  private voiceDraftBaseInput: string = '';
  private voicePlaybackGeneration: number = 0;
  private voicePlaybackSessionId: string = '';
  private voicePlaybackAudioUri: string = '';
  private voicePlaybackVoice: string = '';
  private voiceTtsStreamCancel: () => void = () => {};
  private voiceInputStartGeneration: number = 0;
  private voiceInputStoppedGeneration: number = 0;
  private voiceInputStopFallbackTimerId: number = -1;

  constructor(host: ChatVoiceOrchestratorHost) {
    this.host = host;
  }

  snapshot(): VoiceSessionSnapshot {
    return this.voiceController.snapshot();
  }

  private emitSnapshot(): void {
    this.host.onSnapshot(this.voiceController.snapshot());
  }

  private failVoiceInteraction(message: string): void {
    this.clearVoiceInputStopFallbackTimer();
    this.voiceController.fail(message);
    this.emitSnapshot();
    showToastSafely(message, 1800);
  }

  async toggleVoiceInput(): Promise<void> {
    AiServiceAccess.requireAllowed();
    let status = this.voiceController.snapshot().status;
    if (status === 'listening' || status === 'transcribing') {
      await this.stopVoiceInput();
      return;
    }
    if (status === 'speaking' || status === 'synthesizing' || status === 'paused') {
      await this.stopVoicePlayback();
      return;
    }
    if (this.host.isBusy()) {
      showToastSafely('当前正在处理消息，稍后再使用语音', 1600);
      return;
    }
    await this.startVoiceInput();
  }

  async stopVoiceInput(): Promise<void> {
    this.voiceInputStoppedGeneration = voiceInputStopGeneration(this.voiceInputStartGeneration,
      this.voiceInputStoppedGeneration);
    let snapshot = this.voiceController.snapshot();
    let status = snapshot.status;
    if (status === 'listening' || status === 'transcribing') {
      this.voiceController.markTranscribing();
      this.emitSnapshot();
      this.scheduleVoiceInputStopFallback(snapshot.turnId);
      this.asrProvider.finish();
    }
  }

  async playAssistantMessageVoice(messageId: string, text: string): Promise<void> {
    AiServiceAccess.requireAllowed();
    let sessionId = this.host.activeSessionId();
    await this.playAssistantMessageVoiceInSession(sessionId, messageId, text, false);
  }

  async replayAssistantMessageVoice(messageId: string, text: string): Promise<void> {
    AiServiceAccess.requireAllowed();
    let sessionId = this.host.activeSessionId();
    await this.playAssistantMessageVoiceInSession(sessionId, messageId, text, true);
  }

  shutdown(): void {
    this.clearVoiceInputStopFallbackTimer();
    this.asrProvider.shutdown();
    this.voicePlaybackGeneration++;
    this.voiceTtsStreamCancel();
    this.voiceTtsStreamCancel = () => {};
    this.voiceAudioPlayback.stop().catch(() => {});
    this.voicePcmStreamPlayback.stop().catch(() => {});
    this.voiceController.reset();
    this.voiceDraftTargetId = '';
    this.voiceDraftBaseInput = '';
    this.voiceInputStoppedGeneration = voiceInputStopGeneration(this.voiceInputStartGeneration,
      this.voiceInputStoppedGeneration);
    this.clearVoicePlaybackContext();
    this.emitSnapshot();
  }

  private async ensureMicrophonePermission(): Promise<boolean> {
    try {
      let permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
      let result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.host.abilityContext(),
        permissions);
      for (let i = 0; i < result.permissions.length; i++) {
        if (result.permissions[i] === 'ohos.permission.MICROPHONE' && result.authResults[i] === 0) {
          return true;
        }
      }
      showToastSafely('需要麦克风权限才能语音输入', 1800);
      return false;
    } catch (e) {
      let err = e as Error;
      showToastSafely('麦克风权限请求失败：' + err.message, 1800);
      return false;
    }
  }

  private async startVoiceInput(): Promise<void> {
    this.clearVoiceInputStopFallbackTimer();
    let startGeneration = nextVoiceInputStartGeneration(this.voiceInputStartGeneration);
    this.voiceInputStartGeneration = startGeneration;
    let granted = await this.ensureMicrophonePermission();
    if (!granted || !AiServiceAccess.isAllowed()) {
      return;
    }
    if (!this.voiceInputStartActive(startGeneration)) {
      return;
    }
    let turnId = 'voice-' + String(new Date().getTime());
    this.handledVoiceTurnId = '';
    let draftTarget = this.host.activeInputDraftTarget();
    this.voiceDraftTargetId = draftTarget.id;
    this.voiceDraftBaseInput = draftTarget.text;
    this.voiceController.beginListening(turnId);
    this.emitSnapshot();
    try {
      await this.asrProvider.start({
        onStart: (sessionId: string) => {
          if (sessionId !== turnId || !this.voiceTurnActive(turnId)) {
            return;
          }
          this.voiceController.beginListening(turnId);
          this.emitSnapshot();
        },
        onPartialTranscript: (transcript: string) => {
          if (!this.voiceTurnActive(turnId)) {
            return;
          }
          this.voiceController.updatePartialTranscript(transcript);
          this.applyVoiceTranscriptDraft(transcript);
          this.emitSnapshot();
        },
        onFinalTranscript: (transcript: string, isLast: boolean) => {
          if (!this.voiceTurnActive(turnId)) {
            return;
          }
          this.voiceController.completeTranscript(transcript);
          this.applyVoiceTranscriptDraft(transcript);
          this.emitSnapshot();
          if (isLast) {
            this.handleVoiceTranscriptComplete(transcript).catch((e: Error) => {
              this.failVoiceInteraction(e.message);
            });
          }
        },
        onComplete: (transcript: string) => {
          if (!this.voiceTurnActive(turnId)) {
            return;
          }
          this.handleVoiceTranscriptComplete(transcript).catch((e: Error) => {
            this.failVoiceInteraction(e.message);
          });
        },
        onError: (message: string) => {
          if (!this.voiceTurnActive(turnId)) {
            return;
          }
          this.failVoiceInteraction(message);
        }
      }, {
        language: 'zh-CN',
        sessionId: turnId
      });
      if (!this.voiceInputStartActive(startGeneration)) {
        if (this.voiceTurnActive(turnId)) {
          this.asrProvider.finish();
        }
      }
    } catch (e) {
      let err = e as Error;
      this.failVoiceInteraction(err.message);
    }
  }

  private voiceTurnActive(turnId: string): boolean {
    return this.voiceController.snapshot().turnId === turnId;
  }

  private voiceInputStartActive(startGeneration: number): boolean {
    return voiceInputStartCanProceed(startGeneration, this.voiceInputStartGeneration,
      this.voiceInputStoppedGeneration);
  }

  private clearVoiceInputStopFallbackTimer(): void {
    if (this.voiceInputStopFallbackTimerId !== -1) {
      clearTimeout(this.voiceInputStopFallbackTimerId);
      this.voiceInputStopFallbackTimerId = -1;
    }
  }

  private scheduleVoiceInputStopFallback(turnId: string): void {
    if (turnId.length === 0) {
      return;
    }
    this.clearVoiceInputStopFallbackTimer();
    // finish() 依赖系统 ASR 回调；部分设备静默或取消时可能不回调，用短超时防止 UI 长时间停在转写态。
    this.voiceInputStopFallbackTimerId = setTimeout(() => {
      this.voiceInputStopFallbackTimerId = -1;
      let snapshot = this.voiceController.snapshot();
      if (snapshot.turnId !== turnId) {
        return;
      }
      if (snapshot.status !== 'listening' && snapshot.status !== 'transcribing') {
        return;
      }
      let transcript = snapshot.finalTranscript.trim().length > 0 ? snapshot.finalTranscript : snapshot.partialTranscript;
      if (transcript.trim().length > 0) {
        this.handleVoiceTranscriptComplete(transcript).catch((e: Error) => {
          this.failVoiceInteraction(e.message);
        });
        return;
      }
      this.finishVoiceInputWithoutTranscript();
    }, VOICE_INPUT_STOP_FALLBACK_MS);
  }

  private shouldHandleVoiceTranscriptComplete(snapshot: VoiceSessionSnapshot): boolean {
    if (snapshot.turnId.length === 0) {
      return false;
    }
    if (this.handledVoiceTurnId === snapshot.turnId) {
      return false;
    }
    this.handledVoiceTurnId = snapshot.turnId;
    return true;
  }

  private applyVoiceTranscriptDraft(transcript: string): void {
    if (transcript.trim().length === 0) {
      return;
    }
    if (this.voiceDraftTargetId.length === 0) {
      return;
    }
    this.host.setInputDraftForTarget(this.voiceDraftTargetId,
      appendVoiceTranscriptToInput(this.voiceDraftBaseInput, transcript));
  }

  private async handleVoiceTranscriptComplete(transcript: string): Promise<void> {
    let snapshot = this.voiceController.snapshot();
    if (!this.shouldHandleVoiceTranscriptComplete(snapshot)) {
      return;
    }
    this.clearVoiceInputStopFallbackTimer();
    let finalTranscript = transcript.trim().length > 0 ? transcript.trim() : snapshot.finalTranscript.trim();
    if (finalTranscript.length === 0) {
      this.finishVoiceInputWithoutTranscript();
      return;
    }
    this.voiceController.completeTranscript(finalTranscript);
    this.applyVoiceTranscriptDraft(finalTranscript);
    this.emitSnapshot();
    this.voiceController.reset();
    this.voiceDraftTargetId = '';
    this.voiceDraftBaseInput = '';
    this.voiceInputStoppedGeneration = voiceInputStopGeneration(this.voiceInputStartGeneration,
      this.voiceInputStoppedGeneration);
    this.emitSnapshot();
    showToastSafely('语音已转写到输入框', 1200);
  }

  private finishVoiceInputWithoutTranscript(): void {
    this.clearVoiceInputStopFallbackTimer();
    this.voiceController.completeWithoutTranscript();
    this.voiceDraftTargetId = '';
    this.voiceDraftBaseInput = '';
    this.voiceInputStoppedGeneration = voiceInputStopGeneration(this.voiceInputStartGeneration,
      this.voiceInputStoppedGeneration);
    this.emitSnapshot();
    showToastSafely('没有识别到语音内容', 1200);
  }

  private ttsConfigReady(): boolean {
    let config = this.host.ttsConfig();
    return config.baseUrl.trim().length > 0 && config.apiKey.trim().length > 0 &&
      config.model.trim().length > 0 && config.voice.trim().length > 0;
  }

  private updateMessageVoiceMetadataForSession(sessionId: string, messageId: string,
    voice?: ChatVoiceMetadata): void {
    let state = ChatSessionController.updateMessageVoiceMetadataInSession(this.host.filesDir(),
      this.host.currentChatSessionViewState(), sessionId, messageId, voice);
    this.host.applyChatSessionViewState(state);
  }

  private voiceTtsAssetPath(sessionId: string, messageId: string): string {
    return ChatSessionStorage.sessionAssetPath(this.host.filesDir(), sessionId, messageId + '-tts.wav');
  }

  private voiceTtsSessionExists(sessionId: string): boolean {
    return ChatSessionStorage.sessionExists(this.host.filesDir(), sessionId);
  }

  private prepareVoiceTtsAssetWritePath(sessionId: string, messageId: string): string {
    if (!this.voiceTtsSessionExists(sessionId)) {
      return '';
    }
    ChatSessionStorage.ensureSessionAssetsDir(this.host.filesDir(), sessionId);
    if (!this.voiceTtsSessionExists(sessionId)) {
      ChatSessionStorage.deleteSessionAssetsDir(this.host.filesDir(), sessionId);
      return '';
    }
    return this.voiceTtsAssetPath(sessionId, messageId);
  }

  private completeVoiceTtsAssetWrite(sessionId: string, path: string): boolean {
    if (this.voiceTtsSessionExists(sessionId)) {
      return true;
    }
    // TTS 可能在会话删除后才完成；此时必须移除刚创建的缓存，避免留下孤立 assets 目录。
    try {
      if (ChatSessionStorage.pathExists(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
    }
    ChatSessionStorage.deleteSessionAssetsDir(this.host.filesDir(), sessionId);
    return false;
  }

  private finishVoicePlaybackForDeletedSession(generation: number): void {
    if (!this.voicePlaybackGenerationActive(generation)) {
      return;
    }
    this.clearVoicePlaybackContext();
    this.voiceController.finishSpeaking();
    this.emitSnapshot();
  }

  private saveVoiceTtsAudio(sessionId: string, messageId: string, audioBase64: string): string {
    let path = this.prepareVoiceTtsAssetWritePath(sessionId, messageId);
    if (path.length === 0) {
      return '';
    }
    let helper = new util.Base64Helper();
    let bytes = helper.decodeSync(audioBase64);
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, bytes.buffer);
    } finally {
      fs.closeSync(file);
    }
    if (!this.completeVoiceTtsAssetWrite(sessionId, path)) {
      return '';
    }
    return 'file://' + path;
  }

  private saveVoiceTtsPcmAudio(sessionId: string, messageId: string, chunks: Uint8Array[]): string {
    let path = this.prepareVoiceTtsAssetWritePath(sessionId, messageId);
    if (path.length === 0) {
      return '';
    }
    let pcm = concatPcmChunks(chunks);
    let wavBytes = buildPcm16WavBytes(pcm, { sampleRate: 24000, channels: 1 });
    let file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, wavBytes.buffer);
    } finally {
      fs.closeSync(file);
    }
    if (!this.completeVoiceTtsAssetWrite(sessionId, path)) {
      return '';
    }
    return 'file://' + path;
  }

  private nextVoicePlaybackGeneration(): number {
    this.voicePlaybackGeneration++;
    return this.voicePlaybackGeneration;
  }

  private voicePlaybackGenerationActive(generation: number): boolean {
    return generation === this.voicePlaybackGeneration;
  }

  private clearVoicePlaybackContext(): void {
    this.voicePlaybackSessionId = '';
    this.voicePlaybackAudioUri = '';
    this.voicePlaybackVoice = '';
    this.voiceTtsStreamCancel = () => {};
  }

  private messageVoiceMetadata(messageId: string): ChatVoiceMetadata {
    let messages: ChatMessage[] = this.host.currentChatSessionViewState().activeMessages;
    for (let index = 0; index < messages.length; index++) {
      if (messages[index].id === messageId) {
        return chatMessageVoiceMetadata(messages[index]);
      }
    }
    return {
      input: 'none',
      provider: '',
      status: 'none',
      transcript: '',
      confidence: 0,
      audioUri: '',
      voice: '',
      error: '',
      createdAt: 0
    };
  }

  private async playAssistantMessageVoiceInSession(sessionId: string, messageId: string, text: string,
    replay: boolean): Promise<void> {
    if (sessionId.length === 0 || messageId.length === 0 || text.trim().length === 0) {
      return;
    }
    let snapshot = this.voiceController.snapshot();
    if (snapshot.activeMessageId === messageId && !replay) {
      if (snapshot.status === 'speaking') {
        await this.pauseVoicePlayback(sessionId, messageId);
        return;
      }
      if (snapshot.status === 'paused') {
        await this.resumeVoicePlayback(sessionId, messageId);
        return;
      }
      if (snapshot.status === 'synthesizing') {
        await this.stopVoicePlayback();
        return;
      }
    }
    let cachedVoice = this.messageVoiceMetadata(messageId);
    if (replay && cachedVoice.audioUri.length === 0) {
      showToastSafely(snapshot.activeMessageId === messageId ? '语音仍在生成缓存，稍后再重播' : '暂无可重播语音', 1400);
      return;
    }
    if (cachedVoice.audioUri.length === 0 && !this.ttsConfigReady()) {
      showToastSafely('请先在设置中配置语音合成服务和 API Key', 1800);
      return;
    }
    await this.stopVoicePlayback();
    let config = this.host.ttsConfig();
    let generation = this.nextVoicePlaybackGeneration();
    this.voicePlaybackSessionId = sessionId;
    this.voicePlaybackVoice = config.voice;
    this.voicePlaybackAudioUri = '';
    if (cachedVoice.audioUri.length > 0) {
      await this.playCachedVoiceAudio(sessionId, messageId, cachedVoice.audioUri,
        cachedVoice.voice.length > 0 ? cachedVoice.voice : config.voice, generation);
      return;
    }
    if (config.streamingEnabled) {
      await this.playStreamingVoiceAudio(sessionId, messageId, text, generation);
      return;
    }
    await this.playNonStreamingVoiceAudio(sessionId, messageId, text, generation);
  }

  private async playCachedVoiceAudio(sessionId: string, messageId: string, audioUri: string, voice: string,
    generation: number): Promise<void> {
    this.voicePlaybackAudioUri = audioUri;
    this.voicePlaybackVoice = voice;
    await this.voiceAudioPlayback.playFile(audioUri, {
      onStarted: () => {
        if (!this.voicePlaybackGenerationActive(generation)) {
          return;
        }
        this.voiceController.beginSpeaking(messageId);
        this.updateMessageVoiceMetadataForSession(sessionId, messageId,
          createTtsVoiceRuntimeMetadata('mimo', voice, audioUri, 'playing', new Date().getTime()));
        this.emitSnapshot();
      },
      onCompleted: () => {
        this.handleVoicePlaybackCompleted(sessionId, messageId, voice, audioUri, generation);
      },
      onError: (message: string) => {
        this.handleVoicePlaybackError(sessionId, messageId, message, generation);
      }
    });
  }

  private async playNonStreamingVoiceAudio(sessionId: string, messageId: string, text: string,
    generation: number): Promise<void> {
    let config = this.host.ttsConfig();
    this.voiceController.beginSynthesizing(messageId);
    this.emitSnapshot();
    this.updateMessageVoiceMetadataForSession(sessionId, messageId,
      createTtsVoiceMetadata('mimo', config.voice, '', new Date().getTime()));
    try {
      let result = await this.voiceTtsClient.synthesizeSpeech(text.trim(), {
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        model: config.model,
        voice: config.voice,
        stylePrompt: config.stylePrompt
      });
      if (!this.voicePlaybackGenerationActive(generation)) {
        return;
      }
      let audioUri = this.saveVoiceTtsAudio(sessionId, messageId, result.audioBase64);
      if (audioUri.length === 0) {
        this.finishVoicePlaybackForDeletedSession(generation);
        return;
      }
      this.voicePlaybackAudioUri = audioUri;
      this.voicePlaybackVoice = result.voice;
      if (!this.voicePlaybackGenerationActive(generation)) {
        return;
      }
      this.updateMessageVoiceMetadataForSession(sessionId, messageId,
        createTtsVoiceMetadata('mimo', result.voice, audioUri, new Date().getTime()));
      await this.voiceAudioPlayback.playFile(audioUri, {
        onStarted: () => {
          if (!this.voicePlaybackGenerationActive(generation)) {
            return;
          }
          this.voiceController.beginSpeaking(messageId);
          this.updateMessageVoiceMetadataForSession(sessionId, messageId,
            createTtsVoiceRuntimeMetadata('mimo', result.voice, audioUri, 'playing', new Date().getTime()));
          this.emitSnapshot();
        },
        onCompleted: () => {
          this.handleVoicePlaybackCompleted(sessionId, messageId, result.voice, audioUri, generation);
        },
        onError: (message: string) => {
          this.handleVoicePlaybackError(sessionId, messageId, message, generation);
        }
      });
    } catch (e) {
      if (!this.voicePlaybackGenerationActive(generation)) {
        return;
      }
      let err = e as Error;
      this.updateMessageVoiceMetadataForSession(sessionId, messageId,
        createVoiceErrorMetadata('tts', 'mimo', err.message, new Date().getTime()));
      this.clearVoicePlaybackContext();
      this.failVoiceInteraction('语音合成失败：' + err.message);
    }
  }

  private async playStreamingVoiceAudio(sessionId: string, messageId: string, text: string,
    generation: number): Promise<void> {
    let config = this.host.ttsConfig();
    let pcmChunks: Uint8Array[] = [];
    let firstChunkReceived = false;
    let audioUri = '';
    let completedBeforeCacheReady = false;
    this.voiceController.beginSynthesizing(messageId);
    this.emitSnapshot();
    this.updateMessageVoiceMetadataForSession(sessionId, messageId,
      createTtsVoiceMetadata('mimo', config.voice, '', new Date().getTime()));
    try {
      await this.voicePcmStreamPlayback.start({
        onCompleted: () => {
          if (audioUri.length === 0) {
            completedBeforeCacheReady = true;
            return;
          }
          this.handleVoicePlaybackCompleted(sessionId, messageId, config.voice, audioUri, generation);
        },
        onError: (message: string) => {
          this.handleVoicePlaybackError(sessionId, messageId, message, generation);
        }
      });
      await this.voiceTtsClient.synthesizeSpeechStream(text.trim(), {
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        model: config.model,
        voice: config.voice,
        stylePrompt: config.stylePrompt
      }, {
        onRequest: (control: MimoTtsStreamRequestControl) => {
          this.voiceTtsStreamCancel = control.cancel;
        },
        onPcmChunk: (chunk: Uint8Array) => {
          if (!this.voicePlaybackGenerationActive(generation)) {
            return;
          }
          pcmChunks.push(chunk);
          this.voicePcmStreamPlayback.appendChunk(chunk);
          if (!firstChunkReceived) {
            firstChunkReceived = true;
            this.voiceController.beginSpeaking(messageId);
            this.updateMessageVoiceMetadataForSession(sessionId, messageId,
              createTtsVoiceRuntimeMetadata('mimo', config.voice, '', 'playing', new Date().getTime()));
            this.emitSnapshot();
          }
        },
        onDone: () => {
          this.voicePcmStreamPlayback.markEnded();
        }
      });
      this.voiceTtsStreamCancel = () => {};
      if (!this.voicePlaybackGenerationActive(generation)) {
        return;
      }
      this.voicePcmStreamPlayback.markEnded();
      if (!firstChunkReceived || pcmChunks.length === 0) {
        await this.voicePcmStreamPlayback.stop();
        await this.playNonStreamingVoiceAudio(sessionId, messageId, text, generation);
        return;
      }
      audioUri = this.saveVoiceTtsPcmAudio(sessionId, messageId, pcmChunks);
      if (audioUri.length === 0) {
        await this.voicePcmStreamPlayback.stop();
        this.finishVoicePlaybackForDeletedSession(generation);
        return;
      }
      this.voicePlaybackAudioUri = audioUri;
      this.voicePlaybackVoice = config.voice;
      if (completedBeforeCacheReady) {
        this.handleVoicePlaybackCompleted(sessionId, messageId, config.voice, audioUri, generation);
        return;
      }
      this.updateMessageVoiceMetadataForSession(sessionId, messageId,
        createTtsVoiceRuntimeMetadata('mimo', config.voice, audioUri, 'playing', new Date().getTime()));
    } catch (e) {
      if (!this.voicePlaybackGenerationActive(generation)) {
        return;
      }
      let err = e as Error;
      await this.voicePcmStreamPlayback.stop();
      if (!firstChunkReceived) {
        await this.playNonStreamingVoiceAudio(sessionId, messageId, text, generation);
        return;
      }
      this.handleVoicePlaybackError(sessionId, messageId, '语音流式播放失败：' + err.message, generation);
    }
  }

  private async pauseVoicePlayback(sessionId: string, messageId: string): Promise<void> {
    let voice = this.voicePlaybackVoice.length > 0 ? this.voicePlaybackVoice : this.host.ttsConfig().voice;
    let audioUri = this.voicePlaybackAudioUri;
    await this.voiceAudioPlayback.pause();
    await this.voicePcmStreamPlayback.pause();
    this.voiceController.pauseSpeaking(messageId);
    this.updateMessageVoiceMetadataForSession(sessionId, messageId,
      createTtsVoiceRuntimeMetadata('mimo', voice, audioUri, 'paused', new Date().getTime()));
    this.emitSnapshot();
  }

  private async resumeVoicePlayback(sessionId: string, messageId: string): Promise<void> {
    let voice = this.voicePlaybackVoice.length > 0 ? this.voicePlaybackVoice : this.host.ttsConfig().voice;
    let audioUri = this.voicePlaybackAudioUri;
    await this.voiceAudioPlayback.resume();
    await this.voicePcmStreamPlayback.resume();
    this.voiceController.beginSpeaking(messageId);
    this.updateMessageVoiceMetadataForSession(sessionId, messageId,
      createTtsVoiceRuntimeMetadata('mimo', voice, audioUri, 'playing', new Date().getTime()));
    this.emitSnapshot();
  }

  private handleVoicePlaybackCompleted(sessionId: string, messageId: string, voice: string, audioUri: string,
    generation: number): void {
    if (!this.voicePlaybackGenerationActive(generation)) {
      return;
    }
    let finalAudioUri = audioUri.length > 0 ? audioUri : this.voicePlaybackAudioUri;
    this.updateMessageVoiceMetadataForSession(sessionId, messageId,
      createTtsVoiceMetadata('mimo', voice, finalAudioUri, new Date().getTime()));
    this.clearVoicePlaybackContext();
    this.voiceController.finishSpeaking();
    this.emitSnapshot();
  }

  private handleVoicePlaybackError(sessionId: string, messageId: string, message: string, generation: number): void {
    if (!this.voicePlaybackGenerationActive(generation)) {
      return;
    }
    this.updateMessageVoiceMetadataForSession(sessionId, messageId,
      createVoiceErrorMetadata('tts', 'mimo', message, new Date().getTime()));
    this.clearVoicePlaybackContext();
    this.failVoiceInteraction(message);
  }

  private async stopVoicePlayback(): Promise<void> {
    let snapshot = this.voiceController.snapshot();
    let voiceOutputActive = snapshot.status === 'speaking' || snapshot.status === 'synthesizing' ||
      snapshot.status === 'paused';
    let sessionId = this.voicePlaybackSessionId;
    let audioUri = this.voicePlaybackAudioUri;
    let voice = this.voicePlaybackVoice;
    this.voicePlaybackGeneration++;
    let cancelStream = this.voiceTtsStreamCancel;
    this.voiceTtsStreamCancel = () => {};
    cancelStream();
    await this.voiceAudioPlayback.stop();
    await this.voicePcmStreamPlayback.stop();
    if (voiceOutputActive && sessionId.length > 0 && snapshot.activeMessageId.length > 0) {
      if (audioUri.length > 0) {
        this.updateMessageVoiceMetadataForSession(sessionId, snapshot.activeMessageId,
          createTtsVoiceMetadata('mimo', voice, audioUri, new Date().getTime()));
      } else if (snapshot.status === 'synthesizing' || snapshot.status === 'speaking' || snapshot.status === 'paused') {
        this.updateMessageVoiceMetadataForSession(sessionId, snapshot.activeMessageId, undefined);
      }
    }
    this.clearVoicePlaybackContext();
    if (voiceOutputActive) {
      this.voiceController.finishSpeaking();
      this.emitSnapshot();
    }
  }
}
