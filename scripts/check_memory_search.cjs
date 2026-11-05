// Focused, offline checks. No device, real model, index rebuild or build tools.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript'),root=path.resolve(__dirname,'..'),base='entry/src/main/ets/',cache=new Map();
function load(relative){
  const file=path.resolve(root,relative.endsWith('.ets')?relative:relative+'.ets');if(cache.has(file))return cache.get(file);
  if(path.basename(file)==='CloudModelClient.ets')return{cloudPlannerApiKey:c=>c.plannerApiKey};
  const exports={};cache.set(file,exports);
  const output=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}});
  vm.runInNewContext(output.outputText,{exports,console,Date,require:id=>{
    if(id==='@kit.ArkTS')return{JSON};if(!id.startsWith('.'))throw Error('Unexpected '+id);
    return load(path.resolve(path.dirname(file),id));
  }},{filename:file});return exports;
}
const {MemorySemanticSearch,parseMemorySearchArguments,memoryEventText}=load(base+'datamanager/MemorySemanticSearch');
const {createMemorySearchTool}=load(base+'datamanager/MemorySearchTool');
const links=load(base+'pages/codex/CodexMarkdownLinks'),{parseMarkdown}=load(base+'utils/markdown/MarkdownParser');
const config={plannerBaseUrl:'https://planner.example',plannerApiKey:'test-key',plannerModel:'phone-planner'};
const event=(id,text='偏好清淡饮食')=>({event_id:id,event_date:'2026-11-05',sources:['微信'],summary:text,normalized_fact:text});
const result=events=>({events,total_events:events.length,events_truncated:false});
function client(plan,rank){return{calls:[],async chatCompletion(options){this.calls.push(options);return{content:JSON.stringify(this.calls.length===1?plan:rank),finishReason:'stop'};}};}
const tests=[];const test=(name,fn)=>tests.push([name,fn]);
test('semantic retrieval expands non-literal queries, keeps explicit filters and only returns indexed evidence',async()=>{
  const queries=[],item=event('meal');item.chat_attribution={subject:'other',subject_name:'同事',action_owner:'other',action_owner_name:'同事',status:'pending'};
  const c=client({queries:[{keywords:['清淡','饮食'],domains:['eat']}],broad_domains:['eat']},{selected_ids:['candidate-1']});
  const args=parseMemorySearchArguments('{"query":"我的口味","domains":["work"],"entities":[{"type":"person","name":"同事"}],"month":"2026-11","subject_ids":["person:mother"]}');
  const found=await new MemorySemanticSearch(options=>{queries.push(options);return result([item]);},c,config,()=>{}).search(args);
  assert.equal(found.mode,'semantic');assert.equal(found.events[0].event_id,'meal');assert.equal(c.calls.length,2);
  for(const q of queries){assert.deepEqual(Array.from(q.domains),['work']);assert.equal(q.month,'2026-11');assert(q.entities.length);assert.deepEqual(Array.from(q.subjectIds),['person:mother']);}
  assert.equal(queries[0].keywordOperator,'or');assert(queries[0].keywords.includes('清淡'));assert.equal(queries[1].keywords.length,0);
  assert(c.calls.every(call=>call.model==='phone-planner'&&call.chatTemplateKwargs.enable_thinking===false));
  assert.match(memoryEventText(item),/行动人：同事；状态：pending/);
});
test('malformed or invented ranking IDs degrade explicitly; legitimate empty results stay empty',async()=>{
  for(const rank of [{selected_ids:['invented']},{selected_ids:[123]},{not_ids:[]}]){
    const c=client({queries:[{keywords:['饮食']}]},rank);
    const found=await new MemorySemanticSearch(()=>result([event('real')]),c,config,()=>{}).search(parseMemorySearchArguments('{"query":"口味"}'));
    assert.equal(found.mode,'index_fallback');assert.equal(found.events[0].event_id,'real');assert.match(found.notice,/未完成/);
  }
  const c=client({queries:[{keywords:['饮食']}]},{selected_ids:[]});
  const found=await new MemorySemanticSearch(()=>result([event('real')]),c,config,()=>{}).search(parseMemorySearchArguments('{"query":"口味"}'));
  assert.equal(found.mode,'semantic');assert.equal(found.events.length,0);
});
test('recall, ranking input and serialized tool payloads remain bounded and disclose truncation',async()=>{
  const all=Array.from({length:36},(_,i)=>event('e'+i,'内容'.repeat(700)));
  const c=client({queries:[{keywords:['资料']}]},{selected_ids:['candidate-1']});
  const found=await new MemorySemanticSearch(()=>result(all),c,config,()=>{}).search(parseMemorySearchArguments('{"query":"我的资料"}'));
  assert.equal(found.truncated,true);assert(Buffer.byteLength(c.calls[1].messages[1].content)<24000);
  assert(JSON.parse(c.calls[1].messages[1].content).candidates.length<=16);
  const tool=createMemorySearchTool(async()=>({events:all,mode:'semantic',truncated:false,notice:'有限候选'}));
  const text=await tool.execute('{"query":"资料"}',{});const payload=JSON.parse(text);
  assert(text.length<=3500);assert(payload.truncated);assert(payload.events.length<=6);assert(payload.events.length>0);
});
test('ownership and planned status survive long fact clipping; cancellation never returns stale candidates',async()=>{
  const e=event('long','内容'.repeat(3000));e.calendar={};e.todo={text:'开会',deadline:'2026-11-07'};
  e.chat_attribution={subject_name:'同事',action_owner_name:'同事',status:'pending'};
  const text=memoryEventText(e);assert.match(text,/行动人：同事/);assert.match(text,/不证明已完成/);assert.match(text,/2026-11-07/);
  let cancelled=false;const c={async chatCompletion(){cancelled=true;throw Error('network');}};
  const search=new MemorySemanticSearch(()=>{throw Error('must not read');},c,config,()=>{if(cancelled)throw Error('cancelled');});
  await assert.rejects(search.search(parseMemorySearchArguments('{"query":"资料"}')),/cancelled/);
  assert.throws(()=>parseMemorySearchArguments('{"query":"资料","illegal":true}'));
});
function boundedProbe(){
  const text=fs.readFileSync(path.join(root,base+'datamanager/IndexService.ets'),'utf8');
  const tree=ts.createSourceFile('IndexService.ts',text,ts.ScriptTarget.Latest,true);
  const klass=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='IndexService');
  const method=klass.members.find(n=>ts.isMethodDeclaration(n)&&n.name.getText(tree)==='queryBounded');
  const exports={};vm.runInNewContext(ts.transpileModule('exports.Probe=class{'+method.getText(tree)+'}',
    {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{exports});
  const probe = new exports.Probe();probe.withCurrentFacts=(_options,history)=>history;return probe;
}
test('interactive index retrieval reads at most eight matching monthly partitions and no raw history',()=>{
  const probe=boundedProbe(),docs={},reads=[],options={month:'2025-01'};
  for(let i=1;i<=12;i++){const month='2025-'+String(i).padStart(2,'0');docs[month]={event_ids:['e'+i]};}
  let candidates=Array.from({length:12},(_,i)=>'e'+(i+1));
  Object.assign(probe,{ensureCommitted(){},queryCandidateIds(_options,legacy){assert.equal(legacy,false);return candidates;},
    loadTemporalDocuments:()=>docs,temporalDays:()=>[],paths:{eventPartitionPath:m=>m},
    readWantedEventsFromPartition(month,ids,out){reads.push(month);for(const id of docs[month].event_ids)if(ids[id])out[id]=event(id);},
    filterCurrentCalendarEvents:events=>events,queryWithEvents:(_o,events)=>result(Object.values(events))});
  let found=probe.queryBounded(options);assert.equal(reads.length,8);assert(found.events_truncated);assert.equal(found.events.length,8);
  reads.length=0;candidates=['e1'];found=probe.queryBounded(options);
  assert.deepEqual(reads,['2025-01']);assert.equal(found.events.length,1);assert.equal(found.events_truncated,false);
  reads.length=0;candidates=Array.from({length:12},(_,i)=>'e'+(i+1));found=probe.queryBounded(options,2);
  assert.equal(reads.length,2);assert(found.events_truncated);assert.deepEqual(options,{month:'2025-01'});
});
test('Markdown supports formatted blocks and never loses the original expanded answer',()=>{
  const source='# 标题\n\n**重点**和`code`\n\n- 第一项\n- 第二项\n\n> 引用\n\n```js\nconst x=1;\n```\n\n|列1|列2|\n|---|---|\n|A|B|\n\n[报告](outputs/report.docx)';
  const blocks=parseMarkdown(source),types=Array.from(blocks,b=>b.type);
  for(const type of ['heading','paragraph','list','quote','code','table'])assert(types.includes(type),types.join(','));
  const long=source+'\n\n'+('😀'.repeat(2000));assert.equal(links.codexMarkdownExcerpt(long,true),long);
  const excerpt=links.codexMarkdownExcerpt(long,false);assert(excerpt.length<=1600);assert(!/[\uD800-\uDBFF]$/.test(excerpt));
  for(const file of ['CodexChatRunCard.ets','CodexPage.ets']){
    const text=fs.readFileSync(path.join(root,base+'pages/codex/'+file),'utf8');assert.match(text,/MarkdownView\(/);assert.match(text,/onLinkClick:/);
  }
});
test('Markdown file links resolve only unique declared deliveries; arbitrary schemes cannot open local files',()=>{
  const artifacts=[{id:'r',name:'report.docx'},{id:'i',name:'示意 图.png'}];
  for(const target of ['outputs/report.docx','C:\\work\\report.docx','sandbox:/mnt/data/report.docx','file:///work/report.docx'])
    assert.equal(links.codexLinkedArtifact(target,artifacts)?.id,'r');
  assert.equal(links.codexLinkedArtifact('outputs/%E7%A4%BA%E6%84%8F%20%E5%9B%BE.png',artifacts)?.id,'i');
  for(const target of ['javascript:report.docx','data:report.docx','https://host/report.docx','custom:/report.docx','outputs/unknown.docx','#report.docx'])
    assert.equal(links.codexLinkedArtifact(target,artifacts),undefined);
  assert.equal(links.codexLinkedArtifact('report.docx',artifacts.concat([{id:'r2',name:'report.docx'}])),undefined);
  assert(links.codexWebLink('https://example.org/file'));assert(!links.codexWebLink('javascript:alert(1)'));
});
(async()=>{for(const[name,fn]of tests){await fn();console.log('PASS '+name);}console.log(tests.length+' memory/Markdown checks passed');})().catch(e=>{console.error(e);process.exitCode=1;});
