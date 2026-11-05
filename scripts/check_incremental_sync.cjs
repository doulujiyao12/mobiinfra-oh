// Production business-logic simulation. No HAP build, account, device or network.
// node scripts/check_incremental_sync.cjs <typescript-module-path>
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..'), base = 'entry/src/main/ets/datamanager/';
const disk = new Map(), directories = new Set(), reads = new Map(), writes = [];
const logs = []; let failWrite = null, cloudHandler = null, calendarEvents = [], calendarIndexEpoch = '', trackSourceChanges = false, hashedChars = 0, debugForTest = false;
const clone = value => JSON.parse(JSON.stringify(value));
class Storage {
  beginReadSession() {} endReadSession() {return 0;}
  join(...parts) { return parts.filter(Boolean).join('/').replace(/\/+/g,'/'); }
  dirname(file) { return path.posix.dirname(file); } basename(file) { return path.posix.basename(file); }
  exists(file) { return disk.has(file) || directories.has(file); }
  isDirectory(file) { return directories.has(file) || [...disk.keys()].some(key=>key.startsWith(file+'/')); }
  ensureDir(file) { directories.add(file); }
  readText(file, fallback='') { reads.set(file,(reads.get(file)||0)+1); return disk.get(file) ?? fallback; }
  readJson(file, fallback) { try { return JSON.parse(this.readText(file)); } catch { return clone(fallback); } }
  writeTextAtomic(file, text) { if(trackSourceChanges)load(base+'MemoryChangeJournal').MemoryChangeJournal.beforeMutation(file,this);if(failWrite?.(file,text)) throw Error('injected write failure'); disk.set(file,text); writes.push(file); }
  writeJsonAtomic(file, value) { this.writeTextAtomic(file,JSON.stringify(value,null,2)+'\n'); }
  removeFile(file) { if(trackSourceChanges)load(base+'MemoryChangeJournal').MemoryChangeJournal.beforeMutation(file,this);disk.delete(file); }
  sha256Text(text) { hashedChars+=text.length;return crypto.createHash('sha256').update(text).digest('hex'); }
  listDir(dir) { return [...new Set([...disk.keys(),...directories].filter(key=>key.startsWith(dir+'/'))
    .map(key=>key.slice(dir.length+1).split('/')[0]))].sort(); }
  findFiles(dir,suffix) { return [...disk.keys()].filter(key=>key.startsWith(dir+'/')&&key.endsWith(suffix)).sort(); }
  relativePath(dir,file) { return path.posix.relative(dir,file); }
  syncJsonDirectory(dir,desired) { Object.keys(desired).forEach(name=>this.writeJsonAtomic(this.join(dir,name),desired[name]));
    this.listDir(dir).filter(name=>name.endsWith('.json')&&desired[name]===undefined).forEach(name=>this.removeFile(this.join(dir,name))); }
}
const mocks = {
  'DataManagerStorage.ets': {DataManagerStorage:Storage},
  'DataManagerLog.ets': {dataManagerInfo:line=>logs.push(line),dataManagerWarn:line=>logs.push(line),dataManagerError:line=>logs.push(line)},
  'DebugSettings.ets': {DebugSettings:{isEnabled:()=>debugForTest}},
  'CalendarMemoryStore.ets': {CalendarMemoryStore:class {events(){return clone(calendarEvents);} fingerprint(){return JSON.stringify(calendarEvents);} indexFingerprint(){return this.fingerprint()+calendarIndexEpoch;}}},
  'DataManagerImageResolver.ets': {DataManagerImageResolver:class {}},
  'AvatarService.ets': {AvatarService:class {}},
  'GalleryMemorySync.ets': {GalleryMemorySync:{imageRefsForSourceRefs:()=>[],dailyLogRelativePaths:()=>[]}},
  'ChatMemorySync.ets': {ChatMemorySync:{dailyLogRelativePaths:()=>[]}},
  'CloudModelClient.ets': {CloudModelClient:class {
    async chatCompletionText(options){const value=await cloudHandler(options);return typeof value==='string'?value:value.content;}
    async chatCompletion(options){const value=await cloudHandler(options);return typeof value==='string'?{content:value,finishReason:'stop'}:value;}
    async chatCompletionStream(options,callbacks={}){
      let updates=0;const emit=value=>{updates++;callbacks.onProgress?.(value);};
      const value=await cloudHandler(options,{onProgress:emit}),result=typeof value==='string'?{content:value,finishReason:'stop'}:value;
      if(!updates)emit({phase:'receiving',responseCode:200,receivedBytes:result.content.length,contentChars:result.content.length,
        reasoningChars:0,contentDelta:result.content,reasoningDelta:'',finishReason:result.finishReason||''});
      callbacks.onProgress?.({phase:'completed',responseCode:200,receivedBytes:result.content.length,contentChars:result.content.length,
        reasoningChars:0,contentDelta:'',reasoningDelta:'',finishReason:result.finishReason||''});
      return result;
    }
  }}
};
const loaded = new Map();
function load(relative) {
  const file=path.resolve(root,relative.endsWith('.ets')?relative:relative+'.ets');
  if(mocks[path.basename(file)]) return mocks[path.basename(file)];
  if(loaded.has(file)) return loaded.get(file);
  const output=ts.transpileModule(fs.readFileSync(file,'utf8').replace(/^@Concurrent\s*$/gm,''),{fileName:file.replace(/\.ets$/,'.ts'),reportDiagnostics:true,
    compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}});
  assert.equal((output.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,file);
  const exports={}; loaded.set(file,exports);
  vm.runInNewContext(output.outputText,{exports,console,Date,setTimeout,clearTimeout,require:id=>{
    if(id==='@kit.ArkTS') return {JSON,taskpool:{execute:async(fn,...args)=>fn(...args)}};
    if(id==='@ohos.file.fs')return {default:{readTextSync:p=>{if(!disk.has(p))throw Error('missing file');return storage.readText(p);},accessSync:p=>storage.exists(p)||storage.isDirectory(p),listFileSync:p=>storage.listDir(p)}};
    if(!id.startsWith('.')) throw Error('Unexpected dependency: '+id);
    return load(path.resolve(path.dirname(file),id));
  }},{filename:file}); return exports;
}
const {ProfileBlockCache}=load(base+'ProfileBlockCache');
const {IndexWriteBatch}=load(base+'IndexWriteBatch');
const {IndexService}=load(base+'IndexService');
const {DataManagerPaths}=load(base+'DataManagerPaths');
const {DataPipelineModelClient}=load(base+'DataPipelineModelClient');
const {ConsolidationService}=load(base+'ConsolidationService');
const {DataManagerFacade}=load(base+'DataManagerFacade');
const {StartupSourceSync}=load('entry/src/main/ets/utils/StartupSourceSync');
const config={enabled:true,baseUrl:'https://model.invalid/v1',model:'model-a',apiKey:'fixture-key-never-persist'};
const storage=new Storage(), paths=new DataManagerPaths('/app',storage);
function reset(){disk.clear();directories.clear();reads.clear();writes.length=0;logs.length=0;failWrite=null;calendarEvents=[];calendarIndexEpoch='';trackSourceChanges=false;hashedChars=0;debugForTest=false;}
function event(id,date='2026-10-01',extra={}) {return {event_id:id,source_state_file:'outputs/'+date.slice(0,7)+'/sample.md.state.json',record_id:1,
  event_date:date,last_seen_date:date,summary:'关注端侧模型研究 '+id,normalized_fact:'关注端侧模型研究 '+id,tags:['模型'],source_refs:['daily/'+id],
  sources:['研究记录'],workflow_scene_ids:[0],image_paths:[],todo:{type:'',deadline:'',text:'',agent_task:''},
  keywords:['模型'],domains:['work'],entity_mentions:[],enrichment_method:'model',entities:[],profile_domains:['work'],...extra};}
function payload(events,final=false){return {short_summary:final?'模型研究':'',summary:final?'关注模型研究':'',generation:final?'model':'model_block',
  claims:[{statement:'关注模型研究与部署',kind:'topic',confidence:'medium',event_ids:events.map(e=>e.event_id).slice(0,10),example:''}]};}
class Model {
  constructor(){this.leaves=[];this.merges=[];this.fail=false;this.enriched=[];}
  profileCacheIdentity(c){return c.baseUrl+':'+c.model+':policy-a';}
  async summarizeProfileBlock(domain,events){this.leaves.push(events.map(e=>e.event_id));if(this.fail)throw Error('model interrupted');return payload(events);}
  async combineProfileBlocks(domain,blocks,events,c,final){this.merges.push({final,ids:events.map(e=>e.event_id)});
    if(this.fail)throw Error('model interrupted');return payload(events,final);}
  async enrichEvents(events){this.enriched.push(...events.map(e=>e.event_id));return events.map(e=>({...e,domains:['work'],enrichment_method:'model'}));}
}
const cases=[];const test=(name,run)=>cases.push([name,run]);
test('profile warm-up, identical sync and a new month reuse independent historical blocks',async()=>{
  reset();const model=new Model(), cache=new ProfileBlockCache(paths,storage,model);
  const input=[event('a','2025-01-01'),event('b','2025-02-01'),event('c','2026-09-01')];
  await cache.build('work',input,config);const leafCalls=model.leaves.length, mergeCalls=model.merges.length;
  await cache.build('work',input,config);assert.equal(model.leaves.length,leafCalls);assert.equal(model.merges.length,mergeCalls);
  assert.equal(cache.stats.reused,cache.stats.total);
  await cache.build('work',[...input,event('d','2026-10-01')],config);
  assert.equal(model.leaves.length-leafCalls,1);assert.deepEqual(clone(model.leaves.at(-1)),['d']);
  assert.ok(model.merges.length-mergeCalls<=5);assert.ok(cache.stats.reused>0);
  assert.ok(![...disk.values()].join('').includes(config.apiKey));
});
test('editing old evidence, deleting a month and deleting all inputs cannot retain stale root facts',async()=>{
  reset();const model=new Model(),cache=new ProfileBlockCache(paths,storage,model);
  const input=[event('a','2025-01-01'),event('b','2026-01-01')];await cache.build('work',input,config);
  let calls=model.leaves.length;await cache.build('work',[{...input[0],normalized_fact:'修改后的事实'},input[1]],config);
  assert.equal(model.leaves.length-calls,1);calls=model.leaves.length;
  const result=await cache.build('work',[input[1]],config);
  assert.ok(result.claims.every(c=>c.event_ids.every(id=>id==='b')));assert.equal(model.leaves.length,calls);
  const empty=await cache.build('work',[],config);assert.equal(empty.generation,'empty');assert.equal(empty.claims.length,0);
});
test('reordered records and API-key edits preserve caches; model, URL and policy changes invalidate them',async()=>{
  reset();const model=new Model(),cache=new ProfileBlockCache(paths,storage,model);
  const input=[event('a'),event('b')];await cache.build('work',input,config);let calls=model.leaves.length;
  await cache.build('work',input.slice().reverse(),{...config,apiKey:'different-fixture'});assert.equal(model.leaves.length,calls);
  for(const modified of [{...config,model:'model-b'},{...config,baseUrl:'https://different.invalid'}]){
    await cache.build('work',input,modified);assert.ok(model.leaves.length>calls);calls=model.leaves.length;
  }
  model.profileCacheIdentity=()=> 'changed-prompt-policy';await cache.build('work',input,config);assert.ok(model.leaves.length>calls);
});
test('failed parent generation resumes successful children after a simulated process restart',async()=>{
  reset();const model=new Model(), cache=new ProfileBlockCache(paths,storage,model);
  model.combineProfileBlocks=async()=>{throw Error('model interrupted');};
  const input=[event('a','2026-01-01'),event('b','2026-02-01')];
  await assert.rejects(cache.build('work',input,config),/interrupted/);
  const next=new Model();await new ProfileBlockCache(paths,storage,next).build('work',input,config);
  assert.equal(next.leaves.length,0);assert.ok(next.merges.length>0);
});
test('a damaged but parseable checkpoint is rejected and oversized months split deterministically',async()=>{
  reset();const model=new Model(),cache=new ProfileBlockCache(paths,storage,model);
  const input=Array.from({length:130},(_,i)=>event('e'+i));await cache.build('work',input,config);
  assert.ok(model.leaves.every(ids=>ids.length<=48));const counts=model.leaves.length;
  for(const [file,text] of disk){const receipt=JSON.parse(text);receipt.versions.forEach(v=>v.payload.summary='corrupted');disk.set(file,JSON.stringify(receipt));}
  await cache.build('work',input,config);assert.ok(model.leaves.length>counts);
});
test('production block model preserves singleton evidence and marks calendar plans; final profile still needs multiple facts',async()=>{
  reset();const client=new DataPipelineModelClient();
  cloudHandler=async options=>{
    const input=JSON.parse(options.messages[1].content);
    const ids=input.events?.map(e=>e.event_id)||input.candidate_claims.flatMap(c=>c.event_ids);
    return JSON.stringify({short_summary:'模型研究',summary:'关注模型研究',claims:[{statement:'关注模型研究',kind:'topic',confidence:'medium',event_ids:ids}]});
  };
  const input=[event('a','2026-01-01',{calendar:{seriesKey:'x',start:1,end:2,profileEnabled:true}})];
  const block=await client.summarizeProfileBlock('work',input,config);
  assert.equal(block.claims.length,1);assert.ok(block.claims[0].statement.startsWith('[日历安排'));
  const root=await client.combineProfileBlocks('work',[block],input,config,true);assert.equal(root.generation,'model_empty');
  assert.ok(!client.profileCacheIdentity(config).includes(config.apiKey));
  cloudHandler=async()=>JSON.stringify({claims:'invalid'});
  await assert.rejects(client.summarizeProfileBlock('work',input,config),/claims/);
});
test('batch writes stay private until publication and identical/reverted files are not rewritten',()=>{
  reset();const root='/index';storage.writeTextAtomic(root+'/a.json','old');storage.writeTextAtomic(root+'/same.json','same');
  const batch=new IndexWriteBatch(root,storage);batch.writeTextAtomic(root+'/a.json','new');batch.writeTextAtomic(root+'/same.json','same');
  assert.equal(storage.readText(root+'/a.json'),'old');assert.equal(batch.readText(root+'/a.json'),'new');
  batch.writeTextAtomic(root+'/revert.json','new');batch.removeFile(root+'/revert.json');
  batch.commit();assert.equal(storage.readText(root+'/a.json'),'new');assert.equal(batch.written,2);assert.equal(batch.reused,1);
  const revert=new IndexWriteBatch(root,storage);revert.writeTextAtomic(root+'/a.json','wrong');revert.writeTextAtomic(root+'/a.json','new');
  revert.commit();assert.equal(storage.readText(root+'/a.json'),'new');assert.equal(revert.written,0);
  const restored=new IndexWriteBatch(root,storage);restored.removeFile(root+'/a.json');assert.equal(restored.exists(root+'/a.json'),false);
  restored.writeTextAtomic(root+'/a.json','new');assert.equal(restored.exists(root+'/a.json'),true);
  restored.writeTextAtomic(root+'/empty.json','');assert.equal(restored.readText(root+'/empty.json','fallback'),'');
  assert.equal(restored.exists(root+'/empty.json'),true);assert.ok(restored.listDir(root).includes('empty.json'));
  restored.commit();assert.equal(restored.written,1);assert.equal(storage.readText(root+'/empty.json','fallback'),'');
});
test('interrupted publication rolls forward before index readers observe a mixed generation',()=>{
  reset();const root='/index';storage.writeTextAtomic(root+'/a.json','old-a');storage.writeTextAtomic(root+'/b.json','old-b');
  const batch=new IndexWriteBatch(root,storage);batch.writeTextAtomic(root+'/a.json','new-a');batch.writeTextAtomic(root+'/b.json','new-b');
  let count=0;failWrite=file=>file.startsWith(root+'/')&&++count===2;
  assert.throws(()=>batch.commit(),/injected/);assert.ok(storage.exists(root+'.pending-sync/prepared.json'));
  failWrite=null;new IndexService({indexesRoot:root},storage,new Model());
  assert.equal(storage.readText(root+'/a.json'),'new-a');assert.equal(storage.readText(root+'/b.json'),'new-b');
  assert.ok(!storage.exists(root+'.pending-sync/prepared.json'));
});
test('corrupt journals and traversal paths are rejected before changing live files',()=>{
  reset();const root='/index';storage.writeTextAtomic(root+'/a.json','old');
  const marker=root+'.pending-sync/prepared.json';storage.writeTextAtomic(marker,JSON.stringify({schema:'index-commit-v1',mutations:[{relative:'../outside',remove:true}]}));
  assert.throws(()=>IndexWriteBatch.recover(root,storage),/路径/);assert.equal(storage.readText(root+'/a.json'),'old');
  const batchRoot='/other';const batch=new IndexWriteBatch(batchRoot,storage);batch.writeTextAtomic(batchRoot+'/a.json','new');
  failWrite=file=>file===batchRoot+'/a.json';assert.throws(()=>batch.commit(),/injected/);failWrite=null;
  const dataFile=[...disk.keys()].find(key=>key.startsWith(batchRoot+'.pending-sync/')&&key.endsWith('.txt'));
  disk.set(dataFile,'damaged');assert.throws(()=>IndexWriteBatch.recover(batchRoot,storage),/校验/);assert.ok(!disk.has(batchRoot+'/a.json'));
});
test('delta postings match full rebuilds for add, edit, date move and delete across all four indexes',()=>{
  reset();const service=new IndexService(paths,storage,new Model());
  const methods={inverted:'buildInvertedDocument',source:'buildSourceDocument',domain:'buildDomainDocument','workflow-scene':'buildWorkflowSceneDocument'};
  let previous={a:event('a'),b:event('b','2026-09-01'),c:event('c','2025-01-01')};
  for(const [kind,method]of Object.entries(methods))storage.writeJsonAtomic(paths.indexesRoot+'/'+kind+'/index.json',service[method](previous));
  const next={a:event('a','2026-11-01',{keywords:['优化'],summary:'新的研究成果',domains:['travel'],workflow_scene_ids:[1]}),c:previous.c,d:event('d')};
  const changed={a:true,b:true,d:true},oldDelta={a:previous.a,b:previous.b},newDelta={a:next.a,d:next.d};
  for(const [kind,method]of Object.entries(methods)){
    service.writePostingIndex(kind,service[method](oldDelta).postings,service[method](newDelta).postings,next,changed,true);
    assert.deepEqual(clone(storage.readJson(paths.indexesRoot+'/'+kind+'/index.json',null)),clone(service[method](next)),kind);
  }
});
test('unchanged months are not rewritten and moved/deleted months are correctly removed',()=>{
  reset();const service=new IndexService(paths,storage,new Model());
  const input={a:event('a','2026-01-01'),b:event('b','2026-02-01')};service.dirtyMonths={'2026-01':true,'2026-02':true};
  service.writeEventPartitions(input);service.writeTemporalDocuments(input);writes.length=0;
  service.dirtyMonths={'2026-02':true,'2026-03':true};
  service.writeEventPartitions({a:input.a,b:event('b','2026-03-01')});service.writeTemporalDocuments({a:input.a,b:event('b','2026-03-01')});
  assert.ok(!writes.some(file=>file.endsWith('/2026-01.json')));assert.ok(!disk.has(paths.eventPartitionPath('2026-02')));
  assert.ok(disk.has(paths.eventPartitionPath('2026-03')));assert.ok(!disk.has(paths.temporalPath('2026-02')));
});
test('source enrichment checkpoints survive retries but edits and model changes invalidate them',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);const input=[event('a'),event('b')];
  await service.enrichWithCheckpoint(input,config);assert.equal(model.enriched.length,2);
  await new IndexService(paths,storage,model).enrichWithCheckpoint(input,config);assert.equal(model.enriched.length,2);
  await service.enrichWithCheckpoint([{...input[0],normalized_fact:'changed'},input[1]],config);assert.equal(model.enriched.length,3);
  await service.enrichWithCheckpoint(input,{...config,model:'new-model'});assert.equal(model.enriched.length,5);
});
test('one sync shares event partitions and releases the read snapshot afterwards',()=>{
  reset();const service=new IndexService(paths,storage,new Model());service.dirtyMonths={'2026-01':true};
  service.writeEventPartitions({a:event('a','2026-01-01'),b:event('b','2026-01-01')});
  const file=paths.eventPartitionPath('2026-01');reads.clear();service.beginSyncRead();
  for(let i=0;i<8;i++)service.loadEventsByIds(['a']);assert.equal(reads.get(file),1);
  service.endSyncRead();service.loadEventsByIds(['a']);assert.ok(reads.get(file)>1);
});
test('warm-cache model work stays bounded as historical input increases',async()=>{
  const reports=[];
  for(const size of [240,2400]){
    reset();const model=new Model(),cache=new ProfileBlockCache(paths,storage,model);
    const input=Array.from({length:size},(_,i)=>event('e'+i,`${2006+Math.floor(i/120)}-${String(Math.floor(i/10)%12+1).padStart(2,'0')}-01`));
    await cache.build('work',input,config);const old=model.leaves.length,merges=model.merges.length;
    await cache.build('work',[...input,event('new','2006-01-01')],config);
    reports.push({historyEvents:size,newEvents:1,leafCalls:model.leaves.length-old,mergeCalls:model.merges.length-merges});
    assert.equal(model.leaves.length-old,1);assert.ok(model.merges.length-merges<=6);
  }
  console.log('MODEL_WORK_BENCHMARK '+JSON.stringify(reports));
});
test('edited/deleted raw log evidence rebuilds only its source group, without keeping merged old facts',async()=>{
  reset();const service=new ConsolidationService(paths,storage,new DataPipelineModelClient());
  const first={source_date:'2026-10-01',file_name:'shopping.md',entry_index:1,entry_text:'用户买了咖啡，花费20元',workflow_metadata:{},workflow_scene_id:0,source_ref:'2026-10-01/shopping.md#1'};
  const second={...first,entry_index:2,entry_text:'用户买了面包，花费10元',source_ref:'2026-10-01/shopping.md#2'};
  const group={month:'2026-10',fileName:'shopping.md',entries:[first,second]}, disabled={...config,enabled:false};
  let state=await service.consolidateGroup(group,disabled,5);
  assert.equal(service.requiresGroupRebuild(group,state),false);
  const edited={...group,entries:[{...first,entry_text:'用户买了茶，花费8元'},second]};
  assert.equal(service.requiresGroupRebuild(edited,state),true);
  state=await service.consolidateGroup(edited,disabled,5);
  assert.ok(!JSON.stringify(state.records).includes('咖啡'));assert.ok(JSON.stringify(state.records).includes('花费8元'));
  const removed={...group,entries:[second]};assert.equal(service.requiresGroupRebuild(removed,state),true);
  state=await service.consolidateGroup(removed,disabled,5);assert.ok(!JSON.stringify(state.records).includes('花费8元'));
  const idx=new IndexService(paths,storage,new Model());
  storage.writeJsonAtomic(paths.outputsRoot+'/state-index.json',{schema:'datamanager-consolidation-output-state-index-v1',state_paths:[]});
  assert.equal(idx.loadOutputStatePaths().length,0,'Orphaned generated files must not resurrect deleted sources');
});
test('full production index stays unchanged on model failure, resumes event checkpoints, and publishes consistent results',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  const file=paths.outputStatePath('2026-10','shopping.md');
  const record=(id,text)=>({record_id:id,first_seen_date:'2026-10-01',last_seen_date:'2026-10-01',
    source_refs:['2026-10-01/shopping.md#'+id],source_dates:['2026-10-01'],workflow_scene_ids:[0],summary:'工作会议：'+text,
    normalized_fact:'工作会议：'+text,raw_excerpts:[],tags:['会议'],dedup_status:'new',model_notes:[],dedup_text:text});
  const save=records=>storage.writeJsonAtomic(file,{metadata:{},records});
  save([record(1,'关注模型部署'),record(2,'研究量化技术')]);
  await service.build(config);const before=[...disk.entries()].filter(([file])=>file.startsWith(paths.indexesRoot+'/'));
  assert.equal(Object.keys(service.loadEvents()).length,2);
  save([record(1,'关注模型部署'),record(2,'研究量化技术'),record(3,'研究推理优化')]);model.fail=true;
  await assert.rejects(service.build(config),/interrupted/);
  assert.deepEqual([...disk.entries()].filter(([file])=>file.startsWith(paths.indexesRoot+'/')),before);
  const enriched=model.enriched.length;model.fail=false;await service.build(config);
  assert.equal(model.enriched.length,enriched,'Successful event classifications are not paid for again');
  assert.equal(Object.keys(service.loadEvents()).length,3);
  const profile=service.loadProfileState();assert.equal(profile.event_count,3);
  const allowed=new Set(Object.keys(service.loadEvents()));assert.ok(Object.values(profile.domains).every(d=>d.claims.every(c=>c.event_ids.every(id=>allowed.has(id)))));
});
test('legacy index upgrade preserves historical inputs and events, refreshes derived metadata once, then reuses caches',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model),sourceFiles=[];
  for(const month of ['2026-05','2026-07','2026-09']){
    const date=month+'-01',file=paths.outputStatePath(month,'shopping.md');sourceFiles.push(file);
    storage.writeJsonAtomic(file,{metadata:{},records:[1,2].map(id=>({record_id:id,first_seen_date:date,last_seen_date:date,
      source_refs:[date+'/shopping.md#'+id],source_dates:[date],workflow_scene_ids:[0],summary:'工作会议：研究模型部署 '+id,
      normalized_fact:'工作会议：研究模型部署 '+id,raw_excerpts:[],tags:['会议'],dedup_status:'new',model_notes:[],dedup_text:'模型部署 '+id}))});
    const raw=paths.dailyLogRoot+'/'+date+'/shopping.md';sourceFiles.push(raw);storage.writeTextAtomic(raw,'原始采集记录 '+month);
  }
  await service.build(config);
  const beforeIds=Object.keys(service.loadEvents()).sort(),beforeInputs=sourceFiles.map(file=>[file,storage.readText(file)]);
  assert.equal(beforeIds.length,6);
  const manifestPath=paths.indexesRoot+'/manifest.json',manifest=storage.readJson(manifestPath,null);
  manifest.enrichment={schema:manifest.enrichment.schema,mode:manifest.enrichment.mode,base_url:manifest.enrichment.base_url};
  manifest.sources=Object.fromEntries(Object.entries(manifest.sources).map(([name,s])=>[name,
    {sha256:s.sha256,event_ids:s.event_ids,event_input_hashes:s.event_input_hashes}]));
  storage.writeJsonAtomic(manifestPath,manifest);
  const profilePath=paths.indexesRoot+'/profile/state.json',profile=storage.readJson(profilePath,null);
  for(const domain of Object.values(profile.domains))domain.input_hash='legacy-profile-hash';
  storage.writeJsonAtomic(profilePath,profile);
  for(const file of [...disk.keys()])if(file.startsWith(paths.consolidationRoot+'/sync-cache/'))storage.removeFile(file);
  assert.equal(service.canReuseIndex(manifest,service.currentEnrichment(config)),false);
  const enriched=model.enriched.length,leaves=model.leaves.length;await service.build(config);
  assert.ok(model.enriched.length>enriched);assert.ok(model.leaves.length>leaves);
  assert.deepEqual(Object.keys(service.loadEvents()).sort(),beforeIds);
  assert.deepEqual(sourceFiles.map(file=>[file,storage.readText(file)]),beforeInputs);
  assert.equal(storage.readJson(manifestPath,null).enrichment.model_name,config.model);
  const warmed=[model.enriched.length,model.leaves.length,model.merges.length];await service.build(config);
  assert.deepEqual([model.enriched.length,model.leaves.length,model.merges.length],warmed);
  const facade=Object.create(DataManagerFacade.prototype);facade.indexService={hasCompletePublishedIndex:()=>true};
  const legacy={tree_hash:'same',file_count:3,entry_count:6},current={...legacy,pipeline_hash:'sync-v2'};
  assert.equal(facade.canSkipRefresh(legacy,current),false);assert.equal(facade.canSkipRefresh(current,current),true);
});

test('ArkTS modules reject delete operators while allowing Map and Set deletion methods',()=>{
  function deleteOperators(text,file){
    const tree=ts.createSourceFile(file,text,ts.ScriptTarget.ES2022,true,ts.ScriptKind.TS),errors=[];
    function visit(node){
      if(ts.isDeleteExpression(node))errors.push(file+':'+(tree.getLineAndCharacterOfPosition(node.getStart(tree)).line+1));
      ts.forEachChild(node,visit);
    }
    visit(tree);return errors;
  }
  assert.equal(deleteOperators('delete entries[key];','invalid.ts').length,1,'Detect the ArkTS-only incompatibility');
  assert.equal(deleteOperators('entries.delete(key); entries.clear(); // delete entries[key]','valid.ts').length,0);
  const modules=['DataManagerStorage','IndexWriteBatch','IndexService','DataManagerFacade','ConsolidationService',
    'DataPipelineModelClient','ProfileBlockCache','SyncMetrics'];
  const errors=modules.flatMap(name=>deleteOperators(fs.readFileSync(path.join(root,base+name+'.ets'),'utf8'),name+'.ts'));
  assert.deepEqual(errors,[],'ArkTS forbids DeleteExpression: '+errors.join(', '));
});

test('production declarations check changed business modules with strict types and platform-only stubs',()=>{
  const sources=new Map(),etsRoot=path.join(root,'entry/src/main/ets');
  const actual=['datamanager/WorkflowRunEvidence','datamanager/WorkflowRunEvidenceTask','datamanager/SyncWorkSlice','datamanager/ProfileBlockCache','datamanager/IndexWriteBatch','datamanager/SyncMetrics','datamanager/MemoryChangeJournal',
    'datamanager/DataManagerStorage','datamanager/DataManagerTypes','datamanager/DataManagerPaths','datamanager/IndexService','datamanager/ChatFactDedup',
    'datamanager/DataPipelineModelClient','datamanager/ModelStreamActivity','datamanager/EventStreamParser','datamanager/DataManagerUtils','datamanager/ChatMemoryExtraction','datamanager/ConsolidationService',
    'datamanager/DataManagerFacade','datamanager/CollectionGroupingService','datamanager/HomeRecommendationService',
    'datamanager/DataManagerImageResolver','datamanager/ChatMemorySync','datamanager/DataManagerSyncReminder',
    'utils/ChatSessionStorage','pages/chat/ChatSessionTypes','pages/chat/ChatPageTypes','pages/chat/VoiceInteractionTypes',
    'utils/gallery/GalleryMemorySync','utils/gallery/GalleryTypes','utils/gallery/GalleryExifUtils',
    'utils/calendar/CalendarMemoryStore','utils/calendar/CalendarMemoryPolicy','utils/mail/MailStore','utils/mail/MailReminderPolicy',
    'datamanager/avatar/AvatarTypes','utils/WorkflowSceneConfig','utils/JsonCompat','utils/DateUtils',
    'utils/StartupSourceSync','utils/mail/MailTypes','utils/ChatMessageTime','utils/WorkflowDateContext',
    'pages/home/HomeEmotionalSupport','pages/home/HomeComfortConcernStore'];
  for(const name of actual)sources.set(path.join(etsRoot,name+'.ts'),fs.readFileSync(path.join(etsRoot,name+'.ets'),'utf8').replace(/^@Concurrent\s*$/gm,''));
  const stubs={
    'datamanager/DataManagerLog': 'export declare function dataManagerInfo(s:string):void;export declare function dataManagerWarn(s:string):void;export declare function dataManagerError(s:string):void;',
    'utils/TextEncodingCompat':'export declare function decodeUtf8Compat(b:Uint8Array):string;export declare function encodeUtf8Compat(s:string):Uint8Array;',
    'utils/DebugSettings':'export declare class DebugSettings {static isEnabled():boolean;}',
    'utils/CloudModelClient':`export interface CloudChatMessage {role:string;content:string;}
      export interface CloudChatCompletionOptions {baseUrl:string;apiKey:string;model?:string;messages:CloudChatMessage[];temperature?:number;readTimeout?:number;maxTokens?:number;logResponseContent?:boolean;separateReasoning?:boolean;chatTemplateKwargs?:Object;}
      export interface CloudChatStreamProgress {phase:string;responseCode:number;receivedBytes:number;contentChars:number;reasoningChars:number;contentDelta:string;reasoningDelta:string;finishReason:string;}
      export declare class CloudModelClient {chatCompletionText(options:Object):Promise<string>;chatCompletion(options:Object):Promise<{content:string;finishReason:string}>;
        chatCompletionStream(options:CloudChatCompletionOptions,callbacks:{onProgress?:(value:CloudChatStreamProgress)=>void}):Promise<{content:string;finishReason:string}>;}`,
    'datamanager/avatar/AvatarService':`import {AvatarHomeViewModel,AvatarGenerateRequest,AvatarVersionViewModel,AvatarProviderConfig,AvatarGenerationMode} from './AvatarTypes';
      import {ProfileState} from '../DataManagerTypes';
      export declare class AvatarService {constructor(paths:Object,storage:Object);ensureReady():void;currentHomeView():AvatarHomeViewModel;
      homeView(p:ProfileState,c:number):AvatarHomeViewModel;isCurrentProfileSnapshotUnchanged(p:ProfileState,c:number):boolean;
      buildGenerateRequest(p:ProfileState,c:number,m:AvatarGenerationMode,s:string,a:string,photo?:string):AvatarGenerateRequest;
      generate(c:AvatarProviderConfig,r:AvatarGenerateRequest):Promise<AvatarHomeViewModel>;saveReferencePhoto(s:string):Promise<AvatarHomeViewModel>;
      ensureCurrentForeground():Promise<AvatarHomeViewModel>;listVersionViewModels():AvatarVersionViewModel[];}`
  };
  for(const[name,text]of Object.entries(stubs))sources.set(path.join(etsRoot,name+'.ts'),text);
  sources.set(path.join(root,'.codex-tmp/sync-kits.d.ts'),"declare module '@kit.ArkTS' { export const JSON:typeof globalThis.JSON; export namespace taskpool { function execute(func:Function,...args:Object[]):Promise<Object>; } } declare module '@kit.CryptoArchitectureKit' { export namespace cryptoFramework { interface DataBlob { data:Uint8Array; } function createMd(name:string):any; } } declare module '@ohos.file.fs' { const fs:any; export default fs; }");
  const options={noEmit:true,strict:true,skipLibCheck:true,target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS,moduleResolution:ts.ModuleResolutionKind.NodeJs};
  const host=ts.createCompilerHost(options),read=host.readFile.bind(host),exists=host.fileExists.bind(host);
  host.readFile=file=>sources.get(path.resolve(file))??read(file);host.fileExists=file=>sources.has(path.resolve(file))||exists(file);
  host.getSourceFile=(file,language)=>{const source=host.readFile(file);return source===undefined?undefined:ts.createSourceFile(file,source,language,true);};
  host.resolveModuleNames=(names,containing)=>names.map(name=>{const candidate=path.resolve(path.dirname(containing),name+'.ts');return sources.has(candidate)?{resolvedFileName:candidate,extension:ts.Extension.Ts}:ts.resolveModuleName(name,containing,options,host).resolvedModule;});
  const errors=ts.getPreEmitDiagnostics(ts.createProgram([...sources.keys()],options,host)).filter(d=>d.category===ts.DiagnosticCategory.Error);
  assert.equal(errors.length,0,errors.map(d=>(d.file?path.basename(d.file.fileName)+':'+(d.file.getLineAndCharacterOfPosition(d.start).line+1)+': ':'')+ts.flattenDiagnosticMessageText(d.messageText,'\n')).join('\n'));
});
test('randomized delta indexes stay equivalent to full rebuilds across sixty update sequences',()=>{
  reset();const service=new IndexService(paths,storage,new Model());
  let seed=19;const random=()=>((seed=(seed*1664525+1013904223)>>>0)/4294967296);
  const methods={inverted:'buildInvertedDocument',source:'buildSourceDocument',domain:'buildDomainDocument','workflow-scene':'buildWorkflowSceneDocument'};
  let previous={};
  for(let turn=0;turn<60;turn++){
    const next={};for(let i=0;i<35;i++)if(random()>.25)next['e'+i]=event('e'+i,`2026-${random()>.5?'09':'10'}-01`,{
      summary:random()>.5?'交通出行记录':'工作会议研究',domains:[random()>.5?'work':'travel'],workflow_scene_ids:[Math.floor(random()*7)]});
    const ids=new Set([...Object.keys(previous),...Object.keys(next)]),changed={},before={},after={};
    for(const id of ids)if(JSON.stringify(previous[id])!==JSON.stringify(next[id])){changed[id]=true;if(previous[id])before[id]=previous[id];if(next[id])after[id]=next[id];}
    for(const[kind,method]of Object.entries(methods)){
      if(turn===0)storage.writeJsonAtomic(paths.indexesRoot+'/'+kind+'/index.json',service[method](previous));
      service.writePostingIndex(kind,service[method](before).postings,service[method](after).postings,next,changed,true);
      assert.deepEqual(clone(storage.readJson(paths.indexesRoot+'/'+kind+'/index.json',null)),clone(service[method](next)),kind+' round '+turn);
    }previous=next;
  }
});
test('deleted calendar events retract stored partitions and reverse indexes even when public reads already hide them',async()=>{
  reset();const service=new IndexService(paths,storage,new Model());
  calendarEvents=[event('calendar:fixture','2026-10-01',{calendar:{seriesKey:'fixture',start:1,end:2,profileEnabled:false}})];
  await service.build(config);assert.equal(Object.keys(service.loadEvents()).length,1);
  calendarEvents=[];assert.equal(Object.keys(service.loadEvents()).length,0);
  await service.build(config);assert.equal(storage.exists(paths.eventPartitionPath('2026-10')),false);
  const inverted=storage.readJson(paths.indexesRoot+'/inverted/index.json',null);
  assert.ok(Object.values(inverted.postings).every(ids=>!ids.includes('calendar:fixture')));
});
test('production file read cache is scoped, invalidated by writes and bounded in memory',()=>{
  const files=new Map([['/idx/file','old'],['/other/file','external']]),counts={reads:0};let fd=0;const handles=new Map();
  const platform={OpenMode:{READ_ONLY:1,CREATE:2,WRITE_ONLY:4,TRUNC:8},accessSync:p=>files.has(p)||p==='/idx'||p==='/other',mkdirSync(){},
    openSync:(p,mode)=>{const handle={fd:++fd,path:p};handles.set(handle.fd,handle);return handle;},
    closeSync(){},statSync:p=>({size:Buffer.byteLength(files.get(p)||''),isDirectory:()=>p==='/idx'||p==='/other'}),
    readSync:(id,buffer)=>{counts.reads++;new Uint8Array(buffer).set(Buffer.from(files.get(handles.get(id).path)));},
    writeSync:(id,buffer)=>files.set(handles.get(id).path,Buffer.from(buffer).toString()),unlinkSync:p=>files.delete(p),
    renameSync:(from,to)=>{files.set(to,files.get(from));files.delete(from);},listFileSync:()=>[]};
  const output=ts.transpileModule(fs.readFileSync(path.join(root,base+'DataManagerStorage.ets'),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  const exported={};vm.runInNewContext(output,{exports:exported,ArrayBuffer,Uint8Array,require:id=>{
    if(id==='@ohos.file.fs')return {default:platform};if(id==='@kit.CryptoArchitectureKit')return {cryptoFramework:{}};
    if(id.endsWith('JsonCompat'))return {parseJsonCompat:JSON.parse,stringifyJsonCompat:(value,space)=>JSON.stringify(value,null,space)};
    if(id.endsWith('TextEncodingCompat'))return {encodeUtf8Compat:s=>new TextEncoder().encode(s),decodeUtf8Compat:b=>new TextDecoder().decode(b)};
    if(id.endsWith('MemoryChangeJournal'))return load(base+'MemoryChangeJournal');
    throw Error(id);
  }});
  const store=new exported.DataManagerStorage();store.beginReadSession('/idx');store.readText('/idx/file');store.readText('/idx/file');assert.equal(counts.reads,1);
  store.readText('/other/file');store.readText('/other/file');assert.equal(counts.reads,3);
  store.writeTextAtomic('/idx/file','updated');assert.equal(store.readText('/idx/file'),'updated');assert.equal(counts.reads,4);
  files.set('/idx/large','x'.repeat(9*1024*1024));store.readText('/idx/large');store.readText('/idx/large');assert.equal(counts.reads,6);
  assert.ok(store.readBytes<=16*1024*1024);assert.equal(store.endReadSession(),1);store.readText('/idx/file');assert.equal(counts.reads,7);
});
test('production model combines sparse months and reduces large summary inputs within the configured prompt budget',async()=>{
  reset();const client=new DataPipelineModelClient(),sizes=[];
  cloudHandler=async options=>{
    sizes.push(options.messages[1].content.length);const input=JSON.parse(options.messages[1].content);
    const ids=[...new Set(input.events?.map(e=>e.event_id)||input.candidate_claims.flatMap(c=>c.event_ids))].slice(0,6);
    return JSON.stringify({short_summary:'模型研究',summary:'关注模型研究',claims:[{statement:'持续关注模型研究',kind:'topic',confidence:'medium',event_ids:ids}]});
  };
  const sparse=[event('one','2026-01-01'),event('two','2026-02-01')];
  const combined=await new ProfileBlockCache(paths,storage,client).build('work',sparse,config);
  assert.equal(combined.generation,'model');assert.equal(combined.claims[0].event_ids.length,2);
  const events=Array.from({length:150},(_,i)=>event('long-id-'+String(i).padStart(60,'0')));
  const blocks=events.map(e=>({short_summary:'',summary:'',generation:'model_block',claims:[{statement:'关注模型研究与端侧部署'.repeat(15),kind:'topic',confidence:'medium',event_ids:[e.event_id],example:''}]}));
  sizes.length=0;await client.combineProfileBlocks('work',blocks,events,config,true);
  assert.ok(sizes.length>1);assert.ok(sizes.every(size=>size<=10000),'Every merge request is bounded');
});
test('a directory enumeration failure cannot turn known existing raw logs into deletions',()=>{
  reset();const local=new Storage(),file=paths.dailyLogRoot+'/2026-10-01/shopping.md';
  local.writeTextAtomic(file,'1. 用户购买咖啡20元\n');
  local.writeJsonAtomic(paths.consolidationRoot+'/daily-log-snapshot.json',{generated_at:'',root:'workflows/daily-log',
    tree_hash:'fixture',file_count:1,entry_count:1,files:[{path:'2026-10-01/shopping.md',sha256:'fixture',entry_count:1}]});
  local.listDir=()=>[];local.findFiles=()=>[];
  const consolidation=new ConsolidationService(paths,local,new DataPipelineModelClient());
  assert.equal(consolidation.collectSourceEntries().length,1);
  const facade=Object.create(DataManagerFacade.prototype);facade.storage=local;facade.paths=paths;
  const snapshot=facade.buildDailyLogSnapshot();assert.equal(snapshot.file_count,1);assert.equal(snapshot.entry_count,1);
  const read=local.readText.bind(local);local.readText=(name,fallback='')=>name===file?fallback:read(name,fallback);
  assert.throws(()=>consolidation.collectSourceEntries(),/读取采集日志失败/);assert.throws(()=>facade.buildDailyLogSnapshot(),/读取采集日志失败/);
});
test('sync and presentation read scopes release caches and busy state on success and failure',async()=>{
  reset();const facade=Object.create(DataManagerFacade.prototype);let begins=0,ends=0,models=0;
  facade.paths=paths;facade.storage={beginReadSession(){begins++;},endReadSession(){ends++;return 3;}};
  facade.indexService={beginSyncRead(){begins++;},endSyncRead(){ends++;}};
  facade.modelClient={resetSyncMetrics(){models++;},reportSyncMetrics(){models++;}};
  facade.refreshInternal=async(_config,progress)=>{progress({stage:'生成画像',message:'fixture',current:1,total:2,percent:88});return {skipped:false};};
  await facade.refresh(config);assert.equal(facade.syncRunning,false);assert.equal(begins,ends);assert.equal(models,2);
  facade.refreshInternal=async()=>{throw Error('fixture failure');};await assert.rejects(facade.refresh(config),/fixture/);
  assert.equal(facade.syncRunning,false);assert.equal(begins,ends);
  facade.loadHomeViewModel=()=>({totalEvents:2});facade.loadCollectionViewModels=()=>[{count:2}];
  assert.equal(facade.loadPresentationSnapshot().home.totalEvents,2);assert.equal(begins,ends);
  facade.loadCollectionViewModels=()=>{throw Error('view failure');};assert.throws(()=>facade.loadPresentationSnapshot(),/view/);assert.equal(begins,ends);
  assert.ok(logs.some(line=>line.startsWith('SYNC_STAGE_END')&&line.includes('elapsedMs=')));
});
test('startup source updates keep published task data and never import pending task/gallery output states',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  const source=paths.outputStatePath('2026-09','shopping.md');
  const record=(id,date,text)=>({record_id:id,first_seen_date:date,last_seen_date:date,source_refs:[date+'/shopping.md#'+id],
    source_dates:[date],workflow_scene_ids:[0],summary:'工作会议 '+text,normalized_fact:'工作会议 '+text,
    raw_excerpts:[],tags:['会议'],dedup_status:'new',model_notes:[],dedup_text:text});
  storage.writeJsonAtomic(source,{metadata:{},records:[record(1,'2026-09-01','已手动同步')]});await service.build(config);
  const before=clone(service.loadEvents());model.enriched.length=0;
  storage.writeTextAtomic(source,'not valid JSON: a pending manual source edit must not be read');
  const pending=paths.outputStatePath('2026-10','gallery.md');
  storage.writeJsonAtomic(pending,{metadata:{},records:[record(2,'2026-10-01','尚未手动同步的图库')]});
  const chat=paths.outputStatePath('2026-10','app-chat__cloud__0.md');
  storage.writeJsonAtomic(chat,{metadata:{},records:[record(3,'2026-10-02','新增聊天')]});reads.clear();
  const selection={chat:true,calendar:false,statePaths:[chat]};assert.equal(service.selectedSourcesNeedRefresh(selection),true);
  await service.build(config,undefined,selection);assert.equal(service.selectedSourcesNeedRefresh(selection),false);
  assert.equal(reads.get(source)||0,0);assert.equal(reads.get(pending)||0,0);
  const after=service.loadEvents();assert.equal(Object.keys(after).length,2);
  for(const id of Object.keys(before))assert.deepEqual(clone(after[id]),before[id]);
  assert.equal(model.enriched.length,1);assert.ok(!JSON.stringify(after).includes('尚未手动同步的图库'));
  assert.equal(storage.readText(source),'not valid JSON: a pending manual source edit must not be read');
  await service.build(config,undefined,{chat:true,calendar:false,statePaths:[]});assert.deepEqual(clone(service.loadEvents()),before);
  calendarEvents=[event('calendar:startup','2026-10-03',{calendar:{seriesKey:'startup',start:1,end:2,profileEnabled:false}})];
  await service.build(config,undefined,{chat:false,calendar:true,statePaths:[]});
  assert.equal(Object.keys(service.loadEvents()).length,2);assert.equal(reads.get(pending)||0,0);
});

test('chat-only consolidation preserves the other source ledger and skips raw task and gallery scans',async()=>{
  reset();const chatSource='2026-10-01/app-chat__cloud__0.md',manualSource=paths.dailyLogRoot+'/2026-10-01/shopping.md';
  storage.writeTextAtomic(paths.dailyLogRoot+'/'+chatSource,'1. 工作会议研究模型部署\n');
  storage.writeTextAtomic(manualSource,'1. 尚未手动同步的任务记录\n');
  const ledgerPath=paths.outputsRoot+'/state-index.json';storage.writeJsonAtomic(ledgerPath,{
    schema:'datamanager-consolidation-output-state-index-v1',state_paths:['2026-09/shopping.md.state.json','2026-08/app-chat__cloud__0.md.state.json']});
  const chatMock=mocks['ChatMemorySync.ets'].ChatMemorySync,oldChat=chatMock.dailyLogRelativePaths;
  const gallery=mocks['GalleryMemorySync.ets'].GalleryMemorySync,oldGallery=gallery.dailyLogRelativePaths;
  chatMock.dailyLogRelativePaths=()=>[chatSource];gallery.dailyLogRelativePaths=()=>{throw Error('Unexpected gallery scan');};
  try{
    const result=await new ConsolidationService(paths,storage,new DataPipelineModelClient()).consolidateChat({...config,enabled:false});
    assert.equal(result.length,1);assert.equal(reads.get(manualSource)||0,0);
    assert.deepEqual(clone(storage.readJson(ledgerPath,null).state_paths),['2026-09/shopping.md.state.json','2026-10/app-chat__cloud__0.md.state.json']);
  } finally {chatMock.dailyLogRelativePaths=oldChat;gallery.dailyLogRelativePaths=oldGallery;}
});

test('daily startup checkpoints persist per source, isolate failures and avoid repeated or overlapping runs',async()=>{
  reset();const now=new Date('2026-10-26T09:00:00+08:00').getTime(),selection={mail:true,calendar:true,chat:true};
  const calls=[],scheduler=new StartupSourceSync('/app');let calendarFailure=true;
  const actions={mail:async()=>calls.push('mail'),calendar:async()=>{calls.push('calendar');if(calendarFailure)throw Error('offline');},chat:async()=>calls.push('chat')};
  const first=await scheduler.run(selection,actions,now);assert.deepEqual(clone(first.updated),['mail','chat']);assert.deepEqual(clone(first.failed),['calendar']);
  await new StartupSourceSync('/app').run(selection,actions,now+1000);assert.equal(calls.length,3);
  calendarFailure=false;await scheduler.run(selection,actions,now+600001);assert.equal(calls.length,3);
  await scheduler.run(selection,actions,now+600001,undefined,true);assert.deepEqual(calls,['mail','calendar','chat','calendar']);
  assert.equal(scheduler.hasDue(selection,now+12*3600000),false);
  await scheduler.run(selection,actions,now+86400000+600100);assert.equal(calls.length,7);
  const allOff={mail:false,calendar:false,chat:false};await scheduler.run(allOff,actions,now+2*86400000);assert.equal(calls.length,7);
  scheduler.markSynced('mail',now+2*86400000);await scheduler.run({mail:true,calendar:false,chat:false},actions,now+2*86400000+1000);
  assert.equal(calls.length,7);
  let release;const gate=new Promise(resolve=>release=resolve),next=new StartupSourceSync('/concurrent');
  const firstRun=next.run({mail:true,calendar:false,chat:false},{...actions,mail:async()=>{calls.push('held');await gate;}},now);
  const concurrent=await new StartupSourceSync('/concurrent').run(selection,actions,now);assert.equal(concurrent.updated.length,0);
  release();await firstRun;assert.equal(calls.filter(value=>value==='held').length,1);
});

test('startup authorization is sequential and persists refusals, system denials and grants across page restarts',async()=>{
  const file=path.join(root,'entry/src/main/ets/pages/Index.ets');
  const source=fs.readFileSync(file,'utf8').replace(/\bstruct Index\b/,'class Index');
  const tree=ts.createSourceFile('Index.ts',source,ts.ScriptTarget.Latest,true,ts.ScriptKind.TS);
  const component=tree.statements.find(node=>ts.isClassDeclaration(node)&&node.name?.text==='Index');assert.ok(component);
  const names=['runStartupServices','offerCalendarConsent'];
  const methods=names.map(name=>component.members.find(node=>ts.isMethodDeclaration(node)&&node.name.getText(tree)===name).getText(tree)).join('\n');
  const code=ts.transpileModule('exports.Probe=class Probe {'+methods+'}',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  function scenario(calendarChoice,reminderChoice,calendarGrant,notificationGrant){
    const state={calendarConfigured:false,calendarEnabled:false,reminderAsked:false,reminderEnabled:false,
      accepted:true,calendarDialogs:0,reminderDialogs:0,calendarRequests:0,notificationRequests:0,fullSyncs:0,dailySyncs:0};
    class CalendarStore {shouldOfferConsent(){return !state.calendarConfigured&&!state.calendarEnabled;}
      markConfigured(){state.calendarConfigured=true;}settings(){return {enabled:state.calendarEnabled};}
      saveSettings(settings){state.calendarEnabled=settings.enabled;}consentChoice(){return {}; }saveConsentChoice(){} }
    const exported={};vm.runInNewContext(code,{exports:exported,CalendarMemoryStore:CalendarStore,
      PrivacyConsent:{isAccepted:()=>state.accepted,state:()=>state.privacyChoice||(state.accepted?'accepted':'rejected')},getContext:()=>({}),AppTheme:{dialogText:color=>color},showToastSafely(){},
      showCalendarConsentDialog:async()=>{state.calendarDialogs++;return calendarChoice;},
      CalendarMemoryService:{requestAccess:async()=>{state.calendarRequests++;if(!calendarGrant)throw Error('denied');}},
      CollectionReminderService:{shouldOfferStartupConsent:()=>!state.reminderAsked,markStartupConsentPrompted:()=>{state.reminderAsked=true;},
        load:()=>({enabled:state.reminderEnabled,hour:21,minute:0}),setEnabled:async()=>{
          state.notificationRequests++;if(!notificationGrant)throw Error('denied');state.reminderEnabled=true;}},
      notificationManager:{isNotificationEnabled:async()=>notificationGrant},
      promptAction:{showDialog:async()=>{state.reminderDialogs++;return {index:reminderChoice};}}});
    function probe(){const value=new exported.Probe();value.pageVisible=true;value.filesDir='/app';value.getUIContext=()=>({});
      value.ensurePrivacyConsent=async()=>state.accepted;value.syncDailyStartupSources=async()=>{state.dailySyncs++;};
      value.refreshDataManager=async()=>{state.fullSyncs++;};return value;}
    return {state,probe};
  }
  for(const options of [[false,0,false,false],[true,1,false,false],[true,1,true,true]]){
    const {state,probe}=scenario(...options);await probe().runStartupServices();await probe().runStartupServices();
    assert.equal(state.calendarDialogs,1);assert.equal(state.reminderDialogs,1);assert.equal(state.fullSyncs,0);
    assert.equal(state.calendarRequests,options[0]?1:0);assert.equal(state.notificationRequests,options[1]===1?1:0);
    assert.equal(state.calendarEnabled,options[0]&&options[2]);assert.equal(state.reminderEnabled,options[1]===1&&options[3]);
  }
  const hidden=scenario(true,1,true,true);const page=hidden.probe();page.pageVisible=false;await page.runStartupServices();
  assert.equal(hidden.state.calendarDialogs,0);assert.equal(hidden.state.dailySyncs,0);
  const rejected=scenario(true,1,true,true);rejected.state.accepted=false;await rejected.probe().runStartupServices();
  assert.equal(rejected.state.calendarDialogs,1);assert.equal(rejected.state.reminderDialogs,1);assert.equal(rejected.state.dailySyncs,1);
  const unselected=scenario(true,1,true,true);unselected.state.accepted=false;unselected.state.privacyChoice='unselected';
  let privacyRequests=0;const firstPage=unselected.probe();firstPage.ensurePrivacyConsent=async()=>{
    privacyRequests++;unselected.state.privacyChoice='rejected';return false;};
  await firstPage.runStartupServices();await unselected.probe().runStartupServices();
  assert.equal(privacyRequests,0);assert.equal(unselected.state.privacyChoice,'unselected');
  assert.equal(unselected.state.calendarDialogs,1);assert.equal(unselected.state.dailySyncs,2);
});

test('automatic updates can be disabled persistently and stop queued sources after the current one',async()=>{
  reset();const now=Date.now(),scheduler=new StartupSourceSync('/opt-out'),selection={mail:true,calendar:true,chat:true},calls=[];
  assert.equal(scheduler.isEnabled(),true);scheduler.setEnabled(false);
  assert.equal(new StartupSourceSync('/opt-out').isEnabled(),false);assert.equal(scheduler.hasDue(selection,now),false);
  const actions={mail:async()=>{calls.push('mail');scheduler.setEnabled(false);},calendar:async()=>{calls.push('calendar');},chat:async()=>{calls.push('chat');}};
  await scheduler.run(selection,actions,now);assert.equal(calls.length,0);
  scheduler.setEnabled(true);const result=await scheduler.run(selection,actions,now);
  assert.deepEqual(clone(result.updated),['mail']);assert.deepEqual(calls,['mail']);
  const state=storage.readJson('/opt-out/workflows/startup-source-sync.json',null);
  assert.equal(state.calendar.attemptedAt,0);assert.equal(state.chat.attemptedAt,0);
  scheduler.markSynced('mail',now);scheduler.setEnabled(true);
  await scheduler.run(selection,{...actions,mail:async()=>{throw Error('Already updated today');}},now+1000);
  assert.deepEqual(calls,['mail','calendar','chat']);
  storage.writeTextAtomic('/opt-out/workflows/startup-source-settings.json','invalid preferences');
  assert.equal(scheduler.isEnabled(),false);
});

test('startup selection skips missing calendar access and mailbox configuration, while the popup opt-out shares settings',async()=>{
  reset();const file=path.join(root,'entry/src/main/ets/pages/Index.ets');
  const tree=ts.createSourceFile('Index.ts',fs.readFileSync(file,'utf8').replace(/\bstruct Index\b/,'class Index'),ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(node=>ts.isClassDeclaration(node)&&node.name?.text==='Index');
  const methods=['syncDailyStartupSources','disableDailyStartupSync','updateStartupSourceProgress','updateStartupWorkProgress',
    'startMemoryProgressTimer','stopMemoryProgressTimer','refreshModelActivities','beginMemoryOperation','endMemoryOperation'].map(name=>component.members.find(node=>ts.isMethodDeclaration(node)&&node.name.getText(tree)===name).getText(tree)).join('\n');
  const code=ts.transpileModule('exports.Probe=class Probe {'+methods+'}',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  const exported={},calls=[],values={},counters={calendarCheck:0,mailCheck:0,providerReads:0,mailReads:0};
  let calendarAllowed=false,mailConfigured=false;
  class CalendarStore {settings(){return {enabled:true};}}
  class MailStore {settings(){return {enabled:true,aiAllowed:false};}}
  vm.runInNewContext(code,{exports:exported,setInterval,clearInterval,StartupSourceSync,STARTUP_SOURCE_SYNC_ENABLED_KEY:'startupSourceSyncEnabled',
    CalendarMemoryStore:CalendarStore,MailStore,AiServiceAccess:{isAllowed:()=>true},PrivacyConsent:{isAccepted:()=>true,requireAccepted(){}},
    CalendarMemoryService:{canAutoRefresh:async()=>{counters.calendarCheck++;return calendarAllowed;},refresh:async()=>{counters.providerReads++;}},
    MailService:{isBusy:()=>false,canAutoRefresh:async()=>{counters.mailCheck++;return mailConfigured;},refresh:async()=>{counters.mailReads++;}},
    getContext:()=>({}),dataManagerInfo:line=>logs.push(line),AppStorage:{setOrCreate:(key,value)=>{values[key]=value;}},showToastSafely(){}});
  const page=new exported.Probe();page.filesDir='/app';page.pageVisible=true;page.dataManagerRefreshing=false;page.memoryOperationEpoch=0;
  page.memoryProgressTimerId=-1;page.startupSourceSyncEnabled=true;const progressValues=[];
  page.dataManagerFacade={modelActivities:()=>[],refreshSourceMemory:async(_config,chat,calendar,progress)=>{
    calls.push({chat,calendar});assert.equal(typeof progress,'function');
    progress({stage:'生成画像',message:'fixture model work',current:2,total:3,percent:90});progressValues.push(page.dataManagerProgressPercent);}};
  page.getDataManagerModelConfig=()=>config;page.reloadDataManagerViewModels=()=>{};
  await page.syncDailyStartupSources();assert.deepEqual(calls,[{chat:true,calendar:false}]);
  assert.equal(counters.providerReads,0);assert.equal(counters.mailReads,0);assert.equal(page.dataManagerSyncFailed,false);
  assert.equal(page.startupSourceSyncRunning,false);page.disableDailyStartupSync();
  assert.ok(progressValues[0]>0&&progressValues[0]<100);assert.equal(page.memoryProgressTimerId,-1);
  assert.equal(values.startupSourceSyncEnabled,false);assert.equal(new StartupSourceSync('/app').isEnabled(),false);
  const before={...counters};await page.syncDailyStartupSources();assert.deepEqual(counters,before);
  const settings=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/settings/SettingsCenterPage.ets'),'utf8');
  assert.ok(settings.includes('@StorageLink(STARTUP_SOURCE_SYNC_ENABLED_KEY)'));assert.ok(settings.includes("label: '每日自动更新'"));
  reset();calls.length=0;calendarAllowed=true;mailConfigured=true;
  await page.syncDailyStartupSources();assert.deepEqual(calls,[{chat:true,calendar:true}],'One memory rebuild combines calendar and chat');
  assert.equal(counters.providerReads,1);assert.equal(counters.mailReads,1);
  assert.equal(page.startupSourceTotal,3);assert.equal(page.startupSourceCompleted,3);assert.equal(page.dataManagerProgressPercent,100);
  assert.equal(page.memoryProgressTimerId,-1);
});

test('source progress reports only eligible work and real completion boundaries, with elapsed diagnostics',async()=>{
  reset();const scheduler=new StartupSourceSync('/progress'),now=Date.now(),steps=[];
  scheduler.markSynced('calendar',now);
  await scheduler.run({mail:true,calendar:true,chat:true},{mail:async()=>{},calendar:async()=>{throw Error('Already updated');},chat:async()=>{}},now,
    value=>steps.push(clone(value)));
  assert.deepEqual(steps.map(value=>[value.source,value.completed,value.total,value.finished]),[
    ['mail',0,2,false],['mail',1,2,true],['chat',1,2,false],['chat',2,2,true]]);
  assert.ok(logs.some(line=>line.startsWith('STARTUP_SYNC success')&&line.includes('elapsedMs=')));
});

test('automatic memory processing forwards detailed stages and releases metrics/read scopes on success or failure',async()=>{
  reset();const facade=Object.create(DataManagerFacade.prototype),steps=[];let begins=0,ends=0,builds=0,changed=true;
  facade.paths=paths;facade.storage=Object.assign(new Storage(),{beginReadSession(){begins++;},endReadSession(){ends++;}});facade.ensureReady=()=>{};
  facade.modelClient={resetSyncMetrics(){},reportSyncMetrics(){}};
  facade.indexService={beginSyncRead(){begins++;},endSyncRead(){ends++;},selectedSourcesNeedRefresh:()=>changed,
    build:async(_config,progress)=>{builds++;progress({stage:'生成画像',message:'fixture',current:1,total:2,percent:90});}};
  facade.consolidationService={consolidateChat:async(_config,progress)=>{
    progress({stage:'整理聊天',message:'fixture',current:1,total:1,percent:58});return [];}};
  const chatModule=mocks['ChatMemorySync.ets'],original=chatModule.ChatMemorySync;
  chatModule.ChatMemorySync=class {async sync(_config,progress){
    progress({stage:'聊天同步',message:'fixture',current:1,total:1,percent:5});return {processedParts:1,factCount:1};}};
  try {
    await facade.refreshSourceMemory(config,true,true,value=>steps.push(clone(value)));
    assert.equal(builds,1);assert.equal(steps.at(-1).percent,100);assert.equal(begins,ends);assert.equal(facade.syncRunning,false);
    assert.ok(steps.some(value=>value.stage==='生成画像'&&value.current===1&&value.total===2));
    changed=false;await facade.refreshSourceMemory(config,true,true);assert.equal(builds,1);
    changed=true;facade.indexService.build=async()=>{throw Error('fixture failure');};
    await assert.rejects(facade.refreshSourceMemory(config,true,true),/fixture failure/);
    assert.equal(begins,ends);assert.equal(facade.syncRunning,false);
    assert.ok(logs.some(line=>line.startsWith('SYNC_FINISH')&&line.includes('success=false')));
  } finally {chatModule.ChatMemorySync=original;}
});

test('skipped calendar records are retained locally but excluded from model inputs during a chat-only update',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  calendarEvents=[event('calendar:withheld','2026-10-01',{calendar:{seriesKey:'withheld',start:1,end:2,profileEnabled:true}})];
  await service.build(config);assert.ok(service.loadStoredEvents()['calendar:withheld']);
  calendarEvents=[];model.leaves.length=0;model.merges.length=0;model.enriched.length=0;
  await service.build(config,undefined,{chat:true,calendar:false,statePaths:[]});
  assert.ok(service.loadStoredEvents()['calendar:withheld'],'Preserve historical storage');
  assert.equal(Object.keys(service.loadEvents()).length,0);assert.equal(model.leaves.length,0);
  assert.equal(model.merges.length,0);assert.equal(model.enriched.length,0);
});

test('platform privacy replaces local records and the duplicate agreement dialog',()=>{
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/utils/PrivacyConsent.ets'),'utf8');
  assert.ok(source.includes('privacyManager.getAppPrivacyResult()'));
  assert.ok(!source.includes('getPreferences')&&!source.includes('privacy_consent'));
  assert.ok(!fs.existsSync(path.join(root,'entry/src/main/ets/components/PrivacyConsentDialog.ets')));
  const helper=fs.readFileSync(path.join(root,'entry/src/main/ets/utils/HuaweiPrivacyAccess.ets'),'utf8');
  assert.ok(!/showAlertDialog|openCustomDialog|requestAppPrivacyConsent/.test(helper));
});

test('system privacy refusal still blocks automatic sources and A2A remains opt-in',()=>{
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/agent/PersonalMemoryAccess.ets'),'utf8');
  assert.ok(source.includes('platformAccepted && enabled'));
  assert.ok(source.includes('PrivacyConsent.requireAccepted()'));
  assert.ok(!source.includes('privacy_consent'));
});

test('rolling 24-hour windows survive midnight, failures, opt-out and damaged independent source stamps',async()=>{
  reset();const start=Date.parse('2026-10-27T23:55:00+08:00'),s=new StartupSourceSync('/app');
  const selection={mail:true,calendar:true,chat:true};
  for(const source of ['mail','calendar','chat'])s.markSynced(source,start);
  assert.equal(s.hasDue(selection,start+11*60000),false);
  assert.equal(s.hasDue(selection,start+86400000-1),false);
  assert.equal(s.hasDue(selection,start+86400000),true);
  let calls=0;const actions={mail:async()=>{calls++;throw Error('offline');},calendar:async()=>{},chat:async()=>{}};
  await s.run({mail:true,calendar:false,chat:false},actions,start+86400000);
  assert.equal(s.hasDue({mail:true,calendar:false,chat:false},start+86400000+3600000),false);
  s.setEnabled(false);actions.mail=async()=>{calls++;};
  await s.run(selection,actions,start+86400000+3600000,undefined,true);assert.equal(calls,2);
  const state=storage.readJson('/app/workflows/startup-source-sync.json',null);
  state.calendar={successAt:'broken'};storage.writeJsonAtomic('/app/workflows/startup-source-sync.json',state);
  s.setEnabled(true);
  assert.equal(s.pendingSelection(selection,start+86400000+3600001).mail,false,'One invalid source cannot erase another success');
});

test('compact evidence ignores presentation metadata and caches both automatic and full input variants',async()=>{
  reset();const model=new Model(),cache=new ProfileBlockCache(paths,storage,model);
  const a=[event('a'),event('b')];await cache.build('work',a,config);
  const before=model.leaves.length+model.merges.length;
  await cache.build('work',a.map(e=>({...e,image_paths:['changed-image-path'],todo:{text:'UI only'},source_state_file:'new-ui-path'})),config);
  assert.equal(model.leaves.length+model.merges.length,before);
  await cache.build('work',[...a,event('c')],config);const afterB=model.leaves.length+model.merges.length;
  await cache.build('work',a,config);assert.equal(model.leaves.length+model.merges.length,afterB);
  for(const text of disk.values())assert.ok(JSON.parse(text).versions.length<=2);
  const large=Array.from({length:197},(_,i)=>event('long-source-path/'.repeat(6)+i,'2026-0'+(i%6+1)+'-01'));
  await cache.build('work',large,config);assert.ok(cache.stats.total<45);
  assert.ok(model.leaves.every(ids=>ids.length<=32));
});

test('unchanged published v1 domains migrate without calling the model or deleting historical indexes',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model),input=[event('a'),event('b')];
  const previous=service.emptyProfileState();
  const hash=storage.sha256Text('profile-month-tree-v1:work:'+model.profileCacheIdentity(config)+':'+JSON.stringify(input));
  const buildState=load(base+'IndexService').buildProfileDomainStateFromPayload;
  previous.domains.work=buildState('work',hash,['a','b'],2,{start_date:'2026-10-01',end_date:'2026-10-01'},payload(input,true),
    [{statement:'关注模型研究',kind:'topic',confidence:'medium',event_ids:['a','b'],evidence_count:2,start_date:'2026-10-01',end_date:'2026-10-01',example:''}]);
  storage.writeJsonAtomic(paths.indexesRoot+'/profile/state.json',previous);
  const next=await service.buildProfileDocument({a:input[0],b:input[1]},config,true);
  assert.equal(model.leaves.length+model.merges.length,0);assert.equal(next.domains.work.claims.length,1);
  assert.notEqual(next.domains.work.input_hash,hash);
});

function profileAnswer(input){
  const ids=[...new Set(input.events?.map(e=>e.event_id)||input.candidate_claims.flatMap(c=>c.event_ids))];
  return JSON.stringify({short_summary:'模型研究',summary:'关注模型研究',claims:[{statement:'关注端侧模型研究与部署',
    kind:'topic',confidence:'medium',event_ids:ids.slice(0,4),example:''}]});
}

test('profile aliases reduce long path output and restore only actual evidence IDs',async()=>{
  reset();const client=new DataPipelineModelClient();const input=[event('source/'.repeat(35)+'a'),event('source/'.repeat(35)+'b')];
  let seen;cloudHandler=async options=>{seen=JSON.parse(options.messages[1].content);return profileAnswer(seen);};
  const result=await client.summarizeProfileBlock('work',input,config);
  assert.ok(seen.events.every(e=>/^e\d+$/.test(e.event_id)));assert.ok(result.claims[0].event_ids.every(id=>input.some(e=>e.event_id===id)));
  let calls=0;cloudHandler=async()=>{calls++;return JSON.stringify({claims:[{statement:'fake',event_ids:['e99999']}]});};
  await assert.rejects(client.summarizeProfileBlock('work',[input[0]],config),/证据/);assert.equal(calls,2);
});

test('truncated profile responses split input rather than retrying the same oversized request',async()=>{
  reset();const client=new DataPipelineModelClient(),input=Array.from({length:4},(_,i)=>event('item-'+i)),steps=[];
  let calls=0;cloudHandler=async options=>{
    calls++;const data=JSON.parse(options.messages[1].content);
    return {content:profileAnswer(data),finishReason:data.events?.length>1?'length':'stop'};
  };
  const result=await client.summarizeProfileBlock('work',input,config,message=>steps.push(message));
  assert.ok(calls<=12);assert.ok(steps.some(x=>x.includes('拆小')));
  assert.ok(result.claims.every(c=>c.event_ids.every(id=>input.some(e=>e.event_id===id))));
  let networkCalls=0;cloudHandler=async()=>{networkCalls++;throw Error('network unavailable');};
  await assert.rejects(client.summarizeProfileBlock('work',input,config),/network/);assert.equal(networkCalls,1);
});

test('profile correction retries remain deterministic, visible and bounded',async()=>{
  reset();const client=new DataPipelineModelClient(),steps=[],temperatures=[];let calls=0;
  cloudHandler=async options=>{temperatures.push(options.temperature);calls++;
    return calls===1?'{broken':profileAnswer(JSON.parse(options.messages[1].content));};
  await client.summarizeProfileBlock('work',[event('a')],config,m=>steps.push(m));
  assert.deepEqual(temperatures,[0,0]);assert.ok(steps.some(x=>x.includes('重试')));
  calls=0;cloudHandler=async()=>{calls++;return '{broken';};
  await assert.rejects(client.summarizeProfileBlock('work',Array.from({length:32},(_,i)=>event('bad-'+i)),config));
  assert.ok(calls<=12);
});

function memoryOperationProbe(){
  const tree=ts.createSourceFile('Index.ts',fs.readFileSync(path.join(root,'entry/src/main/ets/pages/Index.ets'),'utf8')
    .replace(/\bstruct Index\b/,'class Index'),ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='Index');
  const names=['syncDailyStartupSources','updateStartupSourceProgress','updateStartupWorkProgress','startMemoryProgressTimer',
    'stopMemoryProgressTimer','refreshModelActivities','beginMemoryOperation','endMemoryOperation','syncMailReminders','syncCalendarMemory',
    'updateDataManagerProgress','retryMemoryOperation'];
  const methods=names.map(name=>component.members.find(n=>ts.isMethodDeclaration(n)&&n.name.getText(tree)===name).getText(tree)).join('\n');
  const code=ts.transpileModule('exports.Probe=class Probe {'+methods+'}',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  const exp={},state={mail:false,calendar:false,failChat:false,failMail:false,mailCalls:0,calendarReads:0,memoryCalls:[],mailBegins:[],fullCalls:0};let page;
  vm.runInNewContext(code,{exports:exp,setInterval,clearInterval,StartupSourceSync,
    PrivacyConsent:{isAccepted:()=>true,requireAccepted(){}},AiServiceAccess:{isAllowed:()=>true},getContext:()=>({}),dataManagerInfo(){},
    MailStore:class{settings(){return {enabled:state.mail,aiAllowed:true};}},CalendarMemoryStore:class{settings(){return {enabled:state.calendar};}},
    CalendarMemoryService:{canAutoRefresh:async()=>state.calendar,refresh:async()=>{state.calendarReads++;}},
    MailService:{isBusy:()=>false,canAutoRefresh:async()=>{if(state.readinessGate)await state.readinessGate;return state.mail;},refresh:async(_dir,_config,_message,progress)=>{
      state.mailCalls++;state.mailBegins.push({stage:page.dataManagerProgressStage,automatic:page.startupSourceSyncRunning,failed:page.dataManagerSyncFailed});
      progress({stage:'AI筛选邮件',message:'正在分析邮件',current:1,total:2,percent:70});
      if(state.failMail)throw Error('mail incomplete');}},showToastSafely(){}});
  page=new exp.Probe();Object.assign(page,{filesDir:'/operation',pageVisible:true,dataManagerRefreshing:false,memoryProgressTimerId:-1,memoryOperationEpoch:0,
    startupSourceSyncEnabled:true,ensurePrivacyConsent:async()=>true,ensureAiServiceLogin:()=>true,getDataManagerModelConfig:()=>config,
    reloadDataManagerViewModels(){},refreshDataManager:async()=>{state.fullCalls++;},dataManagerFacade:{modelActivities:()=>[],refreshSourceMemory:async(_config,chat,calendar)=>{
      state.memoryCalls.push({chat,calendar});if(state.failChat)throw Error('profile incomplete');}}});return {page,state};
}

test('failed automatic work remains visible; mail starts fresh and retry never launches unrelated memory analysis',async()=>{
  reset();const {page,state}=memoryOperationProbe();state.failChat=true;await page.syncDailyStartupSources();
  assert.equal(page.dataManagerSyncFailed,true);assert.equal(page.dataManagerRefreshing,false);assert.equal(page.dataManagerProgressStage,'部分来源未完成');
  new StartupSourceSync('/operation').setEnabled(false);page.startupSourceSyncEnabled=false;state.mail=true;state.failMail=true;
  await assert.rejects(page.syncMailReminders(),/mail incomplete/);
  assert.deepEqual(state.mailBegins[0],{stage:'读取邮件',automatic:false,failed:false});
  assert.ok(!page.dataManagerProgressMessage.includes('自动更新'));assert.equal(page.memoryOperationKind,'mail');
  state.failMail=false;await page.retryMemoryOperation();assert.equal(state.mailCalls,2);assert.equal(state.fullCalls,0);
  assert.equal(state.memoryCalls.length,1);assert.equal(page.dataManagerSyncFailed,false);assert.equal(page.memoryProgressTimerId,-1);
});

test('calendar analysis uses selected-source memory and never rereads email or imports task/gallery data',async()=>{
  reset();const {page,state}=memoryOperationProbe();state.calendar=true;state.mail=true;
  const scheduler=new StartupSourceSync('/operation');scheduler.markSynced('calendar',Date.now()-25*3600000);
  await page.syncCalendarMemory();assert.deepEqual(state.memoryCalls,[{chat:false,calendar:true}]);
  assert.equal(state.mailCalls,0);assert.equal(state.fullCalls,0);assert.equal(page.dataManagerSyncFailed,false);
  assert.equal(scheduler.hasDue({mail:false,calendar:true,chat:false}),true,'Reanalyzing a cached snapshot is not a fresh calendar read');
});

test('manual source success suppresses automatic repeats and explicit failed-source retry works with automation disabled',async()=>{
  reset();const {page,state}=memoryOperationProbe();await page.syncDailyStartupSources();
  assert.equal(page.dataManagerProgressStage,'已自动更新');state.mail=true;
  await page.syncMailReminders();assert.equal(state.mailBegins[0].stage,'读取邮件');
  assert.equal(new StartupSourceSync('/operation').hasDue({mail:true,calendar:false,chat:true}),false);
  reset();const failed=memoryOperationProbe();failed.state.failChat=true;await failed.page.syncDailyStartupSources();
  new StartupSourceSync('/operation').setEnabled(false);failed.page.startupSourceSyncEnabled=false;failed.state.failChat=false;
  await failed.page.retryMemoryOperation();assert.equal(failed.page.memoryOperationKind,'startup-retry');
  assert.equal(failed.page.dataManagerSyncFailed,false);assert.equal(failed.state.memoryCalls.length,2);
  assert.equal(failed.state.mailCalls,0);assert.equal(failed.state.fullCalls,0);
});

test('calendar panel delegates one read-and-analysis operation and never retries analysis from a catch block',async()=>{
  reset();const {page,state}=memoryOperationProbe();state.calendar=true;state.failChat=true;
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/components/CalendarMemoryPanel.ets'),'utf8')
    .replace(/\bstruct CalendarMemoryPanel\b/,'class CalendarMemoryPanel');
  const tree=ts.createSourceFile('CalendarPanel.ts',source,ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='CalendarMemoryPanel');
  const method=component.members.find(n=>ts.isMethodDeclaration(n)&&n.name.getText(tree)==='synchronize').getText(tree);
  const exp={};vm.runInNewContext(ts.transpileModule('exports.Panel=class Panel {'+method+'}',
    {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{exports:exp});
  let callbacks=0;const panel=new exp.Panel();Object.assign(panel,{busy:false,memoryRefreshing:false,reload(){},
    onSync:async()=>{await page.syncCalendarMemory(true);},onMemoryChanged:async()=>{callbacks++;}});
  await panel.synchronize();assert.equal(state.calendarReads,1);assert.equal(state.memoryCalls.length,1);
  assert.equal(callbacks,0);assert.equal(panel.failed,true);assert.equal(panel.busy,false);assert.equal(page.dataManagerSyncFailed,true);
});

test('the compatibility profile entry shares short-ID generation and never feeds removed historical claims back into the model',async()=>{
  reset();const client=new DataPipelineModelClient(),input=[event('current/a'),event('current/b')];let calls=0;
  cloudHandler=async options=>{calls++;const data=JSON.parse(options.messages[1].content);
    assert.equal(data.previous_claims.length,0);
    assert.ok(!(options.messages[1].content).includes('deleted-evidence'));
    return profileAnswer(data);};
  const result=await client.generateProfile('work',input,[{statement:'outdated',event_ids:['deleted-evidence']}],config);
  assert.equal(result.generation,'model');assert.ok(calls>=2);
  assert.ok(result.claims.every(c=>c.event_ids.every(id=>input.some(e=>e.event_id===id))));
});

test('a stale asynchronous startup check cannot take over progress after an explicit mail read has finished',async()=>{
  reset();const {page,state}=memoryOperationProbe();state.mail=true;
  let release;state.readinessGate=new Promise(resolve=>{release=resolve;});
  const automatic=page.syncDailyStartupSources();await Promise.resolve();
  await page.syncMailReminders();release();await automatic;
  assert.equal(state.mailCalls,1);assert.equal(state.memoryCalls.length,0);
  assert.equal(page.memoryOperationKind,'mail');assert.equal(page.dataManagerProgressStage,'邮件读取完成');
});

test('sync reminder and recent-sync label use persisted successful activity instead of only the old full snapshot',()=>{
  reset();const reminder=load(base+'DataManagerSyncReminder');
  const oldAt='2026-10-24T12:00:00',old=reminder.syncSnapshotTimeMs(oldAt),day=86400000,now=old+4*day;
  const previous={generated_at:oldAt,files:[{path:'2026-10-24/test.md',entry_count:1}]};
  const facade=Object.create(DataManagerFacade.prototype);facade.paths=paths;facade.storage=storage;
  facade.loadDailyLogSnapshot=()=>clone(previous);
  facade.buildDailyLogSnapshot=()=>({files:[{path:'2026-10-24/test.md',entry_count:2}]});
  facade.formatHomeUpdatedLabel=value=>'label:'+value;
  const chat=mocks['ChatMemorySync.ets'],original=chat.ChatMemorySync;
  chat.ChatMemorySync=class{hasPendingMessages(){return false;}};
  try {
    assert.equal(facade.shouldRemindToSync(now),true);
    for(const source of ['mail','calendar','chat']) {
      reset();const scheduler=new StartupSourceSync('/app');scheduler.markSynced(source,now-day);
      assert.equal(new StartupSourceSync('/app').latestSuccessfulSyncAt(),now-day,'success survives instance recreation');
      const before=writes.length;
      assert.equal(facade.shouldRemindToSync(now),false,source+' succeeded yesterday');
      assert.equal(facade.lastSyncLabel([]),'label:2026-10-27T12:00:00');
      assert.equal(writes.length,before,'reading reminder history does not write state');
      assert.equal(facade.loadDailyLogSnapshot().generated_at,oldAt,'do not rewrite the raw-source ingestion checkpoint');
    }
    reset();const failed=new StartupSourceSync('/app');failed.markAttempted('chat',now-day);failed.markFailed('chat',now-day+1);
    assert.equal(failed.latestSuccessfulSyncAt(),0,'attempts and failures are not successes');
    assert.equal(facade.shouldRemindToSync(now),true);
    assert.equal(reminder.latestSuccessfulSyncTime(oldAt,NaN),oldAt);
    assert.equal(reminder.latestSuccessfulSyncTime('',-1),'');
    assert.equal(reminder.shouldOfferSyncReminder(reminder.latestSuccessfulSyncTime(oldAt,now+day),true,now),false);
  } finally {chat.ChatMemorySync=original;}
});

test('home profile time follows the published text, independently of avatar generation and mail sync',()=>{
  reset();const facade=Object.create(DataManagerFacade.prototype),profile={generated_at:'2026-11-03T01:14:44',event_count:2};
  facade.paths=paths;facade.storage=storage;facade.indexService={loadProfileState:()=>profile};
  facade.homeRecommendationService={pruneInactiveRecommendationsForToday(){}};
  facade.avatarService={homeView:()=>({avatarUpdatedLabel:'2026-09-06T20:00:11',avatarStatus:'stale'})};
  facade.homeProfileDomains=()=>[];facade.homeRecommendations=()=>[];
  facade.formatHomeUpdatedLabel=value=>'text:'+value;facade.lastSyncLabel=()=>{throw Error('Mail activity is not the text-profile clock');};
  const calendar=mocks['CalendarMemoryStore.ets'].CalendarMemoryStore.prototype;
  const previous={settings:calendar.settings,snapshot:calendar.snapshot};
  calendar.settings=()=>({enabled:false});calendar.snapshot=()=>({error:''});
  try {
    const first=facade.loadHomeViewModel();assert.equal(first.updatedLabel,'text:2026-11-03T01:14:44');
    assert.equal(first.avatarUpdatedLabel,'2026-09-06T20:00:11');
    new StartupSourceSync('/app').markSynced('mail',Date.now());
    assert.equal(facade.loadHomeViewModel().updatedLabel,first.updatedLabel);
    profile.generated_at='2026-11-03T10:30:00';
    const next=facade.loadHomeViewModel();assert.equal(next.updatedLabel,'text:2026-11-03T10:30:00');
    assert.equal(next.avatarUpdatedLabel,first.avatarUpdatedLabel);
    const home=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/home/HomePage.ets'),'utf8');
    assert.ok(/Text\('画像摘要由 AI 分析生成'\)[\s\S]*?Text\(this\.profile\.updatedLabel\)/.test(home));
  } finally {calendar.settings=previous.settings;calendar.snapshot=previous.snapshot;}
});

test('a recent source sync never marks earlier unsynced gallery records as ingested',()=>{
  reset();const reminder=load(base+'DataManagerSyncReminder'),oldAt='2026-10-20T12:00:00';
  const old=reminder.syncSnapshotTimeMs(oldAt),day=86400000,photoCreated=old+day;
  new StartupSourceSync('/app').markSynced('mail',old+2*day);
  const facade=Object.create(DataManagerFacade.prototype);facade.paths=paths;facade.storage=storage;
  facade.loadDailyLogSnapshot=()=>({generated_at:oldAt,files:[]});facade.buildDailyLogSnapshot=()=>({files:[]});
  const chat=mocks['ChatMemorySync.ets'],originalChat=chat.ChatMemorySync;
  const gallery=mocks['GalleryMemorySync.ets'].GalleryMemorySync,originalGallery=gallery.hasNewValidResultsSince;
  let cutoff;chat.ChatMemorySync=class{hasPendingMessages(){return false;}};
  gallery.hasNewValidResultsSince=(_root,since)=>{cutoff=since;return photoCreated>since;};
  try {assert.equal(facade.shouldRemindToSync(old+6*day),true);assert.equal(cutoff,old);}
  finally {chat.ChatMemorySync=originalChat;gallery.hasNewValidResultsSince=originalGallery;}
});

test('successful no-change memory checks are durable, while failed pipelines preserve the prior completion time',async()=>{
  reset();const facade=Object.create(DataManagerFacade.prototype);facade.paths=paths;
  facade.storage={beginReadSession(){},endReadSession(){return 0;}};
  facade.indexService={beginSyncRead(){},endSyncRead(){}};
  facade.modelClient={resetSyncMetrics(){},reportSyncMetrics(){}};
  facade.refreshInternal=async()=>({skipped:true});
  const before=Date.now();await facade.refresh(config);
  const completed=new StartupSourceSync('/app').latestSuccessfulSyncAt();assert.ok(completed>=before&&completed<=Date.now());
  assert.equal(storage.exists(storage.join(paths.consolidationRoot,'daily-log-snapshot.json')),false);
  facade.refreshInternal=async()=>{throw Error('fixture interrupted');};
  await assert.rejects(facade.refresh(config),/fixture interrupted/);
  assert.equal(new StartupSourceSync('/app').latestSuccessfulSyncAt(),completed);
});

function reviewRecord(id,text='工作会议：研究端侧模型部署') {
  return {record_id:id,first_seen_date:'2026-10-01',last_seen_date:'2026-10-01',
    source_refs:['2026-10-01/alipay.md#'+id],source_dates:['2026-10-01'],workflow_scene_ids:[0],
    summary:text,normalized_fact:text,raw_excerpts:[],tags:[],dedup_status:'new',model_notes:[],dedup_text:text};
}
function reviewEnrichment(options) {
  return {events:JSON.parse(options.messages[1].content).events.map(e=>({event_id:e.event_id,
    keywords:['研究'],domains:['work'],entities:[],todo:{type:'',deadline:'',text:'',agent_task:''}}))};
}
test('review: real model_batch checkpoints survive a failed profile and process restart',async()=>{
  reset();let calls=0;cloudHandler=async options=>{calls++;return JSON.stringify(reviewEnrichment(options));};
  const real=new DataPipelineModelClient(),model=new Model();model.enrichEvents=real.enrichEvents.bind(real);model.fail=true;
  storage.writeJsonAtomic(paths.outputStatePath('2026-10','alipay.md'),{metadata:{},records:[reviewRecord(1),reviewRecord(2)]});
  await assert.rejects(new IndexService(paths,storage,model).build(config),/interrupted/);
  const before=calls;model.fail=false;await new IndexService(paths,storage,model).build(config);
  assert.equal(calls,before,'Production model_batch successes must not be requested again');
  assert.ok(Object.values(new IndexService(paths,storage,model).loadEvents()).every(e=>e.enrichment_method==='model_batch'));
});
test('review: real calendar enrichment retains plan metadata and reuses completed series',async()=>{
  reset();let calls=0;cloudHandler=async options=>{calls++;return JSON.stringify(reviewEnrichment(options));};
  const real=new DataPipelineModelClient(),service=new IndexService(paths,storage,real);
  calendarEvents=[event('calendar:a','2026-10-01',{calendar:{seriesKey:'same-series',start:1,end:2,profileEnabled:true}}),
    event('calendar:b','2026-10-02',{calendar:{seriesKey:'same-series',start:3,end:4,profileEnabled:true}})];
  const enriched=await real.enrichEvents([calendarEvents[0]],config);assert.deepEqual(clone(enriched[0].calendar),calendarEvents[0].calendar);
  const previous={};await service.buildCalendarEvents(previous,{},config);const before=calls;
  await new IndexService(paths,storage,real).buildCalendarEvents({},previous,config);
  assert.equal(calls,before,'A repeat series is classified once across syncs');
});
test('review: enabled model failure or omitted classification cannot publish successful heuristic indexes',async()=>{
  reset();const real=new DataPipelineModelClient(),model=new Model();model.enrichEvents=real.enrichEvents.bind(real);
  storage.writeJsonAtomic(paths.outputStatePath('2026-10','alipay.md'),{metadata:{},records:[reviewRecord(1)]});
  cloudHandler=async()=>{throw Error('fixture network failure');};
  const failedService=new IndexService(paths,storage,model),failed=await failedService.build(config);
  assert.equal(failed.failedEventCount,1);
  assert.equal(Object.keys(failedService.loadEvents()).length,0,'Failed events must never publish heuristic facts');
  let attempts=0;cloudHandler=async()=>{attempts++;return JSON.stringify({events:[]});};
  await assert.rejects(real.enrichEvents([event('missing')],config),/遗漏|完整/);assert.ok(attempts<=3);
  cloudHandler=async options=>{const data=reviewEnrichment(options);data.events.push(data.events[0]);return JSON.stringify(data);};
  await assert.rejects(real.enrichEvents([event('duplicate')],config),/重复/);
  cloudHandler=async options=>JSON.stringify({events:JSON.parse(options.messages[1].content).events.map(e=>({event_id:e.event_id}))});
  await assert.rejects(real.enrichEvents([event('incomplete')],config),/字段不完整/);
  await assert.rejects(real.enrichEvents([event('unconfigured')],{...config,baseUrl:''}),/配置/);
});
test('review: a previously published heuristic fallback is repaired rather than certified as complete',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  storage.writeJsonAtomic(paths.outputStatePath('2026-10','alipay.md'),{metadata:{},records:[reviewRecord(1),reviewRecord(2)]});
  await service.build(config);assert.equal(service.hasCompletePublishedIndex(config),true);
  const file=paths.eventPartitionPath('2026-10'),partition=storage.readJson(file,null);
  partition.events[0].enrichment_method='heuristic_batch_fallback';storage.writeJsonAtomic(file,partition);
  assert.equal(service.hasCompletePublishedIndex(config),false);
  await service.build(config);assert.equal(service.hasCompletePublishedIndex(config),true);
  assert.ok(Object.values(service.loadEvents()).every(e=>['model','model_batch'].includes(e.enrichment_method)));
});
test('review: zero effective facts are a valid published result; missing index or profile is not',async()=>{
  reset();const service=new IndexService(paths,storage,new Model()),facade=Object.create(DataManagerFacade.prototype);
  facade.paths=paths;facade.storage=storage;facade.indexService=service;
  storage.writeJsonAtomic(paths.outputStatePath('2026-10','alipay.md'),{metadata:{},records:[]});
  const snapshot={tree_hash:'same',pipeline_hash:'same-policy',file_count:1,entry_count:1};
  assert.equal(facade.canSkipRefresh(snapshot,snapshot),false);
  await service.build({...config,enabled:false});assert.equal(facade.canSkipRefresh(snapshot,snapshot),true);
  storage.removeFile(paths.indexesRoot+'/inverted/index.json');assert.equal(facade.canSkipRefresh(snapshot,snapshot),false);
  await service.build({...config,enabled:false});storage.removeFile(paths.indexesRoot+'/profile/state.json');
  assert.equal(facade.canSkipRefresh(snapshot,snapshot),false);
});
test('review: partial refresh preserves each source model identity and full refresh reuses matching chat',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  const task=paths.outputStatePath('2026-10','alipay.md'),chat=paths.outputStatePath('2026-10','app-chat__cloud__0.md');
  storage.writeJsonAtomic(task,{metadata:{},records:[reviewRecord(1)]});await service.build(config);
  storage.writeJsonAtomic(chat,{metadata:{},records:[reviewRecord(2)]});
  const next={...config,model:'model-b'};await service.build(next,undefined,{chat:true,calendar:false,statePaths:[chat]});
  const before=model.enriched.length;await service.build(next);
  assert.equal(model.enriched.length-before,1,'Only the historical source still using model-a needs classification');
  await service.build(config,undefined,{chat:true,calendar:false,statePaths:[chat]});
  assert.equal(service.hasCompletePublishedIndex(next),false,'A source-scoped model switch cannot certify a full snapshot');
  const afterPartial=model.enriched.length;await service.build(next);
  assert.equal(model.enriched.length-afterPartial,1,'The chat switched back to model-a must not be reused as model-b');
  const count=model.enriched.length;await service.build(next);assert.equal(model.enriched.length,count);
});
test('review: parallel failure stops queued jobs and waits for in-flight jobs before releasing the sync',async()=>{
  const {runLimitedTasks}=load(base+'DataManagerUtils');let release;const gate=new Promise(resolve=>release=resolve),steps=[];
  const work=runLimitedTasks([async()=>{steps.push('failure');throw Error('fixture failed');},
    async()=>{steps.push('active');await gate;steps.push('drained');},async()=>{steps.push('must-not-start');}],2);
  let settled=false;const result=work.then(()=>{settled=true;},error=>{settled=true;return error;});
  await new Promise(resolve=>setImmediate(resolve));assert.equal(settled,false,'The old job must still own its lifecycle');
  release();assert.match((await result).message,/fixture failed/);
  assert.deepEqual(steps,['failure','active','drained']);
});
test('review: the production index also waits for active writers after a sibling fails',async()=>{
  reset();let release;const gate=new Promise(resolve=>release=resolve),model=new Model(),steps=[];
  model.enrichEvents=async events=>{
    if(events[0]?.source_state_file.includes('fail.md'))throw Error('fixture index failure');
    steps.push('active');await gate;steps.push('checkpoint');return events.map(e=>({...e,domains:['work'],enrichment_method:'model_batch'}));
  };
  for(const name of ['fail.md','slow.md'])storage.writeJsonAtomic(paths.outputStatePath('2026-10',name),{metadata:{},records:[reviewRecord(1)]});
  let settled=false;const work=new IndexService(paths,storage,model).build(config).then(()=>{settled=true;},error=>{settled=true;return error;});
  await new Promise(resolve=>setImmediate(resolve));assert.equal(settled,false);
  release();assert.match((await work).message,/index failure/);assert.deepEqual(steps,['active','checkpoint']);
  assert.equal(storage.exists(paths.indexesRoot+'/manifest.json'),false);
  const count=writes.length;await new Promise(resolve=>setImmediate(resolve));assert.equal(writes.length,count);
});
test('review: profile merges cannot cite domain facts absent from the candidate summaries',async()=>{
  reset();const input=[event('a'),event('b'),event('not-in-this-merge')],model=new DataPipelineModelClient();
  cloudHandler=async()=>JSON.stringify({short_summary:'模型研究',summary:'关注模型研究',claims:[
    {statement:'关注端侧模型研究',kind:'topic',confidence:'medium',event_ids:['not-in-this-merge','a']} ]});
  await assert.rejects(model.combineProfileBlocks('work',[payload(input.slice(0,2))],input,config,true),/不存在的证据/);
});
test('review: progress distinguishes cached source checks and group reuse from model generation',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);let groupCalls=0;
  model.planCollectionGroups=async()=>{groupCalls++;return [];};model.assignCollectionGroupEvents=async()=>{groupCalls++;return [];};
  storage.writeJsonAtomic(paths.outputStatePath('2026-10','alipay.md'),{metadata:{},records:[reviewRecord(1)]});
  await service.build(config);const progress=[],before=model.enriched.length;await service.build(config,p=>progress.push(p.message));
  assert.equal(model.enriched.length,before);assert.ok(!progress.some(p=>p.startsWith('批量增强')));
  const {CollectionGroupingService}=load(base+'CollectionGroupingService'),groups=new CollectionGroupingService(paths,storage,model,service);
  await groups.buildAll(config);const groupProgress=[],old=groupCalls;const result=await groups.buildAll(config,p=>groupProgress.push(p.message));
  assert.equal(groupCalls,old);assert.equal(result.updatedGroupDocs,0);assert.equal(result.reusedGroupDocs,12);
  assert.ok(!groupProgress.some(p=>p.startsWith('生成')||p.startsWith('已生成')));assert.ok(groupProgress.some(p=>p.includes('复用')));
});
test('review: the full facade persists its result and skips unchanged work after recreation',async()=>{
  reset();const chat=mocks['ChatMemorySync.ets'],gallery=mocks['GalleryMemorySync.ets'].GalleryMemorySync;
  const oldChat=chat.ChatMemorySync,oldSync=gallery.sync;
  const avatar=mocks['AvatarService.ets'].AvatarService.prototype,oldReady=avatar.ensureReady;
  chat.ChatMemorySync=class {static dailyLogRelativePaths(){return [];}async sync(){return {processedParts:0,factCount:0};}};
  gallery.sync=()=>{};avatar.ensureReady=()=>{};
  try {
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/alipay.md','1. 工作会议：研究端侧模型部署\n');
    const disabled={...config,enabled:false},first=new DataManagerFacade('/app');
    const initial=await first.refreshInternal(disabled);assert.equal(initial.skipped,false);
    const before=clone([...disk.entries()].filter(([file])=>file.startsWith(paths.indexesRoot+'/')));
    const recreated=new DataManagerFacade('/app'),messages=[];
    recreated.indexService.build=async()=>{throw Error('Unchanged index must not rebuild');};
    cloudHandler=async()=>{throw Error('Unchanged sync must not call a model');};
    const second=await recreated.refreshInternal(disabled,p=>messages.push(p.message));assert.equal(second.skipped,true);
    assert.ok(!messages.some(message=>message.includes('整理 alipay')||message.includes('生成画像')));
    assert.deepEqual(clone([...disk.entries()].filter(([file])=>file.startsWith(paths.indexesRoot+'/'))),before);
  } finally {chat.ChatMemorySync=oldChat;gallery.sync=oldSync;avatar.ensureReady=oldReady;}
});

async function sourceFacade(run) {
  reset();trackSourceChanges=true;
  const chat=mocks['ChatMemorySync.ets'],gallery=mocks['GalleryMemorySync.ets'].GalleryMemorySync;
  const oldChat=chat.ChatMemorySync,oldSync=gallery.sync,avatar=mocks['AvatarService.ets'].AvatarService.prototype,oldReady=avatar.ensureReady;
  chat.ChatMemorySync=class {static dailyLogRelativePaths(){return [];}async sync(){return {processedParts:0,factCount:0};}};
  gallery.sync=()=>{};avatar.ensureReady=()=>{};
  try {await run(new DataManagerFacade('/app'),{...config,enabled:false});}
  finally {chat.ChatMemorySync=oldChat;gallery.sync=oldSync;avatar.ensureReady=oldReady;trackSourceChanges=false;}
}
test('sources: captured revisions acknowledge only successful work and preserve concurrent changes',()=>{
  reset();const {MemoryChangeJournal}=load(base+'MemoryChangeJournal'),journal=new MemoryChangeJournal('/app',storage);
  journal.mark('daily','2026-10-01/a.md');const captured=journal.pending('daily');
  journal.mark('daily','2026-10-01/a.md');journal.mark('daily','2026-10-02/b.md');journal.acknowledge(captured);
  assert.equal(journal.pending('daily').length,2);
  journal.acknowledge(journal.pending('daily'));journal.setReady('daily');assert.equal(journal.pending('daily').length,0);
  const file=paths.consolidationRoot+'/source-changes/daily.json';disk.set(file,'damaged');
  assert.throws(()=>journal.pending('daily'),/完整检查/);assert.equal(journal.pending('daily',true)[0].path,'*');
  assert.throws(()=>journal.mark('daily','../outside'),/路径/);
});
test('sources: source writers track daily changes, gallery dates, chat sessions and deletion',()=>{
  reset();trackSourceChanges=true;const {MemoryChangeJournal}=load(base+'MemoryChangeJournal'),journal=new MemoryChangeJournal('/app',storage);
  storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/a.md','one');
  storage.writeTextAtomic('/app/gallery-log/items/2026-10-01/photo.json','{}');
  storage.writeTextAtomic('/app/chat-sessions/sessions/chat-1.json','{}');
  assert.equal(journal.pending('daily')[0].path,'2026-10-01/a.md');assert.equal(journal.pending('gallery')[0].path,'2026-10-01');
  assert.equal(journal.pending('chat')[0].path,'chat-1');
  journal.acknowledge(journal.pending('daily'));storage.removeFile(paths.dailyLogRoot+'/2026-10-01/a.md');
  assert.equal(journal.pending('daily').length,1);trackSourceChanges=false;
});
test('sources: unchanged sync never reads raw logs, old consolidated states or event partitions as history grows',async()=>{
  const benchmark=[];
  for(const count of [30,300])await sourceFacade(async(facade,cfg)=>{
    for(let i=0;i<count;i++)storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/task-'+i+'.md','1. 工作会议研究 '+i+'\n');
    await facade.refreshInternal(cfg);reads.clear();writes.length=0;hashedChars=0;
    const second=await new DataManagerFacade('/app').refreshInternal(cfg);assert.equal(second.skipped,true);
    const historyReads=[...reads.entries()].filter(([file])=>file.startsWith(paths.dailyLogRoot+'/')||
      file.endsWith('.md.state.json')||/\/indexes\/events\/\d{4}-\d{2}\.json$/.test(file));
    assert.deepEqual(historyReads,[]);assert.ok(!writes.some(file=>file===paths.consolidationRoot+'/daily-log-snapshot.json'));
    benchmark.push({historyFiles:count,historyReads:historyReads.length,hashCharacters:hashedChars,fileReads:[...reads.values()].reduce((a,b)=>a+b,0)});
  });
  assert.equal(benchmark[0].hashCharacters,benchmark[1].hashCharacters);console.log('SOURCE_NO_CHANGE_BENCHMARK '+JSON.stringify(benchmark));
});
test('sources: one edit reads and consolidates only its month/source and preserves other history',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    for(let i=0;i<12;i++)storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/task-'+i+'.md','1. 工作会议研究 '+i+'\n');
    await facade.refreshInternal(cfg);const before=clone(facade.indexService.loadEvents());
    const changed=paths.dailyLogRoot+'/2026-10-01/task-3.md';storage.writeTextAtomic(changed,'1. 工作会议研究新方向\n2. 工作会议研究部署\n');
    reads.clear();await facade.refreshInternal(cfg);
    assert.deepEqual([...reads.keys()].filter(file=>file.startsWith(paths.dailyLogRoot+'/')&&file.endsWith('.md')),[changed]);
    assert.deepEqual([...reads.keys()].filter(file=>file.endsWith('.md.state.json')),[paths.outputStatePath('2026-10','task-3.md')]);
    const after=facade.indexService.loadEvents();for(const id of Object.keys(before).filter(id=>!id.includes('task-3.md')))assert.deepEqual(clone(after[id]),before[id]);
    const {MemoryChangeJournal}=load(base+'MemoryChangeJournal');assert.equal(new MemoryChangeJournal('/app',storage).pending('daily').length,0);
    storage.removeFile(changed);await facade.refreshInternal(cfg);assert.ok(!Object.keys(facade.indexService.loadEvents()).some(id=>id.includes('task-3.md')),logs.filter(line=>/SYNC_|Index build|Index source/.test(line)).slice(-35).join('\n'));
  });
});
test('sources: failure keeps changes pending and a write arriving during sync is processed next time',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    const file=paths.dailyLogRoot+'/2026-10-01/task.md';storage.writeTextAtomic(file,'1. 工作会议研究初版\n');await facade.refreshInternal(cfg);
    const build=facade.indexService.build.bind(facade.indexService);storage.writeTextAtomic(file,'1. 工作会议研究二版\n');
    facade.indexService.build=async()=>{throw Error('fixture interruption');};
    await assert.rejects(facade.refreshInternal(cfg),/interruption/);
    const {MemoryChangeJournal}=load(base+'MemoryChangeJournal'),journal=new MemoryChangeJournal('/app',storage);assert.equal(journal.pending('daily').length,1);
    let release,entered;const gate=new Promise(resolve=>release=resolve),started=new Promise(resolve=>entered=resolve);
    facade.indexService.build=async(...args)=>{entered();await gate;return build(...args);};
    const work=facade.refreshInternal(cfg);await started;storage.writeTextAtomic(file,'1. 工作会议研究三版\n');release();await work;
    assert.equal(journal.pending('daily').length,1);facade.indexService.build=build;await facade.refreshInternal(cfg);
    assert.equal(journal.pending('daily').length,0);assert.ok(JSON.stringify(facade.indexService.loadEvents()).includes('三版'));
  });
});
test('sources: a changed month/source is rebuilt from all its days without rereading other months',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    for(const[date,text]of [['2026-09-10','工作会议讨论九月计划'],['2026-10-01','工作会议讨论甲方案'],['2026-10-02','工作会议讨论乙方案']])
      storage.writeTextAtomic(paths.dailyLogRoot+'/'+date+'/task.md','1. '+text+'\n');
    await facade.refreshInternal(cfg);const previous=clone(facade.indexService.loadEvents());
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-02/task.md','1. 工作会议讨论丙方案\n');reads.clear();
    await facade.refreshInternal(cfg);assert.equal(reads.get(paths.dailyLogRoot+'/2026-09-10/task.md')||0,0);
    assert.ok(reads.has(paths.dailyLogRoot+'/2026-10-01/task.md'));
    const current=facade.indexService.loadEvents(),text=JSON.stringify(current);assert.ok(text.includes('甲方案'));assert.ok(text.includes('丙方案'));assert.ok(!text.includes('乙方案'));
    for(const id of Object.keys(previous).filter(id=>id.startsWith('2026-09/')))assert.deepEqual(clone(current[id]),previous[id]);
  });
});
test('sources: unchanged same-day recommendations reuse receipts, while a day change rechecks time-sensitive items',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/task.md','1. 工作会议讨论计划\n');await facade.refreshInternal(cfg);
    let calls=0;const build=facade.homeRecommendationService.build.bind(facade.homeRecommendationService);
    facade.homeRecommendationService.build=async(...args)=>{calls++;return build(...args);};
    await facade.refreshInternal(cfg);assert.equal(calls,0);
    const snapshotFile=paths.consolidationRoot+'/daily-log-snapshot.json',snapshot=storage.readJson(snapshotFile,null);
    snapshot.recommendations_day='2000-01-01';storage.writeJsonAtomic(snapshotFile,snapshot);
    await facade.refreshInternal(cfg);assert.equal(calls,1);await facade.refreshInternal(cfg);assert.equal(calls,1);
  });
});
test('sources: idle automatic chat updates skip historical chat consolidation as well as extraction',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/task.md','1. 工作会议讨论计划\n');await facade.refreshInternal(cfg);
    const {MemoryChangeJournal}=load(base+'MemoryChangeJournal');new MemoryChangeJournal('/app',storage).setReady('chat');
    facade.consolidationService.consolidateChat=async()=>{throw Error('Idle chat must not scan historical outputs');};
    reads.clear();await facade.refreshSourceMemory(cfg,true,false);
    assert.ok(![...reads.keys()].some(file=>file.startsWith(paths.dailyLogRoot+'/')||file.endsWith('.md.state.json')));
  });
});
test('sources: calendar-only changes retain task sources without rereading raw or consolidated history',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/task.md','1. 工作会议讨论计划\n');await facade.refreshInternal(cfg);
    const previous=clone(facade.indexService.loadEvents());
    calendarEvents=[event('calendar:new','2026-10-02',{calendar:{seriesKey:'new',start:1,end:2,profileEnabled:false}})];
    reads.clear();await facade.refreshInternal(cfg);
    assert.ok(![...reads.keys()].some(file=>file.startsWith(paths.dailyLogRoot+'/')||file.endsWith('.md.state.json')));
    const current=facade.indexService.loadEvents();assert.ok(current['calendar:new']);
    for(const id of Object.keys(previous))assert.deepEqual(clone(current[id]),previous[id]);
  });
});

test('isolation: upgrading a source catalog does not recheck historical task indexes for a calendar update',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    for(let i=0;i<77;i++)storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/alipay-'+i+'.md','1. 工作会议讨论计划 '+i+'\n');
    await facade.refreshInternal(cfg);
    const snapshotPath=paths.consolidationRoot+'/daily-log-snapshot.json',snapshot=storage.readJson(snapshotPath,null);
    delete snapshot.catalog_schema;delete snapshot.calendar_hash;delete snapshot.index_revision;
    storage.writeJsonAtomic(snapshotPath,snapshot);
    storage.removeFile(paths.consolidationRoot+'/source-changes/daily-ready');
    const before=clone(facade.indexService.loadEvents());
    calendarEvents=[event('calendar:upgrade','2026-10-02',{calendar:{seriesKey:'upgrade',start:1,end:2,profileEnabled:false}})];
    reads.clear();const progress=[];await new DataManagerFacade('/app').refreshInternal(cfg,value=>progress.push(value));
    assert.equal([...reads.keys()].filter(file=>file.endsWith('.md.state.json')).length,0);
    assert.ok(!progress.some(value=>value.stage==='检查索引'));
    const after=new IndexService(paths,storage,new Model()).loadEvents();
    for(const id of Object.keys(before))assert.deepEqual(clone(after[id]),before[id]);
    reads.clear();await new DataManagerFacade('/app').refreshInternal(cfg);
    assert.ok(![...reads.keys()].some(file=>file.startsWith(paths.dailyLogRoot+'/')||file.endsWith('.md.state.json')));
  });
});

test('isolation: one historical model identity cannot turn a calendar-only refresh into a full task scan',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    for(let i=0;i<12;i++)storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/alipay-'+i+'.md','1. 工作会议讨论计划 '+i+'\n');
    await facade.refreshInternal(cfg);
    const manifestPath=paths.indexesRoot+'/manifest.json',manifest=storage.readJson(manifestPath,null);
    const key=Object.keys(manifest.sources)[0];manifest.sources[key].enrichment.model_name='historical-model';
    storage.writeJsonAtomic(manifestPath,manifest);
    const before=clone(facade.indexService.loadEvents());
    calendarEvents=[event('calendar:mixed','2026-10-02',{calendar:{seriesKey:'mixed',start:1,end:2,profileEnabled:false}})];
    reads.clear();const progress=[];await new DataManagerFacade('/app').refreshInternal(cfg,value=>progress.push(value));
    assert.ok(![...reads.keys()].some(file=>file.startsWith(paths.dailyLogRoot+'/')||file.endsWith('.md.state.json')));
    assert.ok(!progress.some(value=>value.stage==='检查索引'));
    assert.equal(storage.readJson(manifestPath,null).sources[key].enrichment.model_name,'historical-model');
    const after=new IndexService(paths,storage,new Model()).loadEvents();
    for(const id of Object.keys(before))assert.deepEqual(clone(after[id]),before[id]);
  });
});

test('isolation: manual sync adopts an already published automatic calendar generation without rebuilding it',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/alipay.md','1. 工作会议讨论计划\n');
    await facade.refreshInternal(cfg);
    calendarEvents=[event('calendar:auto','2026-10-02',{calendar:{seriesKey:'auto',start:1,end:2,profileEnabled:false}})];
    await facade.refreshSourceMemory(cfg,false,true);
    const revision=facade.indexService.completion().revision;
    reads.clear();const progress=[];await new DataManagerFacade('/app').refreshInternal(cfg,value=>progress.push(value));
    assert.equal(facade.indexService.completion().revision,revision);
    assert.ok(![...reads.keys()].some(file=>file.startsWith(paths.dailyLogRoot+'/')||file.endsWith('.md.state.json')||
      /\/indexes\/events\/\d{4}-\d{2}\.json$/.test(file)));
    assert.ok(!progress.some(value=>value.stage==='生成画像'||value.stage==='检查索引'));
  });
});

test('isolation: real calendar model timeout is skipped without analyzing untouched historical tasks',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    for(let i=0;i<12;i++)storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/alipay-'+i+'.md','1. 工作会议讨论计划 '+i+'\n');
    await facade.refreshInternal(cfg);
    const real=new DataPipelineModelClient(),model=new Model(),seen=[];
    model.enrichEvents=real.enrichEvents.bind(real);
    facade.modelClient=model;facade.indexService=new IndexService(paths,storage,model);
    let fail=true;
    cloudHandler=async options=>{
      const ids=JSON.parse(options.messages[1].content).events.map(item=>item.event_id);seen.push(...ids);
      assert.ok(ids.every(id=>id==='calendar:timeout'));
      if(fail)throw Error('Operator timeout');return JSON.stringify(reviewEnrichment(options));
    };
    calendarEvents=[event('calendar:timeout','2026-10-02',{enrichment_method:'calendar-structured-v1',
      calendar:{seriesKey:'timeout',start:1,end:2,profileEnabled:false}})];
    const taskIds=Object.keys(facade.indexService.loadEvents()).sort();
    reads.clear();const failed=await facade.refreshInternal(config,undefined,cfg);
    assert.equal(failed.failedEventCount,1);
    assert.deepEqual(Object.keys(facade.indexService.loadEvents()).sort(),taskIds);
    assert.ok(![...reads.keys()].some(file=>file.endsWith('.md.state.json')||file.startsWith(paths.dailyLogRoot+'/')));
    const requests=seen.length;fail=false;reads.clear();await facade.refreshInternal(config,undefined,cfg);
    assert.equal(seen.length,requests,'The same failed calendar input is not retried automatically');
    assert.ok(![...reads.keys()].some(file=>file.endsWith('.md.state.json')||file.startsWith(paths.dailyLogRoot+'/')));
    const calls=seen.length;await facade.refreshInternal(config,undefined,cfg);assert.equal(seen.length,calls);
    assert.equal(facade.indexService.completion().complete,true);
  });
});

test('isolation: migration still detects a real task edit and updates only its source',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    for(let i=0;i<12;i++)storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/alipay-'+i+'.md','1. 工作会议讨论计划 '+i+'\n');
    await facade.refreshInternal(cfg);
    const snapshotPath=paths.consolidationRoot+'/daily-log-snapshot.json',snapshot=storage.readJson(snapshotPath,null);
    delete snapshot.catalog_schema;storage.writeJsonAtomic(snapshotPath,snapshot);
    storage.removeFile(paths.consolidationRoot+'/source-changes/daily-ready');
    disk.set(paths.dailyLogRoot+'/2026-10-01/alipay-3.md','1. 工作会议讨论新的研究方向\n');
    reads.clear();await facade.refreshInternal(cfg);
    assert.ok([...reads.keys()].filter(file=>file.endsWith('.md.state.json')).every(file=>file.endsWith('/alipay-3.md.state.json')));
    assert.ok(JSON.stringify(facade.indexService.loadEvents()).includes('新的研究方向'));
  });
});

test('isolation: index timeout diagnostics identify the failing source and preserve the published generation',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  const file=paths.outputStatePath('2026-10','com.alipay.mobile.client.md');
  storage.writeJsonAtomic(file,{metadata:{},records:[reviewRecord(1)]});await service.build(config);
  const manifest=storage.readText(paths.indexesRoot+'/manifest.json');
  storage.writeJsonAtomic(file,{metadata:{},records:[reviewRecord(1,'工作会议讨论新方案')]});
  model.enrichEvents=async()=>{throw Error('事件分析的模型请求超时');};
  await assert.rejects(service.build(config),/支付宝：事件分析的模型请求超时/);
  assert.equal(storage.readText(paths.indexesRoot+'/manifest.json'),manifest);
  assert.ok(logs.some(line=>line.includes('SYNC_SOURCE_FAILED source=2026-10/com.alipay.mobile.client.md.state.json')));
});

test('isolation: elapsed calendar occurrences invalidate index receipts without scanning task sources',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/alipay.md','1. 工作会议讨论计划\n');await facade.refreshInternal(cfg);
    const before=facade.indexService.completion().revision;
    calendarIndexEpoch='past-cutoff-changed';reads.clear();await facade.refreshInternal(cfg);
    const after=facade.indexService.completion().revision;assert.notEqual(after,before);
    assert.ok(![...reads.keys()].some(file=>file.endsWith('.md.state.json')||file.startsWith(paths.dailyLogRoot+'/')));
    await facade.refreshInternal(cfg);assert.equal(facade.indexService.completion().revision,after);
  });
});

test('legacy recovery: 809 unchanged raw logs and a missing completion marker do not rescan 77 task states',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    for(let i=0;i<809;i++){
      const date='2026-10-'+String(Math.floor(i/77)+1).padStart(2,'0');
      storage.writeTextAtomic(paths.dailyLogRoot+'/'+date+'/task-'+(i%77)+'.md','1. 工作会议讨论计划 '+i+'\n');
    }
    await facade.refreshInternal(cfg);
    const snapshotPath=paths.consolidationRoot+'/daily-log-snapshot.json',snapshot=storage.readJson(snapshotPath,null);
    delete snapshot.catalog_schema;delete snapshot.calendar_hash;delete snapshot.index_revision;
    storage.writeJsonAtomic(snapshotPath,snapshot);storage.removeFile(paths.indexesRoot+'/completion.json');
    storage.removeFile(paths.consolidationRoot+'/source-changes/daily-ready');
    // An old/failed derived state is not evidence of an edit to the original.
    const statePath=paths.outputStatePath('2026-10','task-0.md'),state=storage.readJson(statePath,null);
    for(const ref of Object.keys(state.metadata.processed_entry_hashes))state.metadata.processed_entry_hashes[ref]='legacy-processing-version';
    state.records[0].normalized_fact='未发布的派生文本，不应被无变化同步导入';
    storage.writeJsonAtomic(statePath,state);
    calendarEvents=[event('calendar:legacy','2026-10-02',{calendar:{seriesKey:'legacy',start:1,end:2,profileEnabled:false}})];
    reads.clear();const progress=[];await facade.refreshInternal(cfg,value=>progress.push(value));
    assert.equal([...reads.keys()].filter(file=>file.endsWith('.md.state.json')).length,0);
    assert.ok(!progress.some(value=>value.stage==='检查索引'));
    assert.ok(!JSON.stringify(facade.indexService.loadEvents()).includes('未发布的派生文本'));
    assert.equal(storage.readJson(snapshotPath,null).catalog_schema,'source-catalog-v1');
    reads.clear();await new DataManagerFacade('/app').refreshInternal(cfg);
    assert.ok(![...reads.keys()].some(file=>file.endsWith('.md.state.json')||file.startsWith(paths.dailyLogRoot+'/')));
  });
});

test('legacy recovery: a scoped empty content change never falls back to the entire index after consolidation',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/task.md','1. 工作会议讨论计划\n');await facade.refreshInternal(cfg);
    facade.canSkipRefresh=()=>false;facade.canRecoverIndexesFromConsolidatedOutputs=()=>false;
    reads.clear();const progress=[];await facade.refreshInternal(cfg,value=>progress.push(value));
    assert.ok(!progress.some(value=>value.stage==='检查索引'));
  });
});

test('legacy recovery: unchanged fallback history stays labelled and is not retried during ordinary model-enabled sync',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-01/com.tencent.wechat.md','1. 工作会议讨论计划\n');
    await facade.refreshInternal(cfg);
    for(const file of [...disk.keys()].filter(file=>/\/indexes\/events\/\d{4}-\d{2}\.json$/.test(file))){
      const partition=storage.readJson(file,null);for(const item of partition.events)item.enrichment_method='heuristic_batch_fallback';
      storage.writeJsonAtomic(file,partition);
    }
    const snapshotPath=paths.consolidationRoot+'/daily-log-snapshot.json',snapshot=storage.readJson(snapshotPath,null);
    delete snapshot.catalog_schema;delete snapshot.calendar_hash;delete snapshot.index_revision;
    storage.writeJsonAtomic(snapshotPath,snapshot);storage.removeFile(paths.indexesRoot+'/completion.json');
    storage.removeFile(paths.consolidationRoot+'/source-changes/daily-ready');
    const model=new Model();let analyzed=0;
    model.enrichEvents=async events=>{analyzed+=events.length;assert.equal(events.length,0);return [];};
    facade.modelClient=model;facade.indexService=new IndexService(paths,storage,model);
    reads.clear();await facade.refreshInternal(config,undefined,cfg);
    assert.equal(analyzed,0);assert.ok(![...reads.keys()].some(file=>file.endsWith('.md.state.json')));
    assert.ok(Object.values(facade.indexService.loadEvents()).every(e=>e.enrichment_method==='heuristic_batch_fallback'));
    const calls=[model.leaves.length,model.merges.length];reads.clear();await facade.refreshInternal(config,undefined,cfg);
    assert.deepEqual([model.leaves.length,model.merges.length],calls);
    assert.ok(![...reads.keys()].some(file=>file.endsWith('.md.state.json')||file.startsWith(paths.dailyLogRoot+'/')));
  });
});

test('legacy recovery: completed cached sources cannot hide an active WeChat model request in progress',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  for(const name of ['com.alipay.mobile.client.md','com.tencent.wechat.md','shopping.md'])
    storage.writeJsonAtomic(paths.outputStatePath('2026-10',name),{metadata:{},records:[reviewRecord(1)]});
  await service.build(config);
  storage.writeJsonAtomic(paths.outputStatePath('2026-10','com.tencent.wechat.md'),{metadata:{},records:[reviewRecord(1,'工作会议讨论新方案')]});
  let release,entered;const gate=new Promise(resolve=>release=resolve),started=new Promise(resolve=>entered=resolve),progress=[];
  const analyze=model.enrichEvents.bind(model);
  model.enrichEvents=async events=>{if(events.length){entered();await gate;}return analyze(events);};
  const build=service.build(config,value=>progress.push(value));await started;
  const waiting=progress.at(-1);release();await build;
  assert.equal(waiting.stage,'索引分析');assert.match(waiting.message,/微信/);
});
test('sources: full verification discovers untracked external edits',async()=>{
  await sourceFacade(async(facade,cfg)=>{
    const file=paths.dailyLogRoot+'/2026-10-01/task.md';storage.writeTextAtomic(file,'1. 工作会议研究初版\n');await facade.refreshInternal(cfg);
    disk.set(file,'1. 工作会议研究外部改动\n');reads.clear();await facade.refreshInternal(cfg,undefined,undefined,true);
    assert.ok(reads.has(file));assert.ok(JSON.stringify(facade.indexService.loadEvents()).includes('外部改动'));
  });
});

function realGallery() {
  const old=mocks['GalleryMemorySync.ets'];delete mocks['GalleryMemorySync.ets'];
  try{return load('entry/src/main/ets/utils/gallery/GalleryMemorySync').GalleryMemorySync;}
  finally {mocks['GalleryMemorySync.ets']=old;}
}
function galleryItem(id,date,category='文档') {
  return {id,date,category,uri:'/original/'+id+'.jpg',thumbnailUri:'/thumbnail/'+id+'.jpg',title:'报告照片 '+id,
    summary:'记录学术会议报告内容',details:['模型与推理'],tags:['报告'],ocrText:'',rawModelText:'',keywords:[],
    embeddingRef:'',embeddingStatus:'',error:'',createdAt:Date.parse(date+'T12:00:00+08:00')};
}
test('sources: gallery warm sync reads no items; edits, category moves and deletes touch one date only',()=>{
  reset();trackSourceChanges=true;const Gallery=realGallery(),items=[];
  for(let i=1;i<=25;i++){
    const item=galleryItem('photo-'+i,'2026-10-'+String(i).padStart(2,'0'));items.push(item);
    storage.writeJsonAtomic('/app/gallery-log/items/'+item.date+'/'+item.id+'.json',item);
  }
  Gallery.sync('/app');reads.clear();writes.length=0;const unchanged=Gallery.sync('/app');
  assert.equal(unchanged.scannedItemCount,0);assert.equal(writes.length,0);
  assert.ok(![...reads.keys()].some(file=>file.includes('/gallery-log/items/')||file.startsWith(paths.dailyLogRoot+'/')));
  const before=new Map([...disk.entries()].filter(([file])=>file.startsWith(paths.dailyLogRoot+'/')));
  const changed={...items[2],category:'工作',summary:'工作会议的新记录'};
  storage.writeJsonAtomic('/app/gallery-log/items/'+changed.date+'/'+changed.id+'.json',changed);reads.clear();writes.length=0;
  const result=Gallery.sync('/app');assert.equal(result.scannedItemCount,1);
  assert.ok([...reads.keys()].filter(file=>file.includes('/gallery-log/items/')).every(file=>file.includes('/2026-10-03/')));
  for(const[file,text]of before)if(!file.includes('/2026-10-03/')&&file.endsWith('.md'))assert.equal(disk.get(file),text);
  const affected=[...disk.keys()].filter(file=>file.startsWith(paths.dailyLogRoot+'/2026-10-03/')&&file.endsWith('.md'));
  assert.equal(affected.length,1);assert.ok(disk.get(affected[0]).includes('工作会议的新记录'));
  reads.clear();const refs=Gallery.imageRefsForSourceRefs('/app',paths.dailyLogRoot,['2026-10-03/'+path.posix.basename(affected[0])+'#'+
    /\n(\d+)\. \[gallery-item:/.exec(disk.get(affected[0]))[1]]);
  assert.equal(refs.length,1);assert.equal([...reads.keys()].filter(file=>file.includes('/gallery-log/items/')).length,1);
  storage.removeFile('/app/gallery-log/items/'+changed.date+'/'+changed.id+'.json');Gallery.sync('/app');assert.equal(storage.exists(affected[0]),false);
  trackSourceChanges=false;
});
test('sources: failed gallery reads preserve exports and pending work, and clearing retracts old groups',()=>{
  reset();trackSourceChanges=true;const Gallery=realGallery(),item=galleryItem('a','2026-10-01');
  const file='/app/gallery-log/items/2026-10-01/a.json';storage.writeJsonAtomic(file,item);Gallery.sync('/app');
  const prior=[...disk.entries()].filter(([file])=>file.startsWith(paths.dailyLogRoot+'/')&&file.endsWith('.md'));
  storage.writeTextAtomic(file,'broken JSON');assert.throws(()=>Gallery.sync('/app'),/记录损坏/);
  for(const[file,text]of prior)assert.equal(disk.get(file),text);
  const {MemoryChangeJournal}=load(base+'MemoryChangeJournal'),journal=new MemoryChangeJournal('/app',storage);
  assert.equal(journal.pending('gallery').length,1);storage.writeJsonAtomic(file,{...item,summary:'恢复后的报告内容'});Gallery.sync('/app');
  assert.equal(journal.pending('gallery').length,0);journal.mark('gallery','*');
  for(const file of [...disk.keys()])if(file.startsWith('/app/gallery-log/'))disk.delete(file);
  Gallery.sync('/app');assert.equal([...disk.keys()].filter(file=>file.startsWith(paths.dailyLogRoot+'/')&&file.endsWith('.md')).length,0);
  trackSourceChanges=false;
});
test('sources: chat reads only changed sessions, skips idle history, and retries failed extraction',async()=>{
  reset();trackSourceChanges=true;const old=mocks['ChatMemorySync.ets'];delete mocks['ChatMemorySync.ets'];let Chat;
  try {Chat=load(base+'ChatMemorySync').ChatMemorySync;}finally {mocks['ChatMemorySync.ets']=old;}
  const now=Date.now(),session={id:'chat-source',mode:'cloud_agent',title:'test',createdAt:now,updatedAt:now,messages:[
    {id:'m1',role:'user',kind:'chat',content:'工作会议讨论模型部署',createdAt:now}]};
  const sessionFile='/app/chat-sessions/sessions/chat-source.json';storage.writeJsonAtomic(sessionFile,session);
  let calls=0,fail=false;const model={extractChatMemory:async inputs=>{calls++;if(fail)throw Error('fixture chat failure');
    return inputs.map(item=>({source_ref:item.source_ref,facts:[{scene_id:10,text:'工作会议讨论模型部署 '+item.source_ref}]}));}};
  const chat=new Chat(paths,storage,model);await chat.sync(config,undefined,now);assert.equal(calls,1);
  reads.clear();await new Chat(paths,storage,model).sync(config,undefined,now);assert.equal(calls,1);
  assert.ok(![...reads.keys()].some(file=>file.includes('/chat-sessions/')||file.includes('/chat-memory/')||file.startsWith(paths.dailyLogRoot+'/')));
  session.messages.push({id:'m2',role:'user',kind:'chat',content:'工作会议讨论下一阶段计划',createdAt:now});storage.writeJsonAtomic(sessionFile,session);
  fail=true;await assert.rejects(chat.sync(config,undefined,now),/chat failure/);
  const {MemoryChangeJournal}=load(base+'MemoryChangeJournal'),journal=new MemoryChangeJournal('/app',storage);
  assert.equal(journal.pending('chat').length,1);fail=false;await chat.sync(config,undefined,now);
  assert.equal(journal.pending('chat').length,0);
  assert.equal(storage.readJson('/app/workflows/chat-memory/state.json',null).receipts.length,2);
  const before=calls;await chat.sync(config,undefined,now,true);assert.equal(calls,before);trackSourceChanges=false;
});

test('stream: completed event objects survive arbitrary chunks, escaped text and an unfinished tail',()=>{
  const {EventStreamParser}=load(base+'EventStreamParser'),parser=new EventStreamParser();
  const items=[{event_id:'a',todo:{text:'引号 " 和括号 } [',details:[{x:1}]}},{event_id:'b',keywords:['中文']}];
  const text='```json\n{"other":{"events":[{"event_id":"not-root"}]},"events":['+items.map(JSON.stringify).join(',')+',{"event_id":"unfinished"';
  const result=[];for(const ch of text)result.push(...parser.append(ch));assert.deepEqual(clone(result),items);
  assert.equal(new EventStreamParser().append('<think>{"events":[{"event_id":"draft"}]}</think>').length,0);
});

test('stream: metadata tracks inactivity, previews are Debug-only and repetition uses the shared guard',()=>{
  const {ModelStreamActivityStore,hasRepeatedStreamTail}=load(base+'ModelStreamActivity'),store=new ModelStreamActivityStore();
  store.begin('a','enrich.batch','微信 1/2',1,1000);
  assert.equal(store.snapshots(0,false,22000)[0].idleSeconds,21);
  const update={phase:'receiving',responseCode:200,receivedBytes:20,contentChars:20,reasoningChars:0,
    contentDelta:'private preview',reasoningDelta:'',finishReason:''};
  store.update('a',update,true,23000);assert.equal(store.snapshots(0,true,24000)[0].preview,'private preview');
  assert.equal(store.snapshots(0,false,24000)[0].preview,'');assert.equal(store.snapshots(0,true,24000)[0].preview,'');
  assert.equal(hasRepeatedStreamTail('持续重复的完整文本片段'.repeat(30)),true);
  assert.equal(hasRepeatedStreamTail('},{'.repeat(100)),false);
  store.finish('a','invalid',25000);assert.equal(store.snapshots(0,false,100000)[0].elapsedSeconds,24);
  store.begin('b','split.batch','事实提取',1,26000);
  const loop={...update,contentDelta:'持续重复的完整文本片段需要停止'.repeat(12)};
  assert.equal(store.update('b',loop,false,27000),true);
  assert.equal(store.snapshots(0,false,28000).find(x=>x.id==='b').repeating,true);
  assert.equal(store.snapshots(0,true,28000).find(x=>x.id==='b').preview,'');
  assert.equal(store.update('b',{...update,phase:'failed',contentDelta:''},false,29000),false,
    'A failed-status notification must not throw again before native rejection settles');
});

test('stream: successful event is durable before its batch times out, failure is skipped after restart',async()=>{
  reset();const real=new DataPipelineModelClient(),model=new Model();model.enrichEvents=real.enrichEvents.bind(real);
  const file=paths.outputStatePath('2026-10','com.tencent.wechat.md');
  storage.writeJsonAtomic(file,{metadata:{},records:[reviewRecord(1),reviewRecord(2)]});let requests=0;
  cloudHandler=async(options,stream)=>{
    requests++;assert.equal(options.readTimeout,120000);assert.equal(options.separateReasoning,true);
    const items=reviewEnrichment(options).events,partial='{"events":['+(items.length>1?JSON.stringify(items[0])+',':'');
    stream.onProgress({phase:'receiving',responseCode:200,receivedBytes:partial.length,contentChars:partial.length,
      reasoningChars:0,contentDelta:partial,reasoningDelta:'',finishReason:''});
    assert.ok([...disk.keys()].some(p=>p.includes('/sync-cache/events/')&&!p.endsWith('.failed.json')));
    throw Error('Operation timed out');
  };
  const service=new IndexService(paths,storage,model),result=await service.build(config);
  assert.equal(Object.keys(service.loadEvents()).length,1);assert.equal(result.failedEventCount,1);
  assert.equal([...disk.keys()].filter(p=>p.endsWith('.failed.json')).length,1);
  const unchanged=await new IndexService(paths,storage,model).build(config);assert.equal(requests,3);
  assert.equal(unchanged.failedEventCount,0,'Untouched historical failures are not counted as current skips');
  assert.equal(service.completion().failed_event_count,1,'The persisted historical total is retained');
  const facade=Object.create(DataManagerFacade.prototype);facade.indexService=service;
  assert.equal(facade.skippedRefreshSummary({entry_count:0,consolidated_record_count:0,generated_at:''}).failedEventCount,0);
  assert.equal(real.modelActivities()[0].phase,'failed');
  const next=new DataPipelineModelClient(),nextModel=new Model();nextModel.enrichEvents=next.enrichEvents.bind(next);
  storage.writeJsonAtomic(file,{metadata:{},records:[reviewRecord(1),reviewRecord(2,'工作会议修改后的新内容')]});
  cloudHandler=async options=>{requests++;assert.equal(JSON.parse(options.messages[1].content).events.length,1);return JSON.stringify(reviewEnrichment(options));};
  const repaired=await new IndexService(paths,storage,nextModel).build(config);assert.equal(repaired.failedEventCount,0);assert.equal(requests,4);
});

test('stream: repeated output aborts only its event batch, keeps success and persists failure with Debug off',async()=>{
  reset();assert.equal(debugForTest,false);
  const real=new DataPipelineModelClient(),model=new Model();model.enrichEvents=real.enrichEvents.bind(real);
  const file=paths.outputStatePath('2026-10','com.tencent.wechat.md');
  storage.writeJsonAtomic(file,{metadata:{},records:[reviewRecord(1),reviewRecord(2)]});let requests=0,reachedTail=false;
  cloudHandler=async(options,stream)=>{
    requests++;const items=reviewEnrichment(options).events,partial='{"events":['+(items.length>1?JSON.stringify(items[0])+',':'');
    let total=partial.length;
    stream.onProgress({phase:'receiving',responseCode:200,receivedBytes:total,contentChars:total,
      reasoningChars:0,contentDelta:partial,reasoningDelta:'',finishReason:''});
    const loop='持续重复的完整文本片段需要停止';
    for(let i=0;i<30;i++){total+=loop.length;stream.onProgress({phase:'receiving',responseCode:200,receivedBytes:total,
      contentChars:total,reasoningChars:0,contentDelta:loop,reasoningDelta:'',finishReason:''});}
    reachedTail=true;throw Error('Must abort before reaching here');
  };
  const service=new IndexService(paths,storage,model),result=await service.build(config);
  assert.equal(reachedTail,false);assert.equal(result.failedEventCount,1);assert.equal(Object.keys(service.loadEvents()).length,1);
  const failure=[...disk.entries()].find(([p])=>p.endsWith('.failed.json'));assert.equal(JSON.parse(failure[1]).reason,'repeated_output');
  assert.equal(real.modelActivities()[0].phase,'repeated');assert.equal(real.modelActivities()[0].preview,'');
  await new IndexService(paths,storage,model).build(config);assert.equal(requests,3);
  cloudHandler=async options=>JSON.stringify(reviewEnrichment(options));
  assert.equal((await real.enrichEvents([event('following-batch')],config)).length,1,'Other event requests still run');
});

test('stream: repetition abort covers fact extraction and all memory stages without retrying the request',async()=>{
  reset();const client=new DataPipelineModelClient();let calls=0,finishedLoop=false;
  cloudHandler=async(options,stream)=>{
    calls++;const loop='持续重复的完整文本片段需要停止';
    for(let i=0;i<30;i++)stream.onProgress({phase:'receiving',responseCode:200,receivedBytes:(i+1)*loop.length,
      contentChars:(i+1)*loop.length,reasoningChars:0,contentDelta:loop,reasoningDelta:'',finishReason:''});
    finishedLoop=true;throw Error('Must stop on repeated content');
  };
  const kinds=['split.batch','dedup','profile.block.work','collection.group.chat','entity.resolve.person','chat.memory','home.recommendation'];
  for(const kind of kinds){
    const before=calls;
    await assert.rejects(client.callJson(config,kind,'system','input'),/MODEL_REPEATED_OUTPUT/);
    assert.equal(calls,before+1,kind+' must not retry a repeated-output response');
  }
  assert.equal(finishedLoop,false);assert.ok(client.modelActivities().every(x=>x.phase==='repeated'));
  assert.ok(client.modelActivities().every(x=>x.repeating&&x.preview===''));
  const entry={source_ref:'2026-10-29/alipay.md#1',source_date:'2026-10-29',file_name:'alipay.md',
    entry_index:1,entry_text:'1. 支付宝查看订单记录',workflow_scene_id:1,workflow_metadata:{}};
  const before=calls,facts=await client.splitEntriesIntoFacts([entry],config);
  assert.equal(calls,before+1);assert.ok(facts[entry.source_ref].length>0,'Fact extraction keeps its existing rule fallback');
});

test('stream: changed business declarations remain strict',()=>{
  cases.find(([name])=>name==='production declarations check changed business modules with strict types and platform-only stubs')[1]();
});

test('stream: real SSE transport decodes UTF-8, separates reasoning and preserves legacy chat display',async()=>{
  const seenLogs=[],requests=[];let raw='',destroyed=0;
  const fakeRequest=()=>{const listeners={};return {on:(name,fn)=>{listeners[name]=fn;},off:name=>{delete listeners[name];},
    requestInStream:async(_url,options)=>{requests.push(options);await new Promise(resolve=>setImmediate(resolve));
      const bytes=Buffer.from(raw);for(let i=0;i<bytes.length;i+=3){const chunk=Uint8Array.from(bytes.subarray(i,i+3));listeners.dataReceive?.(chunk.buffer);}
      listeners.dataEnd?.();return 200;}};};
  const cache=new Map();
  const nativeMocks={'AppRequests':{AppRequests:{createHttp:fakeRequest,destroyHttp(){destroyed++;},onHttpCancel(){}}},
    'AiServiceAccess':{AiServiceAccess:{isAllowed:()=>true,requireAllowed(){}},AI_LOGIN_REQUIRED_MESSAGE:'login'},
    'AppLogger':{AppLogger:{info:(_m,x)=>seenLogs.push(x),warn:(_m,x)=>seenLogs.push(x),error(){},warnCause(){}}},
    'TextEncodingCompat':{decodeUtf8Compat:b=>new TextDecoder().decode(b)},'JsonCompat':{parseJsonCompat:JSON.parse}};
  function nativeLoad(name){
    if(nativeMocks[name])return nativeMocks[name];if(cache.has(name))return cache.get(name);
    if(!['CloudModelClient','CloudApiCompatibility'].includes(name))return {};
    const source=fs.readFileSync(path.join(root,'entry/src/main/ets/utils',name+'.ets'),'utf8');
    const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
    const exported={};cache.set(name,exported);
    vm.runInNewContext(code,{exports:exported,URL,Date,console,require:id=>{
      if(id==='@kit.ArkTS')return {JSON,util:{TextDecoder:{create:()=>{const decoder=new TextDecoder();return {decodeWithStream:b=>decoder.decode(b,{stream:true})};}}}};
      if(id==='@kit.NetworkKit')return {http:{RequestMethod:{POST:'POST'},HttpDataType:{STRING:0}}};
      return nativeLoad(path.basename(id));
    }});return exported;
  }
  const Cloud=nativeLoad('CloudModelClient').CloudModelClient;
  const frame=delta=>'data: '+JSON.stringify({choices:[{delta,finish_reason:null}]})+'\n\n';
  raw=frame({reasoning_content:'draft {should not parse}'})+frame({content:'{"events":[],"text":"中文 private"}'})+
    'data: '+JSON.stringify({choices:[{delta:{},finish_reason:'stop'}]})+'\n\ndata: [DONE]\n\n';
  const progress=[],options={baseUrl:'https://model.invalid/v1',apiKey:'fixture',messages:[],readTimeout:300000,separateReasoning:true,logResponseContent:false};
  const result=await new Cloud().chatCompletionStream(options,{onProgress:x=>progress.push(x)});
  assert.equal(JSON.parse(result.content).text,'中文 private');assert.equal(result.finishReason,'stop');
  assert.ok(progress.some(x=>x.reasoningChars>0));assert.ok(progress.some(x=>x.contentChars>0));
  assert.ok(!seenLogs.join('').includes('中文 private'));assert.equal(JSON.parse(requests[0].extraData).stream,true);
  const legacy=await new Cloud().chatCompletionStream({...options,separateReasoning:false});assert.ok(legacy.content.includes('<think>'));
  raw=JSON.stringify({choices:[{message:{content:'{"events":[]}'},finish_reason:'stop'}]});
  const fallback=await new Cloud().chatCompletionStream(options,{onProgress:x=>progress.push(x)});
  assert.equal(fallback.content,'{"events":[]}');assert.ok(progress.some(x=>x.phase==='buffered'));
  raw=frame({content:'loop fragment'})+frame({content:'must not be consumed'});
  let deltas=0;const before=destroyed;
  await assert.rejects(new Cloud().chatCompletionStream(options,{onProgress:x=>{
    if(x.contentDelta){deltas++;throw Error('MODEL_REPEATED_OUTPUT');}
  }}),/MODEL_REPEATED_OUTPUT/);
  assert.equal(deltas,1);assert.equal(destroyed,before+1,'Callback failure destroys the individual native HTTP request');
});

const chatContext = load(base+'ChatCollectionContext');
const comfort = load('entry/src/main/ets/pages/home/HomeEmotionalSupport');
const messageTime = load('entry/src/main/ets/utils/ChatMessageTime');
const {WorkflowDateContext} = load('entry/src/main/ets/utils/WorkflowDateContext');
function transcriptLine(raw,body='请明天处理材料。') {
  return '- 位置：左侧｜发送人：同事甲｜聊天对象：我｜时间原文：'+raw+'｜原文：'+body;
}
test('chat dates: Monday collection resolves yesterday and the most recent Saturday without model arithmetic',()=>{
  const context=new WorkflowDateContext(new Date(2026,10,2,14,10));
  const result=context.normalizeDailyLogText(transcriptLine('昨天 下午09:19')+'\n'+transcriptLine('星期六 上午10:36'));
  assert.ok(result.includes('时间：2026-11-01 21:19'));assert.ok(result.includes('时间：2026-10-31 10:36'));
  assert.ok(result.includes('时间原文：昨天 下午09:19'));assert.ok(result.includes('原文：请明天处理材料。'));
  assert.ok(context.datePrompt().includes('2026-11-02 星期一'));assert.ok(context.datePrompt().includes('2026-10-31 星期六'));
  assert.equal(context.normalizeDailyLogText(result),result,'Summary timestamp normalization must be idempotent');
});
test('chat dates: all weekdays resolve within the preceding seven calendar days across month and year boundaries',()=>{
  for(const start of [new Date(2026,0,1,23,59),new Date(2026,10,2,23,59),new Date(2028,2,1,23,59)]) {
    for(let offset=0;offset<7;offset++) {
      const capture=new Date(start);capture.setDate(capture.getDate()+offset);
      for(let day=0;day<7;day++) {
        const expected=new Date(capture);expected.setDate(expected.getDate()-((capture.getDay()-day+7)%7));
        const key=d=>d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');
        const result=messageTime.normalizeChatMessageTimes(transcriptLine('星期'+'日一二三四五六'[day]+' 09:00'),capture);
        assert.ok(result.includes('时间：'+key(expected)+' 09:00'),result);
      }
    }
  }
  const capture=new Date(2026,10,2,14,10);
  assert.ok(messageTime.normalizeChatMessageTimes(transcriptLine('上周六 09:00'),capture).includes('时间：2026-10-31 09:00'));
  assert.ok(messageTime.normalizeChatMessageTimes(transcriptLine('前天 09:00'),new Date(2027,0,1,14)).includes('时间：2026-12-30 09:00'));
});
test('chat dates: missing, invalid, conflicting or future separators fall back to capture time without changing message content',()=>{
  const capture=new Date(2026,10,2,14,10),body='计划在2027-05-01见面；昨天我已确认。';
  for(const raw of ['未显示','不确定','模糊文字','2026-02-30 09:00','2027-01-01 09:00','2026-11-01 星期一 09:00','昨天 25:00','本周六 09:00']) {
    const result=messageTime.normalizeChatMessageTimes(transcriptLine(raw,body),capture);
    assert.ok(result.includes('时间：2026-11-02 14:10｜时间依据：采集时间兜底'),result);assert.ok(result.endsWith('原文：'+body));
  }
  assert.ok(messageTime.normalizeChatMessageTimes(transcriptLine('2026年06月16日 10:36'),capture).includes('时间：2026-06-16 10:36'),
    'An explicitly transcribed historical calendar date must not be replaced simply for being old');
  assert.ok(messageTime.normalizeChatMessageTimes(transcriptLine('12月31日 10:00'),new Date(2027,0,2,14)).includes('时间：2026-12-31 10:00'));
});
test('chat dates: clock-only separators inherit only a same-page date and cannot change a reply or planned deadline',()=>{
  const capture=new Date(2026,10,2,14,10);
  const result=messageTime.normalizeChatMessageTimes(transcriptLine('昨天 下午09:19')+'\n'+transcriptLine('晚上10:36')+
    '\n会话名称：另一个会话\n'+transcriptLine('上午10:00'),capture);
  assert.ok(result.includes('时间：2026-11-01 22:36｜时间依据：继承同页日期'));
  assert.ok(result.includes('时间：2026-11-02 10:00｜时间依据：采集日期兜底'));
  assert.equal(messageTime.normalizeChatMessageTimes('昨天开会，明天交稿',capture),'昨天开会，明天交稿');
});
test('chat dates: fact dates must come from saved message timestamps, not arbitrary dates in message bodies',()=>{
  const capture=new Date(2026,10,2,14,10),text=messageTime.normalizeChatMessageTimes(transcriptLine('昨天 09:00','回顾2026-06-16的项目')+
    '\n'+transcriptLine('星期六 09:00'),capture);
  for(const source of [text,text.replace(/\s+/g,' ')]) {
    assert.equal(messageTime.supportedFactDate('2026-11-01','2026-11-02',source),'2026-11-01');
    assert.equal(messageTime.supportedFactDate('2026-10-31','2026-11-02',source),'2026-10-31');
    assert.equal(messageTime.supportedFactDate('2026-06-16','2026-11-02',source),'2026-11-02');
    assert.equal(messageTime.supportedFactDate('','2026-11-02',source),'2026-11-02');
  }
  assert.equal(messageTime.supportedFactDate('2026-09-15','2026-11-02','订单日期2026-09-15'),'2026-09-15');
});
test('chat dates: the real fact extraction call includes collection weekday and rejects an unsupported model date',async()=>{
  reset();const entry={source_date:'2026-11-02',file_name:'wechat.md',entry_index:1,workflow_scene_id:3,
    source_ref:'2026-11-02/wechat.md#1',entry_text:messageTime.normalizeChatMessageTimes(transcriptLine('昨天 09:00'),new Date(2026,10,2,14,10))};
  cloudHandler=async options=>{const input=JSON.parse(options.messages[1].content);assert.equal(input.entries[0].source_weekday,'星期一');
    return JSON.stringify({items:[{source_ref:entry.source_ref,facts:[{summary:'处理材料',normalized_fact:'同事甲请我处理材料',event_date:'2026-06-16',tags:[]}]}]});};
  const result=await new DataPipelineModelClient().splitEntriesIntoFacts([entry],config);
  assert.equal(result[entry.source_ref][0].event_date,'2026-11-02');
  assert.ok(logs.some(line=>line.includes('SYNC_FACT_DATE_FALLBACK')&&line.includes('resolved=2026-11-02')));
});
test('chat dates: explicit action dates use the message date, natural weeks, and real calendar boundaries',()=>{
  for(const [raw,base,expected] of [['下周一','2026-11-02','2026-11-09'],['下周一','2026-11-01','2026-11-02'],
    ['下星期一','2026-11-02','2026-11-09'],['下下周二','2026-11-02','2026-11-17'],['这周六','2026-11-02','2026-11-07'],
    ['星期六','2026-11-02','2026-11-07'],['11月5号','2026-11-02','2026-11-05'],['明年1月3日','2026-11-02','2027-01-03'],
    ['2027-01-05','2026-11-02','2027-01-05'],['下个月5号','2026-12-31','2027-01-05'],['明天','2026-12-31','2027-01-01'],
    ['后天','2028-02-28','2028-03-01'],['2月30日','2026-11-02',''],['有空时','2026-11-02','']])
    assert.equal(messageTime.resolveActionDate(raw,base),expected,raw+' relative to '+base);
});
test('chat dates: each task retains its own explicit date while message and collection dates remain separate',async()=>{
  reset();const ref='2026-11-02/dialog.md#1',index=new chatContext.ChatCollectionContextIndex();
  const source=messageTime.normalizeChatMessageTimes(transcriptLine('昨天 09:00','请下周一交材料。')+'\n'+
    transcriptLine('今天 10:00','请11月5号开会。')+'\n'+transcriptLine('未显示','请帮我订书。'),new Date(2026,10,2,14,10));
  index.add('run-time',ref,source,[],1);
  const statements=['同事甲请我下周一交材料','同事甲请我11月5号开会','同事甲请我订书'];
  const events=statements.map((fact,i)=>chatFixture('timed-'+i,{event_date:'2026-11-02',source_refs:[ref],summary:fact,normalized_fact:fact}));
  for(const e of events)e.chat_context=index.forRefs(e.source_refs);
  cloudHandler=async options=>JSON.stringify({events:JSON.parse(options.messages[1].content).events.map(e=>{
    const i=events.findIndex(event=>event.event_id===e.event_id);
    return {event_id:e.event_id,keywords:[],domains:['other'],entities:[],todo:{type:i===2?'buy':'',
      time_text:['下周一','11月5号',''][i],deadline:'2026-06-16',text:statements[i],agent_task:''},
      chat:{subjects:[{kind:'other',name:'同事甲'}],action_owners:[{kind:'self',name:''}],user_involved:true,status:'pending',evidence_source_refs:[ref]}};
  })});
  const result=await new DataPipelineModelClient().enrichEvents(events,config,undefined,index.all());
  assert.equal(result[0].todo.deadline,'2026-11-02','A Sunday message saying next Monday means the following day');
  assert.equal(result[1].todo.deadline,'2026-11-05');assert.equal(result[2].todo.deadline,'');assert.equal(result[2].todo.type,'buy');
  assert.ok(result.every(e=>e.event_date==='2026-11-02'),'Scheduling must not overwrite the original observation dates');
});
test('chat dates: a time expression from a neighboring event cannot assign this task a deadline',async()=>{
  reset();const ref='2026-11-02/dialog.md#1',index=new chatContext.ChatCollectionContextIndex();
  index.add('run-time',ref,'同事甲：11月5号开会；我：帮你买书',[],1);
  const e=chatFixture('separate',{event_date:'2026-11-02',source_refs:[ref],summary:'帮同事甲买书',normalized_fact:'帮同事甲买书'});
  e.chat_context=index.forRefs(e.source_refs);
  cloudHandler=async()=>JSON.stringify({events:[{event_id:e.event_id,keywords:[],domains:['other'],entities:[],
    todo:{type:'buy',time_text:'11月5号',deadline:'2026-11-05',text:'买书',agent_task:''},
    chat:{subjects:[{kind:'other',name:'同事甲'}],action_owners:[{kind:'self',name:''}],user_involved:true,status:'pending',evidence_source_refs:[ref]}}]});
  const [result]=await new DataPipelineModelClient().enrichEvents([e],config,undefined,index.all());
  assert.equal(result.todo.deadline,'');assert.equal(result.todo.type,'buy');
});
test('chat reminders: a dated intention directly shared in private chat remains the other persons plan to follow up',async()=>{
  reset();const ref='2026-11-02/private.md#1',index=new chatContext.ChatCollectionContextIndex();
  index.add('private-run',ref,'会话类型：私聊\n会话名称：同事甲\n位置：左侧｜发送人：同事甲｜聊天对象：我｜时间原文：未显示｜时间：2026-11-02 09:00｜原文：周三想去博物馆玩',[],1);
  const e=chatFixture('private-plan',{event_date:'2026-11-02',source_refs:[ref],summary:'同事甲周三想去博物馆',normalized_fact:'同事甲告诉用户，周三想去博物馆玩'});
  e.chat_context=index.forRefs(e.source_refs);
  cloudHandler=async options=>{const prompt=options.messages[0].content;
    assert.ok(prompt.includes('即使未说“一起”也应作为用户关心对方安排的提醒'));
    assert.ok(prompt.includes('群聊中与用户无关的计划仍不自动提醒'));
    assert.ok(prompt.includes('不能伪造成用户已答应同行或事项已确认'));
    return JSON.stringify({events:[{event_id:e.event_id,keywords:[],domains:['travel'],entities:[],
      todo:{type:'',time_text:'周三',deadline:'2026-11-04',text:'关注同事甲周三想去博物馆的意向',agent_task:'打开应用订票'},
      chat:{subjects:[{kind:'other',name:'同事甲'}],action_owners:[{kind:'other',name:'同事甲'}],user_involved:true,status:'pending',evidence_source_refs:[ref]}}]});};
  const [result]=await new DataPipelineModelClient().enrichEvents([e],config,undefined,index.all());
  assert.equal(result.todo.deadline,'2026-11-04');assert.equal(result.chat_attribution.action_owner_name,'同事甲');
  assert.equal(result.chat_attribution.user_involved,true);assert.equal(result.chat_attribution.status,'pending');
  assert.ok(result.todo.text.includes('想'));assert.equal(result.todo.agent_task,'');
  const service=new IndexService(paths,storage,new Model());
  assert.deepEqual(clone(service.buildHomeTodoDocument({[e.event_id]:result}).deadline_postings['2026-11-04']),[e.event_id]);
});
test('chat dates: explicit occurrence dates override message dates for past facts but future plans remain observations',async()=>{
  reset();const raw=transcriptLine('今天 10:00','10月31号我在杭州参会，11月5号交报告。');
  const entry={source_date:'2026-11-02',file_name:'wechat.md',entry_index:1,workflow_scene_id:3,source_ref:'2026-11-02/wechat.md#1',
    entry_text:messageTime.normalizeChatMessageTimes(raw,new Date(2026,10,2,14,10))};
  cloudHandler=async()=>JSON.stringify({items:[{source_ref:entry.source_ref,facts:[
    {summary:'杭州参会',normalized_fact:'同事甲10月31号在杭州参会',time_text:'10月31号',event_date:'2026-11-02',tags:[]},
    {summary:'交报告',normalized_fact:'同事甲11月5号交报告',time_text:'11月5号',event_date:'2026-11-05',tags:[]}
  ]}]});
  const result=(await new DataPipelineModelClient().splitEntriesIntoFacts([entry],config))[entry.source_ref];
  assert.equal(result[0].event_date,'2026-10-31');assert.equal(result[1].event_date,'2026-11-02');
  assert.ok(result[1].normalized_fact.includes('11月5号'));
  assert.equal(messageTime.eventTimeTextSupported('2026-11-02','发生于2026-11-02',entry.entry_text),false,
    'A separator date is not a time explicitly spoken in the message');
  assert.equal(messageTime.resolveActionDate('下周一或周二','2026-11-02'),'');
  assert.equal(messageTime.resolveActionDate('11月5日至7日','2026-11-02'),'');
  assert.equal(messageTime.resolveActionDate('下周末','2026-11-02'),'2026-11-14');
});
function chatFixture(id='wx',extra={}) {return event(id,'2026-10-31',{source_state_file:'2026-10/com.tencent.mm__basic-gui-task.md.state.json',
  workflow_scene_ids:[3],summary:'小王请我明天发送PPT',normalized_fact:'小王｜2026-10-31 09:00：请明天发PPT；我｜09:10：已经发了',
  source_refs:['2026-10-31/wechat.md#1'],...extra});}
function contextFixture() {const index=new chatContext.ChatCollectionContextIndex();
  index.add('workflow:run-a','2026-10-31/wechat.md#1','聊天对象：小王\n小王｜09:00：请明天发PPT',['runs/a/1.jpg'],1);
  index.add('workflow:run-a','2026-10-31/wechat.md#2','聊天对象：小王\n我｜09:10：已经发了\n小王｜09:11：收到',['runs/a/2.jpg'],2);
  index.add('workflow:run-b','2026-10-31/wechat.md#3','小王｜10:00：请再发一份',[],1);return index;}
test('chat context: same collection includes the answer and retains page evidence without another collection',()=>{
  const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  const batches=chatContext.chatBatchesForEvents([e],index.all());assert.equal(batches.length,1);
  assert.ok(batches[0].entries[1].text.includes('已经发了'));assert.ok(!JSON.stringify(batches).includes('再发一份'));
  assert.equal(batches[0].entries[1].image_paths[0],'runs/a/2.jpg');assert.equal(e.chat_context.complete,true);
});
test('chat context: source identity survives two collections with the same contact on the same date',()=>{
  const index=contextFixture(),a=index.forRefs(['2026-10-31/wechat.md#1']);
  const b=index.forRefs(['2026-10-31/wechat.md#3']);assert.notDeepEqual(clone(a.batch_ids),clone(b.batch_ids));
  assert.equal(index.forRefs(['2026-10-31/wechat.md#1','2026-10-31/wechat.md#3']).complete,false);
  assert.equal(index.forRefs(['unknown']).complete,false);
});
test('chat context: immutable run identity and page counts replace historical text hashes',()=>{
  const index=contextFixture(),before=hashedChars;
  const a=index.forRefs(['2026-10-31/wechat.md#1']),b=index.forRefs(['2026-10-31/wechat.md#3']);
  for(let i=0;i<30;i++)index.forRefs(['2026-10-31/wechat.md#1']);
  assert.equal(hashedChars,before);assert.equal(a.input_hash,undefined);
  index.add('workflow:run-a','2026-10-31/wechat.md#4','我：收到',[],3);
  assert.notEqual(index.forRefs(['2026-10-31/wechat.md#1']).revision,a.revision);
  assert.equal(index.forRefs(['2026-10-31/wechat.md#3']).revision,b.revision);
  assert.equal(hashedChars,before);
});
test('chat context: oversized context is bounded and cannot certify an unresolved task',()=>{
  const index=new chatContext.ChatCollectionContextIndex();index.add('large','p','起始'+ '字'.repeat(60000)+'已完成',[],1);
  const batch=index.all()[0];assert.equal(batch.complete,false);assert.ok(batch.entries[0].text.length<=48000);
  assert.ok(batch.entries[0].text.endsWith('已完成'));assert.equal(index.forRefs(['p']).complete,false);
});
test('chat context: resolved, unknown actor, fabricated name and foreign evidence are not pending ownership',()=>{
  const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  const raw={subject:'other',subject_name:'小王',action_owner:'self',action_owner_name:'',status:'resolved',evidence_source_refs:['2026-10-31/wechat.md#2']};
  const a=chatContext.normalizeChatAttribution(raw,e,index.all());assert.equal(a.status,'resolved');assert.equal(a.subject_name,'小王');
  assert.equal(chatContext.normalizeChatAttribution({...raw,status:'pending',action_owner:'other',action_owner_name:'小赵'},e,index.all()).action_owner,'unknown');
  assert.equal(chatContext.normalizeChatAttribution({...raw,evidence_source_refs:['2026-10-31/wechat.md#3']},e,index.all()).status,'unknown');
});
test('chat context: generic pronouns cannot become third-party titles',()=>{
  for(const name of ['对方','我','你','未知发送人','群友','未出现的人','左侧成员1（姓名未显示）','私聊联系人（姓名未显示）'])
    assert.equal(chatContext.verifiedChatPersonName(name,'小王说对方很累；左侧成员1（姓名未显示）；私聊联系人（姓名未显示）'),'');
  assert.equal(chatContext.chatPersonTitle('最近有点累',['小王','小王']),'小王：最近有点累');
  assert.equal(chatContext.chatPersonTitle('小王：最近有点累',['小王']),'小王：最近有点累');
});
test('chat contract: text-only evidence and one complete output shape share the ordinary GUI enrichment pipeline',()=>{
  const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  const {buildEnrichPromptPreview,buildFactSplitPromptPreview}=load(base+'DataPipelineModelClient');
  const preview=buildEnrichPromptPreview([e],index.all()),input=JSON.parse(preview.userPrompt);
  assert.ok(preview.systemPrompt.split('输出结构（').at(-1).includes('"chat"'));
  assert.ok(preview.systemPrompt.includes('从输入source_refs或同批chat_batches.entries.source_ref原样复制'));
  assert.ok(!JSON.stringify(input).includes('image_paths'));assert.ok(!JSON.stringify(input).includes('runs/a/1.jpg'));
  assert.ok(input.chat_batches[0].entries.some(page=>page.text.includes('已经发了')));
  assert.ok(!buildEnrichPromptPreview([event('ordinary')]).systemPrompt.split('输出结构（').at(-1).includes('"chat"'));
  const entry={source_date:'2026-10-31',source_ref:e.source_refs[0],entry_text:'私聊文字',entry_index:1,
    collection_batch_id:'run-a',workflow_scene_id:3};
  assert.ok(!buildFactSplitPromptPreview([entry]).userPrompt.includes('image_paths'));
});
test('chat contract: requests in either direction retain the named participant and a no-deadline reminder',async()=>{
  reset();const index=new chatContext.ChatCollectionContextIndex(),refs=['2026-10-31/dialog.md#1','2026-10-31/dialog.md#2'];
  index.add('run-a',refs[0],'会话类型：私聊\n会话名称：同事甲\n位置：左侧｜发送人：同事甲｜聊天对象：我｜原文：请帮我订一本教材。',[],1);
  index.add('run-a',refs[1],'位置：右侧｜发送人：我｜聊天对象：同事甲｜原文：请帮我订一套文具。',[],2);
  const events=refs.map((ref,i)=>chatFixture('request-'+i,{source_refs:[ref],normalized_fact:'包含委托事项',summary:'委托事项'}));
  events.forEach(e=>e.chat_context=index.forRefs(e.source_refs));
  cloudHandler=async options=>{const input=JSON.parse(options.messages[1].content);
    assert.ok(input.chat_batches[0].entries[0].text.includes('位置：左侧'));assert.ok(options.messages[0].content.includes('不能把左侧发送人写成self'));
    return JSON.stringify({events:input.events.map((e,i)=>({event_id:e.event_id,keywords:['采购'],domains:['other'],entities:[],
      todo:{type:'buy',deadline:'',text:'为同事甲预订所需物品',agent_task:'打开购物应用搜索物品'},
      chat:{subjects:[{kind:'other',name:'同事甲'}],action_owners:[{kind:i===0?'self':'other',name:i===0?'':'同事甲'}],
        user_involved:true,status:'pending',evidence_source_refs:[refs[i]]}}))});};
  const result=await new DataPipelineModelClient().enrichEvents(events,config,undefined,index.all());
  assert.equal(result[0].chat_attribution.action_owner,'self');assert.equal(result[1].chat_attribution.action_owner_name,'同事甲');
  assert.ok(result.every(e=>e.chat_attribution.subject_name==='同事甲'&&e.todo.type==='buy'&&e.todo.text));
  assert.ok(result[0].todo.agent_task);assert.equal(result[1].todo.agent_task,'');
});
test('chat contract: incomplete response, foreign evidence and invented people are errors, not successful unknowns',()=>{
  const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  const raw={subjects:[{kind:'other',name:'小王'}],action_owners:[{kind:'self',name:''}],user_involved:true,status:'pending',evidence_source_refs:e.source_refs};
  assert.equal(chatContext.chatAttributionValidationError(raw,e,index.all()),'');
  for(const [patch,reason] of [[{status:undefined},'status_missing_or_invalid'],[{user_involved:undefined},'user_involved_missing'],
    [{evidence_source_refs:[]},'evidence_refs_missing'],[{evidence_source_refs:[...e.source_refs,'2026-10-31/wechat.md#3']},'evidence_ref_outside_collection'],
    [{subjects:undefined},'subjects_missing_or_invalid'],[{action_owners:[{kind:'other',name:'凭空人物'}]},'action_owners_name_not_in_evidence'],
    [{action_owners:[]},'pending_people_unidentified']])
    assert.equal(chatContext.chatAttributionValidationError({...raw,...patch},e,index.all()),reason);
});
test('chat contract: genuine uncertainty preserves the identified people and does not fabricate an actionable task',async()=>{
  reset();const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  cloudHandler=async()=>JSON.stringify({events:[{event_id:e.event_id,keywords:[],domains:['other'],entities:[],
    todo:{type:'',deadline:'',text:'',agent_task:''},chat:{subjects:[{kind:'other',name:'小王'}],action_owners:[],
      user_involved:false,status:'unknown',evidence_source_refs:e.source_refs}}]});
  const [result]=await new DataPipelineModelClient().enrichEvents([e],config,undefined,index.all());
  assert.equal(result.chat_attribution.subject_name,'小王');assert.equal(result.chat_attribution.status,'unknown');assert.equal(result.todo.text,'');
});
test('chat contract: malformed streamed items fail individually while valid later chat and ordinary GUI items survive',async()=>{
  reset();const index=contextFixture(),good=chatFixture('good'),bad=chatFixture('bad');
  for(const e of [good,bad])e.chat_context=index.forRefs(e.source_refs);
  const plain=event('ordinary'),success=[],failed=[];
  cloudHandler=async options=>JSON.stringify({events:JSON.parse(options.messages[1].content).events.map(e=>({event_id:e.event_id,
    keywords:[],domains:['other'],entities:[],todo:{type:'',deadline:'',text:'',agent_task:''},
    ...(e.event_id==='good'?{chat:{subjects:[{kind:'other',name:'小王'}],action_owners:[],user_involved:false,status:'resolved',evidence_source_refs:good.source_refs}}:{})}))});
  const result=await new DataPipelineModelClient().enrichEvents([bad,good,plain],config,{onEvent:e=>success.push(e.event_id),
    onFailure:(e,reason)=>failed.push([e.event_id,reason])},index.all());
  assert.deepEqual(success.sort(),['good','ordinary']);assert.deepEqual(failed,[['bad','invalid_chat_attribution']]);
  assert.deepEqual(result.map(e=>e.event_id),['good','ordinary']);
  assert.ok(logs.some(line=>line.includes('SYNC_EVENT_REJECTED event=bad')&&line.includes('chat_missing')));
  cloudHandler=async()=>JSON.stringify({events:[{event_id:bad.event_id,keywords:[],domains:['other'],entities:[],todo:{}}]});
  await assert.rejects(new DataPipelineModelClient().enrichEvents([bad],config,undefined,index.all()),/CHAT_ATTRIBUTION_INVALID/);
});

function outcomeItem(e) {
  return {event_id:e.event_id,keywords:[],domains:['other'],entities:[],todo:{type:'',deadline:'',text:'',agent_task:''},
    chat:{subjects:[{kind:'other',name:'小王'}],action_owners:[{kind:'self',name:''}],user_involved:true,
      status:'resolved',evidence_source_refs:e.source_refs}};
}
function bufferedOutcomes(stream,items) {
  // Legacy/proxied endpoints can return a complete response without SSE deltas.
  stream.onProgress({phase:'buffered',responseCode:200,receivedBytes:0,contentChars:0,reasoningChars:0,
    contentDelta:'',reasoningDelta:'',finishReason:''});
  return JSON.stringify({events:items});
}

test('event outcomes: buffered attribution errors never reject valid siblings in either response order',async()=>{
  const invalids=[['chat_missing',item=>{delete item.chat;}],
    ['status_missing_or_invalid',item=>{delete item.chat.status;}],
    ['evidence_ref_outside_collection',item=>{item.chat.evidence_source_refs=['2026-10-31/wechat.md#3'];}],
    ['action_owners_name_not_in_evidence',item=>{item.chat.action_owners=[{kind:'other',name:'凭空人物'}];}],
    ['pending_people_unidentified',item=>{item.chat.status='pending';item.chat.action_owners=[];}]];
  for(const [code,mutate] of invalids)for(const reverse of [false,true]) {
    reset();const index=contextFixture(),good=chatFixture('good'),bad=chatFixture('bad');
    for(const e of [good,bad])e.chat_context=index.forRefs(e.source_refs);
    const broken=outcomeItem(bad);mutate(broken);const items=[broken,outcomeItem(good)];if(reverse)items.reverse();
    cloudHandler=async(options,stream)=>bufferedOutcomes(stream,items);const successes=[],failures=[];
    const results=await new DataPipelineModelClient().enrichEvents([bad,good],config,{onEvent:e=>successes.push(e.event_id),
      onFailure:(e,reason,detail)=>failures.push([e.event_id,reason,clone(detail)])},index.all());
    assert.deepEqual(results.map(e=>e.event_id),['good']);assert.deepEqual(successes,['good']);
    assert.deepEqual(failures,[['bad','invalid_chat_attribution',{code,scope:'event',attempts:3}]]);
  }
});

test('event outcomes: stray objects, missing IDs and invalid ordinary fields stay isolated',async()=>{
  reset();const events=['good','missing','bad'].map(id=>event(id)),failures=[];
  const invalid=outcomeItem(events[2]);delete invalid.domains;
  cloudHandler=async(options,stream)=>bufferedOutcomes(stream,[null,17,{event_id:'foreign'},invalid,outcomeItem(events[0])]);
  const results=await new DataPipelineModelClient().enrichEvents(events,config,{onEvent:()=>{},
    onFailure:(e,reason,detail)=>failures.push([e.event_id,reason,clone(detail)])});
  assert.deepEqual(results.map(e=>e.event_id),['good']);
  assert.deepEqual(failures,[['missing','missing_event',{code:'event_not_returned',scope:'event',attempts:3}],
    ['bad','invalid_event_payload',{code:'event_fields_missing',scope:'event',attempts:3}]]);
});

test('event outcomes: streamed corrections and repeated IDs save each valid event only once',async()=>{
  reset();const index=contextFixture(),events=['corrected','good'].map(id=>chatFixture(id));
  events.forEach(e=>e.chat_context=index.forRefs(e.source_refs));const accepted=[],failed=[];
  const broken=outcomeItem(events[0]);broken.chat.evidence_source_refs=[];
  const items=[broken,...events.map(outcomeItem),outcomeItem(events[0])];
  cloudHandler=async(options,stream)=>{
    const content=JSON.stringify({events:items});let length=0;
    for(const piece of [content.slice(0,80),content.slice(80,200),content.slice(200)]){
      length+=piece.length;stream.onProgress({phase:'receiving',responseCode:200,receivedBytes:length,contentChars:length,
        reasoningChars:0,contentDelta:piece,reasoningDelta:'',finishReason:''});
    }
    assert.deepEqual(accepted,['corrected','good'],'Accept complete objects before the response ends');return content;
  };
  const result=await new DataPipelineModelClient().enrichEvents(events,config,{onEvent:e=>accepted.push(e.event_id),
    onFailure:(e,reason)=>failed.push(reason)},index.all());
  assert.deepEqual(result.map(e=>e.event_id),['corrected','good']);assert.deepEqual(accepted,['corrected','good']);assert.deepEqual(failed,[]);
});

test('event outcomes: buffered successes and exact failure receipts survive publication failure and restart',async()=>{
  reset();const real=new DataPipelineModelClient(),model=new Model();model.enrichEvents=real.enrichEvents.bind(real);model.fail=true;
  const fixture=evidenceFixture('2026-11-02','wechat.md','mixed',['小王告诉我会议已结束','我请小王回复材料']);let calls=0;
  cloudHandler=async(options,stream)=>{
    calls++;const items=JSON.parse(options.messages[1].content).events.map(outcomeItem);
    for(const item of items)if(item.event_id.endsWith('#2'))item.chat.evidence_source_refs=[];
    return bufferedOutcomes(stream,items);
  };
  await assert.rejects(new IndexService(paths,storage,model).build(config),/interrupted/);
  const failure=JSON.parse([...disk.entries()].find(([file])=>file.endsWith('.failed.json'))[1]);
  assert.equal(failure.policy,'event-analysis-v3');assert.equal(failure.attempts,3);assert.equal(failure.code,'evidence_refs_missing');assert.equal(failure.scope,'event');
  assert.equal(failure.reason,'invalid_chat_attribution');assert.ok(failure.failed_at);
  assert.equal([...disk.keys()].filter(file=>file.includes('/sync-cache/events/')&&!file.endsWith('.failed.json')).length,1);
  model.fail=false;const service=new IndexService(paths,storage,model),result=await service.build(config);
  assert.equal(calls,3,'Exhausted retries and completed outcomes persist outside the publication transaction');
  assert.equal(result.failedEventCount,1);assert.equal(Object.keys(service.loadEvents()).length,1);
  assert.ok(logs.some(line=>line.includes('code=evidence_refs_missing scope=event')));
});

test('event outcomes: checkpoint storage errors remain fatal for streamed, buffered and failed items',async()=>{
  for(const mode of ['streamed','buffered','failure']) {
    reset();const client=new DataPipelineModelClient(),service=new IndexService(paths,storage,client),e=event('write-failure');
    cloudHandler=async(options,stream)=>{
      const items=mode==='failure'?[]:[outcomeItem(e)];
      return mode==='streamed'?JSON.stringify({events:items}):bufferedOutcomes(stream,items);
    };
    failWrite=file=>file.includes('/sync-cache/events/');
    await assert.rejects(service.enrichWithCheckpoint([e],config),/保存事件检查点失败/);
    assert.equal([...disk.keys()].filter(file=>file.endsWith('.failed.json')).length,0);
    assert.equal(service.failedEventIds.size,0,'A storage failure is not a completed model rejection');
  }
});

test('event outcomes: a valid durable success takes precedence over an obsolete failure marker',async()=>{
  reset();const client=new DataPipelineModelClient(),e=event('recovered'),service=new IndexService(paths,storage,client);
  cloudHandler=async()=>JSON.stringify({events:[]});await service.enrichWithCheckpoint([e],config);
  const failureFile=[...disk.keys()].find(file=>file.endsWith('.failed.json')),failure=disk.get(failureFile);
  disk.delete(failureFile);cloudHandler=async()=>JSON.stringify({events:[outcomeItem(e)]});
  await new IndexService(paths,storage,client).enrichWithCheckpoint([e],config);disk.set(failureFile,failure);
  cloudHandler=async()=>{throw Error('Must reuse the valid durable success');};
  const next=new IndexService(paths,storage,client);assert.equal((await next.enrichWithCheckpoint([e],config)).length,1);
  assert.equal(next.failedEventIds.size,0);
});

test('event outcomes: legacy unfinished sources recover without rereading successful history',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model),day='2026-11-02';
  const selected=evidenceFixture(day,'selected.md','selected',['我等小王回复材料','小王说已经发出']);
  const untouched=evidenceFixture(day,'untouched.md','untouched');
  const relative='2026-11/selected.md.state.json',requested=[];
  model.enrichEvents=async(events,c,callbacks)=>{const good=[];for(const e of events){
    if(e.source_state_file===relative)callbacks.onFailure(e,'invalid_or_failed_response');
    else {callbacks.onEvent(e);good.push(e);}}return good;};
  await service.build(config);
  const manifest=storage.readJson(paths.indexesRoot+'/manifest.json',{});
  delete manifest.sources[relative].analysis_policy;storage.writeJsonAtomic(paths.indexesRoot+'/manifest.json',manifest);
  for(const [file,text] of disk)if(file.endsWith('.failed.json')){
    const receipt=JSON.parse(text);delete receipt.attempts;receipt.policy='event-outcome-v2';disk.set(file,JSON.stringify(receipt));
  }
  model.enrichEvents=async(events,c,callbacks)=>{const result=[];for(const e of events){requested.push(e.event_id);
    if(e.record_id===1){const good={...e,domains:['other'],enrichment_method:'model_batch'};callbacks.onEvent(good);result.push(good);}
    else callbacks.onFailure(e,'invalid_chat_attribution',{code:'evidence_refs_missing',scope:'event',attempts:3});
  }return result;};
  reads.clear();const selection=service.changedSourceSelection(config,[]);
  assert.deepEqual(clone(selection.sources),[relative]);
  const first=await service.build(config,undefined,selection);
  assert.deepEqual(requested.sort(),[relative+'#1',relative+'#2']);assert.equal(first.failedEventCount,1);
  assert.equal(reads.get(untouched.state)||0,0);assert.equal(reads.get(untouched.log)||0,0);
  assert.equal(Object.keys(service.loadEvents()).length,2);requested.length=0;
  const next=service.changedSourceSelection(config,[]);assert.equal(next.sources.length,0);
  await service.build(config,undefined,next);assert.equal(requested.length,0);
});

test('event outcomes: recovery selection depends on unfinished policy, never on a specific error or topic',()=>{
  reset();const service=new IndexService(paths,storage,new Model());reads.clear();
  const manifest={sources:{
    'old-timeout':{failed_event_ids:['a'],analysis_policy:'old'},
    'old-attribution':{failed_event_ids:['b']},
    'exhausted':{failed_event_ids:['c'],analysis_policy:'event-analysis-v3'},
    'successful':{failed_event_ids:[]}}};
  assert.deepEqual(clone(service.pendingFailureSources(manifest)),['old-timeout','old-attribution']);
  assert.equal(reads.size,0,'Selection uses the source manifest, not a scan of historical receipts or raw logs');
});

test('chat context: persisted workflow pages recover one collection even when no image was saved',async()=>{
  reset();const daily=paths.dailyLogRoot+'/2026-10-31/com.tencent.mm__basic.md';
  storage.writeTextAtomic(daily,'<!-- DAILY_LOG_METADATA\n'+JSON.stringify({workflow_metadata:{task_scene_id:3},latest_entry_index:2})+'\n-->\n\n1. 小王说请发PPT\n\n2. 我说已发送，小王说收到\n');
  storage.writeJsonAtomic(paths.workflowRunsRoot+'/run-a/run_summary.json',{steps:{'3.1':{output:{tool_name:'vlm_qa',mode:'summary',daily_log_path:daily,response:'小王说请发PPT'}},
    '3.2':{output:{tool_name:'vlm_qa',mode:'summary',daily_log_path:daily,response:'我说已发送，小王说收到'}}}});
  const service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap();
  const context=service.chatContexts.forRefs(['2026-10-31/com.tencent.mm__basic.md#1']);
  assert.equal(context.complete,true);const batches=service.loadChatContextBatches([chatFixture('wx',{chat_context:context})]);
  assert.equal(batches[0].entries.length,2);assert.ok(batches[0].entries[1].text.includes('已发送'));
});
test('chat context: fast WeChat collection uses run ID and workflow metadata keeps collection boundaries',async()=>{
  reset();const dir=paths.dailyLogRoot+'/2026-10-31/';
  storage.writeTextAtomic(dir+'com.tencent.mm__wechat_auto_summary__r.md','<!-- DAILY_LOG_METADATA\n'+JSON.stringify({workflow_metadata:{task_scene_id:3,run_id:'quick-r'}})+'\n-->\n\n1. 小王：我很累\n');
  const service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap();
  const ctx=service.chatContexts.forRefs(['2026-10-31/com.tencent.mm__wechat_auto_summary__r.md#1']);
  assert.equal(ctx.batch_ids[0],'wechat:quick-r');assert.equal(ctx.complete,true);
  const parsed=load(base+'DataManagerUtils').parseDailyLogDocument('<!-- DAILY_LOG_METADATA\n'+JSON.stringify({entry_batch_ids:{'1':'workflow:old','2':'workflow:new'}})+'\n-->\n');
  assert.equal(parsed.entry_batch_ids['1'],'workflow:old');assert.equal(parsed.entry_batch_ids['2'],'workflow:new');
});
function concernResponse(extra={}) {return JSON.stringify({concerns:[{subject:'other',subject_name:'小王',title:'最近压力大',summary:'聊聊如何关心小王',opening:'想聊聊怎样关心小王吗？',category:'relationship',evidence_refs:['record-1'],...extra}]});}
test('chat context: real sync requests see later-page answers across the eight-event chunk boundary',async()=>{
  reset();const index=contextFixture(),events=Array.from({length:10},(_,i)=>chatFixture('wx'+i));
  for(const e of events)e.chat_context=index.forRefs(e.source_refs);
  let calls=0;cloudHandler=async options=>{calls++;assert.equal(options.baseUrl,config.baseUrl);
    const input=JSON.parse(options.messages[1].content);assert.equal(input.chat_batches.length,1);
    assert.ok(input.chat_batches[0].entries[1].text.includes('已经发了'));
    assert.ok(!JSON.stringify(input).includes('再发一份'));assert.ok(options.messages[0].content.includes('不同联系人/群'));
    return JSON.stringify({events:input.events.map(e=>({event_id:e.event_id,keywords:['PPT'],domains:['work'],entities:[],
      todo:{type:'plan',deadline:'2026-11-01',text:'发PPT',agent_task:''},
      chat:{subject:'self',subject_name:'',action_owner:'self',action_owner_name:'',user_involved:true,status:'resolved',
        evidence_source_refs:['2026-10-31/wechat.md#2']}}))});};
  const result=await new DataPipelineModelClient().enrichEvents(events,config,undefined,index.all());
  assert.equal(calls,2);assert.equal(result.length,10);assert.ok(result.every(e=>e.todo.text===''&&e.chat_attribution.status==='resolved'));
});
test('chat context: a third-party task keeps its owner and never inherits a GUI action',async()=>{
  reset();const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  cloudHandler=async()=>JSON.stringify({events:[{event_id:e.event_id,keywords:['商品'],domains:['other'],entities:[],
    todo:{type:'buy',deadline:'',text:'小王要购买商品',agent_task:'打开淘宝下单'},
    chat:{subject:'other',subject_name:'小王',action_owner:'other',action_owner_name:'小王',user_involved:true,status:'pending',
      evidence_source_refs:e.source_refs}}]});
  const [result]=await new DataPipelineModelClient().enrichEvents([e],config,undefined,index.all());
  assert.equal(result.chat_attribution.action_owner_name,'小王');assert.equal(result.todo.type,'buy');assert.equal(result.todo.agent_task,'');
});
test('chat context: unresolved but unrelated, incomplete, or un-attributed output cannot become a user reminder',async()=>{
  reset();const index=contextFixture();let raw={subject:'other',subject_name:'小王',action_owner:'other',action_owner_name:'小王',user_involved:false,status:'pending',evidence_source_refs:['2026-10-31/wechat.md#1']};
  cloudHandler=async options=>JSON.stringify({events:JSON.parse(options.messages[1].content).events.map(e=>({event_id:e.event_id,keywords:[],domains:['other'],entities:[],todo:{type:'buy',deadline:'',text:'购买',agent_task:''},chat:raw}))});
  const e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  assert.equal((await new DataPipelineModelClient().enrichEvents([e],config,undefined,index.all()))[0].todo.type,'');
  raw={...raw,user_involved:true};e.chat_context.complete=false;
  assert.equal((await new DataPipelineModelClient().enrichEvents([e],config,undefined,index.all()))[0].todo.type,'');
  raw={};e.chat_context.complete=true;
  await assert.rejects(new DataPipelineModelClient().enrichEvents([e],config,undefined,index.all()),/CHAT_ATTRIBUTION_INVALID/);
});
test('chat context: local cache changes when same-batch evidence changes, not on another batch',()=>{
  const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  const before=load(base+'IndexService').eventEnrichInputFingerprint(e);
  index.add('workflow:run-b','other','小王：换了安排',[],2);
  e.chat_context=index.forRefs(e.source_refs);assert.equal(load(base+'IndexService').eventEnrichInputFingerprint(e),before);
  index.add('workflow:run-a','same','小王：任务已取消',[],3);
  e.chat_context=index.forRefs(e.source_refs);assert.notEqual(load(base+'IndexService').eventEnrichInputFingerprint(e),before);
});
test('chat context: comfort names the actual person and chat keeps that identity',()=>{
  const e=chatFixture('wx',{summary:'小王很疲惫',normalized_fact:'小王：我最近压力很大；我：想帮帮你'});
  const result=comfort.parseHomeComfortConcerns(concernResponse(),'x',[e]);assert.equal(result[0].title,'小王：最近压力大');
  assert.equal(result[0].subjectName,'小王');const messages=comfort.buildHomeComfortChatMessages(result[0],[],[e],'2026-10-31');
  assert.ok(messages[0].content.includes('情绪、经历或任务'));assert.ok(messages[0].content.includes('"subject_name": "小王"'));
});
test('comfort titles: self uses plain content while only other-person titles receive a name prefix',()=>{
  const e=chatFixture('self',{summary:'最近工作压力大',normalized_fact:'我最近工作压力很大',chat_attribution:{subject:'self',subject_name:''}});
  for(const [title,name] of [['我：最近有点累',''],['用户 : 最近有点累',''],['关于本人：最近有点累',''],['示例用户：最近有点累','示例用户']]) {
    const [result]=comfort.parseHomeComfortConcerns(concernResponse({subject:'self',subject_name:name,title}),'self',[e]);
    assert.equal(result.title,'最近有点累');assert.equal(result.subjectName,'');
  }
  assert.equal(comfort.homeComfortConcernTitle('工作：项目压力','self'),'工作：项目压力','Topic labels must not be mistaken for personal names');
  assert.equal(comfort.homeComfortConcernTitle('小王：最近有点累','other','小王'),'小王：最近有点累');
});
test('comfort titles: cached self prefixes are cleaned on read without another model request',()=>{
  reset();const {HomeComfortConcernStore}=load('entry/src/main/ets/pages/home/HomeComfortConcernStore');
  const e=chatFixture('self',{normalized_fact:'我很累'}),[item]=comfort.parseHomeComfortConcerns(concernResponse({subject:'self',subject_name:'',title:'最近有点累'}),'self',[e]);
  item.title='我：最近有点累';const store=new HomeComfortConcernStore('/app',storage);store.save('2026-11-02','input',[item]);
  assert.equal(store.load('2026-11-02').concerns[0].title,'最近有点累');
});
test('chat context: comfort drops unknown or invented subjects and another person cannot become self',()=>{
  const e=chatFixture('wx',{chat_attribution:{subject:'other',subject_name:'小王'}});
  assert.throws(()=>comfort.parseHomeComfortConcerns(concernResponse({subject:'self'}),'x',[e]),/人物归属/);
  assert.throws(()=>comfort.parseHomeComfortConcerns(concernResponse({subject_name:'小赵'}),'x',[e]),/人物归属/);
  assert.throws(()=>comfort.parseHomeComfortConcerns(concernResponse({subject:'unknown'}),'x',[e]),/人物归属/);
  assert.throws(()=>comfort.parseHomeComfortConcerns('{}','x',[e]),/未返回内容列表/);
  assert.deepEqual(clone(comfort.parseHomeComfortConcerns('{"concerns":[]}','x',[e])),[]);
});
function comfortPageFixture(events,day='2026-11-02') {
  const file=path.join(root,'entry/src/main/ets/pages/Index.ets');
  const tree=ts.createSourceFile('Index.ts',fs.readFileSync(file,'utf8').replace(/\bstruct Index\b/,'class Index'),ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='Index');
  const names=['recentHomeComfortChatEvents','refreshHomeComfortConcerns','initializeStartupServices'];
  const methods=component.members.filter(n=>ts.isMethodDeclaration(n)&&names.includes(n.name.getText(tree)));
  assert.equal(methods.length,names.length);
  const {HomeComfortConcernStore}=load('entry/src/main/ets/pages/home/HomeComfortConcernStore');
  class Cache extends HomeComfortConcernStore {constructor(dir){super(dir,storage);}}
  const exported={},state={toasts:[],clears:0,calls:0,readError:false,modelError:false,reply:concernResponse(),queries:[]};
  vm.runInNewContext(ts.transpileModule('exports.Page=class Page {'+methods.map(n=>n.getText(tree)).join('\n')+'}',
    {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,{exports:exported,Date,Promise,
    ...comfort,HomeComfortConcernStore:Cache,HOME_COMFORT_CHAT_SCENE_ID:3,HOME_COMFORT_CHAT_WINDOW_DAYS:7,
    currentLocalDateKey:()=>day,formatLocalDateKey:d=>d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0'),
    offsetLocalDate:(d,n)=>{const next=new Date(d);next.setDate(next.getDate()+n);return next;},
    showToastSafely:(text,duration)=>state.toasts.push({text,duration}),AiServiceAccess:{isAllowed:()=>true},
    AppLogger:{info(){},warnCause(){},errorCause(){}},dataManagerWarn(){}});
  const page=new exported.Page();Object.assign(page,{filesDir:'/app',homeComfortConcerns:[],homeComfortConcernsLoading:false,
    homeComfortConcernError:'',homeComfortConcernBatch:0,homeComfortChatStore:{clear:()=>state.clears++},ensureAiServiceLogin:()=>true,
    getConfiguredCloudConfig:()=>({}),isConfiguredCloudPlannerReady:()=>true,
    dataManagerFacade:{queryIndexedEvents:options=>{state.queries.push(options);if(state.readError)throw Error('injected read failure');return {events};}},
    cloudClient:{chatPlanner:async()=>{state.calls++;if(state.modelError)throw Error('injected network failure');return state.reply;}}});
  return {page,state};
}
test('comfort cache: restart restores named third-party cards and unchanged inputs do not call the model again',async()=>{
  reset();const e=chatFixture('wx',{summary:'小王很疲惫',normalized_fact:'小王说最近压力很大'});
  const first=comfortPageFixture([e]);await first.page.refreshHomeComfortConcerns(false);
  assert.equal(first.state.calls,1);assert.equal(first.page.homeComfortConcerns[0].title,'小王：最近压力大');
  const reopened=comfortPageFixture([e]);await reopened.page.refreshHomeComfortConcerns(false);
  assert.equal(reopened.state.calls,0);assert.equal(reopened.page.homeComfortConcerns[0].title,'小王：最近压力大');
  assert.equal(reopened.state.clears,0);await reopened.page.refreshHomeComfortConcerns(true);assert.equal(reopened.state.calls,1);
});
test('comfort cache: failed reads retain the persisted cards and emit one bottom system toast even during startup',async()=>{
  reset();const e=chatFixture('wx',{normalized_fact:'小王说最近压力很大'});
  const first=comfortPageFixture([e]);await first.page.refreshHomeComfortConcerns(false);
  const before=storage.readText('/app/home-comfort/concerns.json');
  const reopened=comfortPageFixture([e]);reopened.state.readError=true;await reopened.page.refreshHomeComfortConcerns(false);
  assert.equal(reopened.page.homeComfortConcerns.length,1);assert.equal(reopened.state.calls,0);assert.equal(reopened.state.clears,0);
  assert.equal(reopened.state.toasts.length,1);assert.match(reopened.state.toasts[0].text,/读取失败/);
  assert.equal(storage.readText('/app/home-comfort/concerns.json'),before);
});
test('comfort cache: network or invalid-person responses cannot overwrite successful cards with an empty result',async()=>{
  reset();const e=chatFixture('wx',{normalized_fact:'小王说最近压力很大'});
  const {page,state}=comfortPageFixture([e]);await page.refreshHomeComfortConcerns(false);const id=page.homeComfortConcerns[0].id;
  const before=storage.readText('/app/home-comfort/concerns.json');state.modelError=true;
  await page.refreshHomeComfortConcerns(true);assert.equal(page.homeComfortConcerns[0].id,id);
  state.modelError=false;state.reply=concernResponse({subject_name:'凭空的人'});
  await page.refreshHomeComfortConcerns(true);assert.equal(page.homeComfortConcerns[0].id,id);
  assert.equal(storage.readText('/app/home-comfort/concerns.json'),before);assert.equal(state.toasts.length,2);
  assert.equal(state.clears,1,'Only the successful initial generation clears the conversation');
});
test('comfort cache: empty checks are cached, input changes invalidate them, and prior topics survive the next day',async()=>{
  reset();const events=[chatFixture('wx',{normalized_fact:'小王说最近压力很大'})];
  const first=comfortPageFixture(events);first.state.reply='{"concerns":[]}';await first.page.refreshHomeComfortConcerns(false);
  const reopened=comfortPageFixture(events);await reopened.page.refreshHomeComfortConcerns(false);assert.equal(reopened.state.calls,0);
  events[0]={...events[0],normalized_fact:'小王说最近很疲惫'};await reopened.page.refreshHomeComfortConcerns(false);assert.equal(reopened.state.calls,1);
  const key=comfort.homeComfortInputIdentity(events,'2026-11-02');events[0].chat_attribution={subject:'other',subject_name:'小王'};
  assert.notEqual(comfort.homeComfortInputIdentity(events,'2026-11-02'),key);
  const {HomeComfortConcernStore}=load('entry/src/main/ets/pages/home/HomeComfortConcernStore');
  assert.equal(new HomeComfortConcernStore('/app',storage).load('2026-11-03').concerns.length,1);
  const many=Array.from({length:49},(_,i)=>({...events[0],event_id:'wx'+i})),bounded=comfort.homeComfortInputIdentity(many,'2026-11-02');
  many[48].normalized_fact='outside prompt window';assert.equal(comfort.homeComfortInputIdentity(many,'2026-11-02'),bounded);
});

test('comfort topics: neutral interests and plans can start a conversation without inventing distress',()=>{
  const e=chatFixture('interest',{summary:'用户最近在学摄影',normalized_fact:'用户最近开始学习摄影，想试试拍夜景'});
  const prompt=comfort.buildHomeComfortConcernPrompt([e],'2026-11-03');
  assert.ok(prompt.includes('不必存在烦恼或负面情绪'));
  assert.ok(prompt.includes('兴趣好奇、新鲜经历、工作或学习进展'));
  assert.ok(!prompt.includes('没有明确烦恼时输出'));
  const [topic]=comfort.parseHomeComfortConcerns(concernResponse({subject:'self',subject_name:'',title:'最近拍到了什么',
    summary:'你最近开始学习摄影，可以聊聊拍照体验',opening:'最近最想尝试拍什么？'}),'interest',[e]);
  assert.equal(topic.title,'最近拍到了什么');
  const messages=comfort.buildHomeComfortChatMessages(topic,[{role:'user',content:'想聊摄影',id:'m',createdAt:1}],[e],'2026-11-03');
  assert.ok(messages[0].content.includes('不必把普通话题解释成情绪问题'));
});

test('comfort topics: empty generation retains previous topics and conversations through refresh and restart',async()=>{
  reset();const events=[chatFixture('wx',{normalized_fact:'小王说最近压力很大'})];
  const first=comfortPageFixture(events);await first.page.refreshHomeComfortConcerns(false);
  const original=clone(first.page.homeComfortConcerns),clears=first.state.clears;
  events.push(chatFixture('new',{normalized_fact:'聊到了一个新话题'}));
  first.state.reply='{"concerns":[]}';await first.page.refreshHomeComfortConcerns(false);
  assert.deepEqual(clone(first.page.homeComfortConcerns),original);assert.equal(first.state.clears,clears);
  await first.page.refreshHomeComfortConcerns(false);assert.equal(first.state.calls,2,'The empty result is a completed check');
  const reopened=comfortPageFixture(events);await reopened.page.refreshHomeComfortConcerns(false);
  assert.equal(reopened.state.calls,0);assert.deepEqual(clone(reopened.page.homeComfortConcerns),original);
  await first.page.refreshHomeComfortConcerns(true);assert.equal(first.state.calls,3,'Manual refresh can check again');
  assert.equal(first.state.clears,clears);assert.deepEqual(clone(first.page.homeComfortConcerns),original);
});

test('comfort topics: zero recent input or an empty next-day check never removes the last successful cards',async()=>{
  reset();const e=chatFixture('wx',{normalized_fact:'小王说最近压力很大'});
  const first=comfortPageFixture([e]);await first.page.refreshHomeComfortConcerns(false);
  const previous=clone(first.page.homeComfortConcerns);
  const nextDay=comfortPageFixture([e],'2026-11-03');nextDay.state.reply='{"concerns":[]}';
  await nextDay.page.refreshHomeComfortConcerns(false);assert.deepEqual(clone(nextDay.page.homeComfortConcerns),previous);
  assert.equal(nextDay.state.calls,1);assert.equal(nextDay.state.clears,0);
  const noInput=comfortPageFixture([],'2026-11-04');await noInput.page.refreshHomeComfortConcerns(false);
  assert.deepEqual(clone(noInput.page.homeComfortConcerns),previous);assert.equal(noInput.state.calls,0);assert.equal(noInput.state.clears,0);
  const again=comfortPageFixture([],'2026-11-04');await again.page.refreshHomeComfortConcerns(false);
  assert.deepEqual(clone(again.page.homeComfortConcerns),previous);assert.equal(again.state.calls,0);
});

test('comfort topics: new nonempty topics replace previous cards and empty first use stays a valid empty cache',async()=>{
  reset();const empty=comfortPageFixture([]);await empty.page.refreshHomeComfortConcerns(false);
  assert.equal(empty.page.homeComfortConcerns.length,0);assert.equal(empty.state.clears,0);assert.equal(empty.state.calls,0);
  const e=chatFixture('wx',{normalized_fact:'小王说最近压力很大'}),first=comfortPageFixture([e]);
  await first.page.refreshHomeComfortConcerns(false);const old=first.page.homeComfortConcerns[0].id;
  first.state.reply=concernResponse({title:'小王：最近想聊什么'});await first.page.refreshHomeComfortConcerns(true);
  assert.notEqual(first.page.homeComfortConcerns[0].id,old);assert.equal(first.state.clears,2);
  assert.equal(first.page.homeComfortConcerns[0].title,'小王：最近想聊什么');
});

test('chat undated actions: contact, replies and prerequisites survive enrichment, indexing and reminder planning',async()=>{
  reset();const ref='2026-11-02/dialog.md#1',index=new chatContext.ChatCollectionContextIndex();
  index.add('undated',ref,'会话类型：私聊\n会话名称：同事甲\n位置：右侧｜发送人：我｜聊天对象：同事甲｜原文：确认材料后联系同事甲。',[],1);
  const values=['确认材料后联系同事甲','回复同事甲','同事甲处理材料','普通聊天'];
  const events=values.map((text,i)=>chatFixture('undated-'+i,{event_date:'2026-11-02',source_refs:[ref],summary:text,normalized_fact:text}));
  for(const e of events)e.chat_context=index.forRefs(e.source_refs);
  cloudHandler=async options=>{
    assert.ok(options.messages[0].content.includes('明确日期不是行动或关注的必要条件'));
    const input=JSON.parse(options.messages[1].content);
    return JSON.stringify({events:input.events.map((e,i)=>({event_id:e.event_id,keywords:[],domains:['other'],entities:[],
      todo:{type:'',deadline:'',time_text:'',text:i===3?'':values[i],agent_task:'打开手机执行'},
      chat:{subjects:[{kind:'other',name:'同事甲'}],action_owners:[{kind:'self',name:''}],user_involved:true,
        status:i===1?'resolved':i===2?'unknown':'pending',evidence_source_refs:[ref]}}))});
  };
  const result=await new DataPipelineModelClient().enrichEvents(events,config,undefined,index.all());
  assert.equal(result[0].todo.type,'other');assert.equal(result[0].todo.deadline,'');
  assert.equal(result[0].todo.text,values[0]);assert.equal(result[0].todo.agent_task,'');
  for(const e of result.slice(1))assert.equal(e.todo.type,'','Resolved, uncertain and empty outputs stay nonactionable');
  const service=new IndexService(paths,storage,new Model()),map=Object.fromEntries(result.map(e=>[e.event_id,e]));
  const doc=service.buildHomeTodoDocument(map);assert.deepEqual(clone(doc.no_deadline_event_ids),['undated-0']);
  const {isHomeTodoIndexCandidate}=load(base+'IndexService');
  assert.equal(isHomeTodoIndexCandidate({type:'other',text:'联系同事甲',deadline:'',agent_task:''}),true);
  assert.equal(isHomeTodoIndexCandidate({type:'',text:'普通聊天',deadline:'',agent_task:''}),false);
  const {HomeRecommendationService}=load(base+'HomeRecommendationService');
  const planner=new HomeRecommendationService(paths,storage,new Model(),{loadHomeTodoCandidateEvents:()=>map});
  planner.currentDateKey=()=> '2026-11-03';
  assert.deepEqual(clone(planner.planningContext().candidateEventIds),['undated-0']);
});
test('comfort startup: cache restore starts without waiting for the task suggestion request',async()=>{
  reset();const {page}=comfortPageFixture([]);let release;const blocked=new Promise(resolve=>{release=resolve;});let comfortStarted=false;
  page.homeTaskSuggestionsAutoStarted=false;page.maybeShowCalendarConsent=()=>{};
  page.refreshHomeTaskSuggestions=async()=>blocked;page.refreshHomeComfortConcerns=async()=>{comfortStarted=true;};
  page.initializeStartupServices();await Promise.resolve();assert.equal(comfortStarted,true);release();
});
test('chat context: reminder titles name the third-party action owner',()=>{
  const {HomeRecommendationService}=load(base+'HomeRecommendationService');
  const service=new HomeRecommendationService(paths,storage,new Model(),new IndexService(paths,storage,new Model()));
  const e=chatFixture('wx',{chat_attribution:{action_owner:'other',action_owner_name:'小王'}});
  assert.equal(service.recommendationTitle({title:'发送PPT'},['wx'],{wx:e}),'小王：发送PPT');
});
test('chat migration: a context schema change never enqueues or reanalyzes immutable history',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  const raw='com.tencent.mm__wechat_auto_summary__old.md',ref='2026-10-31/'+raw+'#1';
  const chatState=paths.outputStatePath('2026-10','wechat.md'),shoppingState=paths.outputStatePath('2026-10','shopping.md');
  storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-31/'+raw,'<!-- DAILY_LOG_METADATA\n'+JSON.stringify({workflow_metadata:{task_scene_id:3,run_id:'old'}})+'\n-->\n\n1. 小王：请明天发PPT\n');
  storage.writeJsonAtomic(chatState,{metadata:{},records:[{...reviewRecord(1),source_refs:[ref],workflow_scene_ids:[3]}]});
  storage.writeJsonAtomic(shoppingState,{metadata:{},records:[reviewRecord(2)]});
  await service.build(config);const all=service.loadEvents(),chatId=Object.keys(all).find(id=>all[id].workflow_scene_ids.includes(3));
  assert.ok(all[chatId].chat_context?.complete);const partition=storage.readJson(paths.indexesRoot+'/events/2026-10.json',null);
  const legacy=partition.events.find(e=>e.event_id===chatId);delete legacy.chat_context;storage.writeJsonAtomic(paths.indexesRoot+'/events/2026-10.json',partition);
  const manifest=storage.readJson(paths.indexesRoot+'/manifest.json',null);
  manifest.sources['2026-10/wechat.md.state.json'].event_input_hashes[chatId]='legacy-without-batch';
  storage.writeJsonAtomic(paths.indexesRoot+'/manifest.json',manifest);
  storage.removeFile(paths.consolidationRoot+'/sync-cache/events/'+storage.sha256Text(chatId)+'.json');
  const receipt=storage.readJson(paths.indexesRoot+'/completion.json',null);delete receipt.chat_context_policy;storage.writeJsonAtomic(paths.indexesRoot+'/completion.json',receipt);
  const selection=service.changedSourceSelection(config,[]);assert.deepEqual(clone(selection.sources),[]);
  model.enriched.length=0;await service.build(config,undefined,selection);assert.deepEqual(model.enriched,[]);
  const nextRaw='com.tencent.mm__wechat_auto_summary__new.md',nextRef='2026-10-31/'+nextRaw+'#1';
  storage.writeTextAtomic(paths.dailyLogRoot+'/2026-10-31/'+nextRaw,'<!-- DAILY_LOG_METADATA\n'+JSON.stringify({workflow_metadata:{task_scene_id:3,run_id:'new'}})+'\n-->\n\n1. 小李：明天补充数据\n');
  storage.writeJsonAtomic(chatState,{metadata:{},records:[{...reviewRecord(1),source_refs:[ref],workflow_scene_ids:[3]},
    {...reviewRecord(3),source_refs:[nextRef],workflow_scene_ids:[3]}]});
  await service.build(config,undefined,service.changedSourceSelection(config,['2026-10/wechat.md.state.json']));
  assert.deepEqual(model.enriched,['2026-10/wechat.md.state.json#3']);
  const count=model.enriched.length;await service.build(config);assert.equal(model.enriched.length,count);
  assert.equal(service.completion().chat_context_policy,chatContext.CHAT_CONTEXT_POLICY);
  assert.ok(Object.values(service.loadEvents()).some(e=>e.source_state_file.includes('shopping.md')));
});
test('chat migration: a user action concerning someone else also names the recipient',()=>{
  const {HomeRecommendationService}=load(base+'HomeRecommendationService');
  const service=new HomeRecommendationService(paths,storage,new Model(),new IndexService(paths,storage,new Model()));
  const e=chatFixture('wx',{chat_attribution:{action_owner:'self',subject:'other',subject_name:'小王'}});
  assert.equal(service.recommendationTitle({title:'帮忙确认材料'},['wx'],{wx:e}),'关于小王：帮忙确认材料');
});
test('chat evidence: one forged cross-batch citation cannot be hidden beside a valid citation',()=>{
  const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  const raw={subject:'self',action_owner:'self',user_involved:true,status:'pending',
    evidence_source_refs:['2026-10-31/wechat.md#1','2026-10-31/wechat.md#3']};
  assert.equal(chatContext.normalizeChatAttribution(raw,e,index.all()).status,'unknown');
});
test('chat evidence: duplicate legacy summaries in two runs never guess a collection identity',async()=>{
  reset();const file='com.tencent.mm__basic.md',daily=paths.dailyLogRoot+'/2026-10-31/'+file;
  storage.writeTextAtomic(daily,'<!-- DAILY_LOG_METADATA\n'+JSON.stringify({workflow_metadata:{task_scene_id:3}})+'\n-->\n\n1. 小王说请发PPT\n');
  for(const run of ['a','b'])storage.writeJsonAtomic(paths.workflowRunsRoot+'/'+run+'/run_summary.json',
    {steps:{'1':{output:{tool_name:'vlm_qa',mode:'summary',daily_log_path:daily,response:'小王说请发PPT'}}}});
  const service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap();
  assert.equal(service.chatContexts.forRefs(['2026-10-31/'+file+'#1']).complete,false);
});
test('chat dedup: consolidation merges nearby repeated collections and preserves the latest context separately',async()=>{
  reset();const filename='wechat.md';
  const entry=(id,batch)=>({source_date:'2026-10-31',file_name:filename,entry_index:id,entry_text:'小王说明天需要提交最终版本的研究材料',workflow_metadata:{task_scene_id:3},
    workflow_scene_id:3,source_ref:'2026-10-31/'+filename+'#'+id,collection_batch_id:batch});
  const entries=[entry(1,'workflow:a'),entry(2,'workflow:a'),entry(3,'workflow:b')];
  const model={async splitEntriesIntoFacts(values){return Object.fromEntries(values.map(e=>[e.source_ref,[{
    summary:e.entry_text,normalized_fact:e.entry_text,event_date:e.source_date,tags:[],model_notes:'',raw_excerpt:e.entry_text,
    source_ref:e.source_ref,source_date:e.source_date,workflow_scene_id:3,dedup_text:e.entry_text}]]));},
    async decideDedup(){throw Error('Exact duplicates must not call the model');}};
  const service=new ConsolidationService(paths,storage,model);
  const state=await service.consolidateGroup({month:'2026-10',fileName:filename,entries},config,5);
  assert.equal(state.records.length,1);assert.equal(state.records[0].source_refs.length,3);
  assert.deepEqual(clone(state.records[0].chat_context_source_refs),[entries[2].source_ref]);
});
test('chat batch: fact splitting sees all pages of its collection and never another collection',async()=>{
  reset();const client=new DataPipelineModelClient();let calls=0;
  const entry=(n,batch,text)=>({source_date:'2026-10-31',file_name:'wechat.md',entry_index:n,entry_text:text,
    workflow_scene_id:3,workflow_metadata:{task_scene_id:3},source_ref:'2026-10-31/wechat.md#'+n,collection_batch_id:batch});
  const first=entry(1,'run-a','群聊：课题组；小王要求我发材料，小李需要补充数据');
  const later=entry(9,'run-a','我：材料已发给小王；小李：明天补充数据');
  const other=entry(10,'run-b','另一次采集的无关内容');
  cloudHandler=async options=>{calls++;const input=JSON.parse(options.messages[1].content);
    assert.equal(input.entries.length,1);assert.equal(input.entries[0].collection_batch_id,'run-a');
    assert.equal(input.chat_batches.length,1);assert.equal(input.chat_batches[0].entries.length,2);
    assert.ok(JSON.stringify(input.chat_batches).includes('材料已发给小王'));
    assert.ok(!JSON.stringify(input).includes('无关内容'));
    assert.ok(options.messages[0].content.includes('不代表一个人或一件事'));
    return JSON.stringify({items:[{source_ref:first.source_ref,facts:[
      {summary:'我向小王发送材料',normalized_fact:'我已向小王发送材料',event_date:'2026-10-31',tags:['材料']},
      {summary:'小李补数据',normalized_fact:'小李计划明天补充数据',event_date:'2026-10-31',tags:['数据']}]}]});};
  const result=await client.splitEntriesIntoFacts([first],config,[first,later,other]);
  assert.equal(calls,1);assert.equal(result[first.source_ref].length,2);
});

test('chat batch: independent people and resolved states remain independent inside one collection',async()=>{
  reset();const index=new chatContext.ChatCollectionContextIndex();
  const refs=['2026-10-31/wx.md#1','2026-10-31/wx.md#2','2026-10-31/wx.md#3'];
  index.add('run-a',refs[0],'群聊课题组：小王请我发材料；我：明天发',[],1);
  index.add('run-a',refs[1],'群聊课题组：小李说自己明天补数据，我会参加',[],2);
  index.add('run-a',refs[2],'群聊课题组：小陈要求修改标题；我：已经改完，小陈：已确认',[],3);
  const events=refs.map((ref,i)=>chatFixture('person-'+i,{source_refs:[ref],summary:['小王要材料','小李补数据','小陈确认完成'][i]}));
  events.forEach(e=>e.chat_context=index.forRefs(e.source_refs));
  cloudHandler=async options=>{const input=JSON.parse(options.messages[1].content);assert.equal(input.chat_batches.length,1);
    return JSON.stringify({events:input.events.map(e=>{const i=events.findIndex(item=>item.event_id===e.event_id),name=['小王','小李','小陈'][i];
      return {event_id:e.event_id,keywords:['材料'],domains:['other'],entities:[],
        todo:{type:'other',text:name+'处理事项',deadline:'2026-11-01',agent_task:'打开手机'},
        chat:{subjects:[{kind:'other',name}],action_owners:[{kind:i===0?'self':'other',name:i===0?'':name}],
          user_involved:true,status:i===2?'resolved':'pending',evidence_source_refs:[refs[i]]}};})});};
  const result=await new DataPipelineModelClient().enrichEvents(events,config,undefined,index.all());
  assert.equal(result.length,3);assert.equal(result[0].chat_attribution.subject_name,'小王');
  assert.equal(result[0].chat_attribution.action_owner,'self');assert.equal(result[0].chat_attribution.status,'pending');
  assert.equal(result[1].chat_attribution.action_owner_name,'小李');assert.equal(result[1].chat_attribution.status,'pending');
  assert.equal(result[1].todo.agent_task,'');assert.equal(result[2].chat_attribution.status,'resolved');assert.equal(result[2].todo.text,'');
});

test('chat batch: a jointly owned event keeps every person and reminder title',async()=>{
  reset();const index=new chatContext.ChatCollectionContextIndex(),ref='2026-10-31/wx.md#1';
  index.add('run-a',ref,'小王、小李共同补数据；我负责后续汇总',[],1);
  const e=chatFixture('joint',{source_refs:[ref],summary:'小王、小李共同补数据'});e.chat_context=index.forRefs(e.source_refs);
  cloudHandler=async()=>JSON.stringify({events:[{event_id:e.event_id,keywords:[],domains:['other'],entities:[],
    todo:{type:'other',text:'共同补数据',deadline:'2026-11-01',agent_task:'打开手机完成'},
    chat:{subjects:[{kind:'other',name:'小王'},{kind:'other',name:'小李'}],
      action_owners:[{kind:'other',name:'小王'},{kind:'other',name:'小李'}],user_involved:true,status:'pending',evidence_source_refs:[ref]}}]});
  const [result]=await new DataPipelineModelClient().enrichEvents([e],config,undefined,index.all());
  assert.deepEqual(clone(result.chat_attribution.subjects),[{kind:'other',name:'小王'},{kind:'other',name:'小李'}]);
  assert.equal(result.chat_attribution.action_owners.length,2);assert.equal(result.chat_attribution.action_owner,'unknown');
  assert.equal(result.chat_attribution.status,'pending');assert.equal(result.todo.text,'共同补数据');assert.equal(result.todo.agent_task,'');
  const {HomeRecommendationService}=load(base+'HomeRecommendationService');
  const service=new HomeRecommendationService(paths,storage,new Model(),new IndexService(paths,storage,new Model()));
  assert.equal(service.recommendationTitle({title:'共同补数据'},['joint'],{joint:result}),'小王、小李：共同补数据');
});

test('chat batch: unknown or fabricated joint actors cannot silently become actionable',()=>{
  const index=contextFixture(),e=chatFixture();e.chat_context=index.forRefs(e.source_refs);
  const raw={subjects:[{kind:'other',name:'小王'}],action_owners:[{kind:'self',name:''},{kind:'other',name:'凭空造人'}],
    user_involved:true,status:'pending',evidence_source_refs:e.source_refs};
  const result=chatContext.normalizeChatAttribution(raw,e,index.all());
  assert.equal(result.status,'unknown');assert.equal(chatContext.chatHasKnownActionOwners(result),false);
  raw.action_owners=Array.from({length:17},()=>({kind:'self',name:''}));
  assert.equal(chatContext.normalizeChatAttribution(raw,e,index.all()).status,'unknown');
});

test('chat batch: context text is not hashed by successful or failed event checkpoint preparation',async()=>{
  reset();const model=new DataPipelineModelClient(),service=new IndexService(paths,storage,model);
  const index=new chatContext.ChatCollectionContextIndex(),ref='2026-10-31/wx.md#1';
  index.add('run-a',ref,'RAW_CONTEXT_NOT_A_HASH_INPUT '.repeat(600)+'小王',[],1);
  const e=chatFixture('checkpoint',{source_refs:[ref]});e.chat_context=index.forRefs(e.source_refs);service.chatContexts=index;
  cloudHandler=async()=>JSON.stringify({events:[{event_id:e.event_id,keywords:[],domains:['other'],entities:[],
    todo:{type:'',text:'',deadline:'',agent_task:''},chat:{subjects:[{kind:'self',name:''}],action_owners:[{kind:'self',name:''}],
      user_involved:true,status:'resolved',evidence_source_refs:[ref]}}]});
  const original=storage.sha256Text;
  storage.sha256Text=function(value){assert.ok(!value.includes('RAW_CONTEXT_NOT_A_HASH_INPUT'));return original.call(this,value);};
  try {const result=await service.enrichWithCheckpoint([e],config);assert.equal(result.length,1);}
  finally {storage.sha256Text=original;}
});

test('chat cache: old scalar attribution retains its existing reminder cache identity',()=>{
  const old={subject:'other',subject_name:'小王',action_owner:'self',action_owner_name:'',status:'pending',user_involved:true};
  assert.equal(chatContext.chatAttributionFingerprint(old),'other:小王:self::pending');
  const joint={...old,subjects:[{kind:'other',name:'小王'}],action_owners:[{kind:'self',name:''},{kind:'other',name:'小李'}]};
  assert.notEqual(chatContext.chatAttributionFingerprint(joint),chatContext.chatAttributionFingerprint(old));
});

test('chat cache: appending another collection never retries a previously failed immutable event',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model),state=paths.outputStatePath('2026-10','wechat.md');
  const ref=(run)=>'2026-10-31/com.tencent.mm__wechat_auto_summary__'+run+'.md#1';
  const source=(run)=>storage.writeTextAtomic(paths.dailyLogRoot+'/'+ref(run).split('#')[0],
    '<!-- DAILY_LOG_METADATA\n'+JSON.stringify({workflow_metadata:{task_scene_id:3,run_id:run}})+'\n-->\n\n1. 小王：请处理事项\n');
  source('old');
  const records=[{...reviewRecord(1),workflow_scene_ids:[3],source_refs:[ref('old')]}];
  storage.writeJsonAtomic(state,{metadata:{},records});
  model.enrichEvents=async(events,config,callbacks)=>{const good=[];
    for(const e of events){model.enriched.push(e.event_id);if(e.record_id===1){callbacks.onFailure(e,'MODEL_REPEATED_OUTPUT');}
      else good.push({...e,domains:['other'],enrichment_method:'model'});}return good;};
  await service.build(config);model.enriched.length=0;source('new');
  records.push({...reviewRecord(2),workflow_scene_ids:[3],source_refs:[ref('new')]});
  storage.writeJsonAtomic(state,{metadata:{},records});
  await service.build(config,undefined,service.changedSourceSelection(config,['2026-10/wechat.md.state.json']));
  assert.deepEqual(model.enriched,['2026-10/wechat.md.state.json#2']);
  assert.deepEqual(clone(storage.readJson(paths.indexesRoot+'/manifest.json',null).sources['2026-10/wechat.md.state.json'].failed_event_ids),
    ['2026-10/wechat.md.state.json#1']);
});

function evidenceFixture(day,filename,run,texts=['小王请我发论文，我说已经发出']) {
  const relative=day+'/'+filename,log=paths.dailyLogRoot+'/'+relative,refs=texts.map((_,i)=>relative+'#'+(i+1));
  const metadata={workflow_metadata:{task_scene_id:3},entry_batch_ids:Object.fromEntries(texts.map((_,i)=>[i+1,'workflow:'+run]))};
  storage.writeTextAtomic(log,'<!-- DAILY_LOG_METADATA\n'+JSON.stringify(metadata)+'\n-->\n\n'+texts.map((text,i)=>(i+1)+'. '+text+'\n').join('\n'));
  storage.writeJsonAtomic(paths.workflowRunsRoot+'/'+run+'/run_summary.json',{steps:Object.fromEntries(texts.map((text,i)=>['step-'+i,{output:{
    tool_name:'vlm_qa',mode:'summary',daily_log_path:log,response:text,image_path:paths.workflowRunsRoot+'/'+run+'/image-'+i+'.png'}}]))});
  texts.forEach((_,i)=>storage.writeTextAtomic(paths.workflowRunsRoot+'/'+run+'/image-'+i+'.png','fixture-image'));
  const state=paths.outputStatePath(day.slice(0,7),filename),records=texts.map((text,i)=>({...reviewRecord(i+1),
    summary:text,normalized_fact:text,first_seen_date:day,last_seen_date:day,source_dates:[day],workflow_scene_ids:[3],source_refs:[refs[i]]}));
  storage.writeJsonAtomic(state,{metadata:{},records});return {relative,log,refs,state,records};
}
test('index evidence: a new collection never opens unrelated historical logs or runs',async()=>{
  reset();for(let i=0;i<250;i++)evidenceFixture('2020-01-01','old-'+i+'.md','old-'+i);
  const fresh=evidenceFixture('2026-11-01','wechat.md','20261101-new');reads.clear();
  const service=new IndexService(paths,storage,new Model()),images=await service.buildImageReferenceMap([fresh.state],[fresh.relative]);
  assert.equal(images[fresh.refs[0]][0],'runs/20261101-new/image-0.png');
  assert.deepEqual([...reads.keys()].filter(file=>file.startsWith(paths.workflowRunsRoot+'/')),[paths.workflowRunsRoot+'/20261101-new/run_summary.json']);
  assert.deepEqual([...reads.keys()].filter(file=>file.startsWith(paths.dailyLogRoot+'/')),[fresh.log]);
});
test('index evidence: cached pages survive a new source without rereading their raw log or run',async()=>{
  reset();const old=evidenceFixture('2026-10-30','wechat.md','old');
  let service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap([old.state],[old.relative]);
  const fresh=evidenceFixture('2026-10-31','wechat.md','new');
  storage.writeJsonAtomic(old.state,{metadata:{},records:[old.records[0],{...fresh.records[0],record_id:2}]});reads.clear();
  service=new IndexService(paths,storage,new Model());const images=await service.buildImageReferenceMap([old.state],[fresh.relative]);
  assert.equal(images[old.refs[0]][0],'runs/old/image-0.png');assert.equal(images[fresh.refs[0]][0],'runs/new/image-0.png');
  assert.equal(reads.has(old.log),false);assert.equal(reads.has(paths.workflowRunsRoot+'/old/run_summary.json'),false);
  assert.equal(service.chatContexts.forRefs(old.refs).complete,true);
});
test('index evidence: normalized committed summaries retain image links when structured model output differs',async()=>{
  reset();const original='位置：左侧｜发送人：同事甲｜聊天对象：我｜时间原文：昨天09:00｜原文：请买书';
  const committed=messageTime.normalizeChatMessageTimes(original,new Date(2026,10,2,10));
  const data=evidenceFixture('2026-11-02','chat.md','committed-run',[committed]);
  const summaryPath=paths.workflowRunsRoot+'/committed-run/run_summary.json',image=paths.workflowRunsRoot+'/committed-run/image-0.png';
  storage.writeJsonAtomic(summaryPath,{steps:{'3.iter1.1':{started_at:1,output:{action:'screenshot',image_path:image}},'3.iter1.2':{started_at:2,output:{
    tool_name:'vlm_qa',mode:'summary',daily_log_path:data.log,structured_output:{summary:original,contains_today_chat:true},response:committed}}}});
  const service=new IndexService(paths,storage,new Model());const refs=await service.buildImageReferenceMap([data.state],[data.relative]);
  assert.deepEqual(clone(refs[data.refs[0]]),['runs/committed-run/image-0.png']);
  assert.equal(reads.has(image),false,'Image association must not read image contents');
  const cachePath=service.sourceEvidencePath(data.relative),cache=storage.readJson(cachePath,null);
  delete cache.summary_match_policy;cache.entries[0].image_paths=[];storage.writeJsonAtomic(cachePath,cache);reads.clear();
  const repaired=await new IndexService(paths,storage,new Model()).buildImageReferenceMap([data.state],[]);
  assert.deepEqual(clone(repaired[data.refs[0]]),['runs/committed-run/image-0.png']);assert.ok(reads.has(summaryPath));
  reads.clear();await new IndexService(paths,storage,new Model()).buildImageReferenceMap([data.state],[]);
  assert.equal(reads.has(summaryPath),false);assert.equal(reads.has(data.log),false,'A repaired cache must not scan old evidence again');
  const healthy=storage.readJson(cachePath,null);delete healthy.summary_match_policy;storage.writeJsonAtomic(cachePath,healthy);reads.clear();
  await new IndexService(paths,storage,new Model()).buildImageReferenceMap([data.state],[]);
  assert.equal(reads.has(summaryPath),false,'Healthy old image mappings do not require migration');
});
test('index evidence: edited or deleted pages invalidate only their source and cannot return through old batch context',async()=>{
  reset();const before=evidenceFixture('2026-11-01','wechat.md','run',['小王请我发论文','我说已经发出']);
  const service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap([before.state],[before.relative]);
  const after=evidenceFixture('2026-11-01','wechat.md','run',['小王改为明天再发论文']);reads.clear();
  await service.buildImageReferenceMap([after.state],[after.relative]);const context=service.chatContexts.all()[0];
  assert.equal(context.entries.length,1);assert.equal(context.entries[0].text,'小王改为明天再发论文');
  assert.ok(!JSON.stringify(context).includes('已经发出'));assert.equal(reads.has(after.log),true);
});
test('index evidence: source cache corruption rebuilds locally and missing runs are not sealed as resolved',async()=>{
  reset();const first=evidenceFixture('2026-11-01','wechat.md','run');
  let service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap([first.state],[first.relative]);
  storage.writeTextAtomic(service.sourceEvidencePath(first.relative),'broken-json');reads.clear();
  service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap([first.state],[]);
  assert.equal(reads.has(first.log),true);assert.equal(service.chatContexts.forRefs(first.refs).complete,true);
  storage.removeFile(paths.workflowRunsRoot+'/run/run_summary.json');
  await service.buildImageReferenceMap([first.state],[first.relative]);
  assert.equal(storage.readJson(service.sourceEvidencePath(first.relative),null).resolved_runs,false);
  evidenceFixture('2026-11-01','wechat.md','run');reads.clear();
  assert.equal((await service.buildImageReferenceMap([first.state],[]))[first.refs[0]][0],'runs/run/image-0.png');
});
test('index evidence: a legacy match is cached and full verification can still repair it',async()=>{
  reset();const data=evidenceFixture('2026-11-01','wechat.md','legacy');
  storage.writeTextAtomic(data.log,'<!-- DAILY_LOG_METADATA\n'+JSON.stringify({workflow_metadata:{task_scene_id:3}})+'\n-->\n\n1. 小王请我发论文，我说已经发出\n');
  let service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap([data.state],[data.relative]);reads.clear();
  service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap([data.state],[]);
  assert.equal(reads.has(data.log),false);assert.equal([...reads.keys()].some(file=>file.startsWith(paths.workflowRunsRoot+'/')),false);
  reads.clear();await service.buildImageReferenceMap([data.state]);assert.equal(reads.has(data.log),true);
});
test('index evidence: restored sibling source pages retain collection context and truncation stays incomplete',async()=>{
  reset();const a=evidenceFixture('2026-11-01','a.md','shared',['小王请我发论文']);
  const b=evidenceFixture('2026-11-01','b.md','shared',['我说已经发出']);
  // Both outputs belong to one real run; the helper above replaced its summary.
  const steps={};for(const data of [a,b])steps[data.relative]={output:{tool_name:'vlm_qa',mode:'summary',daily_log_path:data.log,
    response:data.records[0].summary,image_path:paths.workflowRunsRoot+'/shared/'+data.relative.slice(11)+'.png'}};
  storage.writeJsonAtomic(paths.workflowRunsRoot+'/shared/run_summary.json',{steps});
  let service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap([a.state,b.state],[a.relative,b.relative]);
  service=new IndexService(paths,storage,new Model());await service.buildImageReferenceMap([a.state],[]);
  assert.equal(service.chatContexts.all()[0].entries.length,2);assert.ok(service.chatContexts.all()[0].entries.some(e=>e.text.includes('已经发出')));
  const index=new chatContext.ChatCollectionContextIndex();index.restore({batch_id:'large',complete:false,
    entries:[{source_ref:'2026-11-01/b.md#1',text:'[中间内容省略]',image_paths:[],order:0}]});
  assert.equal(index.forRefs(['2026-11-01/b.md#1']).complete,false);
});
test('index evidence: failed analysis publishes neither new evidence caches nor a partial generation',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  const old=evidenceFixture('2026-10-31','old.md','old');await service.build(config);
  const generation=storage.readText(paths.indexesRoot+'/completion.json');
  const fresh=evidenceFixture('2026-11-01','new.md','new');model.enrichEvents=async()=>{throw Error('injected model interruption');};
  await assert.rejects(service.build(config,undefined,service.changedSourceSelection(config,['2026-11/new.md.state.json'],[fresh.relative])));
  assert.equal(storage.readText(paths.indexesRoot+'/completion.json'),generation);
  assert.equal(storage.exists(service.sourceEvidencePath(fresh.relative)),false);
  assert.equal(storage.exists(service.sourceEvidencePath(old.relative)),true);
});
test('index evidence: reconnect retries keep timers responsive and preserve the previous committed generation',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  const old=evidenceFixture('2026-10-31','old.md','old');await service.build(config);
  const generation=storage.readText(paths.indexesRoot+'/completion.json');
  const fresh=Array.from({length:48},(_,i)=>evidenceFixture('2026-11-01','new-'+i+'.md','new-'+i));
  const rawBefore=new Map([...disk].filter(([file])=>file.startsWith(paths.dailyLogRoot+'/')||file.startsWith(paths.workflowRunsRoot+'/')));
  const originalRead=storage.readText,originalEnrich=model.enrichEvents;
  // Simulate expensive local run decoding. The host taskpool mock deliberately
  // runs inline: explicit index work slices must still admit real timer turns.
  storage.readText=function(file,fallback){if(file.endsWith('/run_summary.json')){const until=Date.now()+2;while(Date.now()<until){}}return originalRead.call(this,file,fallback);};
  let ticks=0;const timer=setInterval(()=>ticks++,1);
  try {
    model.enrichEvents=async()=>{throw Error('network disconnected');};
    for(let attempt=0;attempt<2;attempt++) {
      const before=ticks;
      await assert.rejects(service.build(config),/network disconnected/);
      assert.ok(ticks-before>=3,'Preparing a retry must yield repeatedly, not merely once before a blocking scan');
      assert.equal(storage.readText(paths.indexesRoot+'/completion.json'),generation);
      assert.ok(fresh.every(item=>!storage.exists(service.sourceEvidencePath(item.relative))));
    }
    model.enrichEvents=originalEnrich;
    await service.build(config);
    assert.ok(fresh.every(item=>storage.exists(service.sourceEvidencePath(item.relative))));
    assert.ok(storage.exists(service.sourceEvidencePath(old.relative)));
    for(const [file,text] of rawBefore)assert.equal(disk.get(file),text,'Retry must not discard original collected evidence');
  } finally {clearInterval(timer);storage.readText=originalRead;model.enrichEvents=originalEnrich;}
});

test('index evidence: background projection excludes image bytes while preserving all fallback matching metadata',async()=>{
  reset();const {readWorkflowRunEvidence}=load(base+'WorkflowRunEvidenceTask');
  const image='A'.repeat(4*1024*1024),file=paths.workflowRunsRoot+'/large/run_summary.json';
  const payload={request:image,steps:{
    'a.0':{output:{unrelated:image}},
    'a.1':{started_at:1,finished_at:2,output:{action:'screenshot',image_b64:image,image_path:'/missing/screen.png'}},
    'a.2':{started_at:3,output:{tool_name:'vlm_qa',mode:'summary',daily_log_path:'/daily-log/2026-11-01/a.md',response:'exact committed text',
      structured_output:{summary:'original model text',unused:image},request:image}}
  }};
  storage.writeJsonAtomic(file,payload);const before=disk.get(file),result=await readWorkflowRunEvidence(file);
  assert.deepEqual(Object.keys(result.steps),Object.keys(payload.steps));
  assert.equal(result.steps['a.1'].started_at,1);assert.equal(result.steps['a.1'].finished_at,2);
  assert.equal(result.steps['a.1'].output.image_b64,'present');
  assert.equal(result.steps['a.2'].output.response,'exact committed text');
  assert.equal(result.steps['a.2'].output.structured_output.summary,'original model text');
  assert.ok(JSON.stringify(result).length<1000,'Embedded screenshots must never return to the UI thread');
  assert.equal(disk.get(file),before);
  storage.writeTextAtomic(file,'{truncated');assert.throws(()=>readWorkflowRunEvidence(file));
});

test('index evidence: screenshot references are resolved once per run and retain scope/time/order precedence',async()=>{
  reset();const service=new IndexService(paths,storage,new Model());
  const {compactWorkflowRunEvidence}=load(base+'WorkflowRunEvidence');
  const {SyncWorkSlice}=load(base+'SyncWorkSlice');
  const steps={
    'same.early':{started_at:1,finished_at:2,output:{action:'screenshot',image_b64:'image'}},
    'other.new':{started_at:7,finished_at:8,output:{action:'screenshot',image_b64:'image'}},
    'same.future':{started_at:20,finished_at:21,output:{action:'screenshot',image_b64:'image'}},
    'same.tool':{started_at:10,output:{tool_name:'vlm_qa',mode:'summary'}},
    'none.tool':{started_at:10,output:{tool_name:'vlm_qa',mode:'summary'}},
    'no-clock.tool':{output:{tool_name:'vlm_qa',mode:'summary'}}
  };
  const compact=compactWorkflowRunEvidence({steps}).steps,keys=Object.keys(compact);
  let resolved=0;const resolve=service.screenshotImageReference;
  service.screenshotImageReference=function(...args){resolved++;return resolve.apply(this,args);};
  const refs=await service.workflowScreenshotReferences('run',compact,keys,new SyncWorkSlice());
  const count=resolved;
  for(let i=0;i<100;i++)assert.equal(service.nearestScreenshotImageReference('same.tool',compact,keys,refs),'runs/run/run_summary.json#steps/same.early/output/image_b64');
  assert.equal(service.nearestScreenshotImageReference('none.tool',compact,keys,refs),'runs/run/run_summary.json#steps/other.new/output/image_b64');
  assert.equal(service.nearestScreenshotImageReference('no-clock.tool',compact,keys,refs),'runs/run/run_summary.json#steps/same.future/output/image_b64');
  assert.equal(resolved,count,'Matching must not repeatedly traverse raw screenshot data or check files');
});

test('index evidence: scoped builds do not stringify retained historical event contents for delta comparison',async()=>{
  reset();const model=new Model(),service=new IndexService(paths,storage,model);
  const old=evidenceFixture('2020-01-01','old.md','old'),fresh=evidenceFixture('2026-11-01','new.md','new');
  await service.build(config);evidenceFixture('2026-11-01','new.md','new',['小王的新项目安排']);logs.length=0;
  await service.build(config,undefined,service.changedSourceSelection(config,['2026-11/new.md.state.json'],[fresh.relative]));
  assert.ok(logs.some(line=>line.startsWith('SYNC_EVENT_DELTA ')&&line.includes('contentCompared=1 retainedByReference=1')));
  assert.ok(storage.readJson(paths.indexesRoot+'/events/2020-01.json',null).events.length===1);
});

const chatDedup = load(base+'ChatFactDedup');
const chatRepeatedText='小王请我在下周五之前提交最终版本的研究论文材料';
function chatDedupEntry(index,batch,day='2026-10-31',text=chatRepeatedText) {
  return {source_date:day,file_name:'wechat.md',entry_index:index,entry_text:text,workflow_metadata:{task_scene_id:3},
    workflow_scene_id:3,source_ref:day+'/wechat.md#'+index,collection_batch_id:batch};
}
function chatDedupFact(entry,extra={}) {
  return {summary:entry.entry_text,normalized_fact:entry.entry_text,event_date:entry.source_date,tags:[],model_notes:'',
    raw_excerpt:entry.entry_text,source_ref:entry.source_ref,source_date:entry.source_date,workflow_scene_id:3,
    dedup_text:entry.entry_text,...extra};
}
function chatDedupRecord(id,entry,extra={}) {
  return {...reviewRecord(id,entry.entry_text),workflow_scene_ids:[3],source_refs:[entry.source_ref],
    first_seen_date:entry.source_date,last_seen_date:entry.source_date,raw_excerpts:[entry.entry_text],...extra};
}
async function consolidateChatFixture(entries,decideDedup=async()=>{throw Error('Unrelated or exact facts need no model comparison');}) {
  const model={async splitEntriesIntoFacts(values){return Object.fromEntries(values.map(entry=>[entry.source_ref,[chatDedupFact(entry)]]));},decideDedup};
  return new ConsolidationService(paths,storage,model).consolidateGroup({month:'2026-10',fileName:'wechat.md',entries},config,5);
}
test('chat dedup: repeated next-day pages merge without raw file reads or text hashes in the window',()=>{
  reset();const old=chatDedupEntry(1,'old','2026-10-30'),fresh=chatDedupEntry(1,'new');
  const record=chatDedupRecord(1,old),window=new chatDedup.ChatFactDedupWindow([record]);
  const hashes=hashedChars,result=window.select(chatDedupFact(fresh),fresh,{[old.source_ref]:'old',[fresh.source_ref]:'new'});
  assert.equal(result.exact,record);assert.equal(reads.size,0);assert.equal(hashedChars,hashes);
});
test('chat dedup: the collection-date window ignores older history even when message dates are old',()=>{
  reset();const old=chatDedupEntry(1,'old','2026-10-29'),ancient=chatDedupEntry(2,'ancient','2026-10-28'),fresh=chatDedupEntry(1,'new');
  const recentRecord=chatDedupRecord(1,old,{first_seen_date:'2026-01-01'}),olderRecord=chatDedupRecord(2,ancient,{first_seen_date:'2026-01-01'});
  const selection=new chatDedup.ChatFactDedupWindow([olderRecord,recentRecord]).select(chatDedupFact(fresh,{event_date:'2026-01-01'}),fresh,{});
  assert.equal(selection.inspected,1);assert.equal(selection.exact,recentRecord);
  const invalid=chatDedupEntry(1,'new','2026-99-99');
  assert.equal(new chatDedup.ChatFactDedupWindow([recentRecord]).select(chatDedupFact(invalid),invalid,{}).inspected,0);
});
test('chat dedup: 2000 historical facts still inspect at most twenty recent candidates and send at most three',()=>{
  reset();const records=[];
  for(let i=0;i<2000;i++)records.push(chatDedupRecord(i+1,chatDedupEntry(i+1,'old','2026-10-31',chatRepeatedText+String.fromCharCode(0x4e00+i))));
  const fresh=chatDedupEntry(2001,'new','2026-10-31',chatRepeatedText+'最新版本');
  const window=new chatDedup.ChatFactDedupWindow(records),selection=window.select(chatDedupFact(fresh),fresh,{});
  assert.equal(selection.inspected,20);assert.ok(selection.candidates.length>0&&selection.candidates.length<=3);
  assert.ok([...window.days.values()].every(bucket=>bucket.length<=20));assert.equal(window.order.size,20);assert.equal(window.recordDays.size,20);
});
test('chat dedup: different amounts, dates and unrelated content bypass the model',async()=>{
  reset();const entries=[chatDedupEntry(1,'a','2026-10-31','小王让我代付最终版本的论文材料费用100元'),
    chatDedupEntry(2,'b','2026-10-31','小王让我代付最终版本的论文材料费用200元'),
    chatDedupEntry(3,'c','2026-10-31','小王约我2026-11-01参加研究论文讨论会'),
    chatDedupEntry(4,'d','2026-10-31','小王约我2026-11-02参加研究论文讨论会'),
    chatDedupEntry(5,'e','2026-10-31','同事介绍了宠物医院的疫苗预约服务')];
  const state=await consolidateChatFixture(entries);assert.equal(state.records.length,5);
});
test('chat dedup: a confirmed semantic duplicate uses a bounded model request and keeps both source references',async()=>{
  reset();const old=chatDedupEntry(1,'old','2026-10-30'),fresh=chatDedupEntry(1,'new','2026-10-31',chatRepeatedText.replace('请我','希望我'));
  let calls=0;const state=await consolidateChatFixture([old,fresh],async(fact,records,cfg,limit,context)=>{
    calls++;assert.ok(records.length<=3);assert.equal(limit,3);assert.deepEqual(clone(context.cross_batch_record_ids),[1]);
    return {decision:'duplicate',matched_record_ids:[1],reason:'same_message',merged_summary:'',merged_fact:'',merged_tags:[]};});
  assert.equal(calls,1);assert.equal(state.records.length,1);assert.equal(state.records[0].source_refs.length,2);
  assert.deepEqual(clone(state.records[0].chat_context_source_refs),[fresh.source_ref]);
});
test('chat dedup: ambiguous output, changed status and forged record IDs preserve the new fact',async()=>{
  for(const outcome of ['skip_ambiguous','merge_with_existing','forged']) {
    reset();const old=chatDedupEntry(1,'old'),fresh=chatDedupEntry(2,'new','2026-10-31',chatRepeatedText.replace('请我','希望我'));
    const state=await consolidateChatFixture([old,fresh],async()=>({decision:outcome==='forged'?'duplicate':outcome,
      matched_record_ids:[outcome==='forged'?999:1],reason:'uncertain',merged_summary:'',merged_fact:'',merged_tags:[]}));
    assert.equal(state.records.length,2,outcome);assert.equal(state.records[1].dedup_status,'new');
  }
});
test('chat dedup: latest collection follows numeric page order even when facts arrive out of order',()=>{
  reset();const early=chatDedupEntry(2,'early'),latest=chatDedupEntry(10,'latest');
  const record=chatDedupRecord(1,early,{source_refs:[latest.source_ref,early.source_ref]});
  chatDedup.updateChatContextSources(record,{[early.source_ref]:'early',[latest.source_ref]:'latest'});
  assert.deepEqual(clone(record.chat_context_source_refs),[latest.source_ref]);
});
test('chat dedup: integration does not read other monthly or task states to search for duplicates',async()=>{
  reset();storage.writeJsonAtomic(paths.outputStatePath('2025-01','wechat.md'),{metadata:{},records:[reviewRecord(1)]});
  storage.writeJsonAtomic(paths.outputStatePath('2026-10','another-contact.md'),{metadata:{},records:[reviewRecord(2)]});
  const old=chatDedupEntry(1,'old','2026-10-30'),fresh=chatDedupEntry(1,'new');reads.clear();
  const state=await consolidateChatFixture([old,fresh]);assert.equal(state.records.length,1);
  assert.ok(![...reads.keys()].some(file=>file.includes('2025-01')||file.includes('another-contact')));
});
test('chat dedup: real request caps candidates and labels collections; model failures keep data',async()=>{
  reset();const fresh=chatDedupEntry(21,'new'),fact=chatDedupFact(fresh),records=Array.from({length:20},(_,i)=>chatDedupRecord(i+1,chatDedupEntry(i+1,'old')));
  const context={cross_batch_record_ids:records.map(record=>record.record_id)},client=new DataPipelineModelClient();
  cloudHandler=async options=>{const input=JSON.parse(options.messages[1].content);assert.equal(input.existing_records.length,3);
    assert.ok(input.existing_records.every(record=>record.same_collection===false));assert.ok(options.messages[0].content.includes('无法确认时保留为new'));
    return JSON.stringify({decision:'duplicate',matched_record_ids:[input.existing_records[0].record_id],reason:'same',
      merged_summary:'不可信改写',merged_fact:'不可信改写',merged_tags:['不可信']});};
  const matched=await client.decideDedup(fact,records,config,100,context);assert.equal(matched.decision,'duplicate');assert.equal(matched.merged_fact,'');
  cloudHandler=async()=>{throw Error('model timeout');};
  assert.equal((await client.decideDedup(fact,records,config,100,context)).decision,'new');
  assert.equal((await client.decideDedup(fact,records,{...config,enabled:false},100,context)).decision,'new');
});
test('chat dedup: index retains provenance but sends only the latest collection and accepts its later answer',async()=>{
  reset();const old=evidenceFixture('2026-10-30','wechat.md','old',[chatRepeatedText]);
  const fresh=evidenceFixture('2026-10-31','wechat.md','new',[chatRepeatedText,'我说研究论文材料已经发出，小王说收到']);
  const merged={...old.records[0],source_refs:[old.refs[0],fresh.refs[0]],last_seen_date:'2026-10-31',chat_context_source_refs:[fresh.refs[0]]};
  storage.writeJsonAtomic(old.state,{metadata:{},records:[merged]});
  const model=new Model(),client=new DataPipelineModelClient();let requests=0;
  cloudHandler=async options=>{requests++;const input=JSON.parse(options.messages[1].content);
    assert.deepEqual(input.events[0].source_refs,[fresh.refs[0]]);assert.equal(input.chat_batches.length,1);
    assert.equal(input.chat_batches[0].batch_id,'workflow:new');assert.equal(input.chat_batches[0].entries.length,2);
    return JSON.stringify({events:[{event_id:input.events[0].event_id,keywords:[],domains:['other'],entities:[],todo:{type:'',deadline:'',text:'',agent_task:''},
      chat:{subjects:[{kind:'self',name:''}],action_owners:[{kind:'self',name:''}],user_involved:true,status:'resolved',evidence_source_refs:[fresh.refs[1]]}}]});};
  model.enrichEvents=async(events,cfg,callbacks,batches)=>client.enrichEvents(events,cfg,callbacks,batches);
  const service=new IndexService(paths,storage,model);await service.build(config);
  let indexed=service.loadEvents()[Object.keys(service.loadEvents())[0]];
  assert.equal(indexed.source_refs.length,2);assert.equal(indexed.chat_context.complete,true);
  assert.deepEqual(clone(indexed.chat_context.batch_ids),['workflow:new']);assert.equal(indexed.chat_attribution.status,'resolved');
  assert.equal(indexed.todo.text,'');
  const forged={subjects:[{kind:'self',name:''}],action_owners:[{kind:'self',name:''}],user_involved:true,status:'pending',evidence_source_refs:[old.refs[0]]};
  assert.equal(chatContext.normalizeChatAttribution(forged,indexed,service.chatContexts.all()).status,'unknown');
  await service.build(config,undefined,service.changedSourceSelection(config,['2026-10/wechat.md.state.json'],[]));
  assert.equal(requests,1,'Warm source must keep the latest single-batch context and reuse its analysis');
});

test('analysis recovery: syntax repairs preserve quoted facts and reject ambiguous or truncated data',()=>{
  const {parseModelJsonObject}=load(base+'ModelJsonResponse');
  const samples=[
    ['```json\n{unquoted: \'中文事实\', values:[1,2,], flag:True, absent:None,}\n```',
      {unquoted:'中文事实',values:[1,2],flag:true,absent:null}],
    ['说明：{“text”：“保留‘原文’”， “ok”：false，}',{text:'保留‘原文’',ok:false}],
    ['{/* 注释 */ "text":"http://example.invalid/a,} // 字符串", "line":"上句\n下句",}',
      {text:'http://example.invalid/a,} // 字符串',line:'上句\n下句'}],
    ['{"path":"C:\\question\\file",}',{path:'C:\\question\file'}],
    ['<think>思考</think>\n{"quoted":"他说\\"你好\\""}',{quoted:'他说"你好"'}]
  ];
  for(const [source,want] of samples)assert.deepEqual(clone(parseModelJsonObject(source)),want);
  for(const source of ['{"a":1 2}','{"a":"未结束','{"events":[{"event_id":"a"}',
    '{"a":1}{"b":2}','[{"a":1}]','{"a":function(){}}','{"a":NaN}']) {
    assert.throws(()=>parseModelJsonObject(source),undefined,source);
  }
});

test('analysis recovery: two retry rounds isolate unfinished IDs and never resave valid siblings',async()=>{
  reset();const events=['first','second','third'].map(id=>event(id)),seen=new Map(),requests=[],saved=[],failed=[];
  cloudHandler=async options=>{
    const body=JSON.parse(options.messages[1].content),input=body.events;requests.push(input.map(e=>e.event_id));
    if(requests.length>1){assert.equal(body.previous_issues.length,1);assert.equal(body.previous_issues[0].event_id,input[0].event_id);
      assert.ok(['event_fields_missing','event_not_returned'].includes(body.previous_issues[0].error_code));}
    const items=[];for(const e of input){const n=(seen.get(e.event_id)||0)+1;seen.set(e.event_id,n);
      if(e.event_id==='third'&&n<3)continue;
      const item=outcomeItem(e);if(e.event_id==='second'&&n===1)delete item.domains;items.push(item);}
    return JSON.stringify({events:items});
  };
  const result=await new DataPipelineModelClient().enrichEvents(events,config,{onEvent:e=>saved.push(e.event_id),
    onFailure:(...args)=>failed.push(args)});
  assert.deepEqual(result.map(e=>e.event_id),['first','second','third']);
  assert.deepEqual(saved,['first','second','third']);assert.equal(failed.length,0);
  assert.deepEqual(requests,[['first','second','third'],['second'],['third'],['third']]);
  assert.deepEqual([...seen],[['first',1],['second',2],['third',3]]);
});

test('analysis recovery: complete streamed facts survive truncation and repaired JSON needs no model retry',async()=>{
  reset();const events=['saved','unfinished'].map(id=>event(id)),requests=[],saved=[];
  cloudHandler=async(options,stream)=>{
    const input=JSON.parse(options.messages[1].content).events;requests.push(input.map(e=>e.event_id));
    if(input.length===2){const content='{"events":['+JSON.stringify(outcomeItem(input[0]))+',';
      stream.onProgress({phase:'receiving',responseCode:200,receivedBytes:content.length,contentChars:content.length,
        reasoningChars:0,contentDelta:content,reasoningDelta:'',finishReason:''});
      return {content,finishReason:'length'};}
    return '{"events":['+JSON.stringify(outcomeItem(input[0])).replace('"keywords":[]','keywords:[]')+',],}';
  };
  const result=await new DataPipelineModelClient().enrichEvents(events,config,{onEvent:e=>saved.push(e.event_id),
    onFailure:()=>assert.fail('Both results should recover')});
  assert.equal(result.length,2);assert.deepEqual(saved,['saved','unfinished']);
  assert.deepEqual(requests,[['saved','unfinished'],['unfinished']]);
});

test('analysis recovery: exhausted event receipts carry attempt count and failure detail across restart',async()=>{
  reset();let calls=0;cloudHandler=async()=>{calls++;throw Error('Operation timed out');};
  const e=event('timeout'),service=new IndexService(paths,storage,new DataPipelineModelClient());
  assert.equal((await service.enrichWithCheckpoint([e],config)).length,0);assert.equal(calls,3);
  const file=[...disk.keys()].find(p=>p.endsWith('.failed.json')),failure=storage.readJson(file,{});
  assert.equal(failure.attempts,3);assert.equal(failure.policy,'event-analysis-v3');assert.equal(failure.code,'timeout');
  assert.match(failure.message,/超时/);
  await new IndexService(paths,storage,new DataPipelineModelClient()).enrichWithCheckpoint([e],config);
  assert.equal(calls,3,'Unchanged exhausted inputs must not start an unlimited retry loop');
  cloudHandler=async options=>{calls++;return JSON.stringify({events:JSON.parse(options.messages[1].content).events.map(outcomeItem)});};
  const changed={...e,normalized_fact:'新证据明确了具体事项'};
  assert.equal((await service.enrichWithCheckpoint([changed],config)).length,1);assert.equal(calls,4);
});

test('analysis recovery: cancellation, authorization and checkpoint errors never consume automatic retries',async()=>{
  for(const message of ['用户已取消同步','Cloud HTTP 401: unauthorized','保存事件检查点失败：disk full']){
    reset();let calls=0;cloudHandler=async()=>{calls++;throw Error(message);};
    await assert.rejects(new DataPipelineModelClient().enrichEvents([event('fatal')],config),new RegExp(message));
    assert.equal(calls,1);assert.equal([...disk.keys()].filter(p=>p.endsWith('.failed.json')).length,0);
  }
});

test('analysis recovery: explicit message speakers remain separate from recipients and matter subjects',()=>{
  const {chatPromptMessages}=load(base+'ChatMessageEvidence');
  const text='- 位置：右侧｜发送人：我｜聊天对象：小林｜时间：今天｜原文：我最近状态不好。\n'+
    '- 位置：左侧｜发送人：小林｜聊天对象：我｜时间：今天｜原文：我可以来看看你吗？\n'+
    '- 位置：右侧｜发送人：我｜聊天对象：小林｜时间：今天｜原文：他说"好的"\n'+
    "'- 位置：右侧｜发送人：我｜聊天对象：小林｜时间：今天｜原文：我回去休息',";
  const messages=chatPromptMessages(text);
  assert.equal(messages.length,4);assert.deepEqual(clone(messages[0].speaker),{kind:'self',name:''});
  assert.deepEqual(clone(messages[1].speaker),{kind:'other',name:'小林'});
  assert.equal(messages[0].recipient,'小林');assert.equal(messages[2].text,'他说"好的"');
  assert.equal(messages[3].text,'我回去休息');
});

test('analysis recovery: care, research and planning signals reach the planner without deadlines or GUI commands',async()=>{
  reset();const registry=new chatContext.ChatCollectionContextIndex();
  const ref='2026-11-03/wechat.md#1',raw='- 位置：右侧｜发送人：我｜聊天对象：小林｜原文：我这几天不舒服，想了解怎样安排作息。';
  registry.add('workflow:follow-up',ref,raw,[],1);
  const events=['care','research','plan'].map(type=>chatFixture(type,{event_date:'2026-11-03',source_refs:[ref],
    chat_context:registry.forRefs([ref]),normalized_fact:'用户表达了自己的状态和具体研究规划问题'}));
  cloudHandler=async options=>{
    const input=JSON.parse(options.messages[1].content);
    assert.equal(input.chat_batches[0].entries[0].text,raw,'The original capture is retained');
    assert.equal(input.chat_batches[0].entries[0].messages[0].speaker.kind,'self');
    assert.match(options.messages[0].content,/不是把发送人、收信人或会话名称抄进去/);
    return JSON.stringify({events:input.events.map(e=>({event_id:e.event_id,keywords:['近况'],domains:['other'],entities:[],
      todo:{type:e.event_id,deadline:'',time_text:'',text:'可以关注或探索具体事项',agent_task:'不应保留的GUI命令'},
      chat:{subjects:[{kind:'self',name:''}],action_owners:[{kind:'self',name:''}],user_involved:true,status:'pending',evidence_source_refs:[ref]}}))});
  };
  const indexed=await new DataPipelineModelClient().enrichEvents(events,config,undefined,registry.all());
  assert.deepEqual(indexed.map(e=>e.todo.type),['care','research','plan']);
  assert.ok(indexed.every(e=>!e.todo.deadline&&!e.todo.agent_task&&e.chat_attribution.subject==='self'));
  const {HomeRecommendationService}=load(base+'HomeRecommendationService');let received=[];
  const planner={async planHomeRecommendations(input){received=clone(input);return input.map(e=>({title:e.todo_type,tag:'',desc:e.todo_text,domain:'other',source_event_ids:[e.event_id]}));}};
  const service=new HomeRecommendationService(paths,storage,planner,{loadHomeTodoCandidateEvents:()=>Object.fromEntries(indexed.map(e=>[e.event_id,e]))});
  service.currentDateKey=()=> '2026-11-03';await service.build(config);
  assert.ok(received.every(e=>e.chat_attribution.subject==='self'));
  assert.deepEqual(service.loadDocument().recommendations.map(e=>e.tag).sort(),['值得关心','值得研究','可以规划'].sort());
  cloudHandler=async options=>{const input=JSON.parse(options.messages[1].content);
    assert.ok(input.events.every(e=>e.chat_attribution.subject==='self'));assert.match(options.messages[0].content,/建议不能写成必须执行/);
    return JSON.stringify({recommendations:input.events.map(e=>({title:e.todo_type,tag:'值得关注',desc:e.todo_text,domain:'other',source_event_ids:[e.event_id]}))});};
  await new DataPipelineModelClient().planHomeRecommendations(received,'2026-11-03',config);
});

test('analysis recovery: a same-day legacy recommendation cache cannot bypass the expanded planner policy',async()=>{
  reset();const {HomeRecommendationService}=load(base+'HomeRecommendationService');
  const service=new HomeRecommendationService(paths,storage,new Model(),new IndexService(paths,storage,new Model()));
  service.currentDateKey=()=> '2026-11-03';
  const document={generated_at:'2026-11-03T01:00:00',input_hash:'old',total_events:0,recommendations:[]};
  storage.writeJsonAtomic(paths.homeRecommendationsPath(),document);
  assert.equal(service.cachedBuildResult('2026-11-03'),null);
  storage.writeJsonAtomic(paths.homeRecommendationsPath(),{...document,policy:'home-follow-up-v2'});
  assert.equal(service.cachedBuildResult('2026-11-03').reused,true);
});

test('analysis recovery: incomplete planning cannot silently discard a collected concern or replace prior cards',async()=>{
  reset();let calls=0;const events=[{event_id:'care-1',date:'2026-11-03',todo_type:'care',todo_deadline:'',
    todo_text:'关注近况',summary:'状态变化',normalized_fact:'明确的状态变化',sources:[],domains:['other'],keywords:[],image_paths:[]}];
  cloudHandler=async()=>{calls++;return JSON.stringify({recommendations:[]});};
  await assert.rejects(new DataPipelineModelClient().planHomeRecommendations(events,'2026-11-03',config),/遗漏/);
  assert.equal(calls,3,'Planner envelope validation owns its existing bounded JSON retry budget');
  const {HomeRecommendationService}=load(base+'HomeRecommendationService');
  const e=event('care-1','2026-11-03',{todo:{type:'care',deadline:'',text:'关注近况',agent_task:''}});
  const service=new HomeRecommendationService(paths,storage,{planHomeRecommendations:async()=>{throw Error('model unavailable');}},
    {loadHomeTodoCandidateEvents:()=>({'care-1':e})});
  service.currentDateKey=()=> '2026-11-03';
  const previous={generated_at:'2026-11-03T01:00:00',input_hash:'previous',total_events:0,
    recommendations:[{id:'old',title:'已有卡片',completed:true,source_event_ids:['old-event']}]};
  storage.writeJsonAtomic(paths.homeRecommendationsPath(),previous);
  await assert.rejects(service.build(config),/unavailable/);
  assert.deepEqual(clone(service.loadDocument()),previous,'Last successful cards remain byte-for-byte data intact');
});

function readableChatEvent(id,name,topic,extra={}) {
  return event(id,'2026-11-03',{workflow_scene_ids:[3],sources:['微信',name],keywords:[topic],
    summary:'会话标题：'+name+'\n用户讨论'+topic,normalized_fact:'用户讨论'+topic,
    source_state_file:'outputs/2026-11/com.tencent.wechat__basic-gui-task__'+name+'.md.state.json',
    source_refs:['2026-11-03/com.tencent.wechat__basic-gui-task__'+name+'.md#'+id],...extra});
}
function readableGroup(id,title,events) {
  const {collectionGroupEventInputFingerprint}=load(base+'CollectionGroupingService');
  return {group_id:id,title,source:'微信',time:'2026-11-03',meta:'',status:'已整理',domain:'work',
    event_ids:events.map(e=>e.event_id),source_input_hash:'',
    event_input_hashes:Object.fromEntries(events.map(e=>[e.event_id,collectionGroupEventInputFingerprint(e)]))};
}
test('readable groups: conversation evidence wins over mentioned people and sentence fragments',()=>{
  const {collectionChatIdentity}=load(base+'CollectionChatIdentity');
  const group=readableChatEvent('group','产品 研发组（23）','接口设计',{entity_mentions:[{type:'person',name:'陈禾',aliases:[]}]});
  assert.equal(collectionChatIdentity(group).name,'产品 研发组');
  const byPath=readableChatEvent('path','林岚','聚餐安排',{summary:'用户与陈禾的聊天中讨论晚餐安排',normalized_fact:'',sources:['微信']});
  assert.equal(collectionChatIdentity(byPath).name,'林岚');
  const legacy=event('legacy','2026-11-03',{sources:['微信'],workflow_scene_ids:[3],keywords:[],
    summary:'用户与陈禾的聊天中讨论了关于晚餐安排',normalized_fact:''});
  assert.equal(collectionChatIdentity(legacy).name,'陈禾');
  const noConversation={...legacy,summary:'陈禾想了解旅游线路',entity_mentions:[{type:'person',name:'陈禾',aliases:[]}]};
  assert.equal(collectionChatIdentity(noConversation).known,false);
});
test('readable groups: nested titles repair locally and remain stable after repeated normalization',()=>{
  const {normalizeCollectionGroups}=load(base+'CollectionGroupingService');
  const a=readableChatEvent('a','林岚','聚餐安排'),b=readableChatEvent('b','陈禾','聚餐安排');
  let groups=normalizeCollectionGroups('chat','聊天记录',[a,b],[
    readableGroup('old-a','陈禾的聊天中-旧联系人-聚餐安排',[a]),readableGroup('old-b','聚餐安排',[b])]);
  assert.deepEqual(clone(groups.map(g=>g.title).sort()),['林岚 · 聚餐安排','陈禾 · 聚餐安排'].sort());
  const initial=clone(groups);
  for(let i=0;i<3;i++)groups=normalizeCollectionGroups('chat','聊天记录',[a,b],groups);
  assert.deepEqual(clone(groups),initial);assert.ok(groups.every(g=>g.title_topic==='聚餐安排'));
  const legacy=event('legacy','2026-11-03',{workflow_scene_ids:[3],sources:['微信'],keywords:[],
    normalized_fact:'',summary:'用户与陈禾的聊天中讨论了关于晚餐安排'});
  const fixed=normalizeCollectionGroups('chat','聊天记录',[legacy],[readableGroup('bad','陈禾的聊天中-旧联系人-话题',[legacy])]);
  assert.equal(fixed[0].title,'陈禾 · 晚餐安排');
});
test('readable groups: anonymous and mixed conversations never merge by a shared display label',()=>{
  const {normalizeCollectionGroups,prepareIncrementalCollectionGroups}=load(base+'CollectionGroupingService');
  const anonymous=(id,batch)=>readableChatEvent(id,'私聊联系人（姓名未显示）','聚餐安排',{
    summary:'用户讨论聚餐安排',normalized_fact:'用户讨论聚餐安排',
    chat_context:{policy:'fixture',batch_ids:[batch],complete:true}});
  const a=anonymous('a','batch-a'),b=anonymous('b','batch-a');
  const known=readableChatEvent('known','林岚','接口设计');
  const input=[a,b,known];const old=readableGroup('mixed','姓名未显示-历史拼接标题',input);
  const result=prepareIncrementalCollectionGroups('chat','聊天记录',input,[old]);
  assert.equal(result.pendingEvents.length,0);assert.equal(result.reusedGroups.length,3);
  assert.equal(result.reusedGroups.filter(g=>g.group_id==='mixed').length,1);
  const groups=normalizeCollectionGroups('chat','聊天记录',input,result.reusedGroups);
  assert.equal(groups.length,3);assert.deepEqual(clone(groups.flatMap(g=>g.event_ids).sort()),['a','b','known']);
  assert.equal(new Set(groups.map(g=>g.conversation_key)).size,3);
});
test('readable groups: display truncation cannot combine different full topics',()=>{
  const {normalizeCollectionGroups}=load(base+'CollectionGroupingService');
  const prefix='下一代端侧智能体框架的工具调用与数据管理';
  const a=readableChatEvent('a','林岚',prefix+'协议'),b=readableChatEvent('b','林岚',prefix+'性能');
  const groups=normalizeCollectionGroups('chat','聊天记录',[a,b],[readableGroup('a',a.keywords[0],[a]),readableGroup('b',b.keywords[0],[b])]);
  assert.equal(groups.length,2);assert.equal(new Set(groups.map(g=>g.title_topic)).size,2);
  assert.ok(groups.every(g=>g.title.includes('…')));
});
test('readable groups: migration retains old membership and only assigns genuinely new or edited events',async()=>{
  const {prepareIncrementalCollectionGroups,applyIncrementalCollectionGroupAssignments}=load(base+'CollectionGroupingService');
  const a=readableChatEvent('a','林岚','聚餐安排'),b=readableChatEvent('b','林岚','人数确认');
  const legacy=readableGroup('stable-id','林岚-聚餐安排',[a]);legacy.event_input_hashes={};
  const plan=prepareIncrementalCollectionGroups('chat','聊天记录',[a,b],[legacy],true);
  assert.deepEqual(clone(plan.pendingEvents.map(e=>e.event_id)),['b']);
  const joined=applyIncrementalCollectionGroupAssignments('chat','聊天记录',[a,b],plan.reusedGroups,plan.pendingEvents,
    [{event_id:'b',group_id:'stable-id',title:'不应改名',source:'微信',domain:'work'}]);
  assert.equal(joined.length,1);assert.equal(joined[0].group_id,'stable-id');assert.equal(joined[0].title,'林岚 · 聚餐安排');
  assert.equal(joined[0].event_ids.length,2);
  const edited={...a,keywords:['行程变更']};
  assert.deepEqual(clone(prepareIncrementalCollectionGroups('chat','聊天记录',[edited],[readableGroup('receipt','聚餐安排',[a])],true)
    .pendingEvents.map(e=>e.event_id)),['a']);
  const other=readableChatEvent('other','陈禾','聚餐安排');
  const rejected=applyIncrementalCollectionGroupAssignments('chat','聊天记录',[a,other],plan.reusedGroups,[other],
    [{event_id:'other',group_id:'stable-id',title:'聚餐安排',source:'微信',domain:'work'}]);
  assert.equal(rejected.length,2);
  const client=new DataPipelineModelClient();let requests=0;
  cloudHandler=async options=>{requests++;const data=JSON.parse(options.messages[1].content);
    assert.deepEqual(data.events[0].candidate_group_ids,[]);assert.equal(data.existing_groups.length,0);
    return JSON.stringify({assignments:[{event_id:'other',group_id:'new:1',title:'聚餐安排',source:'微信',domain:'work'}]});};
  await client.assignCollectionGroupEvents('chat','聊天记录',[other],plan.reusedGroups,{a,other},config);assert.equal(requests,1);
});
test('readable groups: legacy repair saves once without a model call and future fast paths reuse it',async()=>{
  reset();const {CollectionGroupingService}=load(base+'CollectionGroupingService');
  const a=readableChatEvent('a','林岚','聚餐安排');const old=readableGroup('old-id','陈禾的聊天中-旧联系人-聚餐安排',[a]);
  old.event_input_hashes={};storage.writeJsonAtomic(paths.collectionGroupsPath('chat'),{tab_id:'chat',input_hash:'legacy',groups:[old]});
  const model={planCollectionGroups:async()=>{throw Error('migration must not call planner');},
    assignCollectionGroupEvents:async()=>{throw Error('migration must not reassign old events');}};
  const service=new CollectionGroupingService(paths,storage,model,{query:q=>({events:q.workflowSceneIds[0]===3?[a]:[]})});
  assert.equal(service.cachedBuildResult(1,1),null);await service.buildAll(config);
  const saved=storage.readJson(paths.collectionGroupsPath('chat'),null);
  assert.equal(saved.groups[0].title,'林岚 · 聚餐安排');assert.equal(saved.groups[0].group_id,'old-id');
  const oldWrites=writes.length;const second=await service.buildAll(config);
  assert.equal(second.updatedGroupDocs,0);assert.equal(second.reusedGroupDocs,12);
  assert.ok(writes.slice(oldWrites).every(p=>p.endsWith('/policy.json')));
  assert.equal(service.cachedBuildResult(1,1).updatedGroupDocs,0);
});

test('people: atomic edits stay outside history, preserve other people and reject stale editors',()=>{
  reset();const {PersonMemoryStore}=load(base+'PersonMemoryStore'),store=new PersonMemoryStore('/app',storage);
  assert.deepEqual(clone(store.people().map(p=>p.label)),['本人','父亲','母亲','伴侣']);assert.equal(store.hasFacts(),false);
  const self=store.save('person:self',{name:'林清',wechat_name:'清清'},0);
  assert.equal(self.revision,1);assert(store.hasFacts());const count=writes.length;
  assert.equal(store.save('person:self',{name:' 林清 ',wechat_name:'清清'},1).revision,1);assert.equal(writes.length,count);
  store.save('person:father',{name:'林远'},0);store.save('person:mother',{name:'陈禾'},0);
  assert.equal(store.people().find(p=>p.id==='person:father').values.name,'林远');
  assert.throws(()=>store.save('person:self',{name:'stale'},0),/其他页面更新/);
  assert.equal(store.people().find(p=>p.id==='person:self').values.name,'林清');
  assert(writes.every(p=>p==='/app/people-memory/subjects.json'));
  failWrite=p=>p.includes('people-memory');assert.throws(()=>store.save('person:self',{name:'failed'},1),/injected/);
  assert.equal(store.people().find(p=>p.id==='person:self').values.name,'林清');
});
test('people: editing and clearing a field replaces its stable fact without stale copies or birth-date timestamps',()=>{
  reset();const {PersonMemoryStore}=load(base+'PersonMemoryStore'),store=new PersonMemoryStore('/app',storage);
  const p=store.save('person:self',{name:'林清',birth_date:'1990-02-03',home_address:'旧地址'},0);
  let current=store.events(),address=current.find(e=>e.fact_source.field==='home_address');const id=address.event_id;
  assert.notEqual(current.find(e=>e.fact_source.field==='birth_date').event_date,'1990-02-03');
  const next=store.save(p.id,{name:'林清',birth_date:'1990-02-03',home_address:'新地址'},p.revision);
  current=store.events();assert.equal(current.filter(e=>e.event_id===id).length,1);assert.match(current.find(e=>e.event_id===id).summary,/新地址/);
  store.save(p.id,{name:'林清',birth_date:'1990-02-03'},next.revision);
  assert(!store.events().some(e=>e.event_id===id));
  const {normalizedPersonValues}=load(base+'PersonMemory');
  for(const date of ['2023-02-29','2000-13-01','2999-01-01','2024-2-3'])assert.throws(()=>normalizedPersonValues({birth_date:date},'2026-11-05'));
  assert.equal(normalizedPersonValues({birth_date:'2000-02-29'},'2026-11-05').birth_date,'2000-02-29');
});
test('people: exact and bounded index queries expose subject-scoped current facts without rebuilding history',()=>{
  reset();const {PersonMemoryStore}=load(base+'PersonMemoryStore'),store=new PersonMemoryStore('/app',storage),index=new IndexService(paths,storage,new Model());
  store.save('person:self',{name:'林清',company:'本人单位'},0);store.save('person:father',{name:'林清',company:'父亲单位'},0);
  const old={historical:event('historical','2025-02-01',{summary:'一次工作记录',normalized_fact:'一次工作记录'})};
  index.writeEventPartitions(old);index.writeTemporalDocuments(old);
  const q={keywords:['工作单位'],keywordOperator:'or',domains:[],entities:[],date:'',month:'',startDate:'',endDate:'',workflowSceneIds:[],limit:20,subjectIds:['person:father']};
  reads.clear();const writeCount=writes.length;
  for(const result of [index.query(q),index.queryBounded(q)]){
    assert.equal(result.events.length,1);const fact=result.events[0];assert.match(fact.summary,/父亲单位/);
    assert.equal(fact.subjects[0].id,'person:father');assert.equal(fact.subjects[0].is_self,false);assert.equal(fact.fact_source.authority,'user_confirmed');
    assert.equal(fact.profile_domains.length,0);assert.equal(fact.todo.text,'');
  }
  assert.equal(writes.length,writeCount);assert.deepEqual(Object.keys(index.loadEvents()),['historical']);
  const all={...q,keywords:[],subjectIds:[]};assert.equal(index.query(all,false).events.length,1);
  const dad=store.events().find(e=>e.subjects[0].id==='person:father');reads.clear();
  assert.equal(Object.keys(index.loadEventsByIds([dad.event_id])).length,1);
  assert([...reads.keys()].every(p=>p.includes('people-memory')),'manual hydration must not read historical partitions');
  assert(index.query({...q,subjectIds:['person:partner']}).events.length===0,'unconfigured person cannot inherit another person’s facts');
});
test('people: queries preserve family identity, domain/entity filters and legacy unowned events',()=>{
  reset();const {PersonMemoryStore}=load(base+'PersonMemoryStore'),store=new PersonMemoryStore('/app',storage);
  store.save('person:mother',{name:'陈禾',wechat_name:'小禾',company:'大学',home_address:'南京'},0);
  const {queryPersonFacts,eventMatchesSubjects,mergePersonFactResults}=load(base+'PersonMemory');
  const q={keywords:['单位','公司'],keywordOperator:'or',domains:['work'],entities:['person:小禾'],date:'',month:'',startDate:'',endDate:'',workflowSceneIds:[],limit:2};
  assert.equal(queryPersonFacts(store.events(),q).length,1);
  assert.equal(queryPersonFacts(store.events(),{...q,domains:['live']}).length,0);
  assert.equal(queryPersonFacts(store.events(),{...q,subjectIds:['person:self']}).length,0);
  const legacy=event('legacy');assert(eventMatchesSubjects(legacy));assert(!eventMatchesSubjects(legacy,['person:self']));
  const unchanged={events:[legacy],total_events:1,events_truncated:false};assert.equal(mergePersonFactResults(unchanged,[],20),unchanged);
  const merged=mergePersonFactResults(unchanged,store.events(),1);assert.equal(merged.events.length,1);assert(merged.events_truncated);assert.equal(merged.total_events,5);
});
test('people: normal tool schema and semantic options retain subject IDs and confirmed attribution',()=>{
  reset();const tools=load(base+'DataManagerQueryEventsTool'),parsed=tools.normalizeQueryEventsToolArguments('{"keywords":["工作单位"],"subject_ids":["person:father"]}');
  assert(parsed.ok);assert.deepEqual(clone(parsed.options.subjectIds),['person:father']);
  assert(!tools.normalizeQueryEventsToolArguments('{"subject_ids":["bad/path"]}').ok);
  assert(!Object.hasOwn(tools.normalizeQueryEventsToolArguments('{}').options,'subjectIds'));
  const schema=tools.queryEventsToolParameters();assert(schema.properties.subject_ids);
  const {PersonMemoryStore}=load(base+'PersonMemoryStore'),store=new PersonMemoryStore('/app',storage);
  store.save('person:father',{name:'林远',company:'研究所'},0);
  const {memoryEventText}=load(base+'MemorySemanticSearch');const text=memoryEventText(store.events()[0]);
  assert.match(text,/person:father/);assert.match(text,/用户手填确认/);assert.match(text,/林远/);
});
test('people: first summary tab uses a stable scene ID and form routes remain native and dark-mode aware',()=>{
  const scenes=load('entry/src/main/ets/utils/WorkflowSceneConfig'),groups=load(base+'CollectionGroupingService');
  assert.equal(scenes.memorySceneConfigs()[0].sceneId,12);assert.equal(scenes.workflowSceneConfigs()[0].sceneId,0);
  assert.equal(groups.collectionTabSpecByIndex(0).tabId,'shopping');assert.equal(groups.collectionTabSpecByIndex(12).tabId,'personal-info');
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/collection/PersonInfoPage.ets'),'utf8');
  assert.match(source,/onBackPress\(\)/);assert.match(source,/PERSON_MEMORY_REVISION_KEY/);assert.match(source,/CollectionFormInput/);assert.match(source,/AppTheme\.text/);
  const routes=JSON.parse(fs.readFileSync(path.join(root,'entry/src/main/resources/base/profile/main_pages.json'),'utf8'));
  assert(routes.src.includes('pages/collection/PersonInfoPage'));
});
test('people: form fields are UI builder content, not a regular callback; every tab retains the shared sync overview',()=>{
  let directory=path.dirname(require.resolve(process.argv[2]||'typescript')),ets;
  for(let i=0;i<6&&!ets;i++,directory=path.dirname(directory)){
    const config=path.join(directory,'tsconfig.json');
    if(fs.existsSync(config))ets=ts.parseConfigFileTextToJson(config,fs.readFileSync(config,'utf8')).config?.compilerOptions?.ets;
  }
  assert(ets,'This check requires the DevEco ArkTS parser configuration');
  const parse=relative=>{const file=path.join(root,relative),source=ts.createSourceFile(file,fs.readFileSync(file,'utf8'),ts.ScriptTarget.ES2021,true,ts.ScriptKind.ETS,{ets});assert.equal(source.parseDiagnostics.length,0);return source;};
  const find=(root,predicate)=>{const found=[];function visit(node){if(predicate(node))found.push(node);ts.forEachChild(node,visit);}visit(root);return found;};
  const page=parse('entry/src/main/ets/pages/collection/PersonInfoPage.ets');
  const containers=find(page,n=>ts.SyntaxKind[n.kind]==='EtsComponentExpression'&&n.expression.getText(page)==='CollectionFormGroup');
  assert.equal(containers.length,1);assert(containers[0].body,'Form content must be a compiled trailing builder, not an ordinary arrow callback');
  assert(find(containers[0].body,n=>ts.isCallExpression(n)&&n.expression.getText(page)==='ForEach').length>0);
  assert(find(containers[0].body,n=>ts.isCallExpression(n)&&n.expression.getText(page)==='CollectionFormInput').length>0);
  const groups=find(page,n=>ts.isCallExpression(n)&&n.expression.getText(page)==='this.FieldGroup').map(n=>n.arguments[0].text);
  assert.deepEqual(groups,[...new Set(load(base+'PersonMemory').PERSON_FIELDS.map(f=>f.group))]);
  const collection=parse('entry/src/main/ets/pages/collection/CollectionPage.ets');
  const overview=find(collection,n=>ts.isCallExpression(n)&&n.expression.getText(collection)==='this.CollectionOverview');
  assert.equal(overview.length,1);for(let parent=overview[0].parent;parent&&!ts.isMethodDeclaration(parent);parent=parent.parent)assert(!ts.isIfStatement(parent),'Overview/sync must be available in the personal tab too');
});
test('people: editing starts immediately, saves only the selected person and keeps failed saves on screen',()=>{
  reset();const {PersonMemoryStore}=load(base+'PersonMemoryStore'),{samePersonValues}=load(base+'PersonMemory');
  const file=path.join(root,'entry/src/main/ets/pages/collection/PersonInfoPage.ets'),source=fs.readFileSync(file,'utf8');
  const names=['aboutToAppear','copyValues','edit','goBack','onBackPress','save'],methods=[];
  // Only execute the production state handlers. UI rendering is checked separately above.
  for(const name of names){const declaration=new RegExp('^\\s*(?:private )?'+name+'\\(','m').exec(source);assert(declaration);const start=declaration.index;
    const body=source.indexOf('{',source.indexOf('):',start));let depth=1,end=body+1;
    while(depth&&end<source.length){if(source[end]==='{')depth++;else if(source[end]==='}')depth--;end++;}
    methods.push(source.slice(start,end));}
  const output=ts.transpileModule('class EditorProbe {'+methods.join('\n')+'}\nexports.EditorProbe=EditorProbe;',
    {compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}});
  const exported={},backs=[],dialogs=[],notifications=[],changes=[];
  vm.runInNewContext(output.outputText,{exports:exported,PersonMemoryStore,samePersonValues,personSlot:load(base+'PersonMemory').personSlot,
    PERSON_MEMORY_REVISION_KEY:'personMemoryRevision',router:{getParams:()=>({personId:'person:father'}),back:()=>backs.push(true)},
    AlertDialog:{show:options=>dialogs.push(options)},AppStorage:{setOrCreate:(key,value)=>changes.push([key,value])},Date});
  const editor=new exported.EditorProbe();Object.assign(editor,{values:{},ready:false,dirty:false,error:'',getUIContext:()=>({getHostContext:()=>({filesDir:'/app'}),getPromptAction:()=>({showToast:options=>notifications.push(options)})})});
  editor.aboutToAppear();assert(editor.ready);assert.equal(editor.person.id,'person:father');
  editor.edit({key:'name'},'林远');assert(editor.dirty);assert.equal(new PersonMemoryStore('/app',storage).hasFacts(),false);
  assert.equal(editor.onBackPress(),true);assert.equal(dialogs.length,1);assert.equal(backs.length,0);dialogs[0].primaryButton.action();assert(editor.dirty);
  editor.save();assert.equal(backs.length,1);assert.equal(notifications.length,1);assert.equal(changes.length,1);assert.equal(editor.dirty,false);
  assert.equal(new PersonMemoryStore('/app',storage).people().find(p=>p.id==='person:father').values.name,'林远');
  assert.deepEqual(clone(new PersonMemoryStore('/app',storage).people().find(p=>p.id==='person:self').values),{});
  editor.edit({key:'home_address'},'新地址');failWrite=p=>p.includes('people-memory');editor.save();assert(editor.dirty);assert.match(editor.error,/injected/);assert.equal(backs.length,1);
  assert(!new PersonMemoryStore('/app',storage).people().find(p=>p.id==='person:father').values.home_address);
});
test('people: query tool keeps subject metadata in bounded valid JSON for long multi-person results',async()=>{
  reset();const {PersonMemoryStore}=load(base+'PersonMemoryStore'),store=new PersonMemoryStore('/app',storage);
  for(const person of ['person:self','person:father','person:mother','person:partner'])store.save(person,{name:'同名测试',notes:'补充资料'.repeat(180),home_address:'详细地址'.repeat(60)},0);
  const events=store.events(),{createQueryEventsTool}=load(base+'DataManagerQueryEventsTool');
  const tool=createQueryEventsTool(()=>true,()=>({events,total_events:events.length,events_truncated:false}));
  const text=await tool.execute('{}',{filesDir:'/app',sessionId:'test',userMessage:'查询'}),result=JSON.parse(text);
  assert(text.length<=3500);assert(result.truncated);assert(result.events.length>0);
  assert(result.events.every(event=>event.subjects.length===1&&event.fact_source.authority==='user_confirmed'));
});

(async()=>{const selected=cases.filter(([name])=>!process.env.SYNC_TEST_FILTER||name.includes(process.env.SYNC_TEST_FILTER));for(const[name,run]of selected){await run();console.log('PASS '+name);}console.log(selected.length+' incremental sync checks passed');})()
  .catch(error=>{console.error(error.stack);process.exitCode=1;});
