import { AppTheme } from '../../utils/AppTheme';
import {
  CHAT_MODE_CLOUD_AGENT,
  CHAT_MODE_LOCAL_INFERENCE,
  chatModeLabel
} from './ChatPageTypes';
import { ChatSessionSummary, chatSessionRenderKey } from './ChatSessionTypes';
import { showToastSafely } from '../../utils/PromptSafe';

@Component
export struct ChatSessionDrawer {
  @State renameOverlayVisible: boolean = false;
  @State renameSessionId: string = '';
  @State renameDraftTitle: string = '';
  @State actionMenuVisible: boolean = false;
  @State actionMenuSessionId: string = '';
  @State actionMenuSessionTitle: string = '';
  @State actionMenuSessionPinned: boolean = false;
  @Prop sessions: ChatSessionSummary[] = [];
  @Prop activeSessionId: string = '';
  @Prop restoringLocalSession: boolean = false;
  onClose: () => void = () => {};
  onCreateSession: (mode: string) => void = () => {};
  onSelectSession: (id: string) => Promise<void> = async () => {};
  onDeleteSession: (id: string) => Promise<void> = async () => {};
  onRenameSession: (id: string, title: string) => Promise<boolean> = async () => false;
  onToggleSessionPinned: (id: string) => Promise<void> = async () => {};

  private renameMaxLength(): number {
    return 40;
  }

  private sessionCount(mode: string): number {
    let count = 0;
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].mode === mode) {
        count++;
      }
    }
    return count;
  }

  private formatSessionTime(time: number): string {
    if (time <= 0) {
      return '未知时间';
    }
    return new Date(time).toLocaleString();
  }

  private normalizedRenameTitle(): string {
    let title = this.renameDraftTitle.trim();
    return title.length > this.renameMaxLength() ? title.substring(0, this.renameMaxLength()) : title;
  }

  private openRenameOverlayByValue(sessionId: string, title: string): void {
    this.renameSessionId = sessionId;
    this.renameDraftTitle = title;
    this.renameOverlayVisible = true;
  }

  private closeRenameOverlay(): void {
    this.renameOverlayVisible = false;
    this.renameSessionId = '';
    this.renameDraftTitle = '';
  }

  private async saveRenameOverlay(): Promise<void> {
    let title = this.normalizedRenameTitle();
    if (title.length === 0) {
      showToastSafely('名称不能为空', 1400);
      return;
    }
    let saved = await this.onRenameSession(this.renameSessionId, title);
    if (saved) {
      this.closeRenameOverlay();
    }
  }

  private openSessionActionMenu(session: ChatSessionSummary): void {
    // 长按菜单只承载管理操作；普通点击仍由卡片 onClick 负责切换会话。
    this.actionMenuSessionId = session.id;
    this.actionMenuSessionTitle = session.title;
    this.actionMenuSessionPinned = session.pinned === true;
    this.actionMenuVisible = true;
  }

  private closeSessionActionMenu(): void {
    this.actionMenuVisible = false;
    this.actionMenuSessionId = '';
    this.actionMenuSessionTitle = '';
    this.actionMenuSessionPinned = false;
  }

  private async toggleActionMenuPinned(): Promise<void> {
    let sessionId = this.actionMenuSessionId;
    this.closeSessionActionMenu();
    await this.onToggleSessionPinned(sessionId);
  }

  private renameActionMenuSession(): void {
    let sessionId = this.actionMenuSessionId;
    let title = this.actionMenuSessionTitle;
    this.closeSessionActionMenu();
    this.openRenameOverlayByValue(sessionId, title);
  }

  private async deleteActionMenuSession(): Promise<void> {
    let sessionId = this.actionMenuSessionId;
    this.closeSessionActionMenu();
    await this.onDeleteSession(sessionId);
  }

  @Builder NewSessionButton(mode: string) {
    Text('+ ' + chatModeLabel(mode))
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(AppTheme.text('#111827'))
      .height(36)
      .padding({ left: 12, right: 12 })
      .backgroundColor(AppTheme.background('#F4F6FA'))
      .borderRadius(18)
      .border({ width: 1, color: AppTheme.border('#E7EAF0') })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onCreateSession(mode);
      })
  }

  @Builder SessionItem(session: ChatSessionSummary) {
    Row() {
      Column() {
        Row() {
          Text(session.mode === CHAT_MODE_LOCAL_INFERENCE ? '本' : '云')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.text(Color.White))
            .width(26)
            .height(26)
            .textAlign(TextAlign.Center)
            .backgroundColor(AppTheme.filledBackground(session.mode === CHAT_MODE_LOCAL_INFERENCE ? '#111827' : '#5968FF'))
            .borderRadius(9)
          Text(session.title)
            .fontSize(15)
            .fontWeight(this.activeSessionId === session.id ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(AppTheme.text('#111827'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 10 })
          if (session.pinned === true) {
            Text('置顶')
              .fontSize(10)
              .fontColor(AppTheme.text('#5968FF'))
              .height(20)
              .padding({ left: 6, right: 6 })
              .backgroundColor(AppTheme.background('#EEF2FF'))
              .borderRadius(10)
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(session.lastMessagePreview)
          .fontSize(12)
          .fontColor(AppTheme.text('#6B7280'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })

        Text(String(session.messageCount) + ' 条消息 · ' + this.formatSessionTime(session.updatedAt))
          .fontSize(11)
          .fontColor(AppTheme.text('#9CA3AF'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(AppTheme.background(this.activeSessionId === session.id ? '#EEF2FF' : Color.White))
    .borderRadius(16)
    .border({ width: 1, color: AppTheme.border(this.activeSessionId === session.id ? '#C7D2FE' : '#EDF0F5') })
    .margin({ bottom: 10 })
    .onClick(async () => {
      await this.onSelectSession(session.id);
    })
    .gesture(LongPressGesture({ fingers: 1, repeat: false, duration: 500 }).onAction(() => {
      this.openSessionActionMenu(session);
    }))
  }

  @Builder SessionSection(mode: string) {
    Column() {
      Row() {
        Text(chatModeLabel(mode))
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppTheme.text('#374151'))
        Text(String(this.sessionCount(mode)))
          .fontSize(11)
          .fontColor(AppTheme.text('#6B7280'))
          .height(22)
          .padding({ left: 8, right: 8 })
          .backgroundColor(AppTheme.background('#F3F4F6'))
          .borderRadius(11)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 10 })

      ForEach(this.sessions, (session: ChatSessionSummary) => {
        if (session.mode === mode) {
          this.SessionItem(session)
        }
      }, (session: ChatSessionSummary) => chatSessionRenderKey(session))

      if (this.sessionCount(mode) === 0) {
        Text('暂无' + chatModeLabel(mode) + '会话')
          .fontSize(12)
          .fontColor(AppTheme.text('#9CA3AF'))
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 16 })
      }
    }
    .width('100%')
    .margin({ top: 18 })
  }

  @Builder SessionActionMenuOverlay() {
    if (this.actionMenuVisible) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          Text(this.actionMenuSessionTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.text('#111827'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: 10 })
          Text(this.actionMenuSessionPinned ? '取消置顶' : '置顶')
            .fontSize(15)
            .fontColor(AppTheme.text('#111827'))
            .width('100%')
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor(AppTheme.background('#F7F9FC'))
            .borderRadius(12)
            .onClick(async () => {
              await this.toggleActionMenuPinned();
            })
          Text('重命名')
            .fontSize(15)
            .fontColor(AppTheme.text('#111827'))
            .width('100%')
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor(AppTheme.background('#F7F9FC'))
            .borderRadius(12)
            .margin({ top: 8 })
            .onClick(() => {
              this.renameActionMenuSession();
            })
          Text('删除')
            .fontSize(15)
            .fontColor(AppTheme.text('#EF4444'))
            .width('100%')
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor(AppTheme.background('#FFF1F2'))
            .borderRadius(12)
            .margin({ top: 8 })
            .onClick(async () => {
              await this.deleteActionMenuSession();
            })
          Text('取消')
            .fontSize(14)
            .fontColor(AppTheme.text('#4B5563'))
            .width('100%')
            .height(38)
            .textAlign(TextAlign.Center)
            .backgroundColor(AppTheme.background('#F3F4F6'))
            .borderRadius(12)
            .margin({ top: 12 })
            .onClick(() => {
              this.closeSessionActionMenu();
            })
        }
        .width('84%')
        .padding(16)
        .backgroundColor(AppTheme.background(Color.White))
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppTheme.background('#66000000'))
      .zIndex(35)
    }
  }

  @Builder RenameOverlay() {
    if (this.renameOverlayVisible) {
      Stack({ alignContent: Alignment.Center }) {
        Column() {
          Text('重命名会话')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.text('#111827'))
            .width('100%')
          TextInput({ placeholder: '请输入会话名称', text: this.renameDraftTitle })
            .placeholderColor($r('app.color.ui_text_placeholder'))
            .caretColor($r('app.color.ui_accent_blue'))
            .width('100%')
            .height(42)
            .fontSize(14)
            .fontColor(AppTheme.text('#111827'))
            .backgroundColor(AppTheme.inputBackground())
            .borderRadius(12)
            .padding({ left: 12, right: 12 })
            .maxLength(this.renameMaxLength())
            .margin({ top: 16 })
            .onChange((value: string) => {
              this.renameDraftTitle = value;
            })
          Row() {
            Text('取消')
              .fontSize(14)
              .fontColor(AppTheme.text('#4B5563'))
              .height(38)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .backgroundColor(AppTheme.background('#F3F4F6'))
              .borderRadius(12)
              .onClick(() => {
                this.closeRenameOverlay();
              })
            Text('保存')
              .fontSize(14)
              .fontColor(AppTheme.text(Color.White))
              .height(38)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .backgroundColor(AppTheme.filledBackground('#111827'))
              .borderRadius(12)
              .margin({ left: 10 })
              .onClick(async () => {
                await this.saveRenameOverlay();
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('86%')
        .padding(16)
        .backgroundColor(AppTheme.background(Color.White))
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppTheme.background('#66000000'))
      .zIndex(40)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row() {
          Column() {
            Text('历史会话')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.text('#111827'))
            Text(this.restoringLocalSession ? '正在恢复本地上下文' : '选择会话后由上层恢复上下文')
              .fontSize(12)
              .fontColor(AppTheme.text(this.restoringLocalSession ? '#5968FF' : '#6B7280'))
              .margin({ top: 4 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('×')
            .fontSize(24)
            .fontColor(AppTheme.text('#4B5563'))
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .backgroundColor(AppTheme.background('#F4F6FA'))
            .borderRadius(20)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Flex({ wrap: FlexWrap.Wrap }) {
          this.NewSessionButton(CHAT_MODE_CLOUD_AGENT)
          this.NewSessionButton(CHAT_MODE_LOCAL_INFERENCE)
        }
        .width('100%')
        .margin({ top: 18 })

        Scroll() {
          Column() {
            this.SessionSection(CHAT_MODE_CLOUD_AGENT)
            this.SessionSection(CHAT_MODE_LOCAL_INFERENCE)
            Blank()
              .height(28)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .margin({ top: 4 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 18, right: 18, top: 26, bottom: 20 })

      this.SessionActionMenuOverlay()
      this.RenameOverlay()
    }
    .width(320)
    .height('100%')
    .backgroundColor(AppTheme.background('#FFFFFF'))
    .shadow({ radius: 20, color: AppTheme.shadow('#26000000'), offsetX: 5, offsetY: 0 })
  }
}
