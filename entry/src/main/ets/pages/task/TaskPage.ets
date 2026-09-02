import { common } from '@kit.AbilityKit';
import { JSON as ArkJSON } from '@kit.ArkTS';
import { promptAction, router } from '@kit.ArkUI';
import { AppHeader } from '../../components/AppHeader';
import { AiGeneratedBadge } from '../../components/AiGeneratedBadge';
import { MarkdownView } from '../../components/MarkdownView';
import { WorkflowStorage, SystemResourceManagerReader } from '../../utils/WorkflowStorage';
import { showToastSafely } from '../../utils/PromptSafe';
import {
  WorkflowCondition,
  WorkflowDefinition,
  WorkflowFileStats,
  WorkflowJsonMap,
  WorkflowJsonValue,
  WorkflowManagedFile,
  WorkflowStep,
  WorkflowTask,
  WorkflowToolInputs
} from '../../utils/WorkflowTypes';
import { workflowSceneConfigs, WorkflowSceneConfig } from '../../utils/WorkflowSceneConfig';

interface WorkflowNodeTemplate {
  key: string;
  label: string;
  shortLabel: string;
  group: string;
  accentColor: string;
  backgroundColor: string;
}

interface StepPathPart {
  branch: string;
  index: number;
}

interface SegmentOption {
  label: string;
  value: string;
}

interface FlowRenderItem {
  key: string;
  path: string;
  step: WorkflowStep;
  summary?: WorkflowStep;
  isPair: boolean;
}

const NODE_TEMPLATES: WorkflowNodeTemplate[] = [
  { key: 'open_app', label: '打开应用', shortLabel: '打开', group: '智能 GUI', accentColor: '#276EF1', backgroundColor: '#EAF2FF' },
  { key: 'gui_task', label: 'GUI 任务', shortLabel: '操作', group: '智能 GUI', accentColor: '#276EF1', backgroundColor: '#EAF2FF' },
  { key: 'shot_summary', label: '截图 + Summary', shortLabel: '采集', group: '采集整理', accentColor: '#148F73', backgroundColor: '#EAF8F3' },
  { key: 'if', label: 'If 条件', shortLabel: '条件', group: '控制流', accentColor: '#7C4DFF', backgroundColor: '#F0EAFF' },
  { key: 'for_loop', label: 'For 循环', shortLabel: '循环', group: '控制流', accentColor: '#7C4DFF', backgroundColor: '#F0EAFF' },
  { key: 'until_loop', label: 'Until 循环', shortLabel: '直到', group: '控制流', accentColor: '#7C4DFF', backgroundColor: '#F0EAFF' }
];

const ACTION_OPTIONS: SegmentOption[] = [
  { label: '截图', value: 'screenshot' },
  { label: '点击', value: 'click' },
  { label: '输入', value: 'input' },
  { label: '坐标滑动', value: 'swipe_with_coords' },
  { label: '方向滑动', value: 'swipe' },
  { label: '按键', value: 'keyevent' },
  { label: '等待', value: 'sleep' },
  { label: '启动 App', value: 'app_start' },
  { label: '停止 App', value: 'app_stop' }
];

const CONDITION_OPTIONS: SegmentOption[] = [
  { label: '等于', value: '==' },
  { label: '不等于', value: '!=' },
  { label: '包含', value: 'contains' },
  { label: '不包含', value: 'not_contains' },
  { label: '大于', value: '>' },
  { label: '大于等于', value: '>=' },
  { label: '小于', value: '<' },
  { label: '小于等于', value: '<=' }
];

const SWIPE_OPTIONS: SegmentOption[] = [
  { label: '上', value: 'up' },
  { label: '下', value: 'down' },
  { label: '左', value: 'left' },
  { label: '右', value: 'right' }
];

const KEY_OPTIONS: SegmentOption[] = [
  { label: '返回', value: 'BACK' },
  { label: '主页', value: 'HOME' },
  { label: '确认', value: 'ENTER' }
];

const ROOT_BRANCH = 'root';
const CHILD_BRANCH_STEPS = 'steps';
const CHILD_BRANCH_THEN = 'then';
const CHILD_BRANCH_ELSE = 'else';
const CARD_CONTEXT_SAVE_DELAY_MS = 350;

// 自定义任务页从 App 沙箱中的 workflow JSON 加载任务配置。
// 新增的图编辑器只改变前端展示和编辑方式，保存结果仍然是一份可执行的 workflow JSON。
@Component
export struct TaskPage {
  @Link taskScene: number;
  onRunWorkflow: (task: WorkflowTask) => Promise<void> = async (task: WorkflowTask) => {};

  @State tasks: WorkflowTask[] = [];
  @State editorOpen: boolean = false;
  @State editorText: string = '';
  @State editorMode: string = 'graph';
  @State editingTaskId: string = '';
  @State editorSceneId: number = 0;
  @State editorWorkflow: WorkflowDefinition = { steps: [] };
  @State selectedPath: string = '';
  @State flowGraphVersion: number = 0;
  @State flowCanvasMounted: boolean = true;
  @State flowRenderSteps: WorkflowStep[] = [];
  @State flowStructureBusy: boolean = false;
  @State editorContextText: string = '{}';
  @State cardContextDrafts: Record<string, string> = {};
  @State cardContextRenderVersion: number = 0;
  @State workflowNameDraft: string = '';
  @State workflowDescriptionDraft: string = '';
  @State toolSchemaText: string = '';
  @State nodeIdDraft: string = '';
  @State nodeNameDraft: string = '';
  @State nodeOnErrorDraft: string = 'stop';
  @State openAppNameDraft: string = '';
  @State guiTaskDraft: string = '';
  @State actionFileNameDraft: string = '';
  @State summaryQuestionDraft: string = '';
  @State summaryBlockingDraft: boolean = false;
  @State loopTimesDraft: string = '';
  @State loopMaxTimesDraft: string = '';
  @State conditionLeftDraft: string = '';
  @State conditionOperatorDraft: string = '==';
  @State conditionRightDraft: string = '';
  @State breakLeftDraft: string = '';
  @State breakOperatorDraft: string = '==';
  @State breakRightDraft: string = '';
  @State runningTaskId: string = '';
  @State configViewOpen: boolean = false;
  @State batchRunning: boolean = false;
  @State batchRunStatusText: string = '';
  @State fileStatsText: string = '正在统计 workflow 文件...';
  @State configManagedFiles: WorkflowManagedFile[] = [];
  @State dailyLogManagedFiles: WorkflowManagedFile[] = [];
  @State runManagedFiles: WorkflowManagedFile[] = [];
  @State fileViewerCategory: string = '';
  @State fileViewerOpen: boolean = false;
  @State fileViewerTitle: string = '';
  @State fileViewerFiles: WorkflowManagedFile[] = [];
  @State fileViewerSelectedName: string = '';
  @State fileViewerText: string = '';
  @State fileViewerPreviewMode: boolean = false;

  private filesDir: string = '';
  private pendingStructureSelectionPath: string = '';
  private pendingTemplateInsertKeys: string[] = [];
  private cardContextSaveTimerIds: Record<string, number> = {};

  aboutToAppear(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    this.filesDir = ctx.filesDir;
    try {
      WorkflowStorage.installDefaultWorkflowResources(this.filesDir, new SystemResourceManagerReader(ctx.resourceManager));
    } catch (e) {
    }
    this.reloadTasks();
  }

  aboutToDisappear(): void {
    if (this.filesDir.length > 0) {
      this.flushTaskContextDrafts();
    }
    this.clearAllTaskContextSaveTimers();
  }

  private reloadTasks(): void {
    if (this.filesDir.length === 0) {
      return;
    }
    this.flushTaskContextDrafts();
    this.cardContextDrafts = {};
    this.tasks = WorkflowStorage.loadTasks(this.filesDir);
    this.refreshCardContextInputs();
    this.refreshStatsText();
  }

  private refreshCardContextInputs(): void {
    this.cardContextRenderVersion = this.cardContextRenderVersion + 1;
  }

  private refreshStatsText(): void {
    this.configManagedFiles = WorkflowStorage.listConfigFiles(this.filesDir);
    this.dailyLogManagedFiles = WorkflowStorage.listDailyLogFiles(this.filesDir);
    this.runManagedFiles = WorkflowStorage.listRunFiles(this.filesDir);
    let stats: WorkflowFileStats = WorkflowStorage.getStats(this.filesDir);
    this.fileStatsText = '配置 ' + stats.configCount + ' 个，daily-log ' + stats.dailyLogCount +
      ' 个，运行文件 ' + stats.runCount + ' 个，共 ' + WorkflowStorage.formatSize(stats.totalBytes);
  }

  private totalFileSize(files: WorkflowManagedFile[]): number {
    let total = 0;
    for (let i = 0; i < files.length; i++) {
      total += files[i].size;
    }
    return total;
  }

  private openFileViewer(category: string): void {
    this.fileViewerCategory = category;
    try {
      router.pushUrl({
        url: 'pages/task/WorkflowFileViewer',
        params: { category: category }
      });
    } catch (e) {
      let err = e as Error;
      showToastSafely('打开文件管理失败：' + err.message, 1800);
    }
  }

  private deleteFileCategory(category: string): void {
    if (category === 'config') {
      this.deleteWorkflowConfigs();
      return;
    }
    if (category === 'daily') {
      this.deleteDailyLogs();
      return;
    }
    if (category === 'run') {
      this.deleteRunFiles();
    }
  }

  private sceneTasks(): WorkflowTask[] {
    return this.tasksForScene(this.taskScene);
  }

  private tasksForScene(sceneId: number): WorkflowTask[] {
    let filtered: WorkflowTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].sceneId === sceneId) {
        filtered.push(this.tasks[i]);
      }
    }
    return filtered;
  }

  private enabledTasks(): WorkflowTask[] {
    let enabled: WorkflowTask[] = [];
    let scenes = workflowSceneConfigs();
    for (let sceneIndex = 0; sceneIndex < scenes.length; sceneIndex++) {
      let sceneTasks = this.tasksForScene(scenes[sceneIndex].sceneId);
      for (let taskIndex = 0; taskIndex < sceneTasks.length; taskIndex++) {
        if (sceneTasks[taskIndex].enabled) {
          enabled.push(sceneTasks[taskIndex]);
        }
      }
    }
    return enabled;
  }

  private enabledTaskCount(): number {
    let count = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].enabled) {
        count++;
      }
    }
    return count;
  }

  private enabledTaskCountForScene(sceneId: number): number {
    let count = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].sceneId === sceneId && this.tasks[i].enabled) {
        count++;
      }
    }
    return count;
  }

  private isTaskExecutionBusy(): boolean {
    return this.batchRunning || this.runningTaskId.length > 0;
  }

  private isWorkflowCancelledStatus(status: string, message: string): boolean {
    let normalizedStatus = status.trim().toLowerCase();
    if (normalizedStatus === 'cancelled' || normalizedStatus === 'canceled') {
      return true;
    }
    let normalizedMessage = message.trim().toLowerCase();
    return normalizedMessage.indexOf('用户取消') >= 0 || normalizedMessage.indexOf('已终止') >= 0 ||
      normalizedMessage.indexOf('task cancelled') >= 0 || normalizedMessage.indexOf('task canceled') >= 0;
  }

  private isTaskCancelled(taskId: string): boolean {
    let task = this.findTask(taskId);
    if (!task) {
      return false;
    }
    return this.isWorkflowCancelledStatus(task.lastStatus, task.lastMessage);
  }

  private taskCardRenderKey(task: WorkflowTask): string {
    let keyParts: string[] = [
      task.id,
      task.title,
      task.source,
      task.enabled ? '1' : '0',
      task.lastStatus,
      task.lastRun,
      task.lastMessage,
      String(this.cardContextRenderVersion)
    ];
    return ArkJSON.stringify(keyParts);
  }

  private taskRowRenderKey(task: WorkflowTask): string {
    return this.taskCardRenderKey(task) + '|' + (this.runningTaskId === task.id ? 'running' : 'idle');
  }

  private taskContextMap(task: WorkflowTask): WorkflowJsonMap | null {
    try {
      let workflow = WorkflowStorage.validateWorkflowJson(task.workflowJson, false);
      if (!workflow.context) {
        return null;
      }
      if (Object.keys(workflow.context).length === 0) {
        return null;
      }
      return workflow.context;
    } catch (e) {
      return null;
    }
  }

  private taskHasContext(task: WorkflowTask): boolean {
    let context = this.taskContextMap(task);
    return context !== null && context['contact_name'] !== undefined;
  }

  private taskContactNameOriginalText(task: WorkflowTask): string {
    let context = this.taskContextMap(task);
    if (!context) {
      return '';
    }
    let value = context['contact_name'];
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    return ArkJSON.stringify(value);
  }

  private taskContactNameDraftForTask(task: WorkflowTask): string {
    let draft = this.cardContextDrafts[task.id];
    if (draft !== undefined) {
      return draft;
    }
    return this.taskContactNameOriginalText(task);
  }

  private setTaskContextDraft(taskId: string, value: string): void {
    let next: Record<string, string> = {};
    let keys = Object.keys(this.cardContextDrafts);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.cardContextDrafts[keys[i]];
    }
    next[taskId] = value;
    this.cardContextDrafts = next;
  }

  private removeTaskContextDraft(taskId: string): void {
    let next: Record<string, string> = {};
    let keys = Object.keys(this.cardContextDrafts);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== taskId) {
        next[keys[i]] = this.cardContextDrafts[keys[i]];
      }
    }
    this.cardContextDrafts = next;
  }

  private taskContextSaveTimerId(taskId: string): number {
    let timerId = this.cardContextSaveTimerIds[taskId];
    if (timerId === undefined) {
      return -1;
    }
    return timerId;
  }

  private setTaskContextSaveTimerId(taskId: string, timerId: number): void {
    let next: Record<string, number> = {};
    let keys = Object.keys(this.cardContextSaveTimerIds);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.cardContextSaveTimerIds[keys[i]];
    }
    next[taskId] = timerId;
    this.cardContextSaveTimerIds = next;
  }

  private removeTaskContextSaveTimerId(taskId: string): void {
    let next: Record<string, number> = {};
    let keys = Object.keys(this.cardContextSaveTimerIds);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== taskId) {
        next[keys[i]] = this.cardContextSaveTimerIds[keys[i]];
      }
    }
    this.cardContextSaveTimerIds = next;
  }

  private clearTaskContextSaveTimer(taskId: string): void {
    let timerId = this.taskContextSaveTimerId(taskId);
    if (timerId !== -1) {
      clearTimeout(timerId);
    }
    this.removeTaskContextSaveTimerId(taskId);
  }

  private clearAllTaskContextSaveTimers(): void {
    let keys = Object.keys(this.cardContextSaveTimerIds);
    for (let i = 0; i < keys.length; i++) {
      let timerId = this.cardContextSaveTimerIds[keys[i]];
      if (timerId !== undefined && timerId !== -1) {
        clearTimeout(timerId);
      }
    }
    this.cardContextSaveTimerIds = {};
  }

  private flushTaskContextDrafts(): boolean {
    let keys = Object.keys(this.cardContextDrafts);
    let flushed = keys.length > 0;
    for (let i = 0; i < keys.length; i++) {
      let taskId = keys[i];
      let value = this.cardContextDrafts[taskId];
      this.clearTaskContextSaveTimer(taskId);
      this.persistTaskContextDraft(taskId, value);
    }
    return flushed;
  }

  private syncTaskContextDraft(task: WorkflowTask, value: string): void {
    this.setTaskContextDraft(task.id, value);
    this.clearTaskContextSaveTimer(task.id);
    if (this.isTaskExecutionBusy()) {
      return;
    }
    let taskId = task.id;
    let timerId = setTimeout(() => {
      this.removeTaskContextSaveTimerId(taskId);
      this.persistTaskContextDraft(taskId, value);
    }, CARD_CONTEXT_SAVE_DELAY_MS);
    this.setTaskContextSaveTimerId(taskId, timerId);
  }

  private persistTaskContextDraft(taskId: string, value: string): void {
    if (this.filesDir.length === 0) {
      return;
    }
    try {
      this.tasks = WorkflowStorage.updateTaskContextValue(this.filesDir, taskId, 'contact_name', value);
      this.refreshStatsText();
    } catch (e) {
      let err = e as Error;
      this.removeTaskContextDraft(taskId);
      try {
        this.tasks = WorkflowStorage.loadTasks(this.filesDir);
      } catch (innerError) {
      }
      this.refreshCardContextInputs();
      showToastSafely('上下文变量保存失败：' + err.message, 2500);
    }
  }

  private openConfigView(): void {
    this.reloadTasks();
    this.configViewOpen = true;
  }

  private closeConfigView(): void {
    this.reloadTasks();
    this.configViewOpen = false;
  }

  private batchRunButtonText(): string {
    if (this.batchRunning) {
      return '执行中';
    }
    let count = this.enabledTaskCount();
    if (count === 0) {
      return '暂无开启任务';
    }
    return '一键执行已开启任务（' + count + '）';
  }

  private openCreateEditor(mode: string = 'graph'): void {
    this.editingTaskId = '';
    this.editorSceneId = this.taskScene;
    if (mode === 'graph') {
      this.openBlankGraphEditor();
      return;
    }
    this.openWorkflowEditor(WorkflowStorage.defaultWorkflowForScene(this.taskScene, this.filesDir), mode, this.taskScene);
  }

  private openEditEditor(taskId: string, mode: string = 'graph'): void {
    let flushedContext = this.flushTaskContextDrafts();
    this.cardContextDrafts = {};
    if (!flushedContext) {
      this.tasks = WorkflowStorage.loadTasks(this.filesDir);
    }
    this.refreshCardContextInputs();
    let task = this.findTask(taskId);
    if (!task) {
      showToastSafely('Workflow 已不存在，请刷新后重试', 1800);
      return;
    }
    this.editingTaskId = task.id;
    this.openWorkflowEditor(WorkflowStorage.readTaskWorkflowJson(this.filesDir, task), mode, task.sceneId);
  }

  private openWorkflowEditor(rawJson: string, mode: string, sceneId: number): void {
    try {
      this.editorText = rawJson;
      this.editorWorkflow = WorkflowStorage.validateWorkflowJson(rawJson, false);
      this.editorContextText = this.contextToText(this.editorWorkflow.context);
      this.loadWorkflowMetaDraft();
      this.editorMode = mode;
      this.editorSceneId = sceneId;
      this.selectedPath = this.editorWorkflow.steps.length > 0 ? this.makePath('', ROOT_BRANCH, 0) : '';
      this.flowGraphVersion = this.flowGraphVersion + 1;
      this.flowCanvasMounted = true;
      this.flowStructureBusy = false;
      this.syncFlowRenderSteps();
      this.syncToolSchemaDraft();
      this.loadNodeDraft(this.selectedPath);
      this.editorOpen = true;
    } catch (e) {
      let err = e as Error;
      showToastSafely('无法打开 Workflow：' + err.message, 2500);
    }
  }

  private openBlankGraphEditor(): void {
    this.editorSceneId = this.taskScene;
    this.editorWorkflow = {
      metadata: {
        name: 'custom-workflow',
        description: '自定义 Workflow'
      },
      defaults: {
        device: 'Harmony',
        use_qwen3: true,
        use_e2e: true,
        use_experience: false,
        accept_planner_changes: false
      },
      context: {},
      steps: []
    };
    this.editorText = ArkJSON.stringify(this.editorWorkflow, null, 2);
    this.editorContextText = '{}';
    this.loadWorkflowMetaDraft();
    this.editorMode = 'graph';
    this.selectedPath = '';
    this.flowGraphVersion = this.flowGraphVersion + 1;
    this.flowCanvasMounted = true;
    this.flowStructureBusy = false;
    this.syncFlowRenderSteps();
    this.toolSchemaText = '';
    this.clearNodeDrafts();
    this.editorOpen = true;
  }

  private saveEditor(): void {
    try {
      if (this.editorMode === 'graph') {
        this.applyWorkflowMetaDraft();
        this.applyNodeDraftToSelection(true);
        this.applyContextDraft();
        this.syncEditorTextFromWorkflow();
      }
      let task = WorkflowStorage.createTaskFromJson(this.filesDir, this.editorSceneId, this.editorText, this.editingTaskId);
      if (this.editingTaskId.length > 0) {
        let existing = this.findTask(this.editingTaskId);
        if (existing) {
          task.enabled = existing.enabled;
          task.lastStatus = existing.lastStatus;
          task.lastRun = existing.lastRun;
          task.lastMessage = existing.lastMessage;
          task.configFileName = existing.configFileName;
        }
      }
      this.tasks = WorkflowStorage.upsertTask(this.filesDir, task);
      if (this.editingTaskId.length > 0) {
        this.clearTaskContextSaveTimer(this.editingTaskId);
        this.removeTaskContextDraft(this.editingTaskId);
        this.refreshCardContextInputs();
      }
      this.editorOpen = false;
      this.selectedPath = '';
      this.taskScene = this.editorSceneId;
      showToastSafely('Workflow 已保存', 1500);
      this.refreshStatsText();
    } catch (e) {
      let err = e as Error;
      showToastSafely('保存失败：' + err.message, 2500);
    }
  }

  private switchEditorMode(mode: string): void {
    if (this.editorMode === mode) {
      return;
    }
    try {
      if (mode === 'graph') {
        this.editorWorkflow = WorkflowStorage.validateWorkflowJson(this.editorText, false);
        this.editorContextText = this.contextToText(this.editorWorkflow.context);
        this.loadWorkflowMetaDraft();
        if (this.selectedPath.length > 0 && !this.stepByPath(this.selectedPath)) {
          this.selectedPath = '';
          this.clearNodeDrafts();
        }
        if (this.selectedPath.length === 0 && this.editorWorkflow.steps.length > 0) {
          this.selectedPath = this.makePath('', ROOT_BRANCH, 0);
        }
        this.flowGraphVersion = this.flowGraphVersion + 1;
        this.flowCanvasMounted = true;
        this.flowStructureBusy = false;
        this.syncFlowRenderSteps();
        this.syncToolSchemaDraft();
        this.loadNodeDraft(this.selectedPath);
      } else {
        this.applyWorkflowMetaDraft();
        this.applyNodeDraftToSelection(true);
        this.applyContextDraft();
        this.syncEditorTextFromWorkflow();
      }
      this.editorMode = mode;
    } catch (e) {
      let err = e as Error;
      showToastSafely('切换失败：' + err.message, 2500);
    }
  }

  private findTask(taskId: string): WorkflowTask | null {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === taskId) {
        return this.tasks[i];
      }
    }
    return null;
  }

  private setTaskEnabled(task: WorkflowTask, enabled: boolean): void {
    if (this.isTaskExecutionBusy()) {
      showToastSafely('Workflow 正在执行，请稍后再调整任务开关', 1500);
      return;
    }
    this.tasks = WorkflowStorage.updateTaskEnabled(this.filesDir, task.id, enabled);
  }

  private async runTask(task: WorkflowTask): Promise<void> {
    if (this.isTaskExecutionBusy()) {
      showToastSafely('已有 workflow 正在执行', 1500);
      return;
    }
    let flushedContext = this.flushTaskContextDrafts();
    this.cardContextDrafts = {};
    if (!flushedContext) {
      this.tasks = WorkflowStorage.loadTasks(this.filesDir);
    } else {
      this.refreshCardContextInputs();
    }
    let currentTask = this.findTask(task.id);
    if (!currentTask) {
      showToastSafely('Workflow 已不存在，请刷新后重试', 1800);
      return;
    }
    if (!currentTask.enabled) {
      showToastSafely('任务已停用，请先打开开关', 1500);
      return;
    }
    this.runningTaskId = currentTask.id;
    this.tasks = WorkflowStorage.updateTaskRun(this.filesDir, currentTask.id, '运行中', 'Workflow 正在执行');
    try {
      await this.onRunWorkflow(currentTask);
    } finally {
      this.runningTaskId = '';
      this.tasks = WorkflowStorage.loadTasks(this.filesDir);
      this.refreshStatsText();
    }
  }

  private async runEnabledTasks(): Promise<void> {
    if (this.isTaskExecutionBusy()) {
      showToastSafely('已有 workflow 正在执行', 1500);
      return;
    }
    let flushedContext = this.flushTaskContextDrafts();
    this.cardContextDrafts = {};
    if (!flushedContext) {
      this.tasks = WorkflowStorage.loadTasks(this.filesDir);
    } else {
      this.refreshCardContextInputs();
    }
    let queue = this.enabledTasks();
    if (queue.length === 0) {
      showToastSafely('请先开启至少一个任务', 1500);
      return;
    }
    this.batchRunning = true;
    this.batchRunStatusText = '准备执行 ' + queue.length + ' 个任务';
    let stoppedByError = false;
    let stoppedByCancel = false;
    try {
      for (let i = 0; i < queue.length; i++) {
        let currentTask = this.findTask(queue[i].id);
        if (!currentTask || !currentTask.enabled) {
          continue;
        }
        this.runningTaskId = currentTask.id;
        this.batchRunStatusText = '正在执行 ' + (i + 1) + '/' + queue.length + '：' + currentTask.title;
        this.tasks = WorkflowStorage.updateTaskRun(this.filesDir, currentTask.id, '运行中', 'Workflow 正在执行');
        try {
          await this.onRunWorkflow(currentTask);
          this.tasks = WorkflowStorage.loadTasks(this.filesDir);
          if (this.isTaskCancelled(currentTask.id)) {
            stoppedByCancel = true;
            showToastSafely('批量执行已终止', 1500);
            break;
          }
        } catch (e) {
          let err = e as Error;
          stoppedByError = true;
          this.tasks = WorkflowStorage.updateTaskRun(this.filesDir, currentTask.id, 'failed', err.message);
          showToastSafely('任务执行中断：' + err.message, 2500);
          break;
        } finally {
          this.runningTaskId = '';
        }
      }
      if (!stoppedByError && !stoppedByCancel) {
        showToastSafely('已完成开启任务的依次执行', 1500);
      }
    } finally {
      this.batchRunning = false;
      this.runningTaskId = '';
      this.batchRunStatusText = '';
      this.tasks = WorkflowStorage.loadTasks(this.filesDir);
      this.refreshStatsText();
    }
  }

  private copyWorkflowTask(task: WorkflowTask): void {
    try {
      let copied = WorkflowStorage.duplicateTask(this.filesDir, task.id);
      this.reloadTasks();
      showToastSafely('已复制：' + copied.title, 1500);
    } catch (e) {
      let err = e as Error;
      showToastSafely('复制失败：' + err.message, 2500);
    }
  }

  private deleteWorkflowTask(task: WorkflowTask): void {
    if (this.runningTaskId === task.id) {
      showToastSafely('Workflow 正在执行，无法删除', 1500);
      return;
    }
    promptAction.showDialog({
      title: '删除 Workflow',
      message: '将删除“' + task.title + '”及其配置文件。此操作不可恢复。',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '删除', color: '#FF4D4F' }
      ]
    }).then((data: promptAction.ShowDialogSuccessResponse) => {
      if (data.index === 1) {
        this.tasks = WorkflowStorage.deleteTask(this.filesDir, task.id);
        if (this.editingTaskId === task.id) {
          this.editorOpen = false;
          this.editingTaskId = '';
          this.selectedPath = '';
        }
        this.refreshStatsText();
        showToastSafely('Workflow 已删除', 1500);
      }
    }).catch(() => {});
  }

  private deleteWorkflowConfigs(): void {
    promptAction.showDialog({
      title: '删除 workflow 配置',
      message: '将删除所有沙箱 workflow 配置，并重新生成默认示例任务。',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '删除', color: '#FF4D4F' }
      ]
    }).then((data: promptAction.ShowDialogSuccessResponse) => {
      if (data.index === 1) {
        let count = WorkflowStorage.deleteConfigs(this.filesDir);
        this.reloadTasks();
        showToastSafely('已删除配置项：' + count, 1500);
      }
    }).catch(() => {});
  }

  private deleteDailyLogs(): void {
    promptAction.showDialog({
      title: '删除 daily-log',
      message: '将删除 workflow 生成的所有 daily-log Markdown 文件。',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '删除', color: '#FF4D4F' }
      ]
    }).then((data: promptAction.ShowDialogSuccessResponse) => {
      if (data.index === 1) {
        let count = WorkflowStorage.deleteDailyLogs(this.filesDir);
        this.refreshStatsText();
        showToastSafely('已删除 daily-log 项：' + count, 1500);
      }
    }).catch(() => {});
  }

  private deleteRunFiles(): void {
    promptAction.showDialog({
      title: '删除运行文件',
      message: '将删除 workflow 生成的所有运行摘要和步骤输出文件。',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '删除', color: '#FF4D4F' }
      ]
    }).then((data: promptAction.ShowDialogSuccessResponse) => {
      if (data.index === 1) {
        let count = WorkflowStorage.deleteRunFiles(this.filesDir);
        this.refreshStatsText();
        showToastSafely('已删除运行文件项：' + count, 1500);
      }
    }).catch(() => {});
  }

  private openConfigFileViewer(): void {
    this.fileViewerCategory = 'config';
    this.fileViewerTitle = 'Workflow 配置文件';
    this.fileViewerFiles = WorkflowStorage.listConfigFiles(this.filesDir);
    this.fileViewerOpen = true;
    if (this.fileViewerFiles.length > 0) {
      this.openManagedFile(this.fileViewerFiles[0]);
    } else {
      this.fileViewerSelectedName = '';
      this.fileViewerText = '暂无 workflow 配置文件';
      this.fileViewerPreviewMode = false;
    }
  }

  private openDailyLogFileViewer(): void {
    this.fileViewerCategory = 'daily';
    this.fileViewerTitle = 'daily-log 文件';
    this.fileViewerFiles = WorkflowStorage.listDailyLogFiles(this.filesDir);
    this.fileViewerOpen = true;
    if (this.fileViewerFiles.length > 0) {
      this.openManagedFile(this.fileViewerFiles[0]);
    } else {
      this.fileViewerSelectedName = '';
      this.fileViewerText = '暂无 daily-log 文件';
      this.fileViewerPreviewMode = false;
    }
  }

  private openRunFileViewer(): void {
    this.fileViewerCategory = 'run';
    this.fileViewerTitle = '运行文件';
    this.fileViewerFiles = WorkflowStorage.listRunFiles(this.filesDir);
    this.fileViewerOpen = true;
    if (this.fileViewerFiles.length > 0) {
      this.openManagedFile(this.fileViewerFiles[0]);
    } else {
      this.fileViewerSelectedName = '';
      this.fileViewerText = '暂无运行文件';
      this.fileViewerPreviewMode = false;
    }
  }

  private openManagedFile(file: WorkflowManagedFile): void {
    this.fileViewerSelectedName = file.name;
    this.fileViewerPreviewMode = this.defaultFileViewerPreviewMode(file);
    try {
      this.fileViewerText = WorkflowStorage.readText(file.path);
    } catch (e) {
      let err = e as Error;
      this.fileViewerText = '读取失败：' + (err.message || String(e));
    }
  }

  private defaultFileViewerPreviewMode(file: WorkflowManagedFile): boolean {
    // 内联文件面板沿用独立查看页的默认规则，保证后续入口恢复时预览/原文行为一致。
    let lowerName = file.name.toLowerCase();
    if (this.fileViewerCategory === 'daily') {
      return true;
    }
    return lowerName.endsWith('.md') || lowerName.endsWith('.markdown');
  }

  private fileViewerContainsAiGeneratedContent(): boolean {
    return this.fileViewerCategory === 'daily' || this.fileViewerCategory === 'run';
  }

  private contextToText(context: WorkflowJsonMap | undefined): string {
    if (!context) {
      return '{}';
    }
    return ArkJSON.stringify(context, null, 2);
  }

  private applyContextDraft(): void {
    let text = this.editorContextText.trim();
    if (text.length === 0) {
      this.editorWorkflow.context = {};
      return;
    }
    this.editorWorkflow.context = ArkJSON.parse(text) as WorkflowJsonMap;
  }

  private syncEditorTextFromWorkflow(): void {
    this.editorText = ArkJSON.stringify(this.editorWorkflow, null, 2);
  }

  private cloneWorkflow(workflow: WorkflowDefinition): WorkflowDefinition {
    return ArkJSON.parse(ArkJSON.stringify(workflow)) as WorkflowDefinition;
  }

  private cloneStepList(steps: WorkflowStep[]): WorkflowStep[] {
    return ArkJSON.parse(ArkJSON.stringify(steps)) as WorkflowStep[];
  }

  private syncFlowRenderSteps(): void {
    this.flowRenderSteps = this.cloneStepList(this.editorWorkflow.steps);
  }

  private stepListRenderKey(steps: WorkflowStep[]): string {
    return ArkJSON.stringify(steps);
  }

  private flowDisplaySteps(): WorkflowStep[] {
    if (this.stepListRenderKey(this.flowRenderSteps) === this.stepListRenderKey(this.editorWorkflow.steps)) {
      return this.flowRenderSteps;
    }
    return this.editorWorkflow.steps;
  }

  private maxStepDepth(steps: WorkflowStep[], depth: number): number {
    let maxDepth = depth;
    for (let i = 0; i < steps.length; i++) {
      let step = steps[i];
      if (step.steps && step.steps.length > 0) {
        maxDepth = Math.max(maxDepth, this.maxStepDepth(step.steps, depth + 1));
      }
      if (step.then_steps && step.then_steps.length > 0) {
        maxDepth = Math.max(maxDepth, this.maxStepDepth(step.then_steps, depth + 1));
      }
      if (step.else_steps && step.else_steps.length > 0) {
        maxDepth = Math.max(maxDepth, this.maxStepDepth(step.else_steps, depth + 1));
      }
    }
    return maxDepth;
  }

  private flowMaxDepth(): number {
    return this.maxStepDepth(this.flowDisplaySteps(), 0);
  }

  private flowNeedsHorizontalScroll(): boolean {
    return this.flowMaxDepth() >= 1;
  }

  private flowCanvasMinWidth(): number {
    return 306 + this.flowMaxDepth() * 120;
  }

  private markWorkflowChanged(): void {
    this.editorWorkflow = this.cloneWorkflow(this.editorWorkflow);
    this.syncEditorTextFromWorkflow();
    this.syncFlowRenderSteps();
  }

  private markWorkflowStructureChanged(): void {
    this.flowGraphVersion = this.flowGraphVersion + 1;
    this.editorWorkflow = this.cloneWorkflow(this.editorWorkflow);
    this.syncEditorTextFromWorkflow();
    this.syncFlowRenderSteps();
    this.restorePendingStructureSelection();
    this.flowCanvasMounted = true;
    this.flowStructureBusy = false;
    this.flushPendingTemplateInsert();
  }

  private prepareStructureSelectionRestore(path: string): void {
    this.pendingStructureSelectionPath = path;
    this.selectedPath = '';
    this.clearNodeDrafts();
  }

  private restorePendingStructureSelection(): void {
    let path = this.pendingStructureSelectionPath;
    this.pendingStructureSelectionPath = '';
    if (path.length > 0 && this.stepByPath(path)) {
      this.selectedPath = path;
      this.loadNodeDraft(path);
      return;
    }
    if (this.selectedPath.length > 0 && !this.stepByPath(this.selectedPath)) {
      this.selectedPath = '';
      this.clearNodeDrafts();
    }
  }

  private queueTemplateInsert(templateKey: string): void {
    this.pendingTemplateInsertKeys.push(templateKey);
  }

  private takePendingTemplateInsertKey(): string {
    if (this.pendingTemplateInsertKeys.length === 0) {
      return '';
    }
    let key = this.pendingTemplateInsertKeys[0];
    this.pendingTemplateInsertKeys.splice(0, 1);
    return key;
  }

  private flushPendingTemplateInsert(): void {
    let templateKey = this.takePendingTemplateInsertKey();
    if (templateKey.length > 0) {
      this.insertTemplateAfterSelection(templateKey);
    }
  }

  private clearNodeDrafts(): void {
    this.nodeIdDraft = '';
    this.nodeNameDraft = '';
    this.nodeOnErrorDraft = 'stop';
    this.openAppNameDraft = '';
    this.guiTaskDraft = '';
    this.actionFileNameDraft = '';
    this.summaryQuestionDraft = '';
    this.summaryBlockingDraft = false;
    this.loopTimesDraft = '';
    this.loopMaxTimesDraft = '';
    this.conditionLeftDraft = '';
    this.conditionOperatorDraft = '==';
    this.conditionRightDraft = '';
    this.breakLeftDraft = '';
    this.breakOperatorDraft = '==';
    this.breakRightDraft = '';
    this.toolSchemaText = '';
  }

  private loadNodeDraft(path: string): void {
    let step = this.stepByPath(path);
    if (!step) {
      this.clearNodeDrafts();
      return;
    }
    this.nodeIdDraft = String(step.id);
    this.nodeNameDraft = step.name || '';
    this.nodeOnErrorDraft = step.on_error || 'stop';
    this.openAppNameDraft = this.openAppNameFromDescription(step.task_description || '');
    this.guiTaskDraft = step.task_description || '';
    this.actionFileNameDraft = step.file_name || '';
    this.summaryQuestionDraft = '';
    this.summaryBlockingDraft = false;
    this.loopTimesDraft = this.valueText(step.times as WorkflowJsonValue);
    this.loopMaxTimesDraft = this.valueText(step.max_times as WorkflowJsonValue);

    let condition = this.conditionObjectByPath(path, 'if');
    this.conditionLeftDraft = this.valueText(condition.left);
    this.conditionOperatorDraft = condition.operator || '==';
    this.conditionRightDraft = this.valueText(condition.right);
    let breakCondition = this.conditionObjectByPath(path, 'break');
    this.breakLeftDraft = this.valueText(breakCondition.left);
    this.breakOperatorDraft = breakCondition.operator || '==';
    this.breakRightDraft = this.valueText(breakCondition.right);

    let summary = this.toolTargetStepByPath(path);
    if (summary && summary.inputs) {
      this.summaryQuestionDraft = summary.inputs.question || '';
      this.summaryBlockingDraft = summary.inputs.blocking === true;
      if (summary.inputs.json_schema) {
        this.toolSchemaText = ArkJSON.stringify(summary.inputs.json_schema, null, 2);
      } else {
        this.toolSchemaText = '';
      }
    } else {
      this.toolSchemaText = '';
    }
    let pairSummary = this.pairSummaryStepByPath(path);
    if (pairSummary && pairSummary.inputs) {
      this.summaryQuestionDraft = pairSummary.inputs.question || '';
      this.summaryBlockingDraft = pairSummary.inputs.blocking === true;
    }
  }

  private applyNodeDraftToSelection(throwOnError: boolean): void {
    if (this.applyNodeDraftToPath(this.selectedPath, throwOnError)) {
      this.markWorkflowChanged();
    }
  }

  private applyNodeDraftToPath(path: string, throwOnError: boolean): boolean {
    let step = this.stepByPath(path);
    if (!step) {
      return false;
    }
    step.name = this.nodeNameDraft;
    step.on_error = this.nodeOnErrorDraft.length > 0 ? this.nodeOnErrorDraft : 'stop';

    if (this.isShotSummaryPairPath(path)) {
      step.file_name = this.actionFileNameDraft;
      let summary = this.pairSummaryStepByPath(path);
      if (summary) {
        summary.tool_name = 'vlm_qa';
        let inputs = this.ensureToolInputs(summary);
        inputs.mode = 'summary';
        inputs.image = this.shotImageVariable(step);
        inputs.question = this.summaryQuestionDraft;
        inputs.blocking = this.summaryBlockingDraft;
        this.applyToolSchemaDraftToPath(path, throwOnError);
      }
      return true;
    }

    if (step.type === 'gui_task') {
      if (this.isOpenAppStep(step, path)) {
        let appName = this.openAppNameDraft.trim();
        step.task_description = appName.length > 0 ? '打开' + appName : '打开目标应用';
      } else {
        step.task_description = this.guiTaskDraft;
      }
    } else if (step.type === 'gui_action') {
      if (step.action === 'screenshot') {
        step.file_name = this.actionFileNameDraft;
      }
    } else if (step.type === 'tool') {
      step.tool_name = 'vlm_qa';
      let inputs = this.ensureToolInputs(step);
      inputs.mode = inputs.mode || 'summary';
      inputs.question = this.summaryQuestionDraft;
      inputs.blocking = this.summaryBlockingDraft;
      this.applyToolSchemaDraftToPath(path, throwOnError);
    } else if (step.type === 'loop') {
      if (this.loopUsesBreakCondition(step)) {
        step.times = undefined;
        this.assignNumberOrTextToStep(step, 'max_times', this.loopMaxTimesDraft);
        this.writeConditionAtPath(path, 'break', this.breakLeftDraft, this.breakOperatorDraft, this.breakRightDraft);
      } else {
        this.assignNumberOrTextToStep(step, 'times', this.loopTimesDraft);
        step.max_times = undefined;
        step.break_if = undefined;
      }
    } else if (step.type === 'if') {
      this.writeConditionAtPath(path, 'if', this.conditionLeftDraft, this.conditionOperatorDraft, this.conditionRightDraft);
    }
    return true;
  }

  private assignNumberOrTextToStep(step: WorkflowStep, field: string, text: string): void {
    let value = text.trim();
    if (value.length === 0) {
      if (field === 'times') {
        step.times = undefined;
      } else if (field === 'max_times') {
        step.max_times = undefined;
      }
      return;
    }
    let parsed = Number(value);
    if (field === 'times') {
      step.times = isNaN(parsed) ? value : parsed;
    } else if (field === 'max_times') {
      step.max_times = isNaN(parsed) ? value : parsed;
    }
  }

  private writeCondition(kind: string, leftText: string, operator: string, rightText: string): void {
    this.writeConditionAtPath(this.selectedPath, kind, leftText, operator, rightText);
  }

  private writeConditionAtPath(path: string, kind: string, leftText: string, operator: string, rightText: string): void {
    let condition = this.ensureConditionByPath(path, kind);
    condition.left = this.parseJsonValueText(leftText);
    condition.operator = operator.length > 0 ? operator : '==';
    condition.right = this.parseJsonValueText(rightText);
  }

  private makePath(parentPath: string, branch: string, index: number): string {
    let part = branch + ':' + index;
    return parentPath.length > 0 ? parentPath + '/' + part : part;
  }

  private parsePath(path: string): StepPathPart[] {
    let parts: StepPathPart[] = [];
    if (path.length === 0) {
      return parts;
    }
    let rawParts = path.split('/');
    for (let i = 0; i < rawParts.length; i++) {
      let pos = rawParts[i].lastIndexOf(':');
      if (pos > 0) {
        let index = Number(rawParts[i].substring(pos + 1));
        if (!isNaN(index)) {
          parts.push({
            branch: rawParts[i].substring(0, pos),
            index: index
          });
        }
      }
    }
    return parts;
  }

  private branchSteps(parentStep: WorkflowStep, branch: string): WorkflowStep[] {
    if (branch === CHILD_BRANCH_THEN) {
      if (!parentStep.then_steps) {
        parentStep.then_steps = [];
      }
      return parentStep.then_steps;
    }
    if (branch === CHILD_BRANCH_ELSE) {
      if (!parentStep.else_steps) {
        parentStep.else_steps = [];
      }
      return parentStep.else_steps;
    }
    if (!parentStep.steps) {
      parentStep.steps = [];
    }
    return parentStep.steps;
  }

  private stepByPath(path: string): WorkflowStep | null {
    let parts = this.parsePath(path);
    if (parts.length === 0) {
      return null;
    }
    let currentSteps = this.editorWorkflow.steps;
    let currentStep: WorkflowStep | null = null;
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].branch === ROOT_BRANCH) {
        currentSteps = this.editorWorkflow.steps;
      } else {
        if (!currentStep) {
          return null;
        }
        currentSteps = this.branchSteps(currentStep, parts[i].branch);
      }
      if (parts[i].index < 0 || parts[i].index >= currentSteps.length) {
        return null;
      }
      currentStep = currentSteps[parts[i].index];
    }
    return currentStep;
  }

  private containerByPath(path: string): WorkflowStep[] | null {
    let parts = this.parsePath(path);
    if (parts.length === 0) {
      return this.editorWorkflow.steps;
    }
    let currentSteps = this.editorWorkflow.steps;
    let currentStep: WorkflowStep | null = null;
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].branch === ROOT_BRANCH) {
        currentSteps = this.editorWorkflow.steps;
      } else {
        if (!currentStep) {
          return null;
        }
        currentSteps = this.branchSteps(currentStep, parts[i].branch);
      }
      if (i === parts.length - 1) {
        return currentSteps;
      }
      if (parts[i].index < 0 || parts[i].index >= currentSteps.length) {
        return null;
      }
      currentStep = currentSteps[parts[i].index];
    }
    return currentSteps;
  }

  private selectedIndex(): number {
    let parts = this.parsePath(this.selectedPath);
    if (parts.length === 0) {
      return -1;
    }
    return parts[parts.length - 1].index;
  }

  private replaceLastPathIndex(path: string, index: number): string {
    let parts = this.parsePath(path);
    if (parts.length === 0) {
      return '';
    }
    parts[parts.length - 1].index = index;
    let next = '';
    for (let i = 0; i < parts.length; i++) {
      next = this.makePath(next, parts[i].branch, parts[i].index);
    }
    return next;
  }

  private pathParent(path: string): string {
    let pos = path.lastIndexOf('/');
    if (pos < 0) {
      return '';
    }
    return path.substring(0, pos);
  }

  private persistSelectedDraftInPlace(): boolean {
    if (this.selectedPath.length === 0) {
      return false;
    }
    return this.applyNodeDraftToPath(this.selectedPath, false);
  }

  private selectStep(path: string): void {
    if (this.selectedPath === path) {
      return;
    }
    if (this.persistSelectedDraftInPlace()) {
      this.markWorkflowChanged();
    }
    this.selectedPath = path;
    this.loadNodeDraft(path);
  }

  private focusStepForStructureAction(path: string): void {
    if (this.selectedPath === path) {
      return;
    }
    this.persistSelectedDraftInPlace();
    this.selectedPath = path;
    this.loadNodeDraft(path);
  }

  private currentInsertContainer(): WorkflowStep[] {
    if (this.selectedPath.length === 0) {
      return this.editorWorkflow.steps;
    }
    let container = this.containerByPath(this.selectedPath);
    return container ? container : this.editorWorkflow.steps;
  }

  private currentInsertIndex(container: WorkflowStep[]): number {
    if (this.selectedPath.length === 0) {
      return container.length;
    }
    let index = this.selectedIndex();
    if (index < 0 || index >= container.length) {
      return container.length;
    }
    let groupIndex = this.groupStartIndex(container, index);
    if (this.isShotSummaryPairAt(container, groupIndex)) {
      return groupIndex + 2;
    }
    return groupIndex + 1;
  }

  private nextStepId(container: WorkflowStep[]): number {
    let maxId = 0;
    for (let i = 0; i < container.length; i++) {
      let value = Number(container[i].id);
      if (!isNaN(value) && value > maxId) {
        maxId = value;
      }
    }
    return maxId + 1;
  }

  private defaultImageVariable(container: WorkflowStep[], insertIndex: number): string {
    for (let i = insertIndex - 1; i >= 0; i--) {
      let step = container[i];
      if (step.type === 'gui_action' && step.action === 'screenshot') {
        return '${steps.' + String(step.id) + '.output.image_b64}';
      }
    }
    return '${steps.1.output.image_b64}';
  }

  private shotImageVariable(step: WorkflowStep): string {
    return '${steps.' + String(step.id) + '.output.image_b64}';
  }

  private legacyShotImageVariable(step: WorkflowStep): string {
    return '${steps.' + String(step.id) + '.output.image_path}';
  }

  private isScreenshotStep(step: WorkflowStep): boolean {
    return step.type === 'gui_action' && step.action === 'screenshot';
  }

  private isSummaryStepForImage(step: WorkflowStep, imageVariable: string): boolean {
    if (step.type !== 'tool' || step.tool_name !== 'vlm_qa' || !step.inputs) {
      return false;
    }
    return step.inputs.mode === 'summary' && step.inputs.image === imageVariable;
  }

  private isShotSummaryPairAt(steps: WorkflowStep[], index: number): boolean {
    if (index < 0 || index + 1 >= steps.length) {
      return false;
    }
    let shot = steps[index];
    let summary = steps[index + 1];
    return this.isScreenshotStep(shot) &&
      (this.isSummaryStepForImage(summary, this.shotImageVariable(shot)) ||
        this.isSummaryStepForImage(summary, this.legacyShotImageVariable(shot)));
  }

  private isSummaryPartOfPair(steps: WorkflowStep[], index: number): boolean {
    if (index <= 0) {
      return false;
    }
    return this.isShotSummaryPairAt(steps, index - 1);
  }

  private groupStartIndex(container: WorkflowStep[], index: number): number {
    if (this.isSummaryPartOfPair(container, index)) {
      return index - 1;
    }
    return index;
  }

  private groupStartPath(path: string, container: WorkflowStep[] | null): string {
    if (!container) {
      return path;
    }
    let index = this.pathIndex(path);
    if (index < 0 || index >= container.length) {
      return path;
    }
    let groupIndex = this.groupStartIndex(container, index);
    return groupIndex === index ? path : this.replaceLastPathIndex(path, groupIndex);
  }

  private workflowGroupStartPath(path: string): string {
    return this.groupStartPath(path, this.containerByPath(path));
  }

  private isWorkflowStepPathValid(path: string): boolean {
    let container = this.containerByPath(path);
    let index = this.pathIndex(path);
    return container !== null && index >= 0 && index < container.length;
  }

  private resolvedDeletePath(path: string): string {
    let groupPath = this.workflowGroupStartPath(path);
    if (this.isWorkflowStepPathValid(groupPath)) {
      return groupPath;
    }
    return '';
  }

  private selectedPairSummaryStep(): WorkflowStep | null {
    return this.pairSummaryStepByPath(this.selectedPath);
  }

  private pairSummaryStepByPath(path: string): WorkflowStep | null {
    let container = this.containerByPath(path);
    let index = this.pathIndex(path);
    if (!container || !this.isShotSummaryPairAt(container, index)) {
      return null;
    }
    return container[index + 1];
  }

  private isSelectedShotSummaryPair(): boolean {
    return this.isShotSummaryPairPath(this.selectedPath);
  }

  private isShotSummaryPairPath(path: string): boolean {
    return this.pairSummaryStepByPath(path) !== null;
  }

  private stepGroupLength(container: WorkflowStep[], index: number): number {
    let groupIndex = this.groupStartIndex(container, index);
    return this.isShotSummaryPairAt(container, groupIndex) ? 2 : 1;
  }

  private visibleFlowItems(steps: WorkflowStep[], parentPath: string, branch: string): FlowRenderItem[] {
    let items: FlowRenderItem[] = [];
    for (let i = 0; i < steps.length; i++) {
      if (this.isSummaryPartOfPair(steps, i)) {
        continue;
      }
      let step = steps[i];
      let path = this.makePath(parentPath, branch, i);
      if (this.isShotSummaryPairAt(steps, i)) {
        items.push({
          key: this.flowItemKey(steps, parentPath, branch, step, i),
          path: path,
          step: step,
          summary: steps[i + 1],
          isPair: true
        });
      } else {
        items.push({
          key: this.flowItemKey(steps, parentPath, branch, step, i),
          path: path,
          step: step,
          isPair: false
        });
      }
    }
    return items;
  }

  private flowItemKey(steps: WorkflowStep[], parentPath: string, branch: string, step: WorkflowStep, index: number): string {
    let branchKey = String(this.flowGraphVersion) + ':' + this.makePath(parentPath, branch, index);
    if (this.isShotSummaryPairAt(steps, index)) {
      return branchKey + ':pair:' + String(step.id) + ':' + String(steps[index + 1].id);
    }
    if (this.isSummaryPartOfPair(steps, index)) {
      return branchKey + ':pair-summary:' + String(step.id);
    }
    return branchKey + ':step:' + String(step.id) + ':' + step.type;
  }

  private rootIndexFromPath(path: string): number {
    let parts = this.parsePath(path);
    if (parts.length !== 1 || parts[0].branch !== ROOT_BRANCH) {
      return -1;
    }
    return parts[0].index;
  }

  private isLockedRootFirstPath(path: string): boolean {
    return this.rootIndexFromPath(path) === 0;
  }

  private canDeleteStepAtPath(path: string): boolean {
    let groupPath = this.workflowGroupStartPath(path);
    return this.isWorkflowStepPathValid(groupPath) && !this.isLockedRootFirstPath(groupPath);
  }

  private canMoveStepAtPath(path: string, offset: number): boolean {
    let container = this.renderContainerByPath(path);
    if (!container) {
      container = this.containerByPath(path);
    }
    return this.canMoveStepInContainer(container, path, offset);
  }

  private canMoveWorkflowStepAtPath(path: string, offset: number): boolean {
    let container = this.containerByPath(path);
    return this.canMoveStepInContainer(container, path, offset);
  }

  private canMoveStepInContainer(container: WorkflowStep[] | null, path: string, offset: number): boolean {
    let index = this.pathIndex(path);
    if (!container || index < 0 || index >= container.length || offset === 0) {
      return false;
    }
    index = this.groupStartIndex(container, index);
    let groupPath = this.replaceLastPathIndex(path, index);
    let rootIndex = this.rootIndexFromPath(groupPath);
    if (rootIndex === 0) {
      return false;
    }
    if (rootIndex === 1 && offset < 0) {
      return false;
    }
    let groupLength = this.stepGroupLength(container, index);
    if (offset < 0) {
      return index > 0;
    }
    return index + groupLength < container.length;
  }

  private renderContainerByPath(path: string): WorkflowStep[] | null {
    return this.containerByRootSteps(this.flowRenderSteps, path);
  }

  private containerByRootSteps(rootSteps: WorkflowStep[], path: string): WorkflowStep[] | null {
    let parts = this.parsePath(path);
    if (parts.length === 0) {
      return rootSteps;
    }
    let currentSteps = rootSteps;
    let currentStep: WorkflowStep | null = null;
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].branch === ROOT_BRANCH) {
        currentSteps = rootSteps;
      } else {
        if (!currentStep) {
          return null;
        }
        currentSteps = this.readBranchSteps(currentStep, parts[i].branch);
      }
      if (i === parts.length - 1) {
        return currentSteps;
      }
      if (parts[i].index < 0 || parts[i].index >= currentSteps.length) {
        return null;
      }
      currentStep = currentSteps[parts[i].index];
    }
    return currentSteps;
  }

  private readBranchSteps(parentStep: WorkflowStep, branch: string): WorkflowStep[] {
    if (branch === CHILD_BRANCH_THEN) {
      return parentStep.then_steps ? parentStep.then_steps : [];
    }
    if (branch === CHILD_BRANCH_ELSE) {
      return parentStep.else_steps ? parentStep.else_steps : [];
    }
    return parentStep.steps ? parentStep.steps : [];
  }

  private moveButtonBackground(path: string, offset: number): string {
    return this.canMoveStepAtPath(path, offset) ? '#F6F8FC' : '#F0F2F5';
  }

  private moveButtonColor(path: string, offset: number): string {
    return this.canMoveStepAtPath(path, offset) ? '#4E5666' : '#B7BFCC';
  }

  private deleteButtonBackground(path: string): string {
    return this.canDeleteStepAtPath(path) ? '#FFF0ED' : '#F0F2F5';
  }

  private deleteButtonColor(path: string): string {
    return this.canDeleteStepAtPath(path) ? '#B42318' : '#B7BFCC';
  }

  private insertTemplateAfterSelection(templateKey: string): void {
    if (this.flowStructureBusy) {
      this.queueTemplateInsert(templateKey);
      return;
    }
    this.persistSelectedDraftInPlace();
    let hasSelectedNode = this.selectedPath.length > 0 && this.stepByPath(this.selectedPath) !== null;
    if (!hasSelectedNode) {
      this.selectedPath = '';
    }
    let container = hasSelectedNode ? this.currentInsertContainer() : this.editorWorkflow.steps;
    let insertIndex = hasSelectedNode ? this.currentInsertIndex(container) : container.length;
    let newPath = hasSelectedNode ?
      this.replaceLastPathIndex(this.selectedPath, insertIndex) : this.makePath('', ROOT_BRANCH, insertIndex);
    this.insertTemplateIntoContainer(container, insertIndex, templateKey, newPath);
  }

  private insertTemplateIntoBranch(parentPath: string, branch: string, templateKey: string): void {
    if (this.flowStructureBusy) {
      this.queueTemplateInsert(templateKey);
      return;
    }
    this.persistSelectedDraftInPlace();
    let parent = this.stepByPath(parentPath);
    if (!parent) {
      return;
    }
    let container = this.branchSteps(parent, branch);
    this.insertTemplateIntoContainer(container, container.length, templateKey,
      this.makePath(parentPath, branch, container.length));
  }

  private insertTemplateIntoContainer(container: WorkflowStep[], insertIndex: number, templateKey: string,
    newPath: string): void {
    if (templateKey === 'shot_summary') {
      let shotId = this.nextStepId(container);
      let summaryId = shotId + 1;
      let shot = this.createTemplateStep('screenshot', shotId, '');
      let summary = this.createTemplateStep('summary', summaryId, '${steps.' + shotId + '.output.image_b64}');
      container.splice(insertIndex, 0, shot, summary);
      this.prepareStructureSelectionRestore(newPath);
      this.markWorkflowStructureChanged();
      return;
    }
    let nextId = this.nextStepId(container);
    let imageVariable = this.defaultImageVariable(container, insertIndex);
    let step = this.createTemplateStep(templateKey, nextId, imageVariable);
    container.splice(insertIndex, 0, step);
    this.prepareStructureSelectionRestore(newPath);
    this.markWorkflowStructureChanged();
  }

  private createTemplateStep(templateKey: string, id: number, imageVariable: string): WorkflowStep {
    if (templateKey === 'open_app') {
      return { id: id, type: 'gui_task', task_description: '打开目标应用', on_error: 'stop' };
    }
    if (templateKey === 'gui_task') {
      return { id: id, type: 'gui_task', task_description: '描述需要智能体完成的界面操作', on_error: 'stop' };
    }
    if (templateKey === 'screenshot') {
      return { id: id, type: 'gui_action', action: 'screenshot', file_name: 'screen_' + id + '.jpg' };
    }
    if (templateKey === 'summary') {
      return {
        id: id,
        type: 'tool',
        tool_name: 'vlm_qa',
        inputs: {
          mode: 'summary',
          image: imageVariable,
          question: '请用一段话总结当前截图中的关键信息，不要使用 Markdown 格式。'
        }
      };
    }
    if (templateKey === 'click') {
      return { id: id, type: 'gui_action', action: 'click', x: 540, y: 1200 };
    }
    if (templateKey === 'input') {
      return { id: id, type: 'gui_action', action: 'input', text: '输入文本' };
    }
    if (templateKey === 'swipe_coords') {
      return { id: id, type: 'gui_action', action: 'swipe_with_coords', start_x: 540, start_y: 1700, end_x: 540, end_y: 650 };
    }
    if (templateKey === 'wait') {
      return { id: id, type: 'gui_action', action: 'sleep', seconds: 1 };
    }
    if (templateKey === 'keyevent') {
      return { id: id, type: 'gui_action', action: 'keyevent', key: 'BACK' };
    }
    if (templateKey === 'if') {
      return {
        id: id,
        type: 'if',
        condition: { left: '${steps.2.output.response}', operator: 'contains', right: '关键词' },
        then_steps: [],
        else_steps: []
      };
    }
    if (templateKey === 'until_loop') {
      return {
        id: id,
        type: 'loop',
        max_times: 10,
        break_if: { left: '${steps.2.output.structured_output.contains_today_chat}', operator: '==', right: false },
        steps: []
      };
    }
    return { id: id, type: 'loop', times: 3, steps: [] };
  }

  private deleteSelectedStep(): void {
    this.deleteStepAtPath(this.selectedPath);
  }

  private deleteStepAtPath(path: string): void {
    if (this.flowStructureBusy) {
      return;
    }
    path = this.resolvedDeletePath(path);
    if (path.length === 0) {
      return;
    }
    if (!this.canDeleteStepAtPath(path)) {
      return;
    }
    this.focusStepForStructureAction(path);
    this.persistSelectedDraftInPlace();
    let container = this.containerByPath(path);
    let index = this.pathIndex(path);
    if (!container || index < 0 || index >= container.length) {
      return;
    }
    let count = this.stepGroupLength(container, index);
    container.splice(index, count);
    this.pendingStructureSelectionPath = '';
    this.selectedPath = '';
    this.clearNodeDrafts();
    this.markWorkflowStructureChanged();
  }

  private moveSelectedStep(offset: number): void {
    this.moveStepAtPath(this.selectedPath, offset);
  }

  private moveStepAtPath(path: string, offset: number): void {
    if (this.flowStructureBusy) {
      return;
    }
    path = this.workflowGroupStartPath(path);
    if (!this.canMoveWorkflowStepAtPath(path, offset)) {
      return;
    }
    this.focusStepForStructureAction(path);
    this.persistSelectedDraftInPlace();
    let container = this.containerByPath(path);
    let index = this.pathIndex(path);
    if (!container || index < 0 || index >= container.length || offset === 0) {
      return;
    }
    let groupLength = this.stepGroupLength(container, index);
    if (offset < 0) {
      let prevIndex = index - 1;
      if (prevIndex < 0) {
        return;
      }
      if (this.isSummaryPartOfPair(container, prevIndex)) {
        prevIndex = prevIndex - 1;
      }
      let moving: WorkflowStep[] = container.splice(index, groupLength);
      for (let i = 0; i < moving.length; i++) {
        container.splice(prevIndex + i, 0, moving[i]);
      }
      this.prepareStructureSelectionRestore(this.replaceLastPathIndex(path, prevIndex));
      this.markWorkflowStructureChanged();
      return;
    }

    let nextIndex = index + groupLength;
    if (nextIndex >= container.length) {
      return;
    }
    let nextLength = this.stepGroupLength(container, nextIndex);
    let moving: WorkflowStep[] = container.splice(index, groupLength);
    let insertIndex = index + nextLength;
    for (let i = 0; i < moving.length; i++) {
      container.splice(insertIndex + i, 0, moving[i]);
    }
    this.prepareStructureSelectionRestore(this.replaceLastPathIndex(path, insertIndex));
    this.markWorkflowStructureChanged();
  }

  private duplicateSelectedStep(): void {
    this.duplicateStepAtPath(this.selectedPath);
  }

  private duplicateStepAtPath(path: string): void {
    if (this.flowStructureBusy) {
      return;
    }
    path = this.workflowGroupStartPath(path);
    this.persistSelectedDraftInPlace();
    let container = this.containerByPath(path);
    let index = this.pathIndex(path);
    if (!container || index < 0 || index >= container.length) {
      return;
    }
    if (this.isShotSummaryPairAt(container, index)) {
      let shotCopy = ArkJSON.parse(ArkJSON.stringify(container[index])) as WorkflowStep;
      let summaryCopy = ArkJSON.parse(ArkJSON.stringify(container[index + 1])) as WorkflowStep;
      let shotId = this.nextStepId(container);
      let summaryId = shotId + 1;
      shotCopy.id = shotId;
      summaryCopy.id = summaryId;
      if (!summaryCopy.inputs) {
        summaryCopy.inputs = {};
      }
      summaryCopy.inputs.image = this.shotImageVariable(shotCopy);
      container.splice(index + 2, 0, shotCopy, summaryCopy);
      this.prepareStructureSelectionRestore(this.replaceLastPathIndex(path, index + 2));
      this.markWorkflowStructureChanged();
      return;
    }
    let copy = ArkJSON.parse(ArkJSON.stringify(container[index])) as WorkflowStep;
    copy.id = this.nextStepId(container);
    container.splice(index + 1, 0, copy);
    this.prepareStructureSelectionRestore(this.replaceLastPathIndex(path, index + 1));
    this.markWorkflowStructureChanged();
  }

  private pathIndex(path: string): number {
    let parts = this.parsePath(path);
    if (parts.length === 0) {
      return -1;
    }
    return parts[parts.length - 1].index;
  }

  private selectedStep(): WorkflowStep | null {
    return this.stepByPath(this.selectedPath);
  }

  private selectedStepType(): string {
    let step = this.selectedStep();
    return step ? step.type : '';
  }

  private selectedStepAction(): string {
    let step = this.selectedStep();
    return step && step.action ? step.action : '';
  }

  private isOpenAppStep(step: WorkflowStep, path: string): boolean {
    if (step.type !== 'gui_task') {
      return false;
    }
    let description = step.task_description || '';
    return description.startsWith('打开');
  }

  private isSelectedOpenAppStep(): boolean {
    let step = this.selectedStep();
    return step ? this.isOpenAppStep(step, this.selectedPath) : false;
  }

  private openAppNameFromDescription(description: string): string {
    if (description.startsWith('打开')) {
      return description.substring(2);
    }
    return description;
  }

  private selectedOpenAppName(): string {
    let step = this.selectedStep();
    if (!step) {
      return '';
    }
    return this.openAppNameFromDescription(step.task_description || '');
  }

  private updateSelectedOpenAppName(value: string): void {
    let step = this.selectedStep();
    if (!step) {
      return;
    }
    let appName = value.trim();
    step.task_description = appName.length > 0 ? '打开' + appName : '打开目标应用';
    this.markWorkflowChanged();
  }

  private updateDraftStringField(field: string, value: string): void {
    if (field === 'id') {
      this.nodeIdDraft = value;
    } else if (field === 'name') {
      this.nodeNameDraft = value;
    } else if (field === 'file_name') {
      this.actionFileNameDraft = value;
    } else if (field === 'task_description') {
      this.guiTaskDraft = value;
    } else if (field === 'tool_name') {
      return;
    } else {
      this.updateSelectedStringField(field, value);
    }
  }

  private workflowNameText(): string {
    if (this.editorWorkflow.metadata && this.editorWorkflow.metadata.name) {
      return this.editorWorkflow.metadata.name;
    }
    return '';
  }

  private workflowDescriptionText(): string {
    if (this.editorWorkflow.metadata && this.editorWorkflow.metadata.description) {
      return this.editorWorkflow.metadata.description;
    }
    return '';
  }

  private loadWorkflowMetaDraft(): void {
    this.workflowNameDraft = this.workflowNameText();
    this.workflowDescriptionDraft = this.workflowDescriptionText();
  }

  private applyWorkflowMetaDraft(): void {
    if (!this.editorWorkflow.metadata) {
      this.editorWorkflow.metadata = {};
    }
    this.editorWorkflow.metadata.name = this.workflowNameDraft;
    this.editorWorkflow.metadata.description = this.workflowDescriptionDraft;
  }

  private updateWorkflowName(value: string): void {
    this.workflowNameDraft = value;
  }

  private updateWorkflowDescription(value: string): void {
    this.workflowDescriptionDraft = value;
  }

  private conditionValueIsMeaningful(value: WorkflowJsonValue | undefined): boolean {
    if (value === undefined || value === null) {
      return false;
    }
    if (typeof value === 'string') {
      return value.trim().length > 0;
    }
    return true;
  }

  private conditionIsMeaningful(condition: WorkflowCondition | undefined): boolean {
    if (!condition) {
      return false;
    }
    return this.conditionValueIsMeaningful(condition.left) || this.conditionValueIsMeaningful(condition.right);
  }

  private loopUsesBreakCondition(step: WorkflowStep | null): boolean {
    if (!step || step.type !== 'loop' || !step.break_if) {
      return false;
    }
    if (this.conditionIsMeaningful(step.break_if)) {
      return true;
    }
    return step.max_times !== undefined && step.times === undefined;
  }

  private selectedLoopUsesBreakCondition(): boolean {
    return this.loopUsesBreakCondition(this.selectedStep());
  }

  private selectedStringField(field: string): string {
    let step = this.selectedStep();
    if (!step) {
      return '';
    }
    if (field === 'id') {
      return String(step.id);
    }
    if (field === 'name') {
      return step.name || '';
    }
    if (field === 'task_description') {
      return step.task_description || '';
    }
    if (field === 'file_name') {
      return step.file_name || '';
    }
    if (field === 'text') {
      return step.text || '';
    }
    if (field === 'direction') {
      return step.direction || 'up';
    }
    if (field === 'key') {
      return step.key || 'BACK';
    }
    if (field === 'package_name') {
      return step.package_name || '';
    }
    if (field === 'tool_name') {
      return step.tool_name || 'vlm_qa';
    }
    if (field === 'on_error') {
      return step.on_error || 'stop';
    }
    return '';
  }

  private selectedNumberField(field: string): string {
    let step = this.selectedStep();
    if (!step) {
      return '';
    }
    let value: number | string | undefined = undefined;
    if (field === 'x') {
      value = step.x;
    } else if (field === 'y') {
      value = step.y;
    } else if (field === 'start_x') {
      value = step.start_x;
    } else if (field === 'start_y') {
      value = step.start_y;
    } else if (field === 'end_x') {
      value = step.end_x;
    } else if (field === 'end_y') {
      value = step.end_y;
    } else if (field === 'seconds') {
      value = step.seconds;
    } else if (field === 'times') {
      value = step.times;
    } else if (field === 'max_times') {
      value = step.max_times;
    }
    return value === undefined ? '' : String(value);
  }

  private updateSelectedStringField(field: string, value: string): void {
    let step = this.selectedStep();
    if (!step) {
      return;
    }
    if (field === 'id') {
      step.id = value;
      let summary = this.selectedPairSummaryStep();
      if (summary && summary.inputs) {
        summary.inputs.image = this.shotImageVariable(step);
      }
    } else if (field === 'name') {
      step.name = value;
    } else if (field === 'task_description') {
      step.task_description = value;
    } else if (field === 'file_name') {
      step.file_name = value;
    } else if (field === 'text') {
      step.text = value;
    } else if (field === 'direction') {
      step.direction = value;
    } else if (field === 'key') {
      step.key = value;
    } else if (field === 'package_name') {
      step.package_name = value;
    } else if (field === 'tool_name') {
      step.tool_name = value;
    } else if (field === 'on_error') {
      step.on_error = value;
    }
    this.markWorkflowChanged();
  }

  private updateSelectedNumberField(field: string, value: string): void {
    let step = this.selectedStep();
    if (!step) {
      return;
    }
    if (value.trim().length === 0) {
      this.clearSelectedNumberField(step, field);
      this.markWorkflowChanged();
      return;
    }
    let parsed = Number(value);
    if (isNaN(parsed)) {
      return;
    }
    if (field === 'x') {
      step.x = parsed;
    } else if (field === 'y') {
      step.y = parsed;
    } else if (field === 'start_x') {
      step.start_x = parsed;
    } else if (field === 'start_y') {
      step.start_y = parsed;
    } else if (field === 'end_x') {
      step.end_x = parsed;
    } else if (field === 'end_y') {
      step.end_y = parsed;
    } else if (field === 'seconds') {
      step.seconds = parsed;
    } else if (field === 'times') {
      step.times = parsed;
    } else if (field === 'max_times') {
      step.max_times = parsed;
    }
    this.markWorkflowChanged();
  }

  private clearSelectedNumberField(step: WorkflowStep, field: string): void {
    if (field === 'x') {
      step.x = undefined;
    } else if (field === 'y') {
      step.y = undefined;
    } else if (field === 'start_x') {
      step.start_x = undefined;
    } else if (field === 'start_y') {
      step.start_y = undefined;
    } else if (field === 'end_x') {
      step.end_x = undefined;
    } else if (field === 'end_y') {
      step.end_y = undefined;
    } else if (field === 'seconds') {
      step.seconds = undefined;
    } else if (field === 'times') {
      step.times = undefined;
    } else if (field === 'max_times') {
      step.max_times = undefined;
    }
  }

  private updateSelectedAction(value: string): void {
    let step = this.selectedStep();
    if (!step) {
      return;
    }
    step.action = value;
    if (value === 'screenshot' && !step.file_name) {
      step.file_name = 'screen_' + String(step.id) + '.jpg';
    }
    if (value === 'sleep' && step.seconds === undefined) {
      step.seconds = 1;
    }
    if (value === 'keyevent' && !step.key) {
      step.key = 'BACK';
    }
    if (value === 'swipe' && !step.direction) {
      step.direction = 'up';
    }
    this.markWorkflowChanged();
  }

  private ensureToolInputs(step: WorkflowStep): WorkflowToolInputs {
    if (!step.inputs) {
      step.inputs = {};
    }
    return step.inputs;
  }

  private selectedToolInput(field: string): string {
    let step = this.selectedToolTargetStep();
    if (!step || !step.inputs) {
      return field === 'mode' ? 'summary' : '';
    }
    if (field === 'mode') {
      return step.inputs.mode || 'summary';
    }
    if (field === 'image') {
      return step.inputs.image || '';
    }
    if (field === 'question') {
      return step.inputs.question || '';
    }
    return '';
  }

  private updateSelectedToolInput(field: string, value: string): void {
    let step = this.selectedToolTargetStep();
    if (!step) {
      return;
    }
    let inputs = this.ensureToolInputs(step);
    if (field === 'mode') {
      inputs.mode = value;
    } else if (field === 'image') {
      inputs.image = value;
    } else if (field === 'question') {
      inputs.question = value;
    }
    this.markWorkflowChanged();
  }

  private updateSelectedToolBlocking(value: boolean): void {
    let step = this.selectedToolTargetStep();
    if (!step) {
      return;
    }
    let inputs = this.ensureToolInputs(step);
    inputs.blocking = value;
    this.markWorkflowChanged();
  }

  private selectedToolBlocking(): boolean {
    let step = this.selectedToolTargetStep();
    if (!step || !step.inputs) {
      return false;
    }
    return step.inputs.blocking === true;
  }

  private syncToolSchemaDraft(): void {
    let step = this.selectedToolTargetStep();
    if (step && step.type === 'tool' && step.inputs && step.inputs.json_schema) {
      this.toolSchemaText = ArkJSON.stringify(step.inputs.json_schema, null, 2);
    } else {
      this.toolSchemaText = '';
    }
  }

  private applySelectedToolSchemaDraft(throwOnError: boolean): void {
    this.applyToolSchemaDraftToPath(this.selectedPath, throwOnError);
  }

  private applyToolSchemaDraftToPath(path: string, throwOnError: boolean): void {
    let step = this.toolTargetStepByPath(path);
    if (!step || step.type !== 'tool') {
      return;
    }
    let inputs = this.ensureToolInputs(step);
    let text = this.toolSchemaText.trim();
    if (text.length === 0) {
      inputs.json_schema = undefined;
      return;
    }
    try {
      inputs.json_schema = ArkJSON.parse(text) as Object;
    } catch (e) {
      if (throwOnError) {
        let err = e as Error;
        throw new Error('JSON Schema 格式错误：' + err.message);
      }
    }
  }

  private selectedToolTargetStep(): WorkflowStep | null {
    return this.toolTargetStepByPath(this.selectedPath);
  }

  private toolTargetStepByPath(path: string): WorkflowStep | null {
    let pairSummary = this.pairSummaryStepByPath(path);
    if (pairSummary) {
      return pairSummary;
    }
    let step = this.stepByPath(path);
    if (step && step.type === 'tool') {
      return step;
    }
    return null;
  }

  private summaryQuestion(step: WorkflowStep): string {
    if (step.inputs && step.inputs.question) {
      return step.inputs.question;
    }
    return '请总结当前截图';
  }

  private parseJsonValueText(value: string): WorkflowJsonValue {
    let text = value.trim();
    if (text.length === 0) {
      return '';
    }
    try {
      return ArkJSON.parse(text) as WorkflowJsonValue;
    } catch (e) {
      return value;
    }
  }

  private valueText(value: WorkflowJsonValue | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    return ArkJSON.stringify(value);
  }

  private selectedConditionObject(kind: string): WorkflowCondition {
    return this.conditionObjectByPath(this.selectedPath, kind);
  }

  private conditionObjectByPath(path: string, kind: string): WorkflowCondition {
    let step = this.stepByPath(path);
    if (!step) {
      return {};
    }
    if (kind === 'break') {
      return step.break_if ? step.break_if : {};
    }
    let condition = step.condition;
    if (condition === undefined || condition === null) {
      return {};
    }
    if (typeof condition === 'object') {
      return condition as WorkflowCondition;
    }
    return {
      left: condition as WorkflowJsonValue,
      operator: '==',
      right: true
    };
  }

  private ensureSelectedCondition(kind: string): WorkflowCondition {
    return this.ensureConditionByPath(this.selectedPath, kind);
  }

  private ensureConditionByPath(path: string, kind: string): WorkflowCondition {
    let step = this.stepByPath(path);
    if (!step) {
      return {};
    }
    if (kind === 'break') {
      if (!step.break_if) {
        step.break_if = {};
      }
      return step.break_if;
    }
    if (typeof step.condition !== 'object' || step.condition === null) {
      step.condition = {};
    }
    return step.condition as WorkflowCondition;
  }

  private selectedConditionValue(kind: string, field: string): string {
    let condition = this.selectedConditionObject(kind);
    if (field === 'left') {
      return this.valueText(condition.left);
    }
    if (field === 'right') {
      return this.valueText(condition.right);
    }
    return condition.operator || '==';
  }

  private updateSelectedCondition(kind: string, field: string, value: string): void {
    let condition = this.ensureSelectedCondition(kind);
    if (field === 'left') {
      condition.left = this.parseJsonValueText(value);
    } else if (field === 'right') {
      condition.right = this.parseJsonValueText(value);
    } else {
      condition.operator = value;
    }
    this.markWorkflowChanged();
  }

  private nodeLabel(step: WorkflowStep, path: string): string {
    if (step.type === 'gui_task') {
      return this.isOpenAppStep(step, path) ? '打开应用' : 'GUI 任务';
    }
    if (step.type === 'gui_action') {
      if (step.action === 'screenshot') {
        return '截图';
      }
      if (step.action === 'click') {
        return '点击';
      }
      if (step.action === 'input') {
        return '输入';
      }
      if (step.action === 'sleep') {
        return '等待';
      }
      if (step.action === 'keyevent') {
        return '按键';
      }
      if (step.action === 'swipe' || step.action === 'swipe_with_coords') {
        return '滑动';
      }
      return step.action || 'GUI 动作';
    }
    if (step.type === 'tool') {
      return 'Summary';
    }
    if (step.type === 'if') {
      return 'If 条件';
    }
    if (step.type === 'loop') {
      return this.loopUsesBreakCondition(step) ? 'Until 循环' : 'For 循环';
    }
    return step.type;
  }

  private nodeSummary(step: WorkflowStep, path: string): string {
    if (step.type === 'gui_task') {
      if (this.isOpenAppStep(step, path)) {
        return this.openAppNameFromDescription(step.task_description || '目标应用');
      }
      return step.task_description || '智能 GUI 操作';
    }
    if (step.type === 'gui_action') {
      if (step.action === 'screenshot') {
        return step.file_name || '截图并传给后续节点';
      }
      if (step.action === 'click') {
        return '坐标 ' + String(step.x || 0) + ', ' + String(step.y || 0);
      }
      if (step.action === 'input') {
        return step.text || '输入文本';
      }
      if (step.action === 'swipe_with_coords') {
        return String(step.start_x || 0) + ', ' + String(step.start_y || 0) + ' 到 ' +
          String(step.end_x || 0) + ', ' + String(step.end_y || 0);
      }
      if (step.action === 'swipe') {
        return '方向 ' + (step.direction || 'up');
      }
      if (step.action === 'keyevent') {
        return step.key || 'BACK';
      }
      if (step.action === 'sleep') {
        return String(step.seconds || 1) + ' 秒';
      }
      return step.action || '执行确定性设备动作';
    }
    if (step.type === 'tool') {
      if (step.inputs && step.inputs.question) {
        return step.inputs.question;
      }
      return step.tool_name || 'vlm_qa';
    }
    if (step.type === 'if') {
      return this.selectedConditionSummary(step.condition);
    }
    if (step.type === 'loop') {
      if (this.loopUsesBreakCondition(step)) {
        return '最多 ' + String(step.max_times || 0) + ' 次，满足条件后退出';
      }
      return '重复 ' + String(step.times || 0) + ' 次';
    }
    return '';
  }

  private selectedConditionSummary(condition: WorkflowCondition | string | boolean | undefined): string {
    if (condition === undefined || condition === null) {
      return '条件未设置';
    }
    if (typeof condition === 'string' || typeof condition === 'boolean') {
      return String(condition);
    }
    return this.valueText(condition.left) + ' ' + (condition.operator || '==') + ' ' + this.valueText(condition.right);
  }

  private nodeColor(step: WorkflowStep, path: string): string {
    if (step.type === 'gui_task') {
      return '#276EF1';
    }
    if (step.type === 'tool' || (step.type === 'gui_action' && step.action === 'screenshot')) {
      return '#148F73';
    }
    if (step.type === 'if' || step.type === 'loop') {
      return '#7C4DFF';
    }
    return '#C76800';
  }

  private nodeBackground(step: WorkflowStep, path: string): string {
    if (step.type === 'gui_task') {
      return '#EAF2FF';
    }
    if (step.type === 'tool' || (step.type === 'gui_action' && step.action === 'screenshot')) {
      return '#EAF8F3';
    }
    if (step.type === 'if' || step.type === 'loop') {
      return '#F0EAFF';
    }
    return '#FFF3E2';
  }

  @Builder SegmentButton(label: string, value: string, activeValue: string, color: string, onTap: () => void) {
    Text(label)
      .fontSize(11)
      .fontWeight(activeValue === value ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(activeValue === value ? Color.White : color)
      .height(30)
      .padding({ left: 10, right: 10 })
      .textAlign(TextAlign.Center)
      .backgroundColor(activeValue === value ? color : '#F2F5FA')
      .borderRadius(8)
      .margin({ right: 8, bottom: 8 })
      .onClick(onTap)
  }

  @Builder FieldLabel(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor('#6F7584')
      .width('100%')
      .margin({ bottom: 6 })
  }

  @Builder FieldLabelTop(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor('#6F7584')
      .width('100%')
      .margin({ top: 10, bottom: 6 })
  }

  @Builder TextField(label: string, placeholder: string, value: string, field: string) {
    Column() {
      this.FieldLabel(label)
      TextInput({ placeholder: placeholder, text: value })
        .height(38)
        .fontSize(12)
        .fontColor('#1E2633')
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
        .padding({ left: 10, right: 10 })
        .onChange((val: string) => {
          this.updateDraftStringField(field, val);
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 10 })
  }

  @Builder ReadOnlyField(label: string, value: string) {
    Column() {
      this.FieldLabel(label)
      Text(value)
        .height(38)
        .fontSize(12)
        .fontColor('#1E2633')
        .width('100%')
        .padding({ left: 10, right: 10 })
        .textAlign(TextAlign.Start)
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 10 })
  }

  @Builder NumberField(label: string, placeholder: string, value: string, field: string) {
    Column() {
      this.FieldLabel(label)
      TextInput({ placeholder: placeholder, text: value })
        .height(38)
        .fontSize(12)
        .fontColor('#1E2633')
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
        .padding({ left: 10, right: 10 })
        .onChange((val: string) => {
          this.updateSelectedNumberField(field, val);
        })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder WorkflowMetaPanel() {
    Column() {
      Row() {
        Text('工作流信息')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .layoutWeight(1)
        Text(String(this.editorWorkflow.steps.length) + ' 个主节点')
          .fontSize(11)
          .fontColor('#276EF1')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#EAF2FF')
          .borderRadius(8)
      }
      .width('100%')
      Column() {
        this.FieldLabel('任务标题')
        TextInput({ placeholder: '展示给用户的任务名', text: this.workflowDescriptionDraft })
          .height(38)
          .fontSize(12)
          .backgroundColor('#F6F8FC')
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onChange((val: string) => { this.updateWorkflowDescription(val); })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 12 })
      this.WorkflowSceneSelector()
      this.FieldLabelTop('上下文变量')
      TextArea({ placeholder: '{"contact_name":"小赵"}', text: this.editorContextText })
        .width('100%')
        .height(46)
        .fontSize(11)
        .fontFamily('monospace')
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
        .padding({ left: 10, right: 10, top: 7, bottom: 7 })
        .onChange((val: string) => { this.editorContextText = val; })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .border({ width: 1, color: '#E3E8F1' })
  }

  @Builder WorkflowSceneSelector() {
    Column() {
      this.FieldLabelTop('分类')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(workflowSceneConfigs(), (scene: WorkflowSceneConfig) => {
          Text(scene.label)
            .fontSize(11)
            .fontWeight(this.editorSceneId === scene.sceneId ? FontWeight.Bold : FontWeight.Regular)
            .fontColor(this.editorSceneId === scene.sceneId ? Color.White : scene.color)
            .height(30)
            .padding({ left: 12, right: 12 })
            .textAlign(TextAlign.Center)
            .backgroundColor(this.editorSceneId === scene.sceneId ? scene.color : '#F8F9FE')
            .borderRadius(8)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => { this.editorSceneId = scene.sceneId; })
        }, (scene: WorkflowSceneConfig) => scene.tabId)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder NodePalette() {
    Column() {
      Row() {
        Text('节点库')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .layoutWeight(1)
        Text(this.selectedPath.length > 0 ? '插入到选中节点后' : '插入到末尾')
          .fontSize(11)
          .fontColor('#6F7584')
      }
      .width('100%')
      Scroll() {
        Row() {
          ForEach(NODE_TEMPLATES, (item: WorkflowNodeTemplate) => {
            Column() {
              Text(item.shortLabel)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(item.accentColor)
              Text(item.label)
                .fontSize(10)
                .fontColor('#4E5666')
                .margin({ top: 4 })
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width(82)
            .height(58)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(item.backgroundColor)
            .borderRadius(10)
            .border({ width: 1, color: '#FFFFFF' })
            .margin({ right: 10 })
            .onClick(() => { this.insertTemplateAfterSelection(item.key); })
          }, (item: WorkflowNodeTemplate) => item.key)
        }
      }
      .width('100%')
      .height(68)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .border({ width: 1, color: '#E3E8F1' })
    .margin({ top: 12 })
  }

  @Builder FlowStepList(steps: WorkflowStep[], parentPath: string, branch: string, depth: number) {
    if (steps.length === 0) {
      Row() {
        Row().width(2).height(28).backgroundColor('#DCE3EF').borderRadius(1).margin({ left: depth * 14 + 13, right: 12 })
        Text('空分支')
          .fontSize(12)
          .fontColor('#9AA2B1')
          .height(30)
      }
      .width('100%')
      .margin({ top: 8 })
    } else {
      ForEach(this.visibleFlowItems(steps, parentPath, branch), (item: FlowRenderItem) => {
        if (item.isPair && item.summary) {
          this.FlowShotSummaryCard(item.step, item.summary, item.path, depth)
        } else {
          this.FlowStepCard(item.step, item.path, depth)
        }
      }, (item: FlowRenderItem) => item.key)
    }
  }

  @Builder FlowShotSummaryCard(shot: WorkflowStep, summary: WorkflowStep, path: string, depth: number) {
    Row() {
      Column() {
        Row().width(2).height(18).backgroundColor('#DCE3EF')
        Text(String(shot.id) + '+')
          .fontSize(9)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .backgroundColor('#148F73')
          .borderRadius(14)
        Row().width(2).height(18).backgroundColor('#DCE3EF')
      }
      .width(32)
      .alignItems(HorizontalAlign.Center)
      .margin({ left: depth * 14, right: 10 })
      Column() {
        Row() {
          Text('截图 + Summary')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('2 steps')
            .fontSize(10)
            .fontColor('#148F73')
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor('#EAF8F3')
            .borderRadius(7)
        }
        .width('100%')
        Text((shot.file_name || 'screenshot.jpg') + ' / ' + this.summaryQuestion(summary))
          .fontSize(11)
          .fontColor('#6F7584')
          .margin({ top: 6 })
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Scroll() {
          Row() {
            Button(this.selectedPath === path ? '已选中' : '选中')
              .width(74)
              .height(30)
              .fontSize(11)
              .backgroundColor(this.selectedPath === path ? '#148F73' : '#EAF8F3')
              .fontColor(this.selectedPath === path ? Color.White : '#148F73')
              .borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => { this.selectStep(path); })
            Button('上移')
              .width(68)
              .height(30)
              .fontSize(11)
              .backgroundColor(this.moveButtonBackground(path, -1))
              .fontColor(this.moveButtonColor(path, -1))
              .borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => { this.moveStepAtPath(path, -1); })
            Button('下移')
              .width(68)
              .height(30)
              .fontSize(11)
              .backgroundColor(this.moveButtonBackground(path, 1))
              .fontColor(this.moveButtonColor(path, 1))
              .borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => { this.moveStepAtPath(path, 1); })
            Button('删除')
              .width(68)
              .height(30)
              .fontSize(11)
              .backgroundColor(this.deleteButtonBackground(path))
              .fontColor(this.deleteButtonColor(path))
              .borderRadius(8)
              .onClick(() => { this.deleteStepAtPath(path); })
          }
        }
        .width('100%')
        .height(38)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .margin({ top: 10 })
        if (this.selectedPath === path) {
          this.InlineNodeEditor()
        }
      }
      .layoutWeight(1)
      .padding(13)
      .backgroundColor(this.selectedPath === path ? '#F3FCF8' : Color.White)
      .borderRadius(14)
      .border({ width: this.selectedPath === path ? 2 : 1, color: this.selectedPath === path ? '#148F73' : '#E3E8F1' })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 10 })
  }

  @Builder FlowStepCard(step: WorkflowStep, path: string, depth: number) {
    Row() {
      Column() {
        Row().width(2).height(18).backgroundColor('#DCE3EF')
        Text(String(step.id))
          .fontSize(10)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.nodeColor(step, path))
          .borderRadius(14)
        Row().width(2).height(18).backgroundColor('#DCE3EF')
      }
      .width(32)
      .alignItems(HorizontalAlign.Center)
      .margin({ left: depth * 14, right: 10 })
      Column() {
        Row() {
          Text(this.nodeLabel(step, path))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(step.type)
            .fontSize(10)
            .fontColor(this.nodeColor(step, path))
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor(this.nodeBackground(step, path))
            .borderRadius(7)
        }
        .width('100%')
        Text(this.nodeSummary(step, path))
          .fontSize(11)
          .fontColor('#6F7584')
          .margin({ top: 6 })
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Scroll() {
          Row() {
            Button(this.selectedPath === path ? '已选中' : '选中')
              .width(74)
              .height(30)
              .fontSize(11)
              .backgroundColor(this.selectedPath === path ? '#276EF1' : '#EEF4FF')
              .fontColor(this.selectedPath === path ? Color.White : '#276EF1')
              .borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => { this.selectStep(path); })
            Button('上移')
              .width(68)
              .height(30)
              .fontSize(11)
              .backgroundColor(this.moveButtonBackground(path, -1))
              .fontColor(this.moveButtonColor(path, -1))
              .borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => { this.moveStepAtPath(path, -1); })
            Button('下移')
              .width(68)
              .height(30)
              .fontSize(11)
              .backgroundColor(this.moveButtonBackground(path, 1))
              .fontColor(this.moveButtonColor(path, 1))
              .borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => { this.moveStepAtPath(path, 1); })
            Button('删除')
              .width(68)
              .height(30)
              .fontSize(11)
              .backgroundColor(this.deleteButtonBackground(path))
              .fontColor(this.deleteButtonColor(path))
              .borderRadius(8)
              .onClick(() => { this.deleteStepAtPath(path); })
          }
        }
        .width('100%')
        .height(38)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .margin({ top: 10 })
        if (this.selectedPath === path) {
          this.InlineNodeEditor()
        }
        if (step.type === 'loop') {
          this.BranchEditor(path, '循环体', CHILD_BRANCH_STEPS, step.steps || [], depth + 1)
        }
        if (step.type === 'if') {
          this.BranchEditor(path, '满足条件', CHILD_BRANCH_THEN, step.then_steps || [], depth + 1)
          this.BranchEditor(path, '否则执行', CHILD_BRANCH_ELSE, step.else_steps || [], depth + 1)
        }
      }
      .layoutWeight(1)
      .padding(13)
      .backgroundColor(this.selectedPath === path ? '#F8FBFF' : Color.White)
      .borderRadius(14)
      .border({ width: this.selectedPath === path ? 2 : 1, color: this.selectedPath === path ? '#276EF1' : '#E3E8F1' })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 10 })
  }

  @Builder BranchEditor(parentPath: string, label: string, branch: string, steps: WorkflowStep[], depth: number) {
    Column() {
      Row() {
        Text(label)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor('#4E5666')
          .layoutWeight(1)
        Button('添加节点')
          .height(28)
          .fontSize(10)
          .backgroundColor('#F0EAFF')
          .fontColor('#7C4DFF')
          .borderRadius(8)
          .onClick(() => {
            this.insertTemplateIntoBranch(parentPath, branch, 'gui_task');
          })
      }
      .width('100%')
      .margin({ top: 12, bottom: 6 })
      this.FlowStepList(steps, parentPath, branch, depth)
    }
    .width('100%')
    .padding({ left: 0, right: 0, top: 2, bottom: 2 })
  }

  @Builder FlowCanvas() {
    Column() {
      Row() {
        Text('流程图')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .layoutWeight(1)
        Button('取消选中')
          .height(30)
          .fontSize(11)
          .backgroundColor('#F2F5FA')
          .fontColor('#4E5666')
          .borderRadius(8)
          .onClick(() => {
            this.selectedPath = '';
            this.toolSchemaText = '';
          })
      }
      .width('100%')
      .margin({ bottom: 12 })
      if (!this.flowCanvasMounted) {
        Blank()
          .height(1)
          .width('100%')
      } else if (this.flowGraphVersion % 2 === 0) {
        this.FlowCanvasBodyEven()
      } else {
        this.FlowCanvasBodyOdd()
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FAFBFD')
    .borderRadius(14)
    .border({ width: 1, color: '#E3E8F1' })
    .margin({ top: 12 })
  }

  @Builder FlowCanvasBodyEven() {
    this.FlowCanvasBody()
  }

  @Builder FlowCanvasBodyOdd() {
    this.FlowCanvasBody()
  }

  @Builder FlowCanvasBody() {
    if (this.flowDisplaySteps().length === 0) {
      Column() {
        Text('暂无节点')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
        Text('从上方节点库添加“打开应用”“GUI 任务”“截图+Summary”或控制流节点。')
          .fontSize(12)
          .fontColor('#6F7584')
          .margin({ top: 8 })
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding(24)
      .backgroundColor(Color.White)
      .borderRadius(12)
      .border({ width: 1, color: '#E3E8F1' })
    } else if (this.flowNeedsHorizontalScroll()) {
      Scroll() {
        Column() {
          this.FlowStepList(this.flowDisplaySteps(), '', ROOT_BRANCH, 0)
        }
        .width('100%')
        .constraintSize({ minWidth: this.flowCanvasMinWidth() })
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
    } else {
      this.FlowStepList(this.flowDisplaySteps(), '', ROOT_BRANCH, 0)
    }
  }

  @Builder InlineNodeEditor() {
    Column() {
      Row()
        .width('100%')
        .height(1)
        .backgroundColor('#DCE3EF')
        .margin({ top: 12, bottom: 12 })
      Row() {
        Text('节点属性')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .layoutWeight(1)
      }
      .width('100%')
      if (this.selectedPath.length > 0 && this.selectedStep()) {
        this.ReadOnlyField('节点 ID', this.nodeIdDraft)
        this.TextField('显示名称', '可选', this.nodeNameDraft, 'name')
        Row() {
          Text('失败策略')
            .fontSize(11)
            .fontColor('#6F7584')
            .margin({ right: 10, bottom: 8 })
          this.SegmentButton('停止', 'stop', this.nodeOnErrorDraft, '#B42318', () => {
            this.nodeOnErrorDraft = 'stop';
          })
          this.SegmentButton('继续', 'continue', this.nodeOnErrorDraft, '#148F73', () => {
            this.nodeOnErrorDraft = 'continue';
          })
        }
        .width('100%')
        .margin({ top: 10 })
        Column() {
          this.FieldLabel('在当前节点后添加')
          Scroll() {
            Row() {
              ForEach(NODE_TEMPLATES, (item: WorkflowNodeTemplate) => {
                Button(item.label)
                  .height(30)
                  .fontSize(10)
                  .backgroundColor(item.backgroundColor)
                  .fontColor(item.accentColor)
                  .borderRadius(8)
                  .margin({ right: 8 })
                  .onClick(() => { this.insertTemplateAfterSelection(item.key); })
              }, (item: WorkflowNodeTemplate) => item.key)
            }
          }
          .height(38)
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })
        if (this.isSelectedShotSummaryPair()) {
          this.ShotSummaryEditor()
        } else {
          if (this.selectedStepType() === 'gui_task') {
            this.GuiTaskEditor()
          }
          if (this.selectedStepType() === 'gui_action') {
            this.GuiActionEditor()
          }
          if (this.selectedStepType() === 'tool') {
            this.ToolEditor()
          }
          if (this.selectedStepType() === 'if') {
            this.ConditionEditor('if', '判断条件')
          }
          if (this.selectedStepType() === 'loop') {
            this.LoopEditor()
          }
        }
      }
    }
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder GuiTaskEditor() {
    Column() {
      if (this.isSelectedOpenAppStep()) {
        this.FieldLabel('应用名称')
        TextInput({ placeholder: '例如：支付宝 / 微信 / 哔哩哔哩', text: this.openAppNameDraft })
          .height(40)
          .fontSize(12)
          .backgroundColor('#F6F8FC')
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onChange((val: string) => { this.openAppNameDraft = val; })
      } else {
        this.FieldLabel('GUI 任务描述')
        TextArea({ placeholder: '例如：进入我的订单页并查看当前列表', text: this.guiTaskDraft })
          .width('100%')
          .height(96)
          .fontSize(12)
          .backgroundColor('#F6F8FC')
          .borderRadius(8)
          .padding(10)
          .onChange((val: string) => {
            this.guiTaskDraft = val;
          })
      }
    }
    .width('100%')
  }

  @Builder ShotSummaryEditor() {
    Column() {
      this.TextField('截图文件名', 'screen.jpg', this.actionFileNameDraft, 'file_name')
      Column() {
        this.FieldLabel('Summary 内容')
        TextArea({ placeholder: '请总结当前截图内容', text: this.summaryQuestionDraft })
          .width('100%')
          .height(110)
          .fontSize(12)
          .backgroundColor('#F6F8FC')
          .borderRadius(8)
          .padding(10)
          .onChange((val: string) => { this.summaryQuestionDraft = val; })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 10 })
      Row() {
        Text('阻塞执行')
          .fontSize(12)
          .fontColor('#4E5666')
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.summaryBlockingDraft })
          .selectedColor('#148F73')
          .width(44)
          .height(26)
          .onChange((value: boolean) => { this.summaryBlockingDraft = value; })
      }
      .width('100%')
      .margin({ top: 10 })
      this.FieldLabelTop('结构化输出 Schema')
      TextArea({ placeholder: '{"summary":{"type":"string","description":"..."}}', text: this.toolSchemaText })
        .width('100%')
        .height(96)
        .fontSize(11)
        .fontFamily('monospace')
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
        .padding(10)
        .onChange((val: string) => { this.toolSchemaText = val; })
    }
    .width('100%')
  }

  @Builder GuiActionEditor() {
    Column() {
      this.FieldLabel('动作类型')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(ACTION_OPTIONS, (option: SegmentOption) => {
          this.SegmentButton(option.label, option.value, this.selectedStepAction(), '#C76800', () => {
            this.updateSelectedAction(option.value);
          })
        }, (option: SegmentOption) => option.value)
      }
      .width('100%')
      if (this.selectedStepAction() === 'screenshot') {
        this.TextField('文件名', 'screen.jpg', this.selectedStringField('file_name'), 'file_name')
      }
      if (this.selectedStepAction() === 'click') {
        Row() {
          this.NumberField('X 坐标', '540', this.selectedNumberField('x'), 'x')
          Column().width(10)
          this.NumberField('Y 坐标', '1200', this.selectedNumberField('y'), 'y')
        }.width('100%').margin({ top: 10 })
      }
      if (this.selectedStepAction() === 'input') {
        this.TextField('输入文本', '需要输入的内容', this.selectedStringField('text'), 'text')
      }
      if (this.selectedStepAction() === 'swipe_with_coords') {
        Row() {
          this.NumberField('起点 X', '540', this.selectedNumberField('start_x'), 'start_x')
          Column().width(8)
          this.NumberField('起点 Y', '1700', this.selectedNumberField('start_y'), 'start_y')
        }.width('100%').margin({ top: 10 })
        Row() {
          this.NumberField('终点 X', '540', this.selectedNumberField('end_x'), 'end_x')
          Column().width(8)
          this.NumberField('终点 Y', '650', this.selectedNumberField('end_y'), 'end_y')
        }.width('100%').margin({ top: 10 })
      }
      if (this.selectedStepAction() === 'swipe') {
        this.FieldLabelTop('方向')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SWIPE_OPTIONS, (option: SegmentOption) => {
            this.SegmentButton(option.label, option.value, this.selectedStringField('direction'), '#C76800', () => {
              this.updateSelectedStringField('direction', option.value);
            })
          }, (option: SegmentOption) => option.value)
        }.width('100%')
      }
      if (this.selectedStepAction() === 'keyevent') {
        this.FieldLabelTop('按键')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(KEY_OPTIONS, (option: SegmentOption) => {
            this.SegmentButton(option.label, option.value, this.selectedStringField('key'), '#C76800', () => {
              this.updateSelectedStringField('key', option.value);
            })
          }, (option: SegmentOption) => option.value)
        }.width('100%')
        this.TextField('自定义 Key', 'BACK / HOME / ENTER / 2054', this.selectedStringField('key'), 'key')
      }
      if (this.selectedStepAction() === 'sleep') {
        Row() {
          this.NumberField('等待秒数', '1', this.selectedNumberField('seconds'), 'seconds')
        }.width('100%').margin({ top: 10 })
      }
      if (this.selectedStepAction() === 'app_start' || this.selectedStepAction() === 'app_stop') {
        this.TextField('包名', 'com.example.app', this.selectedStringField('package_name'), 'package_name')
      }
    }
    .width('100%')
  }

  @Builder ToolEditor() {
    Column() {
      this.TextField('工具名', 'vlm_qa', this.selectedStringField('tool_name'), 'tool_name')
      this.FieldLabelTop('模式')
      Flex({ wrap: FlexWrap.Wrap }) {
        this.SegmentButton('Summary', 'summary', this.selectedToolInput('mode'), '#148F73', () => {
          this.updateSelectedToolInput('mode', 'summary');
        })
        this.SegmentButton('问答', 'answer', this.selectedToolInput('mode'), '#148F73', () => {
          this.updateSelectedToolInput('mode', 'answer');
        })
      }.width('100%')
      Column() {
        this.FieldLabel('图片变量')
        TextInput({ placeholder: '${steps.3.output.image_b64}', text: this.selectedToolInput('image') })
          .height(38)
          .fontSize(12)
          .fontFamily('monospace')
          .backgroundColor('#F6F8FC')
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onChange((val: string) => { this.updateSelectedToolInput('image', val); })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 10 })
      this.FieldLabelTop('Summary 提示词')
      TextArea({ placeholder: '请总结当前截图内容', text: this.summaryQuestionDraft })
        .width('100%')
        .height(96)
        .fontSize(12)
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
        .padding(10)
        .onChange((val: string) => { this.summaryQuestionDraft = val; })
      Row() {
        Text('阻塞执行')
          .fontSize(12)
          .fontColor('#4E5666')
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.summaryBlockingDraft })
          .selectedColor('#148F73')
          .width(44)
          .height(26)
          .onChange((value: boolean) => { this.summaryBlockingDraft = value; })
      }
      .width('100%')
      .margin({ top: 10 })
      this.FieldLabelTop('结构化输出 Schema')
      TextArea({ placeholder: '{"summary":{"type":"string","description":"..."}}', text: this.toolSchemaText })
        .width('100%')
        .height(96)
        .fontSize(11)
        .fontFamily('monospace')
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
        .padding(10)
        .onChange((val: string) => { this.toolSchemaText = val; })
    }
    .width('100%')
  }

  @Builder ConditionEditor(kind: string, label: string) {
    Column() {
      this.FieldLabel(label)
      TextInput({ placeholder: '${steps.2.output.response}', text: kind === 'break' ? this.breakLeftDraft : this.conditionLeftDraft })
        .height(38)
        .fontSize(12)
        .fontFamily('monospace')
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
        .padding({ left: 10, right: 10 })
        .onChange((val: string) => {
          if (kind === 'break') {
            this.breakLeftDraft = val;
          } else {
            this.conditionLeftDraft = val;
          }
        })
      this.FieldLabelTop('比较方式')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(CONDITION_OPTIONS, (option: SegmentOption) => {
          this.SegmentButton(option.label, option.value, kind === 'break' ? this.breakOperatorDraft : this.conditionOperatorDraft, '#7C4DFF', () => {
            if (kind === 'break') {
              this.breakOperatorDraft = option.value;
            } else {
              this.conditionOperatorDraft = option.value;
            }
          })
        }, (option: SegmentOption) => option.value)
      }.width('100%')
      this.FieldLabelTop('右侧值')
      TextInput({ placeholder: 'true / 3 / 关键词', text: kind === 'break' ? this.breakRightDraft : this.conditionRightDraft })
        .height(38)
        .fontSize(12)
        .fontFamily('monospace')
        .backgroundColor('#F6F8FC')
        .borderRadius(8)
        .padding({ left: 10, right: 10 })
        .onChange((val: string) => {
          if (kind === 'break') {
            this.breakRightDraft = val;
          } else {
            this.conditionRightDraft = val;
          }
        })
    }
    .width('100%')
  }

  @Builder LoopEditor() {
    Column() {
      if (this.selectedLoopUsesBreakCondition()) {
        Column() {
          this.FieldLabel('最多次数')
          TextInput({ placeholder: '10', text: this.loopMaxTimesDraft })
            .height(38)
            .fontSize(12)
            .backgroundColor('#F6F8FC')
            .borderRadius(8)
            .padding({ left: 10, right: 10 })
            .onChange((val: string) => { this.loopMaxTimesDraft = val; })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 10 })
        this.ConditionEditor('break', '退出条件')
      } else {
        Column() {
          this.FieldLabel('固定次数')
          TextInput({ placeholder: '3', text: this.loopTimesDraft })
            .height(38)
            .fontSize(12)
            .backgroundColor('#F6F8FC')
            .borderRadius(8)
            .padding({ left: 10, right: 10 })
            .onChange((val: string) => { this.loopTimesDraft = val; })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 10 })
      }
    }
    .width('100%')
  }

  @Builder GraphEditorPanel() {
    Column() {
      this.WorkflowMetaPanel()
      this.NodePalette()
      this.FlowCanvas()
    }
    .width('100%')
  }

  @Builder JsonEditorPanel() {
    Column() {
      TextArea({ placeholder: '请输入 workflow JSON', text: this.editorText })
        .width('100%')
        .height(360)
        .fontSize(12)
        .fontFamily('monospace')
        .backgroundColor('#F6F8FC')
        .borderRadius(12)
        .padding(12)
        .onChange((val: string) => { this.editorText = val; })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .border({ width: 1, color: '#E3E8F1' })
  }

  @Builder EditorPanel() {
    if (this.editorOpen) {
      Column() {
        Row() {
          Text(this.editingTaskId.length > 0 ? '编辑 Workflow' : '新建 Workflow')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .layoutWeight(1)
          Button('关闭')
            .height(32)
            .fontSize(12)
            .backgroundColor('#F2F5FA')
            .fontColor('#4E5666')
            .borderRadius(8)
            .onClick(() => { this.editorOpen = false; })
        }
        .width('100%')
        Row() {
          Button('图编辑')
            .height(34)
            .layoutWeight(1)
            .fontSize(12)
            .backgroundColor(this.editorMode === 'graph' ? '#276EF1' : '#EEF4FF')
            .fontColor(this.editorMode === 'graph' ? Color.White : '#276EF1')
            .borderRadius(8)
            .onClick(() => { this.switchEditorMode('graph'); })
          Button('JSON')
            .height(34)
            .layoutWeight(1)
            .fontSize(12)
            .backgroundColor(this.editorMode === 'json' ? '#276EF1' : '#EEF4FF')
            .fontColor(this.editorMode === 'json' ? Color.White : '#276EF1')
            .borderRadius(8)
            .margin({ left: 10 })
            .onClick(() => { this.switchEditorMode('json'); })
        }
        .width('100%')
        .margin({ top: 14, bottom: 14 })
        if (this.editorMode === 'graph') {
          this.GraphEditorPanel()
        } else {
          this.JsonEditorPanel()
        }
        Row() {
          Button('保存 Workflow')
            .height(42)
            .layoutWeight(1)
            .fontSize(13)
            .backgroundColor('#276EF1')
            .borderRadius(10)
            .onClick(() => { this.saveEditor(); })
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('92%')
      .padding(16)
      .backgroundColor('#F4F7FB')
      .borderRadius(18)
      .border({ width: 1, color: '#DCE3EF' })
      .margin({ bottom: 18 })
    }
  }

  @Builder TaskExecutionHeaderPanel() {
    Column() {
      Row() {
        Column() {
          Text('任务执行')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .maxLines(1)
          Text('已开启 ' + this.enabledTaskCount() + ' / 全部 ' + this.tasks.length)
            .fontSize(12)
            .fontColor('#6F7584')
            .margin({ top: 7 })
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('配置任务')
          .width(92)
          .height(36)
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor('#276EF1')
          .borderRadius(10)
          .enabled(!this.isTaskExecutionBusy())
          .onClick(() => { this.openConfigView(); })
      }
      .width('100%')
    }
    .width('86%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .border({ width: 1, color: '#E3E8F1' })
    .margin({ top: 24, bottom: 18 })
  }

  @Builder SimpleTaskRow(task: WorkflowTask, scene: WorkflowSceneConfig) {
    Row() {
      Text(task.icon)
        .fontSize(12)
        .fontColor(task.enabled ? scene.color : '#8E95A3')
        .fontWeight(FontWeight.Bold)
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .backgroundColor(task.enabled ? '#F1F5FF' : '#F4F5F8')
        .borderRadius(12)
      Column() {
        Text(task.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#11182F')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.runningTaskId === task.id ? '执行中' : task.enabled ? '已开启' : '已关闭')
          .fontSize(11)
          .fontColor(this.runningTaskId === task.id ? '#276EF1' : task.enabled ? '#148F73' : '#8E95A3')
          .margin({ top: 5 })
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12, right: 12 })
      Toggle({ type: ToggleType.Switch, isOn: task.enabled })
        .selectedColor(scene.color)
        .width(44)
        .height(26)
        .enabled(!this.isTaskExecutionBusy())
        .onChange((value: boolean) => { this.setTaskEnabled(task, value); })
    }
    .width('100%')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(Color.White)
    .borderRadius(12)
    .border({ width: 1, color: this.runningTaskId === task.id ? scene.color : '#E8EDF5' })
    .margin({ top: 10 })
  }

  @Builder TaskExecutionSceneSection(scene: WorkflowSceneConfig) {
    if (this.tasksForScene(scene.sceneId).length > 0) {
      Column() {
        Row() {
          Text(scene.label)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .layoutWeight(1)
            .maxLines(1)
          Text(this.enabledTaskCountForScene(scene.sceneId) + '/' + this.tasksForScene(scene.sceneId).length + ' 开启')
            .fontSize(11)
            .fontColor(scene.color)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('#F8F9FE')
            .borderRadius(8)
            .maxLines(1)
        }
        .width('100%')
        ForEach(this.tasksForScene(scene.sceneId), (task: WorkflowTask) => {
          this.SimpleTaskRow(task, scene)
        }, (task: WorkflowTask) => this.taskRowRenderKey(task))
      }
      .width('86%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 18 })
    }
  }

  @Builder TaskExecutionList() {
    if (this.tasks.length === 0) {
      Column() {
        Text('暂无任务')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
        Button('配置任务')
          .height(36)
          .fontSize(12)
          .backgroundColor('#276EF1')
          .borderRadius(10)
          .margin({ top: 14 })
          .onClick(() => { this.openConfigView(); })
      }
      .width('86%')
      .padding(22)
      .backgroundColor(Color.White)
      .borderRadius(14)
      .margin({ bottom: 18 })
    } else {
      ForEach(workflowSceneConfigs(), (scene: WorkflowSceneConfig) => {
        this.TaskExecutionSceneSection(scene)
      }, (scene: WorkflowSceneConfig) => scene.tabId)
    }
  }

  @Builder BatchRunPanel() {
    Column() {
      if (this.batchRunStatusText.length > 0) {
        Text(this.batchRunStatusText)
          .fontSize(12)
          .fontColor('#4E5666')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ bottom: 10 })
      }
      Button(this.batchRunButtonText())
        .width('100%')
        .height(46)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .backgroundColor(this.enabledTaskCount() > 0 && !this.isTaskExecutionBusy() ? '#276EF1' : '#A9B7E9')
        .borderRadius(12)
        .enabled(this.enabledTaskCount() > 0 && !this.isTaskExecutionBusy())
        .onClick(() => { this.runEnabledTasks(); })
    }
    .width('86%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .border({ width: 1, color: '#E3E8F1' })
    .margin({ top: 2, bottom: 18 })
  }

  @Builder ConfigHeaderPanel() {
    Row() {
      Button('返回任务')
        .width(88)
        .height(34)
        .fontSize(12)
        .fontColor('#4E5666')
        .backgroundColor('#F2F5FA')
        .borderRadius(10)
        .onClick(() => { this.closeConfigView(); })
      Blank()
      Button('刷新')
        .width(64)
        .height(34)
        .fontSize(12)
        .fontColor(Color.White)
        .backgroundColor('#4E5666')
        .borderRadius(10)
        .onClick(() => { this.reloadTasks(); })
    }
    .width('86%')
    .margin({ top: 18 })
  }

  @Builder TaskContextPanel(task: WorkflowTask) {
    Column() {
      Row() {
        Text('上下文变量')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .layoutWeight(1)
          .maxLines(1)
        Text('contact_name')
          .fontSize(11)
          .fontColor('#276EF1')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#EAF2FF')
          .borderRadius(8)
          .maxLines(1)
      }
      .width('100%')
      TextInput({ placeholder: '请输入联系人名称', text: this.taskContactNameDraftForTask(task) })
        .width('100%')
        .height(40)
        .fontSize(13)
        .fontColor('#222B3D')
        .backgroundColor(Color.White)
        .borderRadius(10)
        .border({ width: 1, color: '#E3E8F1' })
        .padding({ left: 10, right: 10 })
        .margin({ top: 10 })
        .enabled(!this.isTaskExecutionBusy())
        .onChange((val: string) => { this.syncTaskContextDraft(task, val); })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F8FAFD')
    .borderRadius(12)
    .border({ width: 1, color: '#E3E8F1' })
    .margin({ top: 14 })
  }

  @Builder TaskCard(task: WorkflowTask) {
    Column() {
      Row() {
        Text(task.icon)
          .fontSize(13)
          .fontColor(task.iconColor)
          .fontWeight(FontWeight.Bold)
          .width(54)
          .height(54)
          .textAlign(TextAlign.Center)
          .backgroundColor(task.enabled ? '#F1F5FF' : '#F4F5F8')
          .borderRadius(14)
        Column() {
          Row() {
            Text(task.title)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#11182F')
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row().width(7).height(7).backgroundColor(task.enabled ? '#148F73' : '#A8AFBC').borderRadius(4).margin({ left: 8, right: 5 })
            Text(task.enabled ? task.lastStatus : '已暂停')
              .fontSize(11)
              .fontColor(task.enabled ? '#66707E' : '#8E95A3')
              .maxLines(1)
          }
          .width('100%')
          Text('最近运行：' + task.lastRun)
            .fontSize(12)
            .fontColor('#7B8290')
            .margin({ top: 7 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('来源模块：' + task.source)
            .fontSize(12)
            .fontColor('#7B8290')
            .margin({ top: 4 })
            .maxLines(1)
          Text(task.lastMessage)
            .fontSize(11)
            .fontColor('#9AA2B1')
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 14, right: 8 })
        Toggle({ type: ToggleType.Switch, isOn: task.enabled })
          .selectedColor('#276EF1')
          .width(44)
          .height(26)
          .enabled(!this.isTaskExecutionBusy())
          .onChange((value: boolean) => { this.setTaskEnabled(task, value); })
      }
      .width('100%')
      if (this.taskHasContext(task)) {
        this.TaskContextPanel(task)
      }
      Scroll() {
        Row() {
          Button(this.runningTaskId === task.id ? '执行中' : '运行')
            .width(82)
            .height(36)
            .fontSize(12)
            .backgroundColor(this.isTaskExecutionBusy() && this.runningTaskId !== task.id ? '#A9B7E9' :
              this.runningTaskId === task.id ? '#A9B7E9' : '#276EF1')
            .borderRadius(10)
            .margin({ right: 8 })
            .enabled(!this.isTaskExecutionBusy())
            .onClick(() => { this.runTask(task); })
          Button('图编辑')
            .width(86)
            .height(36)
            .fontSize(12)
            .backgroundColor('#EAF8F3')
            .fontColor('#148F73')
            .borderRadius(10)
            .margin({ right: 8 })
            .onClick(() => { this.openEditEditor(task.id, 'graph'); })
          Button('JSON')
            .width(82)
            .height(36)
            .fontSize(12)
            .backgroundColor('#EEF4FF')
            .fontColor('#276EF1')
            .borderRadius(10)
            .margin({ right: 8 })
            .onClick(() => { this.openEditEditor(task.id, 'json'); })
          Button('复制')
            .width(82)
            .height(36)
            .fontSize(12)
            .backgroundColor('#EEF4FF')
            .fontColor('#276EF1')
            .borderRadius(10)
            .margin({ right: 8 })
            .onClick(() => { this.copyWorkflowTask(task); })
          Button('删除')
            .width(82)
            .height(36)
            .fontSize(12)
            .backgroundColor('#FFF0ED')
            .fontColor('#B42318')
            .borderRadius(10)
            .onClick(() => { this.deleteWorkflowTask(task); })
        }
      }
      .width('100%')
      .height(44)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .margin({ top: 14 })
    }
    .width('86%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .shadow({ radius: 10, color: '#0D000000', offsetX: 0, offsetY: 5 })
    .margin({ bottom: 16 })
  }

  @Builder TaskSceneTab(scene: WorkflowSceneConfig) {
    Text(scene.label)
      .fontSize(13)
      .fontWeight(this.taskScene === scene.sceneId ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.taskScene === scene.sceneId ? Color.White : '#6D7481')
      .height(38)
      .padding({ left: 16, right: 16 })
      .textAlign(TextAlign.Center)
      .backgroundColor(this.taskScene === scene.sceneId ? scene.color : Color.White)
      .borderRadius(10)
      .margin({ left: scene.sceneId === 0 ? 0 : 10 })
      .onClick(() => {
        this.taskScene = scene.sceneId;
      })
  }

  @Builder CreatePanel() {
    Column() {
      Row() {
        Column() {
          Row() {
            Text('新建任务')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#11182F')
            Text('图形编排')
              .fontSize(11)
              .fontColor('#148F73')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('#EAF8F3')
              .borderRadius(8)
              .margin({ left: 10 })
          }
          Text('选择场景后用节点连接定义 workflow')
            .fontSize(12)
            .fontColor('#6F7584')
            .margin({ top: 7 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Column() {
          Button('图新建')
            .width(76)
            .height(34)
            .fontSize(12)
            .backgroundColor('#276EF1')
            .borderRadius(10)
            .onClick(() => { this.openCreateEditor('graph'); })
          Button('JSON')
            .width(76)
            .height(30)
            .fontSize(11)
            .backgroundColor('#EEF4FF')
            .fontColor('#276EF1')
            .borderRadius(9)
            .margin({ top: 8 })
            .onClick(() => { this.openCreateEditor('json'); })
        }
      }
      .width('100%')
      Scroll() {
        Row() {
          ForEach(workflowSceneConfigs(), (scene: WorkflowSceneConfig) => {
            Text(scene.label)
              .fontSize(11)
              .fontColor(scene.color)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor('#F8F9FE')
              .borderRadius(8)
              .margin({ left: scene.sceneId === 0 ? 0 : 8 })
          }, (scene: WorkflowSceneConfig) => scene.tabId)
        }
      }
      .width('100%')
      .height(28)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .margin({ top: 14 })
    }
    .width('86%')
    .padding(20)
    .backgroundColor('#F8FAFD')
    .borderRadius(14)
    .border({ width: 1, color: '#E3E8F1' })
    .margin({ top: 24 })
  }

  @Builder TaskSceneList() {
    if (this.sceneTasks().length === 0) {
      Column() {
        Text('当前场景暂无任务')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
        Text('点击上方新建任务，使用图编辑或 JSON 创建 workflow。')
          .fontSize(12)
          .fontColor('#7B8290')
          .margin({ top: 8 })
      }
      .width('86%')
      .padding(22)
      .backgroundColor(Color.White)
      .borderRadius(14)
      .margin({ bottom: 18 })
    } else {
      ForEach(this.sceneTasks(), (task: WorkflowTask) => {
        this.TaskCard(task)
        if (this.editorOpen && this.editingTaskId === task.id) {
          this.EditorPanel()
        }
      }, (task: WorkflowTask) => this.taskCardRenderKey(task))
    }
  }

  @Builder FileManagerPanel() {
    Column() {
      Row() {
        Column() {
          Text('Workflow 文件管理')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .width('100%')
          Text(this.fileStatsText)
            .fontSize(12)
            .fontColor('#6F7584')
            .margin({ top: 7 })
            .width('100%')
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('刷新')
          .width(64)
          .height(34)
          .fontSize(12)
          .backgroundColor('#4E5666')
          .borderRadius(10)
          .margin({ left: 10 })
          .onClick(() => { this.reloadTasks(); })
      }
      .width('100%')

      this.FileCategoryRow('config', '配置', 'Workflow JSON', '#276EF1', '#EEF4FF', this.configManagedFiles)
      this.FileCategoryRow('daily', '日志', 'Daily Log', '#148F73', '#EAF8F3', this.dailyLogManagedFiles)
      this.FileCategoryRow('run', '运行文件', 'Run outputs', '#C76800', '#FFF3E2', this.runManagedFiles)
    }
    .width('86%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(14)
    .margin({ bottom: 18 })
  }

  @Builder FileCategoryRow(category: string, title: string, subtitle: string, color: string, bgColor: string,
    files: WorkflowManagedFile[]) {
    Row() {
      Column() {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#11182F')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(subtitle + ' · ' + files.length + ' 个 · ' + WorkflowStorage.formatSize(this.totalFileSize(files)))
          .fontSize(12)
          .fontColor('#6F7584')
          .margin({ top: 6 })
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Button('查看')
        .width(74)
        .height(34)
        .fontSize(12)
        .fontColor(Color.White)
        .backgroundColor(color)
        .borderRadius(10)
        .margin({ left: 10 })
        .onClick(() => { this.openFileViewer(category); })
      Button('清理')
        .width(66)
        .height(34)
        .fontSize(12)
        .fontColor('#6F7584')
        .backgroundColor('#F3F5FA')
        .borderRadius(10)
        .margin({ left: 8 })
        .onClick(() => { this.deleteFileCategory(category); })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(bgColor)
    .borderRadius(14)
    .margin({ top: 12 })
  }

  @Builder FileViewerPanel() {
    if (this.fileViewerOpen) {
      Column() {
        Row() {
          Text(this.fileViewerTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#11182F')
            .layoutWeight(1)
          if (this.fileViewerContainsAiGeneratedContent()) {
            AiGeneratedBadge({ compact: true })
              .margin({ right: 8 })
          }
          Button('关闭')
            .height(30)
            .fontSize(11)
            .backgroundColor('#F2F5FA')
            .fontColor('#4E5666')
            .borderRadius(8)
            .onClick(() => { this.fileViewerOpen = false; })
        }
        .width('100%')
        if (this.fileViewerFiles.length > 0) {
          Scroll() {
            Row() {
              ForEach(this.fileViewerFiles, (file: WorkflowManagedFile) => {
                Button(file.name + ' (' + WorkflowStorage.formatSize(file.size) + ')')
                  .height(32)
                  .fontSize(11)
                  .backgroundColor(this.fileViewerSelectedName === file.name ? '#276EF1' : '#F3F5FA')
                  .fontColor(this.fileViewerSelectedName === file.name ? Color.White : '#4E5666')
                  .borderRadius(9)
                  .margin({ right: 8 })
                  .onClick(() => { this.openManagedFile(file); })
              }, (file: WorkflowManagedFile) => file.path)
            }
          }
          .width('100%')
          .height(40)
          .scrollable(ScrollDirection.Horizontal)
          .margin({ top: 12 })
          Text('当前文件：' + this.fileViewerSelectedName)
            .fontSize(12)
            .fontColor('#6F7584')
            .margin({ top: 10 })
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row() {
            Button('预览')
              .width(54)
              .height(30)
              .fontSize(12)
              .fontColor(this.fileViewerPreviewMode ? Color.White : '#5968FF')
              .backgroundColor(this.fileViewerPreviewMode ? '#5968FF' : '#F3F5FA')
              .borderRadius(10)
              .onClick(() => { this.fileViewerPreviewMode = true; })
            Button('原文')
              .width(54)
              .height(30)
              .fontSize(12)
              .fontColor(!this.fileViewerPreviewMode ? Color.White : '#5968FF')
              .backgroundColor(!this.fileViewerPreviewMode ? '#5968FF' : '#F3F5FA')
              .borderRadius(10)
              .margin({ left: 8 })
              .onClick(() => { this.fileViewerPreviewMode = false; })
          }
          .width('100%')
          .margin({ top: 8 })
          Scroll() {
            if (this.fileViewerPreviewMode) {
              MarkdownView({ text: this.fileViewerText, variant: 'file_preview' })
            } else {
              Text(this.fileViewerText)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor('#2F3645')
                .width('100%')
            }
          }
          .width('100%')
          .height(280)
          .padding(12)
          .backgroundColor('#F6F8FC')
          .borderRadius(12)
          .margin({ top: 8 })
        } else {
          Text(this.fileViewerText)
            .fontSize(13)
            .fontColor('#7B8290')
            .margin({ top: 14 })
            .width('100%')
        }
      }
      .width('86%')
      .padding(18)
      .backgroundColor(Color.White)
      .borderRadius(14)
      .margin({ bottom: 18 })
    }
  }

  build() {
    Scroll() {
      Column() {
        if (this.configViewOpen) {
          AppHeader({
            title: '配置任务',
            subtitle: 'Workflow 编排与文件管理',
            icon: $r('app.media.header_task')
          })
          this.ConfigHeaderPanel()
          this.CreatePanel()
          if (this.editorOpen && this.editingTaskId.length === 0) {
            this.EditorPanel()
          }

          Scroll() {
            Row() {
              ForEach(workflowSceneConfigs(), (scene: WorkflowSceneConfig) => {
                this.TaskSceneTab(scene)
              }, (scene: WorkflowSceneConfig) => scene.tabId)
            }
            .padding({ left: 24, right: 24 })
          }
          .width('100%')
          .height(42)
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .margin({ top: 20, bottom: 16 })

          this.TaskSceneList()
          this.FileManagerPanel()
        } else {
          AppHeader({ title: '自定义任务', icon: $r('app.media.header_task') })
          this.TaskExecutionHeaderPanel()
          this.TaskExecutionList()
          this.BatchRunPanel()
        }
        Blank().height(110)
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F7FB')
  }
}
