import { inputMethod } from '@kit.IMEKit';
import {
  CHAT_COMPOSER_MAX_LINES,
  CHAT_MODE_CLOUD_AGENT,
  CHAT_MODE_LOCAL_INFERENCE,
  chatComposerBarHeight,
  chatComposerTextAreaHeight,
  chatComposerPrimaryActionRole,
  chatComposerVoiceReleaseShouldStop,
  chatDeepThinkingToggleVisible,
  chatModeLabel,
  chatModePlaceholder,
  chatVoiceStatusBarVisible,
  chatVoiceStatusIsCapturing,
  chatVoiceStatusDetailText,
  chatTimeGreeting
} from './ChatPageTypes';
import {
  CHAT_IMAGE_ATTACHMENT_SOURCE_ALBUM,
  CHAT_IMAGE_ATTACHMENT_SOURCE_CAMERA,
  chatAttachmentComposerExtraHeightWithImages,
  chatAttachmentPreviewHeight,
  chatCanSendMessageWithImages,
  chatCanSubmitTaskWithImages,
  chatImageAttachmentSourceLabel,
  hasChatImageAttachments,
  normalizeChatImageAttachments
} from './ChatAttachmentPolicy';
import {
  ChatMessage,
  ChatSessionSummary,
  chatMessagesAutoScrollKey,
  chatMessagesStreamFollowKey
} from './ChatSessionTypes';
import { ChatMessageList } from './ChatMessageList';
import { ChatSessionDrawer } from './ChatSessionDrawer';
import { DigitalAvatarView } from './DigitalAvatarView';
import { digitalAvatarContainerHeight, digitalAvatarVisualStateForVoiceStatus } from './DigitalAvatarTypes';
import { VoiceInteractionStatus, voiceStatusLabel } from './VoiceInteractionTypes';
import { showToastSafely } from '../../utils/PromptSafe';

@Component
export struct ChatPage {
  @Link chatMode: string;
  @Link cloudUserInput: string;
  @Link userInput: string;
  @Link chatDeepThinkingEnabled: boolean;
  @State previewImagePath: string = '';
  @State attachmentSourceMenuVisible: boolean = false;
  @Prop cloudOutput: string = '';
  @Prop cloudDebugImagePath: string = '';
  @Prop cloudThinking: boolean = false;
  @Prop localOutput: string = '';
  @Prop localDebugImagePath: string = '';
  @Prop chatHistory: string = '';
  @Prop localThinking: boolean = false;
  @Prop localChatCancelable: boolean = false;
  @Prop modelLoaded: boolean = false;
  @Prop sessions: ChatSessionSummary[] = [];
  @Prop activeSessionId: string = '';
  @Prop messages: ChatMessage[] = [];
  // 数字分身透明前景图入口：前景图来自数据层 PNG 缓存，未传入时回退到原有 H 徽标。
  @Prop avatarForegroundUri: string = '';
  @Prop avatarMessageForegroundUri: string = '';
  @Prop pendingImageAttachmentUris: string[] = [];
  @Prop sessionDrawerOpen: boolean = false;
  @Prop restoringLocalSession: boolean = false;
  @Prop pcServerConnected: boolean = false;
  @Prop pcServerCloudEnabled: boolean = false;
  @Prop voiceStatus: VoiceInteractionStatus = 'idle';
  @Prop voicePartialTranscript: string = '';
  @Prop voiceActiveMessageId: string = '';
  onSwitchMode: (mode: string) => Promise<void> = async () => {};
  onOpenSessionDrawer: () => void = () => {};
  onCloseSessionDrawer: () => void = () => {};
  onCreateSession: (mode: string) => void = () => {};
  onSelectSession: (id: string) => Promise<void> = async () => {};
  onDeleteSession: (id: string) => Promise<void> = async () => {};
  onRenameSession: (id: string, title: string) => Promise<boolean> = async () => false;
  onToggleSessionPinned: (id: string) => Promise<void> = async () => {};
  onToggleTaskTrace: (id: string) => void = () => {};
  onToggleThinking: (id: string) => void = () => {};
  onRunCloudPlanner: () => Promise<void> = async () => {};
  onCancelCloudChat: () => void = () => {};
  onCancelLocalChat: () => void = () => {};
  onSubmitCloudTask: () => Promise<void> = async () => {};
  onSendLocalMessage: () => Promise<void> = async () => {};
  onSubmitLocalTask: () => Promise<void> = async () => {};
  onTakePhotoAttachment: () => Promise<void> = async () => {};
  onPickImageAttachment: () => Promise<void> = async () => {};
  onClearImageAttachment: () => void = () => {};
  onClearCloudDebugImage: () => void = () => {};
  onClearLocalDebugImage: () => void = () => {};
  onOpenRuntimeLogs: () => void = () => {};
  onUsePcServerCloud: () => void = () => {};
  onToggleVoiceInput: () => Promise<void> = async () => {};
  onStopVoiceInput: () => Promise<void> = async () => {};
  onPlayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};
  onReplayVoiceMessage: (messageId: string, text: string) => Promise<void> = async () => {};

  private isCloudMode(): boolean {
    return this.chatMode !== CHAT_MODE_LOCAL_INFERENCE;
  }

  private activeInput(): string {
    return this.isCloudMode() ? this.cloudUserInput : this.userInput;
  }

  private composerBarHeight(): number {
    return chatComposerBarHeight(this.activeInput());
  }

  private composerTextAreaHeight(): number {
    return chatComposerTextAreaHeight(this.activeInput());
  }

  private attachmentComposerExtraHeight(): number {
    return chatAttachmentComposerExtraHeightWithImages(this.composerTextAreaHeight(), this.pendingImageAttachmentList());
  }

  private attachmentPreviewHeight(): number {
    return chatAttachmentPreviewHeight(this.composerTextAreaHeight());
  }

  private bottomOverlayInset(): number {
    return this.composerBarHeight() + this.attachmentComposerExtraHeight() + this.voiceStatusExtraHeight() + 64;
  }

  private welcomeGreeting(): string {
    return chatTimeGreeting(new Date().getHours());
  }

  private setActiveInput(value: string): void {
    if (this.isCloudMode()) {
      this.cloudUserInput = value;
      return;
    }
    this.userInput = value;
  }

  private isBusy(): boolean {
    return this.isCloudMode() ? this.cloudThinking : this.localThinking;
  }

  private isVoiceCapturing(): boolean {
    return chatVoiceStatusIsCapturing(this.voiceStatus);
  }

  private voiceStatusVisible(): boolean {
    return chatVoiceStatusBarVisible(this.voiceStatus, this.voicePartialTranscript);
  }

  private voiceStatusExtraHeight(): number {
    return this.voiceStatusVisible() ? 34 : 0;
  }

  private voiceStatusText(): string {
    return chatVoiceStatusDetailText(this.voiceStatus, this.voicePartialTranscript);
  }

  private showConversationThinkingRow(): boolean {
    // 本地流式会先插入 assistant 占位消息，已有消息时不再额外显示底部处理中行。
    if (this.isCloudMode()) {
      return this.cloudThinking;
    }
    return this.localThinking && this.messages.length === 0;
  }

  private showPcServerCloudButton(): boolean {
    return this.isCloudMode() && this.pcServerConnected;
  }

  private primaryButtonText(): string {
    if (this.isCloudMode() && this.cloudThinking) {
      return '停止';
    }
    if (!this.isCloudMode() && this.localChatCancelable) {
      return '终止';
    }
    return this.isBusy() ? '...' : '发送';
  }

  private canCancelPrimaryInference(): boolean {
    return (this.isCloudMode() && this.cloudThinking) ||
      (!this.isCloudMode() && this.localChatCancelable);
  }

  private primaryActionRole(): string {
    return chatComposerPrimaryActionRole(this.isBusy(), this.isVoiceCapturing());
  }

  private primaryButtonBackgroundColor(): string {
    if (this.primaryActionRole() === 'voice_capture') {
      return '#5968FF';
    }
    if (this.canCancelPrimaryInference()) {
      return '#D14343';
    }
    return this.isBusy() ? '#AEB7C8' : '#111827';
  }

  private startPrimaryButtonVoiceInput(): void {
    if (this.isBusy()) {
      return;
    }
    this.onToggleVoiceInput().catch((e: Error) => {
      let err = e as Error;
      showToastSafely(err.message, 1600);
    });
  }

  private stopPrimaryButtonVoiceInput(): void {
    if (!chatComposerVoiceReleaseShouldStop(this.voiceStatus)) {
      return;
    }
    this.onStopVoiceInput().catch((e: Error) => {
      let err = e as Error;
      showToastSafely(err.message, 1600);
    });
  }

  private toggleDeepThinking(): void {
    // Think 开关只影响下一次默认云端模型聊天请求；处理中保持当前请求参数不变。
    if (this.isBusy()) {
      return;
    }
    this.chatDeepThinkingEnabled = !this.chatDeepThinkingEnabled;
  }

  private hasConversationContent(): boolean {
    return this.messages.length > 0 || this.isBusy();
  }

  private hasPendingImageAttachment(): boolean {
    return hasChatImageAttachments(this.pendingImageAttachmentList());
  }

  private pendingImageAttachmentList(): string[] {
    return normalizeChatImageAttachments(this.pendingImageAttachmentUris);
  }

  private pendingImageAttachmentCount(): number {
    return this.pendingImageAttachmentList().length;
  }

  private openDebugImagePreview(path: string): void {
    if (path.length > 0) {
      this.previewImagePath = path;
    }
  }

  private closeDebugImagePreview(): void {
    this.previewImagePath = '';
  }

  private openAttachmentSourceMenu(): void {
    this.dismissChatInput();
    this.attachmentSourceMenuVisible = true;
  }

  private closeAttachmentSourceMenu(): void {
    this.attachmentSourceMenuVisible = false;
  }

  // 来源菜单只负责分发用户选择，真正的相机/相册调用仍在页面宿主中完成，避免 UI 组件持有系统能力细节。
  private async selectImageAttachmentSource(source: string): Promise<void> {
    this.closeAttachmentSourceMenu();
    if (source === CHAT_IMAGE_ATTACHMENT_SOURCE_CAMERA) {
      await this.onTakePhotoAttachment();
      return;
    }
    if (source === CHAT_IMAGE_ATTACHMENT_SOURCE_ALBUM) {
      await this.onPickImageAttachment();
    }
  }

  private activeConversationText(): string {
    if (this.isCloudMode()) {
      return this.cloudThinking ? '云端智能体正在处理...' : '';
    }
    if (!this.modelLoaded) {
      return '本地模型未加载';
    }
    return this.localThinking ? '本地模型正在生成...' : '';
  }

  private compactModeLabel(mode: string): string {
    if (mode === CHAT_MODE_LOCAL_INFERENCE) {
      return '本地';
    }
    return '云端';
  }

  @Builder ModeTopTab(mode: string) {
    Text(this.compactModeLabel(mode))
      .fontSize(12)
      .fontWeight(this.chatMode === mode ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.chatMode === mode ? Color.White : '#5D6472')
      .width(46)
      .height(28)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.chatMode === mode ? '#111827' : '#F4F6FA')
      .borderRadius(14)
      .onClick(async () => {
        await this.onSwitchMode(mode);
      })
  }

  @Builder ModeTopTabs() {
    Row() {
      this.ModeTopTab(CHAT_MODE_CLOUD_AGENT)
      Blank()
        .width(4)
      this.ModeTopTab(CHAT_MODE_LOCAL_INFERENCE)
    }
    .height(32)
    .padding({ left: 2, right: 2 })
    .backgroundColor('#F4F6FA')
    .borderRadius(16)
  }

  @Builder WelcomeActionIcon(kind: string) {
    // 欢迎态功能卡使用 ASCII 命名资源，避免在 ArkTS 中直接引用中文资源名。
    Stack({ alignContent: Alignment.Center }) {
      if (kind === 'image') {
        Image($r('app.media.chat_card_image'))
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
      } else if (kind === 'flow') {
        Image($r('app.media.chat_card_flow'))
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
      } else {
        Image($r('app.media.chat_card_search'))
          .width(22)
          .height(22)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(38)
    .height(38)
    .backgroundColor('#F2F5FF')
    .borderRadius(14)
  }

  @Builder WelcomeActionCard(kind: string, title: string, desc: string, task: string) {
    Row() {
      this.WelcomeActionIcon(kind)
      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(desc)
          .fontSize(11)
          .fontColor('#7B8392')
          .width('100%')
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
    .height(58)
    .padding({ left: 14, right: 14 })
    .backgroundColor(Color.White)
    .borderRadius(16)
    .shadow({ radius: 8, color: '#10000000', offsetX: 0, offsetY: 3 })
    .margin({ bottom: 8 })
    .onClick(() => {
      this.setActiveInput(task);
    })
  }

  @Builder WelcomeAvatarHero() {
    Row() {
      DigitalAvatarView({
        avatarForegroundUri: this.avatarForegroundUri,
        fallbackText: 'H',
        fallbackColor: '#5968FF',
        visualState: digitalAvatarVisualStateForVoiceStatus(this.voiceStatus),
        avatarSize: 'hero',
        debugSource: 'welcome-hero mode=' + this.chatMode
      })
      .margin({ left: 8 })
      Blank()
        .layoutWeight(1)
    }
    .width('100%')
    .height(this.avatarForegroundUri.length > 0 ? digitalAvatarContainerHeight('hero', true) + 8 : 118)
    .alignItems(VerticalAlign.Bottom)
    .margin({ top: 0 })
  }

  @Builder EmptyWelcome() {
    Scroll() {
      Column() {
        this.WelcomeAvatarHero()

        Text(this.welcomeGreeting())
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
          .margin({ top: 8 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text('我可以帮你整理信息、执行任务')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#6F7787')
          .width('100%')
          .margin({ top: 8 })
          .maxLines(2)
          .lineHeight(22)

        Column() {
          this.WelcomeActionCard('image', '整理今天截图里的关键信息', '从图片和聊天里提取重点', '整理今天截图里的关键信息')
          this.WelcomeActionCard('flow', '规划一个自动化 workflow', '拆解步骤并生成执行计划', '规划一个收集微信聊天记录的 workflow')
          this.WelcomeActionCard('search', '淘宝搜索耳机比价', '帮你比较价格和参数', '淘宝搜索耳机比价')
        }
        .width('100%')
        .margin({ top: 14 })

        Blank()
          .height(this.bottomOverlayInset())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder ConversationPanel() {
    if (this.messages.length > 0) {
      ChatMessageList({
        messages: this.messages,
        thinking: this.showConversationThinkingRow(),
        autoScrollKey: chatMessagesAutoScrollKey(this.activeSessionId, this.messages, this.showConversationThinkingRow()),
        streamFollowKey: chatMessagesStreamFollowKey(this.activeSessionId, this.messages, this.showConversationThinkingRow()),
        modeLabel: chatModeLabel(this.chatMode),
        modeMark: this.isCloudMode() ? '云' : '本',
        avatarForegroundUri: this.avatarForegroundUri,
        avatarMessageForegroundUri: this.avatarMessageForegroundUri,
        bottomOverlayInset: this.bottomOverlayInset(),
        onToggleTaskTrace: (id: string) => { this.onToggleTaskTrace(id); },
        onToggleThinking: (id: string) => { this.onToggleThinking(id); },
        onPreviewDebugImage: (path: string) => { this.openDebugImagePreview(path); },
        onPlayVoiceMessage: async (id: string, text: string) => { await this.onPlayVoiceMessage(id, text); },
        onReplayVoiceMessage: async (id: string, text: string) => { await this.onReplayVoiceMessage(id, text); },
        voiceActiveMessageId: this.voiceActiveMessageId,
        voiceStatus: this.voiceStatus,
        onScrollContent: (_yOffset: number) => {}
      })
    } else {
      Scroll() {
        Column() {
          Row() {
            Text(this.isCloudMode() ? '云' : '本')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
              .width(42)
              .height(42)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.isCloudMode() ? '#5968FF' : '#111827')
              .borderRadius(16)
            Column() {
              Text(chatModeLabel(this.chatMode))
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor('#111827')
              Text(this.activeConversationText())
                .fontSize(15)
                .fontColor('#1F2937')
                .lineHeight(22)
                .width('100%')
                .margin({ top: 8 })
            }
            .layoutWeight(1)
            .padding({ left: 14, right: 14, top: 14, bottom: 14 })
            .backgroundColor('#F8FAFD')
            .borderRadius(18)
            .border({ width: 1, color: '#E8ECF3' })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: 28 })

          if (this.isBusy()) {
            Text('处理中...')
              .fontSize(13)
              .fontColor('#6B7280')
              .margin({ left: 56, top: 12 })
          }

          Blank()
            .height(this.bottomOverlayInset())
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
    }
  }

  private async runPrimaryAction(): Promise<void> {
    if (this.isBusy()) {
      if (this.isCloudMode()) {
        this.onCancelCloudChat();
      } else if (this.localChatCancelable) {
        this.onCancelLocalChat();
      }
      return;
    }
    if (!chatCanSendMessageWithImages(this.activeInput(), this.pendingImageAttachmentList())) {
      return;
    }
    if (!this.isBusy()) {
      this.dismissChatInput();
    }
    if (this.isCloudMode()) {
      await this.onRunCloudPlanner();
      return;
    }
    await this.onSendLocalMessage();
  }

  private async runTaskAction(): Promise<void> {
    if (!chatCanSubmitTaskWithImages(this.pendingImageAttachmentList())) {
      showToastSafely('图片附件仅支持普通聊天发送，请先发送或清除附件', 1800);
      return;
    }
    if (this.activeInput().trim().length > 0 && !this.isBusy()) {
      this.dismissChatInput();
    }
    if (this.isCloudMode()) {
      await this.onSubmitCloudTask();
      return;
    }
    await this.onSubmitLocalTask();
  }

  private dismissChatInput(): void {
    try {
      inputMethod.getController().stopInputSession().catch(() => {});
    } catch (e) {
    }

    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
    }
  }

  @Builder PendingImageAttachmentPreview() {
    if (this.hasPendingImageAttachment()) {
      Row() {
        Scroll() {
          Row() {
            ForEach(this.pendingImageAttachmentList(), (uri: string, index?: number) => {
              Image(uri)
                .width(this.attachmentPreviewHeight() * 0.78)
                .height(this.attachmentPreviewHeight() * 0.86)
                .objectFit(ImageFit.Cover)
                .borderRadius(9)
                .backgroundColor('#F3F4F6')
                .margin({ right: 6 })
            }, (uri: string, index?: number) => uri + ':' + String(index === undefined ? 0 : index))
          }
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .height(this.attachmentPreviewHeight())
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        Column() {
          Text('图片附件 x' + String(this.pendingImageAttachmentCount()))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#111827')
            .maxLines(1)
          Text('将随下一条消息发送')
            .fontSize(10)
            .fontColor('#7B8392')
            .margin({ top: 2 })
            .maxLines(1)
        }
        .margin({ left: 10 })
        .alignItems(HorizontalAlign.Start)
        Text('×')
          .fontSize(18)
          .fontColor('#6B7280')
          .width(this.attachmentPreviewHeight() * 0.72)
          .height(this.attachmentPreviewHeight() * 0.72)
          .textAlign(TextAlign.Center)
          .backgroundColor('#F3F4F6')
          .borderRadius(this.attachmentPreviewHeight() * 0.36)
          .onClick(() => {
            this.onClearImageAttachment();
          })
      }
      .width('100%')
      .height(this.attachmentPreviewHeight())
      .alignItems(VerticalAlign.Center)
      .padding({ left: 8, right: 8 })
      .margin({ left: 22, right: 22, bottom: Math.round(this.composerTextAreaHeight() * 0.18) })
      .backgroundColor(Color.White)
      .borderRadius(18)
      .shadow({ radius: 10, color: '#12000000', offsetX: 0, offsetY: 3 })
    }
  }

  @Builder AttachmentSourceAction(source: string) {
    Column() {
      Text(chatImageAttachmentSourceLabel(source))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111827')
        .maxLines(1)
      Text(source === CHAT_IMAGE_ATTACHMENT_SOURCE_CAMERA ? '调用相机' : '选择图片')
        .fontSize(11)
        .fontColor('#7B8392')
        .margin({ top: 4 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(64)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#F8FAFD')
    .borderRadius(18)
    .border({ width: 1, color: '#E8ECF3' })
    .onClick(async () => {
      await this.selectImageAttachmentSource(source);
    })
  }

  @Builder AttachmentSourceMenuOverlay() {
    if (this.attachmentSourceMenuVisible) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
        }
          .width('100%')
          .height('100%')
          .backgroundColor('#33000000')
          .onClick(() => {
            this.closeAttachmentSourceMenu();
          })

        Column() {
          Row() {
            Text('添加附件')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#111827')
            Blank()
              .layoutWeight(1)
            Text('取消')
              .fontSize(14)
              .fontColor('#6B7280')
              .height(32)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                this.closeAttachmentSourceMenu();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row() {
            this.AttachmentSourceAction(CHAT_IMAGE_ATTACHMENT_SOURCE_CAMERA)
            Blank()
              .width(12)
            this.AttachmentSourceAction(CHAT_IMAGE_ATTACHMENT_SOURCE_ALBUM)
          }
          .width('100%')
          .margin({ top: 12 })
        }
        .width('100%')
        .padding({
          left: 20,
          right: 20,
          top: 16,
          bottom: Math.max(22, Math.round(this.bottomOverlayInset() * 0.18))
        })
        .backgroundColor(Color.White)
        .borderRadius(24)
      }
      .width('100%')
      .height('100%')
      .zIndex(70)
    }
  }

  @Builder VoiceStatusBar() {
    if (this.voiceStatusVisible()) {
      Row() {
        Text(voiceStatusLabel(this.voiceStatus))
          .fontSize(11)
          .fontColor('#5968FF')
          .maxLines(1)
        if (this.voiceStatusText().length > 0) {
          Text(this.voiceStatusText())
            .fontSize(12)
            .fontColor('#4B5563')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 8 })
        } else {
          Blank()
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height(26)
      .padding({ left: 24, right: 24 })
      .margin({ bottom: 6 })
    }
  }

  @Builder ImagePreviewOverlay() {
    if (this.previewImagePath.length > 0) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          Row() {
            Blank()
              .layoutWeight(1)
            Text('关闭')
              .fontSize(14)
              .fontColor(Color.White)
              .height(36)
              .padding({ left: 16, right: 16 })
              .backgroundColor('#33000000')
              .borderRadius(18)
              .onClick(() => {
                this.closeDebugImagePreview();
              })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 28 })

          Image(this.previewImagePath)
            .width('92%')
            .height('78%')
            .objectFit(ImageFit.Contain)
            .borderRadius(18)
            .margin({ top: 24 })
            .backgroundColor(Color.Black)

          Text('图片预览')
            .fontSize(13)
            .fontColor('#E5E7EB')
            .margin({ top: 12 })
            .maxLines(1)
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#D9000000')
      .zIndex(90)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row() {
          Text('☰')
            .fontSize(28)
            .fontColor('#111827')
            .width(44)
            .height(44)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.onOpenSessionDrawer();
            })
          Row() {
            Text('MobiAgent')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#111827')
              .maxLines(1)
              .layoutWeight(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row() {
              this.ModeTopTabs()
            }
            .margin({ left: 6 })
          }
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
          Text('日志')
            .fontSize(14)
            .fontColor('#111827')
            .width(52)
            .height(36)
            .textAlign(TextAlign.Center)
            .onClick(() => { this.onOpenRuntimeLogs(); })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 22 })

        Column() {
          if (this.hasConversationContent()) {
            this.ConversationPanel()
          } else {
            this.EmptyWelcome()
          }
        }
        .width('100%')
        .padding({ left: 28, right: 28 })
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.hasConversationContent() ? Color.White : '#F4F8FF')

      Column() {
        this.PendingImageAttachmentPreview()

        Row() {
          if (chatDeepThinkingToggleVisible(this.chatMode)) {
            Text(this.chatDeepThinkingEnabled ? '深度思考 开' : '深度思考 关')
              .fontSize(12)
              .fontColor(this.chatDeepThinkingEnabled ? '#FFFFFF' : '#222222')
              .height(34)
              .padding({ left: 13, right: 13 })
              .backgroundColor(this.chatDeepThinkingEnabled ? '#111827' : Color.White)
              .borderRadius(17)
              .border({ width: 1, color: this.chatDeepThinkingEnabled ? '#111827' : '#E2E5EA' })
              .opacity(this.isBusy() ? 0.6 : 1)
              .onClick(() => { this.toggleDeepThinking(); })
          }
          if (this.showPcServerCloudButton()) {
            Text('PC Server')
              .fontSize(12)
              .fontColor(this.pcServerCloudEnabled ? '#FFFFFF' : '#222222')
              .height(34)
              .padding({ left: 13, right: 13 })
              .backgroundColor(this.pcServerCloudEnabled ? '#167456' : Color.White)
              .borderRadius(17)
              .border({ width: 1, color: this.pcServerCloudEnabled ? '#167456' : '#E2E5EA' })
              .margin({ left: chatDeepThinkingToggleVisible(this.chatMode) ? 10 : 0 })
              .onClick(() => { this.onUsePcServerCloud(); })
          }
          Text('下发任务')
            .fontSize(12)
            .fontColor('#222222')
            .height(34)
            .padding({ left: 13, right: 13 })
            .backgroundColor(Color.White)
            .borderRadius(17)
            .border({ width: 1, color: '#E2E5EA' })
            .margin({ left: (chatDeepThinkingToggleVisible(this.chatMode) || this.showPcServerCloudButton()) ? 10 : 0 })
            .onClick(async () => { await this.runTaskAction(); })
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
        .margin({ bottom: 8 })

        this.VoiceStatusBar()

        Row() {
          Text('+')
            .fontSize(30)
            .fontColor('#111827')
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .backgroundColor(Color.White)
            .borderRadius(20)
            .shadow({ radius: 6, color: '#12000000', offsetX: 0, offsetY: 2 })
            .onClick(() => { this.openAttachmentSourceMenu(); })
          TextArea({ placeholder: chatModePlaceholder(this.chatMode), text: this.activeInput() })
            .layoutWeight(1)
            .height(this.composerTextAreaHeight())
            .maxLines(CHAT_COMPOSER_MAX_LINES)
            .fontSize(15)
            .lineHeight(20)
            .fontColor('#4B5563')
            .backgroundColor('#00FFFFFF')
            .padding({ left: 14, right: 12, top: 8, bottom: 8 })
            .margin({ left: 8 })
            .onChange((value: string) => { this.setActiveInput(value); })
          Button() {
            Row() {
              if (this.primaryActionRole() === 'voice_capture') {
                Image($r('app.media.voice_microphone_light'))
                  .width(20)
                  .height(20)
              } else if (this.primaryActionRole() === 'busy') {
                Text(this.primaryButtonText())
                  .fontSize(14)
                  .fontColor(Color.White)
                  .fontWeight(FontWeight.Bold)
              } else {
                Image($r('app.media.voice_microphone_light'))
                  .width(15)
                  .height(15)
                  .margin({ right: 5 })
                Text(this.primaryButtonText())
                  .fontSize(14)
                  .fontColor(Color.White)
                  .fontWeight(FontWeight.Bold)
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
          }
            .width(82)
            .height(40)
            .backgroundColor(this.primaryButtonBackgroundColor())
            .borderRadius(20)
            .gesture(
              GestureGroup(GestureMode.Exclusive,
                LongPressGesture({ duration: 450, repeat: false })
                  .onAction(() => { this.startPrimaryButtonVoiceInput(); })
                  .onActionEnd(() => { this.stopPrimaryButtonVoiceInput(); }),
                TapGesture()
                  .onAction(() => {
                    this.runPrimaryAction().catch((e: Error) => {
                      let err = e as Error;
                      showToastSafely(err.message, 1600);
                    });
                  })
              )
                .onCancel(() => { this.stopPrimaryButtonVoiceInput(); })
            )
        }
        .width('100%')
        .height(this.composerBarHeight())
        .alignItems(VerticalAlign.Center)
        .padding({ left: 12, right: 12 })
        .backgroundColor(Color.White)
        .borderRadius(26)
        .shadow({ radius: 14, color: '#20000000', offsetX: 0, offsetY: 5 })
        .margin({ left: 20, right: 20, bottom: 22 })
      }
      .width('100%')

      this.AttachmentSourceMenuOverlay()

      if (this.sessionDrawerOpen) {
        Row() {
          ChatSessionDrawer({
            sessions: this.sessions,
            activeSessionId: this.activeSessionId,
            restoringLocalSession: this.restoringLocalSession,
            onClose: () => { this.onCloseSessionDrawer(); },
            onCreateSession: (mode: string) => { this.onCreateSession(mode); },
            onSelectSession: async (id: string) => { await this.onSelectSession(id); },
            onDeleteSession: async (id: string) => { await this.onDeleteSession(id); },
            onRenameSession: async (id: string, title: string) => {
              return await this.onRenameSession(id, title);
            },
            onToggleSessionPinned: async (id: string) => { await this.onToggleSessionPinned(id); }
          })
          Blank()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor('#66000000')
            .onClick(() => {
              this.onCloseSessionDrawer();
            })
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Top)
      }

      this.ImagePreviewOverlay()
    }
    .width('100%')
    .height('100%')
  }
}
