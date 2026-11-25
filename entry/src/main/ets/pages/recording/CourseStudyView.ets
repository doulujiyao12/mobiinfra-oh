import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { filePreview } from '@kit.PreviewKit';
import { AppTheme } from '../../utils/AppTheme';
import { AiServiceAccess } from '../../utils/AiServiceAccess';
import { CLASSROOM_FILE_FILTER, ClassroomDocuments } from '../../utils/recording/ClassroomDocuments';
import { uploadStudyArchive } from '../../utils/recording/ClassroomFiles';
import { COURSE_EXAMS, COURSE_HANDOUTS, COURSE_STUDY_MODES, StudyGroup, StudySource, courseLibraryPath,
  courseRunIds, courseStudyGroups, courseStudyPack, courseStudyPrompt } from '../../utils/recording/CourseStudy';
import { RecordingRecord } from '../../utils/recording/RecordingTypes';
import { CodexChatRunCard } from '../codex/CodexChatRunCard';
import { CodexChatService } from '../codex/CodexChatService';
import { CodexChatRun, CodexChatTarget } from '../codex/CodexChatTypes';
import { pickCodexChatTarget } from '../codex/CodexChatTargetPicker';

@Component
export struct CourseStudyView {
  root: string = '';
  courseId: string = '';
  @Prop courseTitle: string = '';
  @Link section: string;
  scroller: Scroller = new Scroller();
  getLessons: (fresh: boolean) => RecordingRecord[] = (fresh: boolean): RecordingRecord[] => [];
  onLesson: (id: string) => void = (): void => {};
  @State private groups: StudyGroup[] = [];
  @Link selected: string[];
  @State private expanded: string[] = [COURSE_EXAMS, COURSE_HANDOUTS];
  @Link mode: string;
  @Link instruction: string;
  @State private importing: boolean = false;
  @State private sending: boolean = false;
  @State private binding: boolean = false;
  @State private bindId: string = '';
  @State private error: string = '';
  @State private runIds: string[] = [];
  @State private currentRun: string = '';
  @State private canStart: boolean = true;
  @StorageProp('codexChatRevision') @Watch('refreshRun') private revision: number = 0;
  private alive: boolean = true;

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private library(): string { return courseLibraryPath(this.root, this.courseId); }
  private store(group: string): ClassroomDocuments {
    if (group !== COURSE_EXAMS && group !== COURSE_HANDOUTS) { throw new Error('请选择课程资料栏目'); }
    return new ClassroomDocuments(this.library() + '/' + group, true);
  }
  aboutToAppear(): void {
    this.alive = true;
    try { this.reload(); this.runIds = courseRunIds(this.library()); this.refreshRun(); }
    catch (e) { this.error = (e as Error).message; }
  }
  aboutToDisappear(): void { this.alive = false; }
  private reload(): void {
    this.groups = courseStudyGroups(this.root, this.courseId, this.getLessons(false));
    this.selected = this.selected.filter((key: string): boolean =>
      this.groups.some((g: StudyGroup): boolean => g.sources.some((s: StudySource): boolean => s.key === key)));
  }
  private refreshRun(): void {
    if (!this.alive || !this.runIds.length) { return; }
    try {
      const service = CodexChatService.get(this.context().filesDir);
      const id = this.runIds[0];
      const run = service.load(id);
      this.canStart = !service.isActive(id) && (!run || !run.submitted || ['failed', 'cancelled'].includes(run.status) ||
        (run.status === 'completed' && run.files.length === run.artifacts.length));
      if (!this.canStart) { this.currentRun = id; }
    } catch (e) { this.error = (e as Error).message; this.canStart = false; }
  }
  private async importFiles(): Promise<void> {
    if (this.importing || this.sending) { return; }
    this.importing = true; this.error = '';
    try {
      const store = this.store(this.section);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 6; options.fileSuffixFilters = [CLASSROOM_FILE_FILTER];
      const uris = await new picker.DocumentViewPicker(this.context()).select(options);
      for (const uri of uris) {
        if (!this.alive) { break; }
        await store.add(uri);
      }
    } catch (e) { if (this.alive) { this.error = (e as Error).message || '资料导入失败'; } }
    finally {
      if (this.alive) {
        this.importing = false;
        try { this.reload(); } catch (e) { this.error = (e as Error).message; }
      }
    }
  }
  private bind(record: RecordingRecord): void {
    try {
      if (!this.getLessons(true).some((r: RecordingRecord): boolean => r.id === record.id && r.classroomCourseId === this.courseId && !r.capturing)) {
        throw new Error('目标课时已变更');
      }
      this.store(COURSE_HANDOUTS).bindToLesson(this.bindId, new ClassroomDocuments(this.root + '/' + record.id + '/classroom'));
      this.binding = false; this.error = ''; this.reload();
    } catch (e) { this.binding = false; this.error = (e as Error).message; }
  }
  private async removeFile(group: string, item: StudySource): Promise<void> {
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({ title: '移除这份资料？', message: item.title,
        buttons: [{ text: '取消', color: '#737D90' }, { text: '移除', color: '#B74D49' }] });
      if (!this.alive || result.index !== 1) { return; }
      this.store(group).remove(item.documentId || ''); this.reload();
    } catch (e) { this.error = (e as Error).message; }
  }
  private async preview(item: StudySource): Promise<void> {
    if (!item.path) { return; }
    try {
      const uri = fileUri.getUriFromPath(item.path);
      if (!canIUse('SystemCapability.FileManagement.FilePreview.Core') || !await filePreview.canPreview(this.context(), uri)) {
        throw new Error('此设备暂不支持预览该格式');
      }
      await filePreview.openPreview(this.context(), { uri: uri, title: item.title, mimeType: '' });
    } catch (e) { this.error = (e as Error).message; }
  }
  private toggle(key: string): void {
    this.selected = this.selected.includes(key) ? this.selected.filter((id: string): boolean => id !== key) : this.selected.concat([key]);
  }
  private count(group: StudyGroup): number {
    return group.sources.filter((s: StudySource): boolean => this.selected.includes(s.key)).length;
  }
  private toggleGroup(group: StudyGroup): void {
    const keys = group.sources.map((s: StudySource): string => s.key);
    const others = this.selected.filter((key: string): boolean => !keys.includes(key));
    this.selected = this.count(group) === keys.length ? others : others.concat(keys);
  }
  private visibleFiles(group: StudyGroup): StudySource[] {
    return group.sources.filter((s: StudySource): boolean => this.section === COURSE_EXAMS ?
      group.id === COURSE_EXAMS : s.kind === '课件');
  }
  private groupKey(group: StudyGroup): string {
    return group.id + ':' + group.title + ':' + group.sources.map((s: StudySource): string => s.key).join('|');
  }
  private libraryCount(): number {
    return this.groups.reduce((n: number, group: StudyGroup): number => n + this.visibleFiles(group).length, 0);
  }
  private studyExam(item: StudySource): void {
    if (!this.selected.includes(item.key)) { this.selected = this.selected.concat([item.key]); }
    this.mode = '真题分析'; this.section = 'study'; this.error = ''; this.scroller.scrollEdge(Edge.Top);
  }
  private hasExam(): boolean {
    return this.selected.some((key: string): boolean => key.startsWith(COURSE_EXAMS + '/'));
  }
  private async send(): Promise<void> {
    if (this.sending || this.importing || !this.canStart) { return; }
    this.sending = true; this.error = '';
    let created = false;
    try {
      AiServiceAccess.requireAllowed();
      const groups = courseStudyGroups(this.root, this.courseId, this.getLessons(true), this.selected);
      const pack = courseStudyPack(this.courseTitle, groups, this.selected, this.mode);
      const task = courseStudyPrompt(this.mode, this.instruction);
      const description = this.courseTitle + ' · ' + this.mode + '\n仅发送本次勾选的 ' + this.selected.length + ' 项资料。';
      const ctx = this.context();
      const library = this.library();
      const service = CodexChatService.get(ctx.filesDir);
      const result = await service.execute({ task: task, continueRunId: '' }, {
        sessionId: 'course:' + this.courseId, imagePaths: [],
        selectTarget: async (): Promise<CodexChatTarget | null> =>
          await pickCodexChatTarget(this.getUIContext(), description, 0, false, true),
        isCancelled: (): boolean => (!this.alive && !created) || !AiServiceAccess.isAllowed(),
        uploadMaterials: async (upload: (name: string, data: string) => Promise<string>, report: (notice: string) => void): Promise<string[]> =>
          await uploadStudyArchive(ctx.cacheDir, 'course.md', pack.manifest, pack.files, upload, report),
        onCreated: (run: CodexChatRun): void => {
          if (!fs.accessSync(library)) { fs.mkdirSync(library, true); }
          fs.closeSync(fs.openSync(library + '/run-' + run.createdAt + '-' + run.id, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY));
          created = true;
          if (this.alive) {
            this.runIds = [run.id].concat(this.runIds); this.currentRun = run.id; this.canStart = false;
            if (this.section === 'study') { this.scroller.scrollEdge(Edge.Top); }
          }
        }
      });
      if (this.alive && !result.ok && result.status !== 'rejected') { this.error = result.error; }
    } catch (e) { if (this.alive) { this.error = (e as Error).message; } }
    finally { if (this.alive) { this.sending = false; this.refreshRun(); } }
  }

  @Builder private SmallAction(label: string, action: () => void) {
    Button(label).height(36).fontSize(13).padding({ left: 10, right: 10 })
      .fontColor(AppTheme.text('#316B69')).backgroundColor(AppTheme.background('#E7F2EF'))
      .onClick((): void => { action(); })
  }
  @Builder private Library() {
    Row({ space: 8 }) {
      Text((this.section === COURSE_EXAMS ? '往年试卷' : '全部课件') + ' · ' + this.libraryCount())
        .fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).layoutWeight(1)
      this.SmallAction(this.importing ? '正在导入…' : this.section === COURSE_EXAMS ? '+ 导入试卷' : '+ 导入课件',
        (): void => { this.importFiles(); })
    }.width('100%')
    if (this.libraryCount() === 0) {
      Text(this.section === COURSE_EXAMS ? '可以导入 PDF、Word 或试卷照片，再按题分析考点。' :
        '在这里导入课程课件，也可以在单节课中添加。已绑定的课件会按课时展示。')
        .fontSize(15).lineHeight(24).fontColor(AppTheme.text('#737D90')).width('100%').padding(16)
    }
    ForEach(this.groups, (group: StudyGroup) => {
      if (this.visibleFiles(group).length) {
        Column({ space: 8 }) {
          if (group.id !== COURSE_EXAMS) {
            Text(group.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#316B69')).width('100%')
          }
          ForEach(this.visibleFiles(group), (item: StudySource) => {
            Column({ space: 6 }) {
              Text(item.title).fontSize(16).fontColor(AppTheme.text('#172033')).width('100%').maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).onClick((): void => { this.preview(item); })
              Row({ space: 6 }) {
                this.SmallAction('预览', (): void => { this.preview(item); })
                if (group.id === COURSE_EXAMS) {
                  this.SmallAction('分析试卷', (): void => { this.studyExam(item); })
                } else if (group.id === COURSE_HANDOUTS) {
                  this.SmallAction('绑定课时', (): void => { this.bindId = item.documentId || ''; this.binding = true; })
                } else {
                  this.SmallAction('查看课时', (): void => { this.onLesson(group.id); })
                }
                if (group.id === COURSE_EXAMS || group.id === COURSE_HANDOUTS) {
                  Blank()
                  Button('移除').height(36).fontSize(13).fontColor(AppTheme.text('#737D90')).backgroundColor(Color.Transparent)
                    .onClick((): void => { this.removeFile(group.id, item); })
                }
              }.width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%').padding({ top: 6, bottom: 6 })
          }, (item: StudySource): string => item.key)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(17).backgroundColor(AppTheme.background('#FFFFFF'))
      }
    }, (group: StudyGroup): string => this.groupKey(group))
  }

  @Builder private SelectGroup(group: StudyGroup) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text((this.expanded.includes(group.id) ? '▾  ' : '▸  ') + group.title)
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033')).layoutWeight(1)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick((): void => { this.expanded = this.expanded.includes(group.id) ?
            this.expanded.filter((id: string): boolean => id !== group.id) : this.expanded.concat([group.id]); })
        this.SmallAction(this.count(group) === group.sources.length ? '清空' : '全选',
          (): void => { this.toggleGroup(group); })
        Text(this.count(group) + '/' + group.sources.length).fontSize(12).fontColor(AppTheme.text('#737D90'))
      }.width('100%')
      if (this.expanded.includes(group.id)) {
        ForEach(group.sources, (item: StudySource) => {
          Row({ space: 10 }) {
            Text(this.selected.includes(item.key) ? '✓' : '○').fontSize(18).fontColor(AppTheme.text('#316B69'))
            if (item.kind === '照片' && item.path) {
              Image(fileUri.getUriFromPath(item.path)).width(50).height(38).objectFit(ImageFit.Cover)
                .sourceSize({ width: 150, height: 114 }).borderRadius(5)
            }
            Text(item.title).fontSize(14).fontColor(AppTheme.text('#334155')).layoutWeight(1)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').constraintSize({ minHeight: 40 }).onClick((): void => { this.toggle(item.key); })
        }, (item: StudySource): string => item.key)
      }
    }.width('100%').padding(14).borderRadius(15).backgroundColor(AppTheme.background('#FFFFFF'))
  }

  @Builder private StudyForm() {
    Row({ space: 6 }) {
      ForEach(COURSE_STUDY_MODES, (mode: string) => {
        Button(mode).height(39).fontSize(14).layoutWeight(1).padding(0)
          .backgroundColor(this.mode === mode ? AppTheme.filledBackground('#316B69') : AppTheme.background('#E7F2EF'))
          .fontColor(this.mode === mode ? Color.White : AppTheme.text('#316B69'))
          .onClick((): void => { this.mode = mode; })
      }, (mode: string): string => mode)
    }.width('100%')
    TextArea({ text: this.instruction, placeholder: this.mode === '生成模拟卷' ? '可选要求，例如 90 分钟、满分 100 分' : '可选要求，例如重点复习第三章' })
      .height(70).width('100%').maxLength(600).fontSize(14).backgroundColor(AppTheme.background('#FFFFFF'))
      .onChange((value: string): void => { this.instruction = value; })
    Row() {
      Text('选择资料').fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
      Blank()
      Text('已选 ' + this.selected.length + ' 项').fontSize(13).fontColor(AppTheme.text('#737D90'))
    }.width('100%')
    if (!this.groups.some((g: StudyGroup): boolean => g.sources.length > 0)) {
      Text('先导入课件、往年试卷，或在课时中添加笔记、照片和转写。')
        .fontSize(14).lineHeight(22).fontColor(AppTheme.text('#737D90')).width('100%')
    }
    ForEach(this.groups, (group: StudyGroup) => {
      if (group.sources.length) { this.SelectGroup(group) }
    }, (group: StudyGroup): string => this.groupKey(group))
    if (this.mode === '真题分析' && !this.hasExam()) {
      Text('请选择至少一份往年试卷。').fontSize(13).fontColor(AppTheme.text('#737D90')).width('100%')
    }
    Text('仅发送勾选内容，资料包压缩后最多 48 MiB。').fontSize(12).fontColor(AppTheme.text('#737D90')).width('100%')
    Button(this.sending ? '等待确认委托…' : '交给 Codex · ' + this.mode)
      .fontSize(15).height(44).width('100%').backgroundColor(AppTheme.filledBackground('#316B69')).fontColor(Color.White)
      .enabled(!this.sending && this.canStart && this.selected.length > 0 && (this.mode !== '真题分析' || this.hasExam()))
      .onClick((): void => { this.send(); })
  }
  private pastRuns(): string[] { return this.runIds.filter((id: string): boolean => id !== this.currentRun); }
  @Builder private Study() {
    Text('课程学伴').fontSize(22).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
    if (this.currentRun) { CodexChatRunCard({ runId: this.currentRun }) }
    if (this.canStart) { this.StudyForm() }
    if (this.pastRuns().length) {
      Text('学习成果').fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033')).width('100%')
      ForEach(this.pastRuns(), (id: string) => { CodexChatRunCard({ runId: id }) }, (id: string): string => id)
    }
  }
  @Builder private BindSheet() {
    Column({ space: 12 }) {
      Text('绑定到哪一节课？').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
      if (!this.getLessons(false).length) {
        Text('先在「课时」中新建笔记或录音，再回来绑定。').fontSize(15).fontColor(AppTheme.text('#737D90')).width('100%')
      }
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.getLessons(false), (record: RecordingRecord) => {
            Button(record.title + ' · ' + record.createdAt.substring(0, 10)).width('100%').height(44)
              .fontSize(14).fontColor(AppTheme.text('#172033')).backgroundColor(AppTheme.background('#F4F5FA'))
              .enabled(!record.capturing).onClick((): void => { this.bind(record); })
          }, (record: RecordingRecord): string => record.id)
        }.width('100%')
      }.layoutWeight(1).width('100%')
    }.padding(24).width('100%').height('100%')
  }
  build() {
    Scroll(this.scroller) {
      Column({ space: 12 }) {
        if (this.error) { Text(this.error).fontSize(14).fontColor(AppTheme.text('#B74D49')).width('100%') }
        if (this.section === 'study') { this.Study() } else { this.Library() }
      }.padding({ left: 20, right: 20, top: 12, bottom: 28 }).width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
      .bindSheet(this.binding, this.BindSheet(), { height: SheetSize.MEDIUM, showClose: true,
        backgroundColor: AppTheme.pageBackground('#FFFFFF'), onDisappear: (): void => { this.binding = false; } })
  }
}
