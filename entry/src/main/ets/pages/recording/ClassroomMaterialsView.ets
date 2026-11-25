import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { AppTheme } from '../../utils/AppTheme';
import { AiServiceAccess } from '../../utils/AiServiceAccess';
import { RecordingRecord, recordingTime } from '../../utils/recording/RecordingTypes';
import { CLASSROOM_DOCUMENT_LIMIT, ClassroomDocument, ClassroomPhoto, CLASSROOM_TASK, classroomOwner,
  classroomText } from '../../utils/recording/ClassroomMaterials';
import { CLASSROOM_FILE_FILTER, ClassroomDocuments } from '../../utils/recording/ClassroomDocuments';
import { classroomPhotos, uploadClassroomPack } from '../../utils/recording/ClassroomFiles';
import { CodexChatRunCard } from '../codex/CodexChatRunCard';
import { CodexChatService } from '../codex/CodexChatService';
import { CodexChatRun, CodexChatTarget } from '../codex/CodexChatTypes';
import { pickCodexChatTarget } from '../codex/CodexChatTargetPicker';

@Component
export struct ClassroomPhotoStrip {
  @Prop photos: ClassroomPhoto[] = [];
  @Prop excluded: string[] = [];
  directory: string = '';
  selectable: boolean = false;
  onToggle: (name: string) => void = (): void => {};
  @State private previewName: string = '';
  @State private previewOpen: boolean = false;
  @Builder private Preview() {
    Column({ space: 12 }) {
      if (this.previewName) {
        Image(fileUri.getUriFromPath(this.directory + '/' + this.previewName))
          .width('100%').layoutWeight(1).objectFit(ImageFit.Contain)
        if (this.selectable) {
          Button(this.excluded.includes(this.previewName) ? '加入本次资料' : '从本次资料移除').height(42)
            .onClick((): void => { this.onToggle(this.previewName); this.previewOpen = false; })
        }
      }
    }.width('100%').height('100%').padding({ left: 12, right: 12, top: 44, bottom: 16 })
  }
  build() {
    Scroll() {
      Row({ space: 9 }) {
        ForEach(this.photos, (photo: ClassroomPhoto) => {
          Stack({ alignContent: Alignment.TopEnd }) {
            Button({ type: ButtonType.Normal }) {
              Stack({ alignContent: Alignment.BottomStart }) {
                Image(fileUri.getUriFromPath(this.directory + '/' + photo.name)).width(106).height(76)
                  .sourceSize({ width: 300, height: 220 }).objectFit(ImageFit.Cover)
                  .opacity(this.excluded.includes(photo.name) ? 0.5 : 1)
                Row({ space: 4 }) {
                  Text(recordingTime(photo.seconds)).fontSize(11).fontColor(Color.White)
                }.padding({ left: 6, right: 6, top: 2, bottom: 2 }).backgroundColor('#99000000').borderRadius(8).margin(5)
              }
            }.padding(0).borderRadius(12).clip(true).backgroundColor(AppTheme.background('#EDEFF5'))
              .accessibilityText('查看 ' + recordingTime(photo.seconds) + ' 课堂照片')
              .onClick((): void => { this.previewName = photo.name; this.previewOpen = true; })
            if (this.selectable) {
              Button(this.excluded.includes(photo.name) ? '○' : '✓').fontSize(14).width(32).height(32).padding(0)
                .backgroundColor(this.excluded.includes(photo.name) ? '#99000000' : '#316B69').fontColor(Color.White)
                .accessibilityText(this.excluded.includes(photo.name) ? '加入本次资料' : '从本次资料移除')
                .onClick((): void => { this.onToggle(photo.name); })
            }
          }
        }, (photo: ClassroomPhoto): string => photo.name)
      }
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      .bindSheet(this.previewOpen, this.Preview(), { height: SheetSize.LARGE, showClose: true,
        onDisappear: (): void => { this.previewOpen = false; } })
  }
}

@Component
export struct ClassroomMaterialsView {
  directory: string = '';
  getRecord: () => RecordingRecord | null = (): RecordingRecord | null => null;
  @Prop ready: boolean = false;
  @Prop courseTitle: string = '';
  @Prop noteAvailable: boolean = false;
  @Prop working: boolean = false;
  @Prop @Watch('reloadPhotos') photoRevision: number = 0;
  @Prop needsTranscript: boolean = false;
  @Prop canPrepare: boolean = false;
  onPrepare: () => void = (): void => {};
  @State private photos: ClassroomPhoto[] = [];
  @State private excluded: string[] = [];
  @State private documents: ClassroomDocument[] = [];
  @State private excludedDocuments: string[] = [];
  @State private importing: boolean = false;
  @State private runIds: string[] = [];
  @State private sending: boolean = false;
  @State private error: string = '';
  @StorageProp('codexChatRevision') @Watch('refreshRun') private revision: number = 0;
  @State private canStart: boolean = true;
  @State private deliveryNotice: string = '';
  private alive: boolean = true;
  aboutToAppear(): void {
    this.alive = true;
    try {
      this.reloadPhotos();
      this.documents = new ClassroomDocuments(this.directory).list();
      if (fs.accessSync(this.directory)) {
        this.runIds = fs.listFileSync(this.directory).filter((name: string): boolean => /^run-\d+-[\da-f-]{32,36}$/.test(name))
          .sort().reverse().map((name: string): string => name.substring(name.indexOf('-', 4) + 1));
      }
      this.refreshRun();
    } catch (e) { this.error = (e as Error).message; }
  }
  private reloadPhotos(): void {
    if (!this.alive || !this.directory) { return; }
    try { this.photos = classroomPhotos(this.directory); }
    catch (e) { this.error = (e as Error).message; }
  }
  aboutToDisappear(): void { this.alive = false; }

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private hasMaterials(): boolean {
    return this.ready || this.noteAvailable || this.documents.length > this.excludedDocuments.length ||
      this.photos.length > this.excluded.length;
  }
  private async addDocuments(): Promise<void> {
    if (this.working || this.sending || this.importing || this.documents.length >= CLASSROOM_DOCUMENT_LIMIT) { return; }
    this.importing = true; this.error = '';
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = Math.min(6, CLASSROOM_DOCUMENT_LIMIT - this.documents.length);
      options.fileSuffixFilters = [CLASSROOM_FILE_FILTER];
      const uris = await new picker.DocumentViewPicker(this.context()).select(options);
      const store = new ClassroomDocuments(this.directory);
      for (const uri of uris) {
        if (!this.alive) { return; }
        const next = await store.add(uri);
        if (this.alive) { this.documents = next; }
      }
    } catch (e) { if (this.alive) { this.error = (e as Error).message || '课堂附件添加失败'; } }
    finally { if (this.alive) { this.importing = false; } }
  }
  private removeDocument(id: string): void {
    if (this.working || this.sending || this.importing) { return; }
    try {
      this.documents = new ClassroomDocuments(this.directory).remove(id);
      this.excludedDocuments = this.excludedDocuments.filter((item: string): boolean => item !== id);
      this.error = '';
    } catch (e) { this.error = (e as Error).message; }
  }
  private refreshRun(): void {
    if (!this.runIds.length || !this.alive) { return; }
    try {
      const service = CodexChatService.get(this.context().filesDir);
      const run = service.load(this.runIds[0]);
      this.canStart = !service.isActive(this.runIds[0]) && (!run || ['failed', 'cancelled'].includes(run.status) ||
        (run.status === 'completed' && run.artifacts.length === run.files.length) ||
        (!run.submitted && run.status === 'starting'));
      this.deliveryNotice = run?.status === 'completed' &&
        run.artifacts.filter(file => /\.docx$/i.test(file.name)).length < 3 ? '本次返回的 Word 文件不足三份，可查看结果后重新生成。' : '';
    } catch (e) { this.canStart = false; this.error = (e as Error).message; }
  }
  private async send(): Promise<void> {
    if (this.working || this.sending || this.importing || !this.hasMaterials() || !this.canStart) { return; }
    const record = this.getRecord();
    if (!record) { return; }
    this.sending = true; this.error = '';
    let created = false;
    try {
      AiServiceAccess.requireAllowed();
      const photos = this.photos.filter((photo: ClassroomPhoto): boolean => !this.excluded.includes(photo.name));
      const documents = this.documents.filter((doc: ClassroomDocument): boolean => !this.excludedDocuments.includes(doc.id));
      const material = classroomText(record, photos, documents, this.courseTitle);
      const context = this.context();
      const description = record.title + '\n会发送本节课已有的笔记、完整转写和摘要，以及选中的 ' +
        photos.length + ' 张照片、' + documents.length + ' 份参考文件。原始音频保留在手机上。' +
        (documents.length ? '\n' + documents.slice(0, 3).map((doc: ClassroomDocument): string => doc.name).join('、') +
          (documents.length > 3 ? ' 等' : '') : '');
      if (!fs.accessSync(this.directory)) { fs.mkdirSync(this.directory, true); }
      const service = CodexChatService.get(context.filesDir);
      const result = await service.execute({ task: CLASSROOM_TASK, continueRunId: '' }, {
        sessionId: classroomOwner(record.id), imagePaths: [],
        selectTarget: async (): Promise<CodexChatTarget | null> =>
          await pickCodexChatTarget(this.getUIContext(), description, 0, false, true),
        isCancelled: (): boolean => (!this.alive && !created) || !AiServiceAccess.isAllowed(),
        uploadMaterials: async (upload: (name: string, data: string) => Promise<string>, report: (notice: string) => void): Promise<string[]> =>
          await uploadClassroomPack(context.cacheDir, this.directory, material, photos, documents, upload, report),
        onCreated: (run: CodexChatRun): void => {
          const marker = this.directory + '/run-' + run.createdAt + '-' + run.id;
          fs.closeSync(fs.openSync(marker, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY));
          created = true;
          if (this.alive) { this.runIds = [run.id].concat(this.runIds); this.canStart = false; }
        }
      });
      if (this.alive && !result.ok && result.status !== 'rejected') { this.error = result.error; }
    } catch (e) { if (this.alive) { this.error = (e as Error).message || '课堂资料发送失败'; } }
    finally { if (this.alive) { this.sending = false; this.refreshRun(); } }
  }
  @Builder private DocumentRows() {
    Row({ space: 8 }) {
      Text('参考文件').fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
      if (this.documents.length) {
        Text('已选 ' + (this.documents.length - this.excludedDocuments.length) + '/' + this.documents.length)
          .fontSize(12).fontColor(AppTheme.text('#737D90')).maxLines(1)
      }
      Blank()
      Button(this.importing ? '正在保存…' : '+ 添加文件').fontSize(14).height(38).padding({ left: 10, right: 10 })
        .backgroundColor(AppTheme.background('#E7F2EF')).fontColor(AppTheme.text('#316B69'))
        .enabled(!this.working && !this.sending && !this.importing && this.documents.length < CLASSROOM_DOCUMENT_LIMIT)
        .onClick((): void => { this.addDocuments(); })
    }.width('100%')
    if (!this.documents.length) {
      Text('可加入 PPT、PDF 等课件。选中的文件会随本节课发送。').fontSize(13).lineHeight(20)
        .fontColor(AppTheme.text('#737D90')).width('100%')
    }
    ForEach(this.documents, (doc: ClassroomDocument) => {
      Row({ space: 8 }) {
        Button(this.excludedDocuments.includes(doc.id) ? '○' : '✓').width(38).height(38).padding(0)
          .backgroundColor(AppTheme.background('#E7F2EF')).fontColor(AppTheme.text('#316B69'))
          .accessibilityText((this.excludedDocuments.includes(doc.id) ? '发送 ' : '本次不发送 ') + doc.name)
          .enabled(!this.sending && !this.importing)
          .onClick((): void => {
            this.excludedDocuments = this.excludedDocuments.includes(doc.id) ?
              this.excludedDocuments.filter((v: string): boolean => v !== doc.id) : this.excludedDocuments.concat([doc.id]);
          })
        Column({ space: 2 }) {
          Text(doc.name).fontSize(14).fontColor(AppTheme.text('#172033')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(doc.size >= 1024 * 1024 ? (doc.size / (1024 * 1024)).toFixed(1) + ' MiB' : Math.ceil(doc.size / 1024) + ' KiB')
            .fontSize(12).fontColor(AppTheme.text('#737D90'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button('移除').fontSize(13).height(36).padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent)
          .fontColor(AppTheme.text('#737D90')).enabled(!this.working && !this.sending && !this.importing)
          .onClick((): void => { this.removeDocument(doc.id); })
      }.width('100%')
    }, (doc: ClassroomDocument): string => doc.id)
  }
  build() {
    Column() {
      Column({ space: 12 }) {
        Row() {
          Text('课堂资料').fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
          Blank()
          if (this.photos.length) {
            Text('已选 ' + (this.photos.length - this.excluded.length) + '/' + this.photos.length + ' 张').fontSize(13)
              .fontColor(AppTheme.text('#737D90'))
          }
        }.width('100%')
        if (this.photos.length) {
          ClassroomPhotoStrip({ photos: this.photos, directory: this.directory, selectable: true, excluded: this.excluded,
            onToggle: (name: string): void => { this.excluded = this.excluded.includes(name) ?
              this.excluded.filter((v: string): boolean => v !== name) : this.excluded.concat([name]); } })
        }
        this.DocumentRows()
        Text('课堂笔记、知识要点、模拟试题 · Word')
          .fontSize(14).fontColor(AppTheme.text('#737D90')).width('100%')
        if (this.canPrepare) {
          Button(this.needsTranscript ? '先转写录音' : '先生成课堂摘要').height(38).width('100%').fontSize(14)
            .backgroundColor(AppTheme.background('#E7F2EF')).fontColor(AppTheme.text('#316B69'))
            .enabled(!this.working && !this.sending && !this.importing)
            .onClick((): void => { this.onPrepare(); })
        }
        Button(this.sending ? '正在委托 Codex' : this.runIds.length ? '重新生成学习资料' : '用 Codex 生成学习资料')
          .height(42).width('100%').fontSize(15).fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#316B69'))
          .enabled(!this.working && !this.sending && !this.importing && this.hasMaterials() && this.canStart)
          .onClick((): void => { this.send(); })
        if (this.deliveryNotice) { Text(this.deliveryNotice).fontSize(13).fontColor(AppTheme.text('#737D90')).width('100%') }
        if (this.error) { Text(this.error).fontSize(13).fontColor(AppTheme.text('#B74D49')).width('100%') }
      }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
      ForEach(this.runIds, (id: string) => { CodexChatRunCard({ runId: id }) }, (id: string): string => id)
    }.width('100%')
  }
}
