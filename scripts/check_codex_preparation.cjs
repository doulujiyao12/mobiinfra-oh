// Offline checks of the production phone Agent, profile lookup and routing.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript'),root=path.resolve(__dirname,'..'),base='entry/src/main/ets/';
const cache=new Map(),logs=[];
function load(relative){
  const file=path.resolve(root,relative.endsWith('.ets')?relative:relative+'.ets');if(cache.has(file))return cache.get(file);
  if(path.basename(file)==='CloudModelClient.ets')return{CloudModelClient:class{},cloudPlannerApiKey:c=>c.plannerApiKey||c.apiKey||''};
  if(path.basename(file)==='AppLogger.ets')return{AppLogger:{info:(_tag,text)=>logs.push(text),warnCause:(_tag,text)=>logs.push(text)}};
  const exports={};cache.set(file,exports);
  const output=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}});
  vm.runInNewContext(output.outputText,{exports,console,setTimeout,clearTimeout,Date,Observed: target=>target,require:id=>{
    if(id==='@kit.ArkTS')return{JSON};if(!id.startsWith('.'))throw Error('Unexpected '+id);
    return load(path.resolve(path.dirname(file),id));
  }},{filename:file});return exports;
}
const {CodexTaskPreparation}=load(base+'utils/CodexTaskPreparation'),{CodexProfileLookup}=load(base+'utils/CodexProfileLookup');
const {ChatReactAgent}=load(base+'utils/ChatReactAgent'),{ChatToolRegistry}=load(base+'utils/ChatToolRegistry');
const {codexTaskWithDeliveryPolicy}=load(base+'utils/CodexDeliveryPolicy');
const {cloudBadRequestCategory,cloudBadRequestUserHint}=load(base+'utils/CloudHttpDiagnostics');
const {codexMemorySelectionMessages,parseCodexMemorySelection,codexSelectionShape}=load(base+'utils/CodexMemorySelection');
const {eventMemorySupplement,profileMemorySupplement,normalizeMemorySupplement,sameMemorySupplement,MEMORY_SUPPLEMENT_MAX_ITEMS}=load(base+'utils/MemorySupplement');
const {parseCodexMemoryPlan,codexMemoryTextAlreadySupplied}=load(base+'utils/CodexMemoryPlan');
const {codexReferencePeople,codexPersonReferences,codexProfileReferences,composeCodexReferences}=load(base+'utils/CodexReferenceContext');
const config={plannerBaseUrl:'https://planner.example/v1',plannerApiKey:'test-only-key',plannerModel:'phone-planner'};
const profile='# 用户画像\n- 生成时间：2026-11-04\n## 工作\n用户研究方向为端侧智能体。无关的私人暗号为PRIVATE_UNRELATED。\n- 用户任职于某高校，负责科研教学。\n## 吃\n- 用户喜欢清淡饮食。';
const final=content=>({content,toolCalls:[],assistantMessage:{role:'assistant',content},finishReason:'stop'});
const query=(words,id='q')=>{const call={id,type:'function',function:{name:'read_profile',arguments:JSON.stringify({keywords:words})}};
  return{content:'',toolCalls:[call],assistantMessage:{role:'assistant',content:'',tool_calls:[call]},finishReason:'tool_calls'};};
function client(handler,planning=()=>final('{"known_information":[],"missing_information":["完成当前任务还未知且确有帮助的个人背景是什么？"]}')){
  return{requests:[],planningRequests:[],cancels:0,async chatCompletion(options){
    if(options.messages[0]?.content.includes('known_information简列')){
      this.planningRequests.push(options);return planning(options,this.planningRequests.length);
    }
    this.requests.push(options);return handler(options,this.requests.length);
  },cancelActiveRequests(){this.cancels++;}};
}
// Same placement constraint as the official Qwen3.5 chat template: an interior
// system message raises "System message must be at the beginning."
function strictTemplateRequest(options){
  options.messages.forEach((m,i)=>{if(m.role==='system'&&i!==0)throw Error('Cloud HTTP 400 [system_message_position]');});
}
function context(reader=()=>profile){return{filesDir:'/app',readProfile:reader,isCancelled:()=>false};}
const tests=[];function test(name,fn){tests.push([name,fn]);}
test('retrieval stays read-only after gap analysis and never discloses the whole profile',async()=>{
  let reads=0;const c=client(()=>final('{"selected_ids":[]}'));
  const result=await new CodexTaskPreparation(c).prepare('修复给定代码中的语法错误',config,context(()=>{reads++;return profile;}));
  assert.equal(reads,0);assert.equal(result.count,0);assert.equal(result.task,'修复给定代码中的语法错误');
  assert.equal(c.requests[0].model,'phone-planner');assert.equal(c.requests[0].chatTemplateKwargs.enable_thinking,false);
  assert.deepEqual(Array.from(c.requests[0].tools,t=>t.function.name),['query_events','search_memory','read_profile']);
  assert(!JSON.stringify(c.requests).includes('PRIVATE_UNRELATED'));
});
test('Agent selects only original relevant profile facts, not generated claims or unknown IDs',async()=>{
  let reads=0;const c=client((options,round)=>{
    if(round===1)return query(['研究方向']);
    const facts=JSON.parse(options.messages.find(m=>m.role==='tool').content).facts;
    assert.equal(facts.length,1);assert(!facts[0].text.includes('PRIVATE_UNRELATED'));
    return final(JSON.stringify({selected_ids:[facts[0].id,'made-up'],fabricated:'用户拥有三家公司'}));
  });
  const result=await new CodexTaskPreparation(c).prepare('制作介绍我研究方向的PPT',config,context(()=>{reads++;return profile;}));
  assert.equal(reads,1);assert.equal(result.count,1);assert.match(result.task,/用户研究方向为端侧智能体/);
  assert(!result.task.includes('三家公司'));assert(!result.task.includes('PRIVATE_UNRELATED'));assert(!result.task.includes('清淡饮食'));
  assert(result.task.startsWith('制作介绍我研究方向的PPT'));assert.match(result.task,/以当前任务为准/);
  assert.equal(result.memories.length,1);assert.equal(result.memories[0].source,'个人画像');
  assert.match(result.memories[0].content,/端侧智能体/);assert(!JSON.stringify(result.memories).includes('PRIVATE_UNRELATED'));
});
test('profile lookup is lazy, cached, bounded, deduplicated and never falls back to all records',()=>{
  let reads=0;const lookup=new CodexProfileLookup(()=>{reads++;return profile+'\n'+Array(20).fill('- 用户研究方向为端侧智能体。').join('\n');});
  assert.equal(lookup.search([]).length,0);assert.equal(reads,0);
  const found=lookup.search(['研究方向']);assert.equal(found.length,1);assert.equal(reads,1);
  assert.equal(lookup.search(['不存在的领域']).length,0);assert.equal(reads,1);
  assert.equal(lookup.selected(['invented']).length,0);assert.equal(lookup.search(['研究方向'])[0].id,found[0].id);
});
test('long profile results remain complete JSON and undisclosed IDs cannot be selected',async()=>{
  const large='## 工作\n'+Array.from({length:8},(_,i)=>'- 研究兴趣'+i+' '+String(i).repeat(1500)).join('\n');
  const c=client((options,round)=>{
    if(round===1)return query(['研究兴趣']);
    const text=options.messages.find(m=>m.role==='tool').content,facts=JSON.parse(text).facts;
    assert(text.length<=3500);assert(facts.length<6);assert(facts.length>0);
    return final(JSON.stringify({selected_ids:[facts[0].id,'profile-6']}));
  });
  const result=await new CodexTaskPreparation(c).prepare('研究兴趣规划',config,context(()=>large));
  assert.equal(result.count,1);assert.match(result.task,/画像原文节选/);
});
test('missing profile, malformed model output and read errors preserve the original task transparently',async()=>{
  for(const response of ['not JSON','{"selected_ids":[123]}','{"selected_ids":["invented"]}']){
    const result=await new CodexTaskPreparation(client(()=>final(response))).prepare('整理工作计划',config,context());
    assert.equal(result.task,'整理工作计划');assert.equal(result.count,0);
    if(response==='not JSON')assert.match(result.notice,/未完成/);
  }
  const c=client((_options,n)=>n===1?query(['研究方向']):final('{"selected_ids":[]}'));
  const result=await new CodexTaskPreparation(c).prepare('整理工作计划',config,context(()=>{throw Error('storage unavailable');}));
  assert.equal(result.task,'整理工作计划');assert.match(result.notice,/未完成/);
  const noProfile=await new CodexTaskPreparation(client((_o,n)=>n===1?query(['研究方向']):final('{"selected_ids":[]}'))).prepare('整理计划',config,context(()=>''));
  assert.equal(noProfile.task,'整理计划');assert.equal(noProfile.count,0);
});
test('cancellation and total timeout settle even if the model ignores HTTP cancellation',async()=>{
  let release,signal;const ready=new Promise(resolve=>signal=resolve);
  const c=client(()=>{signal();return new Promise(resolve=>release=resolve);});const prep=new CodexTaskPreparation(c,200);
  const job=prep.prepare('整理计划',config,context());await ready;prep.cancel();
  await assert.rejects(job,/已取消/);assert(c.cancels>0);release(final('{"selected_ids":[]}'));
  const slow=client(()=>new Promise(()=>{}));const timed=await new CodexTaskPreparation(slow,10).prepare('整理计划',config,context());
  assert.equal(timed.task,'整理计划');assert.match(timed.notice,/未完成/);assert(slow.cancels>0);
});
test('tool-call and response budgets cannot grow into an unbounded memory search',async()=>{
  let reads=0;const c=client((_o,n)=>query(['研究方向'],'q'+n));
  const result=await new CodexTaskPreparation(c).prepare('研究计划',config,context(()=>{reads++;return profile;}));
  assert.equal(reads,1);assert(c.requests.length<=6);assert.equal(result.count,0);assert.match(result.notice,/未完成/);
  const task='中😀\\"'.repeat(2000);const chosen=client((options,n)=>n===1?query(['研究方向']):
    final(JSON.stringify({selected_ids:JSON.parse(options.messages.find(m=>m.role==='tool').content).facts.map(f=>f.id)})));
  const prepared=await new CodexTaskPreparation(chosen).prepare(task,config,context());
  assert(prepared.task.startsWith(task));assert(Buffer.byteLength(JSON.stringify({text:codexTaskWithDeliveryPolicy(prepared.task)}))<64000);
});
test('repeated retrieval calls finish once without tools and retain previously published evidence',async()=>{
  let queries=0;const item={event_id:'indexed-research',event_date:'2026-11-05',sources:['GUI任务'],summary:'用户研究方向为端侧智能体'};
  const c=client((options,n)=>{
    strictTemplateRequest(options);
    if(options.tools?.length){const call={id:'repeat-'+n,type:'function',function:{name:'query_events',arguments:'{"keywords":["智能体"]}'}};
      return{content:'',toolCalls:[call],assistantMessage:{role:'assistant',content:'',tool_calls:[call]},finishReason:'tool_calls'};}
    assert.equal(options.toolChoice,undefined);assert.match(options.messages[0].content,/不能再调用任何工具/);
    assert.equal(options.messages.length,2);assert.equal(options.messages[1].role,'user');
    const facts=JSON.parse(options.messages[1].content).candidates;
    assert(facts.some(f=>f.text.includes('indexed-research')));
    return final(JSON.stringify({selected_ids:[facts[0].id,'invented']}));
  });
  const ctx=context(()=>{throw Error('profile is unnecessary');});ctx.hasIndexes=()=>true;
  ctx.queryEvents=()=>{queries++;return{events:[item],total_events:1,events_truncated:false};};
  const prepared=await new CodexTaskPreparation(c).prepare('为我的研究制作PPT',config,ctx);
  assert.equal(queries,4);assert.equal(c.requests.length,5);assert.equal(prepared.count,1);
  assert.match(prepared.task,/indexed-research/);assert.match(prepared.notice,/已补充/);assert(!prepared.task.includes('invented'));
});
test('a multi-call response cannot exceed the query budget or contaminate the clean selector with extra calls',async()=>{
  let queries=0;const c=client((options,n)=>{
    if(n===1){const calls=Array.from({length:8},(_,i)=>({id:'multi-'+i,type:'function',function:{name:'query_events',arguments:'{}'}}));
      return{content:'',toolCalls:calls,assistantMessage:{role:'assistant',content:'',tool_calls:calls},finishReason:'tool_calls'};}
    assert(!options.tools);assert.equal(options.toolChoice,undefined);
    assert.equal(options.messages.length,2);const input=JSON.parse(options.messages[1].content);
    assert.equal(input.candidates.length,1);assert.equal(input.candidates[0].id,'event-1');
    assert(!options.messages.some(m=>m.tool_calls||m.tool_call_id||m.role==='tool'));
    return final('{"selected_ids":["event-1"]}');
  });
  const ctx=context();ctx.hasIndexes=()=>true;ctx.queryEvents=()=>{queries++;return{events:[{event_id:'e',event_date:'2026-11-05',sources:['任务'],summary:'相关事件'}],total_events:1,events_truncated:false};};
  const prepared=await new CodexTaskPreparation(c).prepare('整理事件',config,ctx);
  assert.equal(queries,4);assert.equal(c.requests.length,2);assert.equal(prepared.count,1);
});
test('round exhaustion also finalizes, default Agent behavior and terminal user intent remain intact',async()=>{
  const registry=new ChatToolRegistry();let executions=0;
  registry.registerTool({name:'read_profile',description:'test',parameters:{},execute:async()=>{executions++;return '{}';}});
  const bounded=client((options,n)=>options.tools?.length?query(['研究方向'],'round-'+n):final('done'));
  const answer=await new ChatReactAgent(bounded,registry).run([{role:'user',content:'task'}],config,{maxIterations:2,maxToolCalls:4,finalizeOnLimit:true});
  assert.equal(answer.content,'done');assert.equal(answer.iterations,3);assert.equal(answer.reachedLimit,false);assert.equal(executions,2);
  const normal=client((_options,n)=>query(['研究方向'],'normal-'+n));
  const legacy=await new ChatReactAgent(normal,registry).run([{role:'user',content:'task'}],config,{maxIterations:2});
  assert.equal(normal.requests.length,2);assert(legacy.reachedLimit);
  registry.registerTool({name:'read_profile',description:'terminal',parameters:{},execute:async()=>'{"cancelled":true}',terminalResultMessage:()=> 'user cancelled'});
  const cancelled=client(()=>query(['研究方向']));
  const stop=await new ChatReactAgent(cancelled,registry).run([{role:'user',content:'task'}],config,{maxIterations:2,maxToolCalls:1,finalizeOnLimit:true});
  assert.equal(stop.finishReason,'tool_terminal');assert.equal(cancelled.requests.length,1);
});
test('finalization satisfies strict system placement and preserves initial prompts and every tool observation',async()=>{
  const registry=new ChatToolRegistry();registry.registerTool({name:'read_profile',description:'test',parameters:{},execute:async()=>'{"fact":"original"}'});
  for(const system of [undefined,'最初的格式与资料边界',[{type:'text',text:'结构化初始指令'}]]){
    const messages=system===undefined?[{role:'user',content:'task'}]:[{role:'system',content:system},{role:'user',content:'task'}];
    const snapshot=JSON.stringify(messages);let request=0;
    const c=client(options=>{
      strictTemplateRequest(options);
      if(++request===1)return query(['资料']);
      assert.equal(options.messages.filter(m=>m.role==='system').length,1);assert.equal(options.messages[0].role,'system');
      assert.equal(options.messages.at(-1).role,'tool');assert.equal(options.messages.at(-1).content,'{"fact":"original"}');
      assert(options.messages.some(m=>m.role==='assistant'&&m.tool_calls?.length===1));assert(!options.tools);
      const first=options.messages[0].content;
      if(typeof system==='string')assert(first.startsWith(system));
      if(Array.isArray(system)){assert.equal(first[0].text,system[0].text);assert.equal(first.length,2);}
      return final('done');
    });
    const answer=await new ChatReactAgent(c,registry).run(messages,config,{maxIterations:1,maxToolCalls:1,finalizeOnLimit:true});
    assert.equal(answer.content,'done');assert.equal(request,2);assert.equal(JSON.stringify(messages),snapshot);
    const invalid=c.requests.at(-1).messages.concat([{role:'system',content:'old final instruction'}]);
    assert.throws(()=>strictTemplateRequest({messages:invalid}),/HTTP 400/);
  }
});
test('cancellation while final selection is pending stops preparation without dispatch or another read',async()=>{
  let selecting,signal;const ready=new Promise(resolve=>signal=resolve);
  const c=client((options,n)=>{if(options.tools?.length)return query(['研究方向'],'cancel-'+n);
    signal();return new Promise(resolve=>selecting=resolve);});
  const prep=new CodexTaskPreparation(c,1000),job=prep.prepare('介绍研究方向',config,context());
  await ready;prep.cancel();await assert.rejects(job,/已取消/);assert.equal(c.requests.length,5);
  selecting(final('{"selected_ids":["profile-1"]}'));assert(c.cancels>0);
});
test('actual failure notices identify timeout, HTTP errors, malformed output and refusal to finalize',async()=>{
  const timed=await new CodexTaskPreparation(client(()=>new Promise(()=>{})),10).prepare('task',config,context());
  assert.match(timed.notice,/模型请求超时/);
  const rejected=await new CodexTaskPreparation(client(()=>{throw Error('Cloud HTTP 401');})).prepare('task',config,context());
  assert.match(rejected.notice,/HTTP 401/);
  const invalid=await new CodexTaskPreparation(client(()=>final('not JSON'))).prepare('task',config,context());
  assert.match(invalid.notice,/格式不符合要求/);
  const looping=await new CodexTaskPreparation(client((_o,n)=>query(['研究方向'],'loop-'+n))).prepare('task',config,context());
  assert.match(looping.notice,/模型未完成资料选择/);assert.equal(looping.count,0);
});
test('selection accepts explicit JSON variants without guessing choices from prose or tool markup',()=>{
  for(const text of ['{"selected_ids":["event-1"]}','["event-1"]','```json\n["event-1"]\n```',
    JSON.stringify('{"selected_ids":["event-1"]}'),'<think>draft</think>\n{"selected_ids":["event-1"]}',
    '{selected_ids:["event-1"],}']){
    assert.deepEqual(Array.from(parseCodexMemorySelection(text)),['event-1']);
  }
  assert.equal(parseCodexMemorySelection('[]').length,0);
  for(const text of ['不要选择 event-1','<tool_call>{"selected_ids":["event-1"]}</tool_call>',
    '{"selected_ids":[123]}','["event-1"','{"selected_ids":["event-1"]} {"selected_ids":[]}',
    '{"explanation":"do not select event-1"}'])assert.throws(()=>parseCodexMemorySelection(text));
  assert.equal(codexSelectionShape('<tool_call>...'),'tool_markup');assert.equal(codexSelectionShape('["event-1"]'),'array');
});
test('malformed output triggers one clean re-selection with existing facts and no additional retrieval',async()=>{
  let reads=0;const c=client((options,n)=>{
    if(n===1)return query(['研究方向']);
    if(n===2)return final('资料检索完成，但我尚未按 JSON 返回。');
    assert.equal(n,3);assert(!options.tools);assert.equal(options.messages.length,2);strictTemplateRequest(options);
    const data=JSON.parse(options.messages[1].content);assert.equal(data.task,'制作研究PPT');
    assert.equal(data.candidates.length,1);assert(!options.messages.some(m=>m.role==='tool'||m.tool_calls));
    return final('["profile-1","fabricated"]');
  });
  const prepared=await new CodexTaskPreparation(c).prepare('制作研究PPT',config,context(()=>{reads++;return profile;}));
  assert.equal(reads,1);assert.equal(c.requests.length,3);assert.equal(prepared.count,1);assert.match(prepared.task,/端侧智能体/);
  assert(!prepared.task.includes('fabricated'));assert(!prepared.task.includes('PRIVATE_UNRELATED'));
});
test('re-selection failure does not attach unselected facts and total deadline covers a stalled re-selection',async()=>{
  let queries=0;const invalid=client((_options,n)=>n===1?query(['研究方向']):final('not JSON'));
  const failed=await new CodexTaskPreparation(invalid).prepare('task',config,context(()=>{queries++;return profile;}));
  assert.equal(queries,1);assert.equal(invalid.requests.length,3);assert.equal(failed.task,'task');assert.equal(failed.count,0);assert.match(failed.notice,/格式不符合要求/);
  let ready;const selected=new Promise(resolve=>ready=resolve);
  const slow=client((_options,n)=>{if(n===1)return query(['研究方向']);if(n===2)return final('not JSON');ready();return new Promise(()=>{});});
  const pending=new CodexTaskPreparation(slow,100).prepare('task',config,context());
  await selected;const timed=await pending;assert.match(timed.notice,/模型请求超时/);assert(slow.cancels>0);assert.equal(slow.requests.length,3);
});
test('clean selection contains bounded published facts only and keeps original inputs intact',()=>{
  const facts=Array.from({length:60},(_,i)=>({id:'event-'+i,text:'资料'.repeat(500)})),snapshot=JSON.stringify(facts);
  const messages=codexMemorySelectionMessages('任务'.repeat(10000),facts),data=JSON.parse(messages[1].content);
  assert.equal(messages.length,2);assert.equal(messages[0].role,'system');assert.equal(messages[1].role,'user');
  assert(data.truncated);assert(data.candidates.length<=32);assert(Buffer.byteLength(messages[1].content)<38100);
  assert.equal(JSON.stringify(facts),snapshot);assert(data.candidates.every(f=>facts.some(original=>original.id===f.id&&original.text===f.text)));
});
test('HTTP 400 diagnostics use fixed categories without exposing echoed prompts or secrets',async()=>{
  const cases=[['System message must be at the beginning.','system_message_position'],
    ['maximum context length exceeded','context_limit'],['tool_call_id does not match a tool_calls entry','tool_protocol'],
    ['unsupported parameter top_k','unsupported_parameter'],['model does not exist','model_unavailable'],['bad input','unclassified']];
  for(const[text,category]of cases){
    const serverBody=JSON.stringify({error:{message:text+' PRIVATE_REQUEST_TEXT Bearer private-token'}});
    assert.equal(cloudBadRequestCategory(serverBody),category);
    const hint=cloudBadRequestUserHint('Cloud HTTP 400 ['+category+']');assert(!hint.includes('PRIVATE_REQUEST_TEXT'));assert(!hint.includes('private-token'));
  }
  assert.equal(cloudBadRequestCategory(''), 'unclassified');assert.equal(cloudBadRequestUserHint('Cloud HTTP 400'),'');
  const rejected=await new CodexTaskPreparation(client(()=>{throw Error('Cloud HTTP 400 [system_message_position]');})).prepare('task',config,context());
  assert.match(rejected.notice,/HTTP 400.*system 消息位置不兼容/);
});
test('the production HTTP client propagates safe 400 categories and keeps successful responses unchanged',async()=>{
  const seen=[],nativeCache=new Map();let responseCode=400,responseBody=JSON.stringify({error:{message:'System message must be at the beginning. PRIVATE_REQUEST_TEXT Bearer private-token'}});
  let destroyed=0;
  const mocks={AppRequests:{AppRequests:{createHttp:()=>({request:async()=>({responseCode,result:responseBody})}),destroyHttp(){destroyed++;}}},
    AiServiceAccess:{AiServiceAccess:{requireAllowed(){}}},JsonCompat:{parseJsonCompat:JSON.parse},
    AppLogger:{AppLogger:{info:(_module,text)=>seen.push(text),warn:(_module,text)=>seen.push(text),error:(_module,text)=>seen.push(text)}}};
  function nativeLoad(name){
    if(mocks[name])return mocks[name];if(nativeCache.has(name))return nativeCache.get(name);
    if(!['CloudModelClient','CloudApiCompatibility','CloudHttpDiagnostics'].includes(name))return {};
    const file=path.join(root,base+'utils',name+'.ets'),exports={};nativeCache.set(name,exports);
    const code=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
    vm.runInNewContext(code,{exports,URL,Date,console,require:id=>{
      if(id==='@kit.ArkTS')return{JSON};if(id==='@kit.NetworkKit')return{http:{RequestMethod:{POST:'POST'},HttpDataType:{STRING:0}}};
      return nativeLoad(path.basename(id));
    }});return exports;
  }
  const Cloud=nativeLoad('CloudModelClient').CloudModelClient,c=new Cloud();
  const options={baseUrl:'https://planner.example/v1',apiKey:'test-key',messages:[{role:'system',content:'system'},{role:'user',content:'PRIVATE_REQUEST_TEXT'}],logResponseContent:false};
  await assert.rejects(c.chatCompletion(options),/Cloud HTTP 400 \[system_message_position\]/);
  assert(seen.some(text=>text.includes('roles=system,user')));assert(!seen.join('\n').includes('PRIVATE_REQUEST_TEXT'));assert(!seen.join('\n').includes('private-token'));
  responseCode=401;await assert.rejects(c.chatCompletion(options),/^Error: Cloud HTTP 401$/);
  responseCode=200;responseBody=JSON.stringify({choices:[{message:{content:'{"selected_ids":[]}'},finish_reason:'stop'}]});
  const completed=await c.chatCompletion(options);assert.equal(completed.content,'{"selected_ids":[]}');assert.equal(completed.finishReason,'stop');assert.equal(destroyed,3);
});
function methodProbe(file,name,methods,globals){
  const source=fs.readFileSync(path.join(root,base+file),'utf8').replace(new RegExp('\\bstruct '+name+'\\b'),'class '+name);
  const tree=ts.createSourceFile('Probe.ts',source,ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text===name);
  const selected=component.members.filter(n=>ts.isMethodDeclaration(n)&&methods.includes(n.name.getText(tree)));
  const exports={};vm.runInNewContext(ts.transpileModule('exports.Probe=class{'+selected.map(n=>n.getText(tree).replace(/@Builder\s*/g,'')).join('\n')+'}',
    {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{exports,console,...globals});
  return new exports.Probe();
}
test('Guess execution sheet maintains separate Codex and phone drafts and limits',async()=>{
  const suggestion={title:'研究主题',task:'打开浏览器搜索研究主题',reason:'了解最新研究',category:'learning',evidence:[]};
  const helpers=load(base+'pages/home/HomeTaskSuggestion');const calls=[];
  const page=methodProbe('components/HomeTaskExecutionSheet.ets','HomeTaskExecutionSheet',
    ['aboutToAppear','descriptionLimit','draft','execute','selectMethod'],{...helpers,AppLogger:{warnCause(){}}});
  Object.assign(page,{suggestion,method:'phone',submitting:false,onExecute:async(method,draft)=>{calls.push([method,draft]);return true;}});
  page.aboutToAppear();const original=page.phoneDraft;page.selectMethod('codex');assert.equal(page.descriptionLimit(),1000);
  page.codexDraft='制作一份详细的研究PPT';await page.execute();assert.deepEqual(calls[0],['codex','制作一份详细的研究PPT']);
  page.selectMethod('phone');assert.equal(page.descriptionLimit(),60);assert.equal(page.draft(),original);
});
test('Guess execution route delegates with the edited goal and original evidence before any GUI dispatch',async()=>{
  const handoff=load(base+'pages/home/HomeCodexHandoff');let props,captured;
  const page=methodProbe('pages/home/HomePage.ets','HomePage',['TaskExecutionSheetContent'],{
    HomeTaskExecutionSheet:value=>props=value,...handoff,buildHomeTaskExecutionRequest:()=>{throw Error('GUI route must not run');}});
  const item={id:'guess',title:'研究主题',task:'打开浏览器',reason:'想了解',category:'learning',evidence:[{title:'资料',summary:'相关线索',eventId:'e1'}]};
  Object.assign(page,{executionCandidate:item,executionSheetOpen:true,codexBusy:false,agentTaskSubmitting:false,delegateToCodex:async request=>captured=request});
  page.TaskExecutionSheetContent();assert(await props.onExecute('codex','做研究汇报PPT'));
  assert.equal(captured.userGoal,'做研究汇报PPT');assert.equal(captured.evidence[0].eventId,'e1');assert.equal(page.executionSheetOpen,false);
});
test('preparation Agent can retrieve real index events without consulting the profile',async()=>{
  let reads=0;const event={event_id:'indexed-calendar',event_date:'2026-11-07',sources:['calendar'],
    normalized_fact:'与同事讨论端侧智能体',summary:'',calendar:{}};
  const c=client((options,n)=>{
    if(n===1){const call={id:'q-index',type:'function',function:{name:'query_events',arguments:'{"keywords":["智能体"]}'}};
      return{content:'',toolCalls:[call],assistantMessage:{role:'assistant',content:'',tool_calls:[call]},finishReason:'tool_calls'};}
    const facts=JSON.parse(options.messages.find(m=>m.role==='tool').content).facts;
    assert.equal(facts.length,1);return final(JSON.stringify({selected_ids:[facts[0].id,'invented']}));
  });
  const ctx=context(()=>{throw Error('profile must remain lazy');});ctx.hasIndexes=()=>true;
  ctx.queryEvents=options=>{reads++;assert.equal(options.limit,12);return{events:[event],events_truncated:false,total_events:1};};
  const result=await new CodexTaskPreparation(c).prepare('准备我的会议材料',config,ctx);
  assert.equal(reads,1);assert.equal(result.count,1);assert.match(result.task,/indexed-calendar/);
  assert.match(result.task,/不证明已完成或已出席/);assert(result.task.startsWith('准备我的会议材料'));
});
test('preparation Agent uses semantic expansion, indexed recall, ranking and final evidence selection',async()=>{
  const event={event_id:'meal-42',event_date:'2026-11-04',sources:['wechat'],summary:'用户偏好清淡饮食'};
  let recalls=0;const c=client((options,n)=>{
    if(n===1){const call={id:'q-semantic',type:'function',function:{name:'search_memory',arguments:'{"query":"我的口味偏好"}'}};
      return{content:'',toolCalls:[call],assistantMessage:{role:'assistant',content:'',tool_calls:[call]},finishReason:'tool_calls'};}
    if(n===2)return final('{"queries":[{"keywords":["清淡","饮食"],"domains":["eat"]}]}');
    if(n===3){const data=JSON.parse(options.messages[1].content);assert.equal(data.candidates[0].id,'candidate-1');
      return final('{"selected_ids":["candidate-1"]}');}
    const tool=JSON.parse(options.messages.find(m=>m.role==='tool').content);
    assert.equal(tool.mode,'semantic');return final(JSON.stringify({selected_ids:[tool.facts[0].id]}));
  });
  const ctx=context(()=>{throw Error('must use the event index');});ctx.hasIndexes=()=>true;
  ctx.queryEvents=options=>{recalls++;assert(options.keywords.includes('清淡'));return{events:[event],total_events:1,events_truncated:false};};
  const result=await new CodexTaskPreparation(c).prepare('按我的口味制定菜单',config,ctx);
  assert.equal(recalls,1);assert.equal(c.requests.length,4);assert.equal(result.count,1);assert.match(result.task,/meal-42/);
  assert.match(result.task,/清淡饮食/);
});
test('Word/PPT delivery rule remains distinct from source code and short replies',()=>{
  const text=codexTaskWithDeliveryPolicy('制作说明材料');assert(text.startsWith('制作说明材料'));
  assert.match(text,/Word（\.docx）/);assert.match(text,/PowerPoint（\.pptx）/);assert.match(text,/不要以 \.txt/);
  assert.match(text,/不要仅改扩展名/);assert.match(text,/程序源码、配置及数据/);assert.match(text,/简短答复/);
});
test('chat and Home share the Index preparation hook and cancellation is propagated before dispatch',async()=>{
  let page,profileReads=0,prepared=0,fail=false;const notices=[];
  class Preparation{
    async prepare(task,selected,ctx){assert.equal(selected,config);assert.equal(ctx.readProfile(),profile);assert.equal(ctx.readPeople()[0].values.name,'当前手填资料');assert(!ctx.isCancelled());
      assert.equal(page.codexPreparation,this);prepared++;if(fail)throw Error('stopped');
      return{task:task+'\nVERIFIED PROFILE',count:1,notice:'已补充 1 条相关画像信息',memories:[profileMemorySupplement('工作：研究端侧智能体。')]};}
  }
  const service={async execute(request,execution){const task=await execution.prepareTask(request.task);
    assert.match(task,/VERIFIED PROFILE/);assert.equal(request.continueRunId,'');return{runId:'',status:'completed',files:[],received:0};}};
  page=methodProbe('pages/Index.ets','Index',['runCodexTaskForChatSession'],{
    CodexTaskPreparation:Preparation,CodexChatService:{get:()=>service},AiServiceAccess:{isAllowed:()=>true},
    ChatSessionStorage:{sessionExists:()=>true},PersonMemoryStore:class{constructor(dir){assert.equal(dir,'/app');}people(){return[{values:{name:'当前手填资料'}}];}},
    Date,CHAT_MESSAGE_KIND_CONTEXT_NOTICE:'notice',createChatMessage:(...args)=>args});
  Object.assign(page,{filesDir:'/app',cloudChatCancelRequested:false,getCloudConfig:()=>config,nextChatMessageId:()=> 'prepare-message',
    dataManagerFacade:{loadProfileMarkdown:()=>{profileReads++;return profile;}},appendChatMessageToExactSession:()=>{},
    updateChatMessageContentForSession:(_session,_id,text,_trace,memories)=>notices.push({text,memories}),appendCloudLogToSession:()=>{}});
  await page.runCodexTaskForChatSession('chat',{task:'制作研究PPT',continueRunId:''},[]);
  assert.equal(prepared,1);assert.equal(profileReads,1);assert.equal(page.codexPreparation,null);assert.match(notices[0].text,/已补充/);
  assert.equal(notices[0].memories.length,1);assert.match(notices[0].memories[0].content,/端侧智能体/);
  fail=true;await assert.rejects(page.runCodexTaskForChatSession('chat',{task:'继续任务',continueRunId:''},[]),/stopped/);
  assert.equal(page.cloudChatCancelRequested,true);assert.equal(page.codexPreparation,null);
});
test('supplement cards describe only accepted index facts and do not alter the model candidate protocol',async()=>{
  const events=[{event_id:'internal-source-1',event_date:'2026-11-05',sources:['微信'],summary:'陈禾计划参加行业会议',normalized_fact:'陈禾计划下周参加行业会议。',
    chat_attribution:{subject:'other',subject_name:'陈禾',status:'pending'}},
    {event_id:'unselected-secret',event_date:'2026-11-05',sources:['其他'],summary:'UNSELECTED_PRIVATE'}];
  const c=client((options,n)=>{
    if(n===1){const call={id:'events',type:'function',function:{name:'query_events',arguments:'{}'}};
      return{content:'',toolCalls:[call],assistantMessage:{role:'assistant',content:'',tool_calls:[call]},finishReason:'tool_calls'};}
    const facts=JSON.parse(options.messages.find(m=>m.role==='tool').content).facts;
    assert.deepEqual(Object.keys(facts[0]).sort(),['id','text']);return final(JSON.stringify({selected_ids:[facts[0].id,'unknown']}));
  });
  const ctx=context();ctx.hasIndexes=()=>true;ctx.queryEvents=()=>({events,total_events:events.length,events_truncated:false});
  const result=await new CodexTaskPreparation(c).prepare('整理会议计划',config,ctx);
  assert.equal(result.count,1);assert.equal(result.memories.length,result.count);assert.equal(result.memories[0].subject,'陈禾');
  assert.equal(result.memories[0].status,'待办事项');assert.equal(result.memories[0].source,'微信');
  assert(!JSON.stringify(result.memories).includes('internal-source'));assert(!JSON.stringify(result.memories).includes('UNSELECTED_PRIVATE'));
});
test('supplement display uses readable fields and preserves attribution without exposing JSON or source paths',()=>{
  const item=eventMemorySupplement({event_date:'2026-11-05',summary:'```json\n{"summary":"了解项目进展"}\n```',
    normalized_fact:'{"description":"计划整理项目进展，尚未完成。"}',sources:['/app/private/index.json','微信'],
    subjects:[{id:'person:father',name:'林远',relation:'father',is_self:false}],fact_source:{authority:'user_confirmed',field:'company'}});
  assert.equal(item.title,'工作单位');assert.equal(item.subject,'林远');assert.equal(item.source,'个人信息');
  assert.equal(item.content,'计划整理项目进展，尚未完成。');assert(!JSON.stringify(item).includes('/app/private'));
  const invalid=eventMemorySupplement({summary:'{"internal_id":123}',sources:[],event_date:'bad'});
  assert(!invalid.content.includes('internal_id'));assert.equal(invalid.date,'');
  assert.equal(profileMemorySupplement('工作：**研究端侧部署**。').content,'研究端侧部署。');
});
test('stored supplement snapshots are bounded and normalize again without changing their content',()=>{
  const item=profileMemorySupplement('工作：关注多模态模型。');
  const normalized=normalizeMemorySupplement(Array(20).fill(item));assert.equal(normalized.length,MEMORY_SUPPLEMENT_MAX_ITEMS);
  const restored=normalizeMemorySupplement(JSON.parse(JSON.stringify(normalized)));assert(sameMemorySupplement(normalized,restored));
  assert.deepEqual(Array.from(normalizeMemorySupplement()),[]);assert.equal(normalizeMemorySupplement([{content:'{"raw":42}'}]).length,0);
});
test('chat storage retains supplement details on the correct notice without changing AI context',()=>{
  const types=load(base+'pages/chat/ChatSessionTypes'),item=profileMemorySupplement('工作：关注多模态模型。');
  const normalizer=methodProbe('utils/ChatSessionStorage.ets','ChatSessionStorage',['normalizeMessages'],{...types,normalizeMemorySupplement});
  const original=types.createChatMessage('prep','system','context_notice','已补充 1 条相关记忆信息',Date.now());original.memorySupplement=[item];
  const other=types.createChatMessage('other','user','chat','一个新问题',Date.now());
  const restored=normalizer.constructor.normalizeMessages(JSON.parse(JSON.stringify([original,other])));
  assert.equal(restored[0].memorySupplement[0].content,item.content);assert.equal(restored[1].memorySupplement,undefined);
  assert(!JSON.stringify(types.buildCloudContextMessages(restored)).includes('关注多模态模型'));
  assert(!JSON.stringify(types.buildCloudContextMessages(restored)).includes('已补充'));
});
test('async memory results update the existing chat row and survive subsequent messages and reopening',()=>{
  const types=load(base+'pages/chat/ChatSessionTypes');
  const {ChatMessageDataSource}=load(base+'pages/chat/ChatMessageDataSource');
  const source=new ChatMessageDataSource();
  const notice=types.createChatMessage('prep','system','context_notice','正在检索个人记忆…',Date.now());
  source.setMessages([notice]);
  const row=source.getData(0),detail=row.detail,key=source.keyFor(row);
  assert.equal(detail.memorySupplement.length,0);
  const item=profileMemorySupplement('工作：研究端侧智能体。');
  const completed={...notice,content:'已补充 1 条相关记忆信息',memorySupplement:[item]};
  source.setMessages([completed]);
  assert.equal(source.getData(0),row);assert.equal(source.getData(0).detail,detail);
  assert.equal(source.keyFor(row),key);assert.equal(detail.memorySupplement[0].content,item.content);
  const snapshot=JSON.parse(JSON.stringify(row.toChatMessage()));
  source.setMessages([snapshot,types.createChatMessage('next','assistant','chat','继续处理',Date.now())]);
  assert.equal(source.getData(0).detail,detail);assert.equal(detail.memorySupplement.length,1);
  const reopened=new ChatMessageDataSource();reopened.setMessages([snapshot]);
  assert.equal(reopened.getData(0).detail.memorySupplement[0].content,item.content);
});
test('a task without personal-information gaps stops after analysis and performs no retrieval',async()=>{
  let reads=0;
  const c=client(()=>{throw Error('No retrieval Agent needed');},()=>final('{"known_information":["只转换文件格式"],"missing_information":[]}'));
  const task='将提供的CSV转换为Excel，保留原表数据';
  const result=await new CodexTaskPreparation(c).prepare(task,config,context(()=>{reads++;return profile;}));
  assert.equal(c.planningRequests.length,1);assert.equal(c.requests.length,0);assert.equal(reads,0);
  assert.equal(result.count,0);assert.equal(result.task,task);
  const planning=c.planningRequests[0];strictTemplateRequest(planning);
  assert.equal(planning.model,'phone-planner');assert.equal(planning.chatTemplateKwargs.enable_thinking,false);
  assert.equal(planning.tools,undefined);assert.equal(planning.logResponseContent,false);
});
test('missing questions drive indexed retrieval and supplied records cannot be attached again under new IDs',async()=>{
  const task='为两位同事规划参加技术会议的行程。已知会议时间和参与人。原文：双方计划下周赴杭州参加技术会议。';
  const plan={known_information:['双方计划下周赴杭州参加技术会议'],missing_information:['双方从哪里出发？','用户对交通工具有什么偏好？']};
  const existing={event_id:'source-event',summary:'已附的会议计划',normalized_fact:'另一种表述的会议经过，来源条目已附在任务里。'};
  const repeated={event_id:'same-text-new-id',normalized_fact:'双方计划下周赴杭州参加技术会议。'};
  const origin={event_id:'origin',normalized_fact:'用户目前常住在上海，出行通常从上海出发。',sources:['个人信息']};
  const preference={event_id:'transport',normalized_fact:'用户中短途出行偏好高铁，通常不选择飞机。',sources:['微信']};
  let queries=0;
  const c=client((options,n)=>{
    strictTemplateRequest(options);
    if(n===1){
      assert(options.messages[1].content.includes(JSON.stringify(plan.missing_information)));
      const call={id:'gaps',type:'function',function:{name:'query_events',arguments:JSON.stringify({keywords:['出发','交通偏好']})}};
      return{content:'',toolCalls:[call],assistantMessage:{role:'assistant',content:'',tool_calls:[call]},finishReason:'tool_calls'};
    }
    const facts=JSON.parse(options.messages.find(m=>m.role==='tool').content).facts;
    assert.equal(facts.length,2);assert(!JSON.stringify(facts).includes('会议经过'));
    return final(JSON.stringify({selected_ids:[facts[0].id,facts[1].id,'source-event','same-text-new-id']}));
  },options=>{assert.equal(JSON.parse(options.messages[1].content).task,task);return final(JSON.stringify(plan));});
  const ctx=context();ctx.suppliedEventIds=['source-event'];ctx.hasIndexes=()=>true;
  ctx.queryEvents=()=>{queries++;return{events:[existing,repeated,origin,preference],total_events:4,events_truncated:false};};
  const result=await new CodexTaskPreparation(c).prepare(task,config,ctx);
  assert.equal(queries,1);assert.equal(result.count,2);assert(result.task.startsWith(task));
  assert.match(result.task,/上海/);assert.match(result.task,/高铁/);assert(!result.task.includes('另一种表述'));
  assert.equal(result.memories.length,2);
});
test('semantic selection gets the gap plan and rejects re-telling as a selection objective',()=>{
  const plan={known_information:['已附研究报告主题和摘要'],missing_information:['用户既往有哪些相关研究成果？']};
  const messages=codexMemorySelectionMessages('制作研究报告',[{id:'event-1',text:'已发表相关工作'}],plan);
  assert.deepEqual(JSON.parse(messages[1].content).memory_plan,plan);
  assert.match(messages[0].content,/补齐任务缺项的新事实/);assert.match(messages[0].content,/同义复述/);
  assert(codexMemoryTextAlreadySupplied('用户中短途出行偏好高铁，通常不选择飞机。','已有资料：用户中短途出行偏好高铁，通常不选择飞机。'));
  assert(!codexMemoryTextAlreadySupplied('用户偏好高铁，同时工作日一般不能出行。','用户偏好高铁。'));
});
test('gap analysis errors and cancellation never fall back to broad personal retrieval',async()=>{
  for(const answer of ['not JSON','{"known_information":[],"missing_information":[12]}']){
    const c=client(()=>{throw Error('must not retrieve');},()=>final(answer));
    const result=await new CodexTaskPreparation(c).prepare('规划一个活动',config,context());
    assert.equal(c.requests.length,0);assert.equal(result.count,0);assert.equal(result.task,'规划一个活动');
    assert.match(result.notice,/缺项分析结果格式不符合要求/);
  }
  let release;const c=client(()=>{throw Error('must not retrieve');},()=>new Promise(resolve=>release=resolve));
  const prep=new CodexTaskPreparation(c,1000),job=prep.prepare('准备材料',config,context());
  await Promise.resolve();prep.cancel();await assert.rejects(job,/已取消/);
  release(final('{"known_information":[],"missing_information":["材料偏好"]}'));
  assert.equal(c.requests.length,0);
});
test('gap plan parsing is bounded and rejects unstructured instructions as a retrieval plan',()=>{
  const plan=parseCodexMemoryPlan('```json\n'+JSON.stringify({known_information:Array(12).fill('已知条件'),missing_information:Array(10).fill('缺少的特定条件')})+'\n```');
  assert.equal(plan.known_information.length,8);assert.equal(plan.missing_information.length,4);
  assert.throws(()=>parseCodexMemoryPlan('{"known_information":[],"missing_information":"查询所有记录"}'));
});
const peopleFixture=()=>[
  {id:'person:self',relation:'self',label:'本人',values:{name:'林舟',home_address:'上海市徐汇区',company:'示例研究所'},updated_at:'2026-11-05T10:00:00',revision:1},
  {id:'person:father',relation:'father',label:'父亲',values:{name:'林远',phone:'FATHER_PHONE_NOT_RELEVANT'},updated_at:'2026-11-05T10:00:00',revision:1},
  {id:'person:partner',relation:'partner',label:'伴侣',values:{name:'陈禾',wechat_name:'禾禾',home_address:'杭州市西湖区'},updated_at:'2026-11-05T10:00:00',revision:1}
];
test('self and mentioned registered people are always included together with the selected profile even with no gaps',async()=>{
  const people=peopleFixture();let profileReads=0;
  const c=client(()=>{throw Error('No additional search needed');},options=>{
    const data=JSON.parse(options.messages[1].content);
    assert.match(data.task,/林舟/);assert.match(data.task,/陈禾/);assert(!data.task.includes('FATHER_PHONE_NOT_RELEVANT'));
    assert.equal(data.registered_people.length,2);assert(!JSON.stringify(data.registered_people).includes('杭州市西湖区'));
    return final(JSON.stringify({known_information:['计划共进晚餐'],missing_information:[],profile_domains:['eat'],related_person_ids:['person:partner','invented']}));
  });
  const ctx=context(()=>{profileReads++;return '# 用户画像\n## 吃\n偏好清淡口味，喜欢水果。\n## 办公\nUNRELATED_WORK_PROFILE';});
  ctx.readPeople=()=>people;
  const result=await new CodexTaskPreparation(c).prepare('与禾禾安排晚餐',config,ctx);
  assert.equal(c.requests.length,0);assert.equal(profileReads,1);assert.equal(result.count,3);
  for(const value of ['林舟','陈禾','伴侣','清淡','徐汇区','西湖区'])assert(result.task.includes(value));
  assert(!result.task.includes('FATHER_PHONE_NOT_RELEVANT'));assert(!result.task.includes('UNRELATED_WORK_PROFILE'));
  assert.match(result.task,/不是必须使用的条件/);assert.match(result.task,/确实与本次任务相关时/);assert.match(result.task,/以当前任务为准/);
  assert.equal(result.memories[1].subject,'与本人的关系：伴侣');assert.equal(result.memories.length,result.count);
});
test('profile sections are included directly rather than lost through a keyword match or an empty gap selection',async()=>{
  let reads=0;const c=client(()=>{throw Error('Must not search');},()=>final(JSON.stringify({known_information:[],missing_information:[],profile_domains:['eat','live'],related_person_ids:[]})));
  const ctx=context(()=>{reads++;return '# 用户画像\n## 吃\n- 清淡口味。\n## 住\n- 通勤以住处附近为主。\n## 行\nEXCLUDED_TRAVEL';});ctx.readPeople=()=>peopleFixture();
  const result=await new CodexTaskPreparation(c).prepare('安排一个方便回家的用餐方案',config,ctx);
  assert.equal(result.count,3);assert.equal(reads,1);assert.match(result.task,/清淡口味/);assert.match(result.task,/通勤/);
  assert(!result.task.includes('EXCLUDED_TRAVEL'));assert(!result.task.includes('陈禾'));
});
test('manual references survive model failure and use the latest unsynchronized store values',async()=>{
  const people=peopleFixture(),ctx=context();ctx.readPeople=()=>people;
  const c=client(()=>{throw Error('No retrieval expected');},()=>{throw Error('Cloud HTTP 503');});
  const first=await new CodexTaskPreparation(c).prepare('检查这份代码',config,ctx);
  assert.equal(first.count,1);assert.match(first.task,/徐汇区/);assert.match(first.notice,/HTTP 503/);
  people[0].values.home_address='上海市杨浦区';
  const second=await new CodexTaskPreparation(c).prepare('检查这份代码',config,ctx);
  assert.match(second.task,/杨浦区/);assert(!second.task.includes('徐汇区'));assert.equal(c.requests.length,0);
});
test('registered-person selection handles relationships, rejects unknown IDs and avoids ambiguous nickname matching',()=>{
  const people=peopleFixture();
  assert.deepEqual(Array.from(codexReferencePeople(people,'给爸爸准备一份材料'),p=>p.id),['person:self','person:father']);
  assert.deepEqual(Array.from(codexReferencePeople(people,'与爱人出行'),p=>p.id),['person:self','person:partner']);
  assert.deepEqual(Array.from(codexReferencePeople(people,'准备一份文档',['invented']),p=>p.id),['person:self']);
  people[1].values.wechat_name='同名';people[2].values.wechat_name='同名';
  assert.equal(codexReferencePeople(people,'和同名讨论计划').length,1);
  const selected=codexReferencePeople(people,'和太太讨论计划',['person:partner']);assert.equal(selected.length,2);
});
test('reference composition keeps transport and display counts aligned for more than six reference cards',()=>{
  const refs=codexPersonReferences(peopleFixture(),'与陈禾及父亲讨论活动');
  const domains=['eat','wear','live','travel','work','other'];
  const domainRefs=codexProfileReferences(domains.map(d=>'## '+({eat:'吃',wear:'穿',live:'住',travel:'行',work:'办公',other:'其他'})[d]+'\n领域相关背景。').join('\n'),domains);
  const result=composeCodexReferences('准备活动',refs.concat(domainRefs));assert.equal(result.accepted.length,9);
  assert.equal(normalizeMemorySupplement(JSON.parse(JSON.stringify(result.accepted.map(r=>r.preview)))).length,9);
  const large=composeCodexReferences('中😀'.repeat(6400),refs.concat(domainRefs));
  assert(large.task.startsWith('中😀'.repeat(6400)));assert(large.omitted>0);
  if(large.accepted.length)assert(Buffer.byteLength(JSON.stringify({text:codexTaskWithDeliveryPolicy(large.task)}))<=57000);
});
(async()=>{for(const[name,fn]of tests){await fn();console.log('PASS '+name);}console.log(tests.length+' Codex preparation checks passed');})().catch(e=>{console.error(e);process.exitCode=1;});
