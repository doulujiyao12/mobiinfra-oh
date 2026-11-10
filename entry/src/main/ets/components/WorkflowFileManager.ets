import { AppTheme } from '../utils/AppTheme';
import { AppLogger } from '../utils/AppLogger';
import { WorkflowStorage } from '../utils/WorkflowStorage';
import { WorkflowCatalogStats, WorkflowFileCatalog } from '../utils/WorkflowFileCatalog';

@Component
export struct WorkflowFileManager {
  @Prop filesDir: string = '';
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @Prop @Watch('onBusyChanged') busy: boolean = false;
  onOpen: (category: string) => void = (): void => {};
  onDelete: (category: string) => void = (): void => {};
  @State private expanded: boolean = false;
  @State private loading: boolean = false;
  @State private loaded: boolean = false;
  @State private errorText: string = '';
  @State private stats: WorkflowCatalogStats = new WorkflowCatalogStats();
  private catalog: WorkflowFileCatalog | null = null;

  aboutToDisappear(): void { this.cancelScan(); }

  private cancelScan(): void {
    this.catalog?.cancel(); this.catalog = null; this.loading = false;
  }

  private onRevisionChanged(): void {
    this.cancelScan(); this.loaded = false;
    if (this.expanded && !this.busy) { this.loadStats(); }
  }

  private onBusyChanged(): void {
    if (this.busy) { this.cancelScan(); this.loaded = false; }
    else if (this.expanded && !this.loaded && !this.loading) { this.loadStats(); }
  }

  private async loadStats(): Promise<void> {
    if (this.busy || this.filesDir.length === 0) { return; }
    this.cancelScan();
    let catalog = new WorkflowFileCatalog();
    this.catalog = catalog; this.loading = true; this.errorText = '';
    try {
      let stats = await catalog.statistics(this.filesDir);
      if (this.catalog !== catalog) { return; }
      this.stats = stats; this.loaded = true;
    } catch (e) {
      if (this.catalog !== catalog) { return; }
      this.loaded = false; this.errorText = '文件统计未完成，请重试';
      AppLogger.warnCause('Workflow.Files', 'Statistics failed', e as Error);
    } finally {
      if (this.catalog === catalog) { this.loading = false; this.catalog = null; }
    }
  }

  private toggleExpanded(): void {
    this.expanded = !this.expanded;
    if (!this.expanded) { this.cancelScan(); }
    else if (!this.loaded) { this.loadStats(); }
  }

  private subtitle(label: string, count: number, bytes: number): string {
    return this.loaded ? label + ' · ' + count + ' 个 · ' + WorkflowStorage.formatSize(bytes) : label;
  }

  @Builder private CategoryRow(category: string, title: string, subtitle: string, color: string, background: string) {
    Row() {
      Column() {
        Text(title).fontSize(16).fontColor(AppTheme.text('#11182F')).width('100%')
        Text(subtitle).fontSize(12).fontColor(AppTheme.text('#6F7584')).margin({ top: 6 }).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button('查看').width(64).height(34).fontSize(12)
        .fontColor(AppTheme.text(Color.White)).backgroundColor(AppTheme.filledBackground(color))
        .borderRadius(10).margin({ left: 8 }).onClick((): void => { this.onOpen(category); })
      Button('清理').width(60).height(34).fontSize(12)
        .fontColor(AppTheme.text('#6F7584')).backgroundColor(AppTheme.background('#F3F5FA'))
        .borderRadius(10).margin({ left: 8 }).enabled(!this.busy)
        .onClick((): void => { this.onDelete(category); })
    }.width('100%').padding(14).backgroundColor(AppTheme.background(background)).borderRadius(14).margin({ top: 12 })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('Workflow 文件管理').fontSize(16).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#11182F'))
          Text(this.loading ? '正在统计…' : this.errorText ||
            (this.loaded ? '共 ' + WorkflowStorage.formatSize(this.stats.totalBytes) : '配置、采集日志与运行记录'))
            .fontSize(12).fontColor(AppTheme.text('#6F7584')).margin({ top: 7 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.expanded) {
          Button('刷新').height(34).fontSize(12).enabled(!this.loading && !this.busy)
            .fontColor(AppTheme.text('#276EF1')).backgroundColor(AppTheme.background('#EEF4FF'))
            .onClick((): void => { this.loadStats(); })
        }
        Button(this.expanded ? '收起' : '展开').height(34).fontSize(12).margin({ left: 8 })
          .fontColor(AppTheme.text('#6F7584')).backgroundColor(AppTheme.background('#F3F5FA'))
          .onClick((): void => { this.toggleExpanded(); })
      }.width('100%')
      if (this.expanded) {
        this.CategoryRow('config', '配置', this.subtitle('Workflow JSON', this.stats.configCount, this.stats.configBytes), '#276EF1', '#EEF4FF')
        this.CategoryRow('daily', '日志', this.subtitle('Daily Log', this.stats.dailyLogCount, this.stats.dailyLogBytes), '#148F73', '#EAF8F3')
        this.CategoryRow('run', '运行文件', this.subtitle('Run outputs', this.stats.runCount, this.stats.runBytes), '#C76800', '#FFF3E2')
      }
    }.width('86%').padding(18).backgroundColor(AppTheme.background(Color.White)).borderRadius(14).margin({ bottom: 18 })
  }
}
