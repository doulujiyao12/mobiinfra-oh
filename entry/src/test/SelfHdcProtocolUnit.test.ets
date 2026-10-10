import { describe, expect, it } from '@ohos/hypium';
import {
  HdcAuth, HdcCommand, HdcPacketStream, decodeHdcHandshake, decodeHdcTlv,
  encodeHdcHandshake, encodeHdcPacket, encodeHdcTlv, isHdcAuthPending, joinHdcBytes
} from '../main/ets/utils/selfhdc/HdcProtocol';
import {
  parseSelfHdcEndpoint, selfHdcHasCommandFailure, selfHdcShellQuote, selfHdcSwipeForSize
} from '../main/ets/utils/selfhdc/SelfHdcPolicy';
import {
  buildHdcShellPlan, hdcShellOutputPreview, parseHdcShellResult
} from '../main/ets/utils/selfhdc/HdcShell';
import { HdcAuthBarrier } from '../main/ets/utils/selfhdc/HdcAuthBarrier';
import { PhoneHdcActions } from '../main/ets/utils/selfhdc/PhoneHdcActions';
import { phoneHdcBundle, phoneHdcMainAbility } from '../main/ets/utils/selfhdc/PhoneHdcApp';
import { parsePhoneHdcUiInputHelp } from '../main/ets/utils/selfhdc/PhoneHdcCapabilities';
import { selfHdcIsUsableWifiIpv4, selectSelfHdcWifiIpv4 } from '../main/ets/utils/selfhdc/SelfHdcNetworkPolicy';
import { phoneAgentAssertCompleted, phoneAgentLogText, phoneAgentScreenSize } from '../main/ets/utils/selfhdc/PhoneAgentPolicy';
import { localVisionPromptHw } from '../main/ets/utils/LocalVisionImageShape';
import { SelfHdcTaskSettings } from '../main/ets/utils/selfhdc/SelfHdcTaskSettings';
import { selfHdcControlMode, selfHdcSetupProblem } from '../main/ets/utils/selfhdc/SelfHdcSetupPolicy';
import { AgentActionParser } from '../main/ets/utils/AgentActionParser';
import { WorkflowJsonMap } from '../main/ets/utils/WorkflowTypes';

interface PhoneTestPayload {
  action: string;
  x?: number;
  y?: number;
  text?: string;
  target_element?: string;
  submit_enter?: boolean;
  direction?: string;
  key?: string;
}

function phoneTestMap(payload: PhoneTestPayload): WorkflowJsonMap { return payload as Object as WorkflowJsonMap; }

function rejects(operation: () => void): boolean {
  try { operation(); } catch (e) { return true; }
  return false;
}

// Command declaration lines from the reported OpenHarmony-7.0.0.105/API26 help output.
const REPORTED_UIINPUT_HELP: string = 'Missing parameter. \r\n\r\nUSAGE : \r\n' +
  'help                                                                                  print uiInput usage\r\n' +
  'click/doubleClick/longClick <x> <y> [displayId]                           click on the target coordinates\r\n' +
  'swipe/drag <from_x> <from_y> <to_x> <to_y> [velocity] [displayId]\r\n' +
  'keyEvent <keyID/Back/Home/Power> [displayId]                                              inject keyEvent\r\n' +
  'keyEvent <keyID_0> <keyID_1> [keyID_2] [displayId]                               keyID_2 defaults to None\r\n' +
  'inputText <x> <y> <text> [displayId]                             inputText at the target coordinate point\r\n' +
  'text <text> [displayId]                               input text at the location where is already focused\r\n';

export default function selfHdcProtocolUnitTest(): void {
  describe('selfHdcProtocolUnitTest', () => {
    it('defaultsToPhoneAndPreservesAnExplicitDesktopSelection', 0, () => {
      expect(new SelfHdcTaskSettings().mode).assertEqual('phone');
      expect(selfHdcControlMode(undefined)).assertEqual('phone');
      expect(selfHdcControlMode('')).assertEqual('phone');
      expect(selfHdcControlMode('invalid-mode')).assertEqual('phone');
      expect(selfHdcControlMode('phone')).assertEqual('phone');
      expect(selfHdcControlMode('pc')).assertEqual('pc');
    });
    it('reportsBothMissingAddressAndMissingWirelessPort', 0, () => {
      let problem = selfHdcSetupProblem({ ip: '', port: '', autoIp: true }, '');
      expect(problem.indexOf('Wi-Fi IP') >= 0).assertTrue();
      expect(problem.indexOf('尚未填写手机 IP') >= 0).assertTrue();
      expect(problem.indexOf('尚未填写无线调试连接端口') >= 0).assertTrue();
      expect(selfHdcSetupProblem({ ip: '192.168.1.108', port: '33117', autoIp: true }, '192.168.1.108'))
        .assertEqual('');
    });
    it('doesNotTreatAnOldSavedIpAsAFreshDetection', 0, () => {
      expect(selfHdcSetupProblem({ ip: '192.168.1.108', port: '33117', autoIp: true }, '').length > 0).assertTrue();
      expect(selfHdcSetupProblem({ ip: '127.0.0.1', port: '33117', autoIp: false }, '')).assertEqual('');
    });
    it('rejectsInvalidAddressAndPortBeforeStartingDeviceControl', 0, () => {
      expect(selfHdcSetupProblem({ ip: '192.168.1.999', port: '33117', autoIp: false }, '').length > 0).assertTrue();
      for (let port of ['0', '65536', '12abc']) {
        expect(selfHdcSetupProblem({ ip: '127.0.0.1', port: port, autoIp: false }, '').length > 0).assertTrue();
      }
    });
    it('keepsOriginalPhoneGeometryForQuarterAndHalfSizeAgentImages', 0, () => {
      let screen = phoneAgentScreenSize({ status: 'ok', image_b64: 'image-test-fixture', width: 270, height: 611,
        screen_width: 1081, screen_height: 2445 });
      let parsed = AgentActionParser.parse('{"action":"click","parameters":{"coords":[500,900]}}');
      let payload = AgentActionParser.buildHdcActionPayload(parsed, screen.width, screen.height);
      expect(payload['x']).assertEqual(540);
      expect(payload['y']).assertEqual(2200); // Multiplying the quarter image height by 4 would produce 2199.
      let actions = new PhoneHdcActions(); actions.setScreen(screen.width, screen.height);
      expect(actions.plan(payload).commands[0].command).assertEqual('uitest uiInput click 540 2200');
      expect(localVisionPromptHw(270, 611)).assertEqual('600,270');
      let landscape = phoneAgentScreenSize({ status: 'ok', image_b64: 'image-test-fixture', width: 1222, height: 540,
        screen_width: 2445, screen_height: 1081 });
      expect(landscape.width).assertEqual(2445);
      expect(landscape.height).assertEqual(1081);
      expect(localVisionPromptHw(1222, 540)).assertEqual('270,600');
      expect(rejects((): void => { phoneAgentScreenSize({ status: 'ok', image_b64: 'image-test-fixture', width: 270, height: 611 }); })).assertTrue();
    });
    it('doesNotReportFailedSuspendedOrStoppedPhoneAgentTasksAsSuccess', 0, () => {
      phoneAgentAssertCompleted(AgentActionParser.parse('{"action":"done","parameters":{"status":"success"}}'));
      phoneAgentAssertCompleted(AgentActionParser.parse('{"action":"done"}'));
      for (let raw of ['{"action":"done","parameters":{"status":"failed"}}',
        '{"action":"done","status":"suspended"}', '{"action":"stop"}', '{"action":"terminate"}',
        '{"action":"done","status":"failed","parameters":{"status":"success"}}']) {
        expect(rejects((): void => { phoneAgentAssertCompleted(AgentActionParser.parse(raw)); })).assertTrue();
      }
    });
    it('omitsImageDataFromPhoneAgentPromptLogs', 0, () => {
      expect(phoneAgentLogText('image=data:image/jpeg;base64,/9j/SECRETIMAGE==... chars=12000'))
        .assertEqual('image=[image data omitted]... chars=12000');
      expect(phoneAgentLogText('MODEL backend=local-MNN')).assertEqual('MODEL backend=local-MNN');
    });
    it('refreshesAChangedWifiIpAndAvoidsCellularAndVpnAddresses', 0, () => {
      expect(selectSelfHdcWifiIpv4([
        { ip: '10.0.0.8', isWifi: false, isVpn: false, isDefault: true },
        { ip: '10.8.0.2', isWifi: true, isVpn: true, isDefault: true },
        { ip: '192.168.2.108', isWifi: true, isVpn: false, isDefault: false }
      ], '192.168.1.108')).assertEqual('192.168.2.108');
      expect(selectSelfHdcWifiIpv4([
        { ip: '192.168.1.108', isWifi: true, isVpn: false, isDefault: false },
        { ip: '192.168.2.108', isWifi: true, isVpn: false, isDefault: true }
      ], '192.168.1.108')).assertEqual('192.168.2.108');
      expect(selectSelfHdcWifiIpv4([
        { ip: '192.168.1.108', isWifi: true, isVpn: false, isDefault: false },
        { ip: '192.168.2.108', isWifi: true, isVpn: false, isDefault: false }
      ], '192.168.2.108')).assertEqual('192.168.2.108');
    });
    it('doesNotAutoSelectLoopbackLinkLocalInvalidOrUnavailableWifi', 0, () => {
      for (let invalid of ['127.0.0.1', '0.0.0.0', '169.254.1.2', '224.0.0.1', '255.255.255.255', '192.168.1.999', '::1']) {
        expect(selfHdcIsUsableWifiIpv4(invalid)).assertFalse();
      }
      expect(selfHdcIsUsableWifiIpv4('192.168.101.108')).assertTrue();
      expect(selectSelfHdcWifiIpv4([], '192.168.1.108')).assertEqual('');
      expect(selectSelfHdcWifiIpv4([
        { ip: '10.0.0.8', isWifi: false, isVpn: false, isDefault: true }
      ], '192.168.1.108')).assertEqual('');
    });
    it('acceptsTheReportedExitOneUiInputHelpWithoutWeakeningActions', 0, () => {
      let help = parsePhoneHdcUiInputHelp(1, REPORTED_UIINPUT_HELP);
      expect(help.commands.join(',')).assertEqual('click,swipe,text,keyEvent');
      expect(help.acceptedNonzeroExit).assertTrue();
      let normal = parsePhoneHdcUiInputHelp(0, REPORTED_UIINPUT_HELP.replace('Missing parameter. \r\n\r\n', ''));
      expect(normal.acceptedNonzeroExit).assertFalse();
      // Shell results retain the nonzero exit. The exception is local to the read-only help probe.
      let marker = '__SELF_HDC_EXIT_1_100__:';
      expect(parseHdcShellResult('No Error\n' + marker + '1\n', marker).exitCode).assertEqual(1);
    });
    it('rejectsRealHelpFailuresAndWordsThatAreNotCommandDeclarations', 0, () => {
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(127, REPORTED_UIINPUT_HELP); })).assertTrue();
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(2, REPORTED_UIINPUT_HELP); })).assertTrue();
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(1, 'Missing parameter.'); })).assertTrue();
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(0, 'No Error'); })).assertTrue();
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(1, 'Permission denied\n' + REPORTED_UIINPUT_HELP); })).assertTrue();
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(0, REPORTED_UIINPUT_HELP + 'Error: service unavailable\n'); })).assertTrue();
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(1, REPORTED_UIINPUT_HELP + 'Permission denied\n'); })).assertTrue();
      let withoutText = REPORTED_UIINPUT_HELP.replace(/^text <text>[^\r\n]*\r\n/m, '');
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(1, withoutText); })).assertTrue();
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(1, withoutText + '  supports text input in focus\n'); })).assertTrue();
      let withoutClick = REPORTED_UIINPUT_HELP.replace(/^click\/doubleClick\/longClick[^\r\n]*\r\n/m, '');
      expect(rejects((): void => { parsePhoneHdcUiInputHelp(1, withoutClick); })).assertTrue();
    });
    it('mapsHalfSizeDeciderCoordinatesToThePhysicalScreen', 0, () => {
      let actions = new PhoneHdcActions();
      actions.setScreen(1080, 2444);
      let parsed = AgentActionParser.parse('{"action":"click","parameters":{"coords":[500,500]}}');
      // WorkflowRunner's existing PC contract doubles 540x1222 screenshot dimensions.
      let payload = AgentActionParser.buildHdcActionPayload(parsed, 540 * 2, 1222 * 2);
      expect(actions.plan(payload).commands[0].command).assertEqual('uitest uiInput click 540 1222');
      expect(rejects((): void => { actions.plan(phoneTestMap({ action: 'click', x: 2160, y: 100 })); })).assertTrue();
    });
    it('focusesClearsAndQuotesInputBeforeSubmittingAsThePcDriverDoes', 0, () => {
      let actions = new PhoneHdcActions(); actions.setScreen(1080, 2444);
      let plan = actions.plan(phoneTestMap({ action: 'click_input', x: 200, y: 300, text: "中文 a'b;$(id)" }));
      expect(plan.commands.map((command): string => command.label).join('|')).assertEqual(
        'activate/click|select-all|clear-input|input-text chars=12|submit-enter');
      expect(plan.commands[1].command).assertEqual('uitest uiInput keyEvent 2072 2017');
      expect(plan.commands[2].command).assertEqual('uitest uiInput keyEvent 2071');
      expect(plan.commands[3].command).assertEqual("uitest uiInput text '中文 a'\\''b;$(id)'");
      expect(plan.commands[3].sensitive).assertTrue();
      expect(plan.commands[4].command).assertEqual('uitest uiInput keyEvent 2054');
    });
    it('refusesBlindInputAndClearsRememberedFocusAfterNavigation', 0, () => {
      let actions = new PhoneHdcActions(); actions.setScreen(1080, 2444);
      expect(rejects((): void => { actions.plan(phoneTestMap({ action: 'input', text: 'hello' })); })).assertTrue();
      let clicked = actions.plan(phoneTestMap({ action: 'click', x: 200, y: 300, target_element: '搜索输入框' }));
      // A failed/uncommitted click must not establish a remembered target.
      expect(rejects((): void => { actions.plan(phoneTestMap({ action: 'input', text: 'hello' })); })).assertTrue();
      actions.commit(clicked);
      let input = actions.plan(phoneTestMap({ action: 'input', text: ' hello ', submit_enter: false }));
      expect(input.commands[3].command).assertEqual("uitest uiInput text ' hello '");
      expect(input.commands.length).assertEqual(4);
      actions.commit(actions.plan(phoneTestMap({ action: 'sleep' })));
      expect(actions.plan(phoneTestMap({ action: 'input', text: 'after wait' })).commands.length).assertEqual(5);
      actions.commit(actions.plan(phoneTestMap({ action: 'keyevent', key: 'ENTER' })));
      expect(actions.plan(phoneTestMap({ action: 'input', text: 'after enter' })).commands.length).assertEqual(5);
      actions.commit(actions.plan(phoneTestMap({ action: 'keyevent', key: 'BACK' })));
      expect(rejects((): void => { actions.plan(phoneTestMap({ action: 'input', text: 'hello' })); })).assertTrue();
      expect(rejects((): void => { actions.plan(phoneTestMap({ action: 'input', x: 20, text: 'hello' })); })).assertTrue();
      expect(rejects((): void => { actions.plan(phoneTestMap({ action: 'click_input', x: 20, y: 30, text: 'a\0b' })); })).assertTrue();
    });
    it('reproducesPcSwipeDirectionsAndRejectsShellInjectionInKeys', 0, () => {
      let actions = new PhoneHdcActions(); actions.setScreen(1080, 2444);
      expect(actions.plan(phoneTestMap({ action: 'swipe', direction: 'up' })).commands[0].command)
        .assertEqual('uitest uiInput swipe 540 1710 540 733');
      expect(actions.plan(phoneTestMap({ action: 'swipe', direction: 'right' })).commands[0].command)
        .assertEqual('uitest uiInput swipe 324 1222 756 1222');
      expect(rejects((): void => { actions.plan(phoneTestMap({ action: 'keyevent', key: '2; id' })); })).assertTrue();
      expect(rejects((): void => { actions.plan(phoneTestMap({ action: 'swipe', direction: 'diagonal' })); })).assertTrue();
    });
    it('resolvesAliasesAndTheHomeAbilityInsteadOfGuessingEntryAbility', 0, () => {
      expect(phoneHdcBundle('淘宝', '')).assertEqual('com.taobao.taobao4hmos');
      expect(rejects((): void => { phoneHdcBundle('', 'com.example;id'); })).assertTrue();
      let dump = 'bundle info:\n{"hapModuleInfos":[{"mainElementName":"OtherAbility","abilities":[' +
        '{"name":"Taobao_mainAbility","skills":[{"actions":["action.system.home"],"entities":["entity.system.home"]}]}]}]}';
      expect(phoneHdcMainAbility(dump)).assertEqual('Taobao_mainAbility');
      expect(phoneHdcMainAbility('{"moduleInfos":[{"mainAbility":"MainAbility"}]}')).assertEqual('MainAbility');
      let multiModule = '{"mainEntry":"entry","hapModuleInfos":[' +
        '{"moduleName":"feature","mainAbility":"FeatureAbility","abilityInfos":[{"name":"FeatureAbility","skills":[{"actions":["action.system.home"]}]}]},' +
        '{"moduleName":"entry","mainAbility":"MainAbility","abilityInfos":[{"name":"MainAbility","skills":[{"actions":["action.system.home"]}]}]}]}';
      expect(phoneHdcMainAbility(multiModule)).assertEqual('MainAbility');
      expect(phoneHdcMainAbility('mainAbilityName: MainAbility\n')).assertEqual('MainAbility');
      expect(rejects((): void => { phoneHdcMainAbility('mainAbility: MainAbility;id\n'); })).assertTrue();
      expect(rejects((): void => { phoneHdcMainAbility('{"moduleInfos":[]}'); })).assertTrue();
    });
    it('matchesDeviceProtocolGoldenFrame', 0, () => {
      let frame = encodeHdcPacket({ channel: 7, command: HdcCommand.EchoRaw, data: new Uint8Array([1, 2, 3]) });
      // Packed 11-byte HW header, BE lengths, protobuf protection including vCode=9.
      expect(Array.from(frame).join(',')).assertEqual('72,87,0,0,1,0,8,0,0,0,3,8,7,16,10,24,0,32,9,1,2,3');
    });
    it('reassemblesFragmentedAndCoalescedFrames', 0, () => {
      let first = encodeHdcPacket({ channel: 111, command: 1001, data: new Uint8Array([65]) });
      let second = encodeHdcPacket({ channel: 112, command: 2, data: new Uint8Array([1]) });
      let stream = new HdcPacketStream();
      expect(stream.feed(first.slice(0, 1)).length).assertEqual(0);
      expect(stream.feed(first.slice(1, 12)).length).assertEqual(0);
      let result = stream.feed(joinHdcBytes([first.slice(12), second]));
      expect(result.length).assertEqual(2);
      expect(result[0].channel).assertEqual(111);
      expect(result[0].command).assertEqual(1001);
      expect(result[0].data[0]).assertEqual(65);
      expect(result[1].channel).assertEqual(112);
    });
    it('rejectsWrongPortBadProtectionAndOversizedFrames', 0, () => {
      let frame = encodeHdcPacket({ channel: 1, command: 10, data: new Uint8Array([9]) });
      let wrongMagic = frame.slice(); wrongMagic[0] = 0;
      expect(rejects((): void => { new HdcPacketStream().feed(wrongMagic); })).assertTrue();
      let wrongCode = frame.slice(); wrongCode[18] = 8;
      expect(rejects((): void => { new HdcPacketStream().feed(wrongCode); })).assertTrue();
      let oversized = frame.slice(); new DataView(oversized.buffer).setUint32(7, 0x7FFFFFFF, false);
      expect(rejects((): void => { new HdcPacketStream().feed(oversized); })).assertTrue();
      let badVarint = frame.slice(); badVarint[18] = 128;
      expect(rejects((): void => { new HdcPacketStream().feed(badVarint); })).assertTrue();
    });
    it('preservesBinaryAuthenticationChallenge', 0, () => {
      let encoded = encodeHdcHandshake({
        banner: 'OHOS HDC', auth: HdcAuth.Signature, session: 7, target: '',
        data: new Uint8Array([0, 255, 128]), version: 'v'
      });
      expect(Array.from(encoded).join(',')).assertEqual(
        '10,8,79,72,79,83,32,72,68,67,16,2,24,7,34,0,42,3,0,255,128,50,1,118');
      let decoded = decodeHdcHandshake(encoded);
      expect(decoded.auth).assertEqual(HdcAuth.Signature);
      expect(Array.from(decoded.data).join(',')).assertEqual('0,255,128');
    });
    it('parsesAuthTlvAndDistinguishesPendingFromDenied', 0, () => {
      let fields = decodeHdcTlv(joinHdcBytes([
        encodeHdcTlv('authtype', '1'), encodeHdcTlv('daemonauthstatus', 'DAEMON_UNAUTH'),
        encodeHdcTlv('emgmsg', '[E000002]: pending')
      ]));
      expect(fields.get('authtype')).assertEqual('1');
      expect(fields.get('daemonauthstatus')).assertEqual('DAEMON_UNAUTH');
      expect(isHdcAuthPending(fields.get('emgmsg') || '')).assertTrue();
      expect(isHdcAuthPending('[E000003]: denied')).assertFalse();
      let badLength = encodeHdcTlv('authtype', '1').slice(0, 32);
      expect(rejects((): void => { decodeHdcTlv(badLength); })).assertTrue();
    });
    it('validatesEndpointAndDerivesScreenRelativeSwipe', 0, () => {
      let endpoint = parseSelfHdcEndpoint(' 192.168.1.108 ', '33117');
      expect(endpoint.ip).assertEqual('192.168.1.108');
      expect(endpoint.port).assertEqual(33117);
      expect(rejects((): void => { parseSelfHdcEndpoint('192.168.1.999', '1234'); })).assertTrue();
      expect(rejects((): void => { parseSelfHdcEndpoint('127.0.0.1', '65536'); })).assertTrue();
      expect(rejects((): void => { parseSelfHdcEndpoint('127.0.0.1; id', '1234'); })).assertTrue();
      expect(selfHdcShellQuote("a'b")).assertEqual("'a'\\''b'");
      let swipe = selfHdcSwipeForSize(1080, 2340);
      expect(swipe.x).assertEqual(540);
      expect(swipe.startY).assertEqual(1684);
      expect(swipe.endY).assertEqual(748);
    });
    it('acceptsTheReportedUitestSuccessReply', 0, () => {
      let marker = '__SELF_HDC_EXIT_1499113813_105__:';
      let result = parseHdcShellResult('No Error\n\n' + marker + '0\n', marker);
      expect(result.exitCode).assertEqual(0);
      expect(selfHdcHasCommandFailure(result.output)).assertFalse();
      expect(selfHdcHasCommandFailure('  NO ERROR\r\n')).assertFalse();
      expect(selfHdcHasCommandFailure('start ability successfully.\n')).assertFalse();
    });
    it('doesNotHideRealErrorsAlongsideUitestSuccessText', 0, () => {
      expect(selfHdcHasCommandFailure('No Error\nError: input rejected\n')).assertTrue();
      expect(selfHdcHasCommandFailure('Failed to connect\r\nNo Error\r\n')).assertTrue();
      expect(selfHdcHasCommandFailure('No Error: Error: invalid operation')).assertTrue();
      expect(selfHdcHasCommandFailure('操作失败')).assertTrue();
    });
    it('buildsAnExitMarkerForCompoundCommands', 0, () => {
      let plan = buildHdcShellPlan('printf SELF_HDC_PHONE_OK; id', 2410019984, 100);
      expect(plan.wireCommand.startsWith('( ')).assertTrue();
      expect(plan.wireCommand.indexOf('printf SELF_HDC_PHONE_OK; id')).assertLarger(0);
      expect(plan.marker).assertEqual('__SELF_HDC_EXIT_2410019984_100__:');
      expect(plan.wireCommand.indexOf("'\\n__SELF_HDC_EXIT_")).assertLarger(0);
      expect(rejects((): void => { buildHdcShellPlan('id\0ignored', 1, 100); })).assertTrue();
    });
    it('keepsDeviceExitCodeAndDoesNotAcceptThe17ByteTruncatedReply', 0, () => {
      let marker = '__SELF_HDC_EXIT_2410019984_100__:';
      expect(rejects((): void => { parseHdcShellResult('SELF_HDC_PHONE_OK', marker); })).assertTrue();
      let result = parseHdcShellResult('SELF_HDC_PHONE_OKuid=2000(shell)\n\n' + marker + '0\n', marker);
      expect(result.output).assertEqual('SELF_HDC_PHONE_OKuid=2000(shell)\n');
      expect(result.exitCode).assertEqual(0);
      expect(parseHdcShellResult('no such command\n' + marker + '127\r\n\0', marker).exitCode).assertEqual(127);
      expect(rejects((): void => { parseHdcShellResult('\n' + marker + '0\ntrailing data', marker); })).assertTrue();
      expect(rejects((): void => { parseHdcShellResult('\n' + marker + '999\n', marker); })).assertTrue();
    });
    it('logsShortDiagnosticRepliesWithoutExposingScreenshotData', 0, () => {
      expect(hdcShellOutputPreview('SELF_HDC_PHONE_OK\n', false)).assertEqual('SELF_HDC_PHONE_OK\\n');
      expect(hdcShellOutputPreview('iVBORw0KGgoSECRETIMAGE', true)).assertEqual('(sensitive output omitted)');
      expect(hdcShellOutputPreview('x'.repeat(800), false).length).assertLess(800);
    });
    it('doesNotReleaseShellAtAuthSuccessBeforeClosingChannelZero', 0, () => {
      let barrier = new HdcAuthBarrier();
      expect(barrier.hasSuccess()).assertFalse();
      expect(barrier.closeAcknowledged()).assertFalse();
      barrier.authOk(true);
      expect(barrier.hasSuccess()).assertTrue();
      expect(barrier.isReady()).assertFalse();
      // In the reported failure shell channel 100 was sent here, before ACKing channel 0.
      expect(barrier.closeAcknowledged()).assertTrue();
      expect(barrier.isReady()).assertTrue();
      expect(rejects((): void => { barrier.closeAcknowledged(); })).assertTrue();
    });
    it('waitsForAllPendingAuthNoticeClosesBeforeReleasingShell', 0, () => {
      let barrier = new HdcAuthBarrier();
      barrier.authOk(false); // E000002: system confirmation dialog.
      barrier.authOk(true); // SUCCESS may arrive before the earlier close has been consumed.
      expect(barrier.closeAcknowledged()).assertFalse();
      expect(barrier.isReady()).assertFalse();
      expect(barrier.closeAcknowledged()).assertTrue();
      let denied = new HdcAuthBarrier();
      denied.authOk(false);
      expect(denied.closeAcknowledged()).assertFalse();
      expect(denied.hasSuccess()).assertFalse();
      expect(denied.isReady()).assertFalse();
    });
  });
}
