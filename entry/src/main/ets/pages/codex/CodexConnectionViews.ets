import { AppTheme } from '../../utils/AppTheme';
import { CodexSavedConnection, codexConnectionLabel } from './CodexTypes';

@Component
struct ConnectionActionRow {
  icon: Resource = $r('app.media.codex_computer');
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop rowEnabled: boolean = true;
  onAction: () => void = () => {};

  build() {
    Row({ space: 14 }) {
      Image(this.icon).width(26).height(26).fillColor(AppTheme.text('#5968FF'))
      Column({ space: 5 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
        if (this.subtitle) {
          Text(this.subtitle).fontSize(12).fontColor(AppTheme.text('#747B87')).maxLines(2)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(24).fontColor(AppTheme.text('#A0A6B2'))
    }.width('100%').padding({ left: 18, right: 18, top: 18, bottom: 18 })
    .enabled(this.rowEnabled).opacity(this.rowEnabled ? 1 : 0.5)
    .accessibilityGroup(true).accessibilityText(this.title + '，' + this.subtitle)
    .onClick(() => { this.onAction(); })
  }
}

@Component
export struct CodexConnectionsView {
  @Prop connections: CodexSavedConnection[] = [];
  @Prop currentOrigin: string = '';
  @Prop currentName: string = '';
  @Prop currentStatus: string = '正在确认连接';
  @Prop connectingOrigin: string = '';
  @Prop loading: boolean = false;
  @Prop busy: boolean = false;
  onCreate: () => void = () => {};
  onConnect: (item: CodexSavedConnection) => void = () => {};
  onForget: (item: CodexSavedConnection) => void = () => {};
  onResume: () => void = () => {};
  onDisconnect: () => void = () => {};

  private connectionMenu(item: CodexSavedConnection): MenuElement[] {
    const entries: MenuElement[] = [];
    if (this.currentOrigin === item.origin) {
      entries.push({ value: '断开连接', action: () => { this.onDisconnect(); } });
    }
    entries.push({ value: '删除此连接', action: () => { this.onForget(item); } });
    return entries;
  }

  @Builder private ConnectionRow(item: CodexSavedConnection) {
    Row({ space: 0 }) {
      Row({ space: 14 }) {
        Image($r('app.media.codex_computer')).width(28).height(28).fillColor(AppTheme.text('#5968FF'))
        Column({ space: 5 }) {
          Text(item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(codexConnectionLabel(item.origin)).fontSize(12).fontColor(AppTheme.text('#747B87'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.currentOrigin === item.origin ? '● ' + this.currentStatus :
            this.busy && this.connectingOrigin === item.origin ? '正在连接…' : '轻点连接')
            .fontSize(11).fontColor(AppTheme.text(this.currentOrigin === item.origin && this.currentStatus === '已连接' ? '#21855A' : '#747B87'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.layoutWeight(1).padding({ left: 18, top: 18, bottom: 18 })
      .enabled(!this.busy).accessibilityGroup(true).accessibilityText('连接到' + item.name)
      .onClick(() => { this.onConnect(item); })
      Button('···').width(44).height(44).padding(0).fontSize(24).fontColor(AppTheme.text('#747B87'))
        .backgroundColor(Color.Transparent).enabled(!this.busy).accessibilityText('管理' + item.name)
        .bindMenu(this.connectionMenu(item))
    }.width('100%').padding({ right: 6 })
  }

  build() {
    Column({ space: 24 }) {
      Column({ space: 8 }) {
        Text('你的电脑，随时在身边').fontSize(25).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
        Text('从手机继续你的 Codex 项目').fontSize(14).fontColor(AppTheme.text('#747B87'))
      }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 12, bottom: 8 })
      if (this.loading) {
        Text('正在读取连接…').fontSize(13).fontColor(AppTheme.text('#747B87')).width('100%')
      } else if (this.connections.length === 0 && !this.currentOrigin) {
        Column({ space: 16 }) {
          Image($r('app.media.codex_computer')).width(56).height(56).fillColor(AppTheme.text('#5968FF'))
            .padding(12).width(84).height(84).backgroundColor(AppTheme.background('#EEF0FF')).borderRadius(26)
          Column({ space: 7 }) {
            Text('连接第一台电脑').fontSize(19).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
            Text('电脑打开配对码，手机扫一扫').fontSize(13).fontColor(AppTheme.text('#747B87'))
          }
        }.width('100%').padding({ top: 28, bottom: 32 })
      }
      if (this.currentOrigin && !this.connections.some((item: CodexSavedConnection) => item.origin === this.currentOrigin)) {
        Column() {
          ConnectionActionRow({ title: this.currentName || '当前电脑', subtitle: this.currentStatus + ' · ' + codexConnectionLabel(this.currentOrigin),
            rowEnabled: !this.busy, onAction: () => { this.onResume(); } })
          Divider().color(AppTheme.border('#E9EBF0')).margin({ left: 60, right: 18 })
          Button('断开连接').width('100%').height(46).fontSize(14).fontColor(AppTheme.text('#B94D4D'))
            .backgroundColor(Color.Transparent).enabled(!this.busy).onClick(() => { this.onDisconnect(); })
        }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20)
      }
      if (this.connections.length > 0) {
        Column({ space: 10 }) {
          Text('我的连接').fontSize(13).fontColor(AppTheme.text('#747B87')).width('100%').padding({ left: 4 })
          Column() {
            ForEach(this.connections, (item: CodexSavedConnection, index: number) => {
              if (index > 0) { Divider().color(AppTheme.border('#E9EBF0')).margin({ left: 60, right: 18 }) }
              this.ConnectionRow(item)
            }, (item: CodexSavedConnection) => item.id)
          }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20).clip(true)
        }.width('100%')
      }
      Column() {
        ConnectionActionRow({ title: '创建连接', subtitle: '扫描二维码，或导入配对文件', rowEnabled: !this.busy,
          icon: $r('app.media.codex_scan'), onAction: () => { this.onCreate(); } })
      }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20)
      Text('连接凭据保存在手机安全存储中').fontSize(11).fontColor(AppTheme.text('#9198A5')).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct CodexConnectionSetup {
  @Link origin: string;
  @Link token: string;
  @Link pairing: string;
  @Link remember: boolean;
  @Prop busy: boolean = false;
  @State private pasteOpen: boolean = false;
  @State private manualOpen: boolean = false;
  onScan: () => void = () => {};
  onImport: () => void = () => {};
  onPair: () => void = () => {};
  onManualConnect: () => void = () => {};

  build() {
    Column({ space: 24 }) {
      Column({ space: 8 }) {
        Text('把 Codex 带到手机').fontSize(25).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
        Text('电脑端打开「手机配对」，生成一次性配对码').fontSize(13).lineHeight(20).fontColor(AppTheme.text('#747B87'))
      }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 12, bottom: 8 })
      Column() {
        ConnectionActionRow({ title: this.busy ? '正在处理…' : '扫描二维码', subtitle: '对准电脑上的配对码，也支持从相册识别',
          icon: $r('app.media.codex_scan'), rowEnabled: !this.busy, onAction: () => { this.onScan(); } })
      }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20)
      Column() {
        ConnectionActionRow({ title: '导入配对文件', icon: $r('app.media.codex_document'), rowEnabled: !this.busy,
          onAction: () => { this.onImport(); } })
        Divider().color(AppTheme.border('#E9EBF0')).margin({ left: 60, right: 18 })
        ConnectionActionRow({ title: '粘贴配对信息', icon: $r('app.media.codex_document'), rowEnabled: !this.busy,
          onAction: () => { this.pasteOpen = !this.pasteOpen; } })
        if (this.pasteOpen) {
          Column({ space: 12 }) {
            TextArea({ placeholder: '粘贴电脑端复制的完整配对信息', text: this.pairing })
              .height(112).fontSize(13).fontColor(AppTheme.text('#172033'))
              .placeholderColor($r('app.color.ui_text_placeholder')).backgroundColor(AppTheme.inputBackground())
              .borderRadius(14).maxLength(12288).enabled(!this.busy).onChange((v: string) => { this.pairing = v; })
            Button('确认配对').width('100%').height(44).fontSize(15)
              .backgroundColor(AppTheme.filledBackground('#5968FF')).fontColor(AppTheme.text(Color.White))
              .enabled(!this.busy && this.pairing.trim().length > 0).onClick(() => { this.onPair(); })
          }.padding({ left: 18, right: 18, bottom: 18 }).width('100%')
        }
      }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20)
      Column({ space: 8 }) {
        Row() {
          Text('记住此连接').fontSize(15).fontColor(AppTheme.text('#172033')).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.remember }).selectedColor(AppTheme.filledBackground('#5968FF'))
            .enabled(!this.busy).onChange((v: boolean) => { this.remember = v; })
        }.width('100%')
        Text('配对码 5 分钟内有效，连接时会请你确认电脑身份。').fontSize(11).lineHeight(17).fontColor(AppTheme.text('#747B87'))
      }.padding({ left: 4, right: 4 }).width('100%').alignItems(HorizontalAlign.Start)
      Column() {
        Row() {
          Text('手动连接').fontSize(14).fontColor(AppTheme.text('#747B87')).layoutWeight(1)
          Text(this.manualOpen ? '⌃' : '›').fontSize(21).fontColor(AppTheme.text('#9198A5'))
        }.width('100%').padding(16).enabled(!this.busy).onClick(() => { this.manualOpen = !this.manualOpen; })
        if (this.manualOpen) {
          Column({ space: 12 }) {
            Text('仅用于已有 HTTPS 桥接服务；证书指纹不是 token。').fontSize(12).lineHeight(18)
              .fontColor(AppTheme.text('#747B87')).width('100%')
            TextInput({ placeholder: 'HTTPS 地址', text: this.origin }).height(46).fontSize(14)
              .fontColor(AppTheme.text('#172033')).placeholderColor($r('app.color.ui_text_placeholder'))
              .backgroundColor(AppTheme.inputBackground()).maxLength(255).enabled(!this.busy)
              .onChange((v: string) => { this.origin = v; })
            TextInput({ placeholder: '服务器生成的桥接 token', text: this.token }).type(InputType.Password)
              .height(46).fontSize(14).fontColor(AppTheme.text('#172033'))
              .placeholderColor($r('app.color.ui_text_placeholder')).backgroundColor(AppTheme.inputBackground())
              .maxLength(128).enabled(!this.busy).onChange((v: string) => { this.token = v; })
            Button('连接服务器').height(44).width('100%').fontSize(15)
              .fontColor(AppTheme.text(Color.White)).backgroundColor(AppTheme.filledBackground('#5968FF'))
              .enabled(!this.busy && this.origin.trim().length > 0 && this.token.trim().length > 0)
              .onClick(() => { this.onManualConnect(); })
          }.width('100%').padding({ left: 16, right: 16, bottom: 18 })
        }
      }.width('100%').backgroundColor(AppTheme.background('#FFFFFF')).borderRadius(20)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
