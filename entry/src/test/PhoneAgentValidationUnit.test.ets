import { describe, expect, it } from '@ohos/hypium';
import { AgentActionParser } from '../main/ets/utils/AgentActionParser';
import { AgentActionParseRetry, AgentActionParseRetryInfo } from '../main/ets/utils/AgentActionParseRetry';
import { phoneAgentAssertCompleted, phoneAgentValidateAction } from '../main/ets/utils/selfhdc/PhoneAgentPolicy';
import { stringifyJsonCompat } from '../main/ets/utils/JsonCompat';

function rejectsAction(raw: string): boolean {
  try { phoneAgentValidateAction(AgentActionParser.parse(raw)); return false; } catch (e) { return true; }
}

export default function phoneAgentValidationUnitTest(): void {
  describe('phoneAgentValidationUnitTest', () => {
    it('rejectsInvalidCoordinatesRatherThanDroppingItemsOrClampingToTheScreenEdge', 0, () => {
      for (let coords of ['[100,null,500]', '[true,500]', '["",500]', '["bad",500]', '[1e999,500]',
        '[-1,500]', '[1001,500]', '[100,500,800]']) {
        expect(rejectsAction('{"action":"click","parameters":{"coords":' + coords + '}}')).assertTrue();
      }
      for (let box of ['[100,200,"bad",300,400]', '[300,200,100,400]', '[100,400,300,200]', '[100,200,100,400]']) {
        expect(rejectsAction('{"action":"click","parameters":{"bbox":' + box + '}}')).assertTrue();
      }
      expect(rejectsAction('{"action":"click","parameters":{"target_element":"输入框"}}')).assertTrue();
    });

    it('acceptsCompleteCoordinatesAndExistingNonDestructiveSyntaxRepairs', 0, () => {
      for (let raw of ['{"action":"click","parameters":{"coords":[0,1000]}}',
        '{"action":"click","parameters":{"bbox":100,200,300,400}}',
        '{"action":"click","parameters":{"bbox":[[100,200,300,400]]}}',
        '{"action":"click","parameters":{"coords":["100","500"]}}']) {
        expect(rejectsAction(raw)).assertFalse();
      }
    });

    it('rejectsTruncatedOrMissingInputTextBeforeAnyHdcAction', 0, () => {
      expect(rejectsAction('{"action":"input","parameters":{"text":"残缺文字')).assertTrue();
      expect(rejectsAction('{"action":"click_input","parameters":{"bbox":[1,2,3,4],"text":"残缺')).assertTrue();
      expect(rejectsAction('{"action":"input","parameters":{}}')).assertTrue();
      expect(rejectsAction('{"action":"input","parameters":{"text":null}}')).assertTrue();
      // Clearing a field remains possible when an empty string was explicitly requested.
      expect(rejectsAction('{"action":"input","parameters":{"text":""}}')).assertFalse();
      let text = '保留"引号"和{}[]符号\\。'.repeat(30);
      expect(rejectsAction('{"action":"input","parameters":{"text":' + stringifyJsonCompat(text) + '}}')).assertFalse();
    });

    it('requiresExplicitSwipeIntentInsteadOfInventingADefaultGesture', 0, () => {
      expect(rejectsAction('{"action":"swipe","parameters":{}}')).assertTrue();
      expect(rejectsAction('{"action":"swipe","parameters":{"direction":"diagonal"}}')).assertTrue();
      expect(rejectsAction('{"action":"swipe","parameters":{"start_coords":[500,700]}}')).assertTrue();
      expect(rejectsAction('{"action":"swipe","parameters":{"direction":"UP"}}')).assertFalse();
    });

    it('retriesInvalidActionParametersOnTheSameRequestBeforeDispatch', 0, async () => {
      let requests = 0;
      let diagnostic = '';
      let parsed = await AgentActionParseRetry.request(async (): Promise<string> => {
        requests += 1;
        return requests === 1 ? '{"action":"click","parameters":{"coords":[null,400]}}' :
          '{"action":"click","parameters":{"coords":[500,400]}}';
      }, (info: AgentActionParseRetryInfo): void => { diagnostic = info.errorMessage; }, phoneAgentValidateAction);
      expect(requests).assertEqual(2);
      expect(diagnostic).assertContain('PHONE_AGENT_COORDINATE');
      expect(parsed.action).assertEqual('click');
    });

    it('keepsLegacyParsingOptionalAndNeverRetriesRequestCancellation', 0, async () => {
      let legacy = await AgentActionParseRetry.request(async (): Promise<string> => {
        return '{"action":"click","parameters":{"coords":[1001,500]}}';
      });
      expect(legacy.action).assertEqual('click');
      let requests = 0;
      let failure = '';
      try {
        await AgentActionParseRetry.request(async (): Promise<string> => {
          requests += 1; throw new Error('cancelled');
        }, undefined, phoneAgentValidateAction);
      } catch (e) { failure = (e as Error).message; }
      expect(requests).assertEqual(1);
      expect(failure).assertEqual('cancelled');
    });

    it('doesNotReportFailedSuspendedOrAbortedActionsAsTaskSuccess', 0, () => {
      for (let raw of ['{"action":"done","parameters":{"status":"failed"}}',
        '{"action":"done","parameters":{"status":"suspended"}}', '{"action":"abort"}', '{"action":"stop"}']) {
        let failed = false;
        try { phoneAgentAssertCompleted(AgentActionParser.parse(raw)); } catch (e) { failed = true; }
        expect(failed).assertTrue();
      }
      phoneAgentAssertCompleted(AgentActionParser.parse('{"action":"done","parameters":{"status":"success"}}'));
    });
  });
}
