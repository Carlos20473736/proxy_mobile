const net = require('net');

/*
  ╔══════════════════════════════════════════════════════════════╗
  ║  5G-SHARE v8.2 - SOCKS5 SEM AUTH                            ║
  ║  SOCKS5 sem autenticação | Pipe direto | Velocidade máxima  ║
  ╚══════════════════════════════════════════════════════════════╝
*/

const PORT = parseInt(process.env.PORT || '7777');
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'senha123';

let controlSocket = null;
const pendingStreams = new Map();
let nextId = 1;

function log(msg) { console.log(`[${new Date().toISOString().slice(11,19)}] ${msg}`); }
log(`v8.2 SOCKS5 NO-AUTH | Porta: ${PORT}`);

// === SERVIDOR TCP ===
const server = net.createServer({ noDelay: true }, (socket) => {
  socket.setNoDelay(true);
  socket.once('data', (chunk) => {
    const firstByte = chunk[0];

    // SOCKS5: primeiro byte é 0x05
    if (firstByte === 0x05) {
      handleSocks5(socket, chunk);
      return;
    }

    // Texto: TUNNEL ou DATA
    let buf = chunk.toString();
    const nl = buf.indexOf('\n');
    if (nl === -1) {
      const onMore = (d) => {
        buf += d.toString();
        const n = buf.indexOf('\n');
        if (n === -1) return;
        socket.removeListener('data', onMore);
        routeText(socket, buf.slice(0, n).trim(), buf.slice(n + 1));
      };
      socket.on('data', onMore);
      return;
    }
    routeText(socket, buf.slice(0, nl).trim(), buf.slice(nl + 1));
  });

  socket.on('error', () => {});
  socket.setTimeout(15000, () => { if (!socket._ok) socket.destroy(); });
});

server.listen(PORT, '0.0.0.0', () => log(`Servidor ativo na porta ${PORT}`));

// === ROTEAMENTO TEXTO ===
function routeText(socket, line, rest) {
  if (line.startsWith('TUNNEL:')) {
    handleTunnel(socket, line);
  } else if (line.startsWith('DATA:')) {
    handleDataConnection(socket, line, rest);
  } else {
    const b = JSON.stringify({v:'8.2', tunnel: !!(controlSocket && !controlSocket.destroyed), pending: pendingStreams.size});
    socket.write(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(b)}\r\n\r\n${b}`);
    socket.end();
  }
}

// === TÚNEL DE CONTROLE ===
function handleTunnel(socket, line) {
  const secret = line.slice(7);
  if (secret !== TUNNEL_SECRET) { socket.destroy(); return; }

  if (controlSocket && !controlSocket.destroyed) controlSocket.destroy();

  controlSocket = socket;
  socket._ok = true;
  socket.setTimeout(0);
  socket.setKeepAlive(true, 10000);
  socket.write('OK\n');
  log('Celular conectado (controle)');

  const iv = setInterval(() => {
    if (socket.destroyed) { clearInterval(iv); return; }
    try { socket.write('PING\n'); } catch(e) { clearInterval(iv); }
  }, 20000);

  socket.on('data', () => {});
  socket.on('close', () => { if (controlSocket === socket) controlSocket = null; clearInterval(iv); log('Celular desconectou'); });
  socket.on('error', () => { if (controlSocket === socket) controlSocket = null; clearInterval(iv); });
}

// === CONEXÃO DE DADOS ===
function handleDataConnection(socket, line, rest) {
  const parts = line.split(':');
  if (parts.length < 3 || parts[1] !== TUNNEL_SECRET) { socket.destroy(); return; }

  const id = parseInt(parts[2]);
  socket._ok = true;
  socket.setTimeout(0);
  socket.setNoDelay(true);

  const pending = pendingStreams.get(id);
  if (!pending) { socket.destroy(); return; }

  clearTimeout(pending.timeout);
  pendingStreams.delete(id);

  const pcSocket = pending.pcSocket;

  // Responder SOCKS5 success ao PC (sem bind address)
  pcSocket.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));

  if (rest && rest.length > 0) {
    pcSocket.write(Buffer.from(rest, 'binary'));
  }

  // PIPE DIRETO
  socket.pipe(pcSocket);
  pcSocket.pipe(socket);

  socket.on('error', () => pcSocket.destroy());
  pcSocket.on('error', () => socket.destroy());
  socket.on('close', () => pcSocket.destroy());
  pcSocket.on('close', () => socket.destroy());

  log(`#${id} pipe ativo`);
}

// === SOCKS5 SEM AUTENTICAÇÃO ===
function handleSocks5(socket, chunk) {
  socket._ok = true;
  socket.setTimeout(0);

  // Responder: NO AUTH REQUIRED (method 0x00)
  socket.write(Buffer.from([0x05, 0x00]));

  socket.once('data', (req) => {
    // Request: [0x05, CMD, RSV, ATYP, ...]
    if (req.length < 4 || req[0] !== 0x05 || req[1] !== 0x01) {
      socket.write(Buffer.from([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
      socket.destroy();
      return;
    }

    const atyp = req[3];
    let host, port;

    if (atyp === 0x01) { // IPv4
      if (req.length < 10) { socket.destroy(); return; }
      host = `${req[4]}.${req[5]}.${req[6]}.${req[7]}`;
      port = req.readUInt16BE(8);
    } else if (atyp === 0x03) { // Domain
      const dlen = req[4];
      if (req.length < 5 + dlen + 2) { socket.destroy(); return; }
      host = req.slice(5, 5 + dlen).toString();
      port = req.readUInt16BE(5 + dlen);
    } else if (atyp === 0x04) { // IPv6
      if (req.length < 22) { socket.destroy(); return; }
      const parts = [];
      for (let i = 0; i < 16; i += 2) parts.push(req.readUInt16BE(4 + i).toString(16));
      host = parts.join(':');
      port = req.readUInt16BE(20);
    } else {
      socket.write(Buffer.from([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
      socket.destroy();
      return;
    }

    routeToTunnel(socket, host, port);
  });
}

// === ROTEAR PARA O TÚNEL ===
function routeToTunnel(pcSocket, host, port) {
  if (!controlSocket || controlSocket.destroyed) {
    pcSocket.write(Buffer.from([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
    pcSocket.destroy();
    return;
  }

  const id = nextId++;
  if (nextId > 999999) nextId = 1;

  const timeout = setTimeout(() => {
    if (pendingStreams.has(id)) {
      pendingStreams.delete(id);
      pcSocket.write(Buffer.from([0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
      pcSocket.destroy();
    }
  }, 15000);

  pendingStreams.set(id, { pcSocket, timeout });
  controlSocket.write(`OPEN:${id}:${host}:${port}\n`);
  log(`#${id} → ${host}:${port}`);
}

// Limpeza
setInterval(() => {
  for (const [id, p] of pendingStreams) {
    if (p.pcSocket.destroyed) { clearTimeout(p.timeout); pendingStreams.delete(id); }
  }
}, 30000);

process.on('uncaughtException', (e) => log('ERR: ' + e.message));
