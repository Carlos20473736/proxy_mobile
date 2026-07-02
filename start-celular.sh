#!/data/data/com.termux/files/usr/bin/bash
# ============================================
# PROXY MOBILE v3.1 - SSH Direto (Máx Velocidade)
# ============================================
# Arquitetura simplificada:
# - SSH direto (sem sslh no meio = menos latência)
# - Reverse tunnel: porta 9050 do Railway ← microsocks do celular
# - Fingerprint Manager conecta no TCP Proxy da porta 9050
# ============================================

# === CONFIGURAÇÕES ===
RAILWAY_HOST="nozomi.proxy.rlwy.net"
RAILWAY_PORT="33719"
TUNNEL_USER="tunnel"
TUNNEL_PASS="proxypass123"

# === CORES ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PROXY MOBILE v3.1 - SSH Direto (Turbo)   ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║  SSH direto (sem sslh = menos latência)   ║${NC}"
echo -e "${CYAN}║  Ciphers leves + buffers otimizados       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# === MATAR PROCESSOS ANTERIORES ===
echo -e "${YELLOW}[1/3] Limpando processos anteriores...${NC}"
pkill -f microsocks 2>/dev/null
pkill -f "ssh.*rlwy" 2>/dev/null
pkill -f chisel 2>/dev/null
sleep 1

# === INICIAR MICROSOCKS ===
echo -e "${YELLOW}[2/3] Iniciando proxy SOCKS5 local...${NC}"
# Verificar se microsocks está instalado
if ! command -v microsocks &>/dev/null; then
    echo -e "${YELLOW}  → Instalando microsocks...${NC}"
    pkg install -y microsocks 2>/dev/null || {
        # Compilar manualmente se pkg não tiver
        pkg install -y git make clang 2>/dev/null
        git clone https://github.com/rofl0r/microsocks.git /tmp/microsocks 2>/dev/null
        cd /tmp/microsocks && make && cp microsocks $PREFIX/bin/
        cd ~
    }
fi

microsocks -i 127.0.0.1 -p 8899 &
sleep 1

if pgrep -f "microsocks" > /dev/null; then
    echo -e "${GREEN}  ✓ Microsocks rodando (porta 8899)${NC}"
else
    echo -e "${RED}  ✗ Falha ao iniciar microsocks!${NC}"
    exit 1
fi

# === CONECTAR VIA SSH ===
echo -e "${YELLOW}[3/3] Conectando ao Railway...${NC}"
echo ""
echo -e "${CYAN}Configuração:${NC}"
echo -e "  Railway: ${RAILWAY_HOST}:${RAILWAY_PORT}"
echo -e "  Túnel:   porta 9050 (Railway) ← porta 8899 (celular)"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}Fingerprint Manager:${NC}"
echo -e "  Tipo: SOCKS5"
echo -e "  Host: reseau.proxy.rlwy.net"
echo -e "  Porta: 51887"
echo -e "  User/Pass: (vazio)"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

# Verificar se sshpass está instalado
if ! command -v sshpass &>/dev/null; then
    echo -e "${YELLOW}  → Instalando sshpass...${NC}"
    pkg install -y sshpass 2>/dev/null
fi

# === LOOP DE RECONEXÃO ===
ATTEMPT=0
BACKOFF=2
MAX_BACKOFF=30

while true; do
    ATTEMPT=$((ATTEMPT + 1))
    TIMESTAMP=$(date '+%H:%M:%S')
    echo -e "[${TIMESTAMP}] Conectando SSH (tentativa ${ATTEMPT})..."

    sshpass -p "$TUNNEL_PASS" ssh -N \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=10 \
        -o ExitOnForwardFailure=yes \
        -o Compression=no \
        -o IPQoS=throughput \
        -o "Ciphers=aes128-gcm@openssh.com,chacha20-poly1305@openssh.com" \
        -o "MACs=hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com" \
        -o "KexAlgorithms=curve25519-sha256,curve25519-sha256@libssh.org" \
        -o "RekeyLimit=0 0" \
        -R 0.0.0.0:9050:127.0.0.1:8899 \
        -p "$RAILWAY_PORT" \
        "${TUNNEL_USER}@${RAILWAY_HOST}"

    EXIT_CODE=$?
    TIMESTAMP=$(date '+%H:%M:%S')

    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${YELLOW}[${TIMESTAMP}] Conexão encerrada normalmente${NC}"
        BACKOFF=2
    else
        echo -e "${RED}[${TIMESTAMP}] Falha (código: $EXIT_CODE)${NC}"
    fi

    # Backoff exponencial (max 30s)
    echo -e "  → Reconectando em ${BACKOFF}s..."
    sleep $BACKOFF
    BACKOFF=$((BACKOFF * 2))
    [ $BACKOFF -gt $MAX_BACKOFF ] && BACKOFF=$MAX_BACKOFF
done
