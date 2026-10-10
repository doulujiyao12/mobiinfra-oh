import { UIContext } from '@kit.ArkUI';
import { PrivacyConsent, PRIVACY_REQUIRED_MESSAGE, PRIVACY_VERSION } from '../utils/PrivacyConsent';
import { showToastSafely } from '../utils/PromptSafe';

export const PRIVACY_DECLARATION: string =
  '感谢您使用本应用。请了解您的数据如何被处理，并自主选择是否同意。\n\n' +
  '1. 应用中的隐私数据保存在本地\n' +
  '您的个人资料、采集记录、聊天内容及分析结果保存在本地设备中。应用不会为小艺查询功能主动同步完整记忆库。\n\n' +
  '华为账号登录成功后，应用在本地保存该账号在本应用中的标识（OpenID），用于通过华为账号服务确认登录和授权状态，供应用与小艺查询入口共用。应用不保存授权码或身份令牌，也不向云端模型发送该账号标识。\n\n' +
  '2. 云端仅做临时处理\n' +
  '仅在您同意后，为完成任务与智能分析，应用才会将完成该功能所必需的任务描述、相关记录、文本、图片或截图等数据发送至所配置的云端分析服务。云端仅临时处理并返回结果，处理完成后不保留相关隐私数据。\n\n' +
  '3. 小艺查询个人记忆\n' +
  '仅在您另外开启“我的 > 个人与隐私 > 小艺读取个人记忆”后，小艺才可以按问题读取本机已同步的个人记忆摘要，包括个人信息、外卖、微信消息等已进入记忆索引的内容。查询使用本应用配置的云端模型理解问题，必要的提问和匹配记录会交给该模型整理回答。应用不通过该入口提供证件号码、手机号和详细住址，也不读取未同步的原始聊天记录。结果会发送给小艺，之后的处理遵循小艺的隐私规则；您可随时关闭此开关。\n\n' +
  '4. 由您决定是否开启\n' +
  '选择“不同意”后，您仍可查看本地内容和使用不涉及云端处理的功能，但不能执行任务或上传数据进行云端分析。再次主动执行任务时，我们会重新征求您的同意。\n\n' +
  '5. 随时修改选择\n' +
  '您可在“我的 > 个人与隐私 > 隐私声明”中同意或撤回同意。撤回后将停止新的任务、上传与小艺个人记忆查询，并尝试取消正在进行的处理；已发送的数据无法通过撤回操作收回。相册、麦克风等系统权限仍会在使用对应功能时另行申请。\n\n' +
  '声明版本：' + PRIVACY_VERSION;

// Native ArkUI alert dialog supplies system layout, scrollable body and accessible buttons.
export class PrivacyConsentDialog {
  private static visible: boolean = false;

  static async show(uiContext: UIContext, review: boolean = false): Promise<boolean> {
    if (PrivacyConsentDialog.visible) {
      // Do not queue multiple task executions behind the same consent tap.
      return false;
    }
    PrivacyConsentDialog.visible = true;
    try {
      let context = uiContext.getHostContext();
      if (context === undefined) {
        return false;
      }
      await PrivacyConsent.initialize(context);
      if (!review && PrivacyConsent.isAccepted()) {
        return true;
      }
      return await new Promise<boolean>((resolve) => {
        let choiceMade = false;
        let choose = (accepted: boolean): void => {
          if (choiceMade) {
            return;
          }
          choiceMade = true;
          PrivacyConsent.choose(accepted).then(() => {
            if (!accepted) {
              showToastSafely('已拒绝云端处理，可继续查看本地内容');
            }
            resolve(accepted);
          }).catch(() => {
            showToastSafely('隐私选择保存失败，任务与上传保持关闭，请重试');
            resolve(false);
          });
        };
        uiContext.showAlertDialog({
          title: '隐私声明',
          message: PRIVACY_DECLARATION,
          autoCancel: false,
          alignment: DialogAlignment.Center,
          onWillDismiss: () => {},
          onDidDisappear: () => {
            if (!choiceMade) {
              resolve(false);
            }
          },
          primaryButton: { value: '不同意', action: () => { choose(false); } },
          secondaryButton: { value: '同意', action: () => { choose(true); } }
        });
      });
    } catch (e) {
      showToastSafely(PRIVACY_REQUIRED_MESSAGE);
      return false;
    } finally {
      PrivacyConsentDialog.visible = false;
    }
  }
}
