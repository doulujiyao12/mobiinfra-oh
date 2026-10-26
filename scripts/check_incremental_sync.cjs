// Production business-logic simulation. No HAP build, account, device or network.
// node scripts/check_incremental_sync.cjs <typescript-module-path>
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..'), base = 'entry/src/main/ets/datamanager/';
const disk = new Map(), directories = new Set(), reads = new Map(), writes = [];
const logs = []; let failWrite = null, cloudHandler = null, calendarEvents = [];
const clone = value => JSON.parse(JSON.stringify(value));
class Storage {
  join(...parts) { return parts.filter(Boolean).join('/').replace(/\/+/g,'/'); }
  dirname(file) { return path.posix.dirname(file); } basename(file) { return path.posix.basename(file); }
  exists(file) { return disk.has(file) || directories.has(file); }
  isDirectory(file) { return directories.has(file) || [...disk.keys()].some(key=>key.startsWith(file+'/')); }
  ensureDir(file) { directories.add(file); }
  readText(file, fallback='') { reads.set(file,(reads.get(file)||0)+1); return disk.get(file) ?? fallback; }
  readJson(file, fallback) { try { return JSON.parse(this.readText(file)); } catch { return clone(fallback); } }
  writeTextAtomic(file, text) { if(failWrite?.(file,text)) throw Error('injected write failure'); disk.set(file,text); writes.push(file); }
  writeJsonAtomic(file, value) { this.writeTextAtomic(file,JSON.stringify(value,null,2)+'\n'); }
  removeFile(file) { disk.delete(file); }
  sha256Text(text) { return crypto.createHash('sha256').update(text).digest('hex'); }
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
  'CalendarMemoryStore.ets': {CalendarMemoryStore:class {events(){return clone(calendarEvents);} fingerprint(){return JSON.stringify(calendarEvents);} indexFingerprint(){return this.fingerprint();}}},
  'DataManagerImageResolver.ets': {DataManagerImageResolver:class {}},
  'AvatarService.ets': {AvatarService:class {}},
  'GalleryMemorySync.ets': {GalleryMemorySync:{imageRefsForSourceRefs:()=>[],dailyLogRelativePaths:()=>[]}},
  'ChatMemorySync.ets': {ChatMemorySync:{dailyLogRelativePaths:()=>[]}},
  'CloudModelClient.ets': {CloudModelClient:class {async chatCompletionText(options){return cloudHandler(options);}}}
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
function reset(){disk.clear();directories.clear();reads.clear();writes.length=0;logs.length=0;failWrite=null;calendarEvents=[];}
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
  for(const [file,text] of disk){const receipt=JSON.parse(text);receipt.payload.summary='corrupted';disk.set(file,JSON.stringify(receipt));}
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
  const facade=Object.create(DataManagerFacade.prototype);facade.hasGeneratedDataForSnapshot=()=>true;
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
  const actual=['datamanager/ProfileBlockCache','datamanager/IndexWriteBatch','datamanager/SyncMetrics',
    'datamanager/DataManagerStorage','datamanager/DataManagerTypes','datamanager/DataManagerPaths','datamanager/IndexService',
    'datamanager/DataPipelineModelClient','datamanager/DataManagerUtils','datamanager/ChatMemoryExtraction','datamanager/ConsolidationService',
    'datamanager/avatar/AvatarTypes','utils/WorkflowSceneConfig','utils/JsonCompat','utils/DateUtils',
    'utils/StartupSourceSync','utils/mail/MailTypes'];
  for(const name of actual)sources.set(path.join(etsRoot,name+'.ts'),fs.readFileSync(path.join(etsRoot,name+'.ets'),'utf8'));
  const stubs={
    'datamanager/DataManagerLog': 'export declare function dataManagerInfo(s:string):void;export declare function dataManagerWarn(s:string):void;export declare function dataManagerError(s:string):void;',
    'utils/TextEncodingCompat':'export declare function decodeUtf8Compat(b:Uint8Array):string;export declare function encodeUtf8Compat(s:string):Uint8Array;',
    'utils/CloudModelClient':'export interface CloudChatMessage { role:string; content:string; } export declare class CloudModelClient { chatCompletionText(options:Object):Promise<string>; }',
    'utils/calendar/CalendarMemoryStore':"export declare class CalendarMemoryStore { constructor(dir:string); events():import('../../datamanager/DataManagerTypes').IndexedEvent[]; fingerprint():string; }",
    'utils/gallery/GalleryMemorySync': 'export declare class GalleryMemorySync { static imageRefsForSourceRefs(a:string,b:string,c:string[]):string[]; static dailyLogRelativePaths(dir:string):string[]; }',
    'datamanager/ChatMemorySync':"export declare class ChatMemorySync { static dailyLogRelativePaths(dir:string,storage:import('./DataManagerStorage').DataManagerStorage):string[]; }"
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
  calendarFailure=false;await scheduler.run(selection,actions,now+600001);assert.deepEqual(calls,['mail','calendar','chat','calendar']);
  assert.equal(scheduler.hasDue(selection,now+12*3600000),false);
  await scheduler.run(selection,actions,now+86400000);assert.equal(calls.length,7);
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
  assert.equal(rejected.state.calendarDialogs,0);assert.equal(rejected.state.reminderDialogs,0);assert.equal(rejected.state.dailySyncs,0);
  const unselected=scenario(true,1,true,true);unselected.state.accepted=false;unselected.state.privacyChoice='unselected';
  let privacyRequests=0;const firstPage=unselected.probe();firstPage.ensurePrivacyConsent=async()=>{
    privacyRequests++;unselected.state.privacyChoice='rejected';return false;};
  await firstPage.runStartupServices();await unselected.probe().runStartupServices();
  assert.equal(privacyRequests,0);assert.equal(unselected.state.privacyChoice,'unselected');
  assert.equal(unselected.state.calendarDialogs,0);assert.equal(unselected.state.dailySyncs,0);
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
    'startStartupProgressTimer','stopStartupProgressTimer'].map(name=>component.members.find(node=>ts.isMethodDeclaration(node)&&node.name.getText(tree)===name).getText(tree)).join('\n');
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
  const page=new exported.Probe();page.filesDir='/app';page.pageVisible=true;page.dataManagerRefreshing=false;
  page.startupProgressTimerId=-1;page.startupSourceSyncEnabled=true;const progressValues=[];
  page.dataManagerFacade={refreshAutomaticSources:async(_config,chat,calendar,progress)=>{
    calls.push({chat,calendar});assert.equal(typeof progress,'function');
    progress({stage:'生成画像',message:'fixture model work',current:2,total:3,percent:90});progressValues.push(page.dataManagerProgressPercent);}};
  page.getDataManagerModelConfig=()=>config;page.reloadDataManagerViewModels=()=>{};
  await page.syncDailyStartupSources();assert.deepEqual(calls,[{chat:true,calendar:false}]);
  assert.equal(counters.providerReads,0);assert.equal(counters.mailReads,0);assert.equal(page.dataManagerSyncFailed,false);
  assert.equal(page.startupSourceSyncRunning,false);page.disableDailyStartupSync();
  assert.ok(progressValues[0]>0&&progressValues[0]<100);assert.equal(page.startupProgressTimerId,-1);
  assert.equal(values.startupSourceSyncEnabled,false);assert.equal(new StartupSourceSync('/app').isEnabled(),false);
  const before={...counters};await page.syncDailyStartupSources();assert.deepEqual(counters,before);
  const settings=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/settings/SettingsCenterPage.ets'),'utf8');
  assert.ok(settings.includes('@StorageLink(STARTUP_SOURCE_SYNC_ENABLED_KEY)'));assert.ok(settings.includes("label: '每日自动更新'"));
  reset();calls.length=0;calendarAllowed=true;mailConfigured=true;
  await page.syncDailyStartupSources();assert.deepEqual(calls,[{chat:true,calendar:true}],'One memory rebuild combines calendar and chat');
  assert.equal(counters.providerReads,1);assert.equal(counters.mailReads,1);
  assert.equal(page.startupSourceTotal,3);assert.equal(page.startupSourceCompleted,3);assert.equal(page.dataManagerProgressPercent,100);
  assert.equal(page.startupProgressTimerId,-1);
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
  facade.paths=paths;facade.storage={beginReadSession(){begins++;},endReadSession(){ends++;}};facade.ensureReady=()=>{};
  facade.modelClient={resetSyncMetrics(){},reportSyncMetrics(){}};
  facade.indexService={beginSyncRead(){begins++;},endSyncRead(){ends++;},selectedSourcesNeedRefresh:()=>changed,
    build:async(_config,progress)=>{builds++;progress({stage:'生成画像',message:'fixture',current:1,total:2,percent:90});}};
  facade.consolidationService={consolidateChat:async(_config,progress)=>{
    progress({stage:'整理聊天',message:'fixture',current:1,total:1,percent:58});return [];}};
  const chatModule=mocks['ChatMemorySync.ets'],original=chatModule.ChatMemorySync;
  chatModule.ChatMemorySync=class {async sync(_config,progress){
    progress({stage:'聊天同步',message:'fixture',current:1,total:1,percent:5});return {processedParts:1,factCount:1};}};
  try {
    await facade.refreshAutomaticSources(config,true,true,value=>steps.push(clone(value)));
    assert.equal(builds,1);assert.equal(steps.at(-1).percent,100);assert.equal(begins,ends);assert.equal(facade.syncRunning,false);
    assert.ok(steps.some(value=>value.stage==='生成画像'&&value.current===1&&value.total===2));
    changed=false;await facade.refreshAutomaticSources(config,true,true);assert.equal(builds,1);
    changed=true;facade.indexService.build=async()=>{throw Error('fixture failure');};
    await assert.rejects(facade.refreshAutomaticSources(config,true,true),/fixture failure/);
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

test('privacy consent resolves only after persistence and dialog closure, before requesting source permissions',async()=>{
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/components/PrivacyConsentDialog.ets'),'utf8');
  const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  for(const saveFirst of [true,false]){
    let release,options,settled=false;const gate=new Promise(resolve=>release=resolve),exported={};
    vm.runInNewContext(code,{exports:exported,DialogAlignment:{Center:0},require:name=>name.includes('PrivacyConsent')?
      {PrivacyConsent:{initialize:async()=>{},isAccepted:()=>false,choose:async()=>gate},PRIVACY_VERSION:'fixture'}:{showToastSafely(){}}});
    const context={getHostContext:()=>({}),showAlertDialog:value=>{options=value;}};
    const pending=exported.PrivacyConsentDialog.show(context);pending.then(()=>{settled=true;});await new Promise(resolve=>setImmediate(resolve));
    options.secondaryButton.action();
    if(saveFirst)release();else options.onDidDisappear();
    await new Promise(resolve=>setImmediate(resolve));assert.equal(settled,false);
    assert.equal(await exported.PrivacyConsentDialog.show(context),false,'Do not stack dialogs while one is closing');
    if(saveFirst)options.onDidDisappear();else release();
    assert.equal(await pending,true);
  }
});

test('the updated privacy version requires renewed consent for daily automatic processing',()=>{
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/utils/PrivacyConsent.ets'),'utf8');
  const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
  const exported={};vm.runInNewContext(code,{exports:exported,require:()=>({}),AppStorage:{setOrCreate(){}}});
  assert.equal(exported.resolvePrivacyChoice('accepted','2026-10-19-v3'),'unselected');
  assert.equal(exported.resolvePrivacyChoice('accepted',exported.PRIVACY_VERSION),'accepted');
  assert.equal(exported.resolvePrivacyChoice('rejected',exported.PRIVACY_VERSION),'rejected');
  const declaration=fs.readFileSync(path.join(root,'entry/src/main/ets/components/PrivacyConsentDialog.ets'),'utf8');
  assert.ok(declaration.includes('跨天首次打开应用'));assert.ok(declaration.includes('今天及前两天'));
});

(async()=>{for(const[name,run]of cases){await run();console.log('PASS '+name);}console.log(cases.length+' incremental sync checks passed');})()
  .catch(error=>{console.error(error.stack);process.exitCode=1;});
