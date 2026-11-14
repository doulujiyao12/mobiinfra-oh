// Compact, single-line fields for the model settings form. Long URLs scroll
// inside the editor instead of turning the whole row into a large text area.
@Component
export struct ModelSettingsField {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop placeholder: string = '默认';
  @Prop secret: boolean = false;
  @Prop editable: boolean = true;
  onValueChange: (value: string) => void = (_value: string): void => {};
  onInputFocus: () => void = (): void => {};

  build() {
    Row({ space: 12 }) {
      Text(this.label).fontSize(15).fontColor($r('app.color.ui_text_primary')).width(76)
      TextInput({ text: this.value, placeholder: this.placeholder })
        .type(this.secret ? InputType.Password : InputType.Normal)
        .showPasswordIcon(this.secret)
        .fontSize(15).height(48).layoutWeight(1)
        .fontColor($r('app.color.ui_text_primary'))
        .placeholderColor($r('app.color.ui_text_placeholder'))
        .caretColor($r('app.color.ui_accent_blue'))
        .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 })
        .enabled(this.editable).onFocus(this.onInputFocus).onChange(this.onValueChange)
    }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
  }
}
