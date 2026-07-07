const net = require('net');
const http = require('http');

/*
  ╔══════════════════════════════════════════════════════════════╗
  ║  5G-SHARE v8.0 - KISS (Keep It Simple)                     ║
  ║                                                             ║
  ║  Arquitetura: 1 conexão de controle + N conexões de dados   ║
  ║  Cada stream PC↔Celular usa 1 conexão TCP dedicada          ║
  ║  ZERO multiplexação = ZERO bugs de protocolo                ║
  ║  Velocidade máxima: pipe() direto sem processar dados       ║
  ╚══════════════════════════════════════════════════════════════╝
  
  Fluxo:
  1. Celular conecta e envia "TUNNEL:<secret>\n" → servidor responde "OK\n"
  2. PC conecta com HTTP CONNECT ou SOCKS5
  3. Servidor envia para celular via controle: "OPEN:<id>:<host>:<port>\n"
  4. Celular abre nova conexão ao servidor: "DATA:<secret>:<id>\n"
  5. Servidor faz pipe() entre PC socket e DATA socket
  6. Dados fluem direto: PC ↔ Railway ↔ Celular ↔ Internet (zero overhead)
*/

const PORT = parseInt(process.env.PORT || '7777');
const PROXY_USER = process.env.PROXY_USER || '5guser';
const PROXY_PASS = process.env.PROXY_PASS || 'senha123';
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'senha123';

// Estado
let controlSocket = null; // Conexão de controle com o celular
const pendingStreams = new Map(); // id → { pcSocket, timeout }
const dataWaiting = new Map(); // id → celularDataSocket (celular conectou antes do PC responder)
let nextId = 1;

function log(msg) { console.log(`[${new Date().toISOString().slice(11,19)}] ${msg}`); }

log(`v8.0 KISS | Porta: ${PORT} | User: ${PROXY_USER}`);

// === SERVIDOR TCP ===
const server = net.createServer({ noDelay: true }, (socket) => {
  socket.setNoDelay(true);
  
  // Ler primeira linha para determinar tipo
  let buf = '';
  const onData = (chunk) => {
    buf += chunk.toString();
    const nl = buf.indexOf('\n');
    if (nl === -1) return; // Esperar mais dados
    
    socket.removeListener('data', onData);
    const firstLine = buf.slice(0, nl).trim();
    const rest = buf.slice(nl + 1);
    
    if (firstLine.startsWith('TUNNEL:')) {
      handleTunnel(socket, firstLine);
    } else if (firstLine.startsWith('DATA:')) {
      handleDataConnection(socket, firstLine, rest);
    } else {
      // É uma conexão de PC (HTTP CONNECT, SOCKS5, ou HTTP GET)
      // Precisa re-processar o buffer inteiro como binário
      const fullBuf = Buffer.from(buf.slice(0, nl + 1) + rest);
      // Na verdade, para HTTP/SOCKS5 o primeiro byte determina
      const rawChunk = chunk;
      // Reconstituir o buffer original
      socket._firstBuf = Buffer.from(buf, 'binary');
      handlePC(socket);
    }
  };
  socket.on('data', onData);
  socket.on('error', () => {});
  socket.setTimeout(15000, () => { if (!socket._identified) socket.destroy(); });
});

server.listen(PORT, '0.0.0.0', () => log(`Servidor ativo na porta ${PORT}`));

// Health check
const hServer = http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type':'application/json'});
  res.end(JSON.stringify({v:'8.0', tunnel: !!controlSocket && !controlSocket.destroyed, pending: pendingStreams.size}));
});
hServer.listen(PORT + 1, () => log(`Health na porta ${PORT+1}`));

// === TÚNEL DE CONTROLE ===
function handleTunnel(socket, line) {
  const secret = line.slice(7); // Remove "TUNNEL:"
  if (secret !== TUNNEL_SECRET) {
    socket.destroy();
    return;
  }
  
  // Fechar controle antigo
  if (controlSocket && !controlSocket.destroyed) {
    controlSocket.destroy();
  }
  
  controlSocket = socket;
  socket._identified = true;
  socket.setTimeout(0);
  socket.setKeepAlive(true, 10000);
  socket.write('OK\n');
  log('Celular conectado (controle)');
  
  // Keepalive
  const iv = setInterval(() => {
    if (socket.destroyed) { clearInterval(iv); return; }
    try { socket.write('PING\n'); } catch(e) { clearInterval(iv); }
  }, 20000);
  
  socket.on('data', (d) => {
    // Celular pode enviar PONG ou status
    // Ignorar por enquanto
  });
  
  socket.on('close', () => {
    if (controlSocket === socket) controlSocket = null;
    clearInterval(iv);
    log('Celular desconectou');
  });
  socket.on('error', () => {
    if (controlSocket === socket) controlSocket = null;
    clearInterval(iv);
  });
}

// === CONEXÃO DE DADOS (celular abre para cada stream) ===
function handleDataConnection(socket, line, rest) {
  // Formato: "DATA:<secret>:<id>"
  const parts = line.split(':');
  if (parts.length < 3 || parts[1] !== TUNNEL_SECRET) {
    socket.destroy();
    return;
  }
  
  const id = parseInt(parts[2]);
  socket._identified = true;
  socket.setTimeout(0);
  socket.setNoDelay(true);
  
  const pending = pendingStreams.get(id);
  if (!pending) {
    // PC já desistiu ou ID inválido
    socket.destroy();
    return;
  }
  
  // Limpar timeout
  clearTimeout(pending.timeout);
  pendingStreams.delete(id);
  
  const pcSocket = pending.pcSocket;
  
  // Responder ao PC que a conexão foi estabelecida
  if (pending.mode === 'http') {
    pcSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
  } else if (pending.mode === 'socks5') {
    pcSocket.write(Buffer.from([0x05,0x00,0x00,0x01,0,0,0,0,0,0]));
  }
  
  // Se tinha dados extras (HTTP plain), enviar para o celular
  if (pending.extra) {
    socket.write(pending.extra);
  }
  
  // Se rest tem dados, enviar para o PC
  if (rest && rest.length > 0) {
    pcSocket.write(rest);
  }
  
  // PIPE DIRETO - velocidade máxima, zero overhead!
  socket.pipe(pcSocket);
  pcSocket.pipe(socket);
  
  socket.on('error', () => pcSocket.destroy());
  pcSocket.on('error', () => socket.destroy());
  socket.on('close', () => pcSocket.destroy());
  pcSocket.on('close', () => socket.destroy());
  
  log(`Stream #${id} ativo (pipe direto)`);
}

// === CONEXÃO DO PC ===
function handlePC(socket) {
  socket._identified = true;
  const raw = socket._firstBuf;
  
  if (!raw || raw.length === 0) {
    socket.destroy();
    return;
  }
  
  const firstByte = raw[0];
  
  if (firstByte === 0x05) {
    // SOCKS5
    handleSocks5(socket, raw);
  } else {
    // HTTP
    const str = raw.toString();
    if (str.startsWith('CONNECT ')) {
      handleHttpConnect(socket, str);
    } else if (/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+http:\/\//.test(str)) {
      handleHttpProxy(socket, str);
    } else if (/^(GET|POST|HEAD)\s/.test(str)) {
      // Health check direto
      const b = JSON.stringify({v:'8.0', tunnel: !!controlSocket && !controlSocket.destroyed, pending: pendingStreams.size});
      socket.write(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(b)}\r\n\r\n${b}`);
      socket.end();
    } else {
      socket.destroy();
    }
  }
}

// === HTTP CONNECT ===
function handleHttpConnect(socket, str) {
  const lines = str.split('\r\n');
  const m = lines[0].match(/^CONNECT\s+([^:\s]+):(\d+)\s+HTTP/i);
  if (!m) { socket.write('HTTP/1.1 400 Bad\r\n\r\n'); socket.destroy(); return; }
  
  if (!checkAuth(lines)) {
    socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G"\r\n\r\n');
    socket.destroy(); return;
  }
  
  routeToTunnel(socket, m[1], parseInt(m[2]), null, 'http');
}

// === HTTP PROXY (GET/POST direto) ===
function handleHttpProxy(socket, str) {
  const lines = str.split('\r\n');
  const pm = lines[0].match(/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+http:\/\/([^\/:\s]+)(?::(\d+))?(\/\S*)\s+HTTP/i);
  if (!pm) { socket.destroy(); return; }
  
  if (!checkAuth(lines)) {
    socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G"\r\n\r\n');
    socket.destroy(); return;
  }
  
  const host = pm[2], port = parseInt(pm[3]||'80'), path = pm[4];
  lines[0] = `${pm[1]} ${path} HTTP/1.1`;
  const filtered = lines.filter(l => !/^Proxy-Auth/i.test(l));
  const extra = Buffer.from(filtered.join('\r\n'));
  
  routeToTunnel(socket, host, port, extra, 'http-plain');
}

// === SOCKS5 ===
function handleSocks5(socket, chunk) {
  socket.setTimeout(0);
  socket.write(Buffer.from([0x05, 0x02])); // requer auth
  
  socket.once('data', (d) => {
    // Auth
    if (d.length < 3) { socket.destroy(); return; }
    const ulen = d[1];
    const user = d.slice(2, 2+ulen).toString();
    const plen = d[2+ulen];
    const pass = d.slice(3+ulen, 3+ulen+plen).toString();
    
    if (user !== PROXY_USER || pass !== PROXY_PASS) {
      socket.write(Buffer.from([0x01,0x01])); socket.destroy(); return;
    }
    socket.write(Buffer.from([0x01,0x00]));
    
    socket.once('data', (req) => {
      if (req.length < 4) { socket.destroy(); return; }
      const atyp = req[3];
      let host, port;
      
      if (atyp === 1) {
        host = `${req[4]}.${req[5]}.${req[6]}.${req[7]}`;
        port = req.readUInt16BE(8);
      } else if (atyp === 3) {
        const dl = req[4];
        host = req.slice(5, 5+dl).toString();
        port = req.readUInt16BE(5+dl);
      } else if (atyp === 4) {
        const p = []; for(let i=0;i<16;i+=2) p.push(req.readUInt16BE(4+i).toString(16));
        host = p.join(':'); port = req.readUInt16BE(20);
      } else { socket.destroy(); return; }
      
      routeToTunnel(socket, host, port, null, 'socks5');
    });
  });
}

// === ROTEAR PARA O TÚNEL ===
function routeToTunnel(pcSocket, host, port, extra, mode) {
  if (!controlSocket || controlSocket.destroyed) {
    if (mode === 'http' || mode === 'http-plain') pcSocket.write('HTTP/1.1 502 Tunnel Offline\r\n\r\n');
    else if (mode === 'socks5') pcSocket.write(Buffer.from([0x05,0x05,0x00,0x01,0,0,0,0,0,0]));
    pcSocket.destroy();
    return;
  }
  
  const id = nextId++;
  if (nextId > 999999) nextId = 1;
  
  // Guardar PC socket pendente
  const timeout = setTimeout(() => {
    if (pendingStreams.has(id)) {
      pendingStreams.delete(id);
      if (mode === 'http' || mode === 'http-plain') pcSocket.write('HTTP/1.1 504 Timeout\r\n\r\n');
      else if (mode === 'socks5') pcSocket.write(Buffer.from([0x05,0x05,0x00,0x01,0,0,0,0,0,0]));
      pcSocket.destroy();
    }
  }, 15000);
  
  pendingStreams.set(id, { pcSocket, mode, extra, timeout });
  
  // Pedir ao celular para abrir conexão
  controlSocket.write(`OPEN:${id}:${host}:${port}\n`);
  log(`Stream #${id} → ${host}:${port}`);
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

// Limpeza
setInterval(() => {
  for (const [id, p] of pendingStreams) {
    if (p.pcSocket.destroyed) {
      clearTimeout(p.timeout);
      pendingStreams.delete(id);
    }
  }
}, 30000);

process.on('uncaughtException', (e) => log('ERR: ' + e.message));
