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
  const output=ts.transpileModule(fs.readFileSync(file,'utf8'),{fileName:file.replace(/\.ets$/,'.ts'),reportDiagnostics:true,
    compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}});
  assert.equal((output.diagnostics||[]).filter(d=>d.category===ts.DiagnosticCategory.Error).length,0,file);
  const exports={}; loaded.set(file,exports);
  vm.runInNewContext(output.outputText,{exports,console,Date,setTimeout,clearTimeout,require:id=>{
    if(id==='@kit.ArkTS') return {JSON};
    if(id==='@ohos.file.fs')return {default:{accessSync:p=>storage.exists(p)||storage.isDirectory(p),listFileSync:p=>storage.listDir(p)}};
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
  const actual=['datamanager/ProfileBlockCache','datamanager/IndexWriteBatch','datamanager/SyncMetrics','datamanager/MemoryChangeJournal',
    'datamanager/DataManagerStorage','datamanager/DataManagerTypes','datamanager/DataManagerPaths','datamanager/IndexService',
    'datamanager/DataPipelineModelClient','datamanager/ModelStreamActivity','datamanager/EventStreamParser','datamanager/DataManagerUtils','datamanager/ChatMemoryExtraction','datamanager/ConsolidationService',
    'datamanager/DataManagerFacade','datamanager/CollectionGroupingService','datamanager/HomeRecommendationService',
    'datamanager/DataManagerImageResolver','datamanager/ChatMemorySync','datamanager/DataManagerSyncReminder',
    'utils/ChatSessionStorage','pages/chat/ChatSessionTypes','pages/chat/ChatPageTypes','pages/chat/VoiceInteractionTypes',
    'utils/gallery/GalleryMemorySync','utils/gallery/GalleryTypes','utils/gallery/GalleryExifUtils',
    'utils/calendar/CalendarMemoryStore','utils/calendar/CalendarMemoryPolicy','utils/mail/MailStore','utils/mail/MailReminderPolicy',
    'datamanager/avatar/AvatarTypes','utils/WorkflowSceneConfig','utils/JsonCompat','utils/DateUtils',
    'utils/StartupSourceSync','utils/mail/MailTypes'];
  for(const name of actual)sources.set(path.join(etsRoot,name+'.ts'),fs.readFileSync(path.join(etsRoot,name+'.ets'),'utf8'));
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
  sources.set(path.join(root,'.codex-tmp/sync-kits.d.ts'),"declare module '@kit.ArkTS' { export const JSON:typeof globalThis.JSON; } declare module '@kit.CryptoArchitectureKit' { export namespace cryptoFramework { interface DataBlob { data:Uint8Array; } function createMd(name:string):any; } } declare module '@ohos.file.fs' { const fs:any; export default fs; }");
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
    storage.removeFile(changed);await facade.refreshInternal(cfg);assert.ok(!Object.keys(facade.indexService.loadEvents()).some(id=>id.includes('task-3.md')));
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
  let release;const gate=new Promise(resolve=>release=resolve),progress=[];
  const analyze=model.enrichEvents.bind(model);
  model.enrichEvents=async events=>{if(events.length)await gate;return analyze(events);};
  const build=service.build(config,value=>progress.push(value));await new Promise(resolve=>setImmediate(resolve));
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
    const item=reviewEnrichment(options).events[0],partial='{"events":['+JSON.stringify(item)+',';
    stream.onProgress({phase:'receiving',responseCode:200,receivedBytes:partial.length,contentChars:partial.length,
      reasoningChars:0,contentDelta:partial,reasoningDelta:'',finishReason:''});
    assert.ok([...disk.keys()].some(p=>p.includes('/sync-cache/events/')&&!p.endsWith('.failed.json')));
    throw Error('Operation timed out');
  };
  const service=new IndexService(paths,storage,model),result=await service.build(config);
  assert.equal(Object.keys(service.loadEvents()).length,1);assert.equal(result.failedEventCount,1);
  assert.equal([...disk.keys()].filter(p=>p.endsWith('.failed.json')).length,1);
  const unchanged=await new IndexService(paths,storage,model).build(config);assert.equal(requests,1);
  assert.equal(unchanged.failedEventCount,0,'Untouched historical failures are not counted as current skips');
  assert.equal(service.completion().failed_event_count,1,'The persisted historical total is retained');
  const facade=Object.create(DataManagerFacade.prototype);facade.indexService=service;
  assert.equal(facade.skippedRefreshSummary({entry_count:0,consolidated_record_count:0,generated_at:''}).failedEventCount,0);
  assert.equal(real.modelActivities()[0].phase,'failed');
  const next=new DataPipelineModelClient(),nextModel=new Model();nextModel.enrichEvents=next.enrichEvents.bind(next);
  storage.writeJsonAtomic(file,{metadata:{},records:[reviewRecord(1),reviewRecord(2,'工作会议修改后的新内容')]});
  cloudHandler=async options=>{requests++;assert.equal(JSON.parse(options.messages[1].content).events.length,1);return JSON.stringify(reviewEnrichment(options));};
  const repaired=await new IndexService(paths,storage,nextModel).build(config);assert.equal(repaired.failedEventCount,0);assert.equal(requests,2);
});

test('stream: repeated output aborts only its event batch, keeps success and persists failure with Debug off',async()=>{
  reset();assert.equal(debugForTest,false);
  const real=new DataPipelineModelClient(),model=new Model();model.enrichEvents=real.enrichEvents.bind(real);
  const file=paths.outputStatePath('2026-10','com.tencent.wechat.md');
  storage.writeJsonAtomic(file,{metadata:{},records:[reviewRecord(1),reviewRecord(2)]});let requests=0,reachedTail=false;
  cloudHandler=async(options,stream)=>{
    requests++;const item=reviewEnrichment(options).events[0],partial='{"events":['+JSON.stringify(item)+',';
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
  await new IndexService(paths,storage,model).build(config);assert.equal(requests,1);
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

(async()=>{const selected=cases.filter(([name])=>!process.env.SYNC_TEST_FILTER||name.includes(process.env.SYNC_TEST_FILTER));for(const[name,run]of selected){await run();console.log('PASS '+name);}console.log(selected.length+' incremental sync checks passed');})()
  .catch(error=>{console.error(error.stack);process.exitCode=1;});
