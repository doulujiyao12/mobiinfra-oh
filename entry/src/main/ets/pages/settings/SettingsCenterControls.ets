import {
  isMaskedSensitiveSettingValue,
  maskSensitiveSettingValue,
  settingsInputShouldUseMultiline,
  settingsSensitiveInputShouldUseMultiline,
  SettingsActionKind
} from './SettingsCenterTypes';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import {
  SETTINGS_ACTION_GAP,
  SETTINGS_BUTTON_HEIGHT,
  SETTINGS_CARD_BACKGROUND_COLOR,
  SETTINGS_CARD_PADDING,
  SETTINGS_CARD_RADIUS,
  SETTINGS_CONTROL_RADIUS,
  SETTINGS_FIELD_HEIGHT,
  SETTINGS_GROUP_GAP,
  SETTINGS_INPUT_BACKGROUND_COLOR,
  SETTINGS_INPUT_DISABLED_BACKGROUND_COLOR,
  SETTINGS_MUTED_TEXT_COLOR,
  SETTINGS_MULTILINE_FIELD_HEIGHT,
  SETTINGS_PANEL_BACKGROUND_COLOR,
  SETTINGS_PANEL_BORDER_COLOR,
  SETTINGS_SECONDARY_TEXT_COLOR,
  SETTINGS_TITLE_COLOR,
  settingsActionColor
} from './SettingsCenterTheme';
import {
  hiddenDefaultSettingEditorValue,
  hiddenDefaultSettingPlaceholder,
  settingUsesDefaultValue
} from '../../utils/DefaultSettingVisibility';

// 设置分组卡片负责统一分组标题、间距和卡片外观，业务内容通过 Builder 注入。
@Component
export struct SettingsGroupCard {
  title: string = '';
  subtitle: string = '';
  onHeaderClick: () => void = () => {};
  @BuilderParam contentBuilder: () => void = this.EmptyContent;

  @Builder EmptyContent() {}

  build() {
    Column() {
      Text(this.title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(SETTINGS_TITLE_COLOR)
        .width('100%')
        .onClick(() => { this.onHeaderClick(); })
      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(12)
          .fontColor(SETTINGS_SECONDARY_TEXT_COLOR)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .onClick(() => { this.onHeaderClick(); })
      }
      Column() {
        this.contentBuilder()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(SETTINGS_CARD_PADDING)
    .backgroundColor(SETTINGS_CARD_BACKGROUND_COLOR)
    .borderRadius(SETTINGS_CARD_RADIUS)
    .border({ width: 1, color: '#F0F2F7' })
    .margin({ top: 12 })
  }
}

// 设置项输入框只转发用户输入，配置读写由父组件维护。
@Component
export struct SettingInput {
  label: string = '';
  value: string = '';
  placeholder: string = '';
  inputEnabled: boolean = true;
  inputType: InputType = InputType.Normal;
  onValueChange: (value: string) => void = (value: string) => {};
  onInputFocus: () => void = () => {};
  onInputBlur: () => void = () => {};

  build() {
    Column() {
      Text(this.label)
        .fontSize(13)
        .fontColor(SETTINGS_MUTED_TEXT_COLOR)
        .width('100%')
        .margin({ bottom: 6 })
      if (settingsInputShouldUseMultiline(this.value, this.placeholder)) {
        TextArea({ placeholder: this.placeholder, text: this.value })
          .height(SETTINGS_MULTILINE_FIELD_HEIGHT)
          .width('100%')
          .maxLines(4)
          .fontSize(13)
          .lineHeight(20)
          .fontColor(this.inputEnabled ? SETTINGS_TITLE_COLOR : SETTINGS_SECONDARY_TEXT_COLOR)
          .backgroundColor(this.inputEnabled ? SETTINGS_INPUT_BACKGROUND_COLOR : SETTINGS_INPUT_DISABLED_BACKGROUND_COLOR)
          .borderRadius(SETTINGS_CONTROL_RADIUS)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .enabled(this.inputEnabled)
          .onClick(() => { this.onInputFocus(); })
          .onFocus(() => { this.onInputFocus(); })
          .onChange((value: string) => { this.onValueChange(value); })
          .onBlur(() => { this.onInputBlur(); })
      } else {
        TextInput({ placeholder: this.placeholder, text: this.value })
          .type(this.inputType)
          .height(SETTINGS_FIELD_HEIGHT)
          .width('100%')
          .fontSize(13)
          .fontColor(this.inputEnabled ? SETTINGS_TITLE_COLOR : SETTINGS_SECONDARY_TEXT_COLOR)
          .backgroundColor(this.inputEnabled ? SETTINGS_INPUT_BACKGROUND_COLOR : SETTINGS_INPUT_DISABLED_BACKGROUND_COLOR)
          .borderRadius(SETTINGS_CONTROL_RADIUS)
          .padding({ left: 12, right: 12 })
          .enabled(this.inputEnabled)
          .onClick(() => { this.onInputFocus(); })
          .onFocus(() => { this.onInputFocus(); })
          .onChange((value: string) => { this.onValueChange(value); })
          .onBlur(() => { this.onInputBlur(); })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8 })
  }
}

// 敏感输入默认遮罩展示，显示后才允许编辑原始值，避免把遮罩值写回配置。
@Component
export struct SensitiveSettingInput {
  sensitiveId: string = '';
  @Prop activeSensitiveId: string = '';
  label: string = '';
  value: string = '';
  defaultValue: string = '';
  placeholder: string = '';
  onValueChange: (value: string) => void = (value: string) => {};
  onActiveSensitiveChange: (value: string) => void = (value: string) => {};
  @State private localVisible: boolean = false;
  @State private autoFocusEditor: boolean = false;

  private previewText(): string {
    if (settingUsesDefaultValue(this.value, this.defaultValue)) {
      return '默认';
    }
    let maskedValue = maskSensitiveSettingValue(this.value);
    if (maskedValue.length > 0) {
      return maskedValue;
    }
    return this.placeholder;
  }

  private previewTextColor(): string {
    return settingUsesDefaultValue(this.value, this.defaultValue) ? '#A9B0BE' : SETTINGS_SECONDARY_TEXT_COLOR;
  }

  private effectiveSensitiveId(): string {
    if (this.sensitiveId.length > 0) {
      return this.sensitiveId;
    }
    return this.label;
  }

  private isExternallyControlled(): boolean {
    return this.sensitiveId.length > 0;
  }

  private isVisible(): boolean {
    if (this.isExternallyControlled()) {
      return this.activeSensitiveId === this.effectiveSensitiveId();
    }
    return this.localVisible;
  }

  private editorNodeId(): string {
    return 'settings-sensitive-editor-' + this.effectiveSensitiveId();
  }

  private requestEditorFocus(): void {
    let nodeId = this.editorNodeId();
    this.autoFocusEditor = true;
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus(nodeId);
      } catch (e) {
      }
      this.autoFocusEditor = false;
    }, 0);
  }

  private enterEditMode(): void {
    if (this.isExternallyControlled()) {
      this.onActiveSensitiveChange(this.effectiveSensitiveId());
    } else {
      this.localVisible = true;
    }
    this.requestEditorFocus();
  }

  private leaveEditMode(): void {
    if (this.isExternallyControlled()) {
      this.onActiveSensitiveChange('');
    } else {
      this.localVisible = false;
    }
    this.autoFocusEditor = false;
  }

  private editorText(): string {
    if (isMaskedSensitiveSettingValue(this.value)) {
      return '';
    }
    return hiddenDefaultSettingEditorValue(this.value, this.defaultValue);
  }

  private editorPlaceholder(): string {
    if (isMaskedSensitiveSettingValue(this.value)) {
      return '当前密钥已被遮罩，请重新输入';
    }
    return hiddenDefaultSettingPlaceholder(this.value, this.defaultValue, this.placeholder);
  }

  private handleEditorChange(value: string): void {
    if (isMaskedSensitiveSettingValue(value)) {
      return;
    }
    this.onValueChange(value);
  }

  @Builder HiddenPreview() {
    Column() {
      Text(this.previewText())
        .fontSize(13)
        .lineHeight(20)
        .fontColor(this.previewTextColor())
        .width('100%')
        .maxLines(settingsSensitiveInputShouldUseMultiline(this.value, this.placeholder) ? 3 : 1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .justifyContent(FlexAlign.Center)
    .height(settingsSensitiveInputShouldUseMultiline(this.value, this.placeholder) ?
      SETTINGS_MULTILINE_FIELD_HEIGHT : SETTINGS_FIELD_HEIGHT)
    .layoutWeight(1)
    .backgroundColor(SETTINGS_INPUT_DISABLED_BACKGROUND_COLOR)
    .borderRadius(SETTINGS_CONTROL_RADIUS)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .onClick(() => { this.enterEditMode(); })
  }

  @Builder VisibleEditor() {
    if (settingsSensitiveInputShouldUseMultiline(this.value, this.placeholder)) {
      TextArea({ placeholder: this.editorPlaceholder(), text: this.editorText() })
        .height(SETTINGS_MULTILINE_FIELD_HEIGHT)
        .layoutWeight(1)
        .maxLines(4)
        .fontSize(13)
        .lineHeight(20)
        .fontColor(SETTINGS_TITLE_COLOR)
        .backgroundColor(SETTINGS_INPUT_BACKGROUND_COLOR)
        .borderRadius(SETTINGS_CONTROL_RADIUS)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .id(this.editorNodeId())
        .focusOnTouch(true)
        .enabled(true)
        .defaultFocus(this.autoFocusEditor)
        .onFocus(() => { this.autoFocusEditor = false; })
        .onChange((value: string) => { this.handleEditorChange(value); })
        .onBlur(() => { this.leaveEditMode(); })
    } else {
      TextInput({ placeholder: this.editorPlaceholder(), text: this.editorText() })
        .height(SETTINGS_FIELD_HEIGHT)
        .layoutWeight(1)
        .fontSize(13)
        .fontColor(SETTINGS_TITLE_COLOR)
        .backgroundColor(SETTINGS_INPUT_BACKGROUND_COLOR)
        .borderRadius(SETTINGS_CONTROL_RADIUS)
        .padding({ left: 12, right: 12 })
        .id(this.editorNodeId())
        .focusOnTouch(true)
        .enabled(true)
        .defaultFocus(this.autoFocusEditor)
        .onFocus(() => { this.autoFocusEditor = false; })
        .onChange((value: string) => { this.handleEditorChange(value); })
        .onBlur(() => { this.leaveEditMode(); })
    }
  }

  build() {
    Column() {
      Text(this.label)
        .fontSize(13)
        .fontColor(SETTINGS_MUTED_TEXT_COLOR)
        .width('100%')
        .margin({ bottom: 6 })
      Row() {
        if (this.isVisible()) {
          this.VisibleEditor()
        } else {
          this.HiddenPreview()
        }
        if (this.isVisible()) {
          Button('隐藏')
            .height(SETTINGS_FIELD_HEIGHT)
            .width(64)
            .fontSize(12)
            .fontColor(Color.White)
            .backgroundColor(settingsActionColor(SettingsActionKind.Secondary))
            .borderRadius(SETTINGS_CONTROL_RADIUS)
            .margin({ left: 8 })
            .onClick(() => { this.leaveEditMode(); })
        } else {
          Button('显示')
            .height(SETTINGS_FIELD_HEIGHT)
            .width(64)
            .fontSize(12)
            .fontColor(Color.White)
            .backgroundColor(settingsActionColor(SettingsActionKind.Primary))
            .borderRadius(SETTINGS_CONTROL_RADIUS)
            .margin({ left: 8 })
            .onClick(() => { this.enterEditMode(); })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8 })
  }
}

// 设置开关行统一复选框、标题和说明布局。
@Component
export struct SettingToggle {
  label: string = '';
  desc: string = '';
  selected: boolean = false;
  onValueChange: (value: boolean) => void = (value: boolean) => {};

  build() {
    Row() {
      Checkbox({ name: this.label, group: 'settingsCenter' })
        .select(this.selected)
        .selectedColor(settingsActionColor(SettingsActionKind.Primary))
        .onChange((value: boolean) => { this.onValueChange(value); })
      Column() {
        Text(this.label)
          .fontSize(14)
          .fontColor(SETTINGS_TITLE_COLOR)
          .width('100%')
        Text(this.desc)
          .fontSize(12)
          .fontColor(SETTINGS_SECONDARY_TEXT_COLOR)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 8 })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }
}

// 设置操作按钮只负责语义色、禁用态和点击事件转发。
@Component
export struct SettingsActionButton {
  label: string = '';
  kind: SettingsActionKind = SettingsActionKind.Primary;
  actionEnabled: boolean = true;
  onActionClick: () => void = () => {};

  build() {
    Button(this.label)
      .height(SETTINGS_BUTTON_HEIGHT)
      .layoutWeight(1)
      .fontSize(12)
      .fontColor(Color.White)
      .backgroundColor(this.actionEnabled ? settingsActionColor(this.kind) : '#A9B0BE')
      .borderRadius(SETTINGS_CONTROL_RADIUS)
      .enabled(this.actionEnabled)
      .onClick(() => { this.onActionClick(); })
  }
}

// 设置操作行统一横向按钮间距，支持单个按钮自动占满宽度。
@Component
export struct SettingsActionRow {
  @BuilderParam contentBuilder: () => void = this.EmptyContent;

  @Builder EmptyContent() {}

  build() {
    Row({ space: SETTINGS_ACTION_GAP }) {
      this.contentBuilder()
    }
    .width('100%')
    .margin({ top: SETTINGS_ACTION_GAP })
  }
}

// 设置输出面板用于本地/云端日志和配置 JSON 等只读长文本。
@Component
export struct SettingsOutputPanel {
  @Prop title: string = '';
  @Prop content: string = '';
  @Prop aiGenerated: boolean = false;

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(13)
          .fontColor(SETTINGS_MUTED_TEXT_COLOR)
          .layoutWeight(1)
        if (this.aiGenerated) {
          AiGeneratedBadge({ compact: true })
        }
      }
        .width('100%')
      Scroll() {
        Text(this.content.length > 0 ? this.content : '暂无输出')
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor('#333333')
          .width('100%')
          .padding(12)
      }
      .constraintSize({ minHeight: 72, maxHeight: 130 })
      .width('100%')
      .backgroundColor(SETTINGS_PANEL_BACKGROUND_COLOR)
      .borderRadius(SETTINGS_CONTROL_RADIUS)
      .margin({ top: 6 })
      .border({ width: 1, color: SETTINGS_PANEL_BORDER_COLOR })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: SETTINGS_GROUP_GAP })
  }
}
