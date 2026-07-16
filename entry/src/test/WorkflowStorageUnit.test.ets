import { describe, it, expect } from '@ohos/hypium';
import fs from '@ohos.file.fs';
import { CloudModelClient, CloudModelConfig } from '../main/ets/utils/CloudModelClient';
import { RawWorkflowResourceReader, WorkflowStorage } from '../main/ets/utils/WorkflowStorage';
import {
  buildGuiTaskResultExtractionPrompt,
  fallbackGuiTaskResultExtraction,
  guiTaskResultExtractionDiagnosticsText,
  normalizeGuiTaskResultExtractionMap,
  resolveGuiTaskResultExtractionScreenshotCount,
  WorkflowRunner
} from '../main/ets/utils/WorkflowRunner';
import {
  WorkflowDefinition,
  WorkflowJsonMap,
  WorkflowManagedFile,
  WorkflowRunSummary,
  WorkflowStep,
  WorkflowStepResult,
  WorkflowTask
} from '../main/ets/utils/WorkflowTypes';
import { parseJsonCompat } from '../main/ets/utils/JsonCompat';

function findWeixinChatSummaryQuestion(steps: WorkflowStep[]): string {
  for (let i = 0; i < steps.length; i++) {
    let step = steps[i];
    if (step.type === 'tool' && step.tool_name === 'vlm_qa' && step.inputs && step.inputs.mode === 'summary' &&
      step.inputs.question && step.inputs.question.indexOf('聊天') >= 0) {
      return step.inputs.question;
    }
    if (step.steps) {
      let nestedQuestion = findWeixinChatSummaryQuestion(step.steps);
      if (nestedQuestion.length > 0) {
        return nestedQuestion;
      }
    }
    if (step.then_steps) {
      let thenQuestion = findWeixinChatSummaryQuestion(step.then_steps);
      if (thenQuestion.length > 0) {
        return thenQuestion;
      }
    }
    if (step.else_steps) {
      let elseQuestion = findWeixinChatSummaryQuestion(step.else_steps);
      if (elseQuestion.length > 0) {
        return elseQuestion;
      }
    }
  }
  return '';
}

class FailingRawWorkflowResourceReader implements RawWorkflowResourceReader {
  private requestedPaths: string[];

  constructor(requestedPaths: string[]) {
    this.requestedPaths = requestedPaths;
  }

  getRawFileContentSync(path: string): Uint8Array {
    this.requestedPaths.push(path);
    throw new Error('missing raw workflow resource: ' + path);
  }
}

class NoopWorkflowCloudModelClient extends CloudModelClient {
}

interface GuiTaskResultRawTestMap {
  outcome: string;
  summary: string;
  key_values: string;
  items: Object;
  evidence: Object;
}

interface GuiTaskResultItemTestMap {
  name: string;
}

let testRootCounter: number = 0;

function nextTestRoot(name: string): string {
  testRootCounter += 1;
  return '/tmp/workflow-storage-unit-' + name + '-' + String(new Date().getTime()) + '-' + String(testRootCounter);
}

function cleanupPath(path: string): void {
  try {
    let children = fs.listFileSync(path);
    for (let i = 0; i < children.length; i++) {
      cleanupPath(path + '/' + children[i]);
    }
    fs.rmdirSync(path);
  } catch (e) {
    try {
      fs.unlinkSync(path);
    } catch (err) {
    }
  }
}

function prepareTestRoot(path: string): void {
  cleanupPath(path);
  try {
    fs.mkdirSync(path);
  } catch (e) {
  }
}

function testCloudConfig(): CloudModelConfig {
  return {
    plannerBaseUrl: 'http://localhost:8000',
    plannerModel: 'planner-model',
    deciderBaseUrl: 'http://localhost:8000',
    apiKey: 'test-key',
    deciderModel: 'test-model'
  };
}

export default function workflowStorageUnitTest() {
  describe('workflowStorageUnitTest', () => {
    it('sortManagedFilesForDisplayUsesLatestFilesFirst', 0, () => {
      let files: WorkflowManagedFile[] = [
        { name: 'b.md', path: '/tmp/b.md', size: 20, modifiedTime: 200 },
        { name: 'a.md', path: '/tmp/a.md', size: 10, modifiedTime: 200 },
        { name: 'c.md', path: '/tmp/c.md', size: 30, modifiedTime: 100 }
      ];

      let sorted = WorkflowStorage.sortManagedFilesForDisplay(files);

      expect(sorted[0].name).assertEqual('a.md');
      expect(sorted[1].name).assertEqual('b.md');
      expect(sorted[2].name).assertEqual('c.md');
    });

    it('workflowImageInputRecognizesBase64AndPath', 0, () => {
      let base64 = '/9j/4AAQSkZJRgABAQAAAQABAAD';
      expect(WorkflowStorage.workflowImageInputKind(base64)).assertEqual('base64');
      expect(WorkflowStorage.workflowImageInputKind('data:image/jpeg;base64,' + base64)).assertEqual('data_uri');
      expect(WorkflowStorage.workflowImageInputKind('/data/storage/el2/base/files/workflows/runs/demo/steps/1/screenshot.jpg'))
        .assertEqual('path');
      expect(WorkflowStorage.workflowImageInputKind('workflows/runs/demo/steps/1/screenshot.jpg')).assertEqual('path');
    });

    it('workflowScreenshotRelativePathUsesConcreteImageFile', 0, () => {
      let relative = WorkflowStorage.workflowRunRelativePath(
        '/data/app/el2/100/base/com.clawmate.app/haps/entry/files',
        '/data/app/el2/100/base/com.clawmate.app/haps/entry/files/workflows/runs/20260608-103333-basic-gui-task/steps/3/screenshot.jpg'
      );
      expect(relative).assertEqual('workflows/runs/20260608-103333-basic-gui-task/steps/3/screenshot.jpg');
      expect(relative.endsWith('/steps/3')).assertFalse();
    });

    it('chatSessionMobileGuiToolRunRootSanitizesSessionId', 0, () => {
      expect(WorkflowStorage.chatSessionMobileGuiToolRunRoot('/tmp/files', 'session-abc'))
        .assertEqual('/tmp/files/chat-sessions/tool-runs/session-abc/mobile-gui');
      expect(WorkflowStorage.chatSessionMobileGuiToolRunRoot('/tmp/files', 'sess/ion id'))
        .assertEqual('/tmp/files/chat-sessions/tool-runs/sess_ion_id/mobile-gui');
      expect(WorkflowStorage.chatSessionMobileGuiToolRunRoot('/tmp/files', ''))
        .assertEqual('/tmp/files/chat-sessions/tool-runs/unknown/mobile-gui');
      expect(WorkflowStorage.chatSessionMobileGuiToolRunRoot('/tmp/files', '.'))
        .assertEqual('/tmp/files/chat-sessions/tool-runs/unknown/mobile-gui');
      expect(WorkflowStorage.chatSessionMobileGuiToolRunRoot('/tmp/files', '..'))
        .assertEqual('/tmp/files/chat-sessions/tool-runs/unknown/mobile-gui');
      expect(WorkflowStorage.chatSessionMobileGuiToolRunRoot('/tmp/files', '.hidden'))
        .assertEqual('/tmp/files/chat-sessions/tool-runs/_hidden/mobile-gui');
    });

    it('ensureChatSessionMobileGuiToolRunRootCreatesAndReturnsRoot', 0, () => {
      let filesDir = nextTestRoot('ensure-chat-session-root');
      try {
        prepareTestRoot(filesDir);

        let root = WorkflowStorage.ensureChatSessionMobileGuiToolRunRoot(filesDir, 'session/abc');

        expect(root).assertEqual(filesDir + '/chat-sessions/tool-runs/session_abc/mobile-gui');
        expect(fs.accessSync(root)).assertTrue();
        expect(fs.accessSync(filesDir + '/chat-sessions/tool-runs/session_abc')).assertTrue();
      } finally {
        cleanupPath(filesDir);
      }
    });

    it('ensureChatSessionMobileGuiToolRunRootThrowsWhenPathBlockedByFile', 0, () => {
      let filesDir = nextTestRoot('ensure-chat-session-blocked');
      try {
        prepareTestRoot(filesDir);
        WorkflowStorage.writeText(filesDir + '/chat-sessions', 'blocked');

        let threw = false;
        try {
          WorkflowStorage.ensureChatSessionMobileGuiToolRunRoot(filesDir, 'session-abc');
        } catch (e) {
          threw = true;
        }
        expect(threw).assertTrue();
      } finally {
        cleanupPath(filesDir);
      }
    });

    it('workflowRunRelativePathPreservesChatSessionRelativePaths', 0, () => {
      let filesDir = '/tmp/files';
      let absolutePath = '/tmp/files/chat-sessions/tool-runs/session-abc/mobile-gui/run-1/run_summary.json';
      expect(WorkflowStorage.workflowRunRelativePath(filesDir, absolutePath))
        .assertEqual('chat-sessions/tool-runs/session-abc/mobile-gui/run-1/run_summary.json');
      expect(WorkflowStorage.workflowRunRelativePath(filesDir,
        'chat-sessions/tool-runs/session-abc/mobile-gui/run-1/run_summary.json'))
        .assertEqual('chat-sessions/tool-runs/session-abc/mobile-gui/run-1/run_summary.json');
    });

    it('workflowImageInputKindRecognizesChatSessionRelativePaths', 0, () => {
      expect(WorkflowStorage.workflowImageInputKind('chat-sessions/tool-runs/session-abc/mobile-gui/run-1/screenshot.png'))
        .assertEqual('path');
      expect(WorkflowStorage.workflowRunRelativePath('/tmp/files',
        '/tmp/files/chat-sessions/tool-runs/session-abc/mobile-gui/run-1/screenshot.png'))
        .assertEqual('chat-sessions/tool-runs/session-abc/mobile-gui/run-1/screenshot.png');
    });

    it('resolveWorkflowImageInputAsBase64RejectsPathEscapeAndOutsideAbsolutePaths', 0, () => {
      let filesDir = nextTestRoot('resolve-path-safety');
      try {
        prepareTestRoot(filesDir);

        let escaped = false;
        try {
          WorkflowStorage.resolveWorkflowImageInputAsBase64(filesDir, '../../secret.png');
        } catch (e) {
          escaped = true;
        }
        expect(escaped).assertTrue();

        let outside = false;
        try {
          WorkflowStorage.resolveWorkflowImageInputAsBase64(filesDir, '/outside/secret.png');
        } catch (e) {
          outside = true;
        }
        expect(outside).assertTrue();
      } finally {
        cleanupPath(filesDir);
      }
    });

    it('resolveWorkflowImageInputAsBase64ReadsChatSessionRelativePath', 0, () => {
      let filesDir = nextTestRoot('resolve-chat-session-path');
      try {
        prepareTestRoot(filesDir);
        let relativePath = 'chat-sessions/tool-runs/session-abc/mobile-gui/run-1/screenshot.png';
        let absolutePath = filesDir + '/' + relativePath;
        WorkflowStorage.ensureDirectoryTree(filesDir + '/chat-sessions/tool-runs/session-abc/mobile-gui/run-1');
        WorkflowStorage.writeBase64Image(absolutePath,
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=');

        let threw = false;
        try {
          WorkflowStorage.resolveWorkflowImageInputAsBase64(filesDir, relativePath);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertFalse();
      } finally {
        cleanupPath(filesDir);
      }
    });

    it('resolveWorkflowImageInputAsBase64ReadsRunsRelativePath', 0, () => {
      let filesDir = nextTestRoot('resolve-runs-path');
      try {
        prepareTestRoot(filesDir);
        let relativePath = 'runs/demo/steps/1/screenshot.png';
        let absolutePath = filesDir + '/workflows/' + relativePath;
        WorkflowStorage.ensureDirectoryTree(filesDir + '/workflows/runs/demo/steps/1');
        WorkflowStorage.writeBase64Image(absolutePath,
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=');

        let threw = false;
        try {
          WorkflowStorage.resolveWorkflowImageInputAsBase64(filesDir, relativePath);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertFalse();
      } finally {
        cleanupPath(filesDir);
      }
    });

    it('guiTaskResultExtractionPromptConstrainsScreenshotOnlyJsonAndEmptyUncertainRules', 0, () => {
      let prompt = buildGuiTaskResultExtractionPrompt('查看是否有待收货订单', '页面显示暂无待收货订单');

      expect(prompt.indexOf('查看是否有待收货订单') >= 0).assertTrue();
      expect(prompt.indexOf('页面显示暂无待收货订单') >= 0).assertTrue();
      expect(prompt.indexOf('只基于截图') >= 0).assertTrue();
      expect(prompt.indexOf('严格输出 JSON 对象') >= 0).assertTrue();
      expect(prompt.indexOf('"outcome":"found|empty|partial|uncertain"') >= 0).assertTrue();
      expect(prompt.indexOf("outcome='empty'") >= 0).assertTrue();
      expect(prompt.indexOf("outcome='uncertain'") >= 0).assertTrue();
      expect(prompt.indexOf('优先填充 items') >= 0).assertTrue();
      expect(prompt.indexOf('"完成状态"') >= 0).assertTrue();
      expect(prompt.indexOf('success / failed / suspended / unknown') >= 0).assertTrue();
      expect(prompt.indexOf('key_values 不要包含“任务目标”') >= 0).assertTrue();
      expect(prompt.indexOf('订单号') >= 0).assertTrue();
      expect(prompt.indexOf('联系人') >= 0).assertTrue();
      expect(prompt.indexOf('金额') >= 0).assertTrue();
      expect(prompt.indexOf('地点') >= 0).assertTrue();
      expect(prompt.indexOf('没有可靠证据的值填 unknown') >= 0).assertTrue();
      expect(prompt.indexOf('"evidence"') < 0).assertTrue();
      expect(prompt.indexOf('关键证据') < 0).assertTrue();
      expect(prompt.indexOf('截图按时间顺序排列') >= 0).assertTrue();
      expect(prompt.indexOf('最后一张截图是最新状态') >= 0).assertTrue();
      expect(prompt.indexOf('"rank": 1') >= 0).assertTrue();
      expect(prompt.indexOf('"title"') >= 0).assertTrue();
      expect(prompt.indexOf('"order_no"') >= 0).assertTrue();
      expect(prompt.indexOf('"expected_delivery_date"') >= 0).assertTrue();
    });

    it('resolveGuiTaskResultExtractionScreenshotCountDefaultsAndHonorsStepConfig', 0, () => {
      let defaultStep: WorkflowStep = {
        id: '1',
        type: 'gui_task'
      };
      let configuredStep: WorkflowStep = {
        id: '2',
        type: 'gui_task',
        extract_result_screenshot_count: 4
      };
      let invalidStep: WorkflowStep = {
        id: '3',
        type: 'gui_task',
        extract_result_screenshot_count: 0
      };

      expect(resolveGuiTaskResultExtractionScreenshotCount(defaultStep)).assertEqual(2);
      expect(resolveGuiTaskResultExtractionScreenshotCount(configuredStep)).assertEqual(4);
      expect(resolveGuiTaskResultExtractionScreenshotCount(invalidStep)).assertEqual(2);
    });

    it('normalizeGuiTaskResultExtractionMapNormalizesOutcomeSummaryAndContainers', 0, () => {
      let item: GuiTaskResultItemTestMap = { name: '订单A' };
      let raw: GuiTaskResultRawTestMap = {
        outcome: 'done',
        summary: '',
        key_values: 'bad',
        items: [item as Object, 'bad', 12] as Object,
        evidence: ['订单列表为空', 123, false] as Object
      };

      let normalized = normalizeGuiTaskResultExtractionMap(raw as Object as WorkflowJsonMap, 'final reasoning');

      expect(normalized['outcome']).assertEqual('uncertain');
      expect(normalized['summary']).assertEqual('final reasoning');
      expect(Object.keys(normalized['key_values'] as Object).length).assertEqual(0);
      let items = normalized['items'] as Object[];
      expect(items.length).assertEqual(1);
      expect((items[0] as GuiTaskResultItemTestMap).name).assertEqual('订单A');
      expect(normalized['evidence'] === undefined).assertTrue();
    });

    it('fallbackGuiTaskResultExtractionKeepsWorkflowSuccessfulWhenExtractionFails', 0, () => {
      let fallback = fallbackGuiTaskResultExtraction('模型返回空响应', '');

      expect(fallback['outcome']).assertEqual('uncertain');
      expect(fallback['summary']).assertEqual('GUI 任务已完成，但结果提取失败。');
      expect(fallback['extraction_error']).assertEqual('模型返回空响应');
      expect(Object.keys(fallback['key_values'] as Object).length).assertEqual(0);
      expect((fallback['items'] as Object[]).length).assertEqual(0);
      expect(fallback['evidence'] === undefined).assertTrue();
    });

    it('guiTaskResultExtractionDiagnosticsIncludesPreviewAndNormalizedStats', 0, () => {
      let keyValues: WorkflowJsonMap = {};
      keyValues['total'] = 2;
      keyValues['page'] = '微博热搜';
      let item: GuiTaskResultItemTestMap = { name: '话题A' };
      let normalized: WorkflowJsonMap = {};
      normalized['outcome'] = 'found';
      normalized['summary'] = '提取到热搜';
      normalized['key_values'] = keyValues;
      normalized['items'] = [item as Object] as Object;

      let diagnostics = guiTaskResultExtractionDiagnosticsText(normalized, 'raw-response-abcdefghijklmnopqrstuvwxyz');

      expect(diagnostics.indexOf('outcome=found') >= 0).assertTrue();
      expect(diagnostics.indexOf('items.length=1') >= 0).assertTrue();
      expect(diagnostics.indexOf('key_values=total,page') >= 0).assertTrue();
      expect(diagnostics.indexOf('raw_preview=raw-response-abc') >= 0).assertTrue();
    });

    it('workflowRunSummaryCanPersistSafeGuiTaskExtractionResult', 0, () => {
      // 覆盖 GUI 任务结果提取的调试产物：run summary 只记录最终截图相对路径，避免持久化大段 base64。
      let result: WorkflowJsonMap = {};
      let resultKeyValues: WorkflowJsonMap = {};
      let resultItems: Object[] = [];
      let context: WorkflowJsonMap = {};
      let steps: Record<string, WorkflowStepResult> = {};
      result['outcome'] = 'empty';
      result['summary'] = '暂无待收货订单';
      result['key_values'] = resultKeyValues;
      result['items'] = resultItems as Object;
      let summary: WorkflowRunSummary = {
        workflow_file: '/tmp/workflow.json',
        run_dir: '/tmp/run',
        context: context,
        status: 'success',
        steps: steps,
        result_summary: '暂无待收货订单',
        result: result,
        result_extraction_error: '',
        result_screenshot_path: 'chat-sessions/tool-runs/session/mobile-gui/run/result_screenshot.jpg',
        result_screenshot_paths: [
          'chat-sessions/tool-runs/session/mobile-gui/run/result_screenshots/result_screenshot_01.jpg',
          'chat-sessions/tool-runs/session/mobile-gui/run/result_screenshots/result_screenshot_02.jpg'
        ]
      };

      expect(summary.result_summary).assertEqual('暂无待收货订单');
      expect(summary.result!['outcome']).assertEqual('empty');
      expect(summary.result_extraction_error).assertEqual('');
      expect(summary.result_screenshot_path).assertEqual('chat-sessions/tool-runs/session/mobile-gui/run/result_screenshot.jpg');
      expect(summary.result_screenshot_paths!.length).assertEqual(2);
    });

    it('runDirectoryRootPrefersOverride', 0, () => {
      expect(WorkflowRunner.runDirectoryRoot('/tmp/files', '/tmp/files/chat-sessions/tool-runs/session-abc/mobile-gui'))
        .assertEqual('/tmp/files/chat-sessions/tool-runs/session-abc/mobile-gui');
      expect(WorkflowRunner.runDirectoryRoot('/tmp/files', ''))
        .assertEqual('/tmp/files/workflows/runs');
    });

    it('runTaskThrowsWhenOverrideRunRootIsBlockedByFile', 0, async () => {
      let filesDir = nextTestRoot('run-root-override-blocked');
      let blockedRunRoot = filesDir + '/blocked-run-root';
      try {
        prepareTestRoot(filesDir);
        WorkflowStorage.writeText(blockedRunRoot, 'blocked');
        let runner = new WorkflowRunner(filesDir, new NoopWorkflowCloudModelClient(), () => testCloudConfig(),
          '127.0.0.1', (_message: string) => {
          }, blockedRunRoot);
        let task: WorkflowTask = {
          id: 'task-1',
          sceneId: 0,
          icon: 'Play',
          iconColor: '#000000',
          title: 'Minimal workflow task',
          source: 'minimal-workflow',
          enabled: true,
          configFileName: 'minimal-workflow.json',
          workflowJson: '{"steps":[{"id":"1","type":"tool","tool_name":"noop"}]}',
          lastStatus: '未运行',
          lastRun: '尚未执行',
          lastMessage: '等待执行'
        };

        let threw = false;
        let message = '';
        try {
          await runner.runTask(task);
        } catch (e) {
          let err = e as Error;
          threw = true;
          message = err.message || String(e);
        }

        expect(threw).assertTrue();
        expect(message.indexOf('Failed to ensure directory: ' + blockedRunRoot) >= 0).assertTrue();
      } finally {
        cleanupPath(filesDir);
      }
    });

    it('runSummaryDeleteTargetUsesWholeRunDirectory', 0, () => {
      let filesDir = '/data/app/el2/100/base/com.clawmate.app/haps/entry/files';
      let file: WorkflowManagedFile = {
        name: '20260609-104256-basic-gui-task/run_summary.json',
        path: filesDir + '/workflows/runs/20260609-104256-basic-gui-task/run_summary.json',
        size: 128,
        modifiedTime: 0
      };

      expect(WorkflowStorage.managedFileDeleteTarget(filesDir, 'run', file))
        .assertEqual(filesDir + '/workflows/runs/20260609-104256-basic-gui-task');
    });

    it('rootConfigDeleteTargetKeepsSingleConfigFile', 0, () => {
      let filesDir = '/data/app/el2/100/base/com.clawmate.app/haps/entry/files';
      let file: WorkflowManagedFile = {
        name: 'default_ele_order.json',
        path: filesDir + '/workflows/configs/default_ele_order.json',
        size: 128,
        modifiedTime: 0
      };

      expect(WorkflowStorage.managedFileDeleteTarget(filesDir, 'config', file)).assertEqual(file.path);
    });

    it('defaultWeixinSummaryPromptRequiresChatTimeAnchors', 0, () => {
      let workflow = parseJsonCompat<WorkflowDefinition>(WorkflowStorage.defaultWeixinWorkflow());
      let question = findWeixinChatSummaryQuestion(workflow.steps);

      expect(question.length > 0).assertTrue();
      expect(question.indexOf('聊天对象') >= 0).assertTrue();
      expect(question.indexOf('当前聊天对象') >= 0).assertTrue();
      expect(question.indexOf('消息发送绝对时间') >= 0).assertTrue();
      expect(question.indexOf('聊天日期分隔符') >= 0).assertTrue();
      expect(question.indexOf('同一时间锚点') >= 0).assertTrue();
      expect(question.indexOf('只有截图中完全没有聊天时间锚点时') >= 0).assertTrue();
      expect(question.indexOf('任务执行时间') >= 0).assertTrue();
      expect(question.indexOf('事件相对时间') >= 0).assertTrue();
      expect(question.indexOf('事件绝对时间') >= 0).assertTrue();
      let forbiddenTimeEventsKey = 'time' + '_events';
      expect(question.indexOf(forbiddenTimeEventsKey)).assertEqual(-1);
    });

    it('codeDefinedDefaultTaskUsesLatestWorkflowUnlessUserModified', 0, () => {
      let defaultTask: WorkflowTask = {
        id: 'default_weixin_chat',
        sceneId: 3,
        icon: 'Chat',
        iconColor: '#FF9347',
        title: '收集指定微信用户近3页的聊天记录',
        source: 'basic-gui-task',
        enabled: true,
        configFileName: 'default_weixin_chat.json',
        workflowJson: '{"version":"new-code-default"}',
        lastStatus: '未运行',
        lastRun: '尚未执行',
        lastMessage: '点击运行后开始执行 workflow'
      };
      let storedTask: WorkflowTask = {
        id: 'default_weixin_chat',
        sceneId: 3,
        icon: 'Chat',
        iconColor: '#FF9347',
        title: '收集指定微信用户近3页的聊天记录',
        source: 'basic-gui-task',
        enabled: false,
        configFileName: 'default_weixin_chat.json',
        workflowJson: '{"version":"old-stored-default"}',
        lastStatus: '已完成',
        lastRun: '2026/6/9 04:42:00',
        lastMessage: '最近运行完成'
      };

      let synced = WorkflowStorage.mergeCodeDefinedDefaultTaskForTest(defaultTask, storedTask);
      expect(synced.workflowJson).assertEqual(defaultTask.workflowJson);
      expect(synced.enabled).assertFalse();
      expect(synced.lastStatus).assertEqual('已完成');
      expect(synced.lastRun).assertEqual('2026/6/9 04:42:00');

      let modifiedTask: WorkflowTask = {
        id: storedTask.id,
        sceneId: storedTask.sceneId,
        icon: storedTask.icon,
        iconColor: storedTask.iconColor,
        title: storedTask.title,
        source: storedTask.source,
        enabled: storedTask.enabled,
        configFileName: storedTask.configFileName,
        workflowJson: storedTask.workflowJson,
        lastStatus: storedTask.lastStatus,
        lastRun: storedTask.lastRun,
        lastMessage: storedTask.lastMessage,
        isUserModified: true
      };
      let preserved = WorkflowStorage.mergeCodeDefinedDefaultTaskForTest(defaultTask, modifiedTask);
      expect(preserved.workflowJson).assertEqual(storedTask.workflowJson);
      expect(preserved.isUserModified).assertTrue();
    });

    it('defaultWorkflowResourceInstallReportsRawFileFailures', 0, () => {
      let requestedPaths: string[] = [];
      let failurePaths: string[] = [];
      let failureMessages: string[] = [];
      let reader: RawWorkflowResourceReader = new FailingRawWorkflowResourceReader(requestedPaths);

      let failureCount = WorkflowStorage.installDefaultWorkflowResourcesForTest('/tmp/workflow-raw-install-failure',
        reader, (rawFilePath: string, cause: Error) => {
          failurePaths.push(rawFilePath);
          failureMessages.push(cause.message);
        });

      expect(failureCount > 0).assertTrue();
      expect(failurePaths.length).assertEqual(failureCount);
      expect(failurePaths[0].startsWith('workflows/configs/')).assertTrue();
      expect(failureMessages[0].indexOf(failurePaths[0]) >= 0).assertTrue();
      expect(requestedPaths[0]).assertEqual(failurePaths[0]);
    });
  });
}
