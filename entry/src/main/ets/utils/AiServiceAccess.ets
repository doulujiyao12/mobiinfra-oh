import { REQUIRE_LOGIN_FOR_AI } from '../config/AiAccessConfig';

// 当前运行时的登录标记，由登录成功或 HuaweiAccountSession 的官方状态校验更新。
// Agent Extension 须先恢复并核验共享账号标识，不能仅凭此内存标记判断是否登录。
export const HUAWEI_ACCOUNT_SESSION_KEY: string = 'huaweiAccountSessionActive';
export const AI_LOGIN_REQUIRED_MESSAGE: string = '请先到我的中登录，解锁此功能。';

export function aiServiceLoginAllowed(requireLogin: boolean, sessionActive: boolean | undefined): boolean {
  return !requireLogin || sessionActive === true;
}

export class AiServiceAccess {
  static isAllowed(): boolean {
    return aiServiceLoginAllowed(REQUIRE_LOGIN_FOR_AI, AppStorage.get<boolean>(HUAWEI_ACCOUNT_SESSION_KEY));
  }

  static requireAllowed(): void {
    if (!AiServiceAccess.isAllowed()) {
      throw new Error(AI_LOGIN_REQUIRED_MESSAGE);
    }
  }
}
