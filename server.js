const net = require('net');
const http = require('http');

// === CONFIGURAÇÃO ===
const PORT = parseInt(process.env.PORT || '7777');
const PROXY_USER = process.env.PROXY_USER || '5guser';
const PROXY_PASS = process.env.PROXY_PASS || 'senha123';
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'senha123';
const POOL_SIZE = 4;

/*
  ╔══════════════════════════════════════════════════════════════╗
  ║  5G-SHARE v7.1 - ALTA PERFORMANCE + DEBUG                  ║
  ║  Porta única: detecta túnel vs proxy pelo primeiro pacote   ║
  ╚══════════════════════════════════════════════════════════════╝
*/

// === PROTOCOLO BINÁRIO ===
const CMD = { CONNECT: 1, CONNECTED: 2, DATA: 3, CLOSE: 4, ERROR: 5, PING: 6 };
const HDR = 5;
const MAX_PAYLOAD = 65000;

// === ESTADO ===
const tunnelPool = [];
let poolRR = 0;
const pending = new Map();
const streams = new Map();
let nextId = 1;

function log(tag, msg) { console.log(`[${new Date().toISOString().slice(11,19)}][${tag}] ${msg}`); }

log('INIT', `Porta: ${PORT} | User: ${PROXY_USER} | Pool: ${POOL_SIZE}`);

// === FRAME ===
function frame(cmd, id, data) {
  const len = data ? data.length : 0;
  const buf = Buffer.allocUnsafe(HDR + len);
  buf[0] = cmd;
  buf.writeUInt16BE(id, 1);
  buf.writeUInt16BE(len, 3);
  if (data) data.copy(buf, HDR);
  return buf;
}

function pickSocket() {
  for (let i = 0; i < tunnelPool.length; i++) {
    const idx = (poolRR + i) % tunnelPool.length;
    const s = tunnelPool[idx];
    if (s && !s.destroyed && s.writable) {
      poolRR = (idx + 1) % tunnelPool.length;
      return s;
    }
  }
  return null;
}

function sendFrame(cmd, id, data) {
  if (!data || data.length <= MAX_PAYLOAD) {
    const s = pickSocket();
    if (!s) return false;
    return s.write(frame(cmd, id, data));
  }
  let off = 0;
  while (off < data.length) {
    const s = pickSocket();
    if (!s) return false;
    const chunk = data.slice(off, Math.min(off + MAX_PAYLOAD, data.length));
    s.write(frame(cmd, id, chunk));
    off += MAX_PAYLOAD;
  }
  return true;
}

function isTunnelReady() {
  return tunnelPool.some(s => s && !s.destroyed && s.writable);
}

// === SERVIDOR PRINCIPAL ===
const server = net.createServer({ noDelay: true }, (socket) => {
  socket.setNoDelay(true);
  socket.setKeepAlive(true, 15000);
  
  let firstData = true;
  let buf = Buffer.alloc(0);
  
  const onFirstData = (chunk) => {
    if (!firstData) return;
    firstData = false;
    socket.removeListener('data', onFirstData);
    
    buf = chunk;
    const firstByte = chunk[0];
    const str = chunk.toString('utf8', 0, Math.min(chunk.length, 500));
    
    log('CONN', `Novo socket | byte0=0x${firstByte.toString(16)} | str="${str.slice(0,40).replace(/\n/g,'\\n')}"`);
    
    // Detectar tipo de conexão
    if (str.trimEnd().startsWith(TUNNEL_SECRET)) {
      // É um túnel do celular
      handleTunnel(socket, str.trimEnd());
    } else if (firstByte === 0x05) {
      // SOCKS5
      handleSocks5(socket, chunk);
    } else if (str.startsWith('CONNECT ')) {
      // HTTP CONNECT proxy
      handleHttpConnect(socket, str);
    } else if (/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH) /.test(str)) {
      // HTTP proxy ou health check
      handleHttpProxy(socket, str, chunk);
    } else {
      log('CONN', 'Conexão desconhecida, fechando');
      socket.destroy();
    }
  };
  
  socket.on('data', onFirstData);
  socket.on('error', () => {});
  socket.setTimeout(30000, () => { socket.destroy(); });
});

server.listen(PORT, '0.0.0.0', () => {
  log('OK', `Servidor ativo na porta ${PORT}`);
});

// === HEALTH CHECK HTTP (porta separada para Railway) ===
const hServer = http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type':'application/json'});
  res.end(JSON.stringify({v:'7.1', tunnel: isTunnelReady(), pool: tunnelPool.filter(s=>s&&!s.destroyed).length, streams: streams.size}));
});
hServer.listen(PORT + 1, () => log('OK', `Health na porta ${PORT+1}`));

// === TÚNEL ===
function handleTunnel(socket, msg) {
  const parts = msg.split(':');
  // parts[0] = secret, parts[1] = poolIndex (opcional)
  let poolIdx = 0;
  if (parts.length >= 2) {
    const parsed = parseInt(parts[parts.length - 1]);
    if (!isNaN(parsed) && parsed >= 0 && parsed < POOL_SIZE) poolIdx = parsed;
  }
  
  // Destruir slot antigo
  if (tunnelPool[poolIdx] && !tunnelPool[poolIdx].destroyed) {
    tunnelPool[poolIdx].removeAllListeners();
    tunnelPool[poolIdx].destroy();
  }
  
  socket.setNoDelay(true);
  socket.setKeepAlive(true, 10000);
  socket.setTimeout(0); // Sem timeout para túnel
  socket._buf = Buffer.alloc(0);
  tunnelPool[poolIdx] = socket;
  
  socket.write('OK\n');
  log('POOL', `Slot ${poolIdx} conectado | Total: ${tunnelPool.filter(s=>s&&!s.destroyed).length}/${POOL_SIZE}`);
  
  // Processar frames do túnel
  socket.on('data', (data) => {
    socket._buf = socket._buf.length > 0 ? Buffer.concat([socket._buf, data]) : data;
    
    while (socket._buf.length >= HDR) {
      const payloadLen = socket._buf.readUInt16BE(3);
      const totalLen = HDR + payloadLen;
      if (socket._buf.length < totalLen) break;
      
      const cmd = socket._buf[0];
      const id = socket._buf.readUInt16BE(1);
      const payload = payloadLen > 0 ? socket._buf.slice(HDR, totalLen) : null;
      socket._buf = socket._buf.slice(totalLen);
      
      switch(cmd) {
        case CMD.CONNECTED: {
          const p = pending.get(id);
          if (p) {
            pending.delete(id);
            log('STREAM', `#${id} conectado → respondendo ao PC`);
            if (p.mode === 'socks5') {
              p.socket.write(Buffer.from([0x05,0x00,0x00,0x01,0,0,0,0,0,0]));
            } else {
              p.socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
            }
            if (p.extra && p.extra.length > 0) {
              sendFrame(CMD.DATA, id, p.extra);
            }
            setupStream(id, p.socket);
          }
          break;
        }
        case CMD.DATA: {
          const s = streams.get(id);
          if (s && !s.socket.destroyed) {
            s.socket.write(payload);
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
          try { socket.write(frame(CMD.PING, 0, null)); } catch(e) {}
          break;
      }
    }
  });
  
  socket.on('close', () => {
    if (tunnelPool[poolIdx] === socket) tunnelPool[poolIdx] = null;
    log('POOL', `Slot ${poolIdx} desconectou | Total: ${tunnelPool.filter(s=>s&&!s.destroyed).length}/${POOL_SIZE}`);
  });
  socket.on('error', () => {
    if (tunnelPool[poolIdx] === socket) tunnelPool[poolIdx] = null;
  });
  
  // Keepalive ping
  const iv = setInterval(() => {
    if (socket.destroyed) { clearInterval(iv); return; }
    try { socket.write(frame(CMD.PING, 0, null)); } catch(e) { clearInterval(iv); }
  }, 20000);
  socket.on('close', () => clearInterval(iv));
}

// === STREAM (PC ↔ Celular) ===
function setupStream(id, socket) {
  socket.setTimeout(0);
  streams.set(id, { socket });
  
  socket.on('data', (d) => {
    sendFrame(CMD.DATA, id, d);
  });
  
  const cleanup = () => {
    if (streams.has(id)) {
      streams.delete(id);
      sendFrame(CMD.CLOSE, id, null);
    }
  };
  socket.on('close', cleanup);
  socket.on('error', cleanup);
}

// === HTTP CONNECT ===
function handleHttpConnect(socket, str) {
  const lines = str.split('\r\n');
  const m = lines[0].match(/^CONNECT\s+([^:\s]+):(\d+)\s+HTTP/i);
  if (!m) {
    log('HTTP', 'CONNECT inválido: ' + lines[0]);
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
    socket.destroy();
    return;
  }
  
  if (!checkAuth(lines)) {
    log('HTTP', 'Auth falhou para CONNECT ' + m[1]);
    socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\n\r\n');
    socket.destroy();
    return;
  }
  
  const host = m[1], port = parseInt(m[2]);
  log('HTTP', `CONNECT ${host}:${port} | tunnel=${isTunnelReady()}`);
  
  if (!isTunnelReady()) {
    socket.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
    socket.destroy();
    return;
  }
  
  const id = nextId++;
  if (nextId > 65534) nextId = 1;
  
  sendFrame(CMD.CONNECT, id, Buffer.from(`${host}:${port}`));
  pending.set(id, { socket, mode: 'http', extra: null, ts: Date.now() });
  log('STREAM', `#${id} pendente → ${host}:${port}`);
  
  // Timeout
  setTimeout(() => {
    if (pending.has(id)) {
      log('STREAM', `#${id} TIMEOUT`);
      pending.delete(id);
      socket.write('HTTP/1.1 504 Gateway Timeout\r\n\r\n');
      socket.destroy();
    }
  }, 10000);
}

// === HTTP PROXY (GET/POST direto) ===
function handleHttpProxy(socket, str, chunk) {
  const lines = str.split('\r\n');
  const pm = lines[0].match(/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+http:\/\/([^\/:\s]+)(?::(\d+))?(\/\S*)\s+HTTP/i);
  
  if (!pm) {
    // Health check
    const b = JSON.stringify({status:'online', tunnel: isTunnelReady(), pool: tunnelPool.filter(s=>s&&!s.destroyed).length});
    socket.write(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(b)}\r\n\r\n${b}`);
    socket.end();
    return;
  }
  
  if (!checkAuth(lines)) {
    socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\n\r\n');
    socket.destroy();
    return;
  }
  
  if (!isTunnelReady()) {
    socket.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
    socket.destroy();
    return;
  }
  
  const host = pm[2], port = parseInt(pm[3]||'80'), path = pm[4];
  lines[0] = `${pm[1]} ${path} HTTP/1.1`;
  const filtered = lines.filter(l => !/^Proxy-Auth/i.test(l));
  const extra = Buffer.from(filtered.join('\r\n'));
  
  const id = nextId++;
  if (nextId > 65534) nextId = 1;
  
  sendFrame(CMD.CONNECT, id, Buffer.from(`${host}:${port}`));
  pending.set(id, { socket, mode: 'http-plain', extra, ts: Date.now() });
  
  setTimeout(() => {
    if (pending.has(id)) {
      pending.delete(id);
      socket.write('HTTP/1.1 504 Gateway Timeout\r\n\r\n');
      socket.destroy();
    }
  }, 10000);
}

// === SOCKS5 ===
function handleSocks5(socket, chunk) {
  socket.setTimeout(0);
  const nm = chunk[1];
  socket.write(Buffer.from([0x05, 0x02])); // requer user/pass auth
  
  let remaining = chunk.slice(2 + nm);
  if (remaining.length > 0) socks5Auth(socket, remaining);
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
    socket.write(Buffer.from([0x01,0x01]));
    socket.destroy();
    return;
  }
  socket.write(Buffer.from([0x01,0x00])); // auth OK
  
  let rest = buf.slice(3+ulen+plen);
  if (rest.length > 0) socks5Req(socket, rest);
  else socket.once('data', (d) => socks5Req(socket, d));
}

function socks5Req(socket, buf) {
  if (buf.length < 4) { socket.destroy(); return; }
  const atyp = buf[3];
  let host, port, end;
  
  if (atyp === 1) { // IPv4
    if (buf.length < 10) { socket.destroy(); return; }
    host = `${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}`;
    port = buf.readUInt16BE(8); end = 10;
  } else if (atyp === 3) { // Domain
    const dl = buf[4];
    if (buf.length < 5+dl+2) { socket.destroy(); return; }
    host = buf.slice(5, 5+dl).toString();
    port = buf.readUInt16BE(5+dl); end = 7+dl;
  } else if (atyp === 4) { // IPv6
    if (buf.length < 22) { socket.destroy(); return; }
    const p = []; for(let i=0;i<16;i+=2) p.push(buf.readUInt16BE(4+i).toString(16));
    host = p.join(':'); port = buf.readUInt16BE(20); end = 22;
  } else { socket.destroy(); return; }
  
  log('SOCKS5', `CONNECT ${host}:${port} | tunnel=${isTunnelReady()}`);
  
  if (!isTunnelReady()) {
    socket.write(Buffer.from([0x05,0x05,0x00,0x01,0,0,0,0,0,0]));
    socket.destroy();
    return;
  }
  
  const extra = end < buf.length ? buf.slice(end) : null;
  const id = nextId++;
  if (nextId > 65534) nextId = 1;
  
  sendFrame(CMD.CONNECT, id, Buffer.from(`${host}:${port}`));
  pending.set(id, { socket, mode: 'socks5', extra, ts: Date.now() });
  
  setTimeout(() => {
    if (pending.has(id)) {
      pending.delete(id);
      socket.write(Buffer.from([0x05,0x05,0x00,0x01,0,0,0,0,0,0]));
      socket.destroy();
    }
  }, 10000);
}

// === AUTH ===
function checkAuth(lines) {
  for (const l of lines) {
    const m = l.match(/^Proxy-Authorization:\s*Basic\s+(.+)$/i);
    if (m) {
      const decoded = Buffer.from(m[1].trim(), 'base64').toString();
      const idx = decoded.indexOf(':');
      if (idx < 0) return false;
      return decoded.slice(0, idx) === PROXY_USER && decoded.slice(idx+1) === PROXY_PASS;
    }
  }
  return false;
}

// === LIMPEZA ===
setInterval(() => {
  const now = Date.now();
  for (const [id, p] of pending) {
    if (now - p.ts > 15000) {
      pending.delete(id);
      try { p.socket.destroy(); } catch(e) {}
    }
  }
}, 10000);

process.on('uncaughtException', (e) => log('ERR', e.message));
process.on('SIGTERM', () => { log('EXIT', 'Encerrando'); process.exit(0); });
