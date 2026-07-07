#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# 5G-SHARE v6.0 - VELOCIDADE ABSOLUTA
# Relay TCP puro via Railway - overhead 0.007%
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
echo "║    5G-SHARE v6.0 - VELOCIDADE ABSOLUTA                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Instalar Node.js se necessário
if ! command -v node &> /dev/null; then
    echo "[*] Instalando Node.js..."
    pkg install -y nodejs-lts 2>/dev/null || pkg install -y nodejs
fi

termux-wake-lock 2>/dev/null

# Criar o cliente de túnel otimizado
cat > $HOME/.5gtunnel.js << 'TUNNELEOF'
const net = require('net');

const HOST = process.env.SH;
const PORT = parseInt(process.env.SP);
const SECRET = process.env.SS;

const CMD_CONNECT = 1;
const CMD_CONNECTED = 2;
const CMD_DATA = 3;
const CMD_CLOSE = 4;
const CMD_ERROR = 5;
const CMD_PING = 6;
const HDR = 5;
const MAX_PAYLOAD = 65000;

let sock = null;
let buf = Buffer.alloc(0);
let pingIv = null;
const conns = new Map();

function frame(cmd, id, data) {
    const len = data ? data.length : 0;
    const b = Buffer.allocUnsafe(HDR + len);
    b[0] = cmd;
    b.writeUInt16BE(id, 1);
    b.writeUInt16BE(len, 3);
    if (data) data.copy(b, HDR);
    return b;
}

function send(cmd, id, data) {
    if (!sock || sock.destroyed) return;
    try {
        if (!data || data.length <= MAX_PAYLOAD) {
            sock.write(frame(cmd, id, data));
        } else {
            let off = 0;
            while (off < data.length) {
                const chunk = data.slice(off, off + MAX_PAYLOAD);
                sock.write(frame(cmd, id, chunk));
                off += MAX_PAYLOAD;
            }
        }
    } catch(e) {}
}

function connect() {
    if (pingIv) { clearInterval(pingIv); pingIv = null; }
    buf = Buffer.alloc(0);
    for (const [id, c] of conns) { c.destroy(); }
    conns.clear();

    console.log(`[TUNNEL] Conectando ${HOST}:${PORT}...`);
    sock = net.createConnection({host: HOST, port: PORT}, () => {
        console.log('[TUNNEL] Conectado! Autenticando...');
        sock.write(SECRET + '\n');
    });

    sock.setKeepAlive(true, 20000);
    sock.setNoDelay(true);
    try { sock.setRecvBufferSize(262144); } catch(e) {}
    try { sock.setSendBufferSize(262144); } catch(e) {}

    let authed = false;

    sock.on('data', (data) => {
        if (!authed) {
            if (data.toString().trim() === 'OK') {
                authed = true;
                console.log('[TUNNEL] ✅ ATIVO! Velocidade absoluta do 5G.');
                pingIv = setInterval(() => send(CMD_PING, 0, null), 20000);
            } else {
                console.log('[TUNNEL] Auth falhou'); sock.destroy();
            }
            return;
        }

        buf = buf.length ? Buffer.concat([buf, data]) : data;
        processFrames();
    });

    sock.on('close', () => {
        authed = false;
        if (pingIv) { clearInterval(pingIv); pingIv = null; }
        console.log('[TUNNEL] Desconectou. Reconectando em 3s...');
        setTimeout(connect, 3000);
    });
    sock.on('error', (e) => console.log('[TUNNEL] Erro:', e.message));
}

function processFrames() {
    while (buf.length >= HDR) {
        const len = buf.readUInt16BE(3);
        if (buf.length < HDR + len) break;

        const cmd = buf[0];
        const id = buf.readUInt16BE(1);
        const payload = len > 0 ? buf.slice(HDR, HDR + len) : null;
        buf = buf.slice(HDR + len);

        switch(cmd) {
            case CMD_CONNECT: {
                // Server pede pra conectar em host:port
                const target = payload.toString();
                const sep = target.lastIndexOf(':');
                const host = target.slice(0, sep);
                const port = parseInt(target.slice(sep+1));

                const remote = net.createConnection({host, port}, () => {
                    remote.setNoDelay(true);
                    send(CMD_CONNECTED, id, null);
                });
                remote.on('data', (d) => send(CMD_DATA, id, d));
                remote.on('close', () => { conns.delete(id); send(CMD_CLOSE, id, null); });
                remote.on('error', () => { conns.delete(id); send(CMD_ERROR, id, null); });
                conns.set(id, remote);
                break;
            }
            case CMD_DATA: {
                const c = conns.get(id);
                if (c && !c.destroyed) c.write(payload);
                break;
            }
            case CMD_CLOSE: {
                const c = conns.get(id);
                if (c) { c.destroy(); conns.delete(id); }
                break;
            }
            case CMD_PING:
                send(CMD_PING, 0, null);
                break;
        }
    }
}

connect();
process.on('SIGINT', () => { console.log('\nEncerrando...'); process.exit(0); });
process.on('uncaughtException', (e) => {
    console.log('[!] Erro:', e.message);
    setTimeout(connect, 3000);
});
TUNNELEOF

echo -e "${GREEN}[✓] Túnel iniciado${NC}"
echo -e "${YELLOW}    Protocolo binário | Header 5 bytes | Overhead 0.007%${NC}"
echo ""

SH="$SERVER_HOST" SP="$SERVER_PORT" SS="$TUNNEL_SECRET" node $HOME/.5gtunnel.js
