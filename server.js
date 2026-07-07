const net = require('net');

// === CONFIGURAÇÃO ===
const PORT = parseInt(process.env.PORT || '7777');
const PROXY_USER = process.env.PROXY_USER || '5guser';
const PROXY_PASS = process.env.PROXY_PASS || 'senha123';
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'senha123';

// Conexão do celular
let tunnelSocket = null;
let tunnelRawBuf = Buffer.alloc(0);
const pendingConnections = new Map();
const activePipes = new Map();
let connectionId = 0;

console.log('=== 5G-SHARE v4.0 SPEED ===');
console.log(`Porta: ${PORT}`);
console.log(`User: ${PROXY_USER}`);
console.log(`Protocolos: SOCKS5 + HTTP CONNECT`);
console.log('============================');

/*
  PROTOCOLO BINÁRIO DO TÚNEL (v4 - velocidade máxima):
  
  Header: [TYPE:1byte][ID:2bytes][LEN:4bytes][PAYLOAD:LEN bytes]
  
  Types:
    0x01 = connect request  (payload = JSON: {host, port})
    0x02 = connected
    0x03 = data             (payload = raw bytes, sem encoding)
    0x04 = close
    0x05 = error            (payload = error msg)
    0x06 = ping
    0x07 = pong
    
  Isso elimina:
  - Base64 encoding (+33% overhead)
  - JSON.stringify/parse para cada pacote de dados
  - Busca por \n delimitador em buffers grandes
*/

const TYPE_CONNECT = 0x01;
const TYPE_CONNECTED = 0x02;
const TYPE_DATA = 0x03;
const TYPE_CLOSE = 0x04;
const TYPE_ERROR = 0x05;
const TYPE_PING = 0x06;
const TYPE_PONG = 0x07;
const HEADER_SIZE = 7; // 1 + 2 + 4

function buildPacket(type, id, payload) {
    const plen = payload ? payload.length : 0;
    const buf = Buffer.allocUnsafe(HEADER_SIZE + plen);
    buf[0] = type;
    buf.writeUInt16BE(id, 1);
    buf.writeUInt32BE(plen, 3);
    if (payload && plen > 0) payload.copy(buf, HEADER_SIZE);
    return buf;
}

function buildPacketFromData(type, id, data) {
    const plen = data.length;
    const buf = Buffer.allocUnsafe(HEADER_SIZE + plen);
    buf[0] = type;
    buf.writeUInt16BE(id, 1);
    buf.writeUInt32BE(plen, 3);
    data.copy(buf, HEADER_SIZE);
    return buf;
}

function sendToTunnel(type, id, payload) {
    if (!tunnelSocket || tunnelSocket.destroyed) return false;
    try {
        if (payload) {
            tunnelSocket.write(buildPacketFromData(type, id, payload));
        } else {
            tunnelSocket.write(buildPacket(type, id, null));
        }
        return true;
    } catch(e) { return false; }
}

// === SERVIDOR PRINCIPAL ===
const server = net.createServer((socket) => {
    socket.setNoDelay(true);
    socket.once('data', (chunk) => {
        const firstByte = chunk[0];
        if (firstByte === 0x05) {
            handleSocks5(socket, chunk);
        } else if (firstByte === 0x43) {
            handleHttpConnect(socket, chunk);
        } else if (firstByte === 0x47 || firstByte === 0x48 || firstByte === 0x50) {
            handleHttpProxy(socket, chunk);
        } else {
            const msg = chunk.toString('utf8').trim();
            if (msg === TUNNEL_SECRET) {
                handleTunnel(socket, msg);
            } else {
                socket.destroy();
            }
        }
    });
    socket.on('error', () => {});
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`[OK] Rodando na porta ${PORT}`);
});

// === HTTP CONNECT PROXY ===
function handleHttpConnect(socket, chunk) {
    const request = chunk.toString('utf8');
    const lines = request.split('\r\n');
    const match = lines[0].match(/^CONNECT\s+([^:\s]+):(\d+)\s+HTTP\/\d\.\d$/i);
    if (!match) { socket.write('HTTP/1.1 400 Bad Request\r\n\r\n'); socket.destroy(); return; }

    const host = match[1];
    const port = parseInt(match[2]);

    if (!checkHttpAuth(lines)) {
        socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\nContent-Length: 0\r\n\r\n');
        socket.destroy();
        return;
    }

    console.log(`[HTTP] → ${host}:${port}`);
    if (tunnelSocket && !tunnelSocket.destroyed) {
        tunnelConnectGeneric(socket, host, port, null, 'http-connect');
    } else {
        directConnectHttp(socket, host, port);
    }
}

// === HTTP PROXY (GET/POST via proxy) ===
function handleHttpProxy(socket, chunk) {
    const request = chunk.toString('utf8');
    const lines = request.split('\r\n');
    const proxyMatch = lines[0].match(/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+http:\/\/([^\/:\s]+)(?::(\d+))?(\/\S*)\s+HTTP\/\d\.\d$/i);

    if (!proxyMatch) {
        const body = JSON.stringify({ status: 'online', tunnel: tunnelSocket !== null && !tunnelSocket.destroyed, connections: activePipes.size });
        socket.write(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`);
        socket.end();
        return;
    }

    if (!checkHttpAuth(lines)) {
        socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\nContent-Length: 0\r\n\r\n');
        socket.destroy();
        return;
    }

    const method = proxyMatch[1];
    const host = proxyMatch[2];
    const port = parseInt(proxyMatch[3] || '80');
    const path = proxyMatch[4];

    const newFirstLine = `${method} ${path} HTTP/1.1`;
    const filteredLines = lines.filter(l => !l.match(/^Proxy-Authorization/i));
    filteredLines[0] = newFirstLine;
    const reqBuffer = Buffer.from(filteredLines.join('\r\n'));

    console.log(`[HTTP] ${method} → ${host}:${port}`);
    if (tunnelSocket && !tunnelSocket.destroyed) {
        tunnelConnectGeneric(socket, host, port, reqBuffer, 'http');
    } else {
        directConnect(socket, host, port, reqBuffer, 'http');
    }
}

function checkHttpAuth(lines) {
    for (const line of lines) {
        const m = line.match(/^Proxy-Authorization:\s*Basic\s+(.+)$/i);
        if (m) {
            const decoded = Buffer.from(m[1], 'base64').toString();
            const sep = decoded.indexOf(':');
            if (sep === -1) return false;
            return decoded.slice(0, sep) === PROXY_USER && decoded.slice(sep + 1) === PROXY_PASS;
        }
    }
    return false;
}

// === DIRECT CONNECT HTTP ===
function directConnectHttp(client, host, port) {
    const remote = net.createConnection({ host, port }, () => {
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        remote.setNoDelay(true);
        client.pipe(remote);
        remote.pipe(client);
    });
    remote.on('error', () => { client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'); client.destroy(); });
    client.on('close', () => remote.destroy());
    remote.on('close', () => client.destroy());
}

// === TÚNEL (CELULAR) ===
function handleTunnel(socket, secret) {
    console.log('[TUNNEL] Nova conexão do celular');

    if (tunnelSocket && !tunnelSocket.destroyed) {
        try {
            tunnelSocket.removeAllListeners();
            tunnelSocket.destroy();
        } catch (e) {}
    }

    tunnelSocket = socket;
    tunnelRawBuf = Buffer.alloc(0);
    socket.write('OK\n');
    console.log('[TUNNEL] Celular autenticado! (protocolo binário v4)');

    socket.setKeepAlive(true, 30000);
    socket.setNoDelay(true);
    socket.setTimeout(0);

    // Buffer de alta performance para receber dados
    socket.on('data', processTunnelBinary);
    socket.on('close', () => {
        if (tunnelSocket === socket) { tunnelSocket = null; console.log('[TUNNEL] Celular desconectou'); }
    });
    socket.on('error', (err) => {
        if (tunnelSocket === socket) { tunnelSocket = null; console.log('[TUNNEL] Erro:', err.message); }
    });
}

// === PROCESSAR PROTOCOLO BINÁRIO DO TÚNEL ===
function processTunnelBinary(data) {
    tunnelRawBuf = Buffer.concat([tunnelRawBuf, data]);

    while (tunnelRawBuf.length >= HEADER_SIZE) {
        const type = tunnelRawBuf[0];
        const id = tunnelRawBuf.readUInt16BE(1);
        const plen = tunnelRawBuf.readUInt32BE(3);

        if (tunnelRawBuf.length < HEADER_SIZE + plen) break; // esperar mais dados

        const payload = plen > 0 ? tunnelRawBuf.slice(HEADER_SIZE, HEADER_SIZE + plen) : null;
        tunnelRawBuf = tunnelRawBuf.slice(HEADER_SIZE + plen);

        switch (type) {
            case TYPE_CONNECTED: {
                const p = pendingConnections.get(id);
                if (p) {
                    pendingConnections.delete(id);
                    if (p.mode === 'socks5') {
                        p.client.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
                    } else if (p.mode === 'http-connect') {
                        p.client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
                    }
                    if (p.extra && p.extra.length) {
                        sendToTunnel(TYPE_DATA, id, Buffer.from(p.extra));
                    }
                    setupPipe(id, p.client);
                }
                break;
            }
            case TYPE_DATA: {
                const c = activePipes.get(id);
                if (c && !c.destroyed) c.write(payload);
                break;
            }
            case TYPE_CLOSE: {
                const c = activePipes.get(id);
                if (c) { c.end(); activePipes.delete(id); }
                break;
            }
            case TYPE_ERROR: {
                const p = pendingConnections.get(id);
                if (p) {
                    pendingConnections.delete(id);
                    if (p.mode === 'socks5') directConnect(p.client, p.host, p.port, p.extra, 'socks5');
                    else if (p.mode === 'http-connect') directConnectHttp(p.client, p.host, p.port);
                    else directConnect(p.client, p.host, p.port, p.extra, p.mode);
                }
                break;
            }
            case TYPE_PONG:
                break;
        }
    }
}

// === SOCKS5 (PC) ===
function handleSocks5(socket, firstChunk) {
    let buf = firstChunk;
    const nmethods = buf[1];
    socket.write(Buffer.from([0x05, 0x02]));
    buf = buf.slice(2 + nmethods);
    if (buf.length > 0) processAuth(socket, buf);
    else socket.once('data', (data) => processAuth(socket, data));
}

function processAuth(socket, buf) {
    if (buf.length < 2) { socket.destroy(); return; }
    const ulen = buf[1];
    if (buf.length < 2 + ulen + 1) { socket.destroy(); return; }
    const user = buf.slice(2, 2 + ulen).toString();
    const plen = buf[2 + ulen];
    if (buf.length < 2 + ulen + 1 + plen) { socket.destroy(); return; }
    const pass = buf.slice(2 + ulen + 1, 2 + ulen + 1 + plen).toString();

    if (user !== PROXY_USER || pass !== PROXY_PASS) {
        socket.write(Buffer.from([0x01, 0x01])); socket.destroy(); return;
    }

    socket.write(Buffer.from([0x01, 0x00]));
    buf = buf.slice(2 + ulen + 1 + plen);
    if (buf.length > 0) processRequest(socket, buf);
    else socket.once('data', (data) => processRequest(socket, data));
}

function processRequest(socket, buf) {
    if (buf.length < 4) { socket.destroy(); return; }
    const cmd = buf[1]; const atyp = buf[3];
    let host, port, hlen;

    if (atyp === 0x01) {
        if (buf.length < 10) { socket.destroy(); return; }
        host = `${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}`;
        port = buf.readUInt16BE(8); hlen = 10;
    } else if (atyp === 0x03) {
        const dlen = buf[4];
        if (buf.length < 5 + dlen + 2) { socket.destroy(); return; }
        host = buf.slice(5, 5 + dlen).toString();
        port = buf.readUInt16BE(5 + dlen); hlen = 5 + dlen + 2;
    } else if (atyp === 0x04) {
        if (buf.length < 22) { socket.destroy(); return; }
        const p = []; for (let i = 0; i < 16; i += 2) p.push(buf.readUInt16BE(4 + i).toString(16));
        host = p.join(':'); port = buf.readUInt16BE(20); hlen = 22;
    } else {
        socket.write(Buffer.from([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0])); socket.destroy(); return;
    }

    if (cmd !== 0x01) {
        socket.write(Buffer.from([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0])); socket.destroy(); return;
    }

    const remaining = buf.slice(hlen);
    console.log(`[SOCKS5] → ${host}:${port}`);

    if (tunnelSocket && !tunnelSocket.destroyed) {
        tunnelConnectGeneric(socket, host, port, remaining, 'socks5');
    } else {
        directConnect(socket, host, port, remaining, 'socks5');
    }
}

// === CONEXÃO VIA CELULAR (genérico) ===
function tunnelConnectGeneric(client, host, port, extra, mode) {
    const id = connectionId++ % 65535; // 2 bytes max

    const connectPayload = Buffer.from(JSON.stringify({ host, port }));
    if (!sendToTunnel(TYPE_CONNECT, id, connectPayload)) {
        if (mode === 'socks5') directConnect(client, host, port, extra, mode);
        else directConnectHttp(client, host, port);
        return;
    }

    pendingConnections.set(id, { client, host, port, extra, mode, ts: Date.now() });

    setTimeout(() => {
        if (pendingConnections.has(id)) {
            console.log(`[TIMEOUT] ${host}:${port}`);
            pendingConnections.delete(id);
            if (mode === 'socks5') directConnect(client, host, port, extra, mode);
            else directConnectHttp(client, host, port);
        }
    }, 15000);
}

// === CONEXÃO DIRETA (fallback) ===
function directConnect(client, host, port, extra, mode) {
    const remote = net.createConnection({ host, port }, () => {
        remote.setNoDelay(true);
        if (mode === 'socks5') client.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        if (extra && extra.length) remote.write(extra);
        client.pipe(remote);
        remote.pipe(client);
    });
    remote.on('error', () => {
        if (mode === 'socks5') client.write(Buffer.from([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        else client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
        client.destroy();
    });
    client.on('close', () => remote.destroy());
    remote.on('close', () => client.destroy());
}

// === PIPE PC ↔ CELULAR ===
function setupPipe(id, client) {
    activePipes.set(id, client);

    const onData = (d) => { sendToTunnel(TYPE_DATA, id, d); };
    const cleanup = () => {
        client.removeListener('data', onData);
        activePipes.delete(id);
        sendToTunnel(TYPE_CLOSE, id, null);
    };

    client.on('data', onData);
    client.on('close', cleanup);
    client.on('error', cleanup);
}

// === KEEPALIVE ===
setInterval(() => {
    if (tunnelSocket && !tunnelSocket.destroyed) {
        sendToTunnel(TYPE_PING, 0, null);
    }
}, 25000);

// === LIMPEZA ===
setInterval(() => {
    const now = Date.now();
    for (const [id, c] of pendingConnections) {
        if (now - c.ts > 30000) { pendingConnections.delete(id); c.client.destroy(); }
    }
}, 30000);

process.on('SIGTERM', () => { server.close(); process.exit(0); });
