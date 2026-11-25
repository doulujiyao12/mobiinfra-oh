import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { Readable } from 'node:stream';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { classifyDesktop, switchDesktop } from '../desktop/shared-launch.mjs';
import { prepareSharedDesktop, sharedDesktopState } from '../host/shared-desktop.mjs';
import { DaemonRpc } from '../../bridge/codex/daemon-rpc.mjs';

function setup() {
  const info={count:1,pid:42,created:'1',executable:'Codex.exe',cli:'resources/codex.exe',visible:true,stdio:true};
  const log=[];
  const worker=new EventEmitter();
  worker.unref=()=>{};
  worker.disconnect=()=>{worker.connected=false;log.push('disconnect');};
  worker.send=()=>{log.push('launch');setImmediate(()=>{worker.emit('message',{kind:'launched'});setImmediate(()=>worker.emit('message',{kind:'connected'}));});};
  const options={directory:'.',layout:{cli:'worker',node:'node'}, probe:async()=>({state:'private',info}),
    openStream:()=>Readable.from([Buffer.from('CODEX_APP_SER'),Buffer.from('VER_WS_URL')]),
    idle:async()=>log.push('idle'), consent:async()=>{log.push('consent');return true;},
    startWorker:()=>{log.push('prepare');worker.connected=true;setImmediate(()=>worker.emit('message',{kind:'ready'}));return worker;},
    inspect:async()=>({...info,count:0}),close:async()=>log.push('close')};
  return {info,log,options,worker};
}

test('only a positively identified unshared desktop offers a restart',()=>{
  const {info}=setup();
  for(const change of [{custom:true},{count:2},{visible:false},{stdio:false}]) assert.equal(classifyDesktop({...info,...change},null,false).state,'unknown');
  assert.equal(classifyDesktop(info,null,false).state,'private');
  assert.equal(classifyDesktop(info,null,true).state,'available');
  assert.equal(classifyDesktop({...info,stdio:false},{pid:42},false).state,'shared');
  assert.equal(classifyDesktop({...info,count:0},null,false).state,'off');
});
test('no restart on cancellation, active task, incompatible build, PID change or close refusal',async()=>{
  for(const scenario of ['cancel','busy','incompatible','changed','refused']){
    const {options,info,log}=setup();
    if(scenario==='cancel') options.consent=async()=>false;
    if(scenario==='busy') options.idle=async()=>{throw Error('busy');};
    if(scenario==='incompatible') options.openStream=()=>Readable.from([]);
    if(scenario==='changed'){let probes=0;options.probe=async()=>({state:'private',info:{...info,pid:++probes}});}
    if(scenario==='refused') options.close=async()=>{throw Error('refused');};
    if(scenario==='cancel')assert.equal(await switchDesktop(options),'已取消。');else await assert.rejects(switchDesktop(options));
    assert.ok(!log.includes('launch'));assert.ok(!log.includes('close'));
  }
});
test('prepares before closing and confirms the desktop handshake before reporting success', async()=>{
  const {options,log}=setup();
  assert.match(await switchDesktop(options),/已接入/);
  assert.deepEqual(log,['consent','idle','prepare','idle','close','launch','disconnect']);
});

test('real Windows backend accepts the private GUI WebSocket and the ClawMate IPC client on the same thread',
  {skip:process.platform!=='win32'||!process.env.CLAWMATE_TEST_DAEMON,timeout:45000},async t=>{
  const d=mkdtempSync(path.join(os.tmpdir(),'cm-s-')),home=path.join(d,'home');mkdirSync(home);
  const environment={...process.env,CODEX_HOME:home,OPENAI_API_KEY:'',CHATGPT_API_KEY:''};
  const cli=process.env.CLAWMATE_TEST_DAEMON;
  const model=http.createServer((req,res)=>{req.resume();req.on('end',()=>{res.writeHead(400,{'Content-Type':'application/json'});res.end('{"error":{"message":"local fixture"}}');});});
  await new Promise(r=>model.listen(0,'127.0.0.1',r));
  writeFileSync(path.join(home,'config.toml'),'model="fixture"\nmodel_provider="fixture"\n[model_providers.fixture]\nname="Fixture"\nwire_api="responses"\nbase_url="http://127.0.0.1:'+model.address().port+'/v1"\nrequest_max_retries=0\n');
  let transport,desktop,phone;
  t.after(async()=>{desktop?.close();phone?.close();transport?.close();model.closeAllConnections();await new Promise(r=>model.close(r));await delay(500);rmSync(d,{recursive:true,force:true,maxRetries:4});});
  transport=await prepareSharedDesktop(d,cli,environment);
  const wrong=new WebSocket(new URL('/invalid',transport.url));await once(wrong,'error');
  desktop=new WebSocket(transport.url);await once(desktop,'open');
  const messages=[];desktop.addEventListener('message',e=>messages.push(JSON.parse(e.data)));
  const wait=async fn=>{for(let i=0;i<120;i++){const v=fn();if(v)return v;await delay(50);}throw Error('missing event');};
  let seq=0;const call=async(method,params)=>{const id=++seq;desktop.send(JSON.stringify({method,params,id}));const m=await wait(()=>messages.find(m=>m.id===id));assert.ok(!m.error,JSON.stringify(m.error));return m.result;};
  await call('initialize',{clientInfo:{name:'test_desktop',version:'1'}});desktop.send(JSON.stringify({method:'initialized'}));await transport.accepted;
  transport.activate(process.pid);phone=new DaemonRpc(sharedDesktopState(d).socket,{proxy:{command:cli,environment}});await phone.initialize();
  const {thread}=await call('thread/start',{cwd:d,model:'fixture',sandbox:'read-only',approvalPolicy:'never'});
  const turn=async(method,input)=>method('turn/start',{threadId:thread.id,input:[{type:'text',text:input}]});
  const seed=await turn(call,'seed');
  const finished=id=>messages.some(m=>m.method==='turn/completed'&&m.params.turn.id===id);
  await wait(()=>finished(seed.turn.id));
  assert.ok((await phone.request('thread/loaded/list',{limit:50})).data.includes(thread.id));
  await phone.request('thread/resume',{threadId:thread.id,excludeTurns:true});
  const received=[];phone.on('message',m=>received.push(m));
  const phoneTurn=await turn(phone.request.bind(phone),'from phone');await wait(()=>finished(phoneTurn.turn.id));
  const hasInput=(list,text)=>list.some(m=>m.params?.threadId===thread.id&&m.params.item?.type==='userMessage'&&m.params.item.content.some(part=>part.text===text));
  assert.ok(hasInput(messages,'from phone'));
  await turn(call,'from desktop');await wait(()=>hasInput(received,'from desktop'));
});
