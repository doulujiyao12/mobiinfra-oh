// Verify that packaged defaults and the fallback builders use the same prompt.
// node scripts/check_wechat_summary_prompts.cjs <typescript-module-path>
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const promptFile = path.join(root, 'entry/src/main/ets/utils/WechatSummaryPrompt.ets');
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(promptFile, 'utf8'), {
  compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS}
}).outputText, {exports: exportsObject});
const prompt = exportsObject.WECHAT_SUMMARY_PROMPT;
assert.equal(typeof prompt, 'string');
const todayPrompt = exportsObject.WECHAT_TODAY_CHAT_CHECK_PROMPT;
assert.equal(typeof todayPrompt, 'string');
const todaySummaryPrompt = exportsObject.WECHAT_TODAY_SUMMARY_PROMPT;
const todayDescription = exportsObject.WECHAT_TODAY_CHAT_DESCRIPTION;
assert.equal(todaySummaryPrompt, '【聊天内容记录】\n' + prompt + '\n\n' + todayPrompt);
assert.ok(!/[\r\n]/.test(todayPrompt), 'Today-check instructions must be one paragraph');
assert.equal(todayDescription, '判断当前聊天内容是否为今天的聊天内容。');
assert.ok(todayPrompt.includes('微信自动显示的居中时间分隔标签'));
assert.ok(todayPrompt.includes('聊天气泡正文') && todayPrompt.includes('任务执行时间参考、规则文字和示例'));
assert.ok(!prompt.includes('contains_today_chat'), 'Ordinary transcript tasks must not acquire today-only rules');
assert.ok(todayPrompt.includes('这一条优先级最高：即使同一页也出现“上午/下午＋时间”，仍返回 false。'));
function summaryQuestions(value) {
  if (Array.isArray(value)) return value.flatMap(summaryQuestions);
  if (!value || typeof value !== 'object') return [];
  const own = value.tool_name === 'vlm_qa' && value.inputs?.mode === 'summary' ? [value.inputs.question] : [];
  return own.concat(Object.values(value).flatMap(summaryQuestions));
}
for (const name of ['default_weixin_chat.json', 'default_weixin_today_chat.json']) {
  const workflow = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/workflows/configs', name), 'utf8'));
  assert.deepEqual(summaryQuestions(workflow), [name === 'default_weixin_today_chat.json' ? todaySummaryPrompt : prompt],
    name + ' differs from its shared prompt');
  if (name === 'default_weixin_today_chat.json') {
    const descriptions = [];
    function todayDescriptions(value) {
      if (Array.isArray(value)) { value.forEach(todayDescriptions); return; }
      if (!value || typeof value !== 'object') return;
      if (value.tool_name === 'vlm_qa' && value.inputs?.mode === 'summary') {
        const field = value.inputs.json_schema?.contains_today_chat;
        if (field) { assert.equal(field.type, 'boolean'); descriptions.push(field.description); }
      }
      Object.values(value).forEach(todayDescriptions);
    }
    todayDescriptions(workflow);
    assert.deepEqual(descriptions, [todayDescription], 'today schema must contain only the short field description');
  }
}
const storagePath = path.join(root, 'entry/src/main/ets/utils/WorkflowStorage.ets');
const source = ts.createSourceFile(storagePath, fs.readFileSync(storagePath, 'utf8'), ts.ScriptTarget.Latest, true);
const references = [];
function visit(node, method = '') {
  if (ts.isMethodDeclaration(node) && node.name) method = node.name.getText(source);
  if (method === 'weixinTodaySummaryToolStep' && ts.isPropertyAssignment(node) && node.name.getText(source) === 'question') {
    assert.equal(node.initializer.getText(source), 'WECHAT_TODAY_SUMMARY_PROMPT'); references.push(method);
  }
  if (method === 'weixinTodayJsonSchema' && ts.isVariableDeclaration(node) && node.name.getText(source) === 'containsTodayChat') {
    const description = node.initializer.properties.find(item => item.name?.getText(source) === 'description');
    assert.equal(description.initializer.getText(source), 'WECHAT_TODAY_CHAT_DESCRIPTION');
  }
  if (method === 'defaultWeixinWorkflow' && ts.isCallExpression(node) &&
      node.expression.getText(source) === 'WorkflowStorage.summaryToolStep') {
    assert.equal(node.arguments[2].getText(source), 'WECHAT_SUMMARY_PROMPT'); references.push(method);
  }
  ts.forEachChild(node, child => visit(child, method));
}
visit(source);
assert.deepEqual(references.sort(), ['defaultWeixinWorkflow', 'weixinTodaySummaryToolStep']);
assert.ok(source.statements.some(node => ts.isImportDeclaration(node) && node.moduleSpecifier.text === './WechatSummaryPrompt' &&
  node.importClause?.namedBindings?.elements?.some(item => item.name.text === 'WECHAT_SUMMARY_PROMPT')));
console.log('PASS: ordinary summaries stay unchanged; compact today rules follow the shared transcript; packaged defaults, fallback builders and short schema descriptions agree.');

// Run the actual storage/title/copy methods against in-memory task files.
// This also checks that existing configs are corrected on reload, without
// replacing the user's contact, summary prompt, run state or custom title.
const storageClass = source.statements.find(node => ts.isClassDeclaration(node) && node.name?.text === 'WorkflowStorage');
const titleMethods = ['titleForWorkflow', 'sourceForWorkflow', 'copyDescriptionForWorkflow', 'copyTitleBase', 'stripCopySuffix',
  'uniqueCopyTitle', 'uniqueTaskId', 'workflowJsonWithDescription', 'duplicateTask', 'createTaskFromJson',
  'taskWithLatestValidConfig', 'updateTaskContextValue'];
const selectedMethods = storageClass.members.filter(node => ts.isMethodDeclaration(node) && titleMethods.includes(node.name.getText(source)));
assert.equal(selectedMethods.length, titleMethods.length);
const titleExports = {};
vm.runInNewContext(ts.transpileModule('class WorkflowStorage {\n' + selectedMethods.map(node => node.getText(source)).join('\n') +
  '\n}\nexports.WorkflowStorage = WorkflowStorage;', {compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS}}).outputText,
  {exports: titleExports, stringifyJsonCompat: JSON.stringify});
const titles = titleExports.WorkflowStorage;
const raw = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/workflows/configs/default_weixin_today_chat.json'), 'utf8'));
raw.metadata.description += ' 复制'; raw.context.contact_name = 'Agent 小分队';
let savedTasks = [], savedConfig = JSON.stringify(raw);
Object.assign(titles, {
  validateWorkflowJson: value => JSON.parse(value), iconForScene: () => 'Chat', colorForScene: () => '#123456',
  isCodeDefinedDefaultTaskId: () => false, configPath: (_dir, name) => name, readText: () => savedConfig,
  readTaskWorkflowJson: () => savedConfig, loadTasks: () => savedTasks, fileExists: () => false,
  prepareTaskForUpsert: (_dir, task) => task, replaceTaskInList: (tasks, value) => tasks.map(task => task.id === value.id ? value : task),
  writeConfig: (_dir, task) => { savedConfig = task.workflowJson; }, writeTaskIndex: (_dir, tasks) => { savedTasks = tasks; }
});
const task = titles.createTaskFromJson('/app', 3, savedConfig, 'test-agent');
assert.equal(task.title, '收集Agent 小分队的今天聊天记录 复制');
assert.equal(JSON.parse(task.workflowJson).metadata.description, raw.metadata.description);
const stale = {...task, title: raw.metadata.description};
assert.equal(titles.taskWithLatestValidConfig('/app', stale).title, task.title);
task.lastStatus = '成功'; task.enabled = false; savedTasks = [task];
const updated = titles.updateTaskContextValue('/app', task.id, 'contact_name', '新的群聊')[0];
assert.equal(updated.title, '收集新的群聊的今天聊天记录 复制');
assert.equal(updated.lastStatus, '成功'); assert.equal(updated.enabled, false);
assert.equal(JSON.parse(savedConfig).metadata.description, raw.metadata.description);
assert.deepEqual(summaryQuestions(JSON.parse(savedConfig)), [todaySummaryPrompt]);
const copied = titles.duplicateTask('/app', updated.id);
assert.equal(copied.title, '收集新的群聊的今天聊天记录 复制 2');
assert.equal(JSON.parse(copied.workflowJson).metadata.description, '收集指定微信用户的今天聊天记录 复制 2');
const copiedWorkflow = JSON.parse(copied.workflowJson); copiedWorkflow.context.contact_name = '复制后的联系人';
assert.equal(titles.titleForWorkflow(copiedWorkflow), '收集复制后的联系人的今天聊天记录 复制 2');
raw.metadata.description = '我的自定义群聊任务';
assert.equal(titles.titleForWorkflow(raw), '我的自定义群聊任务');
raw.metadata.description = '收集${context.contact_name}的聊天记录'; raw.context.contact_name = '$& $1 群';
assert.equal(titles.titleForWorkflow(raw), '收集$& $1 群的聊天记录');
raw.context.contact_name = '  ';
assert.equal(titles.titleForWorkflow(raw), raw.metadata.description);
console.log('PASS: existing WeChat titles reload with contacts, contact edits preserve configuration, copies retain templates and custom names stay unchanged.');

// Deferred summaries must keep the collection clock, including the log day,
// even when model responses arrive after midnight or a run started earlier.
const dateModules = new Map();
function loadDateModule(name) {
  if(dateModules.has(name))return dateModules.get(name);
  const exported={};dateModules.set(name,exported);
  const text=fs.readFileSync(path.join(root,'entry/src/main/ets/utils',name+'.ets'),'utf8');
  vm.runInNewContext(ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,
    {exports:exported,Date,require:id=>loadDateModule(path.basename(id))});return exported;
}
const {WorkflowDateContext}=loadDateModule('WorkflowDateContext');
const runnerSource=ts.createSourceFile('WorkflowRunner.ets',fs.readFileSync(path.join(root,'entry/src/main/ets/utils/WorkflowRunner.ets'),'utf8'),ts.ScriptTarget.Latest,true);
const runnerClass=runnerSource.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='WorkflowRunner');
const methodNames=['createSummaryJob','dailySummaryLogText','appendDailySummaryLog'];
const methods=runnerClass.members.filter(n=>ts.isMethodDeclaration(n)&&methodNames.includes(n.name.getText(runnerSource)));
assert.equal(methods.length,methodNames.length);
const runnerExports={},savedLogs=new Map();
vm.runInNewContext(ts.transpileModule('class Runner {\n'+methods.map(n=>n.getText(runnerSource)).join('\n')+'\n}\nexports.Runner=Runner;',
  {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{exports:runnerExports,ArkJSON:JSON,
  WorkflowStorage:{dailyLogDir:()=>'/app/daily-log',ensureDirectory(){},countFiles:()=>0,writeText:(p,t)=>savedLogs.set(p,t)}});
const runner=new runnerExports.Runner(),capture=new WorkflowDateContext(new Date(2026,10,2,23,59));
Object.assign(runner,{filesDir:'/app',runDate:'2026-11-01',runDir:'/app/runs/example',workflow:null,runningTask:null,
  dateContext:new WorkflowDateContext(new Date(2026,10,3,0,10)),startSummaryJob:async()=>({ok:true}),
  summaryLogText:t=>t,buildDailyLogFileName:()=> 'chat.md',log(){}});
const job=runner.createSummaryJob('1','question','fixture-image',capture);
assert.equal(job.date_context,capture);
const text=runner.dailySummaryLogText('位置：左侧｜发送人：同事甲｜聊天对象：我｜时间原文：今天23:50｜原文：明天交材料',undefined,job.date_context);
assert.ok(text.includes('时间：2026-11-02 23:50'));
const logPath=runner.appendDailySummaryLog(text,job.date_context);
assert.equal(logPath,'/app/daily-log/2026-11-02/chat.md');assert.ok(savedLogs.get(logPath).includes('时间：2026-11-02 23:50'));
console.log('PASS: actual deferred-summary methods freeze the collection date and log partition across midnight.');
