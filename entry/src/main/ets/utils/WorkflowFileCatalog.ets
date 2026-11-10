import fs from '@ohos.file.fs';
import { WorkflowManagedFile } from './WorkflowTypes';

export class WorkflowCatalogStats {
  configCount: number = 0;
  configBytes: number = 0;
  dailyLogCount: number = 0;
  dailyLogBytes: number = 0;
  runCount: number = 0;
  runBytes: number = 0;
  totalBytes: number = 0;
}

interface CatalogEntry {
  name: string;
  path: string;
  directory: boolean;
  size: number;
  modifiedTime: number;
}

// File management is deliberately separate from loading or launching tasks.
// All directory/metadata I/O is asynchronous; never read screenshots or summaries here.
export class WorkflowFileCatalog {
  private cancelled: boolean = false;

  cancel(): void { this.cancelled = true; }

  async statistics(filesDir: string): Promise<WorkflowCatalogStats> {
    let stats = new WorkflowCatalogStats();
    await this.walk(filesDir + '/workflows', (file: WorkflowManagedFile): void => {
      stats.totalBytes += file.size;
      if (file.name.startsWith('configs/')) {
        stats.configCount++; stats.configBytes += file.size;
      } else if (file.name.startsWith('daily-log/')) {
        stats.dailyLogCount++; stats.dailyLogBytes += file.size;
      } else if (file.name.startsWith('runs/') && file.name.endsWith('/run_summary.json')) {
        stats.runCount++; stats.runBytes += file.size;
      }
    });
    return stats;
  }

  async list(filesDir: string, category: string): Promise<WorkflowManagedFile[]> {
    let directory = category === 'config' ? 'configs' : category === 'run' ? 'runs' : 'daily-log';
    let files: WorkflowManagedFile[] = [];
    await this.walk(filesDir + '/workflows/' + directory, (file: WorkflowManagedFile): void => {
      if (category !== 'run' || file.name === 'run_summary.json' || file.name.endsWith('/run_summary.json')) {
        files.push(file);
      }
    });
    return files.sort((left: WorkflowManagedFile, right: WorkflowManagedFile): number => {
      return right.modifiedTime - left.modifiedTime || (left.name === right.name ? 0 : left.name > right.name ? 1 : -1);
    });
  }

  private ensureActive(): void {
    if (this.cancelled) { throw new Error('WORKFLOW_CATALOG_CANCELLED'); }
  }

  private async inspect(path: string, name: string): Promise<CatalogEntry | null> {
    this.ensureActive();
    try {
      let stat = await fs.lstat(path);
      // Do not follow links out of the managed workspace or recurse through a link cycle.
      if (!stat.isDirectory() && !stat.isFile()) { return null; }
      return { name: name, path: path, directory: stat.isDirectory(), size: stat.size, modifiedTime: stat.mtime };
    } catch (e) {
      // A file may be removed by file management while an older scan is pending.
      if (!await fs.access(path)) { return null; }
      let err = e as Error;
      throw err;
    }
  }

  private async walk(root: string, accept: (file: WorkflowManagedFile) => void): Promise<void> {
    this.ensureActive();
    if (!await fs.access(root)) { return; }
    let directories: CatalogEntry[] = [{ name: '', path: root, directory: true, size: 0, modifiedTime: 0 }];
    for (let index = 0; index < directories.length; index++) {
      this.ensureActive();
      let directory = directories[index];
      let names = await fs.listFile(directory.path);
      for (let offset = 0; offset < names.length; offset += 24) {
        this.ensureActive();
        let reads: Promise<CatalogEntry | null>[] = [];
        for (let i = offset; i < Math.min(offset + 24, names.length); i++) {
          let name = directory.name ? directory.name + '/' + names[i] : names[i];
          reads.push(this.inspect(directory.path + '/' + names[i], name));
        }
        let entries = await Promise.all(reads);
        this.ensureActive();
        for (let i = 0; i < entries.length; i++) {
          let entry = entries[i];
          if (entry === null) { continue; }
          if (entry.directory) { directories.push(entry); }
          else { accept({ name: entry.name, path: entry.path, size: entry.size, modifiedTime: entry.modifiedTime }); }
        }
      }
    }
    this.ensureActive();
  }
}
