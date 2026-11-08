// Focused native settings/default/navigation checks; no account, device or HAP.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript'),root=path.resolve(__dirname,'..');
const pageText=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),'utf8');
const tree=ts.createSourceFile('page.ts',pageText.replace('struct RecordingPage','class RecordingPage'),ts.ScriptTarget.Latest,true);
const page=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='RecordingPage');
const method=name=>page.members.find(n=>ts.isMethodDeclaration(n)&&n.name?.getText(tree)===name).getText(tree);
function preferences(saved={}){
  const values=new Map(Object.entries(saved)),declared=[];const exports={};
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/utils/recording/RecordingPreferences.ets'),'utf8');
  vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
    {exports,PersistentStorage:{persistProp(key,value){declared.push(key);if(!values.has(key))values.set(key,value);}}});
  return {exports,values,declared};
}
const cases=[];function test(name,run){cases.push([name,run]);}
test('fresh preferences default to the system transcription model, cloud summary and live transcription',()=>{
  const p=preferences();p.exports.initializeRecordingPreferences();p.exports.initializeRecordingPreferences();
  assert.equal(p.values.get('recordingTranscriptionEngine'),'system');assert.equal(p.values.get('recordingSummarySource'),'cloud');
  assert.equal(p.values.get('recordingLiveTranscribe'),true);assert.equal(p.values.get('recordingSpeakerSeparation'),false);
  assert.equal(p.values.get('recordingAiSearch'),true);
  assert.equal(p.declared.length,new Set(p.declared).size,'Repeated page imports do not reinitialize choices');
});
test('previously saved explicit choices are not reset when settings open',()=>{
  const p=preferences({recordingTranscriptionEngine:'sensevoice',recordingSummarySource:'local',recordingLiveTranscribe:false,recordingAiSearch:false});
  p.exports.initializeRecordingPreferences();assert.equal(p.values.get('recordingTranscriptionEngine'),'sensevoice');
  assert.equal(p.values.get('recordingSummarySource'),'local');assert.equal(p.values.get('recordingLiveTranscribe'),false);
  assert.equal(p.values.get('recordingAiSearch'),false);
});
test('More opens full-screen settings and Back returns to the same recording without saving or leaving the feature',()=>{
  const exports={};let backs=0,stops=0;
  vm.runInNewContext(ts.transpileModule('exports.Page=class {'+['openRecordingSettings','goBack','selectTranscriptionEngine','useSystemAsr'].map(method).join('\n')+'}',
    {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports,router:{back(){backs++;}}});
  const p=new exports.Page(),selected={id:'existing'};
  Object.assign(p,{busy:false,recording:false,showRecordingSettings:false,selected,separateSpeakers:false,speakerSwitchOn:false,
    stopRecordingSearch(){stops++;},recordingSettingsScroller:{scrollTo(){}},save(){throw Error('Settings back must not save the record');}});
  p.openRecordingSettings();assert(p.showRecordingSettings);assert.equal(stops,1);p.goBack();assert(!p.showRecordingSettings);
  assert.equal(p.selected,selected);assert.equal(backs,0);
  p.separateSpeakers=true;p.speakerSwitchOn=true;p.liveTranscribe=false;p.selectTranscriptionEngine('system');
  assert(p.useSystemAsr());assert.equal(p.speakerSwitchOn,false);assert.equal(p.liveTranscribe,true);
  p.busy=true;p.openRecordingSettings();assert(!p.showRecordingSettings,'Cannot change the engine mid-job');
});
test('main recording UI contains only the requested sections and search remains enabled on empty input',()=>{
  const home=method('HomeHeader'),search=method('SearchControls');
  for(const text of ['声音来源','连接手表','所有录音'])assert(home.includes(text));
  for(const text of ['留住每一刻','转写方式','转写模型','摘要方式','边录边转写','屏幕授权'])assert(!home.includes(text));
  assert(!search.includes("Text('云端')"));assert(!search.includes('.enabled(!this.busy && this.recordingSearchActive())'));
  assert(search.includes('AppTheme.filledBackground'));assert(search.includes("requestFocus('recording-search-input')"));
  assert(!pageText.includes('.bindSheet(this.showOptions'));assert(!pageText.includes('private async actions()'));
  assert(method('Content').includes('this.SettingsContent()'));assert(method('PageHeader').includes('this.openRecordingSettings()'));
  const settings=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingSettingsView.ets'),'utf8');
  assert(!search.includes('Toggle('));assert(!search.includes("Text('AI 搜索')"));
  assert(settings.includes("Text('AI 搜索')"));assert(settings.includes('this.onSearchModeChange(value)'));
  for(const text of ['转写模型','摘要方式','边录边转写','离线语音模型','说话人与声纹','重新生成摘要','仅删除音频文件'])assert(settings.includes(text));
});
for(const[name,run]of cases){run();console.log('PASS '+name);}console.log(cases.length+' recording settings checks passed');
