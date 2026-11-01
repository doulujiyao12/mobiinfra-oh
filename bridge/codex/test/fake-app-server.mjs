// A subprocess fixture for exercising real newline-delimited stdio transport without inference.
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
const send = message => process.stdout.write(JSON.stringify(message) + '\n');
createInterface({ input: process.stdin }).on('line', line => {
  const m = JSON.parse(line);
  if (m.method === 'initialized') return;
  if (m.method === 'initialize') return send({ id: m.id, result: { userAgent: 'fixture' } });
  if (m.method === 'model/list') return send({ id: m.id, result: { data: [{
    id: 'fixture', model: 'fixture', displayName: 'Fixture', defaultReasoningEffort: 'medium',
    supportedReasoningEfforts: [{ reasoningEffort: 'medium' }], inputModalities: ['text', 'image']
  }], nextCursor: null } });
  if (m.method === 'thread/start') return send({ id: m.id, result: { thread: { id: randomUUID() } } });
  if (m.method === 'turn/start') {
    const id = randomUUID(); const threadId = m.params.threadId;
    send({ method: 'turn/started', params: { threadId, turn: { id, status: 'inProgress' } } });
    send({ id: m.id, result: { turn: { id, status: 'inProgress' } } });
    send({ method: 'item/agentMessage/delta', params: { threadId, itemId: 'answer', delta: '测试' } });
    send({ method: 'item/agentMessage/delta', params: { threadId, itemId: 'answer', delta: '成功' } });
    send({ method: 'item/completed', params: { threadId, item: { id: 'answer', type: 'agentMessage', text: '测试成功' } } });
    return send({ method: 'turn/completed', params: { threadId, turn: { id, status: 'completed', error: null } } });
  }
  if (m.method === 'fixture/exit') return process.exit(0);
  send({ id: m.id, error: { code: -32601, message: 'Unknown fixture method' } });
});
