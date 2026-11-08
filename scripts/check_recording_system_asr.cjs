// Production ArkTS with a virtual clock/audio stream and a fake system service.
// No HAP build, device access, real recording, model download or inference.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.argv[2] || 'typescript');
const root = path.resolve(__dirname, '..');
const base = 'entry/src/main/ets/utils/recording/';
let now = 0, serial = 0, engineSerial = 0, tests = 0;
let tasks = new Map(), files = new Map(), handles = new Map(), engines = [], logs = [];
let deferCreate = null, stallFinish = false, failFrame = false, startError = false, amplitude = .2, duration = 120, fastAudio = false;
const durations = new Map();
function schedule(fn, delay, interval = 0) { const id = ++serial; tasks.set(id,{fn,at:now+delay,interval}); return id; }
const clock = {setTimeout:(fn,d)=>schedule(fn,d), clearTimeout:id=>tasks.delete(id),
  setInterval:(fn,d)=>schedule(fn,d,d),clearInterval:id=>tasks.delete(id)};
async function advance(ms) {
  await Promise.resolve(); await Promise.resolve();
  const stop=now+ms;
  for (;;) {
    let found=null;
    for(const [id,task] of tasks) if(task.at<=stop&&(!found||task.at<found[1].at))found=[id,task];
    if(!found)break;
    const [id,task]=found;now=task.at;
    if(task.interval)task.at+=task.interval;else tasks.delete(id);
    task.fn(); await Promise.resolve();
  }
  now=stop; await Promise.resolve();
}
const io = {
  OpenMode:{CREATE:1,READ_WRITE:2},WhenceType:{SEEK_SET:0},accessSync:p=>files.has(p),
  openSync(p){if(!files.has(p))files.set(p,Buffer.alloc(0));const fd=++serial;handles.set(fd,{p,cursor:0});return {fd};},
  closeSync:f=>handles.delete(typeof f==='number'?f:f.fd),
  lseek(fd,n){handles.get(fd).cursor=n;},statSync:fd=>({size:files.get(handles.get(fd).p).length}),
  writeSync(fd,data){const h=handles.get(fd),old=files.get(h.p),next=Buffer.alloc(h.cursor+data.byteLength);
    old.copy(next);Buffer.from(data).copy(next,h.cursor);files.set(h.p,next);h.cursor=next.length;return data.byteLength;},
  fsyncSync(){},readTextSync:p=>files.get(p).toString(),unlinkSync:p=>files.delete(p)
};
function makeEngine() {
  const engine={id:++engineSerial,listener:null,params:null,frames:0,stopped:false,sessions:[],
    setListener(listener){this.listener=listener;},
    startListening(params){assert.equal(params.extraParams.recognitionMode,1);this.params=params;this.frames=0;
      this.sessions.push({id:params.sessionId,frames:0});
      if(startError)this.listener.onError(params.sessionId,1002200002,'service unavailable');
      else this.listener.onStart(params.sessionId,'');},
    writeAudio(id,pcm){assert.equal(pcm.length,1280);assert.equal(id,this.params.sessionId);if(failFrame)throw Error('service write failure');
      this.frames++;this.sessions.at(-1).frames++;
      if(this.frames%25===0)this.listener.onResult(id,{result:'正在说话的内容'+this.sessions.length,isFinal:false,isLast:false});},
    finish(id){if(stallFinish)return;
      if(this.frames)this.listener.onResult(id,{result:'本段已经完成的内容'+this.sessions.length,isFinal:true,isLast:true});
      this.listener.onComplete(id,'');},shutdown(){this.stopped=true;}
  };engines.push(engine);return engine;
}
const mocks={
  '@kit.CoreSpeechKit':{speechRecognizer:{createEngine(params){assert.equal(params.online,1);assert.equal(params.extraParams.recognizerMode,'long');
    if(deferCreate)return new Promise(resolve=>{deferCreate.resolve=resolve;});return Promise.resolve(makeEngine());}}},
  '@kit.CoreFileKit':{fileIo:io},'@kit.BasicServicesKit':{},
  '@kit.ArkTS':{JSON,util:{TextEncoder:class{encodeInto(s){return new TextEncoder().encode(s);}}}},
  '../AppLogger':{AppLogger:{debug:(...v)=>logs.push(v),warn:(...v)=>logs.push(v)}}
};
const loaded=new Map();
function fakeSamples(length) {
  if(!fastAudio)return new Float32Array(length).fill(amplitude);
  return {length,slice:(start,end)=>({length:end-start,every:()=>amplitude<.008})};
}
function load(relative) {
  const file=path.join(root,relative+'.ets');if(loaded.has(file))return loaded.get(file).exports;
  const module={exports:{}};loaded.set(file,module);
  const code=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
  const requireMock=name=>{
    if(mocks[name])return mocks[name];
    if(name==='./RecordingWav')return {recordingWavDuration:p=>durations.get(p)||duration,
      readCapturedPcm:(_p,start,end)=>fakeSamples(end-start),
      readWav16k:(_p,start,end)=>fakeSamples(Math.round(end*16000)-Math.floor(start*16000)),
      writeExact:(fd,data)=>io.writeSync(fd,data)};
    return load(path.relative(root,path.resolve(path.dirname(file),name)).replaceAll('\\','/'));
  };
  class FakeDate extends Date {static now(){return now;}}
  vm.runInNewContext('(function(require,module,exports){'+code+'\n})',
    {...clock,Date:FakeDate,Uint8Array,Float32Array,DataView,ArrayBuffer,console},{filename:file})(requireMock,module,module.exports);
  return module.exports;
}
const policy=load(base+'RecordingSystemAsrPolicy');
const actualPcm=policy.systemAsrPcm;
const {RecordingSystemAsrRunner:Runner}=load(base+'RecordingSystemAsrRunner');
const {RecordingLiveCheckpoint:Checkpoint}=load(base+'RecordingLiveCheckpoint');
async function test(name,fn){
  now=0;tasks.clear();files.clear();handles.clear();engines=[];logs=[];deferCreate=null;stallFinish=false;failFrame=false;startError=false;amplitude=.2;duration=120;
  await fn();assert.equal(tasks.size,0,'all timers released: '+name);assert.equal(handles.size,0);
  console.log('PASS '+name);tests++;
}
function startLive(seconds=130,updates=[]) {
  const runner=new Runner();const began=now;
  runner.start({audioPath:'/capture.wav',modelDir:'',language:'zh'},()=>Math.min(seconds*16000,Math.floor((now-began)*16)),v=>updates.push(v),()=>{});
  return runner;
}
function liveDisplayPage() {
  const source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),'utf8');
  const tree=ts.createSourceFile('page.ts',source.replace('struct RecordingPage','class RecordingPage'),ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='RecordingPage');
  const method=component.members.find(n=>ts.isMethodDeclaration(n)&&n.name?.getText(tree)==='updateLiveTranscript').getText(tree);
  const exported={};vm.runInNewContext(ts.transpileModule('exports.Page=class {'+method+'}',
    {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,{exports:exported});
  return new exported.Page();
}
(async()=>{
  await test('offline long mode, partial results and app-owned PCM input',()=>{
    const p=policy.systemAsrStartParams('r');assert.equal(p.extraParams.recognitionMode,1);
    assert.equal(p.extraParams.recognizerOption.enablePartialResult,true);assert.equal(p.audioInfo.sampleRate,16000);
    assert.equal(p.extraParams.maxAudioDuration,60000);
  });
  await test('PCM16 little endian, clipping and zero-padded final frame',()=>{
    const bytes=policy.systemAsrPcm(new Float32Array([-1,1,.5]));const view=new DataView(bytes.buffer);
    assert.equal(bytes.length,1280);assert.equal(view.getInt16(0,true),-32768);assert.equal(view.getInt16(2,true),32767);
    assert.equal(view.getInt16(4,true),16384);assert.equal(view.getInt16(6,true),0);
  });
  await test('only intentional replay trims boundary text, normal repeated phrases survive',()=>{
    assert.equal(policy.trimSystemAsrOverlap('今天去吃饭。','吃饭，然后散步',true),'然后散步');
    assert.equal(policy.trimSystemAsrOverlap('谢谢','谢谢',false),'谢谢');
  });
  await test('real-time partial text appears before stop; final tail is saved',async()=>{
    const r=startLive(6.013);await advance(3000);assert(r.recent().length>0);assert.equal(engines[0].stopped,false);
    await advance(3013);const result=r.finish(Math.floor(6.013*16000));await advance(2000);
    const value=await result;assert.equal(value.duration,Math.floor(6.013*16000)/16000);assert.equal(value.modelId,policy.SYSTEM_ASR_MODEL_ID);
    assert(value.segments.length>0);assert(engines[0].stopped);
  });
  await test('same-start live sentence updates the page for every hypothesis, including repeated words',async()=>{
    const page=liveDisplayPage(),r=new Runner(),began=now,updates=[];
    r.start({audioPath:'/capture.wav',modelDir:'',language:'zh'},()=>Math.floor((now-began)*16),v=>{
      updates.push(v);page.updateLiveTranscript(r,v);
    },()=>{});
    await advance(1000);const engine=engines[0],id=engine.params.sessionId;
    const hypotheses=['你好','你好，你好','你好，你好，你是谁','你好，你好，你是谁你是谁？'];
    for(const text of hypotheses){
      engine.listener.onResult(id,{result:text,isFinal:false,isLast:false});
      assert.equal(page.livePreviewText,text,'same-start partial must replace the displayed text');
      assert.equal(page.livePreviewStart,0);assert.equal(page.liveSegments.length,0,'hypothesis is outside immutable ForEach rows');
      assert.equal(updates.at(-1).preview.text,text);assert.equal(updates.at(-1).segments.length,0);
    }
    // A revision to a shorter hypothesis must also refresh; length is not a key.
    engine.listener.onResult(id,{result:'你好，你是谁？',isFinal:false,isLast:false});
    assert.equal(page.livePreviewText,'你好，你是谁？');r.cancel();
  });
  await test('finalization replaces preview with one committed row and retains the complete transcript',async()=>{
    const page=liveDisplayPage(),r=new Runner(),began=now;
    r.start({audioPath:'/capture.wav',modelDir:'',language:'zh'},()=>Math.min(32000,Math.floor((now-began)*16)),
      v=>page.updateLiveTranscript(r,v),()=>{});
    await advance(2000);const engine=engines[0],full='你好，你好，你是谁你是谁？后面的内容也在。';
    engine.finish=function(id){this.listener.onResult(id,{result:full,isFinal:true,isLast:true});this.listener.onComplete(id,'');};
    const done=r.finish(32000);await advance(100);const result=await done;
    assert.equal(page.livePreviewText,'');assert.equal(page.liveSegments.length,1);
    assert.equal(page.liveSegments[0].text,full);assert.equal(result.segments[0].text,full);
  });
  await test('mutable preview is bound to primitive ArkUI state outside the keyed history list',()=>{
    const source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),'utf8');
    assert(source.includes('@State private livePreviewText: string'));
    const list=source.indexOf('ForEach(this.liveSegments.slice('),end=source.indexOf('}, (segment: RecordingSegment): string',list);
    const preview=source.indexOf('Text(this.livePreviewText.slice(-100))',list);
    assert(list>=0&&end>list&&preview>end,'live preview must not inherit a stable ForEach item closure');
  });
  await test('long live recording rolls beyond 60 seconds, no silent one-minute stop',async()=>{
    const updates=[],r=startLive(182,updates);await advance(182000);const result=r.finish(182*16000);await advance(6000);
    const value=await result;assert.equal(value.duration,182);assert(engines[0].sessions.length>=4);
    assert(engines[0].sessions.every(s=>s.frames<=1375));assert(updates.filter(v=>v.kind==='checkpoint').length>=3);
  });
  await test('two-hour file stream stays bounded and releases the service',async()=>{
    // PCM conversion is exercised above. Avoid converting two hours of synthetic
    // samples just to verify bounded session scheduling on the virtual clock.
    duration=7200.013;fastAudio=true;policy.systemAsrPcm=()=>new Uint8Array(1280);
    try {
      let checkpoints=0;const r=new Runner();
      const promise=r.run({audioPath:'/file.wav',modelDir:'',language:'en'},'/draft',()=>{checkpoints++;});
      await advance(7350000);const value=await promise;assert.equal(value.duration,Math.floor(duration*16000)/16000);
      assert(value.segments.length>120);assert(checkpoints>value.segments.length);assert(engines[0].sessions.every(s=>s.frames<=1375));
      assert(new Checkpoint('/draft').restoreState(duration).processed<=duration*16000);
    } finally {fastAudio=false;policy.systemAsrPcm=actualPcm;}
  });
  await test('cancelled file resumes completed sessions instead of retranscribing all history',async()=>{
    duration=125;const first=new Runner();const p=first.run({audioPath:'/file.wav',modelDir:'',language:'zh'},'/draft',()=>{}).catch(e=>e);
    await advance(61000);first.cancel();assert((await p).message.includes('暂停'));
    const state=new Checkpoint('/draft').restoreState(duration);assert(state.processed>=54*16000);assert(state.analysis.segments.length>0);
    const r=new Runner();const continued=r.run({audioPath:'/file.wav',modelDir:'',language:'zh'},'/draft',()=>{});
    await advance(76000);const result=await continued;assert.equal(result.duration,125);
    assert(engines.at(-1).sessions.reduce((n,s)=>n+s.frames,0)<1900);
  });
  await test('cancellation retains visible text and ignores callbacks from a stale session',async()=>{
    const r=startLive();await advance(3000);const engine=engines[0],listener=engine.listener,id=engine.params.sessionId;
    r.cancel();const before=r.snapshot(3).segments.length;assert(before>0);
    listener.onResult(id,{result:'late',isFinal:true,isLast:true});assert.equal(r.snapshot(3).segments.length,before);
  });
  await test('cancel during engine creation shuts down the late engine without starting recognition',async()=>{
    deferCreate={};const r=startLive();r.cancel();const e=makeEngine();deferCreate.resolve(e);await advance(1);
    assert(e.stopped);assert.equal(e.sessions.length,0);
  });
  await test('synchronous native startup failure cannot leak a packet timer or report success',async()=>{
    startError=true;const r=startLive();await advance(100);
    assert(engines[0].stopped);await assert.rejects(()=>r.finish(1600),/service unavailable/);
  });
  await test('flush timeout rejects and preserves already visible transcript',async()=>{
    stallFinish=true;const r=startLive(3);await advance(3000);const p=r.finish(48000).catch(e=>e);await advance(22000);
    assert((await p).message.includes('超时'));assert(r.snapshot(3).segments.length>0);
  });
  await test('native feed error fails explicitly while prior text survives',async()=>{
    const r=startLive();await advance(3000);failFrame=true;await advance(100);
    assert(r.snapshot(3.1).segments.length>0);await assert.rejects(()=>r.finish(49600),/service write failure/);
  });
  await test('unfinalized partial output is not marked successful',async()=>{
    const r=startLive(3);await advance(3000);engines[0].finish=function(id){this.listener.onComplete(id,'');};
    const p=r.finish(48000).catch(e=>e);await advance(100);assert((await p).message.includes('未确认'));
  });
  await test('sentence callback plus identical last marker is not duplicated, actual repeated speech is retained',async()=>{
    const r=startLive(4);await advance(3000);const e=engines[0],id=e.params.sessionId;
    e.listener.onResult(id,{result:'谢谢。',isFinal:true,isLast:false});
    e.listener.onResult(id,{result:'谢谢。',isFinal:true,isLast:true});
    assert.equal(r.recent().at(-1).text,'谢谢。');
    await advance(500);e.listener.onResult(id,{result:'谢谢。',isFinal:true,isLast:false});
    assert.equal(r.recent().at(-1).text,'谢谢。谢谢。');r.cancel();
  });
  await test('system choice is available only without speaker separation; existing model remains selectable',()=>{
    const source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),'utf8');
    const tree=ts.createSourceFile('page.ts',source.replace('struct RecordingPage','class RecordingPage'),ts.ScriptTarget.Latest,true);
    const page=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='RecordingPage');
    const method=page.members.find(n=>ts.isMethodDeclaration(n)&&n.name?.getText(tree)==='useSystemAsr').getText(tree);
    const exported={};vm.runInNewContext(ts.transpileModule('exports.Page=class {'+method+'}',
      {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,{exports:exported});
    const p=new exported.Page();p.transcriptionEngine='system';p.separateSpeakers=false;assert(p.useSystemAsr());
    p.separateSpeakers=true;assert(!p.useSystemAsr());p.separateSpeakers=false;p.transcriptionEngine='sensevoice';assert(!p.useSystemAsr());
  });
  console.log(tests+' system ASR groups passed; device recognition quality/background execution not exercised.');
})().catch(e=>{console.error(e);process.exitCode=1;});
