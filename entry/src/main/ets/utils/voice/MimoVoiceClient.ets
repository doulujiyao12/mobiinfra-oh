import { PrivacyConsent } from '../PrivacyConsent';
import { AiServiceAccess, AI_LOGIN_REQUIRED_MESSAGE } from '../AiServiceAccess';
import { http } from '@kit.NetworkKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { parseJsonCompat } from '../JsonCompat';
import { decodeUtf8Compat } from '../TextEncodingCompat';
import { normalizeVoiceTtsPreset } from './VoiceTtsPresets';

export type MimoAudioFormat = 'wav' | 'pcm16';
export type MimoAsrAudioFormat = 'wav' | 'mp3';
export type MimoAsrLanguage = 'auto' | 'zh' | 'en';

export interface MimoVoiceMessage {
  role: string;
  content: string;
}

export interface MimoTtsAudioOptions {
  format: MimoAudioFormat;
  voice: string;
}

export interface MimoTtsRequest {
  model: string;
  messages: MimoVoiceMessage[];
  audio: MimoTtsAudioOptions;
  stream: boolean;
}

export interface MimoTtsBuildOptions {
  model: string;
  voice: string;
  format: MimoAudioFormat;
  stylePrompt?: string;
  stream?: boolean;
}

// MiMO V2.5 TTS 流式请求入参。目标文本固定放 assistant message，user message 仅用于可选风格控制。
export interface MimoTtsStreamBuildOptions {
  model?: string;
  voice?: string;
  selectedVoice?: string;
  stylePrompt?: string;
}

export interface MimoAsrInputAudio {
  data: string;
}

export interface MimoAsrContentPart {
  type: string;
  input_audio: MimoAsrInputAudio;
}

export interface MimoAsrMessage {
  role: string;
  content: MimoAsrContentPart[];
}

export interface MimoAsrOptions {
  language: MimoAsrLanguage;
}

export interface MimoAsrRequest {
  model: string;
  messages: MimoAsrMessage[];
  asr_options: MimoAsrOptions;
  stream: boolean;
}

export interface MimoVoiceConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
  voice: string;
  stylePrompt?: string;
  readTimeoutMs?: number;
}

export interface MimoTtsSynthesisResult {
  audioBase64: string;
  model: string;
  voice: string;
  format: MimoAudioFormat;
}

// 单个 SSE data 行解析结果；audioBase64 为空表示本行没有可播放音频增量。
export interface MimoTtsStreamDelta {
  audioBase64: string;
  done: boolean;
}

// 流式合成回调。PCM chunk 为 MiMO 文档约定的 24kHz PCM16LE mono 裸音频片段。
export interface MimoTtsStreamCallbacks {
  onPcmChunk?: (chunk: Uint8Array) => void;
  onDone?: () => void;
  onRequest?: (control: MimoTtsStreamRequestControl) => void;
}

export interface MimoTtsStreamRequestControl {
  cancel: () => void;
}

export interface MimoTtsStreamResult {
  model: string;
  voice: string;
  format: 'pcm16';
  chunkCount: number;
  byteLength: number;
}

export interface MimoTtsStreamConfig extends MimoVoiceConfig {
  stylePrompt?: string;
}

interface MimoTtsAudioResponse {
  data?: string;
}

interface MimoTtsMessageResponse {
  role?: string;
  content?: string | null;
  audio?: MimoTtsAudioResponse | null;
}

interface MimoTtsChoice {
  message?: MimoTtsMessageResponse;
}

interface MimoTtsResponse {
  choices?: MimoTtsChoice[];
}

interface MimoTtsStreamAudio {
  data?: string | null;
}

interface MimoTtsStreamDeltaPayload {
  audio?: MimoTtsStreamAudio | null;
}

interface MimoTtsStreamChoice {
  delta?: MimoTtsStreamDeltaPayload | null;
}

interface MimoTtsStreamResponse {
  choices?: MimoTtsStreamChoice[];
}

interface MimoAsrMessageResponse {
  role?: string;
  content?: string | null;
}

interface MimoAsrChoice {
  message?: MimoAsrMessageResponse;
}

interface MimoAsrOpenAiResponse {
  choices?: MimoAsrChoice[];
}

interface MimoTextContentPart {
  type?: string;
  text?: string;
}

interface MimoAsrContentResponse {
  content?: MimoTextContentPart[];
  role?: string;
}

export class MimoVoiceClient {
  private static readonly DEFAULT_TTS_MODEL: string = 'mimo-v2.5-tts';

  static buildTtsRequest(text: string, options: MimoTtsBuildOptions): MimoTtsRequest {
    let messages: MimoVoiceMessage[] = [];
    if (options.stylePrompt !== undefined && options.stylePrompt.trim().length > 0) {
      messages.push({
        role: 'user',
        content: options.stylePrompt.trim()
      });
    }
    messages.push({
      role: 'assistant',
      content: text
    });
    return {
      model: options.model,
      messages: messages,
      audio: {
        format: options.format,
        voice: normalizeVoiceTtsPreset(options.voice)
      },
      stream: options.stream === true
    };
  }

  static buildStreamingTtsRequest(text: string, options: MimoTtsStreamBuildOptions): MimoTtsRequest {
    let selectedVoice = 'mimo_default';
    if (options.selectedVoice !== undefined && options.selectedVoice.trim().length > 0) {
      selectedVoice = options.selectedVoice.trim();
    } else if (options.voice !== undefined && options.voice.trim().length > 0) {
      selectedVoice = options.voice.trim();
    }
    let model = MimoVoiceClient.DEFAULT_TTS_MODEL;
    if (options.model !== undefined && options.model.trim().length > 0) {
      model = options.model.trim();
    }
    return MimoVoiceClient.buildTtsRequest(text, {
      model: model,
      voice: selectedVoice,
      format: 'pcm16',
      stylePrompt: options.stylePrompt,
      stream: true
    });
  }

  static buildAsrRequest(audioBase64: string, format: MimoAsrAudioFormat, language: MimoAsrLanguage,
    stream: boolean): MimoAsrRequest {
    let mimeType = format === 'mp3' ? 'audio/mpeg' : 'audio/wav';
    return {
      model: 'mimo-v2.5-asr',
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'input_audio',
              input_audio: {
                data: 'data:' + mimeType + ';base64,' + audioBase64
              }
            }
          ]
        }
      ],
      asr_options: {
        language: language
      },
      stream: stream
    };
  }

  static parseTtsAudioBase64(payload: string): string {
    let parsed = parseJsonCompat<MimoTtsResponse>(payload);
    let choices = parsed.choices === undefined ? [] : parsed.choices;
    if (choices.length === 0 || choices[0].message === undefined || choices[0].message?.audio === undefined ||
      choices[0].message?.audio === null) {
      throw new Error('MiMO TTS response has no audio data');
    }
    let audio = choices[0].message?.audio;
    let data = audio === undefined || audio.data === undefined ? '' : audio.data.trim();
    if (data.length === 0) {
      throw new Error('MiMO TTS response audio data is empty');
    }
    return data;
  }

  static parseTtsStreamDeltaLine(line: string): MimoTtsStreamDelta {
    let emptyDelta: MimoTtsStreamDelta = {
      audioBase64: '',
      done: false
    };
    let trimmed = line.trim();
    if (trimmed.length === 0 || !trimmed.startsWith('data:')) {
      return emptyDelta;
    }
    let payload = trimmed.substring(5).trim();
    if (payload === '[DONE]') {
      return {
        audioBase64: '',
        done: true
      };
    }
    let parsed: MimoTtsStreamResponse;
    try {
      parsed = parseJsonCompat<MimoTtsStreamResponse>(payload);
    } catch (e) {
      let err = e as Error;
      throw new Error('MiMO TTS stream JSON parse failed: ' + err.message);
    }
    let choices = parsed.choices === undefined ? [] : parsed.choices;
    if (choices.length === 0) {
      return emptyDelta;
    }
    let delta = choices[0].delta;
    if (delta === undefined || delta === null || delta.audio === undefined || delta.audio === null) {
      return emptyDelta;
    }
    let audioData = delta.audio.data;
    return {
      audioBase64: typeof audioData === 'string' ? audioData.trim() : '',
      done: false
    };
  }

  static parseTtsStreamDeltaEvent(lines: string[]): MimoTtsStreamDelta {
    let dataParts: string[] = [];
    for (let index = 0; index < lines.length; index++) {
      let trimmed = lines[index].trim();
      if (trimmed.startsWith('data:')) {
        dataParts.push(trimmed.substring(5).trim());
      }
    }
    if (dataParts.length === 0) {
      return {
        audioBase64: '',
        done: false
      };
    }
    return MimoVoiceClient.parseTtsStreamDeltaLine('data: ' + dataParts.join('\n'));
  }

  static parseAsrTranscript(payload: string): string {
    try {
      let parsed = parseJsonCompat<MimoAsrOpenAiResponse>(payload);
      let choices = parsed.choices === undefined ? [] : parsed.choices;
      if (choices.length > 0 && choices[0].message !== undefined &&
        typeof choices[0].message?.content === 'string') {
        return (choices[0].message?.content as string).trim();
      }
    } catch (e) {
    }
    let contentParsed = parseJsonCompat<MimoAsrContentResponse>(payload);
    let content = contentParsed.content === undefined ? [] : contentParsed.content;
    for (let i = 0; i < content.length; i++) {
      let part = content[i];
      let text = part.text;
      if (part.type === 'text' && text !== undefined) {
        return text.trim();
      }
    }
    return '';
  }

  static normalizeChatUrl(baseUrl: string): string {
    let url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) {
      return url;
    }
    if (url.endsWith('/v1')) {
      return url + '/chat/completions';
    }
    return url + '/v1/chat/completions';
  }

  async synthesizeSpeech(text: string, config: MimoVoiceConfig): Promise<MimoTtsSynthesisResult> {
    AiServiceAccess.requireAllowed();
    let requestBody = MimoVoiceClient.buildTtsRequest(text, {
      model: config.model,
      voice: config.voice,
      format: 'wav',
      stylePrompt: config.stylePrompt,
      stream: false
    });
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'api-key': config.apiKey.length > 0 ? config.apiKey : 'EMPTY',
      'Authorization': 'Bearer ' + (config.apiKey.length > 0 ? config.apiKey : 'EMPTY')
    };
    let requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: ArkJSON.stringify(requestBody),
      connectTimeout: 10000,
      readTimeout: config.readTimeoutMs === undefined ? 120000 : config.readTimeoutMs,
      expectDataType: http.HttpDataType.STRING
    };
    let httpReq = PrivacyConsent.createHttp();
    try {
      let response = await httpReq.request(MimoVoiceClient.normalizeChatUrl(config.baseUrl), requestOptions);
      AiServiceAccess.requireAllowed();
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('MiMO TTS HTTP ' + String(response.responseCode) + ': ' + String(response.result));
      }
      return {
        audioBase64: MimoVoiceClient.parseTtsAudioBase64(response.result as string),
        model: config.model,
        voice: requestBody.audio.voice,
        format: 'wav'
      };
    } finally {
      PrivacyConsent.destroyHttp(httpReq);
    }
  }

  async synthesizeSpeechStream(text: string, config: MimoTtsStreamConfig,
    callbacks: MimoTtsStreamCallbacks = {}): Promise<MimoTtsStreamResult> {
    AiServiceAccess.requireAllowed();
    let requestBody = MimoVoiceClient.buildStreamingTtsRequest(text, {
      model: config.model,
      selectedVoice: config.voice,
      stylePrompt: config.stylePrompt
    });
    let headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'api-key': config.apiKey.length > 0 ? config.apiKey : 'EMPTY',
      'Authorization': 'Bearer ' + (config.apiKey.length > 0 ? config.apiKey : 'EMPTY')
    };
    let requestOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: ArkJSON.stringify(requestBody),
      connectTimeout: 10000,
      readTimeout: config.readTimeoutMs === undefined ? 120000 : config.readTimeoutMs
    };
    let httpReq = PrivacyConsent.createHttp();
    return new Promise<MimoTtsStreamResult>((resolve, reject) => {
      let resolved = false;
      let responseCode = -1;
      let finishResultPending = false;
      let textBuffer = '';
      let eventLines: string[] = [];
      let chunkCount = 0;
      let byteLength = 0;
      let textDecoder = util.TextDecoder.create('utf-8');
      let base64Helper = new util.Base64Helper();

      let cleanup = (): void => {
        httpReq.off('dataReceive');
        httpReq.off('dataEnd');
        try {
          PrivacyConsent.destroyHttp(httpReq);
        } catch (e) {
        }
      };
      let finishWithError = (message: string): void => {
        if (resolved) {
          return;
        }
        resolved = true;
        cleanup();
        reject(new Error(message));
      };
      PrivacyConsent.onHttpCancel(httpReq, () => { finishWithError('隐私授权已撤回'); });
      callbacks.onRequest?.({
        cancel: () => { finishWithError('MiMO TTS stream cancelled'); }
      });
      let finishWithResult = (): void => {
        if (resolved) {
          return;
        }
        if (!AiServiceAccess.isAllowed()) {
          finishWithError(AI_LOGIN_REQUIRED_MESSAGE);
          return;
        }
        if (responseCode < 0) {
          finishResultPending = true;
          return;
        }
        resolved = true;
        cleanup();
        if (callbacks.onDone !== undefined) {
          callbacks.onDone();
        }
        resolve({
          model: requestBody.model,
          voice: requestBody.audio.voice,
          format: 'pcm16',
          chunkCount: chunkCount,
          byteLength: byteLength
        });
      };
      let decodeStreamData = (data: ArrayBuffer): string => {
        try {
          return textDecoder.decodeWithStream(new Uint8Array(data));
        } catch (e) {
          return decodeUtf8Compat(new Uint8Array(data));
        }
      };
      let processStreamEvent = (lines: string[]): void => {
        if (resolved) {
          return;
        }
        if (!AiServiceAccess.isAllowed()) {
          finishWithError(AI_LOGIN_REQUIRED_MESSAGE);
          return;
        }
        try {
          let delta = MimoVoiceClient.parseTtsStreamDeltaEvent(lines);
          if (delta.done) {
            finishWithResult();
            return;
          }
          if (delta.audioBase64.length === 0) {
            return;
          }
          let chunk = MimoVoiceClient.exactUint8Array(base64Helper.decodeSync(delta.audioBase64));
          chunkCount++;
          byteLength += chunk.byteLength;
          if (callbacks.onPcmChunk !== undefined) {
            callbacks.onPcmChunk(chunk);
          }
        } catch (e) {
          let err = e as Error;
          finishWithError(err.message);
        }
      };
      let processStreamLine = (line: string): void => {
        if (resolved) {
          return;
        }
        if (line.trim().length === 0) {
          if (eventLines.length > 0) {
            let lines = eventLines.slice();
            eventLines = [];
            processStreamEvent(lines);
          }
          return;
        }
        if (line.trim().startsWith('data:')) {
          eventLines.push(line);
        }
      };
      let processBufferedText = (flushRemaining: boolean): void => {
        while (!resolved) {
          let newlineIndex = textBuffer.indexOf('\n');
          if (newlineIndex < 0) {
            break;
          }
          let line = textBuffer.substring(0, newlineIndex);
          textBuffer = textBuffer.substring(newlineIndex + 1);
          processStreamLine(line);
        }
        if (flushRemaining && !resolved && textBuffer.trim().length > 0) {
          let line = textBuffer;
          textBuffer = '';
          processStreamLine(line);
        }
        if (flushRemaining && !resolved && eventLines.length > 0) {
          let lines = eventLines.slice();
          eventLines = [];
          processStreamEvent(lines);
        }
      };

      httpReq.on('dataReceive', (data: ArrayBuffer) => {
        if (resolved) {
          return;
        }
        textBuffer += decodeStreamData(data);
        processBufferedText(false);
      });
      httpReq.on('dataEnd', () => {
        processBufferedText(true);
        finishWithResult();
      });
      httpReq.requestInStream(MimoVoiceClient.normalizeChatUrl(config.baseUrl), requestOptions).then((code: number) => {
        responseCode = code;
        if (code < 200 || code >= 300) {
          finishWithError('MiMO TTS HTTP ' + String(code));
          return;
        }
        if (finishResultPending) {
          finishWithResult();
        }
      }).catch((e: Error) => {
        finishWithError(e.message);
      });
    });
  }

  private static exactUint8Array(bytes: Uint8Array): Uint8Array {
    if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) {
      return bytes;
    }
    let exact = new Uint8Array(bytes.byteLength);
    for (let index = 0; index < bytes.byteLength; index++) {
      exact[index] = bytes[index];
    }
    return exact;
  }
}
