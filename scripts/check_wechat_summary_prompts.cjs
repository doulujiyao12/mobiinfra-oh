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
assert.equal(todaySummaryPrompt.split('会话类型：')[1].split('\n\n【今日聊天判断】')[0],
  prompt.split('会话类型：')[1].split('\n\n【输出前检查】')[0]);
assert.equal(todayDescription, '判断当前聊天内容是否为今天的聊天内容。');
const outputExample = todaySummaryPrompt.split('\n').find(line => line.startsWith('{"summary":'));
assert.deepEqual(JSON.parse(outputExample), {summary: '聊天记录文本', contains_today_chat: true});
assert.ok(todaySummaryPrompt.includes('contains_today_chat位于summary字符串外。'));
assert.ok(todaySummaryPrompt.includes('换行写成\\n，内容中的英文双引号写成\\"'));
assert.ok(todayPrompt.includes('微信自动显示的居中时间分隔标签'));
assert.ok(todayPrompt.includes('聊天气泡中的内容') && todayPrompt.includes('提示词中的日期均不参与判断'));
assert.ok(!prompt.includes('contains_today_chat'), 'Ordinary transcript tasks must not acquire today-only rules');
assert.ok(todayPrompt.includes('同页同时出现“上午/下午＋时间”也返回false。'));
assert.ok(todaySummaryPrompt.includes('聊天气泡里面出现“昨天”“下周”“上个月”等时间词，不影响contains_today_chat。'));
for (const value of [prompt, todaySummaryPrompt]) {
  assert.ok(value.includes('任务的聊天对象或者群聊名是${context.contact_name}'));
  assert.ok(value.includes('3. 私聊：左侧聊天头像旁没有成员昵称'));
  assert.ok(value.includes('右侧气泡的发送人填写“我”，聊天对象填写私聊对象的人名。'));
  assert.ok(value.includes('聊天对象根据截图中的@、称呼、回复关系和上下文判断'));
  assert.ok(value.includes('无法确定具体接收人时填写群名，不猜测姓名。'));
  assert.ok(value.includes('时间原文初始为“未显示”'));
  assert.ok(value.includes('已经记录的上方消息不使用新出现的下方标签。'));
  assert.ok(!value.includes('左侧成员1（姓名未显示）'));
  assert.ok(value.includes('带斜杠的内容只选一个'));
  assert.ok(value.includes('- 位置：左侧/右侧｜发送人：'));
  assert.ok(!value.includes('左侧/右侧/居中'));
  assert.ok(!value.includes('系统消息'));
  assert.ok(value.includes('会话类型、会话名称各写一行'));
  assert.ok(value.includes('确认每条记录保留了五个字段名'));
  assert.ok(value.includes('发送人：按下方私聊或群聊规则填写｜聊天对象：按下方私聊或群聊规则填写'));
  assert.ok(value.includes('“按下方私聊或群聊规则填写”为填写说明'));
}
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
console.log('PASS: shared transcript, packaged defaults, fallback builders and short schema descriptions agree.');

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
const capturePrompt = new WorkflowDateContext(new Date(2026, 10, 17, 17, 58, 23)).withCaptureDatePrompt(todaySummaryPrompt);
assert.ok(capturePrompt.startsWith('【任务执行时间参考】\n采集时间：2026年11月17日 17:58:23 星期二\n'));
assert.ok(capturePrompt.includes('时间标签和聊天气泡中的时间表达按原文保留，日期换算由App后续处理。'));
assert.equal(capturePrompt.split('【任务执行时间参考】').length, 2);
const runnerSource=ts.createSourceFile('WorkflowRunner.ets',fs.readFileSync(path.join(root,'entry/src/main/ets/utils/WorkflowRunner.ets'),'utf8'),ts.ScriptTarget.Latest,true);
const runnerClass=runnerSource.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='WorkflowRunner');
const methodNames=['createSummaryJob','dailySummaryLogText','appendDailySummaryLog'];
const methods=runnerClass.members.filter(n=>ts.isMethodDeclaration(n)&&methodNames.includes(n.name.getText(runnerSource)));
assert.equal(methods.length,methodNames.length);
const runnerExports={},savedLogs=new Map();
vm.runInNewContext(ts.transpileModule('class Runner {\n'+methods.map(n=>n.getText(runnerSource)).join('\n')+'\n}\nexports.Runner=Runner;',
  {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{exports:runnerExports,ArkJSON:JSON,
    dailyLogMaxEntryId:loadDateModule('DailyLogEntryIdentity').dailyLogMaxEntryId,
    WorkflowStorage:{dailyLogDir:()=>'/app/daily-log',ensureDirectory(){},countFiles:p=>savedLogs.has(p)?1:0,
      readText:p=>savedLogs.get(p),writeText:(p,t)=>savedLogs.set(p,t)}});
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

// Execute the real append method against model text that previously reset IDs.
const identity=loadDateModule('DailyLogEntryIdentity');
runner.appendDailySummaryLog('第一条\n    . 来源：文章作者',job.date_context);
runner.appendDailySummaryLog('下一张截图',job.date_context);
assert.deepEqual(Array.from(identity.dailyLogEntryBlocks(savedLogs.get(logPath).split('-->')[1]),e=>e.index),[1,2,3]);
savedLogs.set(logPath,'<!-- DAILY_LOG_METADATA\n'+JSON.stringify({latest_entry_index:9,entry_batch_ids:{12:'old-run'}})+'\n-->\n\n5. 原始记录\n\n2. 更小的编号\n    . 正文说明');
runner.appendDailySummaryLog('新记录',job.date_context);
assert.ok(savedLogs.get(logPath).endsWith('13. 新记录\n'));
assert.equal(JSON.parse(savedLogs.get(logPath).split('\n-->')[0].split('DAILY_LOG_METADATA\n')[1]).entry_batch_ids['12'],'old-run');
assert.equal(identity.dailyLogMaxEntryId('5. 消息\n    . 来源：作者\n\n2. 消息'),5);
const readSaved=savedLogs.get.bind(savedLogs),beforeReadFailure=readSaved(logPath);
savedLogs.get=()=>{throw Error('injected read failure');};
assert.throws(()=>runner.appendDailySummaryLog('不得覆盖原文件',job.date_context),/未覆盖原始记录/);
savedLogs.get=readSaved;assert.equal(savedLogs.get(logPath),beforeReadFailure);
console.log('PASS: summary append ignores body punctuation and preserves the largest persisted entry ID.');
