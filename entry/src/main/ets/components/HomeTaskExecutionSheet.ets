import { AppTheme } from '../utils/AppTheme';
import { AppLogger } from '../utils/AppLogger';
import {
  HomeTaskSuggestion, homeTaskSupportsQwen, homeTaskQwenDescription, homeTaskQwenUnavailableReason,
  HOME_TASK_DESCRIPTION_LIMIT, homeTaskShortDraft
} from '../pages/home/HomeTaskSuggestion';

@Component
export struct HomeTaskExecutionSheet {
  @Prop suggestion: HomeTaskSuggestion = { id: '', title: '', task: '', reason: '', category: 'life', evidence: [] };
  onExecute: (method: string, draft: string) => Promise<boolean> =
    async (_method: string, _draft: string): Promise<boolean> => false;
  @State private method: string = 'phone';
  @State private phoneDraft: string = '';
  @State private qwenDraft: string = '';
  @State private submitting: boolean = false;
  @State private errorText: string = '';

  aboutToAppear(): void {
    this.phoneDraft = homeTaskShortDraft(this.suggestion.task, this.suggestion.title);
    this.qwenDraft = homeTaskSupportsQwen(this.suggestion) ? homeTaskQwenDescription(this.suggestion) : '';
  }

  private selectMethod(method: string): void {
    if (this.submitting) { return; }
    this.method = method;
    this.errorText = '';
  }

  private async execute(): Promise<void> {
    if (this.submitting) { return; }
    this.submitting = true;
    this.errorText = '';
    try {
      let success = await this.onExecute(this.method, this.method === 'phone' ? this.phoneDraft : this.qwenDraft);
      if (!success) {
        this.errorText = this.method === 'qwen' ? '千问交接未完成。请确认已安装并登录千问、手机控制连接可用，再根据提示重试。' :
          '任务尚未完成，请根据提示检查后重试';
      }
    } catch (e) {
      this.errorText = (e as Error).message;
      AppLogger.warnCause('HomeSuggestion', 'Execution choice rejected', e as Error);
    }
    finally { this.submitting = false; }
  }

  @Builder MethodButton(method: string, label: string, available: boolean) {
    Button(label)
      .layoutWeight(1)
      .height(44)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.method === method ? Color.White : AppTheme.text(available ? '#4F46C8' : '#969DAA'))
      .backgroundColor(AppTheme.background(this.method === method ? '#6658DC' : '#F0EEFC'))
      .borderRadius(14)
      .enabled(available && !this.submitting)
      .onClick((): void => { this.selectMethod(method); })
  }

  build() {
    Column({ space: 14 }) {
      Text(this.suggestion.title)
        .fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033'))
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 10 }) {
        this.MethodButton('phone', '操控手机完成', true)
        this.MethodButton('qwen', '千问协同完成', homeTaskSupportsQwen(this.suggestion))
      }.width('100%')
      Text(this.method === 'phone' ? '由手机 Agent 在目标应用中操作。' : '手机 Agent 只负责打开千问并发送需求，后续由千问处理。')
        .fontSize(12).fontColor(AppTheme.text('#6E7687')).width('100%').lineHeight(18)
      if (!homeTaskSupportsQwen(this.suggestion)) {
        Text(homeTaskQwenUnavailableReason(this.suggestion))
          .fontSize(12).fontColor(AppTheme.text('#8A758F')).width('100%').lineHeight(18)
      }
      TextArea({ text: this.method === 'phone' ? this.phoneDraft : this.qwenDraft,
        placeholder: '一句话，只做一件事（最多60字）' })
        .width('100%').height(90).fontSize(14).fontColor(AppTheme.text('#202839'))
        .placeholderColor($r('app.color.ui_text_placeholder')).caretColor($r('app.color.ui_accent_blue'))
        .backgroundColor(AppTheme.inputBackground()).borderRadius(14).padding(12).maxLength(HOME_TASK_DESCRIPTION_LIMIT)
        .enabled(!this.submitting)
        .onChange((text: string): void => {
          if (this.method === 'phone') { this.phoneDraft = text; } else { this.qwenDraft = text; }
          this.errorText = '';
        })
      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(12).fontColor(AppTheme.text('#B42318')).width('100%').maxLines(3)
      }
      Button(this.submitting ? '正在下发…' : (this.method === 'phone' ? '开始手机执行' : '交给千问'))
        .width('100%').height(46).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Color.White)
        .backgroundColor(AppTheme.filledBackground('#6658DC')).borderRadius(15)
        .enabled(!this.submitting && (this.method === 'phone' ? this.phoneDraft.trim().length > 0 : this.qwenDraft.trim().length > 0))
        .onClick((): void => { this.execute(); })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    .backgroundColor(AppTheme.background('#FFFFFF'))
  }
}
