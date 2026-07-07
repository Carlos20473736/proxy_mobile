const net = require('net');
const http = require('http');

// === CONFIGURAÇÃO ===
const PORT = parseInt(process.env.PORT || '7777');
const PROXY_USER = process.env.PROXY_USER || '5guser';
const PROXY_PASS = process.env.PROXY_PASS || 'senha123';
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'senha123';
const POOL_SIZE = 4; // Conexões paralelas celular↔server
const MAX_BUFFER = 2 * 1024 * 1024; // 2MB backpressure threshold

/*
  ╔══════════════════════════════════════════════════════════════╗
  ║  5G-SHARE v7.0 - ALTA PERFORMANCE                          ║
  ║                                                             ║
  ║  Pool de conexões paralelas + multiplexação binária         ║
  ║  + flow control + pipeline + TCP otimizado                  ║
  ║                                                             ║
  ║  Protocolo: [CMD:1][ID:2][LEN:2][PAYLOAD:0-65000]          ║
  ║  Pool: 4 conexões TCP simultâneas (round-robin)            ║
  ║  Backpressure: pause/resume em 2MB                          ║
  ╚══════════════════════════════════════════════════════════════╝
*/

// === PROTOCOLO ===
const CMD = {
  CONNECT: 1,    // server→cel: payload="host:port"
  CONNECTED: 2,  // cel→server: conexão estabelecida
  DATA: 3,       // bidirecional: raw bytes
  CLOSE: 4,      // bidirecional: fechar stream
  ERROR: 5,      // cel→server: erro na conexão
  PING: 6,       // keepalive bidirecional
  FLOW_PAUSE: 7, // flow control: pausar envio
  FLOW_RESUME: 8 // flow control: retomar envio
};
const HDR = 5;
const MAX_PAYLOAD = 65000;

// === ESTADO GLOBAL ===
const tunnelPool = [];          // Array de sockets do celular
let poolRoundRobin = 0;         // Índice para round-robin
const pending = new Map();      // id → {socket, mode, extra, ts}
const streams = new Map();      // id → {socket, paused}
let nextId = 1;
let tunnelReady = false;

console.log('╔══════════════════════════════════════════════════════════╗');
console.log('║  5G-SHARE v7.0 - ALTA PERFORMANCE                      ║');
console.log(`║  Porta: ${PORT} | Pool: ${POOL_SIZE} conexões | User: ${PROXY_USER}  ║`);
console.log('║  Backpressure: 2MB | Protocolo: binário 5B header       ║');
console.log('╚══════════════════════════════════════════════════════════╝');

// === FUNÇÕES DE PROTOCOLO ===
function frame(cmd, id, data) {
  const len = data ? data.length : 0;
  const buf = Buffer.allocUnsafe(HDR + len);
  buf[0] = cmd;
  buf.writeUInt16BE(id, 1);
  buf.writeUInt16BE(len, 3);
  if (data) data.copy(buf, HDR);
  return buf;
}

// Envia frame usando round-robin no pool
function sendToTunnel(cmd, id, data) {
  if (tunnelPool.length === 0) return false;
  
  try {
    if (!data || data.length <= MAX_PAYLOAD) {
      const sock = pickSocket();
      if (!sock) return false;
      return sock.write(frame(cmd, id, data));
    }
    
    // Fragmentar pacotes grandes - distribui entre sockets do pool
    let offset = 0;
    while (offset < data.length) {
      const chunk = data.slice(offset, Math.min(offset + MAX_PAYLOAD, data.length));
      const sock = pickSocket();
      if (!sock) return false;
      sock.write(frame(cmd, id, chunk));
      offset += MAX_PAYLOAD;
    }
    return true;
  } catch(e) { return false; }
}

// Round-robin com fallback
function pickSocket() {
  if (tunnelPool.length === 0) return null;
  
  // Tentar round-robin
  for (let i = 0; i < tunnelPool.length; i++) {
    const idx = (poolRoundRobin + i) % tunnelPool.length;
    const sock = tunnelPool[idx];
    if (sock && !sock.destroyed && sock.writable) {
      poolRoundRobin = (idx + 1) % tunnelPool.length;
      return sock;
    }
  }
  return null;
}

// === SERVIDOR TCP PRINCIPAL ===
const server = net.createServer({ noDelay: true, keepAlive: true }, (socket) => {
  socket.setNoDelay(true);
  socket.setKeepAlive(true, 15000);
  
  socket.once('data', (chunk) => {
    const first = chunk[0];
    
    if (first === 0x05) {
      handleSocks5(socket, chunk);
    } else if (first >= 0x41 && first <= 0x5A) {
      const str = chunk.toString('utf8', 0, Math.min(chunk.length, 200));
      if (str.startsWith('CONNECT')) handleHttpConnect(socket, chunk);
      else if (/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s/.test(str)) handleHttp(socket, chunk);
      else tryTunnelAuth(socket, chunk);
    } else {
      tryTunnelAuth(socket, chunk);
    }
  });
  
  socket.on('error', () => {});
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[OK] Servidor ativo na porta ${PORT}`);
});

// === HEALTH CHECK HTTP (mantém Railway vivo) ===
const healthServer = http.createServer((req, res) => {
  const status = {
    version: '7.0',
    tunnel: tunnelReady,
    pool: tunnelPool.length,
    streams: streams.size,
    pending: pending.size
  };
  res.writeHead(200, {'Content-Type': 'application/json'});
  res.end(JSON.stringify(status));
});
healthServer.listen(PORT + 1, '0.0.0.0', () => {
  console.log(`[OK] Health check na porta ${PORT + 1}`);
});

// === TÚNEL - POOL DE CONEXÕES ===
function tryTunnelAuth(socket, chunk) {
  const msg = chunk.toString().trim();
  if (msg === TUNNEL_SECRET || msg.startsWith(TUNNEL_SECRET + ':')) {
    handleTunnelConnection(socket, msg);
  } else {
    socket.destroy();
  }
}

function handleTunnelConnection(socket, authMsg) {
  // Formato: "secret:poolIndex" ou apenas "secret"
  const parts = authMsg.split(':');
  const poolIdx = parts.length > 1 ? parseInt(parts[1]) : tunnelPool.length;
  
  // Remover socket antigo neste slot se existir
  if (tunnelPool[poolIdx] && !tunnelPool[poolIdx].destroyed) {
    tunnelPool[poolIdx].removeAllListeners();
    tunnelPool[poolIdx].destroy();
  }
  
  // Configurar socket de alta performance
  socket.setNoDelay(true);
  socket.setKeepAlive(true, 15000);
  try { socket.setRecvBufferSize(524288); } catch(e) {}
  try { socket.setSendBufferSize(524288); } catch(e) {}
  
  // Registrar no pool
  tunnelPool[poolIdx] = socket;
  socket._poolIdx = poolIdx;
  socket._buf = Buffer.alloc(0);
  
  socket.write('OK\n');
  
  // Limpar slots vazios
  while (tunnelPool.length > 0 && !tunnelPool[tunnelPool.length-1]) tunnelPool.pop();
  
  tunnelReady = tunnelPool.some(s => s && !s.destroyed);
  console.log(`[POOL] Slot ${poolIdx} conectado | Pool: ${tunnelPool.filter(s=>s&&!s.destroyed).length}/${POOL_SIZE}`);
  
  // Handler de dados
  socket.on('data', (data) => onTunnelData(socket, data));
  
  socket.on('close', () => {
    if (tunnelPool[poolIdx] === socket) {
      tunnelPool[poolIdx] = null;
      tunnelReady = tunnelPool.some(s => s && !s.destroyed);
      console.log(`[POOL] Slot ${poolIdx} desconectou | Pool: ${tunnelPool.filter(s=>s&&!s.destroyed).length}/${POOL_SIZE}`);
    }
  });
  
  socket.on('error', () => {
    if (tunnelPool[poolIdx] === socket) tunnelPool[poolIdx] = null;
    tunnelReady = tunnelPool.some(s => s && !s.destroyed);
  });
  
  // Ping keepalive
  const iv = setInterval(() => {
    if (socket.destroyed) { clearInterval(iv); return; }
    try { socket.write(frame(CMD.PING, 0, null)); } catch(e) { clearInterval(iv); }
  }, 15000);
  socket.on('close', () => clearInterval(iv));
}

// === PROCESSAR DADOS DO TÚNEL ===
function onTunnelData(socket, data) {
  socket._buf = socket._buf.length ? Buffer.concat([socket._buf, data]) : data;
  
  while (socket._buf.length >= HDR) {
    const len = socket._buf.readUInt16BE(3);
    if (socket._buf.length < HDR + len) break;
    
    const cmd = socket._buf[0];
    const id = socket._buf.readUInt16BE(1);
    const payload = len > 0 ? socket._buf.slice(HDR, HDR + len) : null;
    socket._buf = socket._buf.slice(HDR + len);
    
    switch(cmd) {
      case CMD.CONNECTED: {
        const p = pending.get(id);
        if (p) {
          pending.delete(id);
          if (p.mode === 'socks5') {
            p.socket.write(Buffer.from([0x05,0x00,0x00,0x01,0,0,0,0,0,0]));
          } else if (p.mode === 'http') {
            p.socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
          }
          if (p.extra && p.extra.length) sendToTunnel(CMD.DATA, id, p.extra);
          setupStream(id, p.socket);
        }
        break;
      }
      case CMD.DATA: {
        const s = streams.get(id);
        if (s && !s.socket.destroyed) {
          const ok = s.socket.write(payload);
          // Backpressure: se o buffer do cliente está cheio, pausar o túnel
          if (!ok && !s.paused) {
            s.paused = true;
            sendToTunnel(CMD.FLOW_PAUSE, id, null);
            s.socket.once('drain', () => {
              s.paused = false;
              sendToTunnel(CMD.FLOW_RESUME, id, null);
            });
          }
        }
        break;
      }
      case CMD.CLOSE: {
        const s = streams.get(id);
        if (s) { s.socket.end(); streams.delete(id); }
        break;
      }
      case CMD.ERROR: {
        const p = pending.get(id);
        if (p) { pending.delete(id); p.socket.destroy(); }
        const s = streams.get(id);
        if (s) { s.socket.destroy(); streams.delete(id); }
        break;
      }
      case CMD.PING:
        // Pong - responde no mesmo socket
        try { socket.write(frame(CMD.PING, 0, null)); } catch(e) {}
        break;
    }
  }
}

// === STREAM MANAGEMENT ===
function setupStream(id, socket) {
  streams.set(id, { socket, paused: false });
  
  socket.on('data', (d) => {
    const ok = sendToTunnel(CMD.DATA, id, d);
    // Backpressure do lado do túnel
    if (!ok) {
      socket.pause();
      // Retomar quando algum socket do pool drenar
      const checkDrain = () => {
        const sock = pickSocket();
        if (sock) {
          socket.resume();
        } else {
          setTimeout(checkDrain, 50);
        }
      };
      setTimeout(checkDrain, 10);
    }
  });
  
  const cleanup = () => {
    if (streams.has(id)) {
      streams.delete(id);
      sendToTunnel(CMD.CLOSE, id, null);
    }
  };
  socket.on('close', cleanup);
  socket.on('error', cleanup);
}

// === ROTEAMENTO ===
function routeConnection(socket, host, port, extra, mode) {
  if (!tunnelReady) {
    if (mode === 'http') socket.write('HTTP/1.1 502 Tunnel Offline\r\n\r\n');
    else if (mode === 'socks5') socket.write(Buffer.from([0x05,0x05,0x00,0x01,0,0,0,0,0,0]));
    socket.destroy();
    return;
  }
  
  const id = nextId++;
  if (nextId > 65534) nextId = 1;
  
  const target = Buffer.from(`${host}:${port}`);
  sendToTunnel(CMD.CONNECT, id, target);
  pending.set(id, { socket, mode, extra, ts: Date.now() });
  
  // Timeout para conexão pendente
  setTimeout(() => {
    if (pending.has(id)) {
      pending.delete(id);
      if (mode === 'http') socket.write('HTTP/1.1 504 Gateway Timeout\r\n\r\n');
      socket.destroy();
    }
  }, 8000);
}

// === HTTP CONNECT PROXY ===
function handleHttpConnect(socket, chunk) {
  const req = chunk.toString('utf8', 0, Math.min(chunk.length, 2000));
  const lines = req.split('\r\n');
  const m = lines[0].match(/^CONNECT\s+([^:\s]+):(\d+)\s+HTTP/i);
  if (!m) { socket.write('HTTP/1.1 400 Bad Request\r\n\r\n'); socket.destroy(); return; }
  
  if (!httpAuth(lines)) {
    socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\nConnection: close\r\n\r\n');
    socket.destroy(); return;
  }
  
  routeConnection(socket, m[1], parseInt(m[2]), null, 'http');
}

// === HTTP PROXY (GET/POST direto) ===
function handleHttp(socket, chunk) {
  const req = chunk.toString('utf8', 0, Math.min(chunk.length, 4000));
  const lines = req.split('\r\n');
  const pm = lines[0].match(/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+http:\/\/([^\/:\s]+)(?::(\d+))?(\/\S*)\s+HTTP/i);
  
  if (!pm) {
    // Health check inline
    const b = JSON.stringify({status:'online', tunnel: tunnelReady, pool: tunnelPool.filter(s=>s&&!s.destroyed).length, streams: streams.size});
    socket.write(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${b.length}\r\n\r\n${b}`);
    socket.end(); return;
  }
  
  if (!httpAuth(lines)) {
    socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\nConnection: close\r\n\r\n');
    socket.destroy(); return;
  }
  
  const host = pm[2], port = parseInt(pm[3]||'80'), path = pm[4];
  // Reescrever request para formato direto
  lines[0] = `${pm[1]} ${path} HTTP/1.1`;
  const filtered = lines.filter(l => !/^Proxy-Auth/i.test(l));
  const extra = Buffer.from(filtered.join('\r\n'));
  routeConnection(socket, host, port, extra, 'http-plain');
}

function httpAuth(lines) {
  for (const l of lines) {
    const m = l.match(/^Proxy-Authorization:\s*Basic\s+(.+)$/i);
    if (m) {
      const d = Buffer.from(m[1], 'base64').toString();
      const i = d.indexOf(':');
      return i > 0 && d.slice(0,i) === PROXY_USER && d.slice(i+1) === PROXY_PASS;
    }
  }
  return false;
}

// === SOCKS5 ===
function handleSocks5(socket, buf) {
  const nm = buf[1];
  socket.write(Buffer.from([0x05, 0x02])); // requer auth
  buf = buf.slice(2 + nm);
  if (buf.length > 0) socks5Auth(socket, buf);
  else socket.once('data', (d) => socks5Auth(socket, d));
}

function socks5Auth(socket, buf) {
  if (buf.length < 3) { socket.destroy(); return; }
  const ulen = buf[1];
  if (buf.length < 2 + ulen + 1) { socket.destroy(); return; }
  const user = buf.slice(2, 2+ulen).toString();
  const plen = buf[2+ulen];
  if (buf.length < 3 + ulen + plen) { socket.destroy(); return; }
  const pass = buf.slice(3+ulen, 3+ulen+plen).toString();
  
  if (user !== PROXY_USER || pass !== PROXY_PASS) {
    socket.write(Buffer.from([0x01,0x01])); socket.destroy(); return;
  }
  socket.write(Buffer.from([0x01,0x00]));
  buf = buf.slice(3+ulen+plen);
  if (buf.length > 0) socks5Req(socket, buf);
  else socket.once('data', (d) => socks5Req(socket, d));
}

function socks5Req(socket, buf) {
  if (buf.length < 4) { socket.destroy(); return; }
  const atyp = buf[3];
  let host, port, end;
  
  if (atyp === 1) {
    if (buf.length < 10) { socket.destroy(); return; }
    host = `${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}`;
    port = buf.readUInt16BE(8); end = 10;
  } else if (atyp === 3) {
    const dl = buf[4];
    if (buf.length < 5 + dl + 2) { socket.destroy(); return; }
    host = buf.slice(5, 5+dl).toString();
    port = buf.readUInt16BE(5+dl); end = 7+dl;
  } else if (atyp === 4) {
    if (buf.length < 22) { socket.destroy(); return; }
    const p = []; for(let i=0;i<16;i+=2) p.push(buf.readUInt16BE(4+i).toString(16));
    host = p.join(':'); port = buf.readUInt16BE(20); end = 22;
  } else { socket.destroy(); return; }
  
  const extra = end < buf.length ? buf.slice(end) : null;
  routeConnection(socket, host, port, extra, 'socks5');
}

// === LIMPEZA PERIÓDICA ===
setInterval(() => {
  const now = Date.now();
  for (const [id, p] of pending) {
    if (now - p.ts > 15000) {
      pending.delete(id);
      try { p.socket.destroy(); } catch(e) {}
    }
  }
}, 5000);

// === GRACEFUL SHUTDOWN ===
process.on('SIGTERM', () => {
  console.log('[!] Encerrando...');
  for (const s of tunnelPool) { if (s && !s.destroyed) s.destroy(); }
  server.close();
  process.exit(0);
});

process.on('uncaughtException', (e) => {
  console.error('[!] Erro não tratado:', e.message);
});
