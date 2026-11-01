import { APP_HEADER_HEIGHT } from '../../components/AppHeader';
import { AppTheme } from '../../utils/AppTheme';
import { CodexTaskSummary, CodexWorkspace, codexStatusLabel } from './CodexTypes';

@Component
export struct CodexWorkspaceHeader {
  @Prop serverName: string = '';
  @Prop workspaceName: string = '';
  @Prop connectionStatus: string = '正在确认连接';
  onHistory: () => void = () => {};
  onSettings: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.codex_history')).width(24).height(24).fillColor(AppTheme.text('#172033'))
      }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
      .accessibilityText('打开历史对话').onClick(() => { this.onHistory(); })
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text('Codex').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
          Text('· ' + this.serverName).fontSize(13).fontColor(AppTheme.text('#747B87'))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.width('100%')
        Row({ space: 8 }) {
          Text(this.workspaceName).fontSize(11).fontColor(AppTheme.text('#747B87')).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('● ' + this.connectionStatus).fontSize(11)
            .fontColor(AppTheme.text(this.connectionStatus === '已连接' ? '#21855A' : '#AD6500')).maxLines(1)
        }.width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button({ type: ButtonType.Circle }) {
        Image($r('app.media.codex_settings')).width(23).height(23).fillColor(AppTheme.text('#172033'))
      }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
      .accessibilityText('对话设置').onClick(() => { this.onSettings(); })
    }.width('100%').height(APP_HEADER_HEIGHT).padding({ left: 10, right: 10 })
  }
}

@Component
export struct CodexHistoryDrawer {
  @Prop tasks: CodexTaskSummary[] = [];
  @Prop workspaces: CodexWorkspace[] = [];
  @Prop selectedId: string = '';
  @Prop serverName: string = '';
  @Prop busy: boolean = false;
  @Prop notice: string = '';
  @Prop bottomInset: number = 0;
  @Prop scope: string = 'phone';
  @Prop supportsComputerHistory: boolean = false;
  @Prop loading: boolean = false;
  @Prop hasMore: boolean = false;
  onClose: () => void = () => {};
  onNewTask: () => void = () => {};
  onSelect: (id: string) => void = () => {};
  onConnections: () => void = () => {};
  onScope: (scope: string) => void = () => {};
  onRefresh: () => void = () => {};
  onMore: () => void = () => {};

  private caption(item: CodexTaskSummary): string {
    const name = this.workspaces.find((workspace: CodexWorkspace) => workspace.id === item.workspaceId)?.name || '';
    return (name ? name + ' · ' : '') + codexStatusLabel(item.status);
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row().width('100%').height('100%').backgroundColor('#59000000').onClick(() => { this.onClose(); })
      Column({ space: 18 }) {
        Row() {
          Text('历史对话').fontSize(22).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).layoutWeight(1)
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.codex_close')).width(20).height(20).fillColor(AppTheme.text('#747B87'))
          }.width(40).height(40).padding(0).backgroundColor(AppTheme.background('#F4F6FA'))
          .accessibilityText('关闭历史对话').onClick(() => { this.onClose(); })
        }.width('100%')
        Button() {
          Row({ space: 10 }) {
            Image($r('app.media.codex_plus')).width(20).height(20).fillColor(AppTheme.text('#172033'))
            Text('新对话').fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
          }.justifyContent(FlexAlign.Center).width('100%')
        }.width('100%').height(46).padding(0).borderRadius(14).backgroundColor(AppTheme.background('#EEF0FF'))
        .enabled(!this.busy).onClick(() => { this.onNewTask(); })
        Row({ space: 8 }) {
          Button('手机会话').fontSize(13).height(36).layoutWeight(1)
            .backgroundColor(this.scope === 'phone' ? AppTheme.background('#EEF0FF') : Color.Transparent)
            .fontColor(AppTheme.text(this.scope === 'phone' ? '#5968FF' : '#747B87'))
            .enabled(!this.busy).onClick(() => { this.onScope('phone'); })
          Button('电脑会话').fontSize(13).height(36).layoutWeight(1)
            .backgroundColor(this.scope === 'computer' ? AppTheme.background('#EEF0FF') : Color.Transparent)
            .fontColor(AppTheme.text(this.scope === 'computer' ? '#5968FF' : '#747B87'))
            .enabled(!this.busy).onClick(() => { this.onScope('computer'); })
        }.width('100%')
        if (this.scope === 'computer') {
          Row({ space: 8 }) {
            Text(this.supportsComputerHistory ? '已授权项目中的本地会话' : '请升级电脑端以查看已有会话')
              .fontSize(11).fontColor(AppTheme.text('#747B87')).layoutWeight(1)
            Button(this.loading ? '读取中' : '刷新').fontSize(12).height(32).padding({ left: 10, right: 10 })
              .backgroundColor(Color.Transparent).fontColor(AppTheme.text('#5968FF'))
              .enabled(!this.busy && !this.loading && this.supportsComputerHistory).onClick(() => { this.onRefresh(); })
          }.width('100%')
        }
        if (this.notice) {
          Text(this.notice).fontSize(12).lineHeight(18).fontColor(AppTheme.text('#B94D4D')).width('100%')
        }
        Scroll() {
          Column({ space: 6 }) {
            if (this.tasks.length === 0) {
              Text(this.scope === 'computer' ? (this.loading ? '正在读取电脑会话…' : '暂无可显示的本地会话') : '新对话会保存在这里')
                .fontSize(13).fontColor(AppTheme.text('#747B87')).margin({ top: 24 })
              if (this.scope === 'computer' && this.supportsComputerHistory && !this.loading) {
                Text('请确认电脑端已添加该会话对应的项目').fontSize(11).fontColor(AppTheme.text('#747B87'))
                  .width('100%').textAlign(TextAlign.Center).margin({ top: 10 })
              }
            }
            ForEach(this.tasks, (item: CodexTaskSummary) => {
              Column({ space: 6 }) {
                Text(item.title || '新对话').fontSize(15).fontColor(AppTheme.text('#172033')).maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.caption(item)).fontSize(11).fontColor(AppTheme.text('#747B87')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(14)
              .backgroundColor(item.id === this.selectedId ? AppTheme.background('#EEF0FF') : Color.Transparent)
              .enabled(!this.busy).onClick(() => { this.onSelect(item.id); })
            }, (item: CodexTaskSummary) => item.id)
            if (this.scope === 'computer' && this.hasMore) {
              Button(this.loading ? '读取中…' : '加载更多').fontSize(13).height(40).width('100%')
                .backgroundColor(Color.Transparent).fontColor(AppTheme.text('#5968FF'))
                .enabled(!this.busy && !this.loading).onClick(() => { this.onMore(); })
            }
          }.width('100%')
        }.width('100%').layoutWeight(1).align(Alignment.Top)
        Divider().color(AppTheme.border('#ECEEF3'))
        Row({ space: 12 }) {
          Image($r('app.media.codex_computer')).width(24).height(24).fillColor(AppTheme.text('#5968FF'))
          Column({ space: 4 }) {
            Text(this.serverName).fontSize(14).fontColor(AppTheme.text('#172033')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('我的连接 ›').fontSize(12).fontColor(AppTheme.text('#747B87'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ top: 4, bottom: 4 }).onClick(() => { this.onConnections(); })
      }.width('86%').constraintSize({ maxWidth: 360 }).height('100%')
      .padding({ left: 18, right: 18, top: 20, bottom: this.bottomInset + 20 })
      .backgroundColor(AppTheme.background('#FFFFFF')).borderRadius({ topRight: 24, bottomRight: 24 })
    }.width('100%').height('100%').zIndex(20)
  }
}
