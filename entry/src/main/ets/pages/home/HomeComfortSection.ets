import { window } from '@kit.ArkUI';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import { AppLogger } from '../../utils/AppLogger';
import { showToastSafely } from '../../utils/PromptSafe';
import {
  HomeComfortChatMessage,
  HomeComfortConcern
} from './HomeEmotionalSupport';

const HOME_COMFORT_CASUAL_CHAT_ID: string = 'comfort-casual-chat';

@Component
export struct HomeComfortSection {
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
  private messageSequence: number = 0;
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
      title: '和我随便聊聊，我会读心术',
      summary: '想聊什么都可以，我陪你。',
      opening: '嗨，今天想聊点什么？烦心事、无聊小事都可以，我陪你聊，也能帮你一起想办法。',
      category: 'life',
      evidence: []
    };
  }

  private nextMessageId(role: string): string {
    this.messageSequence++;
    return 'comfort-message-' + role + '-' + new Date().getTime().toString() + '-' + this.messageSequence.toString();
  }

  private openConcern(item: HomeComfortConcern): void {
    this.chatSessionToken++;
    let now = new Date().getTime();
    let opening: HomeComfortChatMessage = {
      id: this.nextMessageId('assistant'),
      role: 'assistant',
      content: item.opening,
      createdAt: now
    };
    this.selectedConcernId = item.id;
    this.chatMessages = [opening];
    this.chatInput = '';
    this.chatError = '';
    this.sending = false;
    this.chatOpen = true;
    this.scrollToLatest();
  }

  private openCasualChat(): void {
    this.openConcern(this.casualChatConcern());
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
      showToastSafely('烦恼推测生成失败：' + e.message, 1800);
    });
  }

  private scrollToLatest(): void {
    setTimeout(() => {
      this.chatScroller.scrollEdge(Edge.Bottom);
    }, 0);
  }

  private async sendMessage(): Promise<void> {
    let text = this.chatInput.trim();
    let selected = this.selectedConcerns();
    if (text.length === 0 || selected.length === 0 || this.sending) {
      return;
    }
    let userMessage: HomeComfortChatMessage = {
      id: this.nextMessageId('user'),
      role: 'user',
      content: text,
      createdAt: new Date().getTime()
    };
    let history: HomeComfortChatMessage[] = this.chatMessages.concat([userMessage]);
    let requestToken = this.chatSessionToken;
    this.chatMessages = history;
    this.chatInput = '';
    this.chatError = '';
    this.sending = true;
    this.scrollToLatest();
    try {
      let reply = await this.onSendMessage(selected[0], history);
      if (requestToken !== this.chatSessionToken) {
        return;
      }
      let assistantMessage: HomeComfortChatMessage = {
        id: this.nextMessageId('assistant'),
        role: 'assistant',
        content: reply,
        createdAt: new Date().getTime()
      };
      this.chatMessages = this.chatMessages.concat([assistantMessage]);
    } catch (e) {
      if (requestToken !== this.chatSessionToken) {
        return;
      }
      let err = e as Error;
      this.chatError = err.message.length > 0 ? err.message : '回复生成失败，请稍后再试';
      showToastSafely(this.chatError, 1800);
    } finally {
      if (requestToken === this.chatSessionToken) {
        this.sending = false;
        this.scrollToLatest();
      }
    }
  }

  @Builder ConcernRow(item: HomeComfortConcern, index: number) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Text((index + 1).toString())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.concernAccent(item.category))
      }
      .width(42)
      .height(42)
      .borderRadius(14)
      .backgroundColor(this.concernTint(item.category))

      Text(item.title)
        .fontSize(15)
        .lineHeight(21)
        .fontWeight(FontWeight.Bold)
        .fontColor('#252A3A')
        .layoutWeight(1)
        .margin({ left: 12, right: 8 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text('›')
        .fontSize(24)
        .fontColor('#9AA0AE')
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .constraintSize({ minHeight: 72 })
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(Color.White)
    .borderRadius(18)
    .border({ width: 1, color: '#ECEEF5' })
    .shadow({ radius: 12, color: '#10000000', offsetX: 0, offsetY: 5 })
    .margin({ top: 10 })
    .onClick(() => {
      this.openConcern(item);
    })
  }

  @Builder EmptyState() {
    if (this.loading) {
      Row() {
        LoadingProgress()
          .width(28)
          .height(28)
          .color('#8B6BD6')
        Text('正在听听最近的心事')
          .fontSize(13)
          .fontColor('#6F7684')
          .margin({ left: 12 })
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height(82)
      .margin({ top: 10 })
      .backgroundColor(Color.White)
      .borderRadius(18)
      .border({ width: 1, color: '#ECEEF5' })
    } else {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Text('心')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
        }
        .width(44)
        .height(44)
        .backgroundColor('#8164D5')
        .borderRadius(15)
        Text('和我随便聊聊，我会读心术')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#2E2840')
          .layoutWeight(1)
          .margin({ left: 12 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('›')
          .fontSize(24)
          .fontColor('#7658C2')
      }
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .padding({ left: 14, right: 14, top: 13, bottom: 13 })
      .margin({ top: 10 })
      .backgroundColor('#FBF9FF')
      .borderRadius(18)
      .border({ width: 1, color: '#E8E0FB' })
      .shadow({ radius: 14, color: '#12000000', offsetX: 0, offsetY: 6 })
      .onClick(() => {
        this.openCasualChat();
      })
    }
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
            .fontColor(Color.White)
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 15, right: 15, top: 11, bottom: 11 })
        .backgroundColor('#7862D3')
        .borderRadius({ topLeft: 8, topRight: 8, bottomLeft: 8, bottomRight: 8 })
        .clip(true)
        .constraintSize({ maxWidth: '78%' })
      }
      .width('100%')
    } else {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Text('心')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#7B5CC4')
        }
        .width(34)
        .height(34)
        .backgroundColor('#EEE8FF')
        .borderRadius(12)
        .alignSelf(ItemAlign.Start)

        Column() {
          Text(item.content)
            .fontSize(14)
            .lineHeight(21)
            .fontColor('#34394A')
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 15, right: 15, top: 11, bottom: 11 })
        .backgroundColor(Color.White)
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
            .fontColor('#252B3B')
            .offset({ y: -1 })
        }
        .width(42)
        .height(42)
        .backgroundColor(Color.White)
        .borderRadius(21)
        .onClick(() => {
          this.closeChat();
        })
        Text('陪你聊聊')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#171B2B')
          .layoutWeight(1)
          .margin({ left: 12 })
      }
      .width('100%')
      .height(70)
      .padding({ left: 16, right: 18 })
      .backgroundColor('#F8F6FF')

      if (item.id !== HOME_COMFORT_CASUAL_CHAT_ID) {
        Row() {
          Blank()
            .width(4)
            .height(38)
            .backgroundColor(this.concernAccent(item.category))
            .borderRadius(2)
          Column() {
            Text(item.title)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#2F3445')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(item.summary)
              .fontSize(11)
              .lineHeight(16)
              .fontColor('#777E8E')
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
        .backgroundColor(Color.White)
        .borderRadius(16)
        .border({ width: 1, color: '#ECE9F6' })
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
                .color('#8568D2')
              Text('正在认真听你说')
                .fontSize(12)
                .fontColor('#777E8E')
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
            .fontColor('#D65A68')
            .width('100%')
            .maxLines(2)
            .margin({ bottom: 7 })
        }
        Row() {
          TextInput({ placeholder: '想说什么都可以…', text: this.chatInput })
            .layoutWeight(1)
            .height(46)
            .fontSize(14)
            .fontColor('#262B3A')
            .backgroundColor('#F1F2F7')
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
            .fontColor(Color.White)
            .backgroundColor(this.chatInput.trim().length > 0 && !this.sending ? '#7862D3' : '#B9B6C8')
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
      .backgroundColor(Color.White)
      .shadow({ radius: 14, color: '#12000000', offsetX: 0, offsetY: -5 })
      .translate({ y: -this.keyboardHeightVp })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F6FF')
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
    .backgroundColor('#F8F6FF')
  }

  build() {
    Column() {
      Row() {
        Text('帮你解闷')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .layoutWeight(1)
        AiGeneratedBadge({ compact: true })
          .margin({ right: 10 })
        Button(this.loading ? '梳理中' : '重新看看')
          .height(32)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.loading ? '#A0A4B0' : '#7557BC')
          .padding({ left: 13, right: 13 })
          .backgroundColor(this.loading ? '#F0F1F5' : '#F1ECFF')
          .borderRadius(16)
          .enabled(!this.loading)
          .onClick(() => {
            this.refreshConcerns();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.concerns.length === 0) {
        this.EmptyState()
      } else {
        ForEach(this.concerns, (item: HomeComfortConcern, index: number) => {
          this.ConcernRow(item, index)
        }, (item: HomeComfortConcern) => item.id)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('92%')
    .margin({ top: 28 })
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
