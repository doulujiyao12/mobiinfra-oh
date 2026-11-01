import { UIContext } from '@kit.ArkUI';
import { AppTheme } from '../../utils/AppTheme';
import { CodexCredentialStore } from './CodexCredentialStore';
import { CodexClient } from './CodexClient';
import { CodexChatTarget } from './CodexChatTypes';
import { CodexSavedConnection, CodexWorkspace } from './CodexTypes';
import { CodexSelectionOption, showCodexSelectionDialog } from './CodexSelectionDialog';

export async function pickCodexChatTarget(uiContext: UIContext, task: string,
  imageCount: number): Promise<CodexChatTarget | null> {
  const saved = await CodexCredentialStore.list();
  if (saved.length === 0) { throw new Error('请先进入底部 Codex 页面，创建并保存电脑连接，再回到聊天委托任务。'); }
  let selected: number | null;
  const computers = saved.map((item: CodexSavedConnection): CodexSelectionOption =>
    ({ id: item.id, title: item.name, subtitle: item.origin.replace('https://', '') }));
  try { selected = await showCodexSelectionDialog(uiContext, '选择执行设备', '交给哪台电脑上的 Codex？', computers); }
  catch (e) { return null; }
  if (selected === null) { return null; }
  const computer = saved[selected];
  if (computer === undefined) { return null; }
  const connection = await CodexCredentialStore.load(computer.id);
  if (connection === null) { throw new Error('该电脑连接已移除，请重新配对'); }
  const client = new CodexClient();
  try {
    client.configure(connection);
    const info = await client.call('/v1/info');
    if (!info.ready || !info.workspaces?.length) { throw new Error('电脑连接器尚未就绪或没有工作目录'); }
    const workspaces = info.workspaces;
    let index: number | null;
    const folders = workspaces.map((item: CodexWorkspace): CodexSelectionOption =>
      ({ id: item.id, title: item.name, subtitle: '' }));
    try { index = await showCodexSelectionDialog(uiContext, '选择工作文件夹', '任务与交付文件将保存在所选目录中', folders, true); }
    catch (e) { return null; }
    if (index === null) { return null; }
    const workspace = workspaces[index];
    if (workspace === undefined) { return null; }
    let confirmed: number;
    try {
      const result = await uiContext.getPromptAction().showDialog({ title: '委托 Codex',
        message: computer.name + ' · ' + workspace.name + '\n\n' + task +
          '\n\n将新建独立会话，允许工作目录内修改，额外操作请求批准。' +
          (imageCount > 0 ? '\n会发送本条消息附带的 ' + imageCount + ' 张图片。' : '') +
          '\n文本及最终交付文件将返回此聊天，由手机 Agent 继续处理。',
        buttons: [{ text: '取消', color: AppTheme.dialogText('#747B87') },
          { text: '开始委托', color: AppTheme.dialogText('#5968FF') }] });
      confirmed = result.index;
    } catch (e) { return null; }
    return confirmed === 1 ? { connectionId: computer.id, workspaceId: workspace.id } : null;
  } finally { client.close(); }
}
