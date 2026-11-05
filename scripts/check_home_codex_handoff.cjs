// Exercise production evidence preparation and homepage-to-chat orchestration.
// Host mocks only: no build, network, Codex dispatch, account or device actions.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assert=require('node:assert/strict'),{randomUUID,createHash}=require('node:crypto');
const ts=require(process.argv[2]||'typescript'),root=path.resolve(__dirname,'..'),base='entry/src/main/ets/';
const disk=new Map(),reads=[],cache=new Map();let handles=new Map(),sequence=0;
class Storage {
  join(...p){return p.filter(Boolean).join('/').replace(/\/+/g,'/');}
  exists(p){return disk.has(p);}ensureDir(){}
  readText(p,f=''){reads.push(p);return disk.get(p)??f;}
  readJson(p,f){try{return JSON.parse(this.readText(p));}catch{return f;}}
}
const files={OpenMode:{READ_ONLY:1,CREATE:2,WRITE_ONLY:4,TRUNC:8},
  async open(p,mode){if(mode===1&&!disk.has(p))throw Error('missing');if(mode!==1)disk.set(p,Buffer.alloc(0));const fd=++sequence;handles.set(fd,{p,pos:0});return{fd};},
  async stat(fd){return{size:disk.get(handles.get(fd).p).length};},
  async read(fd,buffer,options){const h=handles.get(fd),bytes=disk.get(h.p),at=options.offset;
    const n=Math.min(2,bytes.length-at,buffer.byteLength);new Uint8Array(buffer).set(bytes.subarray(at,at+n));return n;},
  async write(fd,buffer){const h=handles.get(fd),n=Math.min(2,buffer.byteLength);disk.set(h.p,Buffer.concat([disk.get(h.p),Buffer.from(buffer).subarray(0,n)]));return n;},
  async close(file){handles.delete(typeof file==='number'?file:file.fd);},async unlink(p){disk.delete(p);}};
const chat={ensureSessionAssetsDir(){},sessionAssetsDir:(dir,id)=>dir+'/chat-sessions/'+id+'/assets'};
function load(relative){
  const file=path.resolve(root,relative.endsWith('.ets')?relative:relative+'.ets');if(cache.has(file))return cache.get(file);
  const name=path.basename(file);
  if(name==='DataManagerStorage.ets')return{DataManagerStorage:Storage};
  if(name==='ChatSessionStorage.ets')return{ChatSessionStorage:chat};
  if(name==='IndexService.ets')return{};
  const exports={};cache.set(file,exports);
  const output=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}});
  vm.runInNewContext(output.outputText,{exports,console,setTimeout,Date,require:id=>{
    if(id==='@kit.ArkTS')return{JSON,util:{generateRandomUUID:()=>randomUUID(),Base64Helper:class{decodeSync(text){return Uint8Array.from(Buffer.from(text,'base64'));}encodeToStringSync(bytes){return Buffer.from(bytes).toString('base64');}}}};
    if(id==='@kit.CoreFileKit')return{fileIo:files};
    if(id==='@kit.CryptoArchitectureKit')return{cryptoFramework:{createMd:()=>{const hash=createHash('sha256');return{update:async({data})=>{hash.update(data);},digest:async()=>({data:Uint8Array.from(hash.digest())})};}}};
    if(!id.startsWith('.'))throw Error('Unexpected '+id);
    return load(path.resolve(path.dirname(file),id));
  }},{filename:file});return exports;
}
const {HomeCodexContextService}=load(base+'datamanager/HomeCodexContext');
const {DataManagerPaths}=load(base+'datamanager/DataManagerPaths');
const handoff=load(base+'pages/home/HomeCodexHandoff');
const {prepareHomeCodexAttachments}=load(base+'pages/home/HomeCodexAttachments');
const {buildHomeCodexBrief,HOME_CODEX_DELIVERY_GOAL}=load(base+'datamanager/HomeCodexBrief');
const budgets=load(base+'utils/CodexRequestBudget');
const storage=new Storage(),paths=new DataManagerPaths('/app',storage);
const req=(extra={})=>({kind:'reminder',id:'reminder-1',title:'准备研究计划',description:'讨论新方向',goal:'',eventIds:['e1'],evidence:[],...extra});
const event=(extra={})=>({event_id:'e1',event_date:'2026-11-04',summary:'讨论研究计划',normalized_fact:'用户和同事讨论研究方向',
  source_refs:['2026-11-04/chat.md#1'],image_paths:['runs/r/one.png'],sources:['微信'],workflow_scene_ids:[3],tags:[],keywords:[],domains:[],...extra});
function context(events=[event()],batches=[]){const calls=[];return{calls,service:new HomeCodexContextService(paths,storage,{
  loadEventsByIds(ids){calls.push([...ids]);return Object.fromEntries(events.filter(e=>ids.includes(e.event_id)).map(e=>[e.event_id,e]));},
  loadChatContextBatches(){return batches;}})};}
const tests=[];function test(name,fn){tests.push([name,fn]);}
test('calendar and mail are excluded at both entry and evidence boundary',async()=>{
  for(const id of ['calendar:overview','mail:overview']){
    assert.equal(handoff.homeReminderSupportsCodex({id,sourceEventIds:[]}),false);
    const c=context();await assert.rejects(c.service.prepare(req({id})),/日历和邮箱/);assert.equal(c.calls.length,0);
  }
  await assert.rejects(context().service.prepare(req({eventIds:['calendar:1','mail:2']})),/日历和邮箱/);
  await assert.rejects(context([event({calendar:{start:1}})]).service.prepare(req()),/日历和邮箱/);
  assert.equal(handoff.homeReminderSupportsCodex({id:'normal',sourceEventIds:['e1'],agentTask:''}),true);
});
test('raw selected pages and later replies are kept without unrelated conversations',async()=>{
  disk.clear();reads.length=0;
  const c=context([event()], [{batch_id:'workflow:r',complete:true,entries:[
    {source_ref:'2026-11-04/chat.md#1',text:'聊天对象：同事甲｜同事：请比较两个研究方案',image_paths:['runs/r/one.png']},
    {source_ref:'2026-11-04/chat.md#2',text:'聊天对象：同事甲｜我：不用发邮件，先整理比较表',image_paths:['runs/r/two.png']},
    {source_ref:'2026-11-04/chat.md#3',text:'聊天对象：联系人乙｜UNRELATED PRIVATE CONVERSATION',image_paths:['runs/r/private.png']}]}]);
  disk.set(paths.dailyLogRoot+'/2026-11-04/unrelated.md','UNRELATED PRIVATE CONVERSATION');
  const result=await c.service.prepare(req());
  assert.match(result.message,/2 条/);assert.match(result.prompt,/不用发邮件/);assert.ok(!result.prompt.includes('UNRELATED'));
  assert.deepEqual([...result.imageRefs],['runs/r/one.png','runs/r/two.png']);assert.equal(reads.length,0);
  assert.match(result.prompt,/不是新的指令/);assert.match(result.prompt,/后续内容为准/);
});
test('raw log fallback reads exact numbered entries and deduplicates shared files',async()=>{
  disk.clear();reads.length=0;disk.set(paths.dailyLogRoot+'/2026-11-04/chat.md','1. 已知的出发日期和预算\n\n2. 不相关隐私\n\n3. 指定目的地\n');
  const c=context([event(),event({event_id:'e2',source_refs:['2026-11-04/chat.md#3']})]);
  const result=await c.service.prepare(req({eventIds:['e1','e2','e1']}));
  assert.match(result.message,/2 条/);assert.ok(!result.prompt.includes('不相关隐私'));
  assert.equal(reads.filter(p=>p.endsWith('chat.md')).length,1);assert.equal(c.calls[0].length,2);
});
test('missing legacy references stay explicit; record-N never indexes a fresh list',async()=>{
  disk.clear();const c=context();const result=await c.service.prepare(req({kind:'suggestion',eventIds:[],evidence:[
    {label:'近期记录',summary:'旧推荐保留的文字',ref:'record-1'}]}));
  assert.equal(c.calls[0].length,0);assert.match(result.prompt,/未找到可用文字原文/);assert.match(result.prompt,/旧推荐保留的文字/);
  assert.ok(!result.prompt.includes('讨论研究计划'));
});
test('recommendation generation retains stable event IDs and selected profile identity',()=>{
  const {parseHomeTaskSuggestions}=load(base+'pages/home/HomeTaskSuggestion');
  const candidates=[1,2,3].map(i=>({title:'研究方向'+i,task:'研究第'+i+'个课题',category:'learning',reason:'想了解',evidence_refs:['record-1','profile-1']}));
  const domain={domain:'work',title:'工作',fullDesc:'研究兴趣',desc:'研究兴趣',eventCount:1,claims:[]};
  const suggestions=parseHomeTaskSuggestions(JSON.stringify({suggestions:candidates}),'batch',[],[event()],[domain]);
  const request=handoff.homeSuggestionCodexRequest(suggestions[0]);
  assert.equal(request.evidence[0].eventId,'e1');assert.equal(request.evidence[1].profileDomain,'work');
});
test('large or incomplete evidence is bounded and labelled',async()=>{
  const entries=Array.from({length:120},(_,i)=>({source_ref:'2026-11-04/chat.md#'+(i+1),text:'聊天对象：同事甲｜'+'长'.repeat(10000),image_paths:[]}));
  const result=await context([event()],[{batch_id:'r',complete:false,entries}]).service.prepare(req());
  assert.ok(Buffer.byteLength(result.prompt,'utf8')<=16000);assert.match(result.prompt,/不完整/);assert.match(result.prompt,/节选/);
});
test('repeated media placeholders and overlapping screens do not flood the task',()=>{
  const photo='- 同事甲 | 2026年11月04日 16:46: [图片]';
  const planning='- 我 | 2026年11月04日 16:47: 周末见面，先比较两个地点';
  const reply='- 同事甲 | 2026年11月04日 16:48: 不用今天，改到周日';
  const pages=[{ref:'a#1',batch:'r',direct:true,distance:0,images:['one'],text:Array(800).fill(photo).join('\\n')+'\n'+planning+'\n'+reply},
    {ref:'a#2',batch:'r',direct:false,distance:1,images:['two'],text:planning+'\n'+reply}];
  const brief=buildHomeCodexBrief(req({title:'安排周末见面',description:'比较地点'}),[],pages,[]);
  assert.equal(brief.prompt.split('周末见面，先比较两个地点').length-1,1);
  assert.equal(brief.prompt.split('不用今天，改到周日').length-1,1);
  assert.ok(!brief.prompt.includes('[图片]'));assert.ok(!brief.prompt.includes('\\n-'));
  assert.ok(Buffer.byteLength(brief.prompt)<5000);assert.ok(brief.message.length<180);
  assert.ok(!brief.prompt.includes('a#'));assert.ok(!brief.prompt.includes('source_refs'));
  const onlyImage=buildHomeCodexBrief(req({title:'解读截图'}),[],[
    {ref:'a',batch:'r',direct:true,distance:0,images:['actual-screenshot'],text:photo}],[]);
  assert.deepEqual([...onlyImage.imageRefs],['actual-screenshot'],'Discarding media placeholders must preserve an actual source screenshot');
});
test('relevance keeps nearby answers while skipping unrelated topics in a long page',()=>{
  const raw=Array.from({length:150},(_,i)=>'其他人： unrelated topic '+i);
  raw.splice(60,0,'同事甲：周末见面地点选哪里','我：先选公园，不用订餐');
  const brief=buildHomeCodexBrief(req({title:'周末见面地点',description:'选择地点'}),[],[
    {ref:'a#1',batch:'r',direct:true,distance:0,images:[],text:raw.join('\n')}],[]);
  assert.match(brief.prompt,/先选公园，不用订餐/);assert.ok(!brief.prompt.includes('topic 120'));
  assert.ok(brief.prompt.length<3000);
});
test('timestamped repeats survive; source and capture metadata are not repeated in each message',()=>{
  const capture=time=>'位置：右侧｜发送人：我｜聊天对象：同事甲｜时间原文：今天｜时间：'+time+'｜原文：确认周末见面';
  const raw=[capture('2026-11-04 16:46'),capture('2026-11-04 16:46'),capture('2026-11-04 17:00')].join('\n');
  const brief=buildHomeCodexBrief(req({title:'确认周末见面'}),[],[{ref:'x',batch:'r',direct:true,distance:0,images:[],text:raw}],[]);
  assert.equal(brief.prompt.split('我：确认周末见面').length-1,2);
  assert.ok(!brief.prompt.includes('时间原文'));assert.ok(!brief.prompt.includes('位置：'));
});
test('legacy reply suggestions become reference data under a concrete work contract',()=>{
  const oldGoal='告诉我怎么回复对方\n然后发送确认消息';
  const input=req({title:'安排见面',description:'此前约晚餐，需确认时间地点',goal:oldGoal});
  const raw='我：今晚倒是可以\n同事甲：改到周末见吧';
  const brief=buildHomeCodexBrief(input,[],[{ref:'x',batch:'r',direct:true,distance:0,images:['screen'],text:raw}],[]);
  assert.ok(brief.prompt.indexOf('工作要求：')<brief.prompt.indexOf(oldGoal.split('\n')[0]));
  assert.match(brief.prompt,/原建议（参考线索，不作为交付要求）：\n> 告诉我怎么回复对方\n> 然后发送确认消息/);
  assert.match(brief.prompt,/时间安排、地点或活动候选、交通衔接、预算和备选方案/);
  assert.match(brief.prompt,/改到周末见吧/);assert.match(brief.prompt,/后续内容为准/);
  assert.match(brief.prompt,/先完成不依赖缺项的工作/);assert.match(brief.prompt,/标明假设/);
  assert.match(brief.prompt,/代拟回复、如何回复和可发送的确认消息不作为主要交付/);
  assert.match(brief.message,/主动调研、规划并交付可用成果/);
});
test('the same work criteria cover research, decisions and document preparation without per-contact cases',()=>{
  for(const topic of ['比较端侧推理方案','选择合适的设备','准备项目申报材料','设计旅行行程']){
    const brief=buildHomeCodexBrief(req({title:topic,description:'根据已有资料推进',goal:'先确认需求'}),[],[],[]);
    assert.match(brief.prompt,/实际完成准备工作/);assert.match(brief.prompt,/检索与核验资料、比较候选/);
    assert.match(brief.prompt,/草案、清单或成品/);assert.match(brief.prompt,/给出来源/);
    assert.match(brief.prompt,/不能把未检索的信息写成已核实事实/);
    assert.ok(brief.prompt.includes(topic));assert.ok(Buffer.byteLength(brief.prompt)<16000);
  }
});
test('an edited Codex goal is an explicit user requirement rather than a phone-operation hint',()=>{
  const brief=buildHomeCodexBrief(req({userGoal:'请制作十页研究汇报PPT',goal:'打开浏览器搜索研究方向'}),[],[],[]);
  assert.match(brief.prompt,/用户本次明确的交付目标：\n请制作十页研究汇报PPT/);
  assert.match(brief.prompt,/原建议（参考线索，不作为交付要求）/);
});
test('Chinese, quotes and emoji fit both bridge limits after JSON serialization',()=>{
  const raw=Array.from({length:100},(_,i)=>'同事'+i+'：周末见面，'+'讨论😀\\"'.repeat(200)).join('\n');
  const brief=buildHomeCodexBrief(req({title:'周末见面',description:'条件'.repeat(30000)}),[],[
    {ref:'a',batch:'r',direct:true,distance:0,images:[],text:raw}],[]);
  const task=brief.prompt+'\n已附 3 张相关来源截图。\n'+HOME_CODEX_DELIVERY_GOAL+'\n交付要求：简述结果和验证情况。';
  const body=JSON.stringify({requestId:randomUUID(),text:task,attachments:['a','b','c'],model:'model',effort:'medium',mode:'workspace-write',approvalMode:'ask'});
  assert.ok(task.length<20000);assert.ok(Buffer.byteLength(brief.prompt)<=16000);assert.ok(Buffer.byteLength(body)<64000);
  assert.doesNotThrow(()=>budgets.checkCodexJsonBudget('/v1/tasks/id/turns',body));
  for(const text of ['纯中文','a😀b','\ud800','\\"\n',body])assert.equal(budgets.codexUtf8Bytes(text),Buffer.byteLength(text));
  assert.equal(budgets.codexUtf8Excerpt('a😀b',4),'a');
  assert.throws(()=>budgets.checkCodexJsonBudget('/v1/tasks/id/turns',JSON.stringify({text:'中'.repeat(22000)})),/本次未发送/);
  const server=fs.readFileSync(path.join(root,'bridge/codex/server.mjs'),'utf8');
  const uploadRoute=/const isUpload = route === '([^']+)'/.exec(server)[1];
  assert.equal(budgets.CODEX_UPLOAD_ROUTE,uploadRoute,'Phone uploads must use the route that the existing PC server accepts');
  assert.doesNotThrow(()=>budgets.checkCodexJsonBudget(uploadRoute,JSON.stringify({base64:'A'.repeat(100000)})));
});
test('managed session attachments preserve local and JSON/base64 image bytes',async()=>{
  disk.clear();const png=Buffer.from('iVBORw0KGgoAAA==','base64');disk.set('/app/p.png',png);
  disk.set(paths.workflowRunsRoot+'/r/run_summary.json',JSON.stringify({steps:{s:{output:{image_b64:png.toString('base64')}}}}));
  const result=await prepareHomeCodexAttachments('/app','new-session',['file:///app/p.png','runs/r/run_summary.json#steps/s/output/image_b64','file:///app/p.png']);
  assert.equal(result.paths.length,1,JSON.stringify(result.notices));assert.equal(handles.size,0);
  for(const uri of result.paths){assert.ok(uri.startsWith('file:///app/chat-sessions/new-session/assets/'));assert.deepEqual(disk.get(uri.substring(7)),png);}
  assert.deepEqual(disk.get('/app/p.png'),png);assert.equal(result.notices.length,0);
});
test('unavailable images cannot abort text delegation; attachment counts match actual saved images',async()=>{
  disk.clear();disk.set('/app/p.jpg',Buffer.from('image'));
  const result=await prepareHomeCodexAttachments('/app','s',['file:///app/missing.jpg','file:///app/p.jpg']);
  assert.equal(result.paths.length,1);assert.equal(result.sources.length,1);assert.equal(result.notices.length,1);
  const embedded='data:image/png;base64,'+Buffer.from('test').toString('base64');
  const inline=await prepareHomeCodexAttachments('/app','s',[embedded]);assert.equal(inline.paths.length,1);assert.ok(!inline.sources[0].includes('base64'));
});
test('attachment limits skip oversized files, cap at six and close every descriptor',async()=>{
  disk.clear();disk.set('/app/large.png',Buffer.alloc(8*1024*1024+1));
  for(let i=0;i<8;i++)disk.set('/app/image-'+i+'.jpg',Buffer.from('image-'+i));
  const result=await prepareHomeCodexAttachments('/app','limited',['file:///app/large.png',
    ...Array.from({length:8},(_,i)=>'file:///app/image-'+i+'.jpg')]);
  assert.equal(result.paths.length,6);assert.equal(result.sources.length,6);assert.match(result.notices.join(' '),/8 MB/);
  assert.match(result.notices.join(' '),/6 张/);assert.equal(handles.size,0);
});
function pageProbe(globals){
  const source=fs.readFileSync(path.join(root,base+'pages/Index.ets'),'utf8').replace(/\bstruct Index\b/,'class Index');
  const tree=ts.createSourceFile('Index.ts',source,ts.ScriptTarget.Latest,true),component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='Index');
  const method=component.members.find(n=>ts.isMethodDeclaration(n)&&n.name.getText(tree)==='handHomeItemToCodex');
  const exports={};vm.runInNewContext(ts.transpileModule('exports.Probe=class{'+method.getText(tree)+'}',{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,
    {exports,Date,ArkJSON:JSON,HOME_CODEX_DELIVERY_GOAL,CHAT_MODE_CLOUD_AGENT:'cloud',CHAT_MESSAGE_KIND_CHAT:'chat',MainTabIndex:{Chat:2},...globals});return new exports.Probe();
}
test('homepage starts an isolated cloud session and delegates once with context and managed pictures',async()=>{
  let delegated=0;const messages=[],modes=[];
  const page=pageProbe({ChatSessionController:{createSession:(_d,_s,mode)=>{modes.push(mode);return{activeSession:{id:'new'},activeSessionId:'new'};},renameSession:(_d,s)=>s},
    ChatSessionStorage:{renameSession(){}},prepareHomeCodexAttachments:async()=>({paths:['file:///managed'],sources:['original'],notices:['one missing']}),
    createChatMessage:(...args)=>args});
  Object.assign(page,{filesDir:'/app',cloudThinking:false,blockChatSessionMutationIfBusy:()=>false,ensureAiServiceLogin:()=>true,
    currentChatSessionViewState:()=>({activeSessionId:'old'}),applyChatSessionViewState(s){this.activeChatSessionId=s.activeSessionId;},
    nextChatMessageId:()=>randomUUID(),appendChatMessageToExactSession:(id,m)=>messages.push([id,m]),
    dataManagerFacade:{prepareHomeCodexContext:async()=>({title:'具体目标',prompt:'RAW CONTEXT',message:'SHORT TASK',imageRefs:['source'],suppliedEventIds:['already-attached']})},
    runCodexTaskForChatSession:async(id,request,images,_preview,suppliedIds)=>{delegated++;assert.deepEqual([...suppliedIds],['already-attached']);assert.equal(id,'new');assert.match(request.task,/RAW CONTEXT/);assert.match(request.task,/部分截图/);assert.ok(!messages[0][1][3].includes('RAW CONTEXT'));assert.match(messages[0][1][3],/SHORT TASK/);
      assert.ok(request.task.endsWith(HOME_CODEX_DELIVERY_GOAL),'The actual remote task must end with the work acceptance criteria after source material and attachment notes');
      assert.equal(request.continueRunId,'');assert.deepEqual([...images],['file:///managed']);return{runId:'run'};}});
  await page.handHomeItemToCodex(req());assert.deepEqual(modes,['cloud']);assert.equal(delegated,1);assert.equal(page.activeChatSessionId,'new');
  assert.equal(page.cloudThinking,false);assert.equal(page.cloudCodexSessionId,'');assert.ok(messages.every(([id])=>id==='new'));
  page.blockChatSessionMutationIfBusy=()=>true;await page.handHomeItemToCodex(req());assert.equal(delegated,1);
  page.blockChatSessionMutationIfBusy=()=>false;
  page.dataManagerFacade.prepareHomeCodexContext=async()=>{throw Error('cannot read source');};
  await assert.rejects(page.handHomeItemToCodex(req()),/cannot read source/);
  assert.equal(page.cloudThinking,false);assert.equal(page.cloudCodexSessionId,'');assert.equal(delegated,1);
  page.dataManagerFacade.prepareHomeCodexContext=async()=>{page.cloudChatCancelRequested=true;return{title:'cancelled',prompt:'data',imageRefs:[]};};
  await page.handHomeItemToCodex(req());assert.equal(modes.length,1,'Cancelling preparation must not create a session or remote turn');
  assert.equal(delegated,1);assert.equal(page.cloudThinking,false);
});
test('only source facts fully present in the final brief are excluded from additional retrieval',()=>{
  const events=Array.from({length:8},(_,i)=>({event_id:'event-'+i,normalized_fact:'资料'+i+'包含一段已经确认过的任务条件和背景。',summary:'资料'+i}));
  const brief=buildHomeCodexBrief(req({evidence:[]}),events,[],[]);
  assert.deepEqual([...brief.suppliedEventIds],events.slice(0,6).map(e=>e.event_id));
  assert(!brief.prompt.includes(events[6].normalized_fact));
  const long={event_id:'long-source',normalized_fact:'很长的相关资料。'.repeat(200)};
  const truncated=buildHomeCodexBrief(req({evidence:[]}),[long],[],[]);
  assert(!truncated.suppliedEventIds.includes('long-source'));
});
(async()=>{for(const[name,fn]of tests){await fn();console.log('PASS '+name);}console.log(tests.length+' home Codex checks passed');})().catch(e=>{console.error(e);process.exitCode=1;});
