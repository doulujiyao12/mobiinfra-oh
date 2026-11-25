import { UIContext } from '@kit.ArkUI';
import { AppTheme } from '../../utils/AppTheme';
import { CodexCredentialStore } from './CodexCredentialStore';
import { CodexClient } from './CodexClient';
import { CodexChatTarget } from './CodexChatTypes';
import { CodexSavedConnection, CodexWorkspace } from './CodexTypes';
import { CodexSelectionOption, showCodexSelectionDialog } from './CodexSelectionDialog';

const SECRETARY_COMPUTER = 'secretaryCodexComputer';
const SECRETARY_WORKSPACE = 'secretaryCodexWorkspace';
PersistentStorage.persistProp(SECRETARY_COMPUTER, '');
PersistentStorage.persistProp(SECRETARY_WORKSPACE, '');

export function setSecretaryTarget(connectionId: string, workspaceId: string): void {
  AppStorage.setOrCreate(SECRETARY_COMPUTER, connectionId);
  AppStorage.setOrCreate(SECRETARY_WORKSPACE, workspaceId);
}

export async function pickCodexChatTarget(uiContext: UIContext, task: string,
  imageCount: number, secretary: boolean = false, classroom: boolean = false): Promise<CodexChatTarget | null> {
  const saved = await CodexCredentialStore.list();
  if (saved.length === 0) { throw new Error('请先进入底部 Codex 页面，创建并保存电脑连接，再回到聊天委托任务。'); }
  const preferred = secretary ? AppStorage.get<string>(SECRETARY_COMPUTER) || '' : '';
  let selected: number | null = saved.findIndex((item: CodexSavedConnection): boolean => item.id === preferred);
  const computers = saved.map((item: CodexSavedConnection): CodexSelectionOption =>
    ({ id: item.id, title: item.name, subtitle: item.origin.replace('https://', '') }));
  if (secretary && !preferred && saved.length === 1) { selected = 0; }
  if (selected < 0) {
    try { selected = await showCodexSelectionDialog(uiContext, '选择执行设备', '交给哪台电脑上的 Codex？', computers); }
    catch (e) { return null; }
  }
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
    const preferredFolder = preferred === computer.id ? AppStorage.get<string>(SECRETARY_WORKSPACE) || '' : '';
    let index: number | null = workspaces.findIndex((item: CodexWorkspace): boolean => item.id === preferredFolder);
    const folders = workspaces.map((item: CodexWorkspace): CodexSelectionOption =>
      ({ id: item.id, title: item.name, subtitle: '' }));
    if (secretary && !preferredFolder && workspaces.length === 1) { index = 0; }
    if (index < 0) {
      try { index = await showCodexSelectionDialog(uiContext, '选择工作文件夹', '任务与交付文件将保存在所选目录中', folders, true); }
      catch (e) { return null; }
    }
    if (index === null) { return null; }
    const workspace = workspaces[index];
    if (workspace === undefined) { return null; }
    let confirmed: number;
    try {
      const result = await uiContext.getPromptAction().showDialog({ title: '委托 Codex',
        message: computer.name + ' · ' + workspace.name + '\n\n' + task +
          '\n\n将新建独立会话，允许工作目录内修改，额外操作请求批准。' +
          (imageCount > 0 ? '\n会发送本条消息附带的 ' + imageCount + ' 张图片。' : '') +
          (classroom ? '\n生成的文件会返回发起委托的课堂或课程页面。' : '\n文本及最终交付文件将返回此聊天，由手机 Agent 继续处理。'),
        buttons: [{ text: '取消', color: AppTheme.dialogText('#747B87') },
          { text: '开始委托', color: AppTheme.dialogText('#5968FF') }] });
      confirmed = result.index;
    } catch (e) { return null; }
    if (confirmed !== 1) { return null; }
    if (secretary) { setSecretaryTarget(computer.id, workspace.id); }
    return { connectionId: computer.id, workspaceId: workspace.id };
  } finally { client.close(); }
}
