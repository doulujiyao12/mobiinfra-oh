import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { AppTheme } from '../../utils/AppTheme';
import { AiServiceAccess } from '../../utils/AiServiceAccess';
import { RecordingRecord, recordingTime } from '../../utils/recording/RecordingTypes';
import { ClassroomPhoto, CLASSROOM_TASK, classroomOwner } from '../../utils/recording/ClassroomMaterials';
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
  @Prop working: boolean = false;
  @Prop @Watch('reloadPhotos') photoRevision: number = 0;
  @Prop needsTranscript: boolean = false;
  @Prop canPrepare: boolean = false;
  onPrepare: () => void = (): void => {};
  @State private photos: ClassroomPhoto[] = [];
  @State private excluded: string[] = [];
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
      this.runIds = fs.listFileSync(this.directory).filter((name: string): boolean => /^run-\d+-[\da-f-]{32,36}$/.test(name))
        .sort().reverse().map((name: string): string => name.substring(name.indexOf('-', 4) + 1));
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
    if (this.working || this.sending || !this.ready || !this.canStart) { return; }
    const record = this.getRecord();
    if (!record) { return; }
    this.sending = true; this.error = '';
    let created = false;
    try {
      AiServiceAccess.requireAllowed();
      const photos = this.photos.filter((photo: ClassroomPhoto): boolean => !this.excluded.includes(photo.name));
      const context = this.context();
      const description = record.title + '\n完整转写、课堂摘要、' + photos.length + ' 张照片。原始音频保留在手机上。';
      const service = CodexChatService.get(context.filesDir);
      const result = await service.execute({ task: CLASSROOM_TASK, continueRunId: '' }, {
        sessionId: classroomOwner(record.id), imagePaths: [],
        selectTarget: async (): Promise<CodexChatTarget | null> =>
          await pickCodexChatTarget(this.getUIContext(), description, 0, false, true),
        isCancelled: (): boolean => (!this.alive && !created) || !AiServiceAccess.isAllowed(),
        uploadMaterials: async (upload: (name: string, data: string) => Promise<string>): Promise<string[]> =>
          await uploadClassroomPack(context.cacheDir, this.directory, record, photos, upload),
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
        Text(this.ready ? '课堂笔记、知识要点、模拟试题 · Word' : '完成转写和摘要后，可生成三份 Word 学习资料。')
          .fontSize(14).fontColor(AppTheme.text('#737D90')).width('100%')
        Button(!this.ready ? (this.needsTranscript ? '转写并生成摘要' : '生成课堂摘要') :
          this.sending ? '正在委托 Codex' : this.runIds.length ? '重新生成学习资料' : '用 Codex 生成学习资料')
          .height(42).width('100%').fontSize(15).fontColor(Color.White).backgroundColor(AppTheme.filledBackground('#316B69'))
          .enabled(!this.working && !this.sending && (this.ready ? this.canStart : this.canPrepare))
          .onClick((): void => { if (this.ready) { this.send(); } else { this.onPrepare(); } })
        if (this.deliveryNotice) { Text(this.deliveryNotice).fontSize(13).fontColor(AppTheme.text('#737D90')).width('100%') }
        if (this.error) { Text(this.error).fontSize(13).fontColor(AppTheme.text('#B74D49')).width('100%') }
      }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(18).backgroundColor(AppTheme.background('#FFFFFF'))
      ForEach(this.runIds, (id: string) => { CodexChatRunCard({ runId: id }) }, (id: string): string => id)
    }.width('100%')
  }
}
