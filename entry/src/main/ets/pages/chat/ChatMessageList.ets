import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  CHAT_MESSAGE_KIND_CHAT,
  CHAT_MESSAGE_KIND_CONTEXT_NOTICE,
  CHAT_MESSAGE_KIND_TASK_RESULT,
  CHAT_MESSAGE_KIND_TASK_TRACE,
  ChatMessage,
  ChatMessageKind,
  ChatMessageRole,
  chatMessageCopyContent,
  chatMessageVoiceMetadata,
  compactChatPreviewText
} from './ChatSessionTypes';
import { ChatMessageDataSource } from './ChatMessageDataSource';
import { ChatMessageDetailUiModel, ChatMessageUiModel } from './ChatMessageUiModel';
import { DigitalAvatarView } from './DigitalAvatarView';
import {
  digitalAvatarContainerWidth,
  DigitalAvatarVisualState,
  digitalAvatarVisualStateForMessageVoice,
  TEXT_AVATAR_SIZE
} from './DigitalAvatarTypes';
import {
  VoiceInteractionStatus,
  voiceReplayAvailable,
  voiceReplayGlobalBlockNeeded
} from './VoiceInteractionTypes';
import { MarkdownView, MarkdownViewVariant } from '../../components/MarkdownView';
import { markdownTitleText } from '../../utils/markdown/MarkdownParser';
import { AppLogger } from '../../utils/AppLogger';
import {
  ChatBottomOverlayKind,
  chatBottomOverlayKind,
  chatBottomSpacerIndex,
  chatLatestContentIndex,
  chatMessageListBottomSpacerHeight,
  chatStreamFollowTargetIndex,
  THINKING_OVERLAY_GAP
} from './ChatMessageScrollPolicy';

const STREAM_FOLLOW_DELAY_MS: number = 150;
const STRUCTURAL_SCROLL_FRAME_DELAY_MS: number = 16;
const STRUCTURAL_SCROLL_SETTLE_MS: number = 80;
const BACK_TO_BOTTOM_BUTTON_GAP: number = 12;
const MESSAGE_BUBBLE_WIDTH: string = '96%';
const MESSAGE_AVATAR_BUBBLE_GAP: number = 6;
const MESSAGE_ROW_TOP_MARGIN: number = 14;
const FIRST_FRAME_FULL_MARKDOWN_COUNT: number = 8;
const LIGHTWEIGHT_PREVIEW_MAX_LENGTH: number = 90;
const MESSAGE_LIST_CACHED_COUNT: number = 6;

function chatIsUserRole(role: ChatMessageRole): boolean {
  return role === 'user';
}

function chatRoleLabelFor(role: ChatMessageRole, kind: ChatMessageKind, modeLabel: string): string {
  if (role === 'user') {
    return '你';
  }
  if (kind === CHAT_MESSAGE_KIND_CONTEXT_NOTICE) {
    return '上下文';
  }
  if (kind === CHAT_MESSAGE_KIND_TASK_RESULT) {
    return '任务结果';
  }
  if (kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
    return '任务过程';
  }
  if (role === 'system') {
    return '系统';
  }
  return modeLabel.length > 0 ? modeLabel : '助手';
}

function chatResolvedMessageAvatarUri(avatarForegroundUri: string, avatarMessageForegroundUri: string): string {
  return avatarMessageForegroundUri.length > 0 ? avatarMessageForegroundUri : avatarForegroundUri;
}

function chatAvatarTextFor(role: ChatMessageRole, kind: ChatMessageKind, modeMark: string): string {
  if (role === 'user') {
    return '我';
  }
  if (kind === CHAT_MESSAGE_KIND_CONTEXT_NOTICE) {
    return '压';
  }
  if (kind === CHAT_MESSAGE_KIND_TASK_RESULT) {
    return '任';
  }
  if (kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
    return '任';
  }
  return modeMark.length > 0 ? modeMark : '助';
}

function chatAvatarColorFor(role: ChatMessageRole, kind: ChatMessageKind): string {
  if (role === 'user') {
    return '#111827';
  }
  if (kind === CHAT_MESSAGE_KIND_CONTEXT_NOTICE) {
    return '#F59E0B';
  }
  if (kind === CHAT_MESSAGE_KIND_TASK_RESULT) {
    return '#059669';
  }
  if (kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
    return '#7C3AED';
  }
  return '#5968FF';
}

function chatShouldUseDigitalAvatarFor(role: ChatMessageRole, kind: ChatMessageKind): boolean {
  return role === 'assistant' && kind === CHAT_MESSAGE_KIND_CHAT;
}

function chatAvatarColumnWidthFor(role: ChatMessageRole, kind: ChatMessageKind, avatarForegroundUri: string,
  avatarMessageForegroundUri: string): number {
  if (chatShouldUseDigitalAvatarFor(role, kind) &&
    chatResolvedMessageAvatarUri(avatarForegroundUri, avatarMessageForegroundUri).length > 0) {
    return digitalAvatarContainerWidth('message', true);
  }
  return TEXT_AVATAR_SIZE;
}

function chatBubbleColorFor(role: ChatMessageRole, kind: ChatMessageKind): string {
  if (chatIsUserRole(role)) {
    return '#111827';
  }
  if (kind === CHAT_MESSAGE_KIND_CONTEXT_NOTICE) {
    return '#FFFBEB';
  }
  if (kind === CHAT_MESSAGE_KIND_TASK_RESULT) {
    return '#ECFDF5';
  }
  if (kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
    return '#F5F3FF';
  }
  return '#F8FAFD';
}

function chatMarkdownVariantFor(role: ChatMessageRole): MarkdownViewVariant {
  return chatIsUserRole(role) ? 'chat_user' : 'chat_assistant';
}

function chatContentTextColorFor(role: ChatMessageRole): string {
  return chatIsUserRole(role) ? '#FFFFFF' : '#2F3645';
}

function chatTraceTitle(detail: ChatMessageDetailUiModel): string {
  let title = markdownTitleText(detail.content);
  if (title.length > 0) {
    return title;
  }
  return detail.content.length > 0 ? detail.content : '任务执行过程';
}

function chatLightweightPreviewText(kind: ChatMessageKind, detail: ChatMessageDetailUiModel): string {
  if (kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
    return chatTraceTitle(detail);
  }
  let preview = compactChatPreviewText(detail.content, LIGHTWEIGHT_PREVIEW_MAX_LENGTH);
  if (preview.length > 0) {
    return preview;
  }
  if (detail.imagePaths.length > 0) {
    return '图片消息';
  }
  if (detail.thinkingContent.length > 0) {
    return '思考内容';
  }
  return '历史消息';
}

function chatToolCallCount(role: ChatMessageRole, kind: ChatMessageKind, detail: ChatMessageDetailUiModel): number {
  if (role !== 'assistant' || kind === CHAT_MESSAGE_KIND_TASK_RESULT || kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
    return 0;
  }
  return detail.trace.length;
}

function chatHasVisibleContent(detail: ChatMessageDetailUiModel): boolean {
  return detail.content.trim().length > 0;
}

/**
 * 将整条气泡的可见正文写入系统剪贴板。局部 Markdown 文本仍由 Text 组件的选择菜单处理，
 * 此入口用于一次复制完整原文，避免跨 Markdown 分块时只能复制局部内容。
 */
async function copyFullChatMessage(message: ChatMessage): Promise<void> {
  let content = chatMessageCopyContent(message).trim();
  if (content.length === 0) {
    promptAction.showToast({ message: '暂无可复制内容', duration: 1200 });
    return;
  }
  try {
    let systemPasteboard = pasteboard.getSystemPasteboard();
    await systemPasteboard.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content));
    promptAction.showToast({ message: '已复制消息', duration: 1200 });
  } catch (e) {
    AppLogger.warnCause('ChatMessageList', 'copy chat message failed', e as Error);
    promptAction.showToast({ message: '复制失败', duration: 1200 });
  }
}

function chatFormatMessageTime(time: number): string {
  if (time <= 0) {
    return '';
  }
  return new Date(time).toLocaleString();
}

function chatAvatarDebugSourceFor(id: string, role: ChatMessageRole, kind: ChatMessageKind): string {
  return 'message id=' + id + ', role=' + role + ', kind=' + kind;
}

@Component
struct ChatMessageAvatarView {
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop modeMark: string = '';
  @Prop avatarForegroundUri: string = '';
  @Prop avatarMessageForegroundUri: string = '';
  @Prop visualState: DigitalAvatarVisualState = 'idle';

  build() {
    if (chatShouldUseDigitalAvatarFor(this.role, this.kind)) {
      DigitalAvatarView({
        avatarForegroundUri: chatResolvedMessageAvatarUri(this.avatarForegroundUri, this.avatarMessageForegroundUri),
        fallbackText: chatAvatarTextFor(this.role, this.kind, this.modeMark),
        fallbackColor: chatAvatarColorFor(this.role, this.kind),
        visualState: this.visualState,
        avatarSize: 'message',
        debugSource: chatAvatarDebugSourceFor(this.messageId, this.role, this.kind)
      })
    } else {
      Text(chatAvatarTextFor(this.role, this.kind, this.modeMark))
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .width(TEXT_AVATAR_SIZE)
        .height(TEXT_AVATAR_SIZE)
        .textAlign(TextAlign.Center)
        .backgroundColor(chatAvatarColorFor(this.role, this.kind))
        .borderRadius(13)
    }
  }
}

@Component
struct ChatMessageAvatarBadge {
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop modeMark: string = '';
  @Prop avatarForegroundUri: string = '';
  @Prop avatarMessageForegroundUri: string = '';
  @Prop voiceActiveMessageId: string = '';
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  onToggleTaskTrace: (id: string) => void = () => {};

  private avatarVisualState(): DigitalAvatarVisualState {
    return digitalAvatarVisualStateForMessageVoice(this.voiceStatus, this.voiceActiveMessageId, this.messageId);
  }

  @Builder AvatarContent() {
    ChatMessageAvatarView({
      messageId: this.messageId,
      role: this.role,
      kind: this.kind,
      modeMark: this.modeMark,
      avatarForegroundUri: this.avatarForegroundUri,
      avatarMessageForegroundUri: this.avatarMessageForegroundUri,
      visualState: this.avatarVisualState()
    })
  }

  build() {
    if (this.kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
      Column() {
        this.AvatarContent()
      }
      .width(chatAvatarColumnWidthFor(this.role, this.kind, this.avatarForegroundUri, this.avatarMessageForegroundUri))
      .onClick(() => {
        this.onToggleTaskTrace(this.messageId);
      })
    } else {
      Column() {
        this.AvatarContent()
      }
      .width(chatAvatarColumnWidthFor(this.role, this.kind, this.avatarForegroundUri, this.avatarMessageForegroundUri))
    }
  }
}

@Component
struct ChatMessageAvatarHeader {
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop modeMark: string = '';
  @Prop avatarForegroundUri: string = '';
  @Prop avatarMessageForegroundUri: string = '';
  @Prop voiceActiveMessageId: string = '';
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  onToggleTaskTrace: (id: string) => void = () => {};

  build() {
    Row() {
      if (chatIsUserRole(this.role)) {
        Blank()
          .layoutWeight(1)
        ChatMessageAvatarBadge({
          messageId: this.messageId,
          role: this.role,
          kind: this.kind,
          modeMark: this.modeMark,
          avatarForegroundUri: this.avatarForegroundUri,
          avatarMessageForegroundUri: this.avatarMessageForegroundUri,
          voiceActiveMessageId: this.voiceActiveMessageId,
          voiceStatus: this.voiceStatus,
          onToggleTaskTrace: this.onToggleTaskTrace
        })
      } else {
        ChatMessageAvatarBadge({
          messageId: this.messageId,
          role: this.role,
          kind: this.kind,
          modeMark: this.modeMark,
          avatarForegroundUri: this.avatarForegroundUri,
          avatarMessageForegroundUri: this.avatarMessageForegroundUri,
          voiceActiveMessageId: this.voiceActiveMessageId,
          voiceStatus: this.voiceStatus,
          onToggleTaskTrace: this.onToggleTaskTrace
        })
        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: MESSAGE_AVATAR_BUBBLE_GAP })
  }
}

@Component
struct ChatToolCallSummaryView {
  @ObjectLink detail: ChatMessageDetailUiModel;
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;

  build() {
    if (chatToolCallCount(this.role, this.kind, this.detail) > 0) {
      Text('已执行 ' + String(chatToolCallCount(this.role, this.kind, this.detail)) + ' 次工具调用')
        .fontSize(12)
        .fontColor('#9CA3AF')
        .lineHeight(18)
        .width('100%')
        .margin({ top: 6 })
    }
  }
}

@Component
struct ChatVoicePlaybackView {
  @ObjectLink detail: ChatMessageDetailUiModel;
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop activeMessageId: string = '';
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  @Prop voiceReplayGloballyBlocked: boolean = false;
  onPlayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  onReplayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};

  private visible(): boolean {
    return this.role === 'assistant' && this.kind === CHAT_MESSAGE_KIND_CHAT &&
      this.detail.content.trim().length > 0 && !this.detail.streamingActive;
  }

  private playing(): boolean {
    return this.activeMessageId.length > 0 && this.activeMessageId === this.messageId &&
      this.detail.voice.status === 'playing';
  }

  private active(): boolean {
    return this.activeMessageId.length > 0 && this.activeMessageId === this.messageId;
  }

  private synthesizing(): boolean {
    return this.active() && this.detail.voice.status === 'synthesizing';
  }

  private replayAvailable(): boolean {
    return voiceReplayAvailable(this.detail.voice.audioUri, this.voiceStatus, this.synthesizing(),
      this.voiceReplayGloballyBlocked);
  }

  private buttonBackgroundColor(): string {
    if (this.playing()) {
      return '#5968FF';
    }
    if (this.synthesizing()) {
      return '#E0E7FF';
    }
    return '#EEF2FF';
  }

  build() {
    if (this.visible()) {
      Row() {
        Button() {
          if (this.playing()) {
            Image($r('app.media.voice_pause_light'))
              .width(18)
              .height(18)
          } else {
            Image($r('app.media.voice_speaker_blue'))
              .width(18)
              .height(18)
          }
        }
          .width(30)
          .height(30)
          .backgroundColor(this.buttonBackgroundColor())
          .borderRadius(15)
          .opacity(this.synthesizing() ? 0.72 : 1)
          .onClick(async () => {
            await this.onPlayVoiceMessage(this.messageId, this.detail.content);
          })
        Button() {
          Image($r('app.media.voice_replay_blue'))
            .width(18)
            .height(18)
        }
          .width(30)
          .height(30)
          .backgroundColor('#EEF2FF')
          .borderRadius(15)
          .opacity(this.replayAvailable() ? 1 : 0.48)
          .enabled(this.replayAvailable())
          .margin({ left: 8 })
          .onClick(async () => {
            if (!this.replayAvailable()) {
              return;
            }
            await this.onReplayVoiceMessage(this.messageId, this.detail.content);
          })
      }
      .width('100%')
      .margin({ top: 8 })
    }
  }
}

@Component
struct ChatThinkingModuleView {
  @ObjectLink detail: ChatMessageDetailUiModel;
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  onToggleThinking: (id: string) => void = () => {};

  build() {
    if (this.role === 'assistant' && this.detail.thinkingContent.length > 0) {
      Column() {
        Row() {
          Text(this.detail.thinkingCollapsed ? '▶' : '▼')
            .fontSize(11)
            .fontColor('#6B7280')
            .width(20)
            .height(20)
            .textAlign(TextAlign.Center)
          Column() {
            Text('Think 思考过程')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#4B5563')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.detail.thinkingCollapsed ? '已折叠，点击查看' : '点击收起')
              .fontSize(10)
              .fontColor('#8B95A5')
              .margin({ top: 2 })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (!this.detail.thinkingCollapsed) {
          Text(this.detail.thinkingContent)
            .fontSize(12)
            .fontColor('#4B5563')
            .lineHeight(18)
            .copyOption(CopyOptions.LocalDevice)
            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
            .width('100%')
            .margin({ top: 8 })
        }
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 9, bottom: 9 })
      .margin({ top: 8 })
      .backgroundColor('#F3F4F6')
      .borderRadius(12)
      .border({ width: 1, color: '#E5E7EB' })
      .onClick(() => {
        this.onToggleThinking(this.messageId);
      })
    }
  }
}

@Component
struct ChatMarkdownContentView {
  @ObjectLink detail: ChatMessageDetailUiModel;
  @Prop role: ChatMessageRole = 'assistant';

  build() {
    if (chatHasVisibleContent(this.detail)) {
      if (this.detail.streamingActive) {
        Text(this.detail.content)
          .fontSize(15)
          .fontColor(chatContentTextColorFor(this.role))
          .lineHeight(22)
          .copyOption(CopyOptions.LocalDevice)
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
          .width('100%')
          .margin({ top: 6 })
      } else {
        MarkdownView({ text: this.detail.content, variant: chatMarkdownVariantFor(this.role) })
          .width('100%')
          .margin({ top: 6 })
      }
    }
  }
}

@Component
struct ChatMessageImagePreviewView {
  @ObjectLink detail: ChatMessageDetailUiModel;
  onPreviewDebugImage: (path: string) => void = () => {};

  build() {
    if (this.detail.imagePaths.length > 0) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.detail.imagePaths, (path: string, index?: number) => {
          Image(path)
            .width(92)
            .height(118)
            .objectFit(ImageFit.Contain)
            .backgroundColor(Color.Black)
            .borderRadius(12)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.onPreviewDebugImage(path);
            })
        }, (path: string, index?: number) => path + ':' + String(index === undefined ? 0 : index))
      }
      .width('100%')
      .margin({ top: 12 })
    }
  }
}

@Component
struct ChatBubbleView {
  @ObjectLink message: ChatMessageUiModel;
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop createdAt: number = 0;
  @Prop modeLabel: string = '';
  onToggleThinking: (id: string) => void = () => {};
  onPreviewDebugImage: (path: string) => void = () => {};
  onPlayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  onReplayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  @Prop voiceActiveMessageId: string = '';
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  @Prop voiceReplayGloballyBlocked: boolean = false;

  private canCopyFullMessage(): boolean {
    return chatHasVisibleContent(this.message.detail) && !this.message.detail.streamingActive;
  }

  private async copyFullMessage(): Promise<void> {
    await copyFullChatMessage(this.message.toChatMessage());
  }

  build() {
    Column() {
      Row() {
        Text(chatRoleLabelFor(this.role, this.kind, this.modeLabel))
          .fontSize(11)
          .fontColor(chatIsUserRole(this.role) ? '#E5E7EB' : '#6B7280')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(chatFormatMessageTime(this.createdAt))
          .fontSize(10)
          .fontColor(chatIsUserRole(this.role) ? '#D1D5DB' : '#9CA3AF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })
        Blank()
          .layoutWeight(1)
        if (this.canCopyFullMessage()) {
          Button('复制')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(chatIsUserRole(this.role) ? '#DBEAFE' : '#5968FF')
            .height(26)
            .padding({ left: 8, right: 8 })
            .backgroundColor(chatIsUserRole(this.role) ? '#273449' : '#EEF2FF')
            .border({ width: 1, color: chatIsUserRole(this.role) ? '#41516A' : '#DCE4FF' })
            .borderRadius(13)
            .margin({ left: 8 })
            .onClick(async () => {
              await this.copyFullMessage();
            })
        }
      }
      .width('100%')

      ChatToolCallSummaryView({ detail: this.message.detail, role: this.role, kind: this.kind })
      ChatThinkingModuleView({
        detail: this.message.detail,
        messageId: this.messageId,
        role: this.role,
        onToggleThinking: this.onToggleThinking
      })
      ChatMarkdownContentView({ detail: this.message.detail, role: this.role })
      ChatVoicePlaybackView({
        detail: this.message.detail,
        messageId: this.messageId,
        role: this.role,
        kind: this.kind,
        activeMessageId: this.voiceActiveMessageId,
        voiceStatus: this.voiceStatus,
        voiceReplayGloballyBlocked: this.voiceReplayGloballyBlocked,
        onPlayVoiceMessage: this.onPlayVoiceMessage,
        onReplayVoiceMessage: this.onReplayVoiceMessage
      })
      ChatMessageImagePreviewView({ detail: this.message.detail, onPreviewDebugImage: this.onPreviewDebugImage })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(chatBubbleColorFor(this.role, this.kind))
    .borderRadius(17)
    .border({
      width: chatIsUserRole(this.role) ? 0 : 1,
      color: this.kind === CHAT_MESSAGE_KIND_TASK_RESULT ? '#A7F3D0' :
        (this.kind === CHAT_MESSAGE_KIND_CONTEXT_NOTICE ? '#FDE68A' : '#E8ECF3')
    })
  }
}

@Component
struct ChatLightweightBubbleView {
  @ObjectLink detail: ChatMessageDetailUiModel;
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop createdAt: number = 0;
  @Prop modeLabel: string = '';
  onToggleTaskTrace: (id: string) => void = () => {};

  build() {
    Column() {
      Row() {
        Text(chatRoleLabelFor(this.role, this.kind, this.modeLabel))
          .fontSize(11)
          .fontColor(chatIsUserRole(this.role) ? '#E5E7EB' : '#6B7280')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(chatFormatMessageTime(this.createdAt))
          .fontSize(10)
          .fontColor(chatIsUserRole(this.role) ? '#D1D5DB' : '#9CA3AF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 8 })
      }
      .width('100%')

      Text(chatLightweightPreviewText(this.kind, this.detail))
        .fontSize(13)
        .fontColor(chatIsUserRole(this.role) ? '#F3F4F6' : '#4B5563')
        .lineHeight(20)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 })

      if (this.kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
        Text(String(this.detail.trace.length) + ' 步操作')
          .fontSize(11)
          .fontColor('#7C3AED')
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(chatBubbleColorFor(this.role, this.kind))
    .borderRadius(17)
    .border({
      width: chatIsUserRole(this.role) ? 0 : 1,
      color: this.kind === CHAT_MESSAGE_KIND_TASK_TRACE ? '#DDD6FE' :
        (this.kind === CHAT_MESSAGE_KIND_TASK_RESULT ? '#A7F3D0' :
          (this.kind === CHAT_MESSAGE_KIND_CONTEXT_NOTICE ? '#FDE68A' : '#E8ECF3'))
    })
    .onClick(() => {
      if (this.kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
        this.onToggleTaskTrace(this.messageId);
      }
    })
  }
}

@Component
struct ChatTraceBubbleView {
  @ObjectLink detail: ChatMessageDetailUiModel;
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_TASK_TRACE;
  onToggleTaskTrace: (id: string) => void = () => {};

  build() {
    Column() {
      Row() {
        Text(this.detail.collapsed ? '▶' : '▼')
          .fontSize(12)
          .fontColor('#7C3AED')
          .width(22)
          .height(22)
          .textAlign(TextAlign.Center)
        Column() {
          Text(chatTraceTitle(this.detail))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#4C1D95')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(String(this.detail.trace.length) + ' 步操作')
            .fontSize(11)
            .fontColor('#7C3AED')
            .margin({ top: 3 })
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (!this.detail.collapsed) {
        Column() {
          if (this.detail.trace.length === 0) {
            Text('暂无步骤')
              .fontSize(12)
              .fontColor('#8B5CF6')
              .width('100%')
          } else {
            ForEach(this.detail.trace, (line: string, index?: number) => {
              Row() {
                Text(String((index === undefined ? 0 : index) + 1))
                  .fontSize(10)
                  .fontColor('#8B5CF6')
                  .width(28)
                Text(line)
                  .fontSize(12)
                  .fontColor('#4B5563')
                  .lineHeight(18)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .margin({ top: 8 })
            }, (line: string, index?: number) => String(index === undefined ? 0 : index) + line)
          }
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 10 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(chatBubbleColorFor(this.role, this.kind))
    .borderRadius(17)
    .border({ width: 1, color: '#DDD6FE' })
    .onClick(() => {
      this.onToggleTaskTrace(this.messageId);
    })
  }
}

@Component
struct ChatMessageBubbleBody {
  @ObjectLink message: ChatMessageUiModel;
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop createdAt: number = 0;
  @Prop shouldRenderFull: boolean = true;
  @Prop modeLabel: string = '';
  onToggleTaskTrace: (id: string) => void = () => {};
  onToggleThinking: (id: string) => void = () => {};
  onPreviewDebugImage: (path: string) => void = () => {};
  onPlayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  onReplayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  @Prop voiceActiveMessageId: string = '';
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  @Prop voiceReplayGloballyBlocked: boolean = false;

  build() {
    if (!this.shouldRenderFull) {
      ChatLightweightBubbleView({
        detail: this.message.detail,
        messageId: this.messageId,
        role: this.role,
        kind: this.kind,
        createdAt: this.createdAt,
        modeLabel: this.modeLabel,
        onToggleTaskTrace: this.onToggleTaskTrace
      })
    } else if (this.kind === CHAT_MESSAGE_KIND_TASK_TRACE) {
      ChatTraceBubbleView({
        detail: this.message.detail,
        messageId: this.messageId,
        role: this.role,
        kind: this.kind,
        onToggleTaskTrace: this.onToggleTaskTrace
      })
    } else {
      ChatBubbleView({
        message: this.message,
        messageId: this.messageId,
        role: this.role,
        kind: this.kind,
        createdAt: this.createdAt,
        modeLabel: this.modeLabel,
        onToggleThinking: this.onToggleThinking,
        onPreviewDebugImage: this.onPreviewDebugImage,
        onPlayVoiceMessage: this.onPlayVoiceMessage,
        onReplayVoiceMessage: this.onReplayVoiceMessage,
        voiceActiveMessageId: this.voiceActiveMessageId,
        voiceStatus: this.voiceStatus,
        voiceReplayGloballyBlocked: this.voiceReplayGloballyBlocked
      })
    }
  }
}

@Component
struct ChatMessageContentBlock {
  @ObjectLink message: ChatMessageUiModel;
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop createdAt: number = 0;
  @Prop shouldRenderFull: boolean = true;
  @Prop modeLabel: string = '';
  @Prop modeMark: string = '';
  @Prop avatarForegroundUri: string = '';
  @Prop avatarMessageForegroundUri: string = '';
  onToggleTaskTrace: (id: string) => void = () => {};
  onToggleThinking: (id: string) => void = () => {};
  onPreviewDebugImage: (path: string) => void = () => {};
  onPlayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  onReplayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  @Prop voiceActiveMessageId: string = '';
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  @Prop voiceReplayGloballyBlocked: boolean = false;

  build() {
    Column() {
      ChatMessageAvatarHeader({
        messageId: this.messageId,
        role: this.role,
        kind: this.kind,
        modeMark: this.modeMark,
        avatarForegroundUri: this.avatarForegroundUri,
        avatarMessageForegroundUri: this.avatarMessageForegroundUri,
        voiceActiveMessageId: this.voiceActiveMessageId,
        voiceStatus: this.voiceStatus,
        onToggleTaskTrace: this.onToggleTaskTrace
      })
      ChatMessageBubbleBody({
        message: this.message,
        messageId: this.messageId,
        role: this.role,
        kind: this.kind,
        createdAt: this.createdAt,
        shouldRenderFull: this.shouldRenderFull,
        modeLabel: this.modeLabel,
        onToggleTaskTrace: this.onToggleTaskTrace,
        onToggleThinking: this.onToggleThinking,
        onPreviewDebugImage: this.onPreviewDebugImage,
        onPlayVoiceMessage: this.onPlayVoiceMessage,
        onReplayVoiceMessage: this.onReplayVoiceMessage,
        voiceActiveMessageId: this.voiceActiveMessageId,
        voiceStatus: this.voiceStatus,
        voiceReplayGloballyBlocked: this.voiceReplayGloballyBlocked
      })
    }
    .width(MESSAGE_BUBBLE_WIDTH)
  }
}

@Component
struct ChatMessageRow {
  @ObjectLink message: ChatMessageUiModel;
  @Prop messageId: string = '';
  @Prop role: ChatMessageRole = 'assistant';
  @Prop kind: ChatMessageKind = CHAT_MESSAGE_KIND_CHAT;
  @Prop createdAt: number = 0;
  @Prop shouldRenderFull: boolean = true;
  @Prop modeLabel: string = '';
  @Prop modeMark: string = '';
  @Prop avatarForegroundUri: string = '';
  @Prop avatarMessageForegroundUri: string = '';
  onToggleTaskTrace: (id: string) => void = () => {};
  onToggleThinking: (id: string) => void = () => {};
  onPreviewDebugImage: (path: string) => void = () => {};
  onPlayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  onReplayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  @Prop voiceActiveMessageId: string = '';
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  @Prop voiceReplayGloballyBlocked: boolean = false;

  build() {
    Row() {
      if (chatIsUserRole(this.role)) {
        Blank()
          .layoutWeight(1)
        ChatMessageContentBlock({
          message: this.message,
          messageId: this.messageId,
          role: this.role,
          kind: this.kind,
          createdAt: this.createdAt,
          shouldRenderFull: this.shouldRenderFull,
          modeLabel: this.modeLabel,
          modeMark: this.modeMark,
          avatarForegroundUri: this.avatarForegroundUri,
          avatarMessageForegroundUri: this.avatarMessageForegroundUri,
          onToggleTaskTrace: this.onToggleTaskTrace,
          onToggleThinking: this.onToggleThinking,
          onPreviewDebugImage: this.onPreviewDebugImage,
          onPlayVoiceMessage: this.onPlayVoiceMessage,
          onReplayVoiceMessage: this.onReplayVoiceMessage,
          voiceActiveMessageId: this.voiceActiveMessageId,
          voiceStatus: this.voiceStatus,
          voiceReplayGloballyBlocked: this.voiceReplayGloballyBlocked
        })
      } else {
        ChatMessageContentBlock({
          message: this.message,
          messageId: this.messageId,
          role: this.role,
          kind: this.kind,
          createdAt: this.createdAt,
          shouldRenderFull: this.shouldRenderFull,
          modeLabel: this.modeLabel,
          modeMark: this.modeMark,
          avatarForegroundUri: this.avatarForegroundUri,
          avatarMessageForegroundUri: this.avatarMessageForegroundUri,
          onToggleTaskTrace: this.onToggleTaskTrace,
          onToggleThinking: this.onToggleThinking,
          onPreviewDebugImage: this.onPreviewDebugImage,
          onPlayVoiceMessage: this.onPlayVoiceMessage,
          onReplayVoiceMessage: this.onReplayVoiceMessage,
          voiceActiveMessageId: this.voiceActiveMessageId,
          voiceStatus: this.voiceStatus,
          voiceReplayGloballyBlocked: this.voiceReplayGloballyBlocked
        })
        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: MESSAGE_ROW_TOP_MARGIN })
  }
}

@Component
export struct ChatMessageList {
  @Prop @Watch('onMessagesChanged') messages: ChatMessage[] = [];
  @Prop thinking: boolean = false;
  @Prop @Watch('onAutoScrollKeyChanged') autoScrollKey: string = '';
  @Prop @Watch('onStreamFollowKeyChanged') streamFollowKey: string = '';
  @Prop modeLabel: string = '';
  @Prop modeMark: string = '';
  @Prop avatarForegroundUri: string = '';
  @Prop avatarMessageForegroundUri: string = '';
  @Prop bottomOverlayInset: number = 122;
  @State autoFollowEnabled: boolean = true;
  @State backToBottomVisible: boolean = false;
  @State sessionFirstFrameLightweight: boolean = false;
  onToggleTaskTrace: (id: string) => void = () => {};
  onToggleThinking: (id: string) => void = () => {};
  onPreviewDebugImage: (path: string) => void = () => {};
  onPlayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  onReplayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  @Prop voiceActiveMessageId: string = '';
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  onScrollContent: (yOffset: number) => void = () => {};
  private messageScroller: Scroller = new Scroller();
  private lastAutoScrollKey: string = '';
  private lastStreamFollowKey: string = '';
  private structuralScrollTimerId: number = -1;
  private structuralSettleTimerId: number = -1;
  private streamFollowTimerId: number = -1;
  private messageDataSource: ChatMessageDataSource = new ChatMessageDataSource();

  private voiceReplayGloballyBlocked(): boolean {
    for (let i = 0; i < this.messages.length; i++) {
      let message = this.messages[i];
      if (message.id === this.voiceActiveMessageId) {
        let voice = chatMessageVoiceMetadata(message);
        return voiceReplayGlobalBlockNeeded(this.voiceStatus, this.voiceActiveMessageId, true, voice.status,
          voice.audioUri);
      }
    }
    return voiceReplayGlobalBlockNeeded(this.voiceStatus, this.voiceActiveMessageId, false, 'none', '');
  }

  aboutToAppear(): void {
    this.syncMessageDataSource();
    this.scheduleScrollToLatest(true);
  }

  aboutToDisappear(): void {
    this.clearScrollTimers();
  }

  private onAutoScrollKeyChanged(): void {
    this.scheduleScrollToLatest(false);
  }

  private onMessagesChanged(): void {
    this.syncMessageDataSource();
  }

  private onStreamFollowKeyChanged(): void {
    if (this.streamFollowKey === this.lastStreamFollowKey) {
      return;
    }
    this.lastStreamFollowKey = this.streamFollowKey;
    if (this.sessionFirstFrameLightweight) {
      this.logScrollDebug('stream-follow-skipped-first-frame');
      return;
    }
    if (!this.autoFollowEnabled) {
      this.markPendingBottomContent('stream-follow-deferred');
      return;
    }
    this.scheduleStreamFollow();
  }

  private clearStructuralScrollTimers(): void {
    if (this.structuralScrollTimerId !== -1) {
      clearTimeout(this.structuralScrollTimerId);
      this.structuralScrollTimerId = -1;
    }
    if (this.structuralSettleTimerId !== -1) {
      clearTimeout(this.structuralSettleTimerId);
      this.structuralSettleTimerId = -1;
    }
  }

  private clearStreamFollowTimer(): void {
    if (this.streamFollowTimerId !== -1) {
      clearTimeout(this.streamFollowTimerId);
      this.streamFollowTimerId = -1;
    }
  }

  private clearScrollTimers(): void {
    this.clearStructuralScrollTimers();
    this.clearStreamFollowTimer();
  }

  private syncMessageDataSource(): void {
    this.messageDataSource.setMessages(this.messages);
  }

  private sessionPart(scrollKey: string): string {
    let delimiterIndex = scrollKey.indexOf(':');
    if (delimiterIndex < 0) {
      return scrollKey;
    }
    return scrollKey.substring(0, delimiterIndex);
  }

  private isSessionScopeChanged(previousKey: string, nextKey: string): boolean {
    if (previousKey.length === 0 || nextKey.length === 0) {
      return false;
    }
    return this.sessionPart(previousKey) !== this.sessionPart(nextKey);
  }

  private logScroll(message: string): void {
    AppLogger.info('Chat.Scroll', message + ' autoFollow=' + String(this.autoFollowEnabled) +
      ', showBackButton=' + String(this.backToBottomVisible) +
      ', autoKeyLength=' + String(this.autoScrollKey.length) +
      ', streamKeyLength=' + String(this.streamFollowKey.length));
  }

  private logScrollDebug(message: string): void {
    AppLogger.debug('Chat.Scroll', message + ' autoFollow=' + String(this.autoFollowEnabled) +
      ', showBackButton=' + String(this.backToBottomVisible) +
      ', autoKeyLength=' + String(this.autoScrollKey.length) +
      ', streamKeyLength=' + String(this.streamFollowKey.length));
  }

  private markPendingBottomContent(reason: string): void {
    this.backToBottomVisible = true;
    this.logScroll(reason);
  }

  private scheduleScrollToLatest(force: boolean): void {
    if (!force && this.autoScrollKey === this.lastAutoScrollKey) {
      return;
    }
    let previousKey = this.lastAutoScrollKey;
    this.lastAutoScrollKey = this.autoScrollKey;
    let sessionChanged = this.isSessionScopeChanged(previousKey, this.autoScrollKey);
    if (force || sessionChanged) {
      this.autoFollowEnabled = true;
      this.backToBottomVisible = false;
    }
    if ((force || sessionChanged) && this.messages.length > FIRST_FRAME_FULL_MARKDOWN_COUNT) {
      this.startSessionFirstFrame();
    } else if (force || sessionChanged) {
      this.sessionFirstFrameLightweight = false;
    }
    if (!this.autoFollowEnabled) {
      this.markPendingBottomContent('structural-scroll-deferred');
      return;
    }
    this.clearStructuralScrollTimers();
    this.logScroll(force ? 'structural-scroll-initial' : 'structural-scroll');
    // 消息气泡中有 Markdown/图片等异步布局，保留一次延迟兜底，但先取消旧任务避免流式更新堆积。
    this.structuralScrollTimerId = setTimeout(() => {
      this.structuralScrollTimerId = -1;
      this.scrollToLatestContentIndex('structural-scroll');
    }, STRUCTURAL_SCROLL_FRAME_DELAY_MS);
    this.structuralSettleTimerId = setTimeout(() => {
      this.structuralSettleTimerId = -1;
      this.scrollToBottomEdge('structural-scroll-settle');
      this.completeSessionFirstFrame('structural-scroll-settle');
    }, STRUCTURAL_SCROLL_SETTLE_MS);
  }

  private scheduleStreamFollow(): void {
    if (this.streamFollowTimerId !== -1) {
      return;
    }
    this.streamFollowTimerId = setTimeout(() => {
      this.streamFollowTimerId = -1;
      this.followStreamingContent();
    }, STREAM_FOLLOW_DELAY_MS);
  }

  private scrollToBottomEdge(reason: string): void {
    if (!this.autoFollowEnabled) {
      this.markPendingBottomContent(reason + '-blocked');
      return;
    }
    try {
      this.messageScroller.scrollEdge(Edge.Bottom);
      this.backToBottomVisible = false;
      this.logScroll(reason + '-edge');
    } catch (e) {
      AppLogger.warnCause('Chat.Scroll', reason + ' failed', e as Error);
    }
  }

  private latestContentIndex(): number {
    return chatLatestContentIndex(this.messages.length);
  }

  private bottomSpacerIndex(): number {
    return chatBottomSpacerIndex(this.messages.length);
  }

  private streamFollowTargetIndex(): number {
    return chatStreamFollowTargetIndex(this.messages.length);
  }

  private scrollToLatestContentIndex(reason: string): void {
    if (!this.autoFollowEnabled) {
      this.markPendingBottomContent(reason + '-blocked');
      return;
    }
    let lastIndex = this.latestContentIndex();
    if (lastIndex < 0) {
      this.scrollToBottomEdge(reason + '-empty');
      return;
    }
    try {
      this.messageScroller.scrollToIndex(lastIndex, false, ScrollAlign.END);
      this.backToBottomVisible = false;
      this.logScroll(reason + '-index');
    } catch (e) {
      AppLogger.warnCause('Chat.Scroll', reason + ' index failed', e as Error);
      this.scrollToBottomEdge(reason + '-index-fallback');
    }
  }

  private followStreamingContent(): void {
    if (!this.autoFollowEnabled) {
      this.markPendingBottomContent('stream-follow-skipped');
      return;
    }
    try {
      this.messageScroller.scrollToIndex(this.streamFollowTargetIndex(), false, ScrollAlign.END);
      this.logScrollDebug('stream-follow');
    } catch (e) {
      AppLogger.warnCause('Chat.Scroll', 'stream-follow failed', e as Error);
      this.scrollToBottomEdge('stream-follow-fallback');
    }
  }

  private isUserScrollSource(scrollSource: ScrollSource): boolean {
    return scrollSource === ScrollSource.DRAG || scrollSource === ScrollSource.OTHER_USER_INPUT ||
      scrollSource === ScrollSource.SCROLL_BAR || scrollSource === ScrollSource.FLING ||
      scrollSource === ScrollSource.SCROLL_BAR_FLING;
  }

  private onScrollWillMove(scrollOffset: number, _scrollState: ScrollState, scrollSource: ScrollSource): void {
    this.onScrollContent(scrollOffset);
    if (this.autoFollowEnabled && this.isUserScrollSource(scrollSource) && Math.abs(scrollOffset) > 0.5) {
      this.completeSessionFirstFrame('user-scroll');
      this.autoFollowEnabled = false;
      this.backToBottomVisible = true;
      this.clearScrollTimers();
      this.logScroll('auto-follow-paused');
    }
  }

  private onReachBottom(): void {
    if (!this.autoFollowEnabled || this.backToBottomVisible) {
      this.autoFollowEnabled = true;
      this.backToBottomVisible = false;
      this.logScroll('reach-end');
    }
  }

  private handleBackToBottom(): void {
    this.autoFollowEnabled = true;
    this.backToBottomVisible = false;
    this.clearScrollTimers();
    this.completeSessionFirstFrame('back-to-bottom');
    this.scrollToBottomEdge('back-to-bottom');
  }

  private startSessionFirstFrame(): void {
    // 切换会话时先只完整渲染最近消息，避免历史 Markdown 拖慢首帧。
    this.sessionFirstFrameLightweight = true;
  }

  private completeSessionFirstFrame(reason: string): void {
    if (!this.sessionFirstFrameLightweight) {
      return;
    }
    this.sessionFirstFrameLightweight = false;
    this.logScrollDebug(reason + '-restore-full-render');
  }

  private shouldRenderFullMessage(index: number): boolean {
    if (!this.sessionFirstFrameLightweight) {
      return true;
    }
    return index >= Math.max(0, this.messages.length - FIRST_FRAME_FULL_MARKDOWN_COUNT);
  }

  private backToBottomButtonBottomOffset(): number {
    return this.bottomOverlayInset + BACK_TO_BOTTOM_BUTTON_GAP;
  }

  private thinkingOverlayBottomOffset(): number {
    return this.bottomOverlayInset + THINKING_OVERLAY_GAP;
  }

  private messageListBottomSpacerHeight(): number {
    return chatMessageListBottomSpacerHeight(this.bottomOverlayInset, this.thinking);
  }

  private bottomOverlayKind(): ChatBottomOverlayKind {
    return chatBottomOverlayKind(this.thinking, this.backToBottomVisible);
  }

  private messageAvatarForegroundUri(): string {
    return this.avatarMessageForegroundUri.length > 0 ? this.avatarMessageForegroundUri : this.avatarForegroundUri;
  }

  private thinkingAvatarColumnWidth(): number {
    if (this.messageAvatarForegroundUri().length > 0) {
      return digitalAvatarContainerWidth('message', true);
    }
    return TEXT_AVATAR_SIZE;
  }

  private thinkingAvatarDebugSource(): string {
    return 'thinking-row modeMark=' + (this.modeMark.length > 0 ? this.modeMark : '助');
  }

  @Builder ThinkingAvatar() {
    DigitalAvatarView({
      avatarForegroundUri: this.messageAvatarForegroundUri(),
      fallbackText: this.modeMark.length > 0 ? this.modeMark : '助',
      fallbackColor: '#5968FF',
      visualState: 'thinking',
      avatarSize: 'message',
      debugSource: this.thinkingAvatarDebugSource()
    })
  }

  @Builder BackToBottomButton() {
    Text('↓ 回到底部')
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(Color.White)
      .height(34)
      .padding({ left: 14, right: 14 })
      .backgroundColor('#111827')
      .borderRadius(17)
      .shadow({ radius: 10, color: '#24000000', offsetX: 0, offsetY: 3 })
      .margin({ right: 4, bottom: this.backToBottomButtonBottomOffset() })
      .onClick(() => {
        this.handleBackToBottom();
      })
  }

  @Builder ThinkingRow() {
    Row() {
      Column() {
        this.ThinkingAvatar()
      }
      .width(this.thinkingAvatarColumnWidth())
      .margin({ right: 10 })
      Text('处理中...')
        .fontSize(13)
        .fontColor('#6B7280')
        .height(36)
        .padding({ left: 14, right: 14 })
        .backgroundColor('#F8FAFD')
        .borderRadius(18)
        .border({ width: 1, color: '#E8ECF3' })
      Blank()
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder ThinkingOverlay() {
    Row() {
      this.ThinkingRow()
    }
    .width('100%')
    .margin({ bottom: this.thinkingOverlayBottomOffset() })
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      List({ scroller: this.messageScroller }) {
        LazyForEach(this.messageDataSource, (message: ChatMessageUiModel, index: number) => {
          ListItem() {
            ChatMessageRow({
              message: message,
              messageId: message.id,
              role: message.role,
              kind: message.kind,
              createdAt: message.createdAt,
              shouldRenderFull: this.shouldRenderFullMessage(index),
              modeLabel: this.modeLabel,
              modeMark: this.modeMark,
              avatarForegroundUri: this.avatarForegroundUri,
              avatarMessageForegroundUri: this.avatarMessageForegroundUri,
              onToggleTaskTrace: this.onToggleTaskTrace,
              onToggleThinking: this.onToggleThinking,
              onPreviewDebugImage: this.onPreviewDebugImage,
              onPlayVoiceMessage: this.onPlayVoiceMessage,
              onReplayVoiceMessage: this.onReplayVoiceMessage,
              voiceActiveMessageId: this.voiceActiveMessageId,
              voiceStatus: this.voiceStatus,
              voiceReplayGloballyBlocked: this.voiceReplayGloballyBlocked()
            })
          }
          .selectable(false)
        }, (message: ChatMessageUiModel, _index: number) => this.messageDataSource.keyFor(message))

        ListItem() {
          Column() {
            Blank()
              .height(this.messageListBottomSpacerHeight())
          }
          .width('100%')
        }
        .selectable(false)
      }
      .onWillScroll((scrollOffset: number, scrollState: ScrollState, scrollSource: ScrollSource) => {
        this.onScrollWillMove(scrollOffset, scrollState, scrollSource);
      })
      .onReachEnd(() => {
        this.onReachBottom();
      })
      .cachedCount(MESSAGE_LIST_CACHED_COUNT)
      .height('100%')
      .width('100%')
      if (this.bottomOverlayKind() === 'back_to_bottom') {
        this.BackToBottomButton()
      }
      if (this.bottomOverlayKind() === 'thinking') {
        this.ThinkingOverlay()
      }
    }
    .layoutWeight(1)
    .width('100%')
  }
}
