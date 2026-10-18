import { AppTheme } from '../../utils/AppTheme';
import { CodexApproval, CodexAnswer, CodexQuestion, CodexQuestionOption } from './CodexTypes';

@Component
export struct CodexApprovalCard {
  @Prop approval: CodexApproval = { id: '', kind: '', title: '', detail: '', questions: [] };
  @Prop busy: boolean = false;
  @State private answers: CodexAnswer[] = [];
  onAnswer: (id: string, decision: string, answers: CodexAnswer[]) => void = () => {};

  private answerText(id: string): string { return this.answers.find((a: CodexAnswer) => a.id === id)?.text ?? ''; }
  private setAnswer(id: string, text: string): void {
    this.answers = this.answers.filter((a: CodexAnswer) => a.id !== id).concat([{ id: id, text: text }]);
  }
  private complete(): boolean {
    return this.approval.questions.every((q: CodexQuestion) => this.answerText(q.id).trim().length > 0);
  }

  build() {
    Column({ space: 12 }) {
      Text(this.approval.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#AD6500'))
      if (this.approval.kind === 'question') {
        ForEach(this.approval.questions, (q: CodexQuestion) => {
          Column({ space: 8 }) {
            Text(q.question).fontSize(14).fontColor(AppTheme.text('#172033'))
            ForEach(q.options ?? [], (option: CodexQuestionOption) => {
              Button(option.label + ' · ' + option.description)
                .fontSize(12).height('auto').padding(10)
                .backgroundColor(AppTheme.background('#FFFFFF')).fontColor(AppTheme.text('#5968FF'))
                .onClick(() => { this.setAnswer(q.id, option.label); })
            }, (option: CodexQuestionOption) => option.label)
            TextInput({ placeholder: '填写回答', text: this.answerText(q.id) })
              .type(q.isSecret ? InputType.Password : InputType.Normal).maxLength(4000)
              .onChange((value: string) => { this.setAnswer(q.id, value); })
          }.alignItems(HorizontalAlign.Start).width('100%')
        }, (q: CodexQuestion) => q.id)
        Button('提交回答').enabled(!this.busy && this.complete())
          .onClick(() => { this.onAnswer(this.approval.id, 'answer', this.answers); })
      } else {
        Text('确认前请检查命令、目录和申请原因；允许操作可能超出当前沙箱。')
          .fontSize(12).fontColor(AppTheme.text('#8E651C'))
        Scroll() {
          Text(this.approval.detail).fontSize(12).fontFamily('monospace')
            .fontColor(AppTheme.text('#293248')).copyOption(CopyOptions.LocalDevice).width('100%')
        }.constraintSize({ maxHeight: 240 }).width('100%')
        Row({ space: 10 }) {
          Button('拒绝').onClick(() => { this.onAnswer(this.approval.id, 'decline', []); })
          Button('仅允许本次').enabled(this.approval.canAccept === true)
            .onClick(() => { this.onAnswer(this.approval.id, 'accept', []); })
        }.enabled(!this.busy)
      }
    }.width('100%').padding(16).borderRadius(16).alignItems(HorizontalAlign.Start)
    .backgroundColor(AppTheme.background('#FFF4DC'))
    .border({ width: 1, color: AppTheme.border('#E4BA6B') })
  }
}
