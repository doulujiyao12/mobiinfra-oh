import { AppTheme } from '../../utils/AppTheme';
import { CLASSROOM_UNASSIGNED, ClassroomCourseRow } from '../../utils/recording/ClassroomCourses';

@Component
export struct ClassroomCourseView {
  @Prop courses: ClassroomCourseRow[] = [];
  scroller: Scroller = new Scroller();
  onCreate: () => void = (): void => {};
  onOpen: (id: string) => void = (): void => {};
  build() {
    Scroll(this.scroller) {
      Column({ space: 16 }) {
        Column({ space: 10 }) {
          Image($r('app.media.classroom_book')).width(30).height(30)
          Text('我的课程').fontSize(27).fontWeight(FontWeight.Bold).fontColor(AppTheme.text('#172033')).width('100%')
          Text('按课程整理录音、笔记和课件。').fontSize(15).lineHeight(22).fontColor(AppTheme.text('#526B68')).width('100%')
          Button('+ 新建课程').fontSize(15).height(42).fontColor(Color.White)
            .backgroundColor(AppTheme.filledBackground('#316B69')).onClick((): void => { this.onCreate(); })
        }.width('100%').alignItems(HorizontalAlign.Start).padding(21).borderRadius(22)
          .backgroundColor(AppTheme.background('#E7F2EF'))

        if (!this.courses.length) {
          Text('还没有课程。创建课程后，就可以开始第一节课。')
            .fontSize(15).lineHeight(22).fontColor(AppTheme.text('#737D90')).width('100%').padding(16)
        }
        ForEach(this.courses, (course: ClassroomCourseRow) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 12 }) {
              Column({ space: 5 }) {
                Text(course.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.text('#172033'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text(course.count + ' 节课' + (course.id === CLASSROOM_UNASSIGNED ? ' · 可归入现有或新课程' : ''))
                  .fontSize(13).fontColor(AppTheme.text('#737D90')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text('›').fontSize(24).fontColor(AppTheme.text('#316B69'))
            }.width('100%').padding({ left: 17, right: 17, top: 13, bottom: 13 })
          }.width('100%').padding(0).borderRadius(17).backgroundColor(AppTheme.background('#FFFFFF'))
            .onClick((): void => { this.onOpen(course.id); })
        }, (course: ClassroomCourseRow): string => course.id + ':' + course.name + ':' + course.count)
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 22, right: 22, top: 14, bottom: 24 })
    }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
  }
}
