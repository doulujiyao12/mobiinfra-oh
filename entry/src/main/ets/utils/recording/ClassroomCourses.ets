import { fileIo as fs } from '@kit.CoreFileKit';
import { JSON as ArkJSON, util } from '@kit.ArkTS';
import { writeRecordingMetadata } from './RecordingMetadata';
import { RecordingRecord } from './RecordingTypes';

export const CLASSROOM_UNASSIGNED: string = 'unassigned';
export const CLASSROOM_NOTE_LIMIT: number = 20000;
export interface ClassroomCourse { id: string; name: string; }
export interface ClassroomCourseRow { id: string; name: string; count: number; }
interface ClassroomCatalog { version: number; courses: ClassroomCourse[]; }

export function classroomCourseName(value: string): string {
  const name = value.trim();
  if (!name || name.length > 48) { throw new Error('请输入 1–48 字的课程名称'); }
  return name;
}

export function classroomRecordCourse(record: RecordingRecord, courses: ClassroomCourse[]): string {
  const id = record.classroomCourseId;
  return id && courses.some((c: ClassroomCourse): boolean => c.id === id) ? id : CLASSROOM_UNASSIGNED;
}

export function classroomCourseRows(courses: ClassroomCourse[], records: RecordingRecord[]): ClassroomCourseRow[] {
  const counts = new Map<string, number>();
  for (const record of records) {
    const id = classroomRecordCourse(record, courses);
    counts.set(id, (counts.get(id) || 0) + 1);
  }
  const rows = courses.map((course: ClassroomCourse): ClassroomCourseRow =>
    ({ id: course.id, name: course.name, count: counts.get(course.id) || 0 }));
  if (counts.get(CLASSROOM_UNASSIGNED)) {
    rows.push({ id: CLASSROOM_UNASSIGNED, name: '未归类', count: counts.get(CLASSROOM_UNASSIGNED) || 0 });
  }
  return rows;
}

export class ClassroomCourseStore {
  private path: string;
  constructor(recordingRoot: string) { this.path = recordingRoot + '/classroom-courses.json'; }
  list(): ClassroomCourse[] {
    if (!fs.accessSync(this.path)) { return []; }
    const catalog = ArkJSON.parse(fs.readTextSync(this.path)) as ClassroomCatalog;
    if (catalog.version !== 1 || !Array.isArray(catalog.courses) ||
      catalog.courses.some((c: ClassroomCourse): boolean => !c || !/^[a-f0-9-]{36}$/.test(c.id) ||
        typeof c.name !== 'string' || !c.name.trim())) { throw new Error('课程目录无法读取，请保留数据后重试'); }
    return catalog.courses;
  }
  saveCourse(name: string, id: string = ''): ClassroomCourse {
    const title = classroomCourseName(name);
    const courses = this.list();
    if (courses.some((c: ClassroomCourse): boolean => c.id !== id && c.name.toLowerCase() === title.toLowerCase())) {
      throw new Error('已有同名课程，请直接打开已有课程');
    }
    if (id && !courses.some((c: ClassroomCourse): boolean => c.id === id)) { throw new Error('该课程已不存在'); }
    const course: ClassroomCourse = { id: id || util.generateRandomUUID(), name: title };
    const next = id ? courses.map((c: ClassroomCourse): ClassroomCourse => c.id === id ? course : c) : courses.concat([course]);
    this.write(next);
    return course;
  }
  remove(id: string): void {
    // Lesson IDs and files are retained. Missing courses resolve to 未归类.
    this.write(this.list().filter((course: ClassroomCourse): boolean => course.id !== id));
  }
  private write(courses: ClassroomCourse[]): void {
    const catalog: ClassroomCatalog = { version: 1, courses: courses };
    writeRecordingMetadata(this.path, catalog);
  }
}
