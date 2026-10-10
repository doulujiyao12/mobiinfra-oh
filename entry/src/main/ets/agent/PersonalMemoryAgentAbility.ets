import { AgentExtensionAbility, common, Want } from '@kit.AbilityKit';
import { PersonalMemoryAccess } from './PersonalMemoryAccess';
import {
  PersonalMemoryA2aRequest,
  parsePersonalMemoryA2aRequest,
  personalMemoryA2aFallbackError,
  personalMemoryA2aInputShape,
  PersonalMemoryA2aReplySession
} from './PersonalMemoryA2aProtocol';
import { PersonalMemoryAnswer } from './PersonalMemoryQuery';
import {
  PERSONAL_MEMORY_AGENT_TIMEOUT,
  PERSONAL_MEMORY_AGENT_REVOKED,
  PERSONAL_MEMORY_AGENT_CANCELLED,
  PersonalMemoryChatAgent,
  PersonalMemoryChatContext
} from './PersonalMemoryChatAgent';
import { DataManagerFacade } from '../datamanager/DataManagerFacade';
import { QueryOptions, QueryResult } from '../datamanager/DataManagerTypes';
import { readChatCloudConfig } from '../utils/ChatCloudConfig';
import { cloudPlannerApiKey } from '../utils/CloudModelClient';
import { AI_LOGIN_REQUIRED_MESSAGE } from '../utils/AiServiceAccess';
import { HuaweiAccountSession, HUAWEI_ACCOUNT_CHECK_FAILED_MESSAGE } from '../utils/HuaweiAccountSession';
import { PrivacyConsent } from '../utils/PrivacyConsent';
import { stringifyJsonCompat } from '../utils/JsonCompat';
import { AppLogger } from '../utils/AppLogger';

interface AuthorizationReply {
  status: string;
}

interface ActiveMemoryQuery {
  proxy: common.AgentHostProxy;
  agent: PersonalMemoryChatAgent;
}

function safeParseFailureReason(error: Error): string {
  switch (error.message) {
    case '请求长度无效':
      return 'invalid-length';
    case '请求必须是 JSON 对象':
      return 'not-json-object';
    case '不支持的协议版本':
      return 'unsupported-version';
    case '请求编号无效':
      return 'invalid-id';
    case '仅接受用户问题':
      return 'non-user-role';
    case '仅支持只读记忆查询':
      return 'unsupported-method';
    case '缺少请求参数':
      return 'missing-params';
    case '不支持的技能':
      return 'unsupported-skill';
    case '问题不能为空且不能超过 200 字':
      return 'invalid-question';
    case '任务编号过长':
      return 'invalid-task-id';
    default:
      return 'invalid-json-or-unexpected';
  }
}

export default class PersonalMemoryAgentAbility extends AgentExtensionAbility {
  private activeQueries: ActiveMemoryQuery[] = [];

  onCreate(_want: Want): void {
    AppLogger.info('XiaoyiA2A', 'Agent Extension created');
  }

  onConnect(_want: Want, _proxy: common.AgentHostProxy): void {
    AppLogger.info('XiaoyiA2A', 'Agent Extension connected');
  }

  onDisconnect(_want: Want, _proxy: common.AgentHostProxy): void {
    this.activeQueries.filter((query: ActiveMemoryQuery): boolean => query.proxy === _proxy)
      .forEach((query: ActiveMemoryQuery): void => { query.agent.cancel(); });
    AppLogger.info('XiaoyiA2A', 'Agent Extension disconnected');
  }

  onDestroy(): void {
    this.activeQueries.forEach((query: ActiveMemoryQuery): void => { query.agent.cancel(); });
    this.activeQueries = [];
  }

  onAuth(proxy: common.AgentHostProxy, _handshakeData: string): void {
    AppLogger.info('XiaoyiA2A', 'authorization requested');
    PersonalMemoryAccess.isEnabled(this.context).then((enabled: boolean): void => {
      // The system owns the IPC connection. The app's separate opt-in is checked again for every query.
      this.sendAuthorization(proxy, enabled);
    }).catch((): void => {
      AppLogger.warn('XiaoyiA2A', 'authorization check failed');
      this.sendAuthorization(proxy, false);
    });
  }

  onData(proxy: common.AgentHostProxy, data: string): void {
    AppLogger.info('XiaoyiA2A', 'request received');
    this.reply(proxy, data).catch((): void => {
      AppLogger.warn('XiaoyiA2A', 'request failed; sending fallback response');
      try {
        proxy.sendData(personalMemoryA2aFallbackError(data, '个人记忆查询失败'));
        AppLogger.info('XiaoyiA2A', 'fallback response sent');
      } catch (e) {
        AppLogger.warn('XiaoyiA2A', 'fallback response failed');
      }
    });
  }

  private sendAuthorization(proxy: common.AgentHostProxy, enabled: boolean): void {
    try {
      let reply: AuthorizationReply = { status: enabled ? 'approved' : 'denied' };
      proxy.authorize(stringifyJsonCompat(reply));
      AppLogger.info('XiaoyiA2A', enabled ? 'authorization approved' : 'authorization denied');
    } catch (e) {
      AppLogger.warn('XiaoyiA2A', 'authorization response failed');
    }
  }

  private sendResponses(proxy: common.AgentHostProxy, responses: string[]): void {
    for (let index = 0; index < responses.length; index++) {
      proxy.sendData(responses[index]);
      AppLogger.info('XiaoyiA2A', 'response frame sent index=' + (index + 1) + '/' + responses.length);
    }
  }

  private async reply(proxy: common.AgentHostProxy, data: string): Promise<void> {
    let request: PersonalMemoryA2aRequest;
    try {
      request = parsePersonalMemoryA2aRequest(data);
    } catch (e) {
      let error = e as Error;
      AppLogger.warn('XiaoyiA2A', 'parse failed reason=' + safeParseFailureReason(error) +
        ' shape=' + personalMemoryA2aInputShape(data));
      throw new Error('A2A request parsing failed');
    }
    AppLogger.info('XiaoyiA2A', 'request parsed method=' + request.method +
      ' idType=' + typeof request.id + ' numericRole=' + String(request.numericRole === true));
    let session = new PersonalMemoryA2aReplySession(request);
    this.sendResponses(proxy, session.start());
    let answer: PersonalMemoryAnswer;
    try {
      answer = await this.queryWithAgent(proxy, request.question);
    } catch (e) {
      let error = e as Error;
      if (error.message === PERSONAL_MEMORY_AGENT_TIMEOUT) {
        AppLogger.warn('XiaoyiA2A', 'memory agent timeout');
        answer = { text: '记忆查询耗时较长，本次已结束。请检查网络或缩小查询范围后重试。', count: 0 };
      } else if (error.message === PERSONAL_MEMORY_AGENT_REVOKED) {
        answer = { text: '小艺读取个人记忆的授权已关闭', count: 0 };
      } else if (error.message === PERSONAL_MEMORY_AGENT_CANCELLED) {
        answer = { text: '本次记忆查询已取消', count: 0 };
      } else if (error.message === AI_LOGIN_REQUIRED_MESSAGE) {
        answer = { text: AI_LOGIN_REQUIRED_MESSAGE, count: 0 };
      } else if (error.message === HUAWEI_ACCOUNT_CHECK_FAILED_MESSAGE) {
        answer = { text: HUAWEI_ACCOUNT_CHECK_FAILED_MESSAGE, count: 0 };
      } else {
        AppLogger.warn('XiaoyiA2A', 'memory agent query failed');
        answer = { text: '记忆 Agent 查询失败，请检查 ClawMate 的云端模型配置与网络后重试。', count: 0 };
      }
    }
    // A revoked preference (including a read failure) must never release an earlier result.
    try {
      if (!await this.isAuthorized()) {
        answer = { text: '请先在 ClawMate 的“个人与隐私”中开启小艺读取个人记忆', count: 0 };
      } else if (!await HuaweiAccountSession.isAiServiceAllowed(this.context)) {
        answer = { text: AI_LOGIN_REQUIRED_MESSAGE, count: 0 };
      }
    } catch (e) {
      let error = e as Error;
      answer = { text: error.message === HUAWEI_ACCOUNT_CHECK_FAILED_MESSAGE ? HUAWEI_ACCOUNT_CHECK_FAILED_MESSAGE :
        '无法确认个人记忆授权，本次查询已结束，请在 ClawMate 中检查设置。', count: 0 };
    }
    this.sendResponses(proxy, session.finish(answer));
    AppLogger.info('XiaoyiA2A', 'response completed');
  }

  private async queryWithAgent(proxy: common.AgentHostProxy, question: string): Promise<PersonalMemoryAnswer> {
    if (!await this.isAuthorized()) {
      return { text: '请先在 ClawMate 的“个人与隐私”中开启小艺读取个人记忆', count: 0 };
    }
    if (!await HuaweiAccountSession.isAiServiceAllowed(this.context)) {
      return { text: AI_LOGIN_REQUIRED_MESSAGE, count: 0 };
    }
    await PrivacyConsent.initialize(this.context);
    let config = readChatCloudConfig();
    if (config.plannerBaseUrl.trim().length === 0 || cloudPlannerApiKey(config).length === 0) {
      return { text: '请先在 ClawMate 中配置云端 Planner 模型服务，再使用小艺查询记忆。', count: 0 };
    }
    let facade = new DataManagerFacade(this.context.filesDir);
    let context: PersonalMemoryChatContext = {
      filesDir: this.context.filesDir,
      hasBuiltIndexes: (): boolean => facade.hasBuiltIndexes(),
      query: (options: QueryOptions): QueryResult => facade.queryIndexedEvents(options),
      isAuthorized: async (): Promise<boolean> => {
        if (!await this.isAuthorized()) {
          return false;
        }
        if (!await HuaweiAccountSession.isAiServiceAllowed(this.context)) {
          throw new Error(AI_LOGIN_REQUIRED_MESSAGE);
        }
        return true;
      }
    };
    let agent = new PersonalMemoryChatAgent();
    let active: ActiveMemoryQuery = { proxy: proxy, agent: agent };
    this.activeQueries.push(active);
    AppLogger.info('XiaoyiA2A', 'memory agent started');
    try {
      return await agent.run(question, config, context);
    } finally {
      this.activeQueries = this.activeQueries.filter((query: ActiveMemoryQuery): boolean => query !== active);
    }
  }

  private async isAuthorized(): Promise<boolean> {
    try {
      return await PersonalMemoryAccess.isEnabled(this.context);
    } catch (e) {
      AppLogger.warn('XiaoyiA2A', 'authorization preference read failed');
      throw new Error('A2A authorization preference read failed');
    }
  }
}
