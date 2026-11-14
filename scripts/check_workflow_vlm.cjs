// Offline replay of the real WorkflowRunner and JSON parser. No network or device actions.
// node scripts/check_workflow_vlm.cjs <HarmonyOS typescript module path>
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const utils = path.join(root, 'entry/src/main/ets/utils');
const clone = value => JSON.parse(JSON.stringify(value));
const cases = [];
const test = (name, body) => cases.push({name, body});
const timeout = JSON.stringify({action: 'error', reason: 'Operation timeout'});
const answer = (today, summary = '一条可见消息') => JSON.stringify({summary, contains_today_chat: today});

function fixtureToday() {
  const workflow = JSON.parse(fs.readFileSync(path.join(root,
    'entry/src/main/resources/rawfile/workflows/configs/default_weixin_today_chat.json'), 'utf8'));
  workflow.steps = [workflow.steps.find(step => step.type === 'loop')];
  // Reproduce the older saved task's strict true gate without changing its configuration.
  workflow.steps[0].steps.find(step => step.type === 'if').condition.operator = '==';
  workflow.steps[0].steps.find(step => step.type === 'if').condition.right = true;
  workflow.steps[0].max_times = 5;
  workflow.context.contact_name = '测试联系人';
  return workflow;
}

function ordinary(blocking = false) {
  return {steps: [{id: 3, type: 'loop', times: 2, steps: [
    {id: 1, type: 'gui_action', action: 'screenshot', file_name: 'page_${loop.index}.jpg'},
    {id: 2, type: 'tool', tool_name: 'vlm_qa', inputs: {
      mode: 'summary', image: '${steps.1.output.image_b64}', question: '记录可见消息', blocking}},
    {id: 3, type: 'if', condition: {left: '${loop.last}', operator: '==', right: false}, then_steps: [
      {id: 1, type: 'gui_action', action: 'swipe_with_coords', start_x: 540, start_y: 800, end_x: 540, end_y: 2100}]}]}]};
}

function environment(handler, options = {}) {
  const files = new Map(), calls = [], actions = [], progress = [], logs = [], modules = new Map();
  let cancelled = false, shots = 0;
  const storage = {
    configDir: () => '/sandbox/configs', runsDir: () => '/sandbox/runs', dailyLogDir: () => '/sandbox/daily-log',
    readTaskWorkflowJson: (_dir, task) => task.workflowJson, validateWorkflowJson: JSON.parse,
    ensureWorkspace() {}, ensureDirectoryTree() {}, ensureDirectory() {},
    resolveWorkflowImageInputAsBase64: (_dir, input) => input,
    workflowRunRelativePath: (_dir, file) => file,
    writeBase64Image: (file, content) => files.set(file, content),
    countFiles: file => files.has(file) ? 1 : 0,
    readText: file => files.get(file),
    writeText(file, text) {
      if (options.failDailyWrite && file.includes('/daily-log/')) throw Error('disk unavailable');
      files.set(file, text);
    }
  };
  const controller = {
    isCancelRequested: () => cancelled, waitIfPaused: async () => {},
    beginExecution() {}, finishExecution: text => progress.push(text), returnToApp: () => true,
    updateFloatText: text => progress.push(text)
  };
  const stubs = {
    './AiServiceAccess': {AiServiceAccess: {requireAllowed() {}}},
    './CloudModelClient': {}, './AgentPromptTemplates': {},
    './AppIdentity': {getAppBundleName: () => 'test.app'},
    './AppLogger': {AppLogger: {info() {}, debug() {}}},
    './WorkflowStorage': {WorkflowStorage: storage},
    './AgentExecutionController': {AgentExecutionController: controller},
    './HdcWorkflowBridge': {HdcWorkflowBridge: class {}}
  };
  function load(file) {
    const resolved = path.resolve(file);
    if (modules.has(resolved)) return modules.get(resolved);
    const exports = {}; modules.set(resolved, exports);
    const compiled = ts.transpileModule(fs.readFileSync(resolved, 'utf8'), {
      compilerOptions: {target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS}
    }).outputText;
    vm.runInNewContext(compiled, {exports, JSON, Date, setTimeout, clearTimeout,
      require(name) {
        if (name === '@kit.ArkTS') return {JSON};
        if (stubs[name]) return stubs[name];
        if (name.startsWith('.')) return load(path.resolve(path.dirname(resolved), name + '.ets'));
        throw Error('Unexpected dependency: ' + name);
      }}, {filename: resolved});
    return exports;
  }
  const {WorkflowRunner} = load(path.join(utils, 'WorkflowRunner.ets'));
  const runner = new WorkflowRunner('/sandbox', {async chatImageQuestion(...args) {
    calls.push(args); return handler({index: calls.length, prompt: args[0], image: args[1], cancel: () => {cancelled = true;}});
  }}, () => ({}), '', text => logs.push(text));
  runner.useDeviceBridgeForPhone({
    screenshot: async () => ({status: 'ok', image_b64: 'image-' + (++shots),
      width: 540, height: 1222, screen_width: 1080, screen_height: 2444}),
    guiAction: async payload => {actions.push(clone(payload)); return {status: 'ok'};}, startApp: async () => {}
  });
  return {files, calls, actions, progress, logs, runner,
    recover: load(path.join(utils, 'WorkflowStructuredRecovery.ets')).recoverWorkflowStructuredFields,
    daily: () => [...files].filter(([file]) => file.includes('/daily-log/')).map(([,text]) => text).join('\n'),
    images: () => [...files.keys()].filter(file => file.endsWith('.jpg')),
    rawFailures: () => [...files].filter(([file]) => /-response\.txt$/.test(file) && !file.includes('-recovered-response.txt')),
    recoveredResponses: () => [...files].filter(([file]) => file.includes('-recovered-response.txt')),
    summary: () => JSON.parse([...files].find(([file]) => file.endsWith('/run_summary.json'))[1]),
    run: workflow => runner.runTask({id: 'fixture', source: 'fixture', title: '测试采集',
      configFileName: 'fixture.json', workflowJson: JSON.stringify(workflow)})};
}

test('recorded timeout envelope fails after two attempts, before any swipe or next iteration', async () => {
  const env = environment(() => timeout), workflow = fixtureToday(), original = JSON.stringify(workflow);
  const result = await env.run(workflow);
  assert.equal(result.status, 'failed'); assert.match(result.message, /Operation timeout/);
  assert.equal(env.calls.length, 2); assert.equal(env.actions.length, 0); assert.equal(env.images().length, 1);
  assert.deepEqual(env.calls[0], env.calls[1]); assert.equal(env.daily(), '');
  assert.equal(env.rawFailures().length, 2); assert.ok(env.rawFailures().every(([,raw]) => raw === timeout));
  assert.equal(env.summary().steps['3.iter1.2'].status, 'failed');
  assert.equal(env.summary().steps['3.iter2.1'], undefined);
  assert.ok(env.progress.some(text => text.includes('正在重试') && text.includes('2/2')));
  assert.match(env.progress.at(-1), /Workflow failed.*Operation timeout/);
  assert.equal(JSON.stringify(workflow), original);
});

test('a transient timeout recovers on the same evidence, then swipes once and stops on false', async () => {
  const env = environment(({index}) => {
    if (index === 1) throw Error('Operation timeout');
    return index === 2 ? answer(true, '今天的消息') : answer(false, '昨天的消息');
  });
  assert.equal((await env.run(fixtureToday())).status, 'success');
  assert.equal(env.calls.length, 3); assert.deepEqual(env.calls[0], env.calls[1]);
  assert.notEqual(env.calls[1][1], env.calls[2][1]);
  assert.equal(env.actions.filter(action => action.action === 'swipe_with_coords').length, 1);
  assert.equal(env.images().length, 2); assert.ok(!env.daily().includes('Operation timeout'));
  assert.equal(env.summary().steps['3'].output.break_iteration, 2);
});

test('retry uses the original prompt and accepts only an independent judgment field', async () => {
  const misplaced = JSON.stringify({summary: '可见消息正文中的引用：contains_today_chat: true'});
  const env = environment(({index}) => index === 1 ? misplaced : answer(false, '日期标签属于昨天'));
  assert.equal((await env.run(fixtureToday())).status, 'success');
  assert.equal(env.calls.length, 2); assert.equal(env.actions.length, 0);
  assert.equal(env.calls[0][1], env.calls[1][1]);
  assert.deepEqual(env.calls[0], env.calls[1]);
  const schema = fixtureToday().steps[0].steps[1].inputs.json_schema;
  assert.ok(env.calls[0][0].endsWith('请严格输出一个 JSON 对象，不要输出 markdown 或额外解释。JSON Schema：' + JSON.stringify(schema)));
  assert.ok(!env.calls[0][0].includes('【必须遵守的输出格式】'));
  assert.ok(!env.calls[1][0].includes('上次返回格式不符合要求'));
  assert.ok(!env.calls[1][0].includes('模型结果缺少必要字段'));
  assert.equal(env.summary().steps['3.iter1.2'].output.structured_output.contains_today_chat, false);
  assert.equal(env.rawFailures()[0][1], misplaced); assert.ok(env.daily().includes('日期标签属于昨天'));
  assert.ok(!env.daily().includes('contains_today_chat: true'));
});

test('a repeated misplaced judgment still fails instead of guessing a swipe', async () => {
  const misplaced = JSON.stringify({summary: '聊天原文\ncontains_today_chat: true'});
  const env = environment(() => misplaced);
  assert.equal((await env.run(fixtureToday())).status, 'failed');
  assert.equal(env.calls.length, 2); assert.equal(env.actions.length, 0); assert.equal(env.daily(), '');
  assert.equal(env.rawFailures().length, 2);
});

test('separate trailing metadata is recovered without another request and its raw response is preserved', async () => {
  const raw = JSON.stringify({summary: '可见消息正文\n\ncontains_today_chat: true'});
  const env = environment(({index}) => index === 1 ? raw : answer(false));
  assert.equal((await env.run(fixtureToday())).status, 'success');
  assert.equal(env.calls.length, 2); assert.equal(env.images().length, 2);
  assert.equal(env.actions.filter(action => action.action === 'swipe_with_coords').length, 1);
  assert.equal(env.summary().steps['3.iter1.2'].output.structured_output.summary, '可见消息正文');
  assert.equal(env.summary().steps['3.iter1.2'].output.structured_output.contains_today_chat, true);
  assert.equal(env.recoveredResponses()[0][1], raw); assert.equal(env.rawFailures().length, 0);
  assert.ok(env.daily().includes('可见消息正文')); assert.ok(!env.daily().includes('contains_today_chat: true'));
});

for (const suffix of ['contains_today_chat: false', '"containsTodayChat": "false"', '{"contains_today_chat":false}']) {
  test('an explicit recovered false stops correctly: ' + suffix, async () => {
    const raw = JSON.stringify({summary: '日期属于昨天\r\n\r\n' + suffix});
    const env = environment(() => raw);
    assert.equal((await env.run(fixtureToday())).status, 'success');
    assert.equal(env.calls.length, 1); assert.equal(env.actions.length, 0);
    assert.equal(env.summary().steps['3.iter1.2'].output.structured_output.contains_today_chat, false);
    assert.equal(env.recoveredResponses()[0][1], raw);
  });
}

for (const suffix of [
  'contains_today_chat: true\ncontains_today_chat: false',
  'contains_today_chat: true\ncontainsTodayChat: false',
  '{"contains_today_chat":true,"contains_today_chat":false}',
  'contains_today_chat: true\nunknown_field: false',
  '> contains_today_chat: true', '原文：contains_today_chat: true',
  'contains_today_chat: 无法确定', 'contains_today_chat: null'
]) test('ambiguous or quoted metadata is never promoted: ' + suffix, async () => {
  const env = environment(() => JSON.stringify({summary: '消息正文\n\n' + suffix}));
  assert.equal((await env.run(fixtureToday())).status, 'failed');
  assert.equal(env.calls.length, 2); assert.equal(env.actions.length, 0); assert.equal(env.daily(), '');
  assert.equal(env.recoveredResponses().length, 0);
});

test('an explicit top-level judgment takes precedence over text and is not rewritten', async () => {
  const summary = '消息正文\n\ncontains_today_chat: true';
  const env = environment(() => answer(false, summary));
  assert.equal((await env.run(fixtureToday())).status, 'success');
  assert.equal(env.calls.length, 1); assert.equal(env.actions.length, 0);
  assert.equal(env.summary().steps['3.iter1.2'].output.structured_output.summary, summary);
  assert.equal(env.recoveredResponses().length, 0);
});

test('conflicting top-level aliases are not replaced by a recovered paragraph', () => {
  const env = environment(() => 'unused');
  const schema = {summary: {type: 'string'}, contains_today_chat: {type: 'boolean'}};
  const source = {summary: '消息正文\n\ncontains_today_chat: true', containsTodayChat: true, CONTAINS_TODAY_CHAT: false};
  const recovered = env.recover(source, schema);
  assert.equal(recovered.output, source); assert.equal(recovered.fields.length, 0);
  assert.throws(() => env.runner.validateVlmQaResponse(JSON.stringify(source), schema), /重复或冲突/);
});

test('unclosed code blocks and multiple possible text fields do not supply control fields', async () => {
  const env = environment(() => 'unused');
  for (const value of [
    {summary: '聊天记录\n```json\n\ncontains_today_chat: true'},
    {summary: '原文：\n\ncontains_today_chat: true'},
    {summary: '正文\n\ncontains_today_chat: true', note: '另一段正文\n\ncontains_today_chat: false'}
  ]) {
    const schema = {summary: {type: 'string'}, contains_today_chat: {type: 'boolean'}};
    if (value.note) schema.note = {type: 'string'};
    assert.throws(() => env.runner.validateVlmQaResponse(JSON.stringify(value), schema), /缺少必要字段/);
  }
});

test('recovery uses schema-declared scalar fields and never mutates the input map', () => {
  const env = environment(() => 'unused');
  const raw = {note: '可见文本\n\ncan_continue: false\nconfidence: 0.75'};
  const schema = {note: {type: 'string'}, can_continue: {type: 'boolean'}, confidence: {type: 'number'}};
  const result = env.recover(raw, schema);
  assert.notEqual(result.output, raw);
  assert.equal(result.output.can_continue, false);
  assert.equal(result.output.confidence, 0.75);
  assert.equal(result.output.note, '可见文本');
  assert.deepEqual(JSON.parse(JSON.stringify(result.fields)), ['can_continue', 'confidence']);
  assert.equal(raw.note, '可见文本\n\ncan_continue: false\nconfidence: 0.75');
  assert.deepEqual(Object.keys(raw), ['note']);
});

if (process.argv[3]) test('the locally exported original failed response is recovered without a model call', () => {
  const raw = fs.readFileSync(process.argv[3], 'utf8');
  const env = environment(() => {throw Error('must not call a model');});
  const schema = fixtureToday().steps[0].steps[1].inputs.json_schema;
  const result = env.runner.validateVlmQaResponse(raw, schema);
  assert.equal(result.structured_output.contains_today_chat, true);
  assert.ok(result.structured_output.summary.length > 0);
  assert.equal(env.calls.length, 0);
});

test('the original simple JSON suffix follows the schema and stays identical on retry', async () => {
  const env = environment(({index}) => index === 1 ? '{"note":"visible"}' : '{"note":"visible","can_continue":false}');
  const schema = {note: {type: 'string'}, can_continue: {type: 'boolean'}};
  env.runner.runDir = '/sandbox/runs/schema';
  const result = await env.runner.runTool({id: 1, type: 'tool', tool_name: 'vlm_qa', inputs: {
    mode: 'answer', question: '读取截图中的内容并判断是否继续', image: 'same-image', json_schema: schema}}, '1');
  assert.equal(result.structured_output.can_continue, false);
  assert.deepEqual(env.calls[0], env.calls[1]);
  assert.ok(env.calls[1][0].endsWith('请严格输出一个 JSON 对象，不要输出 markdown 或额外解释。JSON Schema：' + JSON.stringify(schema)));
  assert.ok(!env.calls[1][0].includes('【必须遵守的输出格式】'));
  assert.ok(!env.calls[1][0].includes('上次返回格式不符合要求'));
  assert.ok(!env.calls[1][0].includes('contains_today_chat'));
});

for (const [name, raw] of [
  ['missing flag', JSON.stringify({summary: '消息'})],
  ['null flag', answer(null)], ['ambiguous flag', answer('无法判断')],
  ['object flag', answer({value: true})], ['invalid JSON', '模型忘记输出结构化结果'],
  ['missing summary', JSON.stringify({contains_today_chat: true})]
]) test(name + ' cannot silently skip both the swipe and stop branches', async () => {
  const env = environment(() => raw);
  assert.equal((await env.run(fixtureToday())).status, 'failed');
  assert.equal(env.calls.length, 2); assert.equal(env.actions.length, 0); assert.equal(env.daily(), '');
});

test('existing fenced JSON, wrappers, key aliases and boolean strings remain compatible', async () => {
  const env = environment(({index}) => index === 1 ?
    '```json\n{"result":{"Summary":"可见消息","containsTodayChat":"true"}}\n```' : answer(false));
  assert.equal((await env.run(fixtureToday())).status, 'success');
  assert.equal(env.calls.length, 2);
  assert.equal(env.summary().steps['3.iter1.2'].output.structured_output.contains_today_chat, true, env.logs.join('\n'));
});

test('a valid false is not a failure and stops without retry or swipe', async () => {
  const env = environment(() => answer(false));
  assert.equal((await env.run(fixtureToday())).status, 'success');
  assert.equal(env.calls.length, 1); assert.equal(env.actions.length, 0);
});

test('later failure preserves the earlier transcript and both screenshots', async () => {
  const env = environment(({index}) => index === 1 ? answer(true, '已经采集的有效消息') : timeout);
  assert.equal((await env.run(fixtureToday())).status, 'failed');
  assert.equal(env.calls.length, 3); assert.equal(env.images().length, 2);
  assert.ok(env.daily().includes('已经采集的有效消息')); assert.ok(!env.daily().includes('Operation timeout'));
  assert.equal(env.summary().steps['3.iter1.2'].status, 'success');
  assert.equal(env.summary().steps['3.iter2.2'].status, 'failed');
});

test('deferred summaries share the two-attempt budget and preserve successful siblings', async () => {
  const counts = new Map();
  const env = environment(({image}) => {
    const count = (counts.get(image) || 0) + 1; counts.set(image, count);
    return image === 'image-1' && count === 2 ? '第一屏的有效消息' : timeout;
  });
  assert.equal((await env.run(ordinary())).status, 'failed');
  assert.deepEqual([...counts.values()], [2, 2]); assert.equal(env.images().length, 2);
  assert.ok(env.daily().includes('第一屏的有效消息')); assert.ok(!env.daily().includes('Operation timeout'));
  assert.equal(env.summary().steps['3.iter2.2'].status, 'failed');
});

test('blocking non-schema summaries also reject error envelopes', async () => {
  const env = environment(() => timeout);
  assert.equal((await env.run(ordinary(true))).status, 'failed');
  assert.equal(env.calls.length, 2); assert.equal(env.daily(), ''); assert.equal(env.actions.length, 0);
});

test('plain transcripts quoting an error JSON message remain valid content', async () => {
  const text = '原文：程序返回了 {"action":"error","reason":"Operation timeout"}，需要排查。';
  const env = environment(() => text);
  assert.equal((await env.run(ordinary())).status, 'success');
  assert.equal(env.calls.length, 2); assert.equal(env.rawFailures().length, 0);
  assert.ok(env.daily().includes(text));
});

test('cancellation while inference is pending prevents retry, commit and subsequent gestures', async () => {
  const env = environment(({cancel}) => {cancel(); return answer(true);});
  assert.equal((await env.run(fixtureToday())).status, 'cancelled');
  assert.equal(env.calls.length, 1); assert.equal(env.actions.length, 0); assert.equal(env.daily(), '');
  assert.equal(env.images().length, 1);
});

test('log persistence failure does not repeat inference or issue a swipe', async () => {
  const env = environment(() => answer(true), {failDailyWrite: true});
  const result = await env.run(fixtureToday());
  assert.equal(result.status, 'failed'); assert.match(result.message, /disk unavailable/);
  assert.equal(env.calls.length, 1); assert.equal(env.actions.length, 0); assert.equal(env.images().length, 1);
});

test('empty deferred responses exhaust the shared budget without polluting daily logs', async () => {
  const env = environment(() => '  ');
  assert.equal((await env.run(ordinary())).status, 'failed');
  assert.equal(env.calls.length, 4); assert.equal(env.daily(), '');
});

(async () => {
  for (const {name, body} of cases) {await body(); console.log('PASS:', name);}
  console.log('Passed ' + cases.length + ' workflow VLM checks; no network/device actions performed.');
})().catch(error => {console.error(error); process.exitCode = 1;});
