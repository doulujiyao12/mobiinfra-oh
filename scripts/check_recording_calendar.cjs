// Local recording-date browsing only: no device, model calls or HAP build.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript'),root=path.resolve(__dirname,'..');
process.env.TZ='Asia/Shanghai';
const cache=new Map();
function load(relative){
  const file=path.resolve(root,relative.endsWith('.ets')?relative:relative+'.ets');
  if(cache.has(file))return cache.get(file);
  const exports={};cache.set(file,exports);
  const source=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(source,{exports,Date,Map,Set,require:id=>{
    if(!id.startsWith('.'))throw Error('Unexpected calendar dependency '+id);
    return load(path.relative(root,path.resolve(path.dirname(file),id)));
  }},{filename:file});
  return exports;
}
const calendar=load('entry/src/main/ets/utils/recording/RecordingCalendar');
const clone=value=>JSON.parse(JSON.stringify(value));
const record=(id,date,extra={})=>({id,createdAt:date,title:id,duration:10,...extra});
const cases=[];function test(name,run){cases.push([name,run]);}
test('month grids cover actual days, complete Sunday-first weeks and leap/year boundaries',()=>{
  for(const [month,total]of [['2026-11',30],['2024-02',29],['2026-02',28],['2026-04',30],['2026-12',31]]){
    const weeks=calendar.recordingCalendarWeeks(month,new Map(),new Date('2026-11-07T12:00:00+08:00'));
    const days=weeks.flatMap(w=>w.days);
    assert(weeks.every(w=>w.days.length===7));assert.equal(days[0].weekday,'日');assert.equal(days.at(-1).weekday,'六');
    assert.equal(new Set(days.map(d=>d.key)).size,days.length);assert.equal(days.filter(d=>d.inMonth).length,total);
  }
  assert.equal(calendar.shiftRecordingCalendarMonth('2026-12',1),'2027-01');
  assert.equal(calendar.shiftRecordingCalendarMonth('2026-01',-1),'2025-12');
  assert.throws(()=>calendar.recordingCalendarWeeks('2026-13',new Map()));
});
test('local date filtering preserves all recordings, handles midnight and marks text-only records',()=>{
  const records=[record('before','2026-11-01T15:59:59Z'),record('after','2026-11-01T16:00:00Z',{audioDeleted:true}),
    record('old','2025-12-31T18:00:00+08:00'),record('invalid','invalid')];
  const counts=calendar.recordingCalendarCounts(records);
  assert.equal(counts.get('2026-11-01'),1);assert.equal(counts.get('2026-11-02'),1);assert.equal(counts.size,3);
  assert.equal(calendar.filterRecordingCalendar(records,'all','2026-11',''),records);
  assert.deepEqual(clone(calendar.filterRecordingCalendar(records,'day','2026-11','2026-11-02').map(r=>r.id)),['after']);
  assert.deepEqual(clone(calendar.filterRecordingCalendar(records,'month','2026-11','').map(r=>r.id)),['before','after']);
  const weeks=calendar.recordingCalendarWeeks('2026-11',counts,new Date('2026-11-02T12:00:00+08:00'));
  assert(weeks.flatMap(w=>w.days).find(d=>d.key==='2026-11-02').hasRecord);
  assert(weeks.flatMap(w=>w.days).find(d=>d.key==='2026-11-02').today);
  assert.equal(records.length,4);
});
test('date browsing can be cleared and search results remain independent of the selected day',()=>{
  const text=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),'utf8');
  const tree=ts.createSourceFile('page.ts',text.replace('struct RecordingPage','class RecordingPage'),ts.ScriptTarget.Latest,true);
  const page=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='RecordingPage');
  const names=['recordingSearchActive','recordingSearchRows','refreshRecordingCalendar','shiftRecordingMonth','selectRecordingDay','clearRecordingDate'];
  const methods=page.members.filter(n=>ts.isMethodDeclaration(n)&&names.includes(n.name?.getText(tree))).map(n=>n.getText(tree)).join('\n');
  const exports={};vm.runInNewContext(ts.transpileModule('exports.Page=class {'+methods+'}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{exports,Date,...calendar});
  const p=new exports.Page();Object.assign(p,{busy:false,records:[record('a','2026-11-01'),record('b','2026-11-02'),record('c','2026-10-01')],
    calendarMonth:'2026-11',calendarDay:'',calendarScope:'all',calendarWeeks:[],calendarWeekIndex:0,recordingSearchQuery:'',recordingSearchHits:[],
    recordingListScroller:{scrollToIndex(){}}});
  p.refreshRecordingCalendar('2026-11-01');p.selectRecordingDay('2026-11-02');assert.equal(p.recordingSearchRows()[0].id,'b');
  p.selectRecordingDay('invalid');assert.equal(p.calendarDay,'2026-11-02');
  p.recordingSearchQuery='project';p.recordingSearchHits=[{recordId:'c'}];assert.equal(p.recordingSearchRows()[0].id,'c');
  p.recordingSearchQuery='';p.shiftRecordingMonth(-1);assert.equal(p.calendarMonth,'2026-10');assert.equal(p.recordingSearchRows()[0].id,'c');
  p.clearRecordingDate();assert.equal(p.recordingSearchRows().length,3);
  assert(p.calendarWeekIndex>=0&&p.calendarWeekIndex<p.calendarWeeks.length);
});
test('cards use saved summary or existing transcript and distinguish time from full dates',()=>{
  const r=record('a','2026-11-07T23:08:00+08:00',{summary:{overview:' 已有摘要\n第二行 ',keyPoints:[]},analysis:{segments:[{text:'现有转写'}]}});
  assert.equal(calendar.recordingCardPreview(r),'已有摘要 第二行');
  delete r.summary;assert.equal(calendar.recordingCardPreview(r),'现有转写');
  assert.equal(calendar.recordingCardPreview(record('empty','2026-11-07')),'点开录音，开始转写');
  assert.equal(calendar.recordingCardClock(r,true),'23:08');
  assert.equal(calendar.recordingCardClock(r,false,new Date('2026-11-07')),'11/7 23:08');
  assert.equal(calendar.recordingCardClock(r,false,new Date('2027-01-01')),'2026/11/7 23:08');
});
for(const[name,run]of cases){run();console.log('PASS '+name);}console.log(cases.length+' recording calendar checks passed');
