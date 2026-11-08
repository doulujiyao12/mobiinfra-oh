// Focused production search simulations: no device, account, network or HAP build.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript'),root=path.resolve(__dirname,'..'),base='entry/src/main/ets/utils/recording/';
process.env.TZ='Asia/Shanghai';
let handler=null,calls=[],cancelled=0,allowed=true;const cache=new Map(),logs=[];
const cloudConfig={plannerBaseUrl:'https://cloud.example.invalid/v1',plannerModel:'cloud-model',plannerApiKey:'fixture-key'};
const mocks={
  'CloudModelClient.ets':{CloudModelClient:class{async chatCompletion(options){calls.push(options);return handler(options,calls.length);}cancelActiveRequests(){cancelled++;}},cloudPlannerApiKey:()=>cloudConfig.plannerApiKey},
  'ChatCloudConfig.ets':{readChatCloudConfig:()=>cloudConfig},
  'AiServiceAccess.ets':{AiServiceAccess:{requireAllowed(){if(!allowed)throw Error('请先登录');}}},
  'AppLogger.ets':{AppLogger:{info:(_tag,message)=>logs.push(message),warn:(_tag,message)=>logs.push(message)}}
};
function load(name){
  const file=path.resolve(root,name.endsWith('.ets')?name:name+'.ets');
  if(mocks[path.basename(file)])return mocks[path.basename(file)];
  if(cache.has(file))return cache.get(file);
  const result=ts.transpileModule(fs.readFileSync(file,'utf8'),{fileName:file.replace(/\.ets$/,'.ts'),reportDiagnostics:true,
    compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}});
  assert.equal((result.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,file);
  const exports={};cache.set(file,exports);
  vm.runInNewContext(result.outputText,{exports,Date,Map,Set,require:id=>id==='@kit.ArkTS'?{JSON}:
    id.startsWith('.')?load(path.relative(root,path.resolve(path.dirname(file),id))):(()=>{throw Error('Unexpected dependency '+id);})()},{filename:file});
  return exports;
}
const search=load(base+'RecordingSearch'),{RecordingSearchService}=load(base+'RecordingSearchService');
const clone=value=>JSON.parse(JSON.stringify(value));
const record=(id,date='2026-10-30T12:00:00+08:00',text='')=>({schema:1,id,title:'项目讨论 '+id,createdAt:date,source:'录制',duration:100,
  analysis:{modelId:'fixture',duration:100,speech:[],speakers:[{id:0,name:'同事甲',seconds:80,embedding:[99]}],
    segments:text?[{id:0,start:20,end:30,speaker:0,text,language:'zh'}]:[]}});
const summary=text=>({title:'研究进展',overview:text,keyPoints:[],decisions:[],actionItems:[],openQuestions:[],model:'local-summary',generatedAt:'2026-10-30'});
const reply=value=>({content:JSON.stringify(value),finishReason:'stop'});
const plan=(words=['海水淡化'],start='2026-10-26',end='2026-11-01')=>reply({start_date:start,end_date:end,keywords:words});
const answer=()=>reply({answer:'讨论了研究方案。[1]',source_ids:['r1']});
const now=new Date('2026-11-07T12:00:00+08:00');
const cases=[];function test(name,run){cases.push([name,run]);}
function reset(){handler=null;calls=[];cancelled=0;allowed=true;logs.length=0;}

test('literal search scans title, summaries, named speakers and the end of a long transcript without fuzzy matching',()=>{
  const a=record('a',undefined,'只讨论太阳能'),b=record('b',undefined,'海水淡化膜工艺');b.summary=summary('环境研究');
  b.summary.sections=[{index:0,start:0,end:30,summary:summary('新材料 A+B[1]')}];b.audioDeleted=true;
  a.analysis.segments=Array.from({length:500},(_,i)=>({id:i,start:i*20,end:i*20+10,speaker:0,text:i===499?'尾部关键词':'普通段落',language:'zh'}));
  assert.deepEqual(clone(search.searchRecordingKeywords([a,b],['尾部关键词']).map(h=>h.recordId)),['a']);
  assert.equal(search.searchRecordingKeywords([a,b],['脱盐']).length,0,'No semantic expansion in literal mode');
  assert.deepEqual(clone(search.searchRecordingKeywords([a,b],['A+B[1]']).map(h=>h.recordId)),['b'],'Query is not a regex');
  assert.equal(search.searchRecordingKeywords([a,b],['同事甲']).length,2);
  assert.equal(search.searchRecordingKeywords([a,b],['海水淡化膜工艺']).length,1);
  assert.equal(search.searchRecordingKeywords([a,b],['海水淡化 太阳能']).length,0,'Whole input is one exact phrase');
  assert.equal(search.searchRecordingKeywords([a,b],['   ']).length,0);
});

test('local calendar ranges are inclusive and natural-week references survive month and year boundaries',()=>{
  const clock=search.recordingSearchClock(now);
  assert.equal(clock.weekday,'星期六');assert.equal(clock.last_week_start,'2026-10-26');assert.equal(clock.last_week_end,'2026-11-01');
  assert.equal(search.recordingSearchClock(new Date('2027-01-01T12:00:00+08:00')).last_month_end,'2026-12-31');
  const parsed=search.parseRecordingSearchPlan({start_date:'2026-11-02',end_date:'2026-11-02',keywords:[]});
  assert(search.recordingSearchInRange(record('edge','2026-11-01T16:00:00.000Z'),parsed));
  assert(!search.recordingSearchInRange(record('before','2026-11-01T15:59:59.000Z'),parsed));
  for(const [start,end]of [['2026-02-30',''],['2026-11-07','2026-11-01']])
    assert.throws(()=>search.parseRecordingSearchPlan({start_date:start,end_date:end,keywords:[]}),/日期/);
});

test('AI planning uses only cloud settings, local text retrieval and bounded evidence with valid result IDs',async()=>{
  const records=[record('matched',undefined,'海水淡化采用膜技术'),record('outside','2026-11-05T12:00:00+08:00','海水淡化新方案')];
  const original=JSON.stringify(records),updates=[];
  handler=async(options,index)=>{
    assert.equal(options.baseUrl,cloudConfig.plannerBaseUrl);assert.equal(options.model,'cloud-model');
    assert.equal(options.logResponseContent,false);assert.equal(options.chatTemplateKwargs.enable_thinking,false);
    const input=JSON.parse(options.messages[1].content);
    if(index===1){assert.equal(input.reference.last_week_start,'2026-10-26');assert.equal(input.recordings,undefined);return plan();}
    assert.equal(input.recordings.length,1);assert.equal(input.recordings[0].id,'r1');assert.equal(input.recordings[0].number,1);
    assert.ok(input.recordings[0].excerpts[0].includes('海水淡化'));
    assert.ok(!options.messages[1].content.includes('embedding'));return answer();
  };
  const result=await new RecordingSearchService().search('上周聊了哪些海水淡化方案？',records,text=>updates.push(text),()=>{},now);
  assert.equal(calls.length,2);assert.deepEqual(clone(result.hits.map(h=>h.recordId)),['matched']);
  assert.match(result.answer,/\[1\]/);assert.equal(result.range,'2026-10-26 至 2026-11-01');assert.equal(JSON.stringify(records),original);
});

test('metadata fallback examines every in-range batch and never sends full transcripts',async()=>{
  const records=Array.from({length:14},(_,i)=>record('record-'+i));records[12].summary=summary('新型膜材料试验进展');
  let selectionCalls=0;
  handler=async(options,index)=>{
    const input=JSON.parse(options.messages[1].content);
    if(index===1)return plan(['脱盐']);
    if(options.messages[0].content.includes('哪些录音可能相关')){
      selectionCalls++;assert(input.recordings.length<=12);assert(input.recordings.every(r=>!r.excerpts&&!r.analysis));
      return reply({matches:input.recordings.filter(r=>r.id==='r13').map(r=>({id:r.id,reason:'讨论膜材料研究'}))});
    }
    return answer();
  };
  const result=await new RecordingSearchService().search('找脱盐相关讨论',records,()=>{},()=>{},now);
  assert.equal(selectionCalls,2);assert.equal(calls.length,4);assert.equal(result.hits[0].recordId,'record-12');
});

test('empty matches are distinguished from AI selection failures and unknown IDs cannot become recording paths',async()=>{
  handler=async(_options,index)=>index===1?plan(['不存在的词']):reply({matches:[]});
  const empty=await new RecordingSearchService().search('找不存在的词',[record('a')],()=>{},()=>{},now);
  assert.equal(empty.hits.length,0);assert.match(empty.notice,/没有找到/);assert.equal(calls.length,2);
  reset();handler=async(_options,index)=>index===1?plan(['不存在的词']):reply({matches:[{id:'../../private',reason:'伪造'}]});
  await assert.rejects(new RecordingSearchService().search('找不存在的词',[record('a')],()=>{},()=>{},now),/格式/);
  assert.equal(calls.length,3);
});

test('answer failures retain matching recordings and do not publish hallucinated sources',async()=>{
  handler=async(_options,index)=>index===1?plan():reply({answer:'没有依据的回答',source_ids:['foreign']});
  const result=await new RecordingSearchService().search('海水淡化',[record('a',undefined,'海水淡化')],()=>{},()=>{},now);
  assert.equal(result.hits[0].recordId,'a');assert.equal(result.answer,'');assert.match(result.notice,/回答暂未完成/);
  assert.equal(calls.length,3);
});

test('time-only searches need no invented keywords and explain bounded answer coverage',async()=>{
  const records=Array.from({length:9},(_,i)=>record('a'+i));
  handler=async(options,index)=>{
    if(index===1)return plan([]);
    assert.equal(JSON.parse(options.messages[1].content).recordings.length,6);return answer();
  };
  const result=await new RecordingSearchService().search('上周有哪些录音',records,()=>{},()=>{},now);
  assert.equal(result.hits.length,9);assert.match(result.notice,/前 6 段/);assert.equal(calls.length,2);
});

test('cancelled searches and login rejection cannot start follow-up requests or publish stale hits',async()=>{
  let release;handler=()=>new Promise(resolve=>{release=resolve;});
  const service=new RecordingSearchService(),published=[];
  const pending=service.search('海水淡化',[record('a',undefined,'海水淡化')],()=>{},hits=>published.push(hits),now);
  service.cancel();release(plan());await assert.rejects(pending,/停止/);assert.equal(calls.length,1);assert.equal(published.length,0);
  allowed=false;await assert.rejects(new RecordingSearchService().search('查找',[record('a')],()=>{},()=>{},now),/登录/);
  assert.equal(calls.length,1);
});

test('UI query changes invalidate in-flight results, and literal search never invokes an AI service',async()=>{
  const page=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),'utf8').replace('struct RecordingPage','class RecordingPage');
  const tree=ts.createSourceFile('page.ts',page,ts.ScriptTarget.Latest,true),component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='RecordingPage');
  const names=['recordingSearchActive','stopRecordingSearch','changeRecordingSearch','runRecordingSearch','recordingSearchNumber'];
  const methods=names.map(name=>component.members.find(n=>n.name?.text===name).getText(tree)).join('\n');
  const exports={};vm.runInNewContext(ts.transpileModule('exports.Page=class {'+methods+'}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
    {exports,searchRecordingKeywords:search.searchRecordingKeywords});
  let release,searchCalls=0;const probe=new exports.Page();
  Object.assign(probe,{alive:true,busy:false,recording:false,recordingSearchEpoch:0,recordingAiSearch:false,
    records:[record('a',undefined,'海水淡化')],recordingSearchQuery:'',recordingSearchService:{cancel(){},search(){searchCalls++;return new Promise(resolve=>{release=resolve;});}}});
  probe.changeRecordingSearch('海水淡化');await probe.runRecordingSearch();assert.equal(searchCalls,0);assert.equal(probe.recordingSearchHits.length,1);
  probe.recordingSearchHits=[{recordId:'a'},{recordId:'b'}];assert.equal(probe.recordingSearchNumber('a'),'1');
  probe.recordingSearchHits.reverse();assert.equal(probe.recordingSearchNumber('a'),'2','Source numbers follow the current hit order');
  probe.recordingAiSearch=true;probe.changeRecordingSearch('旧问题');const pending=probe.runRecordingSearch();
  probe.changeRecordingSearch('新问题');release({hits:[{recordId:'a'}],answer:'旧回答',range:'旧范围',notice:''});await pending;
  assert.equal(probe.recordingSearchAnswer,'');assert.equal(probe.recordingSearchHits.length,0);assert.equal(probe.recordingSearchQuery,'新问题');
});

(async()=>{for(const[name,run]of cases){reset();await run();console.log('PASS '+name);}console.log(cases.length+' recording search checks passed');})()
  .catch(error=>{console.error(error.stack);process.exitCode=1;});
