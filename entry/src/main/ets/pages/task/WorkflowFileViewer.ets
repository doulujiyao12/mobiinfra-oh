import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { JsonMap } from '../../datamanager/DataManagerTypes';
import { MarkdownView } from '../../components/MarkdownView';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import { WorkflowStorage } from '../../utils/WorkflowStorage';
import { WorkflowManagedFile } from '../../utils/WorkflowTypes';
import { showToastSafely } from '../../utils/PromptSafe';

@Entry
@Component
struct WorkflowFileViewer {
  @State category: string = 'daily';
  @State title: string = '日志文件';
  @State files: WorkflowManagedFile[] = [];
  @State selectedPath: string = '';
  @State selectedName: string = '';
  @State fileText: string = '正在加载...';
  // 文件列表默认收起，避免大量历史文件占满首屏并挤压当前文件详情。
  @State fileListExpanded: boolean = false;
  @State currentInfoExpanded: boolean = true;
  @State manageMode: boolean = false;
  @State selectedDeletePaths: string[] = [];
  @State previewMode: boolean = true;

  private filesDir: string = '';

  aboutToAppear(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    this.filesDir = ctx.filesDir;
    this.readParams();
    this.loadFiles();
  }

  private readParams(): void {
    let params = router.getParams() as JsonMap;
    if (!params) {
      return;
    }
    let rawCategory = params['category'];
    if (rawCategory !== null && rawCategory !== undefined) {
      let next = String(rawCategory);
      if (next === 'config' || next === 'daily' || next === 'run') {
        this.category = next;
      }
    }
  }

  private loadFiles(): void {
    this.title = this.categoryTitle(this.category);
    if (this.category === 'config') {
      this.files = WorkflowStorage.listConfigFiles(this.filesDir);
    } else if (this.category === 'run') {
      this.files = WorkflowStorage.listRunFiles(this.filesDir);
    } else {
      this.files = WorkflowStorage.listDailyLogFiles(this.filesDir);
    }
    this.pruneSelectedDeletePaths();
    this.selectCurrentOrFirst();
  }

  private switchCategory(category: string): void {
    if (this.category === category) {
      return;
    }
    this.category = category;
    this.selectedPath = '';
    this.selectedName = '';
    this.manageMode = false;
    this.fileListExpanded = false;
    this.selectedDeletePaths = [];
    this.loadFiles();
  }

  private selectCurrentOrFirst(): void {
    let selected: WorkflowManagedFile | null = null;
    for (let i = 0; i < this.files.length; i++) {
      if (this.files[i].path === this.selectedPath) {
        selected = this.files[i];
        break;
      }
    }
    if (selected === null && this.files.length > 0) {
      selected = this.files[0];
    }
    if (selected !== null) {
      this.openManagedFile(selected);
    } else {
      this.selectedPath = '';
      this.selectedName = '';
      this.fileText = this.emptyText(this.category);
      this.previewMode = false;
    }
  }

  private openManagedFile(file: WorkflowManagedFile): void {
    this.selectedPath = file.path;
    this.selectedName = file.name;
    this.previewMode = this.defaultPreviewMode(file);
    try {
      this.fileText = WorkflowStorage.readText(file.path);
    } catch (e) {
      let err = e as Error;
      this.fileText = '读取失败：' + (err.message || String(e));
    }
  }

  private categoryTitle(category: string): string {
    if (category === 'config') {
      return '配置文件';
    }
    if (category === 'run') {
      return '运行文件';
    }
    return '日志文件';
  }

  private containsAiGeneratedContent(): boolean {
    return this.category === 'daily' || this.category === 'run';
  }

  private emptyText(category: string): string {
    if (category === 'config') {
      return '暂无 workflow 配置文件';
    }
    if (category === 'run') {
      return '暂无运行文件';
    }
    return '暂无 daily-log 文件';
  }

  private defaultPreviewMode(file: WorkflowManagedFile): boolean {
    // daily-log 与 Markdown 文件优先给用户可读预览；配置 JSON 和运行输出保持原文优先，避免隐藏结构化字段。
    let lowerName = file.name.toLowerCase();
    if (this.category === 'daily') {
      return true;
    }
    return lowerName.endsWith('.md') || lowerName.endsWith('.markdown');
  }

  private setPreviewMode(enabled: boolean): void {
    this.previewMode = enabled;
  }

  private fileDisplayTitle(file: WorkflowManagedFile): string {
    let index = file.name.lastIndexOf('/');
    if (index >= 0 && index < file.name.length - 1) {
      return file.name.substring(index + 1);
    }
    return file.name;
  }

  private selectedDisplayTitle(): string {
    if (this.selectedName.length === 0) {
      return this.emptyText(this.category);
    }
    let index = this.selectedName.lastIndexOf('/');
    if (index >= 0 && index < this.selectedName.length - 1) {
      return this.selectedName.substring(index + 1);
    }
    return this.selectedName;
  }

  private fileDisplayMeta(file: WorkflowManagedFile): string {
    let index = file.name.lastIndexOf('/');
    let parent = index > 0 ? file.name.substring(0, index) : '根目录';
    return parent + ' · ' + WorkflowStorage.formatSize(file.size) + ' · ' + this.formatModifiedTime(file.modifiedTime);
  }

  private formatModifiedTime(seconds: number): string {
    if (seconds <= 0) {
      return '未知时间';
    }
    return new Date(seconds * 1000).toLocaleString();
  }

  private toggleFileListExpanded(): void {
    this.fileListExpanded = !this.fileListExpanded;
    if (!this.fileListExpanded) {
      this.manageMode = false;
      this.selectedDeletePaths = [];
    }
  }

  private setManageMode(enabled: boolean): void {
    this.manageMode = enabled;
    if (!enabled) {
      this.selectedDeletePaths = [];
    } else if (!this.fileListExpanded) {
      this.fileListExpanded = true;
    }
  }

  private isFileSelected(file: WorkflowManagedFile): boolean {
    for (let i = 0; i < this.selectedDeletePaths.length; i++) {
      if (this.selectedDeletePaths[i] === file.path) {
        return true;
      }
    }
    return false;
  }

  private setFileSelected(file: WorkflowManagedFile, selected: boolean): void {
    let next: string[] = [];
    let found = false;
    for (let i = 0; i < this.selectedDeletePaths.length; i++) {
      if (this.selectedDeletePaths[i] === file.path) {
        found = true;
        if (!selected) {
          continue;
        }
      }
      next.push(this.selectedDeletePaths[i]);
    }
    if (selected && !found) {
      next.push(file.path);
    }
    this.selectedDeletePaths = next;
  }

  private selectedDeleteCount(): number {
    return this.selectedDeletePaths.length;
  }

  private selectAllFiles(): void {
    let next: string[] = [];
    for (let i = 0; i < this.files.length; i++) {
      next.push(this.files[i].path);
    }
    this.selectedDeletePaths = next;
  }

  private selectedManagedFiles(): WorkflowManagedFile[] {
    let selected: WorkflowManagedFile[] = [];
    for (let i = 0; i < this.files.length; i++) {
      if (this.isFileSelected(this.files[i])) {
        selected.push(this.files[i]);
      }
    }
    return selected;
  }

  private pruneSelectedDeletePaths(): void {
    if (this.selectedDeletePaths.length === 0) {
      return;
    }
    let next: string[] = [];
    for (let i = 0; i < this.files.length; i++) {
      if (this.isFileSelected(this.files[i])) {
        next.push(this.files[i].path);
      }
    }
    this.selectedDeletePaths = next;
  }

  private deleteManagedFile(file: WorkflowManagedFile): void {
    let title = this.fileDisplayTitle(file);
    let deleted = WorkflowStorage.deleteManagedFileForCategory(this.filesDir, this.category, file);
    this.setFileSelected(file, false);
    this.loadFiles();
    showToastSafely(deleted > 0 ? '已删除：' + title : '删除失败：' + title, 1500);
  }

  private deleteSelectedFiles(): void {
    let selected = this.selectedManagedFiles();
    if (selected.length === 0) {
      showToastSafely('请先选择文件', 1200);
      return;
    }
    promptAction.showDialog({
      title: '删除选中文件',
      message: this.deleteSelectedMessage(selected.length),
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '删除', color: '#FF4D4F' }
      ]
    }).then((data: promptAction.ShowDialogSuccessResponse) => {
      if (data.index === 1) {
        let deleted = WorkflowStorage.deleteManagedFilesForCategory(this.filesDir, this.category, selected);
        this.manageMode = false;
        this.selectedDeletePaths = [];
        this.loadFiles();
        showToastSafely('已删除文件：' + deleted, 1500);
      }
    }).catch(() => {});
  }

  private deleteSelectedMessage(count: number): string {
    if (this.category === 'run') {
      return '将删除当前分类中选中的 ' + count + ' 个运行记录，并清除对应运行目录中的步骤输出文件。';
    }
    if (this.category === 'daily') {
      return '将删除当前分类中选中的 ' + count + ' 个 daily-log 文件，并清理删除后为空的日期目录。';
    }
    return '将删除当前分类中选中的 ' + count + ' 个文件。';
  }

  @Builder CategoryTab(category: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.category === category ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.category === category ? Color.White : '#5E6675')
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .backgroundColor(this.category === category ? '#5968FF' : '#F3F5FA')
      .borderRadius(12)
      .onClick(() => { this.switchCategory(category); })
  }

  @Builder ManagedFileRow(file: WorkflowManagedFile) {
    Row() {
      if (this.manageMode) {
        Checkbox({ name: file.path, group: 'workflowFiles' })
          .select(this.isFileSelected(file))
          .selectedColor('#5968FF')
          .margin({ right: 10 })
          .onChange((checked: boolean) => { this.setFileSelected(file, checked); })
      }
      Column() {
        Text(this.fileDisplayTitle(file))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.selectedPath === file.path ? '#4F46E5' : '#202637')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.fileDisplayMeta(file))
          .fontSize(11)
          .fontColor('#7B8290')
          .margin({ top: 6 })
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (!this.manageMode) {
        Text('查看')
          .fontSize(12)
          .fontColor(this.selectedPath === file.path ? '#4F46E5' : '#7B8290')
          .margin({ left: 10 })
      }
    }
    .width('100%')
    .padding(13)
    .backgroundColor(this.selectedPath === file.path ? '#EEF4FF' : '#FFFFFF')
    .borderRadius(14)
    .onClick(() => {
      if (this.manageMode) {
        this.setFileSelected(file, !this.isFileSelected(file));
      } else {
        this.openManagedFile(file);
      }
    })
  }

  @Builder SwipeSelectAction(file: WorkflowManagedFile) {
    Button(this.isFileSelected(file) ? '取消' : '选择')
      .width(58)
      .height('100%')
      .fontSize(12)
      .backgroundColor('#5968FF')
      .borderRadius(12)
      .onClick(() => {
        this.setManageMode(true);
        this.setFileSelected(file, !this.isFileSelected(file));
      })
  }

  @Builder SwipeDeleteAction(file: WorkflowManagedFile) {
    Button('删除')
      .width(58)
      .height('100%')
      .fontSize(12)
      .backgroundColor('#FF5A4F')
      .borderRadius(12)
      .onClick(() => { this.deleteManagedFile(file); })
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .width(70)
          .height(34)
          .fontSize(12)
          .fontColor('#5968FF')
          .backgroundColor('#EEF4FF')
          .borderRadius(12)
          .onClick(() => { router.back(); })
        Text(this.title)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Button('刷新')
          .width(70)
          .height(34)
          .fontSize(12)
          .backgroundColor('#607D8B')
          .borderRadius(12)
          .onClick(() => { this.loadFiles(); })
      }
      .width('100%')
      .padding({ left: 22, right: 22, top: 26, bottom: 10 })

      Row() {
        this.CategoryTab('config', '配置')
        Blank().width(8)
        this.CategoryTab('daily', '日志')
        Blank().width(8)
        this.CategoryTab('run', '运行')
      }
      .width('86%')
      .padding(6)
      .backgroundColor(Color.White)
      .borderRadius(18)
      .margin({ top: 8 })

      Column() {
        Row() {
          Text('文件列表 · ' + this.files.length + ' 个')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .layoutWeight(1)
          if (this.files.length > 0) {
            Button(this.manageMode ? '完成' : '管理')
              .width(58)
              .height(30)
              .fontSize(12)
              .fontColor(this.manageMode ? Color.White : '#5968FF')
              .backgroundColor(this.manageMode ? '#5968FF' : '#EEF4FF')
              .borderRadius(10)
              .margin({ right: 8 })
              .onClick(() => { this.setManageMode(!this.manageMode); })
          }
          Button(this.fileListExpanded ? '收起' : '展开')
            .width(58)
            .height(30)
            .fontSize(12)
            .fontColor('#5968FF')
            .backgroundColor('#F3F5FA')
            .borderRadius(10)
            .onClick(() => { this.toggleFileListExpanded(); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (this.fileListExpanded && this.files.length > 0) {
          List() {
            ForEach(this.files, (file: WorkflowManagedFile) => {
              ListItem() {
                this.ManagedFileRow(file)
              }
              .margin({ bottom: 8 })
              .swipeAction({
                start: {
                  builder: () => { this.SwipeSelectAction(file); },
                  actionAreaDistance: 58
                },
                end: {
                  builder: () => { this.SwipeDeleteAction(file); },
                  actionAreaDistance: 58
                },
                edgeEffect: SwipeEdgeEffect.Spring
              })
            }, (file: WorkflowManagedFile) => file.path)
          }
          .width('100%')
          .height(220)
          .margin({ top: 12 })
          if (this.manageMode) {
            Row() {
              Text('已选 ' + this.selectedDeleteCount() + ' 个')
                .fontSize(12)
                .fontColor('#6F7584')
                .layoutWeight(1)
              Button('全选')
                .width(54)
                .height(30)
                .fontSize(12)
                .fontColor('#5968FF')
                .backgroundColor('#EEF4FF')
                .borderRadius(10)
                .onClick(() => { this.selectAllFiles(); })
              Button('清空')
                .width(54)
                .height(30)
                .fontSize(12)
                .fontColor('#5968FF')
                .backgroundColor('#F3F5FA')
                .borderRadius(10)
                .margin({ left: 8 })
                .onClick(() => { this.selectedDeletePaths = []; })
              Button('删除')
                .width(54)
                .height(30)
                .fontSize(12)
                .backgroundColor('#FF5A4F')
                .borderRadius(10)
                .margin({ left: 8 })
                .onClick(() => { this.deleteSelectedFiles(); })
            }
            .width('100%')
            .margin({ top: 8 })
          }
        } else if (this.fileListExpanded) {
          Text(this.fileText)
            .fontSize(13)
            .fontColor('#7B8290')
            .margin({ top: 16 })
            .width('100%')
        } else {
          Text(this.selectedName.length > 0 ? '当前：' + this.selectedName : this.emptyText(this.category))
            .fontSize(13)
            .fontColor('#7B8290')
            .margin({ top: 12 })
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('86%')
      .padding(18)
      .backgroundColor(Color.White)
      .borderRadius(20)
      .margin({ top: 14 })

      Column() {
        Row() {
          Text('当前文件')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .layoutWeight(1)
          if (this.containsAiGeneratedContent()) {
            AiGeneratedBadge({ compact: true })
              .margin({ right: 8 })
          }
          if (this.selectedName.length > 0) {
            Button('预览')
              .width(62)
              .height(30)
              .fontSize(12)
              .fontColor(this.previewMode ? Color.White : '#5968FF')
              .backgroundColor(this.previewMode ? '#5968FF' : '#F3F5FA')
              .borderRadius(10)
              .margin({ right: 8 })
              .onClick(() => { this.setPreviewMode(true); })
            Button('原文')
              .width(62)
              .height(30)
              .fontSize(12)
              .fontColor(!this.previewMode ? Color.White : '#5968FF')
              .backgroundColor(!this.previewMode ? '#5968FF' : '#F3F5FA')
              .borderRadius(10)
              .margin({ right: 8 })
              .onClick(() => { this.setPreviewMode(false); })
          }
          Button(this.currentInfoExpanded ? '收起' : '展开')
            .width(58)
            .height(30)
            .fontSize(12)
            .fontColor('#5968FF')
            .backgroundColor('#F3F5FA')
            .borderRadius(10)
            .onClick(() => { this.currentInfoExpanded = !this.currentInfoExpanded; })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (this.currentInfoExpanded) {
          Column({ space: 6 }) {
            Row() {
              Text('文件')
                .fontSize(11)
                .fontColor('#8A91A0')
                .width(34)
              Text(this.selectedDisplayTitle())
                .fontSize(12)
                .fontColor('#3C4354')
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)

            Row() {
              Text('路径')
                .fontSize(11)
                .fontColor('#8A91A0')
                .width(34)
              Text(this.selectedName.length > 0 ? this.selectedName : this.emptyText(this.category))
                .fontSize(12)
                .fontColor('#6F7584')
                .layoutWeight(1)
                .maxLines(4)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
            .margin({ top: 8 })
            .width('100%')
        }
        Scroll() {
          if (this.previewMode && this.selectedName.length > 0) {
            MarkdownView({ text: this.fileText, variant: 'file_preview' })
          } else {
            Text(this.fileText)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor('#2F3645')
              .width('100%')
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding(12)
        .backgroundColor('#F7F9FE')
        .borderRadius(14)
        .margin({ top: this.currentInfoExpanded ? 10 : 8 })
      }
      .width('86%')
      .layoutWeight(1)
      .padding(18)
      .backgroundColor(Color.White)
      .borderRadius(20)
      .margin({ top: 14, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F8FF')
  }
}
