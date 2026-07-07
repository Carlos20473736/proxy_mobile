const net = require('net');
const http = require('http');

// === CONFIGURAÇÃO ===
// Railway define PORT automaticamente. O TCP Proxy deve apontar para esta mesma porta.
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

console.log('=== 5G-SHARE v2.2 ===');
console.log(`Porta: ${PORT}`);
console.log(`User: ${PROXY_USER}`);
console.log(`Pass: ${PROXY_PASS}`);
console.log(`Secret: ${TUNNEL_SECRET}`);
console.log('=====================');

// === SERVIDOR PRINCIPAL - UMA PORTA PRA TUDO ===
const server = net.createServer((socket) => {
    let firstData = true;
    let handledAs = null;

    socket.once('data', (chunk) => {
        const firstByte = chunk[0];

        if (firstByte === 0x05) {
            // SOCKS5 do PC
            handledAs = 'socks5';
            handleSocks5(socket, chunk);
        } else if (firstByte === 0x47 || firstByte === 0x48) {
            // GET ou HEAD - HTTP health check
            handledAs = 'http';
            handleHttp(socket, chunk);
        } else {
            // Túnel do celular
            handledAs = 'tunnel';
            handleTunnel(socket, chunk);
        }
    });

    socket.on('error', () => {});
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`[OK] Servidor rodando na porta ${PORT}`);
    console.log('[OK] Aguardando conexões...');
});

// === HTTP HANDLER (health check) ===
function handleHttp(socket, chunk) {
    const req = chunk.toString();
    const body = JSON.stringify({
        status: 'online',
        tunnel: tunnelSocket !== null && !tunnelSocket.destroyed,
        connections: activePipes.size,
        uptime: process.uptime()
    });
    const response = `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`;
    socket.write(response);
    socket.end();
}

// === TUNNEL HANDLER (CELULAR) ===
function handleTunnel(socket, chunk) {
    const msg = chunk.toString('utf8').trim();
    console.log(`[TUNNEL] Recebido auth: "${msg}" (esperado: "${TUNNEL_SECRET}")`);

    if (msg === TUNNEL_SECRET) {
        if (tunnelSocket && !tunnelSocket.destroyed) {
            console.log('[TUNNEL] Fechando túnel anterior');
            tunnelSocket.destroy();
        }

        tunnelSocket = socket;
        tunnelBuffer = '';
        socket.write('OK\n');
        console.log('[TUNNEL] Celular autenticado e conectado!');

        socket.setKeepAlive(true, 15000);
        socket.setNoDelay(true);
        socket.setTimeout(0);

        socket.on('data', (data) => {
            processTunnelData(data);
        });

        socket.on('close', () => {
            console.log('[TUNNEL] Celular desconectou');
            if (tunnelSocket === socket) tunnelSocket = null;
        });

        socket.on('error', (err) => {
            console.log('[TUNNEL] Erro:', err.message);
            if (tunnelSocket === socket) tunnelSocket = null;
        });
    } else {
        console.log('[TUNNEL] Auth FALHOU - fechando');
        socket.destroy();
    }
}

// === SOCKS5 HANDLER (PC) ===
function handleSocks5(socket, firstChunk) {
    let state = 'greeting';
    let buf = firstChunk;

    function process() {
        if (state === 'greeting') {
            if (buf.length < 3) return;
            const nmethods = buf[1];
            if (buf.length < 2 + nmethods) return;
            socket.write(Buffer.from([0x05, 0x02])); // requer user/pass
            buf = buf.slice(2 + nmethods);
            state = 'auth';
            process();
        }
        else if (state === 'auth') {
            if (buf.length < 2) return;
            const ulen = buf[1];
            if (buf.length < 2 + ulen + 1) return;
            const user = buf.slice(2, 2 + ulen).toString();
            const plen = buf[2 + ulen];
            if (buf.length < 2 + ulen + 1 + plen) return;
            const pass = buf.slice(2 + ulen + 1, 2 + ulen + 1 + plen).toString();

            if (user === PROXY_USER && pass === PROXY_PASS) {
                socket.write(Buffer.from([0x01, 0x00])); // auth ok
                buf = buf.slice(2 + ulen + 1 + plen);
                state = 'request';
                process();
            } else {
                console.log(`[SOCKS5] Auth falhou: ${user}/${pass}`);
                socket.write(Buffer.from([0x01, 0x01]));
                socket.destroy();
            }
        }
        else if (state === 'request') {
            if (buf.length < 4) return;
            const cmd = buf[1];
            const atyp = buf[3];
            let host, port, hlen;

            if (atyp === 0x01) {
                if (buf.length < 10) return;
                host = `${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}`;
                port = buf.readUInt16BE(8);
                hlen = 10;
            } else if (atyp === 0x03) {
                const dlen = buf[4];
                if (buf.length < 5 + dlen + 2) return;
                host = buf.slice(5, 5 + dlen).toString();
                port = buf.readUInt16BE(5 + dlen);
                hlen = 5 + dlen + 2;
            } else if (atyp === 0x04) {
                if (buf.length < 22) return;
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
            buf = Buffer.alloc(0);
            state = 'connected';

            console.log(`[SOCKS5] → ${host}:${port}`);

            if (tunnelSocket && !tunnelSocket.destroyed) {
                tunnelConnect(socket, host, port, remaining);
            } else {
                directConnect(socket, host, port, remaining);
            }
        }
    }

    socket.on('data', (data) => {
        if (state !== 'connected') {
            buf = Buffer.concat([buf, data]);
            process();
        }
    });

    process();
}

// === CONEXÃO VIA CELULAR ===
function tunnelConnect(client, host, port, extra) {
    const id = connectionId++;
    const req = JSON.stringify({ type: 'connect', id, host, port }) + '\n';

    try {
        tunnelSocket.write(req);
    } catch (e) {
        directConnect(client, host, port, extra);
        return;
    }

    pendingConnections.set(id, { client, host, port, extra, ts: Date.now() });

    setTimeout(() => {
        if (pendingConnections.has(id)) {
            console.log(`[TUNNEL] Timeout ${host}:${port}, fallback direto`);
            pendingConnections.delete(id);
            directConnect(client, host, port, extra);
        }
    }, 15000);
}

// === CONEXÃO DIRETA (fallback) ===
function directConnect(client, host, port, extra) {
    const remote = net.createConnection({ host, port }, () => {
        client.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
        if (extra && extra.length) remote.write(extra);
        client.pipe(remote);
        remote.pipe(client);
    });
    remote.on('error', () => {
        client.write(Buffer.from([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
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
                    p.client.write(Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
                    if (p.extra && p.extra.length) {
                        tunnelSocket.write(JSON.stringify({ type: 'data', id: msg.id, payload: p.extra.toString('base64') }) + '\n');
                    }
                    setupPipe(msg.id, p.client);
                }
            } else if (msg.type === 'error') {
                const p = pendingConnections.get(msg.id);
                if (p) {
                    pendingConnections.delete(msg.id);
                    directConnect(p.client, p.host, p.port, p.extra);
                }
            } else if (msg.type === 'data') {
                const c = activePipes.get(msg.id);
                if (c && !c.destroyed) c.write(Buffer.from(msg.payload, 'base64'));
            } else if (msg.type === 'close') {
                const c = activePipes.get(msg.id);
                if (c) { c.end(); activePipes.delete(msg.id); }
            } else if (msg.type === 'ping') {
                if (tunnelSocket && !tunnelSocket.destroyed)
                    tunnelSocket.write(JSON.stringify({ type: 'pong' }) + '\n');
            }
        } catch (e) {}
    }
}

// === PIPE PC ↔ CELULAR ===
function setupPipe(id, client) {
    activePipes.set(id, client);
    client.on('data', (d) => {
        if (tunnelSocket && !tunnelSocket.destroyed)
            tunnelSocket.write(JSON.stringify({ type: 'data', id, payload: d.toString('base64') }) + '\n');
    });
    const cleanup = () => {
        activePipes.delete(id);
        if (tunnelSocket && !tunnelSocket.destroyed)
            tunnelSocket.write(JSON.stringify({ type: 'close', id }) + '\n');
    };
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
