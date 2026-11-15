import { DataManagerStorage } from '../../datamanager/DataManagerStorage';
import { SecretaryJob, SecretaryJobState, SecretaryRoute, canReassignJob } from './HomeSecretary';

// The receipt owns the note-to-session link. The chat session owns the actual evidence and results.
@Observed
export class HomeSecretaryDesk {
  jobs: SecretaryJob[] = [];
  private path: string = '';
  private storage: DataManagerStorage = new DataManagerStorage();

  restore(filesDir: string): void {
    const path = filesDir + '/home-secretary-jobs.json';
    if (this.path === path) { return; }
    this.path = path;
    const saved = this.storage.readJson<SecretaryJob[]>(path, []);
    if (!Array.isArray(saved)) { return; }
    this.jobs = saved.filter((job: SecretaryJob): boolean =>
      !!job && typeof job.key === 'string' && typeof job.title === 'string' && typeof job.sessionId === 'string')
      .map((job: SecretaryJob): SecretaryJob => {
        // Receipts saved before the route field used these fixed handoff messages.
        if (!job.route && (job.message === '正在将任务交给千问。' ||
          job.message === '任务已交给千问，可在千问对话中查看回复。')) { job.route = 'qwen'; }
        if (job.state === 'running') {
          job.state = 'review';
          job.message = '上次办理中断，请先查看原任务进度。';
        }
        return job;
      });
  }

  find(key: string): SecretaryJob | undefined {
    return this.jobs.find((job: SecretaryJob): boolean => job.key === key);
  }

  start(key: string, title: string, route: SecretaryRoute, retry: boolean): boolean {
    const previous = this.find(key);
    if (retry ? !previous || !canReassignJob(previous) : !!previous) { return false; }
    if (this.jobs.some((job: SecretaryJob): boolean => job.state === 'running')) {
      throw new Error('正在办理上一张便签，请稍后再交办');
    }
    this.put({ key: key, title: title, route: route, sessionId: '', state: 'running', message: '正在准备这件事…' });
    return true;
  }

  update(key: string, state: SecretaryJobState, message: string, sessionId?: string): void {
    const current = this.find(key);
    if (!current) { return; }
    this.put({ key: key, title: current.title, route: current.route, state: state, message: message,
      sessionId: sessionId === undefined ? current.sessionId : sessionId });
  }

  private put(job: SecretaryJob): void {
    if (!this.path) { throw new Error('秘书工作台还未就绪'); }
    const jobs = [job].concat(this.jobs.filter((entry: SecretaryJob): boolean => entry.key !== job.key));
    this.storage.writeJsonAtomic(this.path, jobs);
    this.jobs = jobs;
  }
}
