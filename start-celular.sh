#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# 5G-SHARE v4.0 SPEED - Celular (Termux)
# Protocolo binário = velocidade máxima do 5G
# ============================================================

SERVER_HOST="hayabusa.proxy.rlwy.net"
SERVER_PORT="32618"
TUNNEL_SECRET="senha123"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       5G-SHARE v4.0 SPEED - Velocidade Máxima          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if ! command -v node &> /dev/null; then
    echo "[*] Instalando Node.js..."
    pkg install -y nodejs-lts 2>/dev/null || pkg install -y nodejs
fi

termux-wake-lock 2>/dev/null

cat > /data/data/com.termux/files/home/.5gshare-tunnel.js << 'EOF'
const net = require('net');

const HOST = process.env.SH || 'hayabusa.proxy.rlwy.net';
const PORT = parseInt(process.env.SP || '32618');
const SECRET = process.env.SS || 'senha123';

/*
  PROTOCOLO BINÁRIO v4:
  Header: [TYPE:1byte][ID:2bytes][LEN:4bytes][PAYLOAD:LEN bytes]
  
  Sem Base64, sem JSON para dados = velocidade máxima
*/

const TYPE_CONNECT = 0x01;
const TYPE_CONNECTED = 0x02;
const TYPE_DATA = 0x03;
const TYPE_CLOSE = 0x04;
const TYPE_ERROR = 0x05;
const TYPE_PING = 0x06;
const TYPE_PONG = 0x07;
const HEADER_SIZE = 7;

let socket = null;
let rawBuf = Buffer.alloc(0);
let pingInterval = null;
let reconnectTimer = null;
const activeConns = new Map();

function buildPacket(type, id, payload) {
    const plen = payload ? payload.length : 0;
    const buf = Buffer.allocUnsafe(HEADER_SIZE + plen);
    buf[0] = type;
    buf.writeUInt16BE(id, 1);
    buf.writeUInt32BE(plen, 3);
    if (payload && plen > 0) payload.copy(buf, HEADER_SIZE);
    return buf;
}

function send(type, id, payload) {
    if (!socket || socket.destroyed) return;
    try { socket.write(buildPacket(type, id, payload)); } catch(e) {}
}

function connect() {
    if (pingInterval) { clearInterval(pingInterval); pingInterval = null; }
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    rawBuf = Buffer.alloc(0);
    for (const [id, c] of activeConns) { c.destroy(); }
    activeConns.clear();

    console.log(`[TUNNEL] Conectando ${HOST}:${PORT}...`);

    socket = net.createConnection({ host: HOST, port: PORT }, () => {
        console.log('[TUNNEL] Conectado! Autenticando...');
        socket.write(SECRET + '\n');
    });

    socket.setKeepAlive(true, 30000);
    socket.setNoDelay(true);
    socket.setTimeout(0);

    // Aumentar buffers para velocidade
    try {
        socket.setRecvBufferSize && socket.setRecvBufferSize(1048576);
        socket.setSendBufferSize && socket.setSendBufferSize(1048576);
    } catch(e) {}

    let authed = false;

    socket.on('data', (data) => {
        if (!authed) {
            const resp = data.toString().trim();
            if (resp === 'OK') {
                authed = true;
                console.log('[TUNNEL] ✅ ATIVO! Velocidade máxima.');
                pingInterval = setInterval(() => { send(TYPE_PONG, 0, null); }, 25000);
            } else {
                console.log('[TUNNEL] Auth falhou');
                socket.destroy();
            }
            return;
        }

        // Protocolo binário
        rawBuf = Buffer.concat([rawBuf, data]);
        processPackets();
    });

    socket.on('close', () => {
        console.log('[TUNNEL] Desconectou. Reconectando em 5s...');
        authed = false;
        if (pingInterval) { clearInterval(pingInterval); pingInterval = null; }
        reconnectTimer = setTimeout(connect, 5000);
    });

    socket.on('error', (err) => {
        console.log('[TUNNEL] Erro:', err.message);
    });
}

function processPackets() {
    while (rawBuf.length >= HEADER_SIZE) {
        const type = rawBuf[0];
        const id = rawBuf.readUInt16BE(1);
        const plen = rawBuf.readUInt32BE(3);

        if (rawBuf.length < HEADER_SIZE + plen) break;

        const payload = plen > 0 ? rawBuf.slice(HEADER_SIZE, HEADER_SIZE + plen) : null;
        rawBuf = rawBuf.slice(HEADER_SIZE + plen);

        switch (type) {
            case TYPE_CONNECT: {
                try {
                    const info = JSON.parse(payload.toString());
                    const remote = net.createConnection({ host: info.host, port: info.port }, () => {
                        remote.setNoDelay(true);
                        send(TYPE_CONNECTED, id, null);
                    });
                    remote.on('data', (d) => { send(TYPE_DATA, id, d); });
                    remote.on('close', () => { activeConns.delete(id); send(TYPE_CLOSE, id, null); });
                    remote.on('error', (e) => {
                        activeConns.delete(id);
                        send(TYPE_ERROR, id, Buffer.from(e.message));
                    });
                    remote.setTimeout(15000, () => { remote.destroy(); });
                    remote.on('connect', () => { remote.setTimeout(0); });
                    activeConns.set(id, remote);
                } catch(e) {
                    send(TYPE_ERROR, id, Buffer.from('parse error'));
                }
                break;
            }
            case TYPE_DATA: {
                const c = activeConns.get(id);
                if (c && !c.destroyed) c.write(payload);
                break;
            }
            case TYPE_CLOSE: {
                const c = activeConns.get(id);
                if (c) { c.destroy(); activeConns.delete(id); }
                break;
            }
            case TYPE_PING: {
                send(TYPE_PONG, 0, null);
                break;
            }
        }
    }
}

connect();
process.on('SIGINT', () => { console.log('\nEncerrando...'); process.exit(0); });
process.on('uncaughtException', (err) => {
    console.log('[TUNNEL] Erro fatal:', err.message);
    if (pingInterval) { clearInterval(pingInterval); pingInterval = null; }
    reconnectTimer = setTimeout(connect, 5000);
});
EOF

echo -e "${GREEN}[✓] Túnel iniciado (protocolo binário v4)${NC}"
echo -e "${YELLOW}    Sem Base64, sem JSON = velocidade máxima do 5G${NC}"
echo ""

SH="$SERVER_HOST" SP="$SERVER_PORT" SS="$TUNNEL_SECRET" node /data/data/com.termux/files/home/.5gshare-tunnel.js
