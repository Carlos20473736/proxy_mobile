#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# 5G-SHARE - Celular (Termux)
# Só roda e conecta. Sem perguntas.
# ============================================================

# === CONFIGURAÇÃO FIXA ===
SERVER_HOST="hayabusa.proxy.rlwy.net"
SERVER_PORT="32618"
TUNNEL_SECRET="senha123"

# Cores
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       5G-SHARE - Conectando ao Railway...              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Instalar node se não tiver
if ! command -v node &> /dev/null; then
    echo "[*] Instalando Node.js..."
    pkg install -y nodejs-lts 2>/dev/null || pkg install -y nodejs
fi

# Wake lock
termux-wake-lock 2>/dev/null

# Criar cliente de túnel
cat > /data/data/com.termux/files/home/.5gshare-tunnel.js << 'EOF'
const net = require('net');

const HOST = process.env.SH || 'hayabusa.proxy.rlwy.net';
const PORT = parseInt(process.env.SP || '32618');
const SECRET = process.env.SS || 'senha123';

let socket = null;
let buffer = '';
let pingInterval = null;
let reconnectTimer = null;
const activeConns = new Map();

function connect() {
    // Limpar estado anterior
    if (pingInterval) { clearInterval(pingInterval); pingInterval = null; }
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    buffer = '';

    // Fechar conexões ativas antigas
    for (const [id, c] of activeConns) {
        c.destroy();
    }
    activeConns.clear();

    console.log(`[TUNNEL] Conectando ${HOST}:${PORT}...`);

    socket = net.createConnection({ host: HOST, port: PORT }, () => {
        console.log('[TUNNEL] Conectado! Autenticando...');
        socket.write(SECRET + '\n');
    });

    socket.setKeepAlive(true, 30000);
    socket.setNoDelay(true);
    socket.setTimeout(0);

    let authed = false;

    socket.on('data', (data) => {
        if (!authed) {
            const resp = data.toString().trim();
            if (resp === 'OK') {
                authed = true;
                console.log('[TUNNEL] ✅ ATIVO! PC pode usar o 5G agora.');
                // Ping a cada 25s para manter conexão viva
                pingInterval = setInterval(() => {
                    if (socket && !socket.destroyed) {
                        try {
                            socket.write(JSON.stringify({type:'ping'}) + '\n');
                        } catch(e) {}
                    }
                }, 25000);
            } else {
                console.log('[TUNNEL] Auth falhou:', resp);
                socket.destroy();
            }
            return;
        }

        buffer += data.toString('utf8');
        let idx;
        while ((idx = buffer.indexOf('\n')) !== -1) {
            const line = buffer.slice(0, idx);
            buffer = buffer.slice(idx + 1);
            try { processMsg(JSON.parse(line)); } catch(e) {}
        }
    });

    socket.on('close', () => {
        console.log('[TUNNEL] Desconectou. Reconectando em 5s...');
        authed = false;
        if (pingInterval) { clearInterval(pingInterval); pingInterval = null; }
        reconnectTimer = setTimeout(connect, 5000);
    });

    socket.on('error', (err) => {
        console.log('[TUNNEL] Erro:', err.message);
        // Não reconectar aqui - o 'close' event vai tratar
    });
}

function processMsg(msg) {
    if (msg.type === 'connect') {
        const remote = net.createConnection({ host: msg.host, port: msg.port }, () => {
            send({ type: 'connected', id: msg.id });
        });
        remote.on('data', (d) => {
            send({ type: 'data', id: msg.id, payload: d.toString('base64') });
        });
        remote.on('close', () => {
            activeConns.delete(msg.id);
            send({ type: 'close', id: msg.id });
        });
        remote.on('error', (e) => {
            activeConns.delete(msg.id);
            send({ type: 'error', id: msg.id, error: e.message });
        });
        remote.setTimeout(15000, () => { remote.destroy(); });
        remote.on('connect', () => { remote.setTimeout(0); });
        activeConns.set(msg.id, remote);
    }
    else if (msg.type === 'data') {
        const c = activeConns.get(msg.id);
        if (c && !c.destroyed) c.write(Buffer.from(msg.payload, 'base64'));
    }
    else if (msg.type === 'close') {
        const c = activeConns.get(msg.id);
        if (c) { c.destroy(); activeConns.delete(msg.id); }
    }
    else if (msg.type === 'pong') {}
}

function send(obj) {
    if (socket && !socket.destroyed) {
        try {
            socket.write(JSON.stringify(obj) + '\n');
        } catch(e) {}
    }
}

connect();
process.on('SIGINT', () => { console.log('\nEncerrando...'); process.exit(0); });
process.on('uncaughtException', (err) => {
    console.log('[TUNNEL] Erro fatal:', err.message);
    // Reconectar
    if (pingInterval) { clearInterval(pingInterval); pingInterval = null; }
    reconnectTimer = setTimeout(connect, 5000);
});
EOF

echo -e "${GREEN}[✓] Túnel iniciado${NC}"
echo ""

# Executar
SH="$SERVER_HOST" SP="$SERVER_PORT" SS="$TUNNEL_SECRET" node /data/data/com.termux/files/home/.5gshare-tunnel.js
