import { common } from '@kit.AbilityKit';
import { authentication } from '@kit.AccountKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { REQUIRE_LOGIN_FOR_AI } from '../config/AiAccessConfig';
import { HUAWEI_ACCOUNT_SESSION_KEY } from './AiServiceAccess';
import { AppLogger } from './AppLogger';
import { parseJsonCompat, stringifyJsonCompat } from './JsonCompat';

const SESSION_FILE: string = 'huawei-account-session.json';
const STATE_CHECK_TIMEOUT_MS: number = 8000;
export const HUAWEI_ACCOUNT_CHECK_FAILED_MESSAGE: string = '暂时无法确认华为账号登录状态，请检查网络后重试。';

// Store only the identifier needed by Account Kit, never authorization codes or tokens.
export interface HuaweiAccountSessionRecord {
  openId: string;
  revision: string;
}

export type HuaweiAccountSessionReader = () => HuaweiAccountSessionRecord;
export type HuaweiAccountStateQuery = (openId: string) => Promise<authentication.State>;

export async function verifyHuaweiAccountSession(
  readSession: HuaweiAccountSessionReader,
  queryState: HuaweiAccountStateQuery
): Promise<boolean> {
  let before = readSession();
  if (before.openId.length === 0 || before.revision.length === 0) {
    return false;
  }
  let state = await queryState(before.openId);
  // Re-read the file: another process may have logged out while the API was pending.
  let after = readSession();
  return state === authentication.State.AUTHORIZED &&
    before.openId === after.openId && before.revision === after.revision;
}

export class HuaweiAccountSession {
  private static localRevision: number = 0;

  private static path(context: common.Context): string {
    return context.getApplicationContext().filesDir + '/' + SESSION_FILE;
  }

  private static read(context: common.Context): HuaweiAccountSessionRecord {
    let path = HuaweiAccountSession.path(context);
    if (!fs.accessSync(path)) {
      AppLogger.info('HuaweiAccount', 'no saved app session');
      return { openId: '', revision: '' };
    }
    let record = parseJsonCompat<HuaweiAccountSessionRecord>(fs.readTextSync(path));
    if (record === null || typeof record.openId !== 'string' || typeof record.revision !== 'string') {
      throw new Error('Invalid local Huawei account session');
    }
    return record;
  }

  private static write(context: common.Context, openId: string): void {
    let path = HuaweiAccountSession.path(context);
    let record: HuaweiAccountSessionRecord = { openId: openId, revision: util.generateRandomUUID(true) };
    let temporaryPath = path + '.' + record.revision + '.tmp';
    try {
      let file = fs.openSync(temporaryPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, stringifyJsonCompat(record));
        fs.fsyncSync(file.fd);
      } finally {
        fs.closeSync(file);
      }
      // Same-directory rename prevents readers from seeing a partially written JSON file.
      fs.renameSync(temporaryPath, path);
    } finally {
      if (fs.accessSync(temporaryPath)) {
        fs.unlinkSync(temporaryPath);
      }
    }
  }

  static recordLogin(context: common.Context, openId: string): void {
    if (typeof openId !== 'string' || openId.trim().length === 0) {
      throw new Error('Huawei account login did not return an OpenID');
    }
    HuaweiAccountSession.localRevision += 1;
    HuaweiAccountSession.write(context, openId);
    AppStorage.setOrCreate<boolean>(HUAWEI_ACCOUNT_SESSION_KEY, true);
    AppLogger.info('HuaweiAccount', 'login session saved');
  }

  static logout(context: common.Context): void {
    HuaweiAccountSession.localRevision += 1;
    HuaweiAccountSession.write(context, '');
    AppStorage.setOrCreate<boolean>(HUAWEI_ACCOUNT_SESSION_KEY, false);
    AppLogger.info('HuaweiAccount', 'local session cleared');
  }

  private static async queryState(openId: string): Promise<authentication.State> {
    let request: authentication.StateRequest = { idType: authentication.IdType.OPEN_ID, idValue: openId };
    let provider = new authentication.HuaweiIDProvider();
    let timer: number = -1;
    let timeout = new Promise<authentication.State>((_resolve, reject): void => {
      timer = setTimeout((): void => {
        reject(new Error(HUAWEI_ACCOUNT_CHECK_FAILED_MESSAGE));
      }, STATE_CHECK_TIMEOUT_MS);
    });
    try {
      let result = provider.getHuaweiIDState(request).then((value: authentication.StateResult): authentication.State => {
        AppLogger.info('HuaweiAccount', 'official account state=' + String(value.state));
        return value.state;
      });
      return await Promise.race<authentication.State>([result, timeout]);
    } finally {
      if (timer >= 0) {
        clearTimeout(timer);
      }
    }
  }

  static async refresh(context: common.Context): Promise<boolean> {
    let revision = HuaweiAccountSession.localRevision;
    try {
      let allowed = await verifyHuaweiAccountSession(
        (): HuaweiAccountSessionRecord => HuaweiAccountSession.read(context),
        (openId: string): Promise<authentication.State> => HuaweiAccountSession.queryState(openId)
      );
      // A UI login/logout performed in this runtime takes precedence over a pending restore.
      if (revision !== HuaweiAccountSession.localRevision) {
        return AppStorage.get<boolean>(HUAWEI_ACCOUNT_SESSION_KEY) === true;
      }
      AppStorage.setOrCreate<boolean>(HUAWEI_ACCOUNT_SESSION_KEY, allowed);
      AppLogger.info('HuaweiAccount', allowed ? 'session verified' : 'session unavailable');
      return allowed;
    } catch (e) {
      // API failures are distinct from an explicit signed-out/revoked response.
      let error = e as BusinessError;
      AppLogger.warn('HuaweiAccount', 'session verification failed code=' + String(error.code === undefined ? 0 : error.code));
      throw new Error(HUAWEI_ACCOUNT_CHECK_FAILED_MESSAGE);
    }
  }

  static async isAiServiceAllowed(context: common.Context): Promise<boolean> {
    return !REQUIRE_LOGIN_FOR_AI || await HuaweiAccountSession.refresh(context);
  }
}
