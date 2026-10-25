import { AppTheme } from '../utils/AppTheme';

// Native grouped forms: content stays on an opaque, readable surface;
// the shared page header owns the glass/navigation layer.
@Component
export struct CollectionFormGroup {
  @Prop title: string = '';
  @Prop footer: string = '';
  @BuilderParam contentBuilder: () => void = this.EmptyContent;
  @Builder EmptyContent() {}
  build() {
    Column({ space: 8 }) {
      if (this.title) {
        Text(this.title).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.text('#747C8A')).width('100%').padding({ left: 16, right: 16 })
      }
      Column() { this.contentBuilder() }.width('100%').alignItems(HorizontalAlign.Start)
        .backgroundColor(AppTheme.background(Color.White)).borderRadius(18).clip(true)
      if (this.footer) {
        Text(this.footer).fontSize(12).lineHeight(19).fontColor(AppTheme.text('#747C8A'))
          .width('100%').padding({ left: 16, right: 16 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 24 })
  }
}

@Component
export struct CollectionFormDivider {
  build() {
    Divider().strokeWidth(0.5).color(AppTheme.border('#E5E5EA')).margin({ left: 16 })
  }
}

@Component
export struct CollectionFormInput {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop placeholder: string = '';
  @Prop secret: boolean = false;
  @Prop multiline: boolean = false;
  @Prop limit: number = 1000;
  @Prop inputType: InputType = InputType.Normal;
  onChangeValue: (value: string) => void = (_value: string): void => {};
  onBlurValue: () => void = (): void => {};
  build() {
    Column({ space: 2 }) {
      Text(this.label).fontSize(13).fontColor(AppTheme.text('#747C8A')).width('100%')
      if (this.multiline) {
        TextArea({ text: this.value, placeholder: this.placeholder }).fontSize(16).height(88)
          .fontColor(AppTheme.text('#172033')).placeholderColor($r('app.color.ui_text_placeholder'))
          .backgroundColor(Color.Transparent).padding({ left: 0, right: 0, top: 8, bottom: 8 })
          .maxLength(this.limit).onChange(this.onChangeValue).onBlur(this.onBlurValue)
      } else {
        TextInput({ text: this.value, placeholder: this.placeholder }).fontSize(16).height(42)
          .type(this.secret ? InputType.Password : this.inputType).showPasswordIcon(this.secret)
          .fontColor(AppTheme.text('#172033')).placeholderColor($r('app.color.ui_text_placeholder'))
          .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).maxLength(this.limit)
          .onChange(this.onChangeValue).onBlur(this.onBlurValue)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 16, right: 16, top: 12, bottom: 8 })
  }
}

@Component
export struct CollectionFormSwitch {
  @Prop label: string = '';
  @Prop detail: string = '';
  @Prop selected: boolean = false;
  onChangeValue: (value: boolean) => void = (_value: boolean): void => {};
  build() {
    Row({ space: 14 }) {
      Column({ space: 5 }) {
        Text(this.label).fontSize(16).fontColor(AppTheme.text('#172033')).width('100%')
        if (this.detail) {
          Text(this.detail).fontSize(12).lineHeight(19).fontColor(AppTheme.text('#747C8A')).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.selected }).selectedColor(AppTheme.filledBackground('#34C759'))
        .onChange(this.onChangeValue)
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }
}

@Component
export struct CollectionFormAction {
  @Prop label: string = '';
  @Prop destructive: boolean = false;
  @Prop centered: boolean = false;
  onAction: () => void = (): void => {};
  build() {
    Button({ type: ButtonType.Normal }) {
      Text(this.label).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.text(this.destructive ? '#D54A59' : '#007AFF')).width('100%')
        .textAlign(this.centered ? TextAlign.Center : TextAlign.Start)
    }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(Color.Transparent).onClick(this.onAction)
  }
}

@Component
export struct CollectionSourceRow {
  @Prop title: string = '';
  @Prop detail: string = '';
  @Prop icon: Resource = $r('app.media.source_calendar');
  @Prop tint: string = '#007AFF';
  onOpen: () => void = (): void => {};
  build() {
    Row({ space: 13 }) {
      Image(this.icon).width(34).height(34).padding(7)
        .backgroundColor(AppTheme.filledBackground(this.tint)).borderRadius(10)
      Column({ space: 4 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033')).width('100%')
        if (this.detail) {
          Text(this.detail).fontSize(12).lineHeight(18).fontColor(AppTheme.text('#747C8A')).width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(23).fontColor(AppTheme.text('#A0A6B2')).width(16).textAlign(TextAlign.Center)
    }.width('100%').constraintSize({ minHeight: 70 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .onClick(this.onOpen).accessibilityText(this.title)
  }
}
