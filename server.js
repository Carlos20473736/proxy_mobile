const net = require('net');
const crypto = require('crypto');

// === CONFIGURAÇÃO (via variáveis de ambiente) ===
const PROXY_PORT = parseInt(process.env.PORT || '1080');
const PROXY_USER = process.env.PROXY_USER || '5guser';
const PROXY_PASS = process.env.PROXY_PASS || 'senha123';
const SSH_PORT = parseInt(process.env.SSH_PORT || '2222');
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'tunnel_secret_key';

// Armazena a conexão do túnel do celular
let tunnelSocket = null;
let pendingConnections = new Map();
let connectionId = 0;

console.log('=== 5G-SHARE - Servidor Railway ===');
console.log(`Proxy SOCKS5 na porta: ${PROXY_PORT}`);
console.log(`Túnel na porta: ${SSH_PORT}`);
console.log(`Usuário: ${PROXY_USER}`);
console.log('===================================');

// === SERVIDOR DE TÚNEL (recebe conexão do Termux) ===
const tunnelServer = net.createServer((socket) => {
    console.log('[TUNNEL] Nova conexão do celular...');
    
    let authenticated = false;
    let buffer = Buffer.alloc(0);
    
    socket.on('data', (data) => {
        if (!authenticated) {
            buffer = Buffer.concat([buffer, data]);
            // Protocolo simples de autenticação: primeiro pacote = secret key
            const msg = buffer.toString('utf8').trim();
            if (msg === TUNNEL_SECRET) {
                authenticated = true;
                tunnelSocket = socket;
                socket.write('OK\n');
                console.log('[TUNNEL] Celular autenticado e conectado!');
                buffer = Buffer.alloc(0);
            } else if (buffer.length > 256) {
                console.log('[TUNNEL] Autenticação falhou');
                socket.destroy();
            }
            return;
        }
        
        // Dados do túnel: respostas das conexões
        handleTunnelData(data);
    });
    
    socket.on('close', () => {
        console.log('[TUNNEL] Celular desconectado');
        if (tunnelSocket === socket) {
            tunnelSocket = null;
        }
    });
    
    socket.on('error', (err) => {
        console.log('[TUNNEL] Erro:', err.message);
        if (tunnelSocket === socket) {
            tunnelSocket = null;
        }
    });
    
    // Keepalive
    socket.setKeepAlive(true, 30000);
    socket.setTimeout(0);
});

// === SERVIDOR SOCKS5 (recebe conexão do PC) ===
const socksServer = net.createServer((clientSocket) => {
    let state = 'greeting';
    let buffer = Buffer.alloc(0);
    
    clientSocket.on('data', (data) => {
        buffer = Buffer.concat([buffer, data]);
        
        if (state === 'greeting') {
            // SOCKS5 greeting
            if (buffer.length < 3) return;
            
            const ver = buffer[0];
            const nmethods = buffer[1];
            
            if (ver !== 0x05) {
                clientSocket.destroy();
                return;
            }
            
            if (buffer.length < 2 + nmethods) return;
            
            // Responder que requer autenticação user/pass (método 0x02)
            clientSocket.write(Buffer.from([0x05, 0x02]));
            state = 'auth';
            buffer = Buffer.alloc(0);
        }
        else if (state === 'auth') {
            // Autenticação user/pass (RFC 1929)
            if (buffer.length < 2) return;
            
            const ver = buffer[0]; // deve ser 0x01
            const ulen = buffer[1];
            
            if (buffer.length < 2 + ulen + 1) return;
            const username = buffer.slice(2, 2 + ulen).toString('utf8');
            
            const plen = buffer[2 + ulen];
            if (buffer.length < 2 + ulen + 1 + plen) return;
            const password = buffer.slice(2 + ulen + 1, 2 + ulen + 1 + plen).toString('utf8');
            
            if (username === PROXY_USER && password === PROXY_PASS) {
                // Sucesso
                clientSocket.write(Buffer.from([0x01, 0x00]));
                state = 'request';
                buffer = Buffer.alloc(0);
            } else {
                // Falha
                console.log(`[SOCKS5] Auth falhou: ${username}/${password}`);
                clientSocket.write(Buffer.from([0x01, 0x01]));
                clientSocket.destroy();
            }
        }
        else if (state === 'request') {
            // SOCKS5 request
            if (buffer.length < 4) return;
            
            const ver = buffer[0];
            const cmd = buffer[1];
            const atyp = buffer[3];
            
            let targetHost = '';
            let targetPort = 0;
            let headerLen = 0;
            
            if (atyp === 0x01) {
                // IPv4
                if (buffer.length < 10) return;
                targetHost = `${buffer[4]}.${buffer[5]}.${buffer[6]}.${buffer[7]}`;
                targetPort = buffer.readUInt16BE(8);
                headerLen = 10;
            }
            else if (atyp === 0x03) {
                // Domain
                const domainLen = buffer[4];
                if (buffer.length < 5 + domainLen + 2) return;
                targetHost = buffer.slice(5, 5 + domainLen).toString('utf8');
                targetPort = buffer.readUInt16BE(5 + domainLen);
                headerLen = 5 + domainLen + 2;
            }
            else if (atyp === 0x04) {
                // IPv6
                if (buffer.length < 22) return;
                const ipv6Parts = [];
                for (let i = 0; i < 16; i += 2) {
                    ipv6Parts.push(buffer.readUInt16BE(4 + i).toString(16));
                }
                targetHost = ipv6Parts.join(':');
                targetPort = buffer.readUInt16BE(20);
                headerLen = 22;
            }
            
            if (cmd !== 0x01) {
                // Apenas CONNECT suportado
                const reply = Buffer.from([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
                clientSocket.write(reply);
                clientSocket.destroy();
                return;
            }
            
            console.log(`[SOCKS5] Conectando: ${targetHost}:${targetPort}`);
            
            // Verificar se o túnel do celular está ativo
            if (!tunnelSocket || tunnelSocket.destroyed) {
                console.log('[SOCKS5] Túnel do celular não conectado!');
                // Conectar diretamente (fallback)
                connectDirect(clientSocket, targetHost, targetPort);
            } else {
                // Rotear pelo celular via túnel
                connectViaTunnel(clientSocket, targetHost, targetPort);
            }
            
            state = 'connected';
            buffer = Buffer.alloc(0);
        }
    });
    
    clientSocket.on('error', (err) => {
        // Silenciar erros de conexão reset
    });
});

// === CONEXÃO DIRETA (fallback quando celular não está conectado) ===
function connectDirect(clientSocket, host, port) {
    const remote = net.createConnection({ host, port }, () => {
        // Sucesso - enviar reply SOCKS5
        const reply = Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        clientSocket.write(reply);
        
        // Pipe bidirecional
        clientSocket.pipe(remote);
        remote.pipe(clientSocket);
    });
    
    remote.on('error', (err) => {
        console.log(`[DIRECT] Erro conectando ${host}:${port} - ${err.message}`);
        const reply = Buffer.from([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        clientSocket.write(reply);
        clientSocket.destroy();
    });
    
    clientSocket.on('close', () => remote.destroy());
    remote.on('close', () => clientSocket.destroy());
}

// === CONEXÃO VIA TÚNEL DO CELULAR ===
function connectViaTunnel(clientSocket, host, port) {
    const connId = connectionId++;
    
    // Enviar request de conexão para o celular
    const request = JSON.stringify({
        type: 'connect',
        id: connId,
        host: host,
        port: port
    }) + '\n';
    
    try {
        tunnelSocket.write(request);
    } catch (err) {
        console.log('[TUNNEL] Erro ao enviar request:', err.message);
        connectDirect(clientSocket, host, port);
        return;
    }
    
    // Registrar conexão pendente
    pendingConnections.set(connId, {
        clientSocket,
        host,
        port,
        timestamp: Date.now()
    });
    
    // Timeout de 15s
    setTimeout(() => {
        if (pendingConnections.has(connId)) {
            console.log(`[TUNNEL] Timeout para ${host}:${port}`);
            pendingConnections.delete(connId);
            // Fallback para conexão direta
            connectDirect(clientSocket, host, port);
        }
    }, 15000);
}

// === PROCESSAR DADOS DO TÚNEL ===
let tunnelBuffer = '';

function handleTunnelData(data) {
    tunnelBuffer += data.toString('utf8');
    
    let newlineIndex;
    while ((newlineIndex = tunnelBuffer.indexOf('\n')) !== -1) {
        const line = tunnelBuffer.slice(0, newlineIndex);
        tunnelBuffer = tunnelBuffer.slice(newlineIndex + 1);
        
        try {
            const msg = JSON.parse(line);
            
            if (msg.type === 'connected') {
                const pending = pendingConnections.get(msg.id);
                if (pending) {
                    pendingConnections.delete(msg.id);
                    
                    // Sucesso - enviar reply SOCKS5
                    const reply = Buffer.from([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
                    pending.clientSocket.write(reply);
                    
                    // Agora os dados vão fluir pelo túnel
                    // Criar um sub-canal para esta conexão
                    setupTunnelPipe(msg.id, pending.clientSocket);
                }
            }
            else if (msg.type === 'error') {
                const pending = pendingConnections.get(msg.id);
                if (pending) {
                    pendingConnections.delete(msg.id);
                    console.log(`[TUNNEL] Erro do celular: ${msg.error}`);
                    // Fallback
                    connectDirect(pending.clientSocket, pending.host, pending.port);
                }
            }
            else if (msg.type === 'data') {
                // Dados recebidos do celular para uma conexão
                const pipe = activePipes.get(msg.id);
                if (pipe) {
                    const decoded = Buffer.from(msg.payload, 'base64');
                    pipe.write(decoded);
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
                // Responder keepalive
                if (tunnelSocket && !tunnelSocket.destroyed) {
                    tunnelSocket.write(JSON.stringify({ type: 'pong' }) + '\n');
                }
            }
        } catch (err) {
            // Ignorar linhas inválidas
        }
    }
}

// === PIPES ATIVOS (dados fluindo pelo túnel) ===
const activePipes = new Map();

function setupTunnelPipe(connId, clientSocket) {
    activePipes.set(connId, clientSocket);
    
    clientSocket.on('data', (data) => {
        if (tunnelSocket && !tunnelSocket.destroyed) {
            const msg = JSON.stringify({
                type: 'data',
                id: connId,
                payload: data.toString('base64')
            }) + '\n';
            tunnelSocket.write(msg);
        }
    });
    
    clientSocket.on('close', () => {
        activePipes.delete(connId);
        if (tunnelSocket && !tunnelSocket.destroyed) {
            tunnelSocket.write(JSON.stringify({ type: 'close', id: connId }) + '\n');
        }
    });
    
    clientSocket.on('error', () => {
        activePipes.delete(connId);
        if (tunnelSocket && !tunnelSocket.destroyed) {
            tunnelSocket.write(JSON.stringify({ type: 'close', id: connId }) + '\n');
        }
    });
}

// === LIMPEZA PERIÓDICA ===
setInterval(() => {
    const now = Date.now();
    for (const [id, conn] of pendingConnections) {
        if (now - conn.timestamp > 30000) {
            pendingConnections.delete(id);
            conn.clientSocket.destroy();
        }
    }
}, 30000);

// === STATUS ENDPOINT (HTTP na mesma porta que o túnel) ===
const http = require('http');
const statusServer = http.createServer((req, res) => {
    if (req.url === '/status') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            status: 'online',
            tunnel_connected: tunnelSocket !== null && !tunnelSocket.destroyed,
            active_connections: activePipes.size,
            pending_connections: pendingConnections.size,
            proxy_port: PROXY_PORT,
            uptime: process.uptime()
        }));
    } else if (req.url === '/health') {
        res.writeHead(200);
        res.end('OK');
    } else {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        res.end(`
            <h1>5G-SHARE - Servidor Proxy</h1>
            <p>Status: ONLINE</p>
            <p>Celular conectado: ${tunnelSocket !== null && !tunnelSocket.destroyed ? 'SIM' : 'NÃO'}</p>
            <p>Conexões ativas: ${activePipes.size}</p>
            <hr>
            <p><b>Para conectar seu PC:</b></p>
            <ul>
                <li>Protocolo: SOCKS5</li>
                <li>Host: (seu domínio railway)</li>
                <li>Porta: ${PROXY_PORT}</li>
                <li>Usuário: ${PROXY_USER}</li>
                <li>Senha: ****</li>
            </ul>
        `);
    }
});

// === INICIAR SERVIDORES ===
// O Railway expõe apenas uma porta (PORT), então vamos multiplexar
// Detectar se a conexão é SOCKS5 ou HTTP ou Tunnel pelo primeiro byte

const mainServer = net.createServer((socket) => {
    socket.once('data', (data) => {
        if (data[0] === 0x05) {
            // SOCKS5 - proxy do PC
            socksServer.emit('connection', socket);
            socket.unshift(data);
        } else if (data.toString('utf8').startsWith('GET') || data.toString('utf8').startsWith('HEAD')) {
            // HTTP - status page
            statusServer.emit('connection', socket);
            socket.unshift(data);
        } else {
            // Tunnel - conexão do celular
            tunnelServer.emit('connection', socket);
            socket.unshift(data);
        }
    });
    
    socket.on('error', () => {});
});

mainServer.listen(PROXY_PORT, '0.0.0.0', () => {
    console.log(`[SERVER] Servidor principal rodando na porta ${PROXY_PORT}`);
    console.log(`[SERVER] Aguardando conexão do celular...`);
    console.log('');
    console.log('=== DADOS PARA O PC ===');
    console.log(`Protocolo: SOCKS5`);
    console.log(`Porta: ${PROXY_PORT}`);
    console.log(`Usuário: ${PROXY_USER}`);
    console.log(`Senha: ${PROXY_PASS}`);
    console.log('=======================');
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('[SERVER] Encerrando...');
    mainServer.close();
    process.exit(0);
});
