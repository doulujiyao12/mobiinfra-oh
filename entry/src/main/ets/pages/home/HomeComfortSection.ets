import { AppTheme } from '../../utils/AppTheme';
import { window } from '@kit.ArkUI';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import { AiLoginGuard } from '../../components/AiLoginGuard';
import { AppLogger } from '../../utils/AppLogger';
import { showToastSafely } from '../../utils/PromptSafe';
import { HomeComfortChatStore } from './HomeComfortChatStore';
import { HomeCategoryIcon } from '../../components/HomeCategoryIcon';
import {
  HomeComfortChatMessage,
  HomeComfortConcern
} from './HomeEmotionalSupport';

const HOME_COMFORT_CASUAL_CHAT_ID: string = 'comfort-casual-chat';

export interface SecretaryChatInvitation { sequence: number; concernId: string; }

@Component
export struct HomeComfortSection {
  @ObjectLink @Watch('onChatSessionsChanged') chatStore: HomeComfortChatStore;
  @Prop @Watch('openInvitation') invitation: SecretaryChatInvitation = { sequence: 0, concernId: '' };
  @Prop expanded: boolean = false;
  @Prop concerns: HomeComfortConcern[] = [];
  @Prop loading: boolean = false;
  @Prop errorMessage: string = '';
  onRefresh: () => Promise<void> = async () => {};
  onSendMessage: (concern: HomeComfortConcern, history: HomeComfortChatMessage[]) => Promise<string> =
    async (concern: HomeComfortConcern, history: HomeComfortChatMessage[]): Promise<string> => '';

  @State private chatOpen: boolean = false;
  @State private selectedConcernId: string = '';
  @State private chatInput: string = '';
  @State private chatMessages: HomeComfortChatMessage[] = [];
  @State private sending: boolean = false;
  @State private chatError: string = '';
  @State private keyboardHeightVp: number = 0;
  private chatSessionToken: number = 0;
  private chatScroller: Scroller = new Scroller();
  private keyboardWindow: window.Window | null = null;
  private keyboardHeightChangeCallback: ((height: number) => void) | null = null;

  private concernAccent(category: string): string {
    if (category === 'work') {
      return '#6C72E8';
    }
    if (category === 'relationship') {
      return '#E46F9D';
    }
    if (category === 'money') {
      return '#D18A35';
    }
    if (category === 'health') {
      return '#39A58C';
    }
    if (category === 'study') {
      return '#4F8FD8';
    }
    return '#8B6BD6';
  }

  private concernTint(category: string): string {
    if (category === 'work') {
      return '#EEF0FF';
    }
    if (category === 'relationship') {
      return '#FFF0F5';
    }
    if (category === 'money') {
      return '#FFF5E7';
    }
    if (category === 'health') {
      return '#EAF9F5';
    }
    if (category === 'study') {
      return '#EBF5FF';
    }
    return '#F3EEFF';
  }

  private concernIconIndex(category: string): number {
    if (category === 'work') {
      return 5;
    }
    if (category === 'relationship') {
      return 9;
    }
    if (category === 'money') {
      return 1;
    }
    if (category === 'health') {
      return 10;
    }
    if (category === 'study') {
      return 11;
    }
    return 6;
  }

  @Builder CategoryIcon(index: number, size: number) {
    HomeCategoryIcon({ iconIndex: index, iconSize: size })
  }

  private selectedConcerns(): HomeComfortConcern[] {
    if (this.selectedConcernId.length === 0) {
      return [];
    }
    if (this.selectedConcernId === HOME_COMFORT_CASUAL_CHAT_ID) {
      return [this.casualChatConcern()];
    }
    return this.concerns.filter((item: HomeComfortConcern): boolean =>
      item.id === this.selectedConcernId).slice(0, 1);
  }

  private casualChatConcern(): HomeComfortConcern {
    return {
      id: HOME_COMFORT_CASUAL_CHAT_ID,
      title: '和小C随便聊聊',
      summary: '想聊什么都可以，我陪你。',
      opening: '我在呢。今天有什么想跟我说的吗？',
      category: 'life',
      evidence: []
    };
  }

  private openConcern(item: HomeComfortConcern): void {
    if (!AiLoginGuard.ensure(this.getUIContext())) {
      return;
    }
    this.chatSessionToken++;
    this.chatStore.open(item);
    this.selectedConcernId = item.id;
    this.chatInput = '';
    this.chatOpen = true;
    this.onChatSessionsChanged();
  }

  private onChatSessionsChanged(): void {
    if (!this.chatOpen) {
      return;
    }
    let session = this.chatStore.get(this.selectedConcernId);
    if (!session) {
      this.closeChat();
      this.selectedConcernId = '';
      this.chatMessages = [];
      return;
    }
    this.chatMessages = session.messages;
    this.sending = session.sending;
    this.chatError = session.error;
    this.scrollToLatest();
  }

  private restartChat(): void {
    let selected = this.selectedConcerns();
    if (selected.length === 0) {
      return;
    }
    this.chatStore.restart(selected[0]);
    this.chatInput = '';
    this.onChatSessionsChanged();
  }

  aboutToDisappear(): void {
    this.stopKeyboardTracking();
  }

  private openCasualChat(): void {
    this.openConcern(this.casualChatConcern());
  }

  private openInvitation(): void {
    if (!this.invitation.sequence) { return; }
    const concern = this.concerns.find((item: HomeComfortConcern): boolean => item.id === this.invitation.concernId);
    if (concern) { this.openConcern(concern); } else { this.openCasualChat(); }
  }

  private closeChat(): void {
    this.chatSessionToken++;
    this.chatOpen = false;
    this.chatInput = '';
    this.chatError = '';
    this.sending = false;
    this.getUIContext().getFocusController().clearFocus();
  }

  private startKeyboardTracking(): void {
    if (this.keyboardWindow !== null || this.keyboardHeightChangeCallback !== null) {
      return;
    }
    let hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      return;
    }
    let sessionToken = this.chatSessionToken;
    window.getLastWindow(hostContext).then((mainWindow: window.Window): void => {
      if (!this.chatOpen || sessionToken !== this.chatSessionToken || this.keyboardWindow !== null) {
        return;
      }
      let callback = (height: number): void => {
        this.keyboardHeightVp = Math.max(0, px2vp(height));
        if (height > 0) {
          this.scrollToLatest();
        }
      };
      mainWindow.on('keyboardHeightChange', callback);
      this.keyboardWindow = mainWindow;
      this.keyboardHeightChangeCallback = callback;
    }).catch((e: Error): void => {
      AppLogger.warn('HomeComfort', 'Failed to observe keyboard height. Cause: ' + e.message);
      this.keyboardHeightVp = 0;
    });
  }

  private stopKeyboardTracking(): void {
    let mainWindow = this.keyboardWindow;
    let callback = this.keyboardHeightChangeCallback;
    this.keyboardWindow = null;
    this.keyboardHeightChangeCallback = null;
    this.keyboardHeightVp = 0;
    if (mainWindow === null || callback === null) {
      return;
    }
    try {
      mainWindow.off('keyboardHeightChange', callback);
    } catch (e) {
      let error = e as Error;
      AppLogger.warn('HomeComfort', 'Failed to stop observing keyboard height. Cause: ' + error.message);
    }
  }

  private refreshConcerns(): void {
    if (this.loading) {
      return;
    }
    this.onRefresh().catch((e: Error) => {
      showToastSafely('聊天话题生成失败：' + e.message, 1800);
    });
  }

  private scrollToLatest(): void {
    setTimeout(() => {
      this.chatScroller.scrollEdge(Edge.Bottom);
    }, 0);
  }

  private sendMessage(): void {
    let text = this.chatInput.trim();
    let selected = this.selectedConcerns();
    if (text.length === 0 || selected.length === 0 || this.sending) {
      return;
    }
    if (!AiLoginGuard.ensure(this.getUIContext())) {
      return;
    }
    this.chatInput = '';
    this.chatStore.send(selected[0], text, this.onSendMessage);
    this.onChatSessionsChanged();
  }

  @Builder ConcernRow(item: HomeComfortConcern) {
    Row({ space: 9 }) {
      this.CategoryIcon(this.concernIconIndex(item.category), 32)
      Text(item.title).fontSize(15).lineHeight(21).fontColor($r('app.color.ui_text_primary'))
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([$r('app.color.ui_text_muted')])
    }.width('100%').constraintSize({ minHeight: 46 }).padding({ top: 4, bottom: 4 })
      .accessibilityGroup(true).accessibilityText('和小C聊聊，' + item.title)
      .onClick((): void => { this.openConcern(item); })
  }

  @Builder Topics() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text('想聊点什么？').fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_text_primary'))
        if (this.concerns.length > 0) { AiGeneratedBadge({ compact: true }) }
        Blank()
        Button({ type: ButtonType.Normal }) {
          if (this.loading) {
            LoadingProgress().width(16).height(16).color($r('app.color.ui_accent_purple'))
          } else {
            Text('换个话题').fontSize(13).fontColor($r('app.color.ui_accent_purple'))
          }
        }.height(40).padding({ left: 5, right: 5 }).backgroundColor(Color.Transparent)
          .enabled(!this.loading).accessibilityText('刷新聊天话题').onClick((): void => { this.refreshConcerns(); })
      }.width('100%')
      ForEach(this.concerns, (item: HomeComfortConcern) => {
        this.ConcernRow(item)
      }, (item: HomeComfortConcern): string => item.id)
      if (this.errorMessage && !this.loading) {
        Text(this.errorMessage).fontSize(13).fontColor($r('app.color.ui_text_secondary'))
      }
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.message')).fontSize(16).fontColor([$r('app.color.ui_accent_purple')])
          Text('随便聊聊').fontSize(14).fontColor($r('app.color.ui_accent_purple'))
        }
      }.height(40).padding({ left: 3, right: 8 }).backgroundColor(Color.Transparent)
        .onClick((): void => { this.openCasualChat(); })
    }.width('100%').padding({ left: 14, right: 12, top: 6, bottom: 6 })
      .alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.ui_soft_purple'))
      .borderRadius({ topLeft: 20, topRight: 5, bottomLeft: 20, bottomRight: 20 })
      .margin({ bottom: 8 })
  }

  @Builder ChatMessageBubble(item: HomeComfortChatMessage) {
    if (item.role === 'user') {
      Row() {
        Blank()
          .layoutWeight(1)
        Column() {
          Text(item.content)
            .fontSize(14)
            .lineHeight(21)
            .fontColor(AppTheme.text(Color.White))
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 15, right: 15, top: 11, bottom: 11 })
        .backgroundColor(AppTheme.background('#7862D3'))
        .borderRadius({ topLeft: 8, topRight: 8, bottomLeft: 8, bottomRight: 8 })
        .clip(true)
        .constraintSize({ maxWidth: '78%' })
      }
      .width('100%')
    } else {
      Row() {
        Image($r('app.media.clawmate_secretary')).width(34).height(34).objectFit(ImageFit.Cover)
          .backgroundColor($r('app.color.ui_soft_purple')).borderRadius(17).alignSelf(ItemAlign.Start)
          .draggable(false).accessibilityText('小C')

        Column() {
          Text(item.content)
            .fontSize(14)
            .lineHeight(21)
            .fontColor(AppTheme.text('#34394A'))
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 15, right: 15, top: 11, bottom: 11 })
        .backgroundColor(AppTheme.background(Color.White))
        .borderRadius({ topLeft: 8, topRight: 8, bottomLeft: 8, bottomRight: 8 })
        .clip(true)
        .constraintSize({ maxWidth: '76%' })
        .margin({ left: 9 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
  }

  @Builder ChatPage(item: HomeComfortConcern) {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Text('‹')
            .fontSize(30)
            .fontColor(AppTheme.text('#252B3B'))
            .offset({ y: -1 })
        }
        .width(42)
        .height(42)
        .backgroundColor(AppTheme.background(Color.White))
        .borderRadius(21)
        .onClick(() => {
          this.closeChat();
        })
        Text('和小C聊聊')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text('#171B2B'))
          .layoutWeight(1)
          .margin({ left: 12 })
        Button('重头开聊')
          .height(32)
          .fontSize(12)
          .fontColor(AppTheme.text('#7557BC'))
          .backgroundColor(AppTheme.background('#F1ECFF'))
          .padding({ left: 13, right: 13 })
          .borderRadius(16)
          .margin({ left: 8 })
          .onClick(() => {
            this.restartChat();
          })
      }
      .width('100%')
      .height(70)
      .padding({ left: 16, right: 18 })
      .backgroundColor(AppTheme.background('#F8F6FF'))

      if (item.id !== HOME_COMFORT_CASUAL_CHAT_ID) {
        Row() {
          Blank()
            .width(4)
            .height(38)
            .backgroundColor(AppTheme.background(this.concernAccent(item.category)))
            .borderRadius(2)
          Column() {
            Text(item.title)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.text('#2F3445'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(item.summary)
              .fontSize(11)
              .lineHeight(16)
              .fontColor(AppTheme.text('#777E8E'))
              .margin({ top: 4 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 10 })
        }
        .alignItems(VerticalAlign.Center)
        .width('92%')
        .padding({ left: 14, right: 14, top: 11, bottom: 11 })
        .backgroundColor(AppTheme.background(Color.White))
        .borderRadius(16)
        .border({ width: 1, color: AppTheme.border('#ECE9F6') })
        .margin({ top: 6, bottom: 8 })
      }

      List({ scroller: this.chatScroller, space: 14 }) {
        ForEach(this.chatMessages, (message: HomeComfortChatMessage) => {
          ListItem() {
            this.ChatMessageBubble(message)
          }
        }, (message: HomeComfortChatMessage) => message.id)
        if (this.sending) {
          ListItem() {
            Row() {
              LoadingProgress()
                .width(20)
                .height(20)
                .color(AppTheme.text('#8568D2'))
              Text('正在认真听你说')
                .fontSize(12)
                .fontColor(AppTheme.text('#777E8E'))
                .margin({ left: 9 })
            }
            .padding({ left: 44, top: 4, bottom: 4 })
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 18, right: 18, bottom: this.keyboardHeightVp })
      .edgeEffect(EdgeEffect.Spring)

      Column() {
        if (this.chatError.length > 0) {
          Text(this.chatError)
            .fontSize(11)
            .fontColor(AppTheme.text('#D65A68'))
            .width('100%')
            .maxLines(2)
            .margin({ bottom: 7 })
        }
        Row() {
          TextInput({ placeholder: '想说什么都可以…', text: this.chatInput })
            .placeholderColor($r('app.color.ui_text_placeholder'))
            .caretColor($r('app.color.ui_accent_blue'))
            .layoutWeight(1)
            .height(46)
            .fontSize(14)
            .fontColor(AppTheme.text('#262B3A'))
            .backgroundColor(AppTheme.inputBackground())
            .borderRadius(16)
            .padding({ left: 14, right: 14 })
            .maxLength(500)
            .enabled(!this.sending)
            .onChange((value: string) => {
              this.chatInput = value;
            })
          Button(this.sending ? '…' : '发送')
            .width(68)
            .height(46)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.text(Color.White))
            .backgroundColor(AppTheme.filledBackground(this.chatInput.trim().length > 0 && !this.sending ? '#7862D3' : '#B9B6C8'))
            .borderRadius(16)
            .enabled(this.chatInput.trim().length > 0 && !this.sending)
            .margin({ left: 10 })
            .onClick(() => {
              this.sendMessage();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 10, bottom: 10 })
      .backgroundColor(AppTheme.background(Color.White))
      .shadow({ radius: 14, color: AppTheme.shadow('#12000000'), offsetX: 0, offsetY: -5 })
      .translate({ y: -this.keyboardHeightVp })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.background('#F8F6FF'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder ChatCover() {
    Stack() {
      ForEach(this.selectedConcerns(), (item: HomeComfortConcern) => {
        this.ChatPage(item)
      }, (item: HomeComfortConcern) => item.id)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.background('#F8F6FF'))
  }

  build() {
    // Keep the chat cover and invitation watcher mounted when the inline topics are folded.
    Column() {
      if (this.expanded) { this.Topics() }
    }
    .width('92%').constraintSize({ maxWidth: 840 })
    .bindContentCover($$this.chatOpen, this.ChatCover(), {
      modalTransition: ModalTransition.DEFAULT,
      enableSafeArea: true,
      onAppear: () => {
        this.startKeyboardTracking();
      },
      onDisappear: () => {
        this.stopKeyboardTracking();
      }
    })
  }
}
