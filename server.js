const net = require('net');

// === CONFIGURAÇÃO ===
const PORT = parseInt(process.env.PORT || '7777');
const PROXY_USER = process.env.PROXY_USER || '5guser';
const PROXY_PASS = process.env.PROXY_PASS || 'senha123';
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'senha123';

// Conexão do celular
let tunnelSocket = null;
let tunnelBuffer = '';
const pendingConnections = new Map();
const activePipes = new Map();
let connectionId = 0;

console.log('=== 5G-SHARE v3.0 ===');
console.log(`Porta: ${PORT}`);
console.log(`User: ${PROXY_USER}`);
console.log(`Protocolos: SOCKS5 + HTTP CONNECT`);
console.log('=====================');

// === SERVIDOR PRINCIPAL ===
const server = net.createServer((socket) => {
    socket.once('data', (chunk) => {
        const firstByte = chunk[0];
        if (firstByte === 0x05) {
            // SOCKS5
            handleSocks5(socket, chunk);
        } else if (firstByte === 0x43) {
            // 'C' = CONNECT method (HTTP CONNECT proxy)
            handleHttpConnect(socket, chunk);
        } else if (firstByte === 0x47 || firstByte === 0x48 || firstByte === 0x50) {
            // G=GET, H=HEAD, P=POST - pode ser HTTP proxy ou health check
            handleHttpProxy(socket, chunk);
        } else {
            // Verificar se é tunnel secret
            const msg = chunk.toString('utf8').trim();
            if (msg === TUNNEL_SECRET) {
                handleTunnel(socket, msg);
            } else {
                console.log(`[IGNORE] Conexão desconhecida: "${msg.substring(0, 20)}"`);
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
    const firstLine = lines[0];

    // Parse: CONNECT host:port HTTP/1.1
    const match = firstLine.match(/^CONNECT\s+([^:\s]+):(\d+)\s+HTTP\/\d\.\d$/i);
    if (!match) {
        socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
        socket.destroy();
        return;
    }

    const host = match[1];
    const port = parseInt(match[2]);

    // Verificar autenticação Proxy-Authorization
    let authenticated = false;
    for (const line of lines) {
        const authMatch = line.match(/^Proxy-Authorization:\s*Basic\s+(.+)$/i);
        if (authMatch) {
            const decoded = Buffer.from(authMatch[1], 'base64').toString();
            const [user, pass] = decoded.split(':');
            if (user === PROXY_USER && pass === PROXY_PASS) {
                authenticated = true;
            }
            break;
        }
    }

    if (!authenticated) {
        console.log(`[HTTP] Auth requerida para ${host}:${port}`);
        socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\nContent-Length: 0\r\n\r\n');
        socket.destroy();
        return;
    }

    console.log(`[HTTP] CONNECT → ${host}:${port}`);

    if (tunnelSocket && !tunnelSocket.destroyed) {
        tunnelConnectHttp(socket, host, port);
    } else {
        directConnectHttp(socket, host, port);
    }
}

// === HTTP PROXY (GET/POST/etc via proxy) ===
function handleHttpProxy(socket, chunk) {
    const request = chunk.toString('utf8');
    const lines = request.split('\r\n');
    const firstLine = lines[0];

    // Verificar se é um request com URL absoluta (proxy HTTP)
    const proxyMatch = firstLine.match(/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+http:\/\/([^\/:\s]+)(?::(\d+))?(\/\S*)\s+HTTP\/\d\.\d$/i);

    if (!proxyMatch) {
        // É um health check normal, não um proxy request
        const body = JSON.stringify({
            status: 'online',
            tunnel: tunnelSocket !== null && !tunnelSocket.destroyed,
            connections: activePipes.size,
            protocols: ['socks5', 'http-connect', 'http-proxy']
        });
        socket.write(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`);
        socket.end();
        return;
    }

    // É um HTTP proxy request
    const method = proxyMatch[1];
    const host = proxyMatch[2];
    const port = parseInt(proxyMatch[3] || '80');
    const path = proxyMatch[4];

    // Verificar autenticação
    let authenticated = false;
    for (const line of lines) {
        const authMatch = line.match(/^Proxy-Authorization:\s*Basic\s+(.+)$/i);
        if (authMatch) {
            const decoded = Buffer.from(authMatch[1], 'base64').toString();
            const [user, pass] = decoded.split(':');
            if (user === PROXY_USER && pass === PROXY_PASS) {
                authenticated = true;
            }
            break;
        }
    }

    if (!authenticated) {
        socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\nContent-Length: 0\r\n\r\n');
        socket.destroy();
        return;
    }

    console.log(`[HTTP] ${method} → ${host}:${port}${path}`);

    // Reescrever o request com path relativo (remover URL absoluta)
    const newFirstLine = `${method} ${path} HTTP/1.1`;
    const filteredLines = lines.filter(l => !l.match(/^Proxy-Authorization/i));
    filteredLines[0] = newFirstLine;
    const newRequest = filteredLines.join('\r\n');
    const reqBuffer = Buffer.from(newRequest);

    if (tunnelSocket && !tunnelSocket.destroyed) {
        tunnelConnect(socket, host, port, reqBuffer, 'http');
    } else {
        directConnect(socket, host, port, reqBuffer, 'http');
    }
}

// === TUNNEL CONNECT para HTTP CONNECT ===
function tunnelConnectHttp(client, host, port) {
    const id = connectionId++;

    try {
        tunnelSocket.write(JSON.stringify({ type: 'connect', id, host, port }) + '\n');
    } catch (e) {
        directConnectHttp(client, host, port);
        return;
    }

    pendingConnections.set(id, { client, host, port, extra: null, mode: 'http-connect', ts: Date.now() });

    setTimeout(() => {
        if (pendingConnections.has(id)) {
            console.log(`[TIMEOUT] ${host}:${port}`);
            pendingConnections.delete(id);
            directConnectHttp(client, host, port);
        }
    }, 15000);
}

// === DIRECT CONNECT para HTTP CONNECT ===
function directConnectHttp(client, host, port) {
    const remote = net.createConnection({ host, port }, () => {
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        client.pipe(remote);
        remote.pipe(client);
    });
    remote.on('error', () => {
        client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
        client.destroy();
    });
    client.on('close', () => remote.destroy());
    remote.on('close', () => client.destroy());
}

// === TÚNEL (CELULAR) ===
function handleTunnel(socket, secret) {
    console.log('[TUNNEL] Nova conexão do celular');

    if (tunnelSocket && !tunnelSocket.destroyed) {
        try {
            tunnelSocket.removeAllListeners('data');
            tunnelSocket.removeAllListeners('close');
            tunnelSocket.removeAllListeners('error');
            tunnelSocket.destroy();
        } catch (e) {}
    }

    tunnelSocket = socket;
    tunnelBuffer = '';
    socket.write('OK\n');
    console.log('[TUNNEL] Celular autenticado!');

    socket.setKeepAlive(true, 30000);
    socket.setNoDelay(true);
    socket.setTimeout(0);

    socket.on('data', processTunnelData);
    socket.on('close', () => {
        if (tunnelSocket === socket) {
            tunnelSocket = null;
            console.log('[TUNNEL] Celular desconectou');
        }
    });
    socket.on('error', (err) => {
        if (tunnelSocket === socket) {
            tunnelSocket = null;
            console.log('[TUNNEL] Erro:', err.message);
        }
    });
}

// === SOCKS5 (PC) ===
function handleSocks5(socket, firstChunk) {
    let buf = firstChunk;

    const nmethods = buf[1];
    socket.write(Buffer.from([0x05, 0x02]));
    buf = buf.slice(2 + nmethods);

    if (buf.length > 0) {
        processAuth(socket, buf);
    } else {
        socket.once('data', (data) => processAuth(socket, data));
    }
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
        console.log(`[SOCKS5] Auth falhou: ${user}`);
        socket.write(Buffer.from([0x01, 0x01]));
        socket.destroy();
        return;
    }

    socket.write(Buffer.from([0x01, 0x00]));
    buf = buf.slice(2 + ulen + 1 + plen);

    if (buf.length > 0) {
        processRequest(socket, buf);
    } else {
        socket.once('data', (data) => processRequest(socket, data));
    }
}

function processRequest(socket, buf) {
    if (buf.length < 4) { socket.destroy(); return; }
    const cmd = buf[1];
    const atyp = buf[3];
    let host, port, hlen;

    if (atyp === 0x01) {
        if (buf.length < 10) { socket.destroy(); return; }
        host = `${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}`;
        port = buf.readUInt16BE(8);
        hlen = 10;
    } else if (atyp === 0x03) {
        const dlen = buf[4];
        if (buf.length < 5 + dlen + 2) { socket.destroy(); return; }
        host = buf.slice(5, 5 + dlen).toString();
        port = buf.readUInt16BE(5 + dlen);
        hlen = 5 + dlen + 2;
    } else if (atyp === 0x04) {
        if (buf.length < 22) { socket.destroy(); return; }
        const p = [];
        for (let i = 0; i < 16; i += 2) p.push(buf.readUInt16BE(4 + i).toString(16));
        host = p.join(':');
        port = buf.readUInt16BE(20);
        hlen = 22;
    } else {
        socket.write(Buffer.from([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        socket.destroy();
        return;
    }

    if (cmd !== 0x01) {
        socket.write(Buffer.from([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        socket.destroy();
        return;
    }

    const remaining = buf.slice(hlen);
    console.log(`[SOCKS5] → ${host}:${port}`);

    if (tunnelSocket && !tunnelSocket.destroyed) {
        tunnelConnect(socket, host, port, remaining, 'socks5');
    } else {
        directConnect(socket, host, port, remaining, 'socks5');
    }
}

// === CONEXÃO VIA CELULAR ===
function tunnelConnect(client, host, port, extra, mode) {
    const id = connectionId++;

    try {
        tunnelSocket.write(JSON.stringify({ type: 'connect', id, host, port }) + '\n');
    } catch (e) {
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
            else if (mode === 'http-connect') directConnectHttp(client, host, port);
            else directConnect(client, host, port, extra, mode);
        }
    }, 15000);
}

// === CONEXÃO DIRETA (fallback) ===
function directConnect(client, host, port, extra, mode) {
    const remote = net.createConnection({ host, port }, () => {
        if (mode === 'socks5') {
            client.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        }
        // Para HTTP proxy, não precisa de reply - já envia o request
        if (extra && extra.length) remote.write(extra);
        client.pipe(remote);
        remote.pipe(client);
    });
    remote.on('error', () => {
        if (mode === 'socks5') {
            client.write(Buffer.from([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        } else {
            client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
        }
        client.destroy();
    });
    client.on('close', () => remote.destroy());
    remote.on('close', () => client.destroy());
}

// === PROCESSAR DADOS DO TÚNEL ===
function processTunnelData(data) {
    tunnelBuffer += data.toString('utf8');
    let idx;
    while ((idx = tunnelBuffer.indexOf('\n')) !== -1) {
        const line = tunnelBuffer.slice(0, idx);
        tunnelBuffer = tunnelBuffer.slice(idx + 1);
        try {
            const msg = JSON.parse(line);

            if (msg.type === 'connected') {
                const p = pendingConnections.get(msg.id);
                if (p) {
                    pendingConnections.delete(msg.id);
                    if (p.mode === 'socks5') {
                        p.client.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
                    } else if (p.mode === 'http-connect') {
                        p.client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
                    }
                    // Para HTTP proxy mode, enviar o request original
                    if (p.extra && p.extra.length) {
                        tunnelSocket.write(JSON.stringify({ type: 'data', id: msg.id, payload: Buffer.from(p.extra).toString('base64') }) + '\n');
                    }
                    setupPipe(msg.id, p.client);
                }
            }
            else if (msg.type === 'error') {
                const p = pendingConnections.get(msg.id);
                if (p) {
                    pendingConnections.delete(msg.id);
                    if (p.mode === 'socks5') directConnect(p.client, p.host, p.port, p.extra, 'socks5');
                    else if (p.mode === 'http-connect') directConnectHttp(p.client, p.host, p.port);
                    else directConnect(p.client, p.host, p.port, p.extra, p.mode);
                }
            }
            else if (msg.type === 'data') {
                const c = activePipes.get(msg.id);
                if (c && !c.destroyed) c.write(Buffer.from(msg.payload, 'base64'));
            }
            else if (msg.type === 'close') {
                const c = activePipes.get(msg.id);
                if (c) { c.end(); activePipes.delete(msg.id); }
            }
            else if (msg.type === 'ping') {
                if (tunnelSocket && !tunnelSocket.destroyed)
                    tunnelSocket.write(JSON.stringify({ type: 'pong' }) + '\n');
            }
        } catch (e) {}
    }
}

// === PIPE PC ↔ CELULAR ===
function setupPipe(id, client) {
    activePipes.set(id, client);

    const onData = (d) => {
        if (tunnelSocket && !tunnelSocket.destroyed)
            tunnelSocket.write(JSON.stringify({ type: 'data', id, payload: d.toString('base64') }) + '\n');
    };

    const cleanup = () => {
        client.removeListener('data', onData);
        activePipes.delete(id);
        if (tunnelSocket && !tunnelSocket.destroyed)
            tunnelSocket.write(JSON.stringify({ type: 'close', id }) + '\n');
    };

    client.on('data', onData);
    client.on('close', cleanup);
    client.on('error', cleanup);
}

// === LIMPEZA ===
setInterval(() => {
    const now = Date.now();
    for (const [id, c] of pendingConnections) {
        if (now - c.ts > 30000) { pendingConnections.delete(id); c.client.destroy(); }
    }
}, 30000);

process.on('SIGTERM', () => { server.close(); process.exit(0); });
