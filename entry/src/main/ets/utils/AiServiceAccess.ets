import { REQUIRE_LOGIN_FOR_AI } from '../config/AiAccessConfig';

// 仅共享本次 App 进程内的登录会话，不持久化一个布尔值来模拟有效登录。
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
