import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { existsSync, lstatSync, realpathSync } from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { secureDaemonSocket } from './daemon-discovery.mjs';

const binary = process.env.CLAWMATE_DESKTOP_CODEX_EXECUTABLE;
const args = process.argv.slice(2);
const command = args.indexOf('app-server');
const extra = args.slice(command + 1);
const subcommands = new Set(['daemon', 'proxy', 'generate-ts', 'generate-json-schema', 'help']);
const oneShotFlags = new Set(['--help', '-h', '--version', '-V', '--print-startup-config']);
const explicitListener = extra.findIndex(arg => arg === '--listen' || arg.startsWith('--listen='));
const listen = explicitListener < 0 ? 'stdio://' : extra[explicitListener].split('=')[1] || extra[explicitListener + 1];

if (!binary || !path.isAbsolute(binary)) {
  process.exitCode = 1;
  console.error('ClawMate: missing installed Codex executable');
} else if (command >= 0 && !subcommands.has(extra[0]) && !extra.some(arg => oneShotFlags.has(arg)) && listen === 'stdio://') {
  await shareDesktop();
} else {
  const native = spawn(binary, args, { stdio: 'inherit' });
  native.once('error', () => { process.exitCode = 1; });
  native.once('exit', code => { process.exitCode = code ?? 1; });
}

async function shareDesktop() {
  const home = path.resolve(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'));
  const socket = path.join(home, 'app-server-control', 'app-server-control.sock');
  try {
    lstatSync(socket);
    console.error('ClawMate: the Codex control socket is already in use');
    process.exitCode = 1;
    return;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const input = createInterface({ input: process.stdin, terminal: false, crlfDelay: Infinity });
  const queue = [];
  const limit = 100 * 1024 * 1024;
  let buffered = 0;
  let backend, client;
  let closed = false;
  function stop() {
    if (closed) return;
    closed = true;
    client?.terminate();
    if (backend?.pid && backend.exitCode === null && backend.signalCode === null) backend.kill();
    input.close();
    process.stdin.destroy();
  }
  function fail(message) {
    if (closed) return;
    process.exitCode = 1;
    console.error('ClawMate: ' + message);
    stop();
  }
  input.on('line', line => {
    const bytes = Buffer.byteLength(line);
    if (client?.readyState === WebSocket.OPEN) {
      if (client.bufferedAmount + bytes > limit) return fail('Codex socket input limit exceeded');
      client.send(line);
    } else {
      buffered += bytes + 1;
      if (buffered > limit) return fail('Codex startup input limit exceeded');
      queue.push(line);
    }
  });
  input.once('close', stop);
  process.stdin.on('error', stop);
  process.stdout.on('error', stop);
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);

  const forwarded = extra.filter((arg, index) => arg !== '--stdio' && index !== explicitListener &&
    !(explicitListener >= 0 && extra[explicitListener] === '--listen' && index === explicitListener + 1));
  backend = spawn(binary, [...args.slice(0, command + 1), ...forwarded, '--listen', 'unix://'],
    { stdio: ['ignore', 'ignore', 'inherit'] });
  backend.once('error', () => fail('could not launch the installed Codex'));
  backend.once('exit', () => fail('the Codex backend exited'));

  const deadline = Date.now() + 10000;
  while (!closed && !existsSync(socket) && Date.now() < deadline) await delay(30);
  if (closed) return;
  let target;
  try { target = realpathSync(socket); }
  catch { return fail('Codex did not open its local control socket'); }
  if (!secureDaemonSocket(target)) return fail('Codex control socket permissions are unsafe');

  client = new WebSocket('ws://localhost/', {
    createConnection: () => net.connect({ path: target }), handshakeTimeout: 4000, maxPayload: limit, perMessageDeflate: false
  });
  client.on('error', () => fail('could not connect desktop Codex to the shared backend'));
  client.on('close', () => fail('the Codex backend connection closed'));
  client.on('message', (frame, binaryFrame) => {
    if (binaryFrame) return fail('unexpected binary frame from Codex');
    if (!process.stdout.write(frame.toString() + '\n') && !client.isPaused) {
      client.pause();
      process.stdout.once('drain', () => { if (!closed) client.resume(); });
    }
  });
  try { await once(client, 'open'); } catch { return; }
  for (const line of queue) client.send(line);
  queue.length = 0;
}
