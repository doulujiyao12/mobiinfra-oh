import { CodexCredentialStore } from '../pages/codex/CodexCredentialStore';
import { SecretaryRoute, secretaryRouteLabel } from '../pages/home/HomeSecretary';
import {
  HomeTaskSuggestion, homeTaskSupportsQwen, homeTaskQwenDescription, homeTaskQwenUnavailableReason,
  HOME_TASK_DESCRIPTION_LIMIT, homeTaskQwenDescriptionLimit
} from '../pages/home/HomeTaskSuggestion';

@Component
export struct HomeTaskExecutionSheet {
  @Prop suggestion: HomeTaskSuggestion = { id: '', title: '', task: '', reason: '', category: 'life', evidence: [] };
  @Prop recommended: SecretaryRoute = 'phone';
  onExecute: (method: SecretaryRoute, draft: string) => void = (): void => {};
  @State private method: SecretaryRoute = 'phone';
  @State private phoneDraft: string = '';
  @State private qwenDraft: string = '';
  @State private codexDraft: string = '';
  @State private codexChecking: boolean = true;
  @State private codexIssue: string = '';
  private userSelected: boolean = false;
  private confirmed: boolean = false;
  @State private errorText: string = '';

  aboutToAppear(): void {
    this.method = this.recommended;
    this.phoneDraft = this.suggestion.task || this.suggestion.title;
    if (homeTaskSupportsQwen(this.suggestion)) {
      try { this.qwenDraft = homeTaskQwenDescription(this.suggestion); }
      catch (e) { this.qwenDraft = this.suggestion.qwenTask || this.phoneDraft; }
    }
    this.checkComputer();
  }

  private async checkComputer(): Promise<void> {
    try {
      if ((await CodexCredentialStore.list()).length === 0) { this.codexIssue = '使用 Codex 前，请先在「Codex」页连接电脑。'; }
    } catch (e) { this.codexIssue = (e as Error).message || '暂时无法读取电脑连接'; }
    finally {
      this.codexChecking = false;
      if (!this.userSelected && !this.confirmed) { this.method = this.availableRecommendation(); }
    }
  }

  private availableRecommendation(): SecretaryRoute {
    if (this.recommended === 'codex' && this.codexIssue) {
      return homeTaskSupportsQwen(this.suggestion) ? 'qwen' : 'phone';
    }
    return this.recommended;
  }

  private selectMethod(method: SecretaryRoute): void {
    if (this.confirmed) { return; }
    this.userSelected = true;
    this.method = method;
    this.errorText = '';
  }

  private descriptionLimit(): number {
    return this.method === 'codex' ? 1000 : this.method === 'phone' ? HOME_TASK_DESCRIPTION_LIMIT : homeTaskQwenDescriptionLimit(this.suggestion);
  }

  private draft(): string { return this.method === 'codex' ? this.codexDraft : this.method === 'phone' ? this.phoneDraft : this.qwenDraft; }

  private unavailableReason(): string {
    if (this.method === 'qwen') { return homeTaskQwenUnavailableReason(this.suggestion); }
    if (this.method === 'codex') { return this.codexChecking ? '正在检查电脑连接…' : this.codexIssue; }
    return '';
  }

  private execute(): void {
    if (this.confirmed || this.unavailableReason() || (this.method !== 'codex' && !this.draft().trim())) { return; }
    this.confirmed = true;
    try {
      this.onExecute(this.method, this.draft());
    } catch (e) {
      this.confirmed = false;
      this.errorText = (e as Error).message;
    }
  }

  @Builder MethodButton(method: SecretaryRoute) {
    Button(secretaryRouteLabel(method)).layoutWeight(1).height(40).fontSize(15).fontWeight(FontWeight.Medium)
      .fontColor(this.method === method ? $r('app.color.ui_accent_purple') : $r('app.color.ui_text_secondary'))
      .backgroundColor(this.method === method ? $r('app.color.ui_surface') : Color.Transparent)
      .accessibilityText(secretaryRouteLabel(method) + (this.method === method ? '，已选中' : ''))
      .onClick((): void => { this.selectMethod(method); })
  }

  build() {
    Column({ space: 14 }) {
      Text(this.suggestion.title)
        .fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.ui_text_primary'))
        .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('执行方式 · 小 C 推荐' + secretaryRouteLabel(this.availableRecommendation())).fontSize(14)
        .fontColor($r('app.color.ui_text_secondary'))
      Row({ space: 3 }) {
        this.MethodButton('phone')
        this.MethodButton('qwen')
        this.MethodButton('codex')
      }.width('100%').padding(4).borderRadius(24).backgroundColor($r('app.color.ui_surface_soft'))
      Text(this.unavailableReason() || (this.method === 'codex' ? '在已连接的电脑上结合相关记录调研、规划或制作文件。' :
        this.method === 'phone' ? '由小 C 操作手机上的目标应用。' : '在手机上的千问新对话中发送需求，需已安装并登录千问。'))
        .fontSize(14).fontColor($r('app.color.ui_text_secondary')).width('100%').lineHeight(21)
      if (!this.unavailableReason()) {
        TextArea({ text: this.draft(),
          placeholder: this.method === 'codex' ? '补充交付要求（可选）' : this.descriptionLimit() > HOME_TASK_DESCRIPTION_LIMIT ?
            '可补充出行时间、地点和人数（最多300字）' : '写下一件希望完成的事（最多60字）' })
          .width('100%').height(88).fontSize(15).fontColor($r('app.color.ui_text_primary'))
          .placeholderColor($r('app.color.ui_text_placeholder')).caretColor($r('app.color.ui_accent_blue'))
          .backgroundColor($r('app.color.ui_surface_soft')).borderRadius(14).padding(12)
          .maxLength(Math.max(this.descriptionLimit(), this.draft().length))
          .onChange((text: string): void => {
            if (this.method === 'codex') { this.codexDraft = text; }
            else if (this.method === 'phone') { this.phoneDraft = text; }
            else { this.qwenDraft = text; }
            this.errorText = '';
          })
      }
      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(14).fontColor($r('app.color.ui_text_primary')).width('100%')
      }
      Button(this.method === 'phone' ? '在手机上执行' : '交给 ' + secretaryRouteLabel(this.method))
        .width('100%').height(46).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ui_text_on_fill'))
        .backgroundColor($r('app.color.ui_surface_emphasized'))
        .enabled(!this.unavailableReason() && (this.method === 'codex' || this.draft().trim().length > 0))
        .onClick((): void => { this.execute(); })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }
}
