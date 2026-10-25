import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { filePreview } from '@kit.PreviewKit';
import { CodexLocalArtifact } from './CodexTypes';

export async function openCodexArtifact(context: common.UIAbilityContext, saved: CodexLocalArtifact): Promise<void> {
  if (!canIUse('SystemCapability.FileManagement.FilePreview.Core')) { throw new Error('此设备暂不支持系统预览，请使用“另存为”打开'); }
  const uri = fileUri.getUriFromPath(saved.localPath);
  if (!await filePreview.canPreview(context, uri)) { throw new Error('该格式暂不支持预览，请使用“另存为”导出'); }
  await filePreview.openPreview(context, { uri: uri, title: saved.name, mimeType: saved.mimeType });
}

export async function exportCodexArtifact(context: common.UIAbilityContext, saved: CodexLocalArtifact): Promise<boolean> {
  const options = new picker.DocumentSaveOptions(); options.newFileNames = [saved.name];
  const destinations = await new picker.DocumentViewPicker(context).save(options);
  if (!destinations.length) { return false; }
  const output = await fileIo.open(destinations[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  try { await fileIo.copyFile(saved.localPath, output.fd); }
  finally { await fileIo.close(output); }
  return true;
}
