import { describe, it, expect } from '@ohos/hypium';
import { AgentActionParser } from '../main/ets/utils/AgentActionParser';
import { stringifyJsonCompat } from '../main/ets/utils/JsonCompat';
import { phoneAgentValidateAction } from '../main/ets/utils/selfhdc/PhoneAgentPolicy';
import {
  AgentActionParseRetry,
  AgentActionParseRetryInfo
} from '../main/ets/utils/AgentActionParseRetry';

interface SwipePayloadForTest {
  action?: string;
  start_x?: number;
  start_y?: number;
  end_x?: number;
  end_y?: number;
  direction?: string;
  width?: number;
  height?: number;
}

interface ClickPayloadForTest {
  action?: string;
  x?: number;
  y?: number;
}

export default function agentActionParserUnitTest() {
  describe('agentActionParserUnitTest', () => {
    it('repairsBareSwipeCoordinatePairFields', 0, () => {
      let raw = '{"reasoning":"scroll list","action":"swipe","parameters":{"direction":"UP",' +
        '"start_coords":500,788,"end_coords":500,180}}';

      let parsed = AgentActionParser.parse(raw, true);
      let payload = AgentActionParser.buildHdcActionPayload(parsed, 1000, 1000) as Object as SwipePayloadForTest;

      expect(parsed.action).assertEqual('swipe');
      expect(payload.action).assertEqual('swipe_with_coords');
      expect(payload.start_x).assertEqual(500);
      expect(payload.start_y).assertEqual(788);
      expect(payload.end_x).assertEqual(500);
      expect(payload.end_y).assertEqual(180);
    });

    it('fallsBackToDirectionalSwipeWhenExplicitSwipeStartsInUnsafeHeaderArea', 0, () => {
      let raw = '{"reasoning":"scroll to earlier month","action":"swipe","parameters":' +
        '{"direction":"DOWN","start_coords":[500,200],"end_coords":[500,800]}}';

      let parsed = AgentActionParser.parse(raw, true);
      let payload = AgentActionParser.buildHdcActionPayload(parsed, 1080, 2444) as Object as SwipePayloadForTest;

      expect(parsed.action).assertEqual('swipe');
      expect(payload.action).assertEqual('swipe');
      expect(payload.direction).assertEqual('DOWN');
      expect(payload.width).assertEqual(1080);
      expect(payload.height).assertEqual(2444);
      let diagnostic = AgentActionParser.getSwipeFallbackDiagnostic(parsed, 1080, 2444);
      expect(diagnostic).assertContain('start point is outside the safe vertical area');
      expect(diagnostic).assertContain('using direction-based swipe');
    });

    it('repairsBareClickBboxField', 0, () => {
      let raw = '{"action":"click","parameters":{"target_element":"confirm","bbox":100,200,300,400}}';

      let parsed = AgentActionParser.parse(raw, true);
      let payload = AgentActionParser.buildHdcActionPayload(parsed, 1000, 1000) as Object as ClickPayloadForTest;

      expect(parsed.action).assertEqual('click');
      expect(payload.action).assertEqual('click');
      expect(payload.x).assertEqual(200);
      expect(payload.y).assertEqual(300);
    });

    it('repairsCjkPunctuationBareBboxAndTruncatedJson', 0, () => {
      // 覆盖模型同时输出中文标点、裸 bbox 序列和截断 JSON 的组合容错。
      let raw = '{"action":"click"，"parameters":{"target_element":"confirm"，"bbox"：100，200，300，400';

      let parsed = AgentActionParser.parse(raw, true);
      let payload = AgentActionParser.buildHdcActionPayload(parsed, 1000, 1000) as Object as ClickPayloadForTest;

      expect(parsed.action).assertEqual('click');
      expect(payload.action).assertEqual('click');
      expect(payload.x).assertEqual(200);
      expect(payload.y).assertEqual(300);
    });

    it('repairsQuotedCjkTargetAndBareBboxWithExtraClosingBracket', 0, () => {
      let raw = '{"reasoning":"select province","action":"click","parameters":' +
        '{"target_element":"搜索结果中的"广东"选项","bbox":132,280,1000,319]}}';

      let parsed = AgentActionParser.parse(raw, true);
      let payload = AgentActionParser.buildHdcActionPayload(parsed, 1000, 1000) as Object as ClickPayloadForTest;

      expect(parsed.action).assertEqual('click');
      expect(payload.action).assertEqual('click');
      expect(payload.x).assertEqual(566);
      expect(payload.y).assertEqual(299);
    });

    it('repairsDuplicateColonBeforeStructuredBbox', 0, () => {
      let raw = '{"reasoning":"find Beijing","action":"click_input","parameters":' +
        '{"target_element":"顶部支持搜索城市／国家的输入框","text":"北京","bbox"::[26,209,975,262]}}';

      let parsed = AgentActionParser.parse(raw, true);
      let payload = AgentActionParser.buildHdcActionPayload(parsed, 1000, 1000) as Object as ClickPayloadForTest;

      expect(parsed.action).assertEqual('click_input');
      expect(payload.action).assertEqual('click_input');
      expect(payload.x).assertEqual(500);
      expect(payload.y).assertEqual(235);
    });

    it('repairsMissingReasoningPrefixAndNestedCalendarBbox', 0, () => {
      let raw = '9月的日历。任务要求选择9月15日，我看到9月15日的日期在视图中。我将点击9月15日以选择该日\n' +
        '期。","action":"click","parameters":' +
        '{"target_element":"日历中2026年9月15日的日期单元格","bbox":[[286,699,427,770]}}}';

      let parsed = AgentActionParser.parse(raw, true);
      let payload = AgentActionParser.buildHdcActionPayload(parsed, 1000, 1000) as Object as ClickPayloadForTest;

      expect(parsed.action).assertEqual('click');
      expect(payload.action).assertEqual('click');
      expect(payload.x).assertEqual(356);
      expect(payload.y).assertEqual(734);
    });

    it('retriesUnrepairableJsonUpToThreeTimesOnSameScreen', 0, async () => {
      let requestCount = 0;
      let retryCount = 0;
      let failure = '';
      try {
        await AgentActionParseRetry.request(async (): Promise<string> => {
          requestCount += 1;
          return 'not-json';
        }, (info: AgentActionParseRetryInfo): void => {
          retryCount = info.retryNumber;
        });
      } catch (e) {
        let err = e as Error;
        failure = err.message || String(e);
      }

      expect(requestCount).assertEqual(4);
      expect(retryCount).assertEqual(3);
      expect(failure).assertContain('after 3 same-screen retries');
    });

    it('retriesTruncatedQwenInputInsteadOfExecutingRepairedPartialText', 0, async () => {
      let requestCount = 0;
      let diagnostics: string[] = [];
      // Same failure shape as the phone log: long reasoning, then text cut off before bbox.
      let truncated = '{"reasoning":"准备输入完整需求","action":"click_input",' +
        '"parameters":{"target_element":"底部输入框","text":"查询指定手机的优惠价';
      let parsed = await AgentActionParseRetry.request(async (): Promise<string> => {
        requestCount += 1;
        return requestCount === 1 ? truncated :
          '{"action":"click","parameters":{"target_element":"底部输入框","bbox":[50,900,900,960]}}';
      }, (info: AgentActionParseRetryInfo): void => { diagnostics.push(info.errorMessage); }, phoneAgentValidateAction);
      expect(requestCount).assertEqual(2);
      expect(diagnostics[0]).assertContain('truncated');
      expect(parsed.action).assertEqual('click');
    });

    it('retriesCompleteJsonWithMissingClickCoordinates', 0, async () => {
      let requestCount = 0;
      let diagnostic = '';
      let parsed = await AgentActionParseRetry.request(async (): Promise<string> => {
        requestCount += 1;
        return requestCount === 1 ? '{"action":"click_input","parameters":{"text":"需求"}}' :
          '{"action":"click_input","parameters":{"bbox":[20,880,950,960],"text":"完整需求"}}';
      }, (info: AgentActionParseRetryInfo): void => { diagnostic = info.errorMessage; }, phoneAgentValidateAction);
      expect(requestCount).assertEqual(2);
      expect(diagnostic).assertContain('PHONE_AGENT_COORDINATE: missing bbox');
      expect(AgentActionParser.getMapString(parsed.parameters, 'text')).assertEqual('完整需求');
    });

    it('rejectsTruncatedTextEvenIfCoordinatesWereAlreadyGenerated', 0, () => {
      let failure = '';
      try {
        AgentActionParser.parseExecutable('{"action":"click_input",' +
          '"parameters":{"bbox":[20,880,950,960],"text":"不能执行这段残缺文字');
      } catch (e) { failure = (e as Error).message; }
      expect(failure).assertContain('truncated');
    });

    it('keepsCompleteSyntaxRepairsAndLongEscapedInputOnPhone', 0, () => {
      let click = AgentActionParser.parseExecutable('{"action":"click","parameters":{"bbox":100,200,300,400}}');
      expect(click.action).assertEqual('click');
      let text = '查询"优惠"，保留符号{}[]与预算条件。'.repeat(35);
      let raw = '{"action":"input","parameters":{"text":' + stringifyJsonCompat(text) + '}}';
      let input = AgentActionParser.parseExecutable(raw);
      expect(AgentActionParser.getMapString(input.parameters, 'text')).assertEqual(text);
    });

    it('doesNotRetryModelRequestExceptionsAsParsingFailures', 0, async () => {
      let requests = 0;
      let retries = 0;
      let failure = '';
      try {
        await AgentActionParseRetry.request(async (): Promise<string> => {
          requests += 1;
          throw new Error('cancelled');
        }, (): void => { retries += 1; }, phoneAgentValidateAction);
      } catch (e) { failure = (e as Error).message; }
      expect(requests).assertEqual(1);
      expect(retries).assertEqual(0);
      expect(failure).assertEqual('cancelled');
    });

    it('returnsRepairedActionWhenSameScreenRetrySucceeds', 0, async () => {
      let requestCount = 0;
      let retryCount = 0;
      let parsed = await AgentActionParseRetry.request(async (): Promise<string> => {
        requestCount += 1;
        return requestCount === 1 ? 'not-json' :
          '{"action":"click","parameters":{"bbox":[100,200,300,400]}}';
      }, (info: AgentActionParseRetryInfo): void => {
        retryCount = info.retryNumber;
      });

      expect(parsed.action).assertEqual('click');
      expect(requestCount).assertEqual(2);
      expect(retryCount).assertEqual(1);
    });
  });
}
