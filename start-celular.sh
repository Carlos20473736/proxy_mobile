#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# 5G-SHARE - Script do Celular (Termux)
# Conecta ao servidor Railway e roteia internet pelo 5G
# ============================================================

set -e

# === CONFIGURAÇÃO ===
# Coloque aqui o endereço do seu servidor Railway
SERVER_HOST="${SERVER_HOST:-SEU_APP.railway.app}"
SERVER_PORT="${SERVER_PORT:-443}"
TUNNEL_SECRET="${TUNNEL_SECRET:-tunnel_secret_key}"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="$HOME/.5gshare/config-railway.sh"

mostrar_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║       5G-SHARE - Celular → Railway (Túnel)             ║"
    echo "║   Compartilhando internet 5G com seu PC                ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

instalar_dependencias() {
    echo -e "${BLUE}[1/3] Verificando dependências...${NC}"
    
    # Verificar se node está instalado
    if ! command -v node &> /dev/null; then
        echo "  Instalando Node.js..."
        pkg install -y nodejs-lts 2>/dev/null || pkg install -y nodejs
    fi
    
    echo -e "${GREEN}  ✅ Dependências OK${NC}"
}

carregar_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}[✓] Config carregada: $SERVER_HOST:$SERVER_PORT${NC}"
        echo ""
        echo -n "Usar esta configuração? (s/n): "
        read -r usar
        if [ "$usar" != "s" ] && [ "$usar" != "S" ] && [ "$usar" != "" ]; then
            solicitar_config
        fi
    else
        solicitar_config
    fi
}

solicitar_config() {
    echo ""
    echo -e "${YELLOW}Configure a conexão com o Railway:${NC}"
    echo ""
    echo -n "  Host do Railway (ex: seu-app.railway.app): "
    read -r SERVER_HOST
    echo -n "  Porta (padrão 443): "
    read -r input_port
    SERVER_PORT="${input_port:-443}"
    echo -n "  Tunnel Secret (padrão: tunnel_secret_key): "
    read -r input_secret
    TUNNEL_SECRET="${input_secret:-tunnel_secret_key}"
    
    # Salvar
    mkdir -p "$HOME/.5gshare"
    cat > "$CONFIG_FILE" << EOF
SERVER_HOST="$SERVER_HOST"
SERVER_PORT="$SERVER_PORT"
TUNNEL_SECRET="$TUNNEL_SECRET"
EOF
    echo -e "${GREEN}  ✅ Configuração salva${NC}"
}

# === CLIENTE DE TÚNEL (Node.js) ===
criar_cliente_tunnel() {
    mkdir -p "$HOME/.5gshare"
    cat > "$HOME/.5gshare/tunnel-client.js" << 'NODEJS_EOF'
const net = require('net');

const SERVER_HOST = process.env.SERVER_HOST;
const SERVER_PORT = parseInt(process.env.SERVER_PORT || '443');
const TUNNEL_SECRET = process.env.TUNNEL_SECRET || 'tunnel_secret_key';

let socket = null;
let reconnectTimer = null;
let buffer = '';

function connect() {
    console.log(`[TUNNEL] Conectando a ${SERVER_HOST}:${SERVER_PORT}...`);
    
    socket = net.createConnection({ host: SERVER_HOST, port: SERVER_PORT }, () => {
        console.log('[TUNNEL] Conectado! Autenticando...');
        socket.write(TUNNEL_SECRET + '\n');
    });
    
    socket.setKeepAlive(true, 15000);
    socket.setTimeout(0);
    
    let authenticated = false;
    
    socket.on('data', (data) => {
        if (!authenticated) {
            const msg = data.toString('utf8').trim();
            if (msg === 'OK') {
                authenticated = true;
                console.log('[TUNNEL] Autenticado! Túnel ativo.');
                console.log('[TUNNEL] Seu PC agora pode usar a internet do seu 5G!');
                console.log('');
                // Iniciar keepalive
                startKeepalive();
            } else {
                console.log('[TUNNEL] Autenticação falhou:', msg);
                socket.destroy();
            }
            return;
        }
        
        // Processar comandos do servidor
        buffer += data.toString('utf8');
        let newlineIndex;
        while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
            const line = buffer.slice(0, newlineIndex);
            buffer = buffer.slice(newlineIndex + 1);
            processCommand(line);
        }
    });
    
    socket.on('close', () => {
        console.log('[TUNNEL] Conexão fechada. Reconectando em 5s...');
        authenticated = false;
        scheduleReconnect();
    });
    
    socket.on('error', (err) => {
        console.log('[TUNNEL] Erro:', err.message);
        scheduleReconnect();
    });
}

function scheduleReconnect() {
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => {
        connect();
    }, 5000);
}

// Conexões ativas para o celular
const activeConnections = new Map();

function processCommand(line) {
    try {
        const msg = JSON.parse(line);
        
        if (msg.type === 'connect') {
            // Servidor pede para conectar a um host
            handleConnect(msg.id, msg.host, msg.port);
        }
        else if (msg.type === 'data') {
            // Dados para uma conexão ativa
            const conn = activeConnections.get(msg.id);
            if (conn) {
                const decoded = Buffer.from(msg.payload, 'base64');
                conn.write(decoded);
            }
        }
        else if (msg.type === 'close') {
            // Fechar uma conexão
            const conn = activeConnections.get(msg.id);
            if (conn) {
                conn.destroy();
                activeConnections.delete(msg.id);
            }
        }
        else if (msg.type === 'pong') {
            // Resposta do keepalive
        }
    } catch (err) {
        // Ignorar linhas inválidas
    }
}

function handleConnect(id, host, port) {
    console.log(`[CONN ${id}] Conectando: ${host}:${port}`);
    
    const remote = net.createConnection({ host, port }, () => {
        console.log(`[CONN ${id}] Conectado!`);
        // Informar servidor que conectou
        sendToServer({ type: 'connected', id });
    });
    
    remote.on('data', (data) => {
        // Enviar dados de volta para o servidor
        sendToServer({
            type: 'data',
            id,
            payload: data.toString('base64')
        });
    });
    
    remote.on('close', () => {
        activeConnections.delete(id);
        sendToServer({ type: 'close', id });
    });
    
    remote.on('error', (err) => {
        console.log(`[CONN ${id}] Erro: ${err.message}`);
        activeConnections.delete(id);
        sendToServer({ type: 'error', id, error: err.message });
    });
    
    // Timeout de conexão
    remote.setTimeout(15000, () => {
        console.log(`[CONN ${id}] Timeout`);
        remote.destroy();
        sendToServer({ type: 'error', id, error: 'timeout' });
    });
    
    // Após conectar, remover timeout
    remote.on('connect', () => {
        remote.setTimeout(0);
    });
    
    activeConnections.set(id, remote);
}

function sendToServer(msg) {
    if (socket && !socket.destroyed) {
        socket.write(JSON.stringify(msg) + '\n');
    }
}

function startKeepalive() {
    setInterval(() => {
        sendToServer({ type: 'ping' });
    }, 25000);
}

// Iniciar
connect();

// Manter processo vivo
process.on('SIGINT', () => {
    console.log('\n[TUNNEL] Encerrando...');
    if (socket) socket.destroy();
    process.exit(0);
});

process.on('uncaughtException', (err) => {
    console.log('[TUNNEL] Erro não tratado:', err.message);
    scheduleReconnect();
});
NODEJS_EOF
}

iniciar_tunnel() {
    echo -e "${BLUE}[2/3] Criando cliente de túnel...${NC}"
    criar_cliente_tunnel
    
    echo -e "${BLUE}[3/3] Conectando ao Railway...${NC}"
    echo ""
    
    # Adquirir wake lock
    termux-wake-lock 2>/dev/null || true
    
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  TÚNEL ATIVO - Pressione Ctrl+C para parar${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Executar o cliente Node.js
    SERVER_HOST="$SERVER_HOST" \
    SERVER_PORT="$SERVER_PORT" \
    TUNNEL_SECRET="$TUNNEL_SECRET" \
    node "$HOME/.5gshare/tunnel-client.js"
}

# === EXECUÇÃO ===
mostrar_banner
instalar_dependencias
carregar_config
iniciar_tunnel
