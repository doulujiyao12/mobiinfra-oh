// Run production ArkTS logic with bounded file/audio/model doubles; no HAP or device execution.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require(process.argv[2] || 'typescript');
const {recordingArktsRules} = require('./recording_arkts_rules.cjs');
const root = path.resolve(__dirname, '..');
const base = 'entry/src/main/ets/utils/recording/';
const files = new Map(), handles = new Map(), dirs = new Set(['/app']);
const revisions = new WeakMap();let nextRevision=1;
let sequence = 10, maxRead = Infinity, writeFailure = false, captureEvents = {}, interrupts = {}, sent = [], calls = [], diarizationFixture = null;
let reportHook=null,availableCpus=8;const modelThreads=[];
let liveDecodeForTest=false;
const toBuffer = value => typeof value === 'string' ? Buffer.from(value) : Buffer.from(value);
const io = {
  OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 2, TRUNC: 4, READ_WRITE: 8 }, WhenceType: { SEEK_SET: 0 },
  accessSync: p => files.has(p) || dirs.has(p), mkdirSync: p => dirs.add(p),
  openSync(p, mode = 0) {
    if ((mode & 2) && !files.has(p)) files.set(p, Buffer.alloc(0));
    if (!files.has(p)) throw Error('ENOENT ' + p);
    if (mode & 4) files.set(p, Buffer.alloc(0));
    const handle = { fd: ++sequence }; handles.set(handle.fd, { p, cursor: 0 }); return handle;
  },
  async open(p, mode) { return this.openSync(p, mode); },
  closeSync(f) { assert(handles.delete(typeof f === 'number' ? f : f.fd)); },
  async close(f) { this.closeSync(f); },
  statSync(f) { const p = typeof f === 'number' ? handles.get(f).p : f,buffer=files.get(p);
    if(!revisions.has(buffer))revisions.set(buffer,nextRevision++);
    const revision=revisions.get(buffer);return {size:buffer.length,mtime:revision,ctime:revision,ino:BigInt(revision)}; },
  lseek(fd, offset) { handles.get(fd).cursor = offset; },
  readSync(fd, array, options = {}) {
    const h = handles.get(fd), src = files.get(h.p), start = h.cursor + (options.offset || 0);
    const n = Math.max(0, Math.min(array.byteLength, src.length - start, maxRead));
    new Uint8Array(array).set(src.subarray(start, start + n)); h.cursor = start + n; return n;
  },
  async read(...args) { return this.readSync(...args); },
  writeSync(fd, value, options = {}) {
    if (writeFailure) throw Error('disk full');
    const h = handles.get(fd), data = toBuffer(value), start = h.cursor + (options.offset || 0), old = files.get(h.p);
    const next = Buffer.alloc(Math.max(old.length, start + data.length)); old.copy(next); data.copy(next, start);
    files.set(h.p, next); h.cursor = start + data.length; return data.length;
  },
  async write(...args) { return this.writeSync(...args); },
  fsyncSync() {},
  readTextSync: p => files.get(p).toString('utf8'),
  renameSync(a,b) { files.set(b,files.get(a)); files.delete(a); },
  unlinkSync: p => files.delete(p), rmdirSync: p => dirs.delete(p),
  listFileSync(p) { return [...new Set([...files.keys(),...dirs].filter(x=>x.startsWith(p+'/')).map(x=>x.slice(p.length+1).split('/')[0]))]; },
  async copyFile(fd, dest) { files.set(dest, Buffer.from(files.get(handles.get(fd).p))); }
};
const storage = new Map();
const port = { postMessage: value => {sent.push(value);if(reportHook&&value.kind==='progress')reportHook(value);} };
const capturer = { on(type, cb) { captureEvents[type] = cb; }, async start(){}, async stop(){}, async release(){} };
const audio = { AudioSamplingRate:{SAMPLE_RATE_16000:16000}, AudioChannel:{CHANNEL_1:1},
  AudioSampleFormat:{SAMPLE_FORMAT_S16LE:1}, AudioEncodingType:{ENCODING_TYPE_RAW:0},SourceType:{SOURCE_TYPE_MIC:0},
  InterruptHint:{INTERRUPT_HINT_STOP:1,INTERRUPT_HINT_PAUSE:2}, async createAudioCapturer(){return capturer;} };
const noopClass = class {};
let screenFrames=[],screenMixed=null,screenStopped=false,screenError='',screenStarts=0,screenElapsed=0;
const audioNotices=[];
const screenNative={
  recordingAvailableCpus:()=>availableCpus,
  async startRecordingScreen(mixed){screenStarts++;screenMixed=mixed;screenStopped=false;screenElapsed=0;if(screenError)throw Error(screenError);},
  readRecordingScreen(){const frames=screenFrames;screenFrames=[];
    screenElapsed=Math.max(screenElapsed,...frames.map(f=>f.receivedMs));
    return {frames,elapsedMs:screenElapsed,stopped:screenStopped,error:''};},
  async stopRecordingScreen(){screenStopped=true;return this.readRecordingScreen();}
};
class DiarizationConfig { constructor(){ this.segmentation={pyannote:{}};this.embedding={};this.clustering={};} }
const sherpa = {
  SileroVadConfig: noopClass, TenVadConfig: noopClass, VadConfig:class{constructor(...args){modelThreads.push(args[4]);}},
  Vad: class {
    constructor(){this.queue=[];this.offset=0;this.start=-1;}
    reset(){this.offset=0;this.start=-1;} clear(){this.queue=[];}
    acceptWaveform(samples){
      const active=samples.some(x=>Math.abs(x)>.1);
      if(active&&this.start<0)this.start=this.offset;
      if(!active&&this.start>=0){this.queue.push({start:this.start,samples:new Float32Array(this.offset-this.start)});this.start=-1;}
      this.offset+=samples.length;
    }
    flush(){if(this.start>=0)this.queue.push({start:this.start,samples:new Float32Array(this.offset-this.start)});}
    isEmpty(){return this.queue.length===0;} front(){return this.queue[0];} pop(){this.queue.shift();}
  },
  OfflineSpeakerDiarizationConfig: DiarizationConfig,
  OfflineSpeakerDiarization: class {
    constructor(config){modelThreads.push(config.segmentation.numThreads,config.embedding.numThreads);}
    process(){calls.push('diarize');return diarizationFixture || [{start:0,end:2,speaker:0},{start:3,end:5,speaker:1}];}
  },
  OfflineRecognizerConfig: class { constructor(){this.modelConfig={senseVoice:{}};} },
  OfflineRecognizer: class {
    constructor(config){assert(['','zh'].includes(config.modelConfig.senseVoice.language));
      modelThreads.push(config.modelConfig.numThreads);calls.push('asr');}
    createStream(){return {acceptWaveform(w){assert.equal(w.sampleRate,16000);}};}
    decode(){if(!liveDecodeForTest)assert(sent.at(-1).message.includes('转写片段'),'ASR status precedes the actual decode');calls.push('decode');}
    getResult(){return {text:'<|zh|>测试转写',lang:'zh'};}
  },
  SpeakerEmbeddingExtractorConfig: noopClass,
  SpeakerEmbeddingExtractor: class {
    constructor(config){modelThreads.push(config.numThreads);}
    createStream(){return {acceptWaveform(){},inputFinished(){}};} isReady(){return true;}
    compute(){calls.push('embedding');return new Float32Array([1,0,0]);}
  }
};
const mocks = {
  '@kit.CoreFileKit': {fileIo:io, picker:{DocumentSelectOptions:class{},DocumentViewPicker:class{async select(){return [];}}}},
  '@kit.ArkTS': {JSON,url:{URL:{parseURL:value=>new URL(value)}},util:{generateRandomUUID:()=>crypto.randomUUID(),
    TextEncoder:class {encodeInto(text){return new TextEncoder().encode(text);}}},worker:{workerPort:port}},
  '@ohos.worker': {default:{workerPort:port}},
  '@kit.AudioKit':{audio},'@kit.MediaKit':{media:{}},
  '@kit.AbilityKit': {wantConstant:{Params:{PARAMS_STREAM:'stream'}}},
  '@kit.BasicServicesKit':{request:{}},
  '@kit.PerformanceAnalysisKit':{hilog:{info(){},debug(){},warn(){},error(){}}},
  '@kit.ArkData':{preferences:{}},
  '@kit.CryptoArchitectureKit':{cryptoFramework:{createMd(){const h=crypto.createHash('sha256');return {
    async update({data}){h.update(data);},async digest(){return {data:new Uint8Array(h.digest())};}};}}},
  'sherpa_onnx':sherpa,
  'libentry.so':{default:screenNative},
  '../AppLogger':{AppLogger:{info:(_tag,message)=>audioNotices.push(message),
    warn:(_tag,message)=>audioNotices.push(message),debug(){}}},
};
const loaded = new Map();
function load(relative, inWorker=false) {
  const p = path.resolve(root,relative.endsWith('.ets')?relative:relative+'.ets');
  if(loaded.has(p))return loaded.get(p);
  const result=ts.transpileModule(fs.readFileSync(p,'utf8'),{fileName:p.replace(/\.ets$/,'.ts'),reportDiagnostics:true,
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}});
  assert.equal((result.diagnostics||[]).filter(x=>x.category===ts.DiagnosticCategory.Error).length,0,p);
  const module={exports:{}};
  const scope={module,exports:module.exports,console,ArrayBuffer,Uint8Array,Float32Array,DataView,
    setTimeout,clearTimeout,setInterval,clearInterval,
    require:name=>mocks[name]||load(path.relative(root,path.resolve(path.dirname(p),name)),inWorker)};
  if(!inWorker)scope.AppStorage={get:k=>storage.get(k),setOrCreate:(k,v)=>storage.set(k,v)};
  vm.runInNewContext(result.outputText,scope,{filename:p});
  loaded.set(p,module.exports); return module.exports;
}
function wave({rate=16000,bits=16,channels=1,format=1,seconds=1,junk=false,silent=false}={}) {
  const data=Buffer.alloc(rate*seconds*channels*bits/8), align=channels*bits/8;
  for(let i=0;i<rate*seconds;i++)for(let c=0;c<channels;c++){
    const value=silent?0:.4*Math.sin(i*.04),p=i*align+c*bits/8;
    if(format===3)data.writeFloatLE(value,p);
    else if(bits===8)data[p]=Math.round(value*127)+128;
    else if(bits===16)data.writeInt16LE(Math.round(value*32767),p);
    else if(bits===24)data.writeIntLE(Math.round(value*8388607),p,3);
    else data.writeInt32LE(Math.round(value*2147483647),p);
  }
  const fmt=Buffer.alloc(24);fmt.write('fmt ');fmt.writeUInt32LE(16,4);fmt.writeUInt16LE(format,8);fmt.writeUInt16LE(channels,10);
  fmt.writeUInt32LE(rate,12);fmt.writeUInt32LE(rate*align,16);fmt.writeUInt16LE(align,20);fmt.writeUInt16LE(bits,22);
  const payload=Buffer.concat([fmt,...(junk?[Buffer.from('JUNK\x03\0\0\0abc\0','binary')]:[]),Buffer.from('data'),Buffer.from(Uint32Array.of(data.length).buffer),data]);
  const header=Buffer.alloc(12);header.write('RIFF');header.writeUInt32LE(payload.length+4,4);header.write('WAVE',8);
  return Buffer.concat([header,payload]);
}
let tests=0;
function selectedTest(name){return !process.env.RECORDING_TEST_FILTER||name.includes(process.env.RECORDING_TEST_FILTER);}
function test(name,fn){if(!selectedTest(name))return;fn();tests++;console.log('PASS',name);}
async function testAsync(name,fn){if(!selectedTest(name))return;await fn();tests++;console.log('PASS',name);}
(async()=>{
  const wav=load(base+'RecordingWav'),types=load(base+'RecordingTypes');
  test('Focused ArkTS guards catch raw rethrows, constructor properties and a custom Entry root',()=>{
    const parse = text => ts.createSourceFile('fixture.ets',text,ts.ScriptTarget.ES2021,true,ts.ScriptKind.ETS);
    const bad = parse('class A { constructor(private value: number) {} run() { try {} catch (e) { throw e; } } }');
    assert.equal(recordingArktsRules(ts,bad).length,2);
    const good = parse('class A { private value: number; constructor(value: number) { this.value=value; } run() { try {} catch(e) { throw new Error((e as Error).message); } } }');
    assert.equal(recordingArktsRules(ts,good).length,0);
    const badPage = parse('@Entry\n@Component\nstruct Page { build() { FrostedPage({}); } }');
    assert.equal(recordingArktsRules(ts,badPage).length,1);
  });
  test('WAV decode/downmix/resample handles PCM and float variants',()=>{
    for(const bits of [8,16,24,32])for(const channels of [1,2])for(const rate of [8000,16000,44100,48000]){
      files.set('/source',wave({bits,channels,rate,junk:true}));const out=wav.readWav16k('/source');
      assert.equal(out.length,16000);assert(out.every(x=>Number.isFinite(x)&&Math.abs(x)<=1));assert(out.some(x=>Math.abs(x)>.2));
    }
    files.set('/source',wave({format:3,bits:32}));assert.equal(wav.readWav16k('/source').length,16000);
  });
  test('Partial reads preserve exact file offsets',()=>{maxRead=7;files.set('/source',wave());assert.equal(wav.readWav16k('/source').length,16000);maxRead=Infinity;});
  test('Malformed, compressed, oversized and truncated files are rejected and closed',()=>{
    for(const value of [Buffer.from('not wave'),wave({format:6}),wave().subarray(0,80)]){
      files.set('/bad',value);assert.throws(()=>wav.readWav16k('/bad'));
    }
    assert.equal(handles.size,0);
  });
  test('Voice comparison validates dimensions, silence and finite values',()=>{
    assert.equal(types.voiceSimilarity([1,0],[1,0]),1);assert.equal(types.voiceSimilarity([1,0],[0,1]),0);
    for(const pair of [[[],[]],[[1],[1,2]],[[0],[0]],[[NaN],[1]]])assert.throws(()=>types.voiceSimilarity(...pair));
  });
  test('VAD intersections preserve overlap and split long turns',()=>{
    const turns=types.recordingTurns([{start:0,end:45,speaker:0},{start:2,end:6,speaker:1}],[{start:1,end:44}]);
    assert(turns.every(s=>s.end-s.start<=20));assert(turns.some(s=>s.speaker===1));assert.equal(turns[0].start,1);
  });
  const Store=load(base+'RecordingStore').RecordingStore,store=new Store('/app');
  await testAsync('Import persists an independent copy, survives reopening, and deletes only its own files',async()=>{
    files.set('file:///sent.wav',wave());const r=await store.importWav('file:///sent.wav');assert.equal(r.duration,1);
    assert.equal(new Store('/app').list().length,1);files.delete('file:///sent.wav');assert(files.has(store.audioPath(r.id)));
    const other=store.create('test');files.set(store.audioPath(other.id),wave());store.save(other);
    store.remove(r.id);assert.equal(store.list().length,1);assert.throws(()=>store.remove('../workflows'));
    assert(files.has(store.audioPath(other.id)));store.remove(other.id);
  });
  await testAsync('Failed import closes descriptors and rolls back its draft',async()=>{
    files.set('/source',wave());writeFailure=true;await assert.rejects(store.importWav('/source'));writeFailure=false;
    assert.equal(handles.size,0);assert.equal(store.list().length,0);
  });
  const Inbox=load(base+'RecordingInbox').RecordingInbox;
  test('WAV Want routing does not steal profile JSON or remote URLs',()=>{
    assert(Inbox.accepts({action:'ohos.want.action.sendData',type:'audio/wav',parameters:{stream:'file:///voice'}}));
    assert(Inbox.accepts({action:'ohos.want.action.viewData',uri:'file:///a.WAV'}));
    assert(!Inbox.accepts({action:'ohos.want.action.sendData',type:'application/json',uri:'file:///profile.json'}));
    assert(!Inbox.accepts({action:'ohos.want.action.viewData',uri:'https://example.com/a.wav'}));
  });
  await testAsync('Incoming WAV is copied before its temporary permission expires',async()=>{
    files.set('file:///received.wav',wave());await Inbox.receive({filesDir:'/app'},{parameters:{stream:'file:///received.wav'}});
    assert(storage.get('recordingAnalysisInbox'));assert.equal(store.list().length,1);
    for(const record of store.list())store.remove(record.id);
  });
  const Capture=load(base+'RecordingCapture').RecordingCapture;
  const audioSources=load(base+'RecordingAudioSource');
  function pcm(value,count=1600){const buffer=new ArrayBuffer(count*2),view=new DataView(buffer);
    for(let i=0;i<count;i++)view.setInt16(i*2,value,true);return buffer;}
  test('Audio mixer aligns timestamped tracks without doubling time and preserves system-only gain',()=>{
    for(const mixed of [false,true]){
      const mixer=new audioSources.RecordingAudioMixer(mixed),out=[];
      mixer.append([{mic:false,timestampMs:1000,receivedMs:100,data:pcm(30000)},
        {mic:true,timestampMs:1000,receivedMs:100,data:pcm(20000)}]);
      mixer.drain(true,b=>out.push(Buffer.from(b)));const result=Buffer.concat(out);
      assert.equal(result.length,3200);assert.equal(result.readInt16LE(0),mixed?25000:30000);
      assert.equal(result.readInt16LE(result.length-2),mixed?25000:30000);
    }
  });
  test('Audio mixer tolerates skew, pads gaps, and rejects invalid buffers',()=>{
    const mixer=new audioSources.RecordingAudioMixer(true),out=[];
    mixer.append([{mic:true,timestampMs:1050,receivedMs:150,data:pcm(10000)}]);mixer.drain(false,b=>out.push(Buffer.from(b)));
    mixer.append([{mic:false,timestampMs:1000,receivedMs:160,data:pcm(20000)}]);
    mixer.append([{mic:false,timestampMs:1300,receivedMs:400,data:pcm(-20000)}]);mixer.drain(true,b=>out.push(Buffer.from(b)));
    const result=Buffer.concat(out);assert.equal(result.length,12800);assert.equal(result.readInt16LE(0),10000);
    assert.equal(result.readInt16LE(1600),15000);assert.equal(result.readInt16LE(6400),0);
    assert.equal(result.readInt16LE(9600),-10000);
    assert.throws(()=>new audioSources.RecordingAudioMixer(false).append([{mic:false,timestampMs:NaN,receivedMs:0,data:pcm(1)}]),/格式/);
    assert.throws(()=>new audioSources.RecordingAudioMixer(false).append([{mic:false,timestampMs:0,receivedMs:0,data:pcm(1,64001)}]),/过大/);
  });
  test('System playback resumes after a long silent gap without aborting or shortening the recording',()=>{
    const mixer=new audioSources.RecordingAudioMixer(false),out=[];
    const write=b=>out.push(Buffer.from(b));
    mixer.append([{mic:false,timestampMs:1000,receivedMs:100,data:pcm(12000)}]);
    for(let t=100;t<=6000;t+=100){mixer.advance(t);mixer.drain(false,write);}
    mixer.append([{mic:false,timestampMs:7000,receivedMs:6100,data:pcm(20000)}]);
    mixer.advance(6100);while(mixer.drain(true,write)){}
    const result=Buffer.concat(out);assert.equal(result.length,6100*32);
    assert.equal(result.readInt16LE(0),12000);assert.equal(result.readInt16LE(3000*32),0);
    assert.equal(result.readInt16LE(6000*32),20000);assert.equal(mixer.takeNotice(),'');
  });
  test('Late mixed audio retains its uncommitted tail instead of stopping both sources',()=>{
    const mixer=new audioSources.RecordingAudioMixer(true),out=[],write=b=>out.push(Buffer.from(b));
    mixer.append([{mic:true,timestampMs:1000,receivedMs:1000,data:pcm(10000,16000)}]);
    mixer.advance(1000);mixer.drain(false,write);
    mixer.append([{mic:false,timestampMs:1400,receivedMs:1000,data:pcm(20000,4800)}]);
    while(mixer.drain(true,write)){}
    const result=Buffer.concat(out);assert.equal(result.length,32000);
    assert.equal(result.readInt16LE(450*32),5000);assert.equal(result.readInt16LE(550*32),15000);
    assert.equal(result.readInt16LE(750*32),5000);assert.match(mixer.takeNotice(),/late_samples=1600/);
  });
  test('Different stream clock origins and timestamp resets re-anchor only the affected source',()=>{
    const mixer=new audioSources.RecordingAudioMixer(true),out=[],write=b=>out.push(Buffer.from(b));
    mixer.append([{mic:false,timestampMs:1000000,receivedMs:100,data:pcm(20000)},
      {mic:true,timestampMs:1000,receivedMs:100,data:pcm(10000)}]);
    mixer.advance(100);mixer.drain(false,write);
    mixer.append([{mic:false,timestampMs:0,receivedMs:200,data:pcm(16000)},
      {mic:true,timestampMs:1100,receivedMs:200,data:pcm(8000)}]);
    mixer.advance(200);while(mixer.drain(true,write)){}
    const result=Buffer.concat(out);assert.equal(result.length,6400);
    assert.equal(result.readInt16LE(0),15000);assert.equal(result.readInt16LE(3200),12000);
    assert.match(mixer.takeNotice(),/clock_realignments=2/);
  });
  test('Capture clock preserves silence, ignores wall-clock changes, and bounds work and real PCM storage',()=>{
    const mixer=new audioSources.RecordingAudioMixer(false);let bytes=0;
    mixer.advance(120000);assert.equal(mixer.drain(false,b=>bytes+=b.byteLength),true);assert.equal(bytes,64000);
    while(mixer.drain(true,b=>bytes+=b.byteLength)){}assert.equal(bytes,120000*32);
    const bounded=new audioSources.RecordingAudioMixer(true);
    assert.throws(()=>{for(let i=0;i<81;i++)bounded.append([{mic:false,timestampMs:i*100,receivedMs:(i+1)*100,data:pcm(1)}]);},/跟上/);
    const frozen=new audioSources.RecordingAudioMixer(false),blocks=[];
    for(let i=0;i<20;i++){
      frozen.append([{mic:false,timestampMs:100,receivedMs:(i+1)*100,data:pcm(3000)}]);
      frozen.advance((i+1)*100);frozen.drain(false,b=>blocks.push(Buffer.from(b)));
    }
    while(frozen.drain(true,b=>blocks.push(Buffer.from(b)))){}
    assert.equal(Buffer.concat(blocks).length,64000);assert.match(frozen.takeNotice(),/clock_realignments=19/);
  });
  await testAsync('System and mixed capture reuse the WAV writer and preserve the final buffered tail',async()=>{
    for(const source of ['system','mixed']){
      screenError='';const capture=new Capture();await capture.start('/'+source,()=>{},msg=>assert.fail(msg),source);
      assert.equal(screenMixed,source==='mixed');
      screenFrames=[{mic:false,timestampMs:500,receivedMs:1000,data:pcm(16000,16000)}];
      if(source==='mixed')screenFrames.push({mic:true,timestampMs:500,receivedMs:1000,data:pcm(8000,16000)});
      assert.equal(await capture.stop(),1);assert.equal(await capture.stop(),1);assert.equal(handles.size,0);
      assert.equal(files.get('/'+source).readInt16LE(44),source==='mixed'?12000:16000);
    }
  });
  await testAsync('System-only silence keeps the capture duration and clock recovery produces debug diagnostics',async()=>{
    const silent=new Capture();await silent.start('/system-silent',()=>{},msg=>assert.fail(msg),'system');
    screenElapsed=6000;assert.equal(await silent.stop(),6);
    assert.equal(files.get('/system-silent').length,44+6000*32);assert.equal(handles.size,0);
    const mixed=new Capture();await mixed.start('/system-clock-reset',()=>{},msg=>assert.fail(msg),'mixed');
    screenFrames=[{mic:false,timestampMs:1000000,receivedMs:100,data:pcm(20000)},
      {mic:true,timestampMs:0,receivedMs:100,data:pcm(10000)}];
    assert.equal(await mixed.stop(),.1);assert.match(audioNotices.at(-1),/clock_realignments=1/);
    assert.equal(files.get('/system-clock-reset').readInt16LE(44),15000);
  });
  await testAsync('Denied system authorization never falls back to the microphone and releases the WAV file',async()=>{
    screenError='SYSTEM_AUDIO_CANCELLED';const before=Object.keys(captureEvents).length;
    await assert.rejects(new Capture().start('/denied',()=>{},()=>{},'system'),/取消/);
    assert.equal(handles.size,0);assert.equal(Object.keys(captureEvents).length,before);screenError='';
    assert.equal(audioSources.recordingAudioSource('old-setting'),'environment');
  });
  await testAsync('Cancelling pending microphone creation or system authorization cannot start a late recorder',async()=>{
    const create=audio.createAudioCapturer;let release,started=0,released=0;
    audio.createAudioCapturer=()=>new Promise(resolve=>release=resolve);
    const mic=new Capture(),pending=mic.start('/cancel-mic',()=>{},()=>{}),rejected=assert.rejects(pending,/取消/);
    await mic.stop();release({release:async()=>{released++;},start:async()=>{started++;}});await rejected;
    assert.equal(started,0);assert.equal(released,1);assert.equal(handles.size,0);audio.createAudioCapturer=create;
    const start=screenNative.startRecordingScreen;screenNative.startRecordingScreen=()=>new Promise(resolve=>release=resolve);
    const system=new Capture(),waiting=system.start('/cancel-system',()=>{},()=>{},'system'),cancelled=assert.rejects(waiting,/取消/);
    await system.stop();release();await cancelled;assert.equal(handles.size,0);screenNative.startRecordingScreen=start;
  });
  await testAsync('Page requests microphone only for environment/mixed and persists the selected source',async()=>{
    const text=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),'utf8').replace('struct RecordingPage','class RecordingPage');
    const tree=ts.createSourceFile('page.ts',text,ts.ScriptTarget.Latest,true);
    const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='RecordingPage');
    const method=component.members.filter(n=>ts.isMethodDeclaration(n)&&['startRecording','clockTime','useSystemAsr'].includes(n.name?.getText(tree))).map(n=>n.getText(tree)).join('\n');
    for(const source of ['environment','mixed','system']){
      let permissions=0,saved=null,started=null;const exported={};
      vm.runInNewContext(ts.transpileModule('exports.Page=class {'+method+'}',{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,
        {exports:exported,Date,recordingAudioSource:audioSources.recordingAudioSource,setInterval:()=>1,
          abilityAccessCtrl:{createAtManager:()=>({requestPermissionsFromUser:async()=>{permissions++;return {authResults:[0]};}})},
          appBackgroundTasks:{set:async()=>{}}});
      const page=new exported.Page();Object.assign(page,{busy:false,audioSource:source,alive:true,epoch:0,
        store:{create:()=>({id:'fixture'}),audioPath:()=>'/audio',save:r=>{saved=cloneRecord(r);},remove(){}},
        playback:{stop:async()=>{}},capture:{start:async(_path,_stop,_error,mode)=>{started=mode;},stop:async()=>0},
        getUIContext:()=>({getHostContext:()=>({})}),context:()=>({}),message:e=>{throw e;},reload(){}});
      await page.startRecording();assert.equal(permissions,source==='system'?0:1);assert.equal(started,source);
      assert.equal(saved.audioSource,source);assert.equal(page.recording,true);assert.equal(page.startingRecording,false);
    }
    function cloneRecord(value){return JSON.parse(JSON.stringify(value));}
  });
  await testAsync('Speaker separation defaults off, requires approval to enable, and cancellation restores the switch',async()=>{
    const source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets'),'utf8');
    assert(source.includes("PersistentStorage.persistProp('recordingSpeakerSeparation', false)"));
    const tree=ts.createSourceFile('page.ts',source.replace('struct RecordingPage','class RecordingPage'),ts.ScriptTarget.Latest,true);
    const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='RecordingPage');
    const method=component.members.find(n=>ts.isMethodDeclaration(n)&&n.name?.getText(tree)==='setSpeakerSeparation').getText(tree);
    let choice=0,dialogs=0,release;const exported={};
    vm.runInNewContext(ts.transpileModule('exports.Page=class {'+method+'}',{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText,
      {exports:exported,AppTheme:{dialogText:s=>s},promptAction:{showDialog:async options=>{
        dialogs++;assert(options.message.includes('可能不准确')&&options.message.includes('增加转写耗时'));
        return choice===-1?new Promise(resolve=>release=resolve):{index:choice};
      }}});
    const page=new exported.Page();Object.assign(page,{alive:true,busy:false,recording:false,separateSpeakers:false,
      speakerSwitchOn:false,confirmingSpeakerSeparation:false});
    await page.setSpeakerSeparation(true);assert.equal(page.separateSpeakers,false);assert.equal(page.speakerSwitchOn,false);
    choice=-1;const pending=page.setSpeakerSeparation(true);assert.equal(page.separateSpeakers,false);
    release({index:1});await pending;assert.equal(page.separateSpeakers,true);assert.equal(page.speakerSwitchOn,true);
    await page.setSpeakerSeparation(false);assert.equal(page.separateSpeakers,false);assert.equal(dialogs,2);
    page.busy=true;await page.setSpeakerSeparation(true);assert.equal(dialogs,2);assert.equal(page.separateSpeakers,false);
  });
  await testAsync('Recording stop finalizes WAV header at byte zero and releases microphone',async()=>{
    let capture=new Capture();await capture.start('/capture',()=>{},msg=>assert.fail(msg));
    captureEvents.readData(new ArrayBuffer(32000));assert.equal(await capture.stop(),1);assert.equal(await capture.stop(),1);
    const file=io.openSync('/capture');assert.equal(wav.inspectWav(file.fd).bytes,32000);io.closeSync(file);assert.equal(handles.size,0);
  });
  await testAsync('System recording interruption still finalizes captured audio',async()=>{
    let stopped;
    const previous=capturer.stop;
    capturer.stop=async()=>{throw Error('already interrupted');};
    const capture=new Capture();await capture.start('/interrupted',()=>{stopped=capture.stop();},msg=>assert.fail(msg));
    captureEvents.readData(new ArrayBuffer(32000));
    captureEvents.audioInterrupt({hintType:audio.InterruptHint.INTERRUPT_HINT_STOP});
    assert.equal(await stopped,1);assert.equal(handles.size,0);capturer.stop=previous;
  });
  await testAsync('Partial header writes still produce a complete playable microphone WAV',async()=>{
    const write=io.writeSync;
    io.writeSync=(fd,value)=>write(fd,Buffer.from(value).subarray(0,13));
    try{
      const capture=new Capture();await capture.start('/partial-header',()=>{},msg=>assert.fail(msg));
      captureEvents.readData(new ArrayBuffer(32000));assert.equal(await capture.stop(),1);
      const file=io.openSync('/partial-header');assert.equal(wav.inspectWav(file.fd).bytes,32000);io.closeSync(file);
    }finally{io.writeSync=write;}
    assert.equal(handles.size,0);
  });
  await testAsync('Player initialization failure closes the opened recording',async()=>{
    mocks['@kit.MediaKit'].media.createAVPlayer=async()=>{throw Error('unavailable');};
    const Player=load(base+'RecordingPlayback').RecordingPlayback;
    files.set('/playback',wave());await assert.rejects(new Player().play('/playback',0,0,()=>{},()=>{}));
    assert.equal(handles.size,0);
  });
  await testAsync('Models reject a wrong digest before publishing a ready receipt',async()=>{
    const {RecordingModels,RECORDING_MODELS}=load(base+'RecordingModels');const models=new RecordingModels({filesDir:'/app'});
    assert.equal(models.readyCount(),0);
    for(const m of RECORDING_MODELS)if(m.sha256)assert.match(m.sha256,/^[0-9a-f]{64}$/);
    files.set('/model.part',Buffer.from('bad'));await assert.rejects(models.accept('/model.part',RECORDING_MODELS[0],'bad'));
    assert.equal(models.readyCount(),0);
  });
  test('Model sources normalize repository links and persist without changing integrity checks',()=>{
    const {RecordingModels,RECORDING_MODELS,DEFAULT_RECORDING_MODEL_URL,recordingModelBaseUrl,recordingModelDownloadUrl}=load(base+'RecordingModels');
    const models=new RecordingModels({filesDir:'/app'});
    assert.equal(models.downloadBaseUrl(),DEFAULT_RECORDING_MODEL_URL);
    const repo='https://modelscope.cn/models/fengerhu1/recording-analysis-models';
    assert.equal(recordingModelBaseUrl(' '+repo+'/files/ '),repo+'/resolve/master');
    assert.equal(recordingModelDownloadUrl(repo,RECORDING_MODELS[0]),repo+'/resolve/master/sensevoice.int8.onnx');
    const custom='http://192.168.1.2:9123/recording-models';
    assert.equal(models.setDownloadBaseUrl(custom+'/'),custom);
    assert.equal(new RecordingModels({filesDir:'/app'}).downloadBaseUrl(),custom);
    for(const invalid of ['', 'modelscope.cn/models/owner/name', 'ftp://host/models', 'https://',
      'https://user:password@host/models', 'https://host/models?token=secret', 'https://host/models#files']) {
      assert.throws(()=>models.setDownloadBaseUrl(invalid));
      assert.equal(models.downloadBaseUrl(),custom);
    }
    assert.equal(models.readyCount(),0);
    files.set('/app/recording-models/download-source.json',Buffer.from('{broken'));
    assert.equal(models.downloadBaseUrl(),DEFAULT_RECORDING_MODEL_URL);
    assert.equal(handles.size,0);
  });
  await testAsync('Download retries use the saved source and surface the failing model and error code',async()=>{
    const {RecordingModels}=load(base+'RecordingModels');
    const models=new RecordingModels({filesDir:'/app'}),requested=[];
    mocks['@kit.BasicServicesKit'].request.downloadFile=async(context,config)=>{
      requested.push(config.url);files.set(config.filePath,Buffer.from('partial'));
      const events={};setImmediate(()=>events.fail(8));
      return {on:(event,callback)=>{events[event]=callback;},delete:async()=>true};
    };
    models.setDownloadBaseUrl('https://first.example/models');
    await assert.rejects(models.prepare(()=>{}),/多语种转写：下载失败（8）.*更换模型下载地址/);
    assert(!files.has('/app/recording-models/sensevoice.int8.onnx.part'));
    models.setDownloadBaseUrl('https://second.example/models');
    await assert.rejects(models.prepare(()=>{}),/下载失败（8）/);
    assert.deepEqual(requested,['https://first.example/models/sensevoice.int8.onnx','https://second.example/models/sensevoice.int8.onnx']);
    assert.equal(models.readyCount(),0);assert.equal(handles.size,0);
  });
  await testAsync('Model downloads supply a client User-Agent accepted by the model host',async()=>{
    const {RecordingModels,RECORDING_MODELS,DEFAULT_RECORDING_MODEL_URL,recordingModelDownloadUrl}=load(base+'RecordingModels');
    const models=new RecordingModels({filesDir:'/app'}),requested=[];
    mocks['@kit.BasicServicesKit'].request.downloadFile=async(context,config)=>{
      requested.push(config);
      const events={},identified=/^ClawMate\//.test(config.header?.['User-Agent']||'');
      setImmediate(()=>{if(identified){files.set(config.filePath,Buffer.from('model response'));events.complete();}else events.fail(8);});
      return {on:(event,callback)=>{events[event]=callback;},delete:async()=>true};
    };
    await models.download(recordingModelDownloadUrl(DEFAULT_RECORDING_MODEL_URL,RECORDING_MODELS[0]),'/ua.part',()=>{});
    assert.equal(files.get('/ua.part').toString(),'model response');
    assert.equal(requested[0].header['User-Agent'],'ClawMate/1.0 (HarmonyOS; recording models)');
    assert.equal(requested[0].header.Accept,'*/*');
    assert(!('Authorization' in requested[0].header));assert(!('Cookie' in requested[0].header));
    assert.equal(models.readyCount(),0);
  });
  await testAsync('Model preparation reports byte-weighted monotonic progress and reaches 100 only after verification',async()=>{
    const {RecordingModels,RECORDING_MODELS}=load(base+'RecordingModels');
    const models=new RecordingModels({filesDir:'/progress'}),updates=[],verified=[];let requested=0,lateUpdates=0;
    models.hash=async p=>RECORDING_MODELS.find(m=>p.endsWith(m.name)||p.endsWith(m.name+'.part')).sha256;
    const accept=models.accept.bind(models);models.accept=async(...args)=>{await accept(...args);verified.push(args[1].name);};
    mocks['@kit.BasicServicesKit'].request.downloadFile=async(_ctx,config)=>{
      const item=RECORDING_MODELS.find(m=>config.url.endsWith(m.name)),events={};requested++;
      setImmediate(()=>{
        events.progress(item.bytes/2,0);events.progress(item.bytes/4,0);
        const data=item.name==='tokens.txt'?Buffer.from('<unk> 0\n'+Array.from({length:25054},(_,i)=>'token'+i+' '+(i+1)).join('\n')+'\n'):Buffer.from('fixture');
        files.set(config.filePath,data);events.complete();
        lateUpdates=updates.length;events.progress(item.bytes,0);assert.equal(updates.length,lateUpdates);
      });
      return {on:(event,cb)=>{events[event]=cb;},delete:async()=>true};
    };
    await models.prepare(()=>{},'https://models.example/files',p=>{updates.push(p);if(p.percent===100)assert.equal(verified.length,5);});
    assert.equal(requested,5);assert.equal(models.readyCount(),5);assert.equal(updates[0].percent,0);assert.equal(updates.at(-1).percent,100);
    assert(updates.some(p=>p.percent>40&&p.percent<50),'large first model contributes its actual byte share');
    assert(updates.every((p,i)=>i===0||p.percent>=updates[i-1].percent));
    assert(updates.slice(0,-1).every(p=>p.percent<100));assert.equal(updates.at(-1).totalBytes,281327856);
    const before=requested;await models.prepare(()=>{},'https://models.example/files',()=>{});assert.equal(requested,before,'verified cache is reused');
    for(const m of RECORDING_MODELS){files.delete(models.directory+'/'+m.name);files.delete(models.directory+'/'+m.name+'.json');}
    assert.equal(handles.size,0);
  });
  await testAsync('Failed model download never reports completed progress and removes its partial file',async()=>{
    const {RecordingModels,RECORDING_MODELS}=load(base+'RecordingModels'),models=new RecordingModels({filesDir:'/progress-failure'}),updates=[];
    mocks['@kit.BasicServicesKit'].request.downloadFile=async(_ctx,config)=>{
      const events={};setImmediate(()=>{
        files.set(config.filePath,Buffer.from('partial'));events.progress(RECORDING_MODELS[0].bytes/2,0);events.fail(8);events.progress(RECORDING_MODELS[0].bytes,0);
      });return {on:(event,cb)=>{events[event]=cb;},delete:async()=>true};
    };
    await assert.rejects(models.prepare(()=>{},'https://models.example/files',p=>updates.push(p)),/下载失败/);
    assert(updates.some(p=>p.percent>0));assert(updates.every(p=>p.percent<100));assert.equal(models.readyCount(),0);
    assert(!files.has(models.directory+'/'+RECORDING_MODELS[0].name+'.part'));
  });
  test('Summary titles persist for automatic names while manual and unfamiliar legacy names are retained',()=>{
    const summary={title:'会议\n  复盘',overview:'内容',keyPoints:[],decisions:[],actionItems:[],openQuestions:[],model:'fixture',generatedAt:'now'};
    const record=store.create('录制');record.title='录音 18:06';files.set(store.audioPath(record.id),wave());
    types.applyRecordingSummary(record,summary);store.save(record);
    assert.equal(new Store('/app').list().find(r=>r.id===record.id).title,'会议 复盘');
    record.title='我自己的名称';record.titleEdited=true;types.applyRecordingSummary(record,summary);assert.equal(record.title,'我自己的名称');
    for(const title of ['录音 11/3/2026, 6:06:30 PM','手表录音 2026/11/3 18:06:30']){
      const legacy={title};types.applyRecordingSummary(legacy,summary);assert.equal(legacy.title,'会议 复盘');
    }
    const legacy={title:'原先手动命名的会议'};types.applyRecordingSummary(legacy,summary);assert.equal(legacy.title,'原先手动命名的会议');
    const empty={title:'录音 18:06'};types.applyRecordingSummary(empty,{...summary,title:'  '});assert.equal(empty.title,'录音 18:06');
    store.remove(record.id);
  });
  await testAsync('List rename and delete target the swiped recording, preserve another open record and require confirmation',async()=>{
    const filename=path.join(root,'entry/src/main/ets/pages/recording/RecordingPage.ets');
    const source=fs.readFileSync(filename,'utf8').replace('struct RecordingPage','class RecordingPage');
    const tree=ts.createSourceFile('page.ts',source,ts.ScriptTarget.Latest,true),component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='RecordingPage');
    const names=['beginRename','finishRename','remove','recordTitle','clockTime','refreshSelected','reload','message','recordingSearchActive'];
    const methods=component.members.filter(n=>ts.isMethodDeclaration(n)&&names.includes(n.name?.getText(tree))).map(n=>n.getText(tree)).join('\n');
    let confirmation=0;const exported={};
    vm.runInNewContext(ts.transpileModule('exports.Page=class {'+methods+'}',{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,
      {exports:exported,Date,recordingUsesAutomaticTitle:types.recordingUsesAutomaticTitle,promptAction:{showDialog:async()=>({index:confirmation})}});
    const open=store.create('录制'),target=store.create('录制');
    for(const r of [open,target]){files.set(store.audioPath(r.id),wave());store.save(r);}
    const page=new exported.Page();Object.assign(page,{alive:true,busy:false,selected:open,store,reference:null,
      recordingListScroller:{closeAllSwipeActions(){}},playback:{stop:async()=>{}},records:[],
      recordingAiSearch:false,recordingSearchQuery:'',recordingSearchHits:[],refreshRecordingCalendar(){}});
    page.beginRename(target);page.editTitle='项目会议';page.finishRename();
    assert.equal(page.selected.id,open.id);assert.equal(store.list().find(r=>r.id===target.id).title,'项目会议');
    assert.equal(store.list().find(r=>r.id===target.id).titleEdited,true);
    await page.remove(target);assert(files.has(store.audioPath(target.id)),'cancel keeps the file');
    confirmation=1;await page.remove(target);assert(!files.has(store.audioPath(target.id)));assert(files.has(store.audioPath(open.id)));
    assert.equal(page.selected.id,open.id);store.remove(open.id);
  });
  // Real workers have no ArkUI globals. Do not stub their logger dependency:
  // otherwise AppLogger -> DebugSettings -> AppStorage misuse is invisible.
  load('entry/src/main/ets/workers/RecordingAnalysisWorker',true);
  test('Production worker wires VAD, diarization, ASR, embeddings and retains unidentified speech',()=>{
    files.set('/speech',wave({seconds:8}));sent=[];calls=[];
    port.onmessage({data:{audioPath:'/speech',modelDir:'/models',language:'auto',diarization:true}});
    const message=sent.at(-1);assert.equal(message.kind,'done',message.message);assert(message.result.segments.some(s=>s.speaker===-1));
    const loading=sent.findIndex(s=>s.message==='加载人声检测模型');
    const detecting=sent.findIndex(s=>s.message.startsWith('检测人声与停顿 ·'));
    assert(loading>=0&&detecting>loading);
    assert(sent.some(s=>s.message==='检测人声与停顿 · 8.0 / 8.0 秒'));
    assert(message.result.segments.every(s=>s.text==='测试转写'));assert(message.result.speakers.some(s=>s.embedding.length===3));
    assert(calls.includes('diarize')&&calls.includes('asr')&&calls.includes('embedding'));assert.equal(handles.size,0);
  });
  test('Worker without AppStorage finishes saving and emits diagnostics separately from progress',()=>{
    files.set('/worker-storage',wave({seconds:8}));sent=[];calls=[];
    port.onmessage({data:{audioPath:'/worker-storage',modelDir:'/models',language:'auto',diarization:true}});
    assert.equal(sent.at(-1).kind,'done',sent.at(-1).message);
    const saved=JSON.parse(files.get('/worker-storage.analysis.json'));
    assert.equal(saved.completed,saved.total);assert(saved.analysis.segments.length>0);
    const diagnostic=sent.filter(value=>value.kind==='diagnostic');
    assert.equal(diagnostic.length,1);assert(diagnostic[0].message.includes('diarization:'));
    assert(sent.some(value=>value.kind==='progress'&&value.message==='本段已保存'));
    sent=[];calls=[];port.onmessage({data:{audioPath:'/worker-storage',modelDir:'/models',language:'auto',diarization:true}});
    assert.equal(sent.at(-1).kind,'done');assert.equal(calls.length,0,'already saved blocks remain recoverable');
  });
  test('Silent audio produces a successful empty result without hallucinated speakers',()=>{
    files.set('/silence',wave({silent:true}));sent=[];port.onmessage({data:{audioPath:'/silence',modelDir:'/models',language:'auto'}});
    assert.equal(sent.at(-1).kind,'done');assert.equal(sent.at(-1).result.speakers.length,0);
  });
  const performance=load(base+'RecordingPerformance');
  test('Inference threads follow available CPUs, reserve capacity and never exceed four',()=>{
    for(const [cpus,threads] of [[1,1],[2,2],[3,2],[4,3],[6,4],[8,4],[14,4],[0,3],[NaN,3]]){
      assert.equal(performance.recordingInferenceThreads(cpus),threads);
    }
    availableCpus=8;modelThreads.length=0;files.set('/threads',wave({seconds:8}));sent=[];
    port.onmessage({data:{audioPath:'/threads',modelDir:'/models',language:'auto',diarization:true}});
    assert.equal(sent.at(-1).kind,'done');assert(modelThreads.length>=5);assert(modelThreads.every(n=>n===4));
    assert(sent.at(-1).result.timings.some(t=>t.stage==='diarization'&&t.threads===4));
    assert(sent.at(-1).result.timings.some(t=>t.stage==='asr'&&t.audioSeconds>0));
  });
  const speechTimeline=load(base+'RecordingSpeechTimeline');
  test('Diarization skips long silence while restoring original times and overlapping speakers',()=>{
    const input=new Float32Array(100*16000);input.fill(.4,10*16000,12*16000);input.fill(.7,80*16000,83*16000);
    const packed=speechTimeline.packRecordingSpeech(input,[{start:10,end:12},{start:80,end:83}]);
    assert.equal(packed.samples.length/16000,7.5);assert.equal(packed.spans.length,2);
    assert.equal(packed.samples[8000],input[10*16000]);
    const turns=speechTimeline.restoreRecordingSpeechTurns([
      {start:0,end:7.5,speaker:0},{start:4,end:7,speaker:1}],packed.spans);
    assert(turns.some(t=>t.speaker===0&&t.start===9.5&&t.end===12.5));
    assert(turns.some(t=>t.speaker===0&&t.start===79.5&&t.end===83.5));
    assert(turns.some(t=>t.speaker===1&&t.start===80&&t.end===83));
    assert(turns.every(t=>t.end<=12.5||t.start>=79.5),'no turn covers removed silence');
    const whole=new Float32Array(4*16000);
    assert.equal(speechTimeline.packRecordingSpeech(whole,[{start:0,end:4}]).samples,whole);
    assert.equal(speechTimeline.packRecordingSpeech(whole,[]).samples.length,0);
  });
  const analysisJob=path=>({audioPath:path,modelDir:'/models',language:'auto',diarization:true});
  function runAnalysis(job){sent=[];calls=[];port.onmessage({data:job});return sent.at(-1);}
  test('Default file transcription skips speaker models and voiceprints entirely',()=>{
    files.set('/fast-default',wave({seconds:30}));modelThreads.length=0;
    const result=runAnalysis({audioPath:'/fast-default',modelDir:'/models',language:'auto'});
    assert.equal(result.kind,'done',result.message);assert.equal(result.result.method,'transcription');
    assert(!calls.includes('diarize'));assert(!calls.includes('embedding'));
    assert(result.result.segments.length>=2);assert(result.result.segments.every(s=>s.speaker===-1&&s.end-s.start<=20));
    assert(result.result.speakers.every(s=>s.id===-1&&s.embedding.length===0));
    assert(!sent.some(v=>/划分说话人|整理说话人声纹/.test(v.message)));
    assert(modelThreads.length===2&&modelThreads.every(n=>n<=4));
    assert(files.has('/fast-default.transcription.json'));assert(!files.has('/fast-default.analysis.json'));
    const required=load(base+'RecordingModels').recordingRequiredModels;
    assert.deepEqual(Array.from(required(false),m=>m.name),['sensevoice.int8.onnx','tokens.txt','silero_vad.onnx']);
    assert.equal(required(true).length,5);
  });
  test('Fast and diarized modes retain independent resumable checkpoints for the same audio',()=>{
    files.set('/mode-switch',wave({seconds:30}));const job=analysisJob('/mode-switch');
    reportHook=value=>{if(value.message==='整理说话人声纹')throw Error('pause speaker mode');};
    try{assert.equal(runAnalysis(job).kind,'error');}finally{reportHook=null;}
    const savedSpeaker=files.get('/mode-switch.analysis-current.json').toString();
    reportHook=value=>{if(value.message.startsWith('转写片段 2 /'))throw Error('pause fast mode');};
    try{assert.equal(runAnalysis({...job,diarization:false}).kind,'error');}finally{reportHook=null;}
    assert.equal(files.get('/mode-switch.analysis-current.json').toString(),savedSpeaker);
    const fast=JSON.parse(files.get('/mode-switch.transcription-current.json'));assert.equal(fast.chunk.nextTurn,1);
    const speakers=runAnalysis(job);assert.equal(speakers.kind,'done',speakers.message);assert(!calls.includes('diarize'));
    const resumed=runAnalysis({...job,diarization:false});assert.equal(resumed.kind,'done',resumed.message);
    assert(!calls.includes('diarize')&&!calls.includes('embedding'));assert.equal(calls.filter(c=>c==='decode').length,1);
    assert(resumed.result.segments.every((s,i)=>s.id===i&&s.speaker===-1));
  });
  test('Pause after diarization resumes without rerunning VAD or speaker separation',()=>{
    files.set('/resume-speakers',wave({seconds:8}));
    reportHook=value=>{if(value.message==='整理说话人声纹')throw Error('simulated pause');};
    try{assert.equal(runAnalysis(analysisJob('/resume-speakers')).kind,'error');}
    finally{reportHook=null;}
    assert(calls.includes('diarize'));
    const saved=JSON.parse(files.get('/resume-speakers.analysis-current.json'));
    assert(saved.chunk.turns.length>0);assert.equal(saved.chunk.mapped,false);
    const resumed=runAnalysis(analysisJob('/resume-speakers'));
    assert.equal(resumed.kind,'done',resumed.message);assert(!calls.includes('diarize'));
    assert(!sent.some(v=>v.message.startsWith('检测人声与停顿')));
    assert(resumed.result.segments.length>0);
  });
  test('Pause between ASR turns resumes at the next turn without duplicate text, voice time or numbering',()=>{
    files.set('/resume-asr',wave({seconds:8}));
    reportHook=value=>{if(value.message.startsWith('转写片段 2 /'))throw Error('simulated pause');};
    try{assert.equal(runAnalysis(analysisJob('/resume-asr')).kind,'error');}finally{reportHook=null;}
    const saved=JSON.parse(files.get('/resume-asr.analysis-current.json'));
    assert.equal(saved.chunk.nextTurn,1);assert.equal(saved.chunk.analysis.segments.length,1);
    const first=JSON.stringify(saved.chunk.analysis.segments[0]);
    const resumed=runAnalysis(analysisJob('/resume-asr'));
    assert.equal(resumed.kind,'done',resumed.message);assert(!calls.includes('diarize'));assert(!calls.includes('embedding'));
    assert.equal(JSON.stringify(resumed.result.segments[0]),first);
    assert.equal(calls.filter(v=>v==='decode').length,resumed.result.segments.length-1);
    assert(resumed.result.segments.every((v,i)=>v.id===i));
    const spoken=resumed.result.segments.reduce((sum,v)=>sum+v.end-v.start,0);
    assert.equal(resumed.result.speakers.reduce((sum,v)=>sum+v.seconds,0),spoken);
    const complete=runAnalysis(analysisJob('/resume-asr'));
    assert.equal(complete.kind,'done');assert.equal(calls.length,0,'completed checkpoint needs no model load');
    const restarted=runAnalysis({...analysisJob('/resume-asr'),restart:true});
    assert.equal(restarted.kind,'done');assert(calls.includes('diarize'));
  });
  test('Atomic current-stage commits preserve the previous checkpoint when a rename fails',()=>{
    files.set('/atomic-resume',wave({seconds:8}));const rename=io.renameSync;
    let commits=0;io.renameSync=(from,to)=>{
      if(to==='/atomic-resume.analysis-current.json'&&++commits===2)throw Error('rename failed');
      return rename(from,to);
    };
    try{assert.equal(runAnalysis(analysisJob('/atomic-resume')).kind,'error');}finally{io.renameSync=rename;}
    const old=JSON.parse(files.get('/atomic-resume.analysis-current.json'));
    assert.equal(old.chunk.turns,null,'first VAD checkpoint remains intact');assert.equal(handles.size,0);
    const resumed=runAnalysis(analysisJob('/atomic-resume'));assert.equal(resumed.kind,'done',resumed.message);
    assert(resumed.result.segments.length>0);
  });
  test('A failed completed-chunk commit recovers the saved ASR without repeating inference',()=>{
    files.set('/atomic-prefix',wave({seconds:8}));const rename=io.renameSync;let commits=0;
    io.renameSync=(from,to)=>{
      if(to==='/atomic-prefix.analysis.json'&&++commits===2)throw Error('prefix rename failed');
      return rename(from,to);
    };
    try{assert.equal(runAnalysis(analysisJob('/atomic-prefix')).kind,'error');}finally{io.renameSync=rename;}
    assert.equal(JSON.parse(files.get('/atomic-prefix.analysis.json')).completed,0);
    const current=JSON.parse(files.get('/atomic-prefix.analysis-current.json')).chunk;
    assert.equal(current.nextTurn,current.turns.length);
    const resumed=runAnalysis(analysisJob('/atomic-prefix'));
    assert.equal(resumed.kind,'done',resumed.message);assert.equal(calls.length,0);
    assert.equal(resumed.result.segments.length,current.nextTurn);assert.equal(handles.size,0);
  });
  test('Checkpoint identity rejects changed audio, language or model and preserves corrupt metadata for explicit restart',()=>{
    const Checkpoint=load(base+'RecordingAnalysisCheckpoint').RecordingAnalysisCheckpoint;
    const job=analysisJob('/resume-asr');
    assert.equal(new Checkpoint(job,8).state.completed,1);
    assert.equal(new Checkpoint({...job,language:'zh'},8).state.completed,0);
    runAnalysis({...job,restart:true});
    assert.equal(new Checkpoint({...job,modelDir:'/other-models'},8).state.completed,0);
    runAnalysis({...job,restart:true});files.set(job.audioPath,wave({seconds:8}));
    assert.equal(new Checkpoint(job,8).state.completed,0,'same-sized replacement audio invalidates prior work');
    files.set(job.audioPath+'.analysis.json',Buffer.from('{broken'));
    assert.throws(()=>new Checkpoint(job,8),/断点无法读取/);
    assert.equal(files.get(job.audioPath+'.analysis.json').toString(),'{broken');
    assert.equal(new Checkpoint({...job,restart:true},8).state.completed,0);
  });
  test('Deleting a recording removes both bounded checkpoint files and interrupted temporary writes',()=>{
    const record=store.create('手机');files.set(store.audioPath(record.id),wave());store.save(record);
    for(const suffix of ['.analysis.json','.analysis.json.tmp','.analysis-current.json','.analysis-current.json.tmp']){
      files.set(store.audioPath(record.id)+suffix,Buffer.from('{}'));
    }
    assert(store.hasAnalysisDraft(record.id,true));store.remove(record.id);
    assert(![...files.keys()].some(p=>p.startsWith(store.directory(record.id)+'/')));
  });
  test('Windowed resampling matches the same interval in a full decode',()=>{
    files.set('/window',wave({seconds:4,rate:48000,channels:2}));
    const whole=wav.readWav16k('/window'),part=wav.readWav16k('/window',1.25,2.5);
    assert.equal(part.length,20000);
    assert.deepEqual(Array.from(part),Array.from(whole.slice(20000,40000)));
    assert.equal(wav.recordingWavDuration('/window'),4);assert.equal(handles.size,0);
    assert.equal(types.RECORDING_MAX_SECONDS,43200);
  });
  test('A valid two-hour WAV header is accepted; the 12-hour storage guard remains explicit',()=>{
    const stat=io.statSync;
    function inspect(seconds){
      files.set('/sparse',Buffer.from(wav.wavHeader(seconds*32000)));
      const file=io.openSync('/sparse');
      io.statSync=fd=>fd===file.fd?{size:44+seconds*32000}:stat(fd);
      try{return wav.inspectWav(file.fd);}finally{io.statSync=stat;io.closeSync(file);}
    }
    assert.equal(inspect(7200).bytes,7200*32000);
    assert.equal(inspect(43200).bytes,43200*32000);
    assert.throws(()=>inspect(43201),/12 小时/);assert.equal(handles.size,0);
  });
  await testAsync('Watch import preserves provenance, deduplicates and retains edited results',async()=>{
    for(const record of store.list())store.remove(record.id);
    files.set('/watch.wav',wave());
    const saved={sourceId:'watch-source-uuid',sha256:'a'.repeat(64),path:'/watch.wav',
      recording:{id:'cm2_1793520000000_0001_16000_speech.wav',createdAt:1793520000000}};
    const first=await store.importWatch(saved);assert.equal(first.source,'手表');
    first.title='保留的标题';first.summary={title:'保留的摘要'};store.save(first);
    const again=await store.importWatch(saved);
    assert.equal(again.id,first.id);assert.equal(again.title,'保留的标题');assert.equal(again.summary.title,'保留的摘要');
    assert.equal(store.list().length,1);
    files.set(store.audioPath(first.id),Buffer.from('damaged'));
    await store.importWatch(saved);
    assert.deepEqual(files.get(store.audioPath(first.id)),files.get('/watch.wav'));
    assert.equal(store.list()[0].summary.title,'保留的摘要');
    await assert.rejects(store.importWatch({...saved,sha256:'b'.repeat(64)}),/发生变化/);
    assert.equal(store.list().length,1);store.remove(first.id);
  });
  test('Interrupted microphone files recover their real PCM length after reopening',()=>{
    const record=store.create('录制');record.capturing=true;
    files.set(store.audioPath(record.id),Buffer.concat([Buffer.from(wav.wavHeader(0)),Buffer.alloc(64000)]));
    store.save(record);new Store('/app').recoverCaptures();
    const recovered=store.list().find(r=>r.id===record.id);
    assert.equal(recovered.duration,2);assert.equal(recovered.capturing,false);
    const file=io.openSync(store.audioPath(record.id));assert.equal(wav.inspectWav(file.fd).bytes,64000);io.closeSync(file);
    store.remove(record.id);assert.equal(handles.size,0);
  });
  test('Two-hour analysis bounds audio windows, preserves absolute times and reuses speakers',()=>{
    const read=wav.readWav16k,duration=wav.recordingWavDuration,windows=[];
    wav.recordingWavDuration=()=>7205;files.set('/long-meeting',wave());
    diarizationFixture=[{start:0,end:10,speaker:0},{start:10,end:20,speaker:1}];
    wav.readWav16k=(_path,start,end)=>{
      windows.push([start,end]);assert(end-start<=302);
      return new Float32Array(Math.round((end-start)*16000)).fill(.4);
    };
    try{
      sent=[];calls=[];port.onmessage({data:{audioPath:'/long-meeting',modelDir:'/models',language:'auto',diarization:true}});
      const done=sent.at(-1);assert.equal(done.kind,'done',done.message);
      assert.equal(windows.length,25);assert.equal(windows.at(-1)[1],7205);
      assert.equal(done.result.duration,7205);
      assert(done.result.segments.some(s=>s.start>=7200));
      assert(done.result.segments.every(s=>s.start>=0&&s.end<=7205&&s.end-s.start<=20.001));
      assert.equal(done.result.speakers.filter(s=>s.id>=0).length,2);
      const progress=sent.filter(s=>s.kind==='progress').map(s=>s.progress);
      assert(progress.every((v,i)=>i===0||v>=progress[i-1]));
      assert.equal(calls.filter(s=>s==='asr').length,1,'one ASR model for all windows');
    }finally{wav.readWav16k=read;wav.recordingWavDuration=duration;diarizationFixture=null;}
  });
  test('A restarted long recording skips completed five-minute chunks and retains global speaker IDs',()=>{
    const read=wav.readWav16k,duration=wav.recordingWavDuration,windows=[];
    files.set('/resume-long',wave());wav.recordingWavDuration=()=>610;
    wav.readWav16k=(_path,start,end)=>{windows.push(start);return new Float32Array(Math.round((end-start)*16000)).fill(.4);};
    diarizationFixture=[{start:0,end:10,speaker:0}];
    reportHook=value=>{if(value.message.startsWith('第 2 / 3 段 · 检测'))throw Error('screen hidden');};
    try{
      assert.equal(runAnalysis(analysisJob('/resume-long')).kind,'error');reportHook=null;
      const prefix=JSON.parse(files.get('/resume-long.analysis.json'));
      assert.equal(prefix.completed,1);const first=JSON.stringify(prefix.analysis.segments);
      windows.length=0;const resumed=runAnalysis(analysisJob('/resume-long'));
      assert.equal(resumed.kind,'done',resumed.message);assert.deepEqual(windows,[299,599]);
      assert.equal(JSON.stringify(resumed.result.segments.slice(0,prefix.analysis.segments.length)),first);
      assert.equal(resumed.result.speakers.filter(s=>s.id>=0).length,1);
      assert(resumed.result.segments.some(s=>s.start>=600));
      const points=sent.filter(v=>v.kind==='progress').map(v=>v.progress);
      assert(points.every((p,i)=>i===0||p>=points[i-1]));
    }finally{wav.readWav16k=read;wav.recordingWavDuration=duration;diarizationFixture=null;reportHook=null;}
  });
  const summaryText=load(base+'RecordingSummaryText');
  test('Summary framing preserves the end of long transcripts and rejects malformed JSON',()=>{
    const text=('甲'.repeat(5998)+'😀\n').repeat(5)+'最后的决定必须保留';
    const chunks=summaryText.summaryTextChunks(text);
    assert(chunks.every(s=>s.length<=6000));assert(chunks.at(-1).includes('最后的决定必须保留'));
    assert.equal(chunks.join('').replace(/\n/g,''),text.replace(/\n/g,''));
    assert(chunks.every(s=>!/[\uD800-\uDBFF]$/.test(s)));
    assert.equal(summaryText.parseRecordingSummary('{"title":"x","overview":"y"}','planner').actionItems.length,0);
    assert.throws(()=>summaryText.parseRecordingSummary('null','planner'));
    const result=summaryText.parseRecordingSummary('```json\n'+JSON.stringify({title:'会谈',overview:'概述',keyPoints:['要点'],decisions:[],actionItems:[],openQuestions:[]})+'\n```','planner');
    assert.equal(result.model,'planner');assert.equal(result.keyPoints[0],'要点');
  });
  test('Recording summaries accept safe syntax recovery, extra prose and model stop markers',()=>{
    const expected={title:'会谈',overview:'保留原始事实',keyPoints:['第一点'],decisions:[],actionItems:['联系同事'],openQuestions:[]};
    const json=JSON.stringify(expected);
    for(const source of [json+'<|im_end|>',json+'</s>',json+'\n<eop>',
      '以下是摘要：\n```json\n'+json+'\n```\n以上是本段结果。',
      '<think>只输出摘要。</think>\n'+json,
      json.replace(/"/g,"'"),
      '{title: "会谈", overview: "保留原始事实", keyPoints: ["第一点",], decisions: [], actionItems: ["联系同事"], openQuestions: [],}',
      '{/* 格式偏差 */ "title":"会谈", "overview":"保留原始事实", "keyPoints":["第一点"], "decisions":[], "actionItems":["联系同事"], "openQuestions":[]}',
      '{“title”：“会谈”，“overview”：“保留原始事实”，“keyPoints”：[“第一点”]，"decisions":[],"actionItems":["联系同事"],"openQuestions":[]}']){
      const result=summaryText.parseRecordingSummary(source,'local');
      for(const [key,value] of Object.entries(expected))assert.deepEqual(JSON.parse(JSON.stringify(result[key])),value,source);
      assert.equal(result.model,'local');
    }
    const multiline=summaryText.parseRecordingSummary('{"title":"会谈","overview":"第一行\n第二行"}','local');
    assert.equal(multiline.overview,'第一行\n第二行');
  });
  test('Recording summary fields normalize missing/null lists, aliases and a named result wrapper',()=>{
    const result=summaryText.parseRecordingSummary(JSON.stringify({result:{summary:'明天联系同事确认进展。',
      key_points:null,decisions:'暂无',action_items:'- 联系同事\n- 确认进展',open_questions:[]}}),'local');
    assert.equal(result.title,'明天联系同事确认进展');
    assert.deepEqual(Array.from(result.actionItems),['联系同事','确认进展']);assert.equal(result.keyPoints.length,0);
    const chinese=summaryText.parseRecordingSummary('{"标题":"会谈","摘要":"保留事实","要点":["要点"],"待办":"联系同事"}','local');
    assert.equal(chinese.title,'会谈');assert.equal(chinese.actionItems[0],'联系同事');
  });
  test('Recording JSON repairs missing separators and one encoded string without changing the shared default',()=>{
    const missing='{"title":"项目讨论" "overview":"保留事实" "keyPoints":["第一项" "第二项"],"decisions":[]}';
    assert.throws(()=>load('entry/src/main/ets/datamanager/ModelJsonResponse').parseModelJsonObject(missing));
    const result=summaryText.parseRecordingSummary(missing,'local');assert.equal(result.title,'项目讨论');
    assert.deepEqual(Array.from(result.keyPoints),['第一项','第二项']);
    assert.equal(summaryText.parseRecordingSummary(JSON.stringify('{"overview":"完整的概述"}'),'local').overview,'完整的概述');
    const objects=summaryText.parseRecordingSummary('{"overview":"事实","keyPoints":[{"text":"要点"},{"content":"要点。"},{"description":"另一项"}]}','local');
    assert.deepEqual(Array.from(objects.keyPoints),['要点','另一项']);
    for(const source of ['{"overview":"截断', '{"overview":"x"}{"overview":"y"}',
      '{"overview":"x","actionItems":[{"text":"任务","owner":"甲"}]}']){
      assert.throws(()=>summaryText.parseRecordingSummary(source,'local'));
    }
  });
  test('Saved summary lists deduplicate on read while retaining decisions, transcript and stored data',()=>{
    const record=store.create('手机');files.set(store.audioPath(record.id),wave());
    record.analysis={modelId:types.RECORDING_MODEL_ID,duration:1,speech:[],segments:[],speakers:[]};
    record.summary={title:'讨论',overview:'保留概述',keyPoints:['同一要点','同一要点。','不同要点'],decisions:['已确认'],
      actionItems:[],openQuestions:[],model:'local',generatedAt:'fixed'};store.save(record);
    const path=store.directory(record.id)+'/record.json',before=files.get(path).toString();
    const restored=store.list().find(r=>r.id===record.id);
    assert.deepEqual(Array.from(restored.summary.keyPoints),['同一要点','不同要点']);assert.equal(restored.summary.decisions[0],'已确认');
    assert.equal(restored.summary.generatedAt,'fixed');assert.equal(files.get(path).toString(),before);store.remove(record.id);
  });
  test('Copied title instructions fall back to real overview text without discarding summary content',()=>{
    const overview='介绍研究方向并讨论合作安排。';
    for(const title of ['根据本段概述拟定的12字内标题','基于录音内容生成的简短标题',
      '请填写12字以内的标题','12字内标题','简短标题']){
      const result=summaryText.parseRecordingSummary(JSON.stringify({title,overview,actionItems:['核对合作材料']}),'local');
      assert.equal(result.title,'介绍研究方向并讨论合作安排',title);
      assert.equal(result.overview,overview);assert.equal(result.actionItems[0],'核对合作材料');
    }
    for(const title of ['标题设计讨论','根据实验结果调整模型','如何拟定研究标题']){
      assert.equal(summaryText.parseRecordingSummary(JSON.stringify({title,overview}),'local').title,title);
    }
    const result=summaryText.parseRecordingSummary(JSON.stringify({title:'简短标题',overview:'甲'.repeat(19)+'😀结束。'}),'local');
    assert.equal(result.title,'甲'.repeat(19),'fallback never leaves half a surrogate pair');
  });
  test('Truncated, ambiguous, empty and invalid-typed summaries never become successful results',()=>{
    for(const source of ['{"title":"x","overview":"unfinished', '{"title":"x","overview":"y",',
      '{"title":"x","overview":"y"}{"title":"z","overview":"another"}',
      '只有普通说明，尚未生成 JSON', 'null','[]','{"overview":123}',
      '{"title":"x","overview":"y","actionItems":[null]}',
      '{"title":"x","overview":"y","keyPoints":{}}']){
      assert.throws(()=>summaryText.parseRecordingSummary(source,'local'),/模型摘要格式不完整或无法解析/,source);
    }
  });
  let plannerRequests=[],plannerDeferred;
  mocks['../CloudModelClient']={cloudPlannerApiKey:config=>config.plannerApiKey,CloudModelClient:class{
    async chatCompletion(options){plannerRequests.push(options);if(plannerDeferred)await plannerDeferred;
      return {content:JSON.stringify({title:'会谈',overview:'已整理',keyPoints:['要点'],decisions:[],actionItems:[],openQuestions:[]}),finishReason:'stop'};}
    cancelActiveRequests(){}
  }};
  mocks['../ChatCloudConfig']={readChatCloudConfig:()=>({plannerBaseUrl:'https://planner.example/v1',plannerModel:'chosen-planner',plannerApiKey:'test-placeholder'})};
  mocks['./AiServiceAccess']={AiServiceAccess:{requireAllowed(){}}};
  const localText=load('entry/src/main/ets/utils/LocalTextInference').LocalTextInference;
  const localParts=load(base+'RecordingLocalSummary');
  let localRequests=[],localFailure=-1,localWait,localPrepareWait,localCancelCount=0,localIdentity='model-1',localRawOverride;
  screenNative.isChatRunning=()=>false;
  screenNative.cancelText=()=>{localCancelCount++;};
  screenNative.completeText=async(prompt,limit,emit)=>{
    const index=localRequests.length;localRequests.push(prompt);assert.equal(limit,768);
    if(localWait)await localWait;
    if(index===localFailure)throw Error('model interrupted');
    if(typeof localRawOverride==='function')return localRawOverride(index,prompt);
    if(localRawOverride!==undefined)return localRawOverride;
    emit('生成');return JSON.stringify({title:index===0?'首段主题':'后续标题',overview:'第'+index+'段概述',
      keyPoints:[],decisions:[],actionItems:['第'+index+'段待办'],openQuestions:[]});
  };
  localText.configure({prepare:async()=>{if(localPrepareWait)await localPrepareWait;return {identity:localIdentity,name:'本地测试模型'};},openDownload(){}});
  const localRecord=()=>({schema:1,id:'local-test',title:'新录音',createdAt:new Date().toISOString(),source:'phone',duration:180,
    analysis:{speakers:[{id:0,name:'甲'}],segments:[{start:0,end:60,speaker:0,text:'甲'.repeat(1200)},
      {start:60,end:120,speaker:0,text:'乙'.repeat(1200)},{start:120,end:180,speaker:0,text:'结尾决定保留这个事项'}]}});
  test('Local and cloud prompts share an empty JSON shape with field instructions outside the values',()=>{
    const expected={title:'',overview:'',keyPoints:[],decisions:[],actionItems:[],openQuestions:[]};
    for(const prompt of [localParts.RECORDING_LOCAL_SUMMARY_SYSTEM,summaryText.RECORDING_SUMMARY_SYSTEM]){
      assert.deepEqual(JSON.parse(prompt.match(/\{[^{}]+\}/)[0]),expected);
      assert(prompt.includes('不得照抄字段名、格式要求或填写说明'));
    }
  });
  test('Local chunking bounds multilingual words, huge tokens and whitespace without losing text',()=>{
    for(const text of ['甲'.repeat(1005),'alpha '.repeat(2003),'😀'.repeat(1200),'x'.repeat(15001),
      ' '.repeat(12000)+'开始'+' '.repeat(14000)+'结束'+' '.repeat(6000),('中文，。abc-123\n').repeat(1000)]){
      const chunks=localParts.localSummaryTextChunks(text);
      assert.equal(chunks.join(''),text);assert(chunks.every(s=>s.length>0&&s.length<=5000));
      assert(chunks.every(s=>!/[\uD800-\uDBFF]$/.test(s)&&! /^[\uDC00-\uDFFF]/.test(s)));
    }
    assert.equal(localParts.localSummaryTextChunks('甲'.repeat(1001))[0].length,1000);
    assert.equal(localParts.localSummaryTextChunks('word '.repeat(1001)).length,2);
    const parts=localParts.localRecordingChunks(localRecord(),summaryText.recordingTranscript(localRecord()));
    assert(parts.length>=3&&parts.at(-1).text.includes('结尾决定保留这个事项'));
    assert(parts.every(p=>p.start>=0&&p.end<=180&&p.start<=p.end));
    assert(parts[1].text.includes('甲：'),'split segments retain the speaker label');
  });
  const Summary=load(base+'RecordingSummaryService').RecordingSummaryService;
  await testAsync('Local output and recovered responses persist at most three unique items per category; cloud stays unchanged',async()=>{
    const items=['第一项','第一项。','第二项','第三项','第四项','第五项','第六项'];
    const raw=JSON.stringify({title:'简要主题',overview:'简短概述',keyPoints:items,decisions:items,actionItems:items,openQuestions:items});
    assert.equal(summaryText.parseRecordingSummary(raw,'cloud').keyPoints.length,6);
    for(const recover of [false,true]){
      const record=store.create('手机');record.analysis=localRecord().analysis;
      record.analysis.segments=[{start:0,end:6,speaker:0,text:'讨论研究方向和课程选择'}];record.duration=6;
      files.set(store.audioPath(record.id),wave({seconds:6}));
      const transcript=JSON.stringify(record.analysis);localRequests=[];localRawOverride=raw;
      if(recover){
        record.localSummaryDraft=localParts.prepareLocalSummary(record,localIdentity,false);
        record.localSummaryDraft.pendingResponse={index:0,content:raw,truncated:false};
      }
      try{
        const result=await new Summary().generate(record,()=>{},{source:'local',onCheckpoint:()=>store.save(record)});
        const part=result.sections[0].summary;
        for(const field of ['keyPoints','decisions','actionItems','openQuestions']){
          assert.deepEqual(Array.from(part[field]),['第一项','第二项','第三项']);
          assert.equal(store.list().find(r=>r.id===record.id).summary.sections[0].summary[field].length,3);
        }
        assert.equal(localRequests.length,recover?0:1);assert.equal(JSON.stringify(record.analysis),transcript);
      }finally{localRawOverride=undefined;store.remove(record.id);}
    }
  });
  test('Rendered local categories cap legacy content at three without mutating it or limiting cloud content',()=>{
    const source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/recording/RecordingSummaryView.ets'),'utf8');
    const expression=source.match(/ForEach\((uniqueRecordingSummaryItems[\s\S]*?), \(item: string/)[1];
    const lists=load(base+'RecordingSummaryLists'),items=['甲','甲。','乙','丙','丁','戊'];
    for(const mode of ['local','cloud']){
      const result=vm.runInNewContext('(function(items){return '+expression+';}).call(root,items)',
        {items,root:{summary:{source:mode}},uniqueRecordingSummaryItems:lists.uniqueRecordingSummaryItems,
          RECORDING_LOCAL_SUMMARY_MAX_ITEMS:lists.RECORDING_LOCAL_SUMMARY_MAX_ITEMS});
      assert.equal(result.length,mode==='local'?3:5);
    }
    assert.equal(items.length,6);
  });
  await testAsync('Saved copied titles normalize on read while preserving manual names, checkpoints and files',async()=>{
    const record=store.create('手机');record.analysis=localRecord().analysis;
    record.analysis.segments=[{start:1,end:7,speaker:0,text:'介绍研究方向并讨论合作安排'}];record.duration=8;
    const title='根据本段概述拟定的12字内标题';
    const part={title,overview:'介绍研究方向并讨论合作安排。',keyPoints:['保留要点'],decisions:[],
      actionItems:['核对合作材料'],openQuestions:[],model:'本地测试模型',generatedAt:'2026-11-05T04:00:00Z'};
    record.localSummaryDraft={policy:localParts.RECORDING_LOCAL_SUMMARY_POLICY,input:summaryText.recordingTranscript(record),
      model:localIdentity,total:1,sections:[{index:0,start:1,end:7,summary:part}]};
    types.applyRecordingSummary(record,localParts.localSummarySnapshot(record.localSummaryDraft,'本地测试模型'));
    files.set(store.audioPath(record.id),wave());store.save(record);
    const metadata=store.directory(record.id)+'/record.json';const before=files.get(metadata).toString();
    const restored=store.list().find(r=>r.id===record.id);
    assert.equal(restored.title,'介绍研究方向并讨论合作安排');
    assert.equal(restored.summary.title,restored.title);
    assert.equal(restored.summary.sections[0].summary.title,restored.title);
    assert.equal(restored.localSummaryDraft.sections[0].summary.title,restored.title);
    assert.equal(restored.summary.sections[0].summary.actionItems[0],'核对合作材料');
    assert.equal(restored.summary.sections[0].summary.generatedAt,part.generatedAt);
    assert.equal(files.get(metadata).toString(),before,'read normalization does not rewrite stored data');
    localRequests=[];await new Summary().generate(restored,()=>{},{source:'local'});
    assert.equal(localRequests.length,0,'title repair reuses completed local chunks');
    record.title=title;record.titleEdited=true;store.save(record);
    const manual=store.list().find(r=>r.id===record.id);
    assert.equal(manual.title,title,'even an instruction-shaped manual name is retained');
    assert.equal(manual.summary.title,'介绍研究方向并讨论合作安排');
  });
  await testAsync('Local summaries retain every section and action, use the first title and never call cloud',async()=>{
    localRequests=[];plannerRequests=[];const checkpoints=[];const record=localRecord();
    const result=await new Summary().generate(record,()=>{}, {source:'local',onCheckpoint:(done,total)=>{
      checkpoints.push([done,total]);assert.equal(record.localSummaryDraft.sections.length,done);
    }});
    assert.equal(plannerRequests.length,0);assert.equal(result.source,'local');assert(result.complete);
    assert.equal(result.title,'首段主题');assert.equal(record.title,'首段主题');
    assert.equal(result.sections.length,localRequests.length);assert(result.sections.length>=3);
    assert(result.sections.every(p=>p.summary.actionItems.length===1));
    assert.equal(checkpoints.length,result.sections.length+1);assert.equal(checkpoints.at(-1)[0],result.partCount);
    assert(!localRequests[0].includes('结尾决定保留这个事项'));assert(localRequests.at(-1).includes('结尾决定保留这个事项'));
  });
  await testAsync('Failed local chunks keep saved work; retry skips completed chunks and preserves manual names',async()=>{
    const record=store.create('手机');record.analysis=localRecord().analysis;record.duration=180;
    record.title='我的自定名称';record.titleEdited=true;files.set(store.audioPath(record.id),wave());
    localRequests=[];localFailure=1;
    await assert.rejects(new Summary().generate(record,()=>{},{source:'local',onCheckpoint:()=>store.save(record)}),/interrupted/);
    assert.equal(record.summary.sections.length,1);assert.equal(record.summary.complete,false);
    const restored=new Store('/app').list().find(r=>r.id===record.id);assert.equal(restored.localSummaryDraft.sections.length,1);
    localFailure=-1;localRequests=[];
    const result=await new Summary().generate(restored,()=>{},{source:'local'});
    assert.equal(localRequests.length,result.partCount-1);assert(result.complete);
    assert.equal(result.title,'首段主题');assert.equal(restored.title,'我的自定名称');
    localRequests=[];await new Summary().generate(restored,()=>{},{source:'local'});assert.equal(localRequests.length,0);
    for(const change of [r=>r.analysis.segments[0].text+='新增',r=>r.analysis.speakers[0].name='乙',r=>r.localSummaryDraft.model='old',
      r=>r.localSummaryDraft.sections[0].index=10]){
      const changed=JSON.parse(JSON.stringify(restored));change(changed);
      assert.equal(localParts.prepareLocalSummary(changed,localIdentity,false).sections.length,0);
    }
    assert.equal(localParts.prepareLocalSummary(restored,localIdentity,true).sections.length,0);
  });
  await testAsync('Recoverable local output is checkpointed, while invalid output cannot overwrite a completed part',async()=>{
    let record=localRecord();record.analysis.segments=[{start:0,end:6,speaker:0,text:'请明天联系同事'}];
    localRawOverride='摘要如下：\n{title:"联系同事",overview:"明天联系同事确认进展",action_items:["明天联系同事",],}\n<|im_end|>';
    try {
      const result=await new Summary().generate(record,()=>{},{source:'local'});
      assert(result.complete);assert.equal(record.localSummaryDraft.sections.length,1);
      assert.equal(result.sections[0].summary.actionItems[0],'明天联系同事');
      const saved=JSON.stringify(record.summary);localRawOverride='{"overview":"截断';
      await assert.rejects(new Summary().generate(record,()=>{},{source:'local',restart:true}),/无法解析/);
      assert.equal(JSON.stringify(record.summary),saved);assert.equal(record.localSummaryDraft.sections.length,0);
      assert(!localText.isBusy());
    } finally {localRawOverride=undefined;}
  });
  await testAsync('Local JSON failure retries only the failed part once with a shorter prompt and retains the raw checkpoint',async()=>{
    const record=store.create('手机');record.analysis=localRecord().analysis;record.duration=180;
    files.set(store.audioPath(record.id),wave());const valid=JSON.stringify({title:'已保存主题',overview:'保留事实',actionItems:['核对材料']});
    localRequests=[];localRawOverride=index=>index===0?valid:'{"overview":"被截断';
    try{
      await assert.rejects(new Summary().generate(record,()=>{},{source:'local',onCheckpoint:()=>store.save(record)}),/无法解析/);
      assert.equal(localRequests.length,3,'first good part, failed part, one retry');
      assert.equal(record.localSummaryDraft.sections.length,1);assert.equal(record.localSummaryDraft.pendingResponse.index,1);
      assert.equal(record.localSummaryDraft.pendingResponse.content,'{"overview":"被截断');
      assert(localRequests[2].includes('这次必须更简短'));
      const first=JSON.stringify(record.localSummaryDraft.sections[0]);
      const restored=store.list().find(r=>r.id===record.id);localRequests=[];localRawOverride=valid;
      const result=await new Summary().generate(restored,()=>{},{source:'local',onCheckpoint:()=>store.save(restored)});
      assert(result.complete);assert.equal(JSON.stringify(restored.localSummaryDraft.sections[0]),first);
      assert.equal(localRequests.length,result.partCount-1);assert(localRequests[0].includes('这次必须更简短'));
      assert.equal(restored.localSummaryDraft.pendingResponse,undefined);assert.equal(handles.size,0);
    }finally{localRawOverride=undefined;store.remove(record.id);}
  });
  await testAsync('A safely recoverable saved response completes a local part without another model request',async()=>{
    const record=localRecord();record.analysis.segments=[{start:0,end:6,speaker:0,text:'核对合作材料'}];
    record.localSummaryDraft=localParts.prepareLocalSummary(record,localIdentity,false);
    record.localSummaryDraft.pendingResponse={index:0,content:'{"overview":"核对合作材料" "keyPoints":["核对材料" "核对材料。"]}',truncated:false};
    localRequests=[];const result=await new Summary().generate(record,()=>{},{source:'local'});
    assert(result.complete);assert.equal(localRequests.length,0);assert.equal(result.sections[0].summary.keyPoints.length,1);
    assert.equal(record.localSummaryDraft.pendingResponse,undefined);
  });
  await testAsync('Local leases serialize work, propagate load failures and wait for cancelled native jobs',async()=>{
    const first=await localText.acquire();await assert.rejects(localText.acquire(),/正在使用/);
    let release;localWait=new Promise(resolve=>release=resolve);const pending=first.generate('资料',()=>{});
    await assert.rejects(first.generate('重叠',()=>{}),/尚未完成/);first.close();
    assert(localText.isBusy());assert(localCancelCount>0);release();await assert.rejects(pending,/已停止/);
    assert(!localText.isBusy());localWait=undefined;
    localText.configure({prepare:async()=>{throw Error('LOCAL_MODEL_REQUIRED: 缺少模型');},openDownload(){}});
    await assert.rejects(localText.acquire(),/LOCAL_MODEL_REQUIRED/);assert(!localText.isBusy());
    localText.configure({prepare:async()=>{if(localPrepareWait)await localPrepareWait;return {identity:localIdentity,name:'本地测试模型'};},openDownload(){}});
  });
  await testAsync('Cancellation ignores late local output and releases loading or inference leases',async()=>{
    let release;localPrepareWait=new Promise(resolve=>release=resolve);let service=new Summary();
    let job=service.generate(localRecord(),()=>{},{source:'local'});await Promise.resolve();service.cancel();release();
    await assert.rejects(job,/已停止/);localPrepareWait=undefined;assert(!localText.isBusy());
    localWait=new Promise(resolve=>release=resolve);service=new Summary();const record=localRecord();localRequests=[];
    job=service.generate(record,()=>{},{source:'local'});while(!localRequests.length)await Promise.resolve();
    service.cancel();release();await assert.rejects(job,/已停止/);localWait=undefined;
    assert.equal(record.localSummaryDraft.sections.length,0);assert(!record.summary);assert(!localText.isBusy());
  });
  await testAsync('Planner summary reduces all transcript chunks with isolated data and no audio',async()=>{
    const record={analysis:{speakers:[{id:0,name:'甲'}],segments:Array.from({length:50},(_,id)=>({id,start:id*20,end:(id+1)*20,speaker:0,text:'会谈资料'.repeat(120)}))}};
    plannerRequests=[];const service=new Summary();const result=await service.generate(record,()=>{});
    assert.equal(result.model,'chosen-planner');assert(plannerRequests.length>2);
    assert(plannerRequests.every(r=>r.logResponseContent===false&&r.baseUrl==='https://planner.example/v1'));
    assert(plannerRequests.every(r=>r.messages[0].role==='system'&&r.messages[1].role==='user'));
    assert(plannerRequests.some(r=>r.messages[1].content.includes('16:20')),'the last original segment is included');
  });
  await testAsync('Cancellation prevents a late Planner response from becoming a saved summary',async()=>{
    let release;plannerDeferred=new Promise(resolve=>release=resolve);
    const service=new Summary();const job=service.generate({analysis:{speakers:[],segments:[{start:0,end:1,speaker:-1,text:'测试'}]}},()=>{});
    await Promise.resolve();service.cancel();release();await assert.rejects(job,/已停止/);plannerDeferred=undefined;
  });
  await testAsync('Foreground Agent cleanup preserves the microphone background task',async()=>{
    const operations=[];let listener;
    mocks['@kit.BackgroundTasksKit']={backgroundTaskManager:{on:(_event,cb)=>listener=cb,
      startBackgroundRunning:async(_ctx,modes)=>operations.push(['start',Array.from(modes)]),
      updateBackgroundRunning:async(_ctx,modes)=>operations.push(['update',Array.from(modes)]),
      stopBackgroundRunning:async()=>operations.push(['stop'])}};
    mocks['@kit.AbilityKit'].wantAgent={OperationType:{START_ABILITY:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:1},getWantAgent:async()=>({})};
    mocks['./AppIdentity']={getAppBundleName:()=> 'test.clawmate'};
    const tasks=load('entry/src/main/ets/utils/AppBackgroundTasks').appBackgroundTasks;
    const ctx={eventHub:{emit(){}}};await tasks.set(ctx,'recording','audioRecording',true);
    await tasks.set(ctx,'agent','dataTransfer',true);await tasks.set(ctx,'agent','dataTransfer',false);
    assert.equal(operations.filter(x=>x[0]==='stop').length,0);
    assert.deepEqual(operations.at(-1),['update',['audioRecording']]);
    await tasks.set(ctx,'recording','audioRecording',false);assert.equal(operations.at(-1)[0],'stop');
    let release;
    mocks['@kit.BackgroundTasksKit'].backgroundTaskManager.startBackgroundRunning=async()=>new Promise(resolve=>release=resolve);
    const pending=tasks.set(ctx,'recording','audioRecording',true);
    const rejected=assert.rejects(pending,/系统结束/);
    while(!release)await Promise.resolve();listener();release();await rejected;
    await tasks.set(ctx,'recording','audioRecording',false);
  });
  await testAsync('Analysis cancellation ignores late worker messages and settles the interrupted job',async()=>{
    const threads=[];
    mocks['@ohos.worker'].default.ThreadWorker=class{
      constructor(){threads.push(this);}postMessage(){}terminate(){this.terminated=true;}
    };
    const Runner=load(base+'RecordingAnalysisRunner').RecordingAnalysisRunner,runner=new Runner();
    const first=runner.run({},()=>{});const firstRejected=assert.rejects(first,/已停止/);
    const second=runner.run({},()=>{});await firstRejected;
    threads[0].onmessage({data:{kind:'done',result:{duration:999}}});threads[0].onerror();
    threads[1].onmessage({data:{kind:'done',result:{duration:2}}});assert.equal((await second).duration,2);
    const next=runner.run({},()=>{});const cancelled=assert.rejects(next,/已停止/);runner.cancel();await cancelled;
    assert(threads.every(thread=>thread.terminated));
  });
  await testAsync('Main thread receives diagnostics without changing progress or failing a saved result',async()=>{
    let thread;const progress=[],logs=[];
    mocks['@ohos.worker'].default.ThreadWorker=class{constructor(){thread=this;}postMessage(){}terminate(){}};
    const logger=mocks['../AppLogger'].AppLogger,info=logger.info;
    const Runner=load(base+'RecordingAnalysisRunner').RecordingAnalysisRunner,runner=new Runner();
    const job=runner.run({},value=>progress.push(value));
    try{
      logger.info=(tag,message)=>logs.push([tag,message]);
      thread.onmessage({data:{kind:'diagnostic',progress:0,message:'chunk=1/1 stages=asr:1ms',result:null}});
      assert.deepEqual(logs,[['RecordingAnalysis','chunk=1/1 stages=asr:1ms']]);assert.equal(progress.length,0);
      logger.info=()=>{throw Error('logging unavailable');};
      assert.doesNotThrow(()=>thread.onmessage({data:{kind:'diagnostic',progress:0,message:'optional log',result:null}}));
      thread.onmessage({data:{kind:'done',progress:100,message:'分析完成',result:{duration:8}}});
      assert.equal((await job).duration,8);assert.equal(progress.length,0);
    }finally{logger.info=info;runner.cancel();}
  });
  await testAsync('Analysis status shows elapsed time while native processing is busy and stops after completion',async()=>{
    let thread;const messages=[];
    mocks['@ohos.worker'].default.ThreadWorker=class{
      constructor(){thread=this;}postMessage(){}terminate(){}
    };
    const Runner=load(base+'RecordingAnalysisRunner').RecordingAnalysisRunner,runner=new Runner();
    const job=runner.run({},value=>messages.push(value));
    thread.onmessage({data:{kind:'progress',progress:12,message:'划分说话人片段',result:null}});
    await new Promise(resolve=>setTimeout(resolve,1150));
    assert(messages.some(m=>/划分说话人片段 · 已用 \d+ 秒/.test(m.message)));
    thread.onmessage({data:{kind:'done',progress:100,message:'分析完成',result:{duration:8}}});await job;
    const count=messages.length;await new Promise(resolve=>setTimeout(resolve,1050));
    assert.equal(messages.length,count,'completed runs release the heartbeat timer');
  });
  test('Live PCM reads use committed sample ranges despite a stale WAV header and never load an unbounded window',()=>{
    const original=wave({seconds:3});const growing=Buffer.from(original);Buffer.from(wav.wavHeader(0)).copy(growing);
    files.set('/growing-live.wav',growing);maxRead=79;
    try {
      const result=wav.readCapturedPcm('/growing-live.wav',16000,32000);assert.equal(result.length,16000);
      assert(Math.abs(result[100]-original.readInt16LE(44+16100*2)/32768)<1e-6);
      assert.throws(()=>wav.readCapturedPcm('/growing-live.wav',0,64001),/范围无效/);
      assert.throws(()=>wav.readCapturedPcm('/growing-live.wav',48000,48001),/完整写入/);
      assert.equal(handles.size,0);
    }finally{maxRead=Infinity;}
  });
  test('Live transcript checkpoints append completed text and recover a crashed capture with a torn final line',()=>{
    const {RecordingLiveCheckpoint}=load(base+'RecordingLiveCheckpoint'),{emptyLiveAnalysis}=load(base+'RecordingLiveTypes');
    const record=store.create('录制');record.capturing=true;record.analysis=emptyLiveAnalysis(0);record.transcriptionComplete=false;
    const audio=wave({seconds:4});Buffer.from(wav.wavHeader(0)).copy(audio);files.set(store.audioPath(record.id),audio);store.save(record);
    const checkpoint=new RecordingLiveCheckpoint(store.livePath(record.id));
    const batch=(processed,start,end,text)=>({kind:'update',processed,segments:[{id:0,start,end,speaker:-1,text,language:'zh'}],speech:[{start,end}],error:''});
    checkpoint.append(batch(32000,0,1,'第一段'));const prefix=files.get(store.livePath(record.id)).toString();
    checkpoint.append(batch(64000,2,3,'第二段'));assert(files.get(store.livePath(record.id)).toString().startsWith(prefix));
    files.set(store.livePath(record.id),Buffer.concat([files.get(store.livePath(record.id)),Buffer.from('{torn-tail')]));
    store.recoverCaptures();const restored=store.list().find(r=>r.id===record.id);
    assert.equal(restored.duration,4);assert.equal(restored.capturing,false);assert.equal(restored.transcriptionComplete,false);
    assert.deepEqual(Array.from(restored.analysis.segments,s=>s.text),['第一段','第二段']);
    assert.deepEqual(Array.from(restored.analysis.segments,s=>s.id),[0,1]);assert.equal(restored.analysis.speakers[0].seconds,2);
    store.remove(record.id);
  });
  await testAsync('Audio-only deletion retains transcript, summary and voiceprints after reopening and rolls back failed deletion',async()=>{
    files.set('/delete-source.wav',wave());const record=await store.importWav('/delete-source.wav');
    record.title='研究讨论';record.titleEdited=true;
    record.analysis={modelId:types.RECORDING_MODEL_ID,duration:1,speech:[{start:0,end:1}],segments:[{id:0,start:0,end:1,speaker:0,text:'保留文字',language:'zh'}],speakers:[{id:0,name:'同事',seconds:1,embedding:[1,0]}]};
    record.summary={title:'研究讨论',overview:'保留摘要',keyPoints:[],decisions:[],actionItems:[],openQuestions:[],model:'test',generatedAt:new Date().toISOString()};store.save(record);
    writeFailure=true;assert.throws(()=>store.removeAudio(record),/disk full/);writeFailure=false;assert(store.hasAudio(record.id));
    const unlink=io.unlinkSync;io.unlinkSync=p=>{if(p===store.audioPath(record.id))throw Error('file busy');return unlink(p);};
    try{assert.throws(()=>store.removeAudio(record),/删除失败/);assert(store.hasAudio(record.id));assert(!store.list().find(r=>r.id===record.id).audioDeleted);}finally{io.unlinkSync=unlink;}
    files.set(store.audioPath(record.id)+'.analysis.json',Buffer.from('{}'));
    assert.throws(()=>store.removeAudio(record),/进度/);store.clearAnalysisDraft(record.id);
    const before=JSON.stringify([record.analysis,record.summary]);files.set('/unrelated.wav',wave());store.removeAudio(record);
    const restored=store.list().find(r=>r.id===record.id);assert(restored.audioDeleted);assert(!store.hasAudio(record.id));
    assert.equal(JSON.stringify([restored.analysis,restored.summary]),before);assert.equal(restored.title,'研究讨论');assert(files.has('/unrelated.wav'));
    store.remove(record.id);assert(!dirs.has(store.directory(record.id)));
  });
  test('Live VAD emits text before stop, flushes the final utterance once and reuses bounded ASR threads',()=>{
    const audio=wave({seconds:3});audio.fill(0,44+16000*2,44+32000*2);files.set('/live-worker.wav',audio);
    liveDecodeForTest=true;sent=[];calls=[];modelThreads.length=0;
    try{
      load('entry/src/main/ets/workers/RecordingLiveWorker',true);
      port.onmessage({data:{kind:'start',job:{audioPath:'/live-worker.wav',modelDir:'/models',language:'auto'}}});assert.equal(sent.at(-1).kind,'ready');
      port.onmessage({data:{kind:'advance',end:32000}});const first=sent.at(-1);assert.equal(first.kind,'update');assert.equal(first.segments.length,1);assert.equal(first.segments[0].start,0);
      port.onmessage({data:{kind:'finish',end:48000}});const last=sent.at(-1);assert.equal(last.kind,'done');assert.equal(last.segments.length,1);assert(last.segments[0].start>=2);assert(last.segments[0].end<=3);
      assert.equal(calls.filter(c=>c==='asr').length,1);assert.equal(calls.filter(c=>c==='decode').length,2);assert(!calls.includes('diarize'));
      assert(modelThreads.every(n=>n>=1&&n<=2));assert.equal(handles.size,0);
    }finally{liveDecodeForTest=false;}
  });
  await testAsync('Live runner keeps one bounded request in flight and drains the final tail without a PCM backlog',async()=>{
    const threads=[];mocks['@ohos.worker'].default.ThreadWorker=class{constructor(){this.requests=[];threads.push(this);}postMessage(value){this.requests.push(value);}terminate(){this.terminated=true;}};
    const Runner=load(base+'RecordingLiveRunner').RecordingLiveRunner,runner=new Runner(),updates=[],failures=[];
    try{
      runner.start({audioPath:'/live',modelDir:'/models',language:'auto'},()=>160000,value=>updates.push(value),text=>failures.push(text));
      const thread=threads[0];assert.equal(thread.requests.length,1);thread.onmessage({data:{kind:'ready',processed:0,segments:[],speech:[],error:''}});
      assert.equal(thread.requests.length,2);assert.equal(thread.requests[1].end,64000);
      const done=runner.finish(160000);assert.equal(thread.requests.length,2,'finishing cannot queue another read while native ASR is busy');
      for(let i=1;i<5;i++){
        const request=thread.requests[i];assert(request);const previous=i===1?0:thread.requests[i-1].end;
        assert(request.end-previous<=64000);
        thread.onmessage({data:{kind:request.kind==='finish'?'done':'update',processed:request.end,segments:[],speech:[],error:''}});
        if(request.kind==='finish')break;
      }
      const result=await done;assert.equal(result.duration,10);assert.equal(result.method,'live');assert(thread.terminated);assert.equal(failures.length,0);
      runner.cancel();assert.equal(failures.length,0,'closing a successful runner must not report cancellation');
    }finally{runner.cancel();}
  });
  await testAsync('Live cancellation preserves completed text and ignores late replies without stopping or deleting audio',async()=>{
    const threads=[];mocks['@ohos.worker'].default.ThreadWorker=class{constructor(){threads.push(this);}postMessage(){}terminate(){this.terminated=true;}};
    const Runner=load(base+'RecordingLiveRunner').RecordingLiveRunner,runner=new Runner(),failures=[];
    runner.start({audioPath:'/live',modelDir:'/models',language:'auto'},()=>64000,()=>{},text=>failures.push(text));const thread=threads[0];
    thread.onmessage({data:{kind:'ready',processed:0,segments:[],speech:[],error:''}});
    thread.onmessage({data:{kind:'update',processed:64000,segments:[{id:0,start:0,end:1,speaker:-1,text:'已完成内容',language:'zh'}],speech:[{start:0,end:1}],error:''}});
    const finishing=runner.finish(64000);const rejected=assert.rejects(finishing,/已停止/);runner.cancel();await rejected;
    const before=runner.snapshot(4).segments.length;thread.onmessage({data:{kind:'done',processed:64000,segments:[],speech:[],error:''}});
    assert.equal(runner.snapshot(4).segments.length,before);assert.equal(runner.snapshot(4).segments[0].text,'已完成内容');assert(thread.terminated);assert.equal(failures.length,1);
  });
  test('Page, Worker and WAV entry points are registered without importing memory services',()=>{
    const pages=JSON.parse(fs.readFileSync(path.join(root,'entry/src/main/resources/base/profile/main_pages.json'),'utf8'));
    assert(pages.src.includes('pages/recording/RecordingPage'));
    assert(fs.readFileSync(path.join(root,'entry/build-profile.json5'),'utf8').includes('./src/main/ets/workers/RecordingAnalysisWorker.ets'));
    assert(fs.readFileSync(path.join(root,'entry/build-profile.json5'),'utf8').includes('./src/main/ets/workers/RecordingLiveWorker.ets'));
    const module=fs.readFileSync(path.join(root,'entry/src/main/module.json5'),'utf8');assert(module.includes('audio/wav'));
    for(const name of fs.readdirSync(path.join(root,base))) {
      assert(!/import[^;]*(?:DataManagerFacade|IndexService|HomeRecommendationService|WorkflowRunner)/.test(fs.readFileSync(path.join(root,base,name),'utf8')));
    }
  });
  console.log(`${tests} groups passed; native inference, ArkUI rendering and device performance were not exercised.`);
})().catch(e=>{console.error(e);process.exitCode=1;});
