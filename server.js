const net = require('net');
const http = require('http');

// === CONFIGURAÇÃO ===
const TCP_PORT = 7777; // Porta TCP pública (Railway TCP Proxy)
const HTTP_PORT = parseInt(process.env.PORT || '3000'); // Porta HTTP (health check)
const PROXY_USER = process.env.PROXY_USER || '5guser';
const PROXY_PASS = process.env.PROXY_PASS || 'senha123';
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'senha123';

// Conexão do celular
let tunnelSocket = null;
let tunnelAuthenticated = false;
let tunnelBuffer = '';
const pendingConnections = new Map();
const activePipes = new Map();
let connectionId = 0;

console.log('=== 5G-SHARE - Servidor Railway ===');
console.log(`TCP (SOCKS5 + Túnel): porta ${TCP_PORT}`);
console.log(`HTTP (health check): porta ${HTTP_PORT}`);
console.log(`Usuário: ${PROXY_USER}`);
console.log(`Público: hayabusa.proxy.rlwy.net:32618`);
console.log('===================================');

// === HEALTH CHECK HTTP (para Railway não matar o container) ===
const httpServer = http.createServer((req, res) => {
    if (req.url === '/health' || req.url === '/') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            status: 'online',
            tunnel: tunnelSocket !== null && !tunnelSocket.destroyed,
            connections: activePipes.size
        }));
    } else {
        res.writeHead(404);
        res.end();
    }
});

httpServer.listen(HTTP_PORT, '0.0.0.0', () => {
    console.log(`[HTTP] Health check na porta ${HTTP_PORT}`);
});

// === SERVIDOR TCP PRINCIPAL (porta 7777 → exposta como 32618) ===
const mainServer = net.createServer((socket) => {
    socket.once('data', (firstChunk) => {
        // Detectar tipo de conexão pelo primeiro byte
        if (firstChunk[0] === 0x05) {
            // SOCKS5 - conexão do PC
            handleSocks5(socket, firstChunk);
        } else {
            // Túnel - conexão do celular
            handleTunnel(socket, firstChunk);
        }
    });

    socket.on('error', () => {});
    socket.setTimeout(60000, () => {
        if (!tunnelSocket || tunnelSocket !== socket) {
            socket.destroy();
        }
    });
});

mainServer.listen(TCP_PORT, '0.0.0.0', () => {
    console.log(`[TCP] Servidor SOCKS5 + Túnel na porta ${TCP_PORT}`);
    console.log('[TCP] Aguardando celular e PC...');
});

// === HANDLER DO TÚNEL (CELULAR) ===
function handleTunnel(socket, firstChunk) {
    const msg = firstChunk.toString('utf8').trim();

    if (msg === TUNNEL_SECRET) {
        // Fechar túnel anterior se existir
        if (tunnelSocket && !tunnelSocket.destroyed) {
            tunnelSocket.destroy();
        }

        tunnelSocket = socket;
        tunnelAuthenticated = true;
        tunnelBuffer = '';
        socket.write('OK\n');
        console.log('[TUNNEL] Celular conectado e autenticado!');

        socket.setKeepAlive(true, 15000);
        socket.setTimeout(0);

        socket.on('data', (data) => {
            handleTunnelData(data);
        });

        socket.on('close', () => {
            console.log('[TUNNEL] Celular desconectou');
            if (tunnelSocket === socket) {
                tunnelSocket = null;
                tunnelAuthenticated = false;
            }
        });

        socket.on('error', (err) => {
            console.log('[TUNNEL] Erro:', err.message);
            if (tunnelSocket === socket) {
                tunnelSocket = null;
                tunnelAuthenticated = false;
            }
        });
    } else {
        // Autenticação falhou
        console.log('[TUNNEL] Auth falhou, fechando');
        socket.destroy();
    }
}

// === HANDLER SOCKS5 (PC) ===
function handleSocks5(socket, firstChunk) {
    let state = 'greeting';
    let buffer = firstChunk;

    function processBuffer() {
        if (state === 'greeting') {
            if (buffer.length < 3) return;
            const ver = buffer[0];
            const nmethods = buffer[1];
            if (ver !== 0x05) { socket.destroy(); return; }
            if (buffer.length < 2 + nmethods) return;

            // Requer autenticação user/pass
            socket.write(Buffer.from([0x05, 0x02]));
            buffer = buffer.slice(2 + nmethods);
            state = 'auth';
            processBuffer();
        }
        else if (state === 'auth') {
            if (buffer.length < 2) return;
            const ulen = buffer[1];
            if (buffer.length < 2 + ulen + 1) return;
            const username = buffer.slice(2, 2 + ulen).toString('utf8');
            const plen = buffer[2 + ulen];
            if (buffer.length < 2 + ulen + 1 + plen) return;
            const password = buffer.slice(2 + ulen + 1, 2 + ulen + 1 + plen).toString('utf8');

            if (username === PROXY_USER && password === PROXY_PASS) {
                socket.write(Buffer.from([0x01, 0x00]));
                buffer = buffer.slice(2 + ulen + 1 + plen);
                state = 'request';
                processBuffer();
            } else {
                console.log(`[SOCKS5] Auth falhou: ${username}`);
                socket.write(Buffer.from([0x01, 0x01]));
                socket.destroy();
            }
        }
        else if (state === 'request') {
            if (buffer.length < 4) return;
            const cmd = buffer[1];
            const atyp = buffer[3];

            let targetHost = '';
            let targetPort = 0;
            let headerLen = 0;

            if (atyp === 0x01) {
                if (buffer.length < 10) return;
                targetHost = `${buffer[4]}.${buffer[5]}.${buffer[6]}.${buffer[7]}`;
                targetPort = buffer.readUInt16BE(8);
                headerLen = 10;
            } else if (atyp === 0x03) {
                const domainLen = buffer[4];
                if (buffer.length < 5 + domainLen + 2) return;
                targetHost = buffer.slice(5, 5 + domainLen).toString('utf8');
                targetPort = buffer.readUInt16BE(5 + domainLen);
                headerLen = 5 + domainLen + 2;
            } else if (atyp === 0x04) {
                if (buffer.length < 22) return;
                const parts = [];
                for (let i = 0; i < 16; i += 2) {
                    parts.push(buffer.readUInt16BE(4 + i).toString(16));
                }
                targetHost = parts.join(':');
                targetPort = buffer.readUInt16BE(20);
                headerLen = 22;
            }

            if (cmd !== 0x01) {
                socket.write(Buffer.from([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]));
                socket.destroy();
                return;
            }

            buffer = buffer.slice(headerLen);
            state = 'connected';

            console.log(`[SOCKS5] → ${targetHost}:${targetPort}`);

            // Rotear pelo celular ou direto
            if (tunnelSocket && !tunnelSocket.destroyed && tunnelAuthenticated) {
                connectViaTunnel(socket, targetHost, targetPort, buffer);
            } else {
                connectDirect(socket, targetHost, targetPort, buffer);
            }
        }
    }

    socket.on('data', (data) => {
        if (state !== 'connected') {
            buffer = Buffer.concat([buffer, data]);
            processBuffer();
        }
    });

    socket.on('error', () => {});
    processBuffer();
}

// === CONEXÃO VIA TÚNEL (pelo celular 5G) ===
function connectViaTunnel(clientSocket, host, port, remainingData) {
    const connId = connectionId++;

    const request = JSON.stringify({ type: 'connect', id: connId, host, port }) + '\n';
    try {
        tunnelSocket.write(request);
    } catch (err) {
        connectDirect(clientSocket, host, port, remainingData);
        return;
    }

    pendingConnections.set(connId, { clientSocket, host, port, remainingData, timestamp: Date.now() });

    setTimeout(() => {
        if (pendingConnections.has(connId)) {
            pendingConnections.delete(connId);
            connectDirect(clientSocket, host, port, remainingData);
        }
    }, 15000);
}

// === CONEXÃO DIRETA (fallback) ===
function connectDirect(clientSocket, host, port, remainingData) {
    const remote = net.createConnection({ host, port }, () => {
        const reply = Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        clientSocket.write(reply);
        if (remainingData && remainingData.length > 0) {
            remote.write(remainingData);
        }
        clientSocket.pipe(remote);
        remote.pipe(clientSocket);
    });

    remote.on('error', (err) => {
        const reply = Buffer.from([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        clientSocket.write(reply);
        clientSocket.destroy();
    });

    clientSocket.on('close', () => remote.destroy());
    remote.on('close', () => clientSocket.destroy());
}

// === PROCESSAR DADOS DO TÚNEL ===
function handleTunnelData(data) {
    tunnelBuffer += data.toString('utf8');

    let idx;
    while ((idx = tunnelBuffer.indexOf('\n')) !== -1) {
        const line = tunnelBuffer.slice(0, idx);
        tunnelBuffer = tunnelBuffer.slice(idx + 1);

        try {
            const msg = JSON.parse(line);

            if (msg.type === 'connected') {
                const pending = pendingConnections.get(msg.id);
                if (pending) {
                    pendingConnections.delete(msg.id);
                    const reply = Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
                    pending.clientSocket.write(reply);
                    if (pending.remainingData && pending.remainingData.length > 0) {
                        tunnelSocket.write(JSON.stringify({
                            type: 'data', id: msg.id,
                            payload: pending.remainingData.toString('base64')
                        }) + '\n');
                    }
                    setupTunnelPipe(msg.id, pending.clientSocket);
                }
            }
            else if (msg.type === 'error') {
                const pending = pendingConnections.get(msg.id);
                if (pending) {
                    pendingConnections.delete(msg.id);
                    connectDirect(pending.clientSocket, pending.host, pending.port, pending.remainingData);
                }
            }
            else if (msg.type === 'data') {
                const pipe = activePipes.get(msg.id);
                if (pipe && !pipe.destroyed) {
                    pipe.write(Buffer.from(msg.payload, 'base64'));
                }
            }
            else if (msg.type === 'close') {
                const pipe = activePipes.get(msg.id);
                if (pipe) {
                    pipe.end();
                    activePipes.delete(msg.id);
                }
            }
            else if (msg.type === 'ping') {
                if (tunnelSocket && !tunnelSocket.destroyed) {
                    tunnelSocket.write(JSON.stringify({ type: 'pong' }) + '\n');
                }
            }
        } catch (err) {}
    }
}

// === PIPE DE DADOS PC ↔ CELULAR ===
function setupTunnelPipe(connId, clientSocket) {
    activePipes.set(connId, clientSocket);

    clientSocket.on('data', (data) => {
        if (tunnelSocket && !tunnelSocket.destroyed) {
            tunnelSocket.write(JSON.stringify({
                type: 'data', id: connId,
                payload: data.toString('base64')
            }) + '\n');
        }
    });

    const cleanup = () => {
        activePipes.delete(connId);
        if (tunnelSocket && !tunnelSocket.destroyed) {
            tunnelSocket.write(JSON.stringify({ type: 'close', id: connId }) + '\n');
        }
    };

    clientSocket.on('close', cleanup);
    clientSocket.on('error', cleanup);
}

// === LIMPEZA ===
setInterval(() => {
    const now = Date.now();
    for (const [id, conn] of pendingConnections) {
        if (now - conn.timestamp > 30000) {
            pendingConnections.delete(id);
            conn.clientSocket.destroy();
        }
    }
}, 30000);

process.on('SIGTERM', () => {
    console.log('[SERVER] Encerrando...');
    mainServer.close();
    httpServer.close();
    process.exit(0);
});
