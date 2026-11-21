import { webview } from '@kit.ArkWeb';
import { MarkdownView } from '../../components/MarkdownView';
import { buildCodexMathDocument } from '../../utils/markdown/CodexMathDocument';
import { APP_DARK_MODE_KEY } from '../../utils/AppTheme';

class CodexMathLinkProxy {
  onOpen: (index: number, revision: number) => void = () => {};

  open(index: number, revision: number): void {
    this.onOpen(index, revision);
  }
}

@Component
export struct CodexMarkdownView {
  @Prop @Watch('refreshContent') text: string = '';
  @StorageProp(APP_DARK_MODE_KEY) @Watch('updatePage') private dark: boolean = false;
  onLinkClick: (target: string) => void = (_target: string): void => {};
  @State private mathHtml: string = '';
  @State private mathFailed: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private linkProxy: CodexMathLinkProxy = new CodexMathLinkProxy();
  private linkTargets: string[] = [];
  private pageReady: boolean = false;
  private revision: number = 0;

  aboutToAppear(): void {
    this.linkProxy.onOpen = (index: number, revision: number): void => {
      if (this.pageReady && revision === this.revision && Number.isInteger(index) &&
        index >= 0 && index < this.linkTargets.length) {
        this.onLinkClick(this.linkTargets[index]);
      }
    };
    this.refreshContent();
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.revision++;
  }

  private refreshContent(): void {
    const doc = buildCodexMathDocument(this.text);
    this.linkTargets = doc?.links ?? [];
    this.mathHtml = doc?.html ?? '';
    if (!this.mathHtml) { this.pageReady = false; }
    this.updatePage();
  }

  private updatePage(): void {
    const revision = ++this.revision;
    if (!this.pageReady || !this.mathHtml) { return; }
    const html = JSON.stringify(this.mathHtml);
    this.controller.runJavaScript('window.renderCodexMath(' + html + ',' + revision.toString() + ',' +
      (this.dark ? 'true' : 'false') + ')').catch((): void => {
      if (this.pageReady && revision === this.revision) { this.useNativeFallback(); }
    });
  }

  private useNativeFallback(): void {
    this.pageReady = false;
    this.mathFailed = true;
  }

  build() {
    if (this.mathHtml && !this.mathFailed) {
      Web({ src: $rawfile('codex_math/index.html'), controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
        .width('100%').backgroundColor(Color.Transparent)
        .layoutMode(WebLayoutMode.FIT_CONTENT).overScrollMode(OverScrollMode.NEVER)
        .keyboardAvoidMode(WebKeyboardAvoidMode.RESIZE_CONTENT)
        .javaScriptAccess(true).fileAccess(false).blockNetwork(true)
        .javaScriptProxy({ object: this.linkProxy, name: 'codexMathLinks', methodList: ['open'], controller: this.controller })
        .onPageEnd((): void => { this.pageReady = true; this.updatePage(); })
        .onErrorReceive((event): void => {
          if (event.request.isMainFrame()) { this.useNativeFallback(); }
        })
        .onRenderExited((): void => { this.useNativeFallback(); })
    } else {
      MarkdownView({ text: this.text, variant: 'chat_assistant', onLinkClick: this.onLinkClick })
    }
  }
}
