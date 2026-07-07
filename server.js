const net = require('net');

// === CONFIGURAÇÃO ===
const PORT = parseInt(process.env.PORT || '7777');
const PROXY_USER = process.env.PROXY_USER || '5guser';
const PROXY_PASS = process.env.PROXY_PASS || 'senha123';
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'senha123';

/*
  ARQUITETURA v6.0 - RELAY TCP PURO (VELOCIDADE ABSOLUTA)
  
  O Railway é apenas um relay de bytes. Não processa, não encoda, não bufferiza.
  
  Protocolo de multiplexação ultra-leve:
  [CMD:1][ID:2][LEN:2][PAYLOAD:LEN]
  
  CMD:
    1 = CONNECT (server→cel): payload = "host:port"
    2 = CONNECTED (cel→server): sem payload
    3 = DATA (bidirecional): payload = raw bytes
    4 = CLOSE (bidirecional): sem payload
    5 = ERROR (cel→server): sem payload
    6 = PING/PONG: sem payload
  
  Header = 5 bytes apenas (mínimo possível)
  LEN = uint16 = max 65535 bytes por frame
  Para pacotes maiores: fragmenta automaticamente
  
  Resultado: overhead de 5 bytes a cada 65KB = 0.007%
*/

const CMD_CONNECT = 1;
const CMD_CONNECTED = 2;
const CMD_DATA = 3;
const CMD_CLOSE = 4;
const CMD_ERROR = 5;
const CMD_PING = 6;
const HDR = 5;
const MAX_PAYLOAD = 65000; // deixar margem

let tunnel = null;
let tunnelBuf = Buffer.alloc(0);
const pending = new Map(); // id → {socket, host, port, extra, mode}
const pipes = new Map();   // id → socket
let nextId = 1;

console.log('=== 5G-SHARE v6.0 - RELAY PURO ===');
console.log(`Porta: ${PORT} | User: ${PROXY_USER}`);
console.log('Overhead: 0.007% | Velocidade: absoluta');
console.log('===================================');

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

function sendTunnel(cmd, id, data) {
    if (!tunnel || tunnel.destroyed) return false;
    try {
        if (!data || data.length <= MAX_PAYLOAD) {
            tunnel.write(frame(cmd, id, data));
        } else {
            // Fragmentar pacotes grandes
            let offset = 0;
            while (offset < data.length) {
                const chunk = data.slice(offset, offset + MAX_PAYLOAD);
                tunnel.write(frame(cmd, id, chunk));
                offset += MAX_PAYLOAD;
            }
        }
        return true;
    } catch(e) { return false; }
}

// === SERVIDOR TCP ===
const server = net.createServer({ noDelay: true }, (socket) => {
    socket.setNoDelay(true);
    socket.once('data', (chunk) => {
        const first = chunk[0];
        
        if (first === 0x05) {
            // SOCKS5
            handleSocks5(socket, chunk);
        } else if (first === 0x16) {
            // TLS ClientHello - HTTPS proxy
            // O cliente está tentando fazer TLS com o proxy
            // Precisamos responder como proxy HTTP sem TLS
            // Isso acontece quando configuram como "HTTPS" no app
            // Na verdade, proxy HTTPS = HTTP CONNECT na porta 443, não TLS pro proxy
            socket.destroy();
        } else if (first >= 0x41 && first <= 0x5A) {
            // Letra maiúscula ASCII = HTTP method (CONNECT, GET, POST, HEAD, PUT, etc)
            const str = chunk.toString();
            if (str.startsWith('CONNECT')) handleHttpConnect(socket, chunk);
            else if (/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)/.test(str)) handleHttp(socket, chunk);
            else {
                const msg = str.trim();
                if (msg === TUNNEL_SECRET) handleTunnel(socket);
                else socket.destroy();
            }
        } else {
            const msg = chunk.toString().trim();
            if (msg === TUNNEL_SECRET) handleTunnel(socket);
            else socket.destroy();
        }
    });
    socket.on('error', () => {});
});

server.listen(PORT, '0.0.0.0', () => console.log(`[OK] Porta ${PORT}`));

// === TÚNEL (CELULAR) ===
function handleTunnel(socket) {
    if (tunnel && !tunnel.destroyed) {
        tunnel.removeAllListeners();
        tunnel.destroy();
    }
    tunnel = socket;
    tunnelBuf = Buffer.alloc(0);
    socket.write('OK\n');
    console.log('[CEL] Conectado!');

    socket.setKeepAlive(true, 20000);
    socket.setNoDelay(true);

    // Buffers grandes para throughput máximo
    try { socket.setRecvBufferSize(262144); } catch(e) {}
    try { socket.setSendBufferSize(262144); } catch(e) {}

    socket.on('data', onTunnelData);
    socket.on('close', () => { if (tunnel === socket) { tunnel = null; console.log('[CEL] Desconectou'); } });
    socket.on('error', () => { if (tunnel === socket) { tunnel = null; } });

    // Ping keepalive
    const iv = setInterval(() => {
        if (!tunnel || tunnel.destroyed) { clearInterval(iv); return; }
        sendTunnel(CMD_PING, 0, null);
    }, 20000);
    socket.on('close', () => clearInterval(iv));
}

function onTunnelData(data) {
    tunnelBuf = tunnelBuf.length ? Buffer.concat([tunnelBuf, data]) : data;

    while (tunnelBuf.length >= HDR) {
        const len = tunnelBuf.readUInt16BE(3);
        if (tunnelBuf.length < HDR + len) break;

        const cmd = tunnelBuf[0];
        const id = tunnelBuf.readUInt16BE(1);
        const payload = len > 0 ? tunnelBuf.slice(HDR, HDR + len) : null;
        tunnelBuf = tunnelBuf.slice(HDR + len);

        switch(cmd) {
            case CMD_CONNECTED: {
                const p = pending.get(id);
                if (p) {
                    pending.delete(id);
                    if (p.mode === 'socks5') {
                        p.socket.write(Buffer.from([0x05,0x00,0x00,0x01,0,0,0,0,0,0]));
                    } else if (p.mode === 'http') {
                        p.socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
                    }
                    if (p.extra && p.extra.length) sendTunnel(CMD_DATA, id, p.extra);
                    pipeClient(id, p.socket);
                }
                break;
            }
            case CMD_DATA: {
                const s = pipes.get(id);
                if (s && !s.destroyed) s.write(payload);
                break;
            }
            case CMD_CLOSE: {
                const s = pipes.get(id);
                if (s) { s.end(); pipes.delete(id); }
                break;
            }
            case CMD_ERROR: {
                const p = pending.get(id);
                if (p) { pending.delete(id); p.socket.destroy(); }
                break;
            }
            case CMD_PING:
                sendTunnel(CMD_PING, 0, null); // pong
                break;
        }
    }
}

function pipeClient(id, socket) {
    pipes.set(id, socket);
    socket.on('data', (d) => sendTunnel(CMD_DATA, id, d));
    const cleanup = () => { pipes.delete(id); sendTunnel(CMD_CLOSE, id, null); };
    socket.on('close', cleanup);
    socket.on('error', cleanup);
}

// === SOCKS5 ===
function handleSocks5(socket, buf) {
    const nm = buf[1];
    socket.write(Buffer.from([0x05, 0x02])); // auth required
    buf = buf.slice(2 + nm);
    if (buf.length > 0) socks5Auth(socket, buf);
    else socket.once('data', (d) => socks5Auth(socket, d));
}

function socks5Auth(socket, buf) {
    if (buf.length < 3) { socket.destroy(); return; }
    const ulen = buf[1];
    const user = buf.slice(2, 2+ulen).toString();
    const plen = buf[2+ulen];
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
        host = `${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}`;
        port = buf.readUInt16BE(8); end = 10;
    } else if (atyp === 3) {
        const dl = buf[4];
        host = buf.slice(5, 5+dl).toString();
        port = buf.readUInt16BE(5+dl); end = 7+dl;
    } else if (atyp === 4) {
        const p = []; for(let i=0;i<16;i+=2) p.push(buf.readUInt16BE(4+i).toString(16));
        host = p.join(':'); port = buf.readUInt16BE(20); end = 22;
    } else { socket.destroy(); return; }

    const extra = buf.slice(end);
    routeConnection(socket, host, port, extra, 'socks5');
}

// === HTTP CONNECT (usado por HTTPS proxy) ===
function handleHttpConnect(socket, chunk) {
    const req = chunk.toString();
    const lines = req.split('\r\n');
    const m = lines[0].match(/^CONNECT\s+([^:\s]+):(\d+)\s+HTTP/i);
    if (!m) { socket.write('HTTP/1.1 400 Bad Request\r\n\r\n'); socket.destroy(); return; }

    if (!httpAuth(lines)) {
        socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G-SHARE"\r\nConnection: close\r\n\r\n');
        socket.destroy(); return;
    }

    console.log(`[HTTPS] CONNECT ${m[1]}:${m[2]}`);
    routeConnection(socket, m[1], parseInt(m[2]), null, 'http');
}

// === HTTP GET/POST proxy ===
function handleHttp(socket, chunk) {
    const req = chunk.toString();
    const lines = req.split('\r\n');
    const pm = lines[0].match(/^(GET|POST|PUT|DELETE|HEAD|OPTIONS|PATCH)\s+http:\/\/([^\/:\s]+)(?::(\d+))?(\/\S*)\s+HTTP/i);

    if (!pm) {
        // Health check
        const b = JSON.stringify({status:'online',tunnel:!!(tunnel&&!tunnel.destroyed),pipes:pipes.size});
        socket.write(`HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${b.length}\r\n\r\n${b}`);
        socket.end(); return;
    }

    if (!httpAuth(lines)) {
        socket.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="5G"\r\n\r\n');
        socket.destroy(); return;
    }

    const host = pm[2], port = parseInt(pm[3]||'80'), path = pm[4];
    lines[0] = `${pm[1]} ${path} HTTP/1.1`;
    const filtered = lines.filter(l => !/^Proxy-Auth/i.test(l));
    const extra = Buffer.from(filtered.join('\r\n'));
    routeConnection(socket, host, port, extra, 'http-plain');
}

function httpAuth(lines) {
    for (const l of lines) {
        const m = l.match(/^Proxy-Authorization:\s*Basic\s+(.+)$/i);
        if (m) {
            const d = Buffer.from(m[1],'base64').toString();
            const i = d.indexOf(':');
            return i>0 && d.slice(0,i)===PROXY_USER && d.slice(i+1)===PROXY_PASS;
        }
    }
    return false;
}

// === ROTEAMENTO ===
function routeConnection(socket, host, port, extra, mode) {
    if (tunnel && !tunnel.destroyed) {
        const id = nextId++ % 65535 || 1;
        const target = Buffer.from(`${host}:${port}`);
        sendTunnel(CMD_CONNECT, id, target);
        pending.set(id, {socket, host, port, extra, mode});
        setTimeout(() => {
            if (pending.has(id)) {
                pending.delete(id);
                // Fallback: conexão direta
                directConnect(socket, host, port, extra, mode);
            }
        }, 10000);
    } else {
        directConnect(socket, host, port, extra, mode);
    }
}

function directConnect(socket, host, port, extra, mode) {
    const remote = net.createConnection({host, port}, () => {
        remote.setNoDelay(true);
        if (mode === 'socks5') socket.write(Buffer.from([0x05,0x00,0x00,0x01,0,0,0,0,0,0]));
        else if (mode === 'http') socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        if (extra && extra.length) remote.write(extra);
        socket.pipe(remote);
        remote.pipe(socket);
    });
    remote.on('error', () => socket.destroy());
    socket.on('close', () => remote.destroy());
    remote.on('close', () => socket.destroy());
}

// Limpeza
setInterval(() => {
    const now = Date.now();
    for (const [id,p] of pending) {
        if (!p.ts) p.ts = now;
        if (now - p.ts > 15000) { pending.delete(id); p.socket.destroy(); }
    }
}, 10000);

process.on('SIGTERM', () => process.exit(0));
