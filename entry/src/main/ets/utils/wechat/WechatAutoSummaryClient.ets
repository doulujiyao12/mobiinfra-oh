import { PrivacyConsent } from '../PrivacyConsent';
import { JSON as ArkJSON } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { WechatAutoSummaryRequest, WechatAutoSummaryResponse } from './WechatAutoSummaryTypes';

interface WechatAutoSummaryBridgeRequest {
  action: string;
  payload: WechatAutoSummaryRequest;
}

export class WechatAutoSummaryClient {
  private baseUrl: string;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  private workflowUrl(): string {
    let url = this.baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url + '/api/workflow';
  }

  // 通过 PC 侧 HDC bridge 触发微信采集，App 侧只负责提交参数并解析服务端结果。
  async collect(request: WechatAutoSummaryRequest): Promise<WechatAutoSummaryResponse> {
    let body: WechatAutoSummaryBridgeRequest = {
      action: 'wechat_collect',
      payload: request
    };
    let httpReq = PrivacyConsent.createHttp();
    try {
      let options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: ArkJSON.stringify(body),
        connectTimeout: 8000,
        readTimeout: 300000,
        expectDataType: http.HttpDataType.STRING
      };
      let resp = await httpReq.request(this.workflowUrl(), options);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return {
          status: 'error',
          message: 'HDC bridge HTTP ' + resp.responseCode + ': ' + String(resp.result)
        };
      }
      return ArkJSON.parse(resp.result as string) as WechatAutoSummaryResponse;
    } catch (e) {
      let err = e as Error;
      return {
        status: 'error',
        message: 'HDC bridge 请求失败：' + err.message
      };
    } finally {
      PrivacyConsent.destroyHttp(httpReq);
    }
  }
}
