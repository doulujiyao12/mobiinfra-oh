import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { AppBackupExportResult, AppBackupImportResult, AppBackupManager } from '../../utils/AppBackupManager';
import { AppLogger } from '../../utils/AppLogger';
import { showToastSafely } from '../../utils/PromptSafe';

export interface SettingsBackupExportRequest {
  context: common.UIAbilityContext;
  filesDir: string;
  password: string;
  includeSensitiveSettings: boolean;
  onStatusChange: (status: string) => void;
}

export interface SettingsBackupImportRequest {
  context: common.UIAbilityContext;
  filesDir: string;
  password: string;
  onStatusChange: (status: string) => void;
  onRestored: () => void;
}

// 设置中心备份协调层：只处理系统文件选择器、状态提示和页面刷新回调，加密恢复交给 AppBackupManager。
export class SettingsBackupController {
  static async exportEncryptedBackup(request: SettingsBackupExportRequest): Promise<void> {
    AppLogger.info('Backup.Controller', 'export start filesDirReady=' + String(request.filesDir.length > 0) +
      ', includeSensitive=' + String(request.includeSensitiveSettings));
    if (request.filesDir.length === 0) {
      throw new Error('应用沙箱目录尚未初始化');
    }
    request.onStatusChange('正在选择导出位置...');
    try {
      let targetUri = await SettingsBackupController.chooseBackupSaveUri(request.context);
      if (targetUri.length === 0) {
        AppLogger.info('Backup.Controller', 'export cancelled by user');
        request.onStatusChange('已取消导出');
        return;
      }
      AppLogger.info('Backup.Controller', 'export uri selected');
      request.onStatusChange('正在扫描文件并加密备份...');
      let result: AppBackupExportResult = await AppBackupManager.exportBackup(request.filesDir, {
        password: request.password,
        includeSensitiveSettings: request.includeSensitiveSettings,
        targetUri: targetUri
      });
      request.onStatusChange(
        `导出完成：${result.fileCount} 个文件，${SettingsBackupController.formatBackupBytes(result.totalBytes)}，${result.createdAt}`);
      AppLogger.info('Backup.Controller', 'export success fileCount=' + String(result.fileCount) +
        ', totalBytes=' + String(result.totalBytes));
      showToastSafely('加密备份已导出', 1600);
    } catch (e) {
      let err = e as Error;
      request.onStatusChange('导出失败：' + err.message);
      AppLogger.errorCause('Backup.Controller', 'export failed', err);
      showToastSafely('导出失败：' + err.message, 2200);
      throw err;
    }
  }

  static async importEncryptedBackup(request: SettingsBackupImportRequest): Promise<void> {
    AppLogger.info('Backup.Controller', 'import start filesDirReady=' + String(request.filesDir.length > 0));
    if (request.filesDir.length === 0) {
      throw new Error('应用沙箱目录尚未初始化');
    }
    request.onStatusChange('正在选择备份文件...');
    try {
      let sourceUri = await SettingsBackupController.chooseBackupSourceUri(request.context);
      if (sourceUri.length === 0) {
        AppLogger.info('Backup.Controller', 'import cancelled by user');
        request.onStatusChange('已取消导入');
        return;
      }
      AppLogger.info('Backup.Controller', 'import uri selected');
      request.onStatusChange('正在解密并校验备份文件...');
      let result: AppBackupImportResult = await AppBackupManager.importBackup(request.filesDir, {
        password: request.password,
        sourceUri: sourceUri,
        overwrite: true
      });
      request.onRestored();
      request.onStatusChange(`导入完成：恢复 ${result.fileCount} 个文件、${result.restoredSettings} 个设置项`);
      AppLogger.info('Backup.Controller', 'import success fileCount=' + String(result.fileCount) +
        ', restoredSettings=' + String(result.restoredSettings));
      showToastSafely('备份恢复完成', 1600);
    } catch (e) {
      let err = e as Error;
      request.onStatusChange('导入失败：' + err.message);
      AppLogger.errorCause('Backup.Controller', 'import failed', err);
      showToastSafely('导入失败：' + err.message, 2400);
      throw err;
    }
  }

  private static async chooseBackupSaveUri(context: common.UIAbilityContext): Promise<string> {
    AppLogger.info('Backup.Controller', 'open document save picker');
    let documentPicker = new picker.DocumentViewPicker(context);
    let options = new picker.DocumentSaveOptions();
    options.newFileNames = [SettingsBackupController.backupFileName()];
    options.fileSuffixChoices = ['MobiInfer 备份|.mibak'];
    let uris = await documentPicker.save(options);
    return uris.length > 0 ? uris[0] : '';
  }

  private static async chooseBackupSourceUri(context: common.UIAbilityContext): Promise<string> {
    AppLogger.info('Backup.Controller', 'open document select picker');
    let documentPicker = new picker.DocumentViewPicker(context);
    let options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['MobiInfer 备份|.mibak,.json'];
    let uris = await documentPicker.select(options);
    return uris.length > 0 ? uris[0] : '';
  }

  private static backupFileName(): string {
    let now = new Date();
    let year = String(now.getFullYear());
    let month = SettingsBackupController.padDatePart(now.getMonth() + 1);
    let day = SettingsBackupController.padDatePart(now.getDate());
    let hour = SettingsBackupController.padDatePart(now.getHours());
    let minute = SettingsBackupController.padDatePart(now.getMinutes());
    let second = SettingsBackupController.padDatePart(now.getSeconds());
    return `mobiinfra-backup-${year}${month}${day}-${hour}${minute}${second}.mibak`;
  }

  private static padDatePart(value: number): string {
    return value < 10 ? '0' + String(value) : String(value);
  }

  private static formatBackupBytes(totalBytes: number): string {
    if (totalBytes < 1024) {
      return `${totalBytes} B`;
    }
    let kb = totalBytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    let mb = kb / 1024;
    return `${mb.toFixed(1)} MB`;
  }
}
