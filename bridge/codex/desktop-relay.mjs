import { WebSocketServer } from 'ws';
import { openDaemonWebSocket } from './daemon-rpc.mjs';

// The native socket authenticates the bridge via its OS permissions. The GUI receives
// a separate, per-launch capability in its own process environment, never in an argv or file.
export function acceptDesktopConnections(server, secretPath, socket, proxy, initialized) {
  const webSockets = new WebSocketServer({ noServer:true, perMessageDeflate:false, maxPayload:16 * 1024 * 1024 });
  server.on('upgrade', (request, client, head) => {
    if (request.method !== 'GET' || request.url !== secretPath || request.headers.origin ||
        request.headers.host !== '127.0.0.1:' + server.address().port) { client.destroy(); return; }
    const upstream = openDaemonWebSocket(socket, proxy);
    const stop = () => { client.destroy(); upstream.terminate(); };
    client.once('close', stop); client.on('error', stop);
    upstream.once('error', stop); upstream.once('close', stop);
    upstream.once('open', () => {
      if (client.destroyed) { stop(); return; }
      webSockets.handleUpgrade(request, client, head, desktop => {
        desktop.once('close', stop); desktop.on('error', stop);
        let initializeId;
        let confirmed = false;
        function forward(from, to, outbound) {
          from.on('message', (bytes, binary) => {
            if (binary || to.readyState !== to.OPEN) { stop(); return; }
            if (!confirmed) {
              let frame;
              try { frame = JSON.parse(bytes); } catch { stop(); return; }
              if (outbound && frame.method === 'initialize' && frame.id != null) initializeId = frame.id;
              if (!outbound && initializeId != null && frame.id === initializeId && frame.result) {
                confirmed = true; initialized();
              }
            }
            from.pause();
            to.send(bytes, { binary:false }, error => { if (error) stop(); else from.resume(); });
          });
        }
        forward(desktop, upstream, true); forward(upstream, desktop, false);
      });
    });
  });
  server.once('close', () => webSockets.close());
}
