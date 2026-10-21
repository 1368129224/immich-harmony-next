// Debug-only bridge for IPv4-only HarmonyOS emulators on an IPv6-capable Windows host.
// Start: node scripts/immich_emulator_proxy.cjs
// Tunnel: hdc rport tcp:15941 tcp:15941
// Emulator endpoint: http://127.0.0.1:15941
// Fixed upstream, loopback binding, no credentials/config/request-body logging.
const http = require('node:http');
const https = require('node:https');
const UPSTREAM = new URL('https://photo.v6.sora233.eu.org:59418');
const PORT = 15941;
const server = http.createServer((req, res) => {
  if (!req.url?.startsWith('/api/')) {
    res.writeHead(404); res.end(); return;
  }
  const headers = { ...req.headers, host: UPSTREAM.host };
  delete headers.connection;
  delete headers['proxy-authorization'];
  const upstream = https.request({
    hostname: UPSTREAM.hostname, port: UPSTREAM.port, family: 6,
    method: req.method, path: req.url, headers, timeout: 30000,
    // Keep standard TLS certificate and hostname verification enabled.
  }, response => {
    const responseHeaders = { ...response.headers };
    delete responseHeaders['transfer-encoding'];
    delete responseHeaders.connection;
    res.writeHead(response.statusCode || 502, responseHeaders);
    response.pipe(res);
  });
  upstream.on('timeout', () => upstream.destroy(new Error('Upstream timeout')));
  upstream.on('error', () => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end('{"message":"IPv6 debug bridge could not reach upstream"}');
  });
  req.on('aborted', () => upstream.destroy());
  res.on('close', () => { if (!res.writableEnded) upstream.destroy(); });
  req.pipe(upstream);
});
server.listen(PORT, '127.0.0.1', () => {
  console.info(`Debug bridge listening on 127.0.0.1:${PORT}; TLS upstream verification enabled.`);
});
server.on('error', error => {
  console.error(`Debug bridge failed: ${error.code || 'unknown'}`);
  process.exitCode = 1;
});
process.on('SIGINT', () => server.close());
process.on('SIGTERM', () => server.close());
