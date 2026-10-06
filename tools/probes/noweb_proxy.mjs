// A reverse proxy that carries HTTP only, to a staging server on 7533,
// with any WebSocket upgrade refused — a road with no WebSockets.
import http from 'node:http';
const listen = Number(process.env.PORT ?? 8099);
const server = http.createServer((req, res) => {
  const path = req.url.replace(/^\/visor/, '');
  const upstream = http.request({ host: '127.0.0.1', port: 7533, path, method: req.method, headers: req.headers }, (up) => {
    res.writeHead(up.statusCode, up.headers); up.pipe(res);
  });
  upstream.on('error', () => { res.writeHead(502); res.end('bad gateway'); });
  req.pipe(upstream);
});
server.on('upgrade', (req, socket) => { socket.end('HTTP/1.1 501 Not Implemented\r\nConnection: close\r\n\r\n'); });
server.listen(listen, '127.0.0.1', () => console.log(`proxy on http://127.0.0.1:${listen}/visor (no WebSockets)`));
