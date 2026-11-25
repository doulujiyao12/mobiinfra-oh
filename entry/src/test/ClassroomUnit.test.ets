import { describe, expect, it } from '@ohos/hypium';
import { ClassroomCourse, CLASSROOM_UNASSIGNED, classroomCourseName, classroomCourseRows,
  classroomRecordCourse } from '../main/ets/utils/recording/ClassroomCourses';
import { CLASSROOM_SOURCE, ClassroomDocument, classroomDocumentExtension, classroomPackDocumentName,
  classroomText } from '../main/ets/utils/recording/ClassroomMaterials';
import { StudyGroup, courseStudyPack, courseStudyPrompt } from '../main/ets/utils/recording/CourseStudy';
import { RecordingRecord } from '../main/ets/utils/recording/RecordingTypes';

import { CodexTask } from '../main/ets/pages/codex/CodexTypes';
import { studyExecutionNotice, studyFinalAnswer, studyStage } from '../main/ets/pages/codex/CodexStudyProgress';

function lesson(id: string, notes: string = '', courseId: string = ''): RecordingRecord {
  return { schema: 1, id: id, title: '第一节', createdAt: '2026-11-24T00:00:00Z', source: CLASSROOM_SOURCE,
    duration: 0, analysis: null, classroomNotes: notes, classroomCourseId: courseId };
}

export default function classroomUnitTest(): void {
  describe('classroomUnitTest', () => {
    it('KeepsLegacyAndOrphanedLessonsVisibleWhenCoursesChange', 0, () => {
      const courses: ClassroomCourse[] = [{ id: 'math', name: classroomCourseName('  数学  ') }];
      const existing = lesson('a');
      const deleted = lesson('b', '旧笔记', 'deleted-course');
      const assigned = lesson('c', '已有笔记', 'math');
      expect(classroomRecordCourse(existing, courses)).assertEqual(CLASSROOM_UNASSIGNED);
      expect(classroomRecordCourse(assigned, courses)).assertEqual('math');
      const rows = classroomCourseRows(courses, [existing, deleted, assigned]);
      expect(rows[0].name).assertEqual('数学');
      expect(rows[0].count).assertEqual(1);
      expect(rows[1].count).assertEqual(2);
      expect(classroomRecordCourse(assigned, [])).assertEqual(CLASSROOM_UNASSIGNED);
    });
    it('PackagesNoteOnlyLessonsWithDistinctReferenceNames', 0, () => {
      const documents: ClassroomDocument[] = [
        { id: '11111111-1111-1111-1111-111111111111', name: '课程.PPTX', size: 30 },
        { id: '22222222-2222-2222-2222-222222222222', name: '课程.PPTX', size: 35 },
        { id: '33333333-3333-3333-3333-333333333333', name: '讲义.pdf', size: 48 }];
      const text = classroomText(lesson('a', '记录复习重点'), [], documents, '数学');
      expect(text.includes('课程：数学')).assertTrue();
      expect(text.includes('记录复习重点')).assertTrue();
      expect(text.includes('attachment-01.pptx — 课程.PPTX')).assertTrue();
      expect(text.includes('attachment-02.pptx — 课程.PPTX')).assertTrue();
      expect(classroomPackDocumentName(documents[2], 2)).assertEqual('attachment-03.pdf');
      expect(classroomDocumentExtension('slides.pdf.exe')).assertEqual('');
      expect(text.includes('完整转写')).assertFalse();
    });
    it('RequiresSomeMaterialAndBlocksSendingWhileRecording', 0, () => {
      const record = lesson('a');
      let blocked = false;
      try { classroomText(record, []); } catch (_) { blocked = true; }
      expect(blocked).assertTrue();
      record.capturing = true;
      record.classroomNotes = '不能在录音中发送';
      blocked = false;
      try { classroomText(record, []); } catch (_) { blocked = true; }
      expect(blocked).assertTrue();
    });
    it('SendsOnlySelectedCourseSourcesAndKeepsDuplicateNamesDistinct', 0, () => {
      const groups: StudyGroup[] = [
        { id: 'exams', title: '往年试卷', sources: [{ key: 'exam', kind: '试卷', title: '复习.pdf', path: '/exam' }] },
        { id: 'lesson1', title: '第一节', sources: [
          { key: 'slides', kind: '课件', title: '复习.pdf', path: '/slides' },
          { key: 'speech', kind: '文字', title: '转写', content: '[01:30] 判别条件' },
          { key: 'private', kind: '文字', title: '私人笔记', content: '本次不发送' }] },
        { id: 'lesson2', title: '第二节', sources: [{ key: 'photo', kind: '照片', title: '黑板', path: '/photo' }] }
      ];
      const pack = courseStudyPack('数学', groups, ['exam', 'slides', 'speech', 'photo'], '真题分析');
      expect(pack.files.length).assertEqual(3);
      expect(pack.files[0].name).assertEqual('source-001.pdf');
      expect(pack.files[1].name).assertEqual('source-002.pdf');
      expect(pack.files[2].name).assertEqual('source-003.jpg');
      expect(pack.manifest.includes('[01:30] 判别条件')).assertTrue();
      expect(pack.manifest.includes('本次不发送')).assertFalse();
      expect(courseStudyPack('数学', groups, ['speech'], '生成模拟卷').files.length).assertEqual(0);
      expect(courseStudyPrompt('生成模拟卷', '时长 90 分钟').includes('时长 90 分钟')).assertTrue();
    });
    it('RejectsMissingExamOrStaleMaterialBeforeDelegating', 0, () => {
      const groups: StudyGroup[] = [{ id: 'lesson', title: '课时', sources: [
        { key: 'note', kind: '文字', title: '笔记', content: '课堂要点' }] }];
      let rejected = 0;
      try { courseStudyPack('课程', groups, ['note'], '真题分析'); } catch (_) { rejected++; }
      try { courseStudyPack('课程', groups, [], '提取要点'); } catch (_) { rejected++; }
      try { courseStudyPack('课程', groups, ['note', 'moved'], '生成模拟卷'); } catch (_) { rejected++; }
      expect(rejected).assertEqual(3);
    });
    it('ShowsOnlyReportedStudyMilestonesFromTheCurrentTurn', 0, () => {
      const task: CodexTask = { id: 'task', title: '', status: 'running', workspaceId: 'work', model: '', effort: '',
        mode: '', turnId: 'turn', items: [], approvals: [], updatedAt: 0, revision: 1, error: '' };
      task.items.push({ id: 'old:a', kind: 'assistant', text: '学伴进度：正在核对交付文件' });
      task.items.push({ id: 'turn:b', kind: 'tool', text: 'private command output' });
      expect(studyStage(task)).assertEqual('Codex 正在使用工具处理任务');
      task.items.push({ id: 'turn:c', kind: 'assistant', text: '学伴进度：正在生成学习文件' });
      task.items.push({ id: 'turn:d', kind: 'assistant', text: 'private intermediate commentary' });
      const stage = studyStage(task);
      expect(studyExecutionNotice(task, stage)).assertEqual('正在生成学习文件');
      expect(studyFinalAnswer(task)).assertEqual('');
      task.status = 'waitingApproval';
      expect(studyExecutionNotice(task, stage)).assertEqual('请查看此卡片中的待确认操作');
      task.items = [];
      expect(studyStage(task, stage)).assertEqual(stage);
      task.status = 'completed';
      task.items.push({ id: 'turn:e', kind: 'assistant', text: '已完成试卷分析' });
      expect(studyFinalAnswer(task)).assertEqual('已完成试卷分析');
      expect(studyExecutionNotice(task, stage)).assertEqual('');
    });
  });
}
