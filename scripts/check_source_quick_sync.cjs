// Exercise the real page coordinators with fake sources; no accounts, device,
// permissions dialogs, network, models or HAP build are involved.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript'),root=path.resolve(__dirname,'..');
const read=name=>fs.readFileSync(path.join(root,'entry/src/main/ets',name),'utf8');
const index=read('pages/Index.ets'),tree=ts.createSourceFile('Index.ts',index.replace(/\bstruct Index\b/,'class Index'),ts.ScriptTarget.Latest,true);
const definition=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='Index');
const methods=['reloadCollectionSourceSyncReadiness','syncCollectionSource','syncMailReminders','syncCalendarMemory'];
const source=methods.map(name=>{
  const method=definition.members.find(n=>ts.isMethodDeclaration(n)&&n.name.getText(tree)===name);
  assert.ok(method,name);return method.getText(tree).replace(/\bprivate\s+/g,'');
}).join('\n');
const output=ts.transpileModule('export class Probe {\n'+source+'\n}',{reportDiagnostics:true,
  compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}});
assert.equal(output.diagnostics.filter(d=>d.category===ts.DiagnosticCategory.Error).length,0);
function fixture(){
  const events=[],toasts=[],state={calendarReady:true,mailReady:true,calendarChecks:0,mailChecks:0,
    calendarReads:0,mailReads:0,memoryCalls:[],mailFailure:null,calendarFailure:null,mailWork:null,calendarCheck:null};
  const exported={};
  vm.runInNewContext(output.outputText,{exports:exported,Promise,
    getContext:()=>({filesDir:'/fixture'}),
    MailStore:class{settings(){return {enabled:true,aiAllowed:false};}},
    StartupSourceSync:class{
      markAttempted(source){events.push('attempt:'+source);}markSynced(source){events.push('synced:'+source);}
      markFailed(source){events.push('failed:'+source);}},
    MailService:{canAutoRefresh:async()=>{state.mailChecks++;return state.mailReady;},
      refresh:async()=>{state.mailReads++;if(state.mailWork)await state.mailWork;if(state.mailFailure)throw state.mailFailure;}},
    CalendarMemoryService:{canAutoRefresh:async()=>{state.calendarChecks++;return state.calendarCheck?await state.calendarCheck():state.calendarReady;},
      refresh:async()=>{state.calendarReads++;if(state.calendarFailure)throw state.calendarFailure;}},
    showToastSafely:(message,duration)=>{events.push('toast');toasts.push({message,duration,afterClose:events.includes('overlay:close')});}
  });
  const page=Object.assign(new exported.Probe(),{filesDir:'/fixture',sourceReadinessEpoch:0,
    calendarSourceSyncReady:false,mailSourceSyncReady:false,sourceSyncPending:'',dataManagerRefreshing:false,dataManagerSyncFailed:false,
    dataManagerFacade:{refreshSourceMemory:async(_model,chat,calendar)=>state.memoryCalls.push({chat,calendar})},
    getDataManagerModelConfig:()=>({}),ensureAiServiceLogin:()=>true,
    beginMemoryOperation(kind){if(this.dataManagerRefreshing)return false;this.dataManagerRefreshing=true;this.dataManagerSyncFailed=false;events.push('overlay:'+kind);return true;},
    endMemoryOperation(){this.dataManagerRefreshing=false;events.push('overlay:close');},
    reloadDataManagerViewModels(){events.push('reload');},updateDataManagerProgress(){}});
  return {page,state,events,toasts};
}
const cases=[];const test=(name,fn)=>cases.push([name,fn]);
test('source readiness independently disables unavailable calendar and mail',async()=>{
  const f=fixture();f.state.calendarReady=false;await f.page.reloadCollectionSourceSyncReadiness();
  assert.equal(f.page.calendarSourceSyncReady,false);assert.equal(f.page.mailSourceSyncReady,true);
  f.state.calendarReady=true;f.state.mailReady=false;await f.page.reloadCollectionSourceSyncReadiness();
  assert.equal(f.page.calendarSourceSyncReady,true);assert.equal(f.page.mailSourceSyncReady,false);
  assert.equal(f.state.calendarReads+f.state.mailReads,0);
});
test('late readiness responses cannot overwrite newer authorization state',async()=>{
  const f=fixture();let release;f.state.calendarCheck=()=>new Promise(resolve=>release=resolve);
  const first=f.page.reloadCollectionSourceSyncReadiness();
  f.state.calendarCheck=async()=>false;await f.page.reloadCollectionSourceSyncReadiness();
  release(true);await first;assert.equal(f.page.calendarSourceSyncReady,false);
});
test('initialization and failed readiness checks stay disabled without unhandled rejection',async()=>{
  const f=fixture();f.page.filesDir='';await f.page.reloadCollectionSourceSyncReadiness();assert.equal(f.state.calendarChecks,0);
  f.page.filesDir='/fixture';f.state.calendarCheck=async()=>{throw Error('permission unavailable');};
  await f.page.reloadCollectionSourceSyncReadiness();assert.equal(f.page.calendarSourceSyncReady,false);assert.equal(f.page.mailSourceSyncReady,true);
});
test('calendar sync reads and refreshes only calendar memory and shows its hint after closing progress',async()=>{
  const f=fixture();await f.page.syncCollectionSource('calendar');
  assert.equal(f.state.calendarReads,1);assert.equal(f.state.mailReads,0);
  assert.deepEqual(f.state.memoryCalls,[{chat:false,calendar:true}]);
  assert.ok(f.events.includes('synced:calendar'));assert.equal(f.toasts.length,1);
  assert.ok(f.toasts[0].message.includes('首页 → 为你提醒'));assert.equal(f.toasts[0].duration,3500);assert.equal(f.toasts[0].afterClose,true);
  assert.equal(f.page.sourceSyncPending,'');
});
test('mail sync does not read calendar or refresh unrelated memory',async()=>{
  const f=fixture();await f.page.syncCollectionSource('mail');
  assert.equal(f.state.mailReads,1);assert.equal(f.state.calendarReads,0);assert.equal(f.state.memoryCalls.length,0);
  assert.ok(f.events.includes('synced:mail'));assert.equal(f.toasts.length,1);assert.equal(f.toasts[0].afterClose,true);
});
test('click-time authorization recheck prevents stale enabled buttons from starting work',async()=>{
  for(const kind of ['calendar','mail']){
    const f=fixture();f.page.calendarSourceSyncReady=true;f.page.mailSourceSyncReady=true;
    f.state[kind+'Ready']=false;await f.page.syncCollectionSource(kind);
    assert.equal(f.state.calendarReads+f.state.mailReads,0);assert.equal(f.toasts.length,1);
    assert.ok(!f.toasts[0].message.includes('同步完成'));assert.equal(f.page.sourceSyncPending,'');
  }
});
test('rapid clicks and concurrent full sync cannot start duplicate source work',async()=>{
  const f=fixture();let release;f.state.mailWork=new Promise(resolve=>release=resolve);
  const first=f.page.syncCollectionSource('mail');await f.page.syncCollectionSource('calendar');
  await new Promise(resolve=>setImmediate(resolve));assert.equal(f.state.mailReads,1);assert.equal(f.state.calendarReads,0);
  release();await first;f.page.dataManagerRefreshing=true;await f.page.syncCollectionSource('mail');assert.equal(f.state.mailReads,1);
});
test('failed sync keeps existing error/retry state and never displays a success hint',async()=>{
  for(const kind of ['calendar','mail']){
    const f=fixture();f.state[kind+'Failure']=Error('fixture sync failed');await f.page.syncCollectionSource(kind);
    assert.equal(f.page.dataManagerSyncFailed,true);assert.ok(f.events.includes('failed:'+kind));
    assert.equal(f.toasts.length,0);assert.equal(f.page.dataManagerRefreshing,false);assert.equal(f.page.sourceSyncPending,'');
  }
});
test('calendar cache-only updates do not advertise a new read and initialization is not false success',async()=>{
  const f=fixture();await f.page.syncCalendarMemory(false);assert.equal(f.state.calendarReads,0);assert.equal(f.toasts.length,0);
  f.page.dataManagerFacade=null;await f.page.syncCollectionSource('calendar');assert.ok(!f.toasts.some(t=>t.message.includes('同步完成')));
});
test('both source lists bind separate disabled/busy sync actions while keeping navigation clickable',()=>{
  for(const name of ['pages/collection/CollectionPage.ets','pages/settings/SettingsCenterPage.ets']){
    const page=read(name);
    for(const kind of ['calendar','mail']){
      const label=kind==='calendar'?'日历分析':'邮箱分析';
      const row=page.slice(page.indexOf("CollectionSourceRow({ title: '"+label),page.indexOf("CollectionSourceRow({ title: '"+label)+650);
      assert.ok(row.includes('showSync: true'));assert.ok(row.includes('this.'+kind+'SourceSyncReady'));
      assert.ok(row.includes('!this.sourceSyncPending'));assert.ok(row.includes('onOpen:'));
      assert.ok(row.includes('onSync: this.onQuickSync'+(kind==='calendar'?'Calendar':'Mail')));
    }
  }
  const controls=read('components/CollectionFormControls.ets').split('export struct CollectionSourceRow')[1];
  assert.ok(controls.includes('.enabled(this.syncEnabled && !this.syncing).onClick(this.onSync)'));
  assert.ok(!controls.slice(controls.lastIndexOf(".padding({ left: 16")).includes('.onClick(this.onOpen)'),'outer row must not swallow sync clicks');
  assert.ok(index.includes('this.currentTab === MainTabIndex.Summary || this.currentTab === MainTabIndex.Mine'));
});
(async()=>{let failures=0;for(const [name,fn]of cases){try{await fn();console.log('PASS '+name);}catch(e){failures++;console.error('FAIL '+name+'\n'+e.stack);}}
console.log(`${cases.length-failures}/${cases.length} source quick-sync checks passed`);process.exitCode=failures?1:0;})();
