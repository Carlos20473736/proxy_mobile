#!/data/data/com.termux/files/usr/bin/bash
# =============================================
# PROXY MOBILE v4.0 - 1 Porta, Tudo Funciona
# =============================================
#
# Arquitetura:
#   [Fingerprint Manager] → SOCKS5 → hayabusa:32618
#        ↓ sslh detecta que NÃO é SSH
#   encaminha para 127.0.0.1:8800 (reverse tunnel)
#        ↓
#   celular:8899 (microsocks)
#        ↓
#   internet com IP do celular
#
# =============================================

# === CONFIGURAÇÕES ===
RAILWAY_HOST="hayabusa.proxy.rlwy.net"
RAILWAY_PORT="32618"
TUNNEL_USER="tunnel"
TUNNEL_PASS="proxypass123"
LOCAL_SOCKS_PORT="8899"
REMOTE_TUNNEL_PORT="8800"

# === CORES ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

clear
echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PROXY MOBILE v4.0                        ║${NC}"
echo -e "${CYAN}╠═══════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║  1 TCP Proxy | sslh + reverse tunnel      ║${NC}"
echo -e "${CYAN}║  Tudo no mesmo endereço/porta             ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# === FUNÇÕES ===
log() { echo -e "[$(date '+%H:%M:%S')] $1"; }

cleanup() {
    echo ""
    log "${YELLOW}Encerrando...${NC}"
    pkill -f microsocks 2>/dev/null
    pkill -f "ssh.*${RAILWAY_HOST}" 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

# === MATAR PROCESSOS ANTERIORES ===
log "${YELLOW}Limpando processos anteriores...${NC}"
pkill -f microsocks 2>/dev/null
pkill -f "ssh.*rlwy" 2>/dev/null
sleep 1

# === INSTALAR DEPENDÊNCIAS ===
log "${YELLOW}Verificando dependências...${NC}"
for pkg_bin in "openssh:ssh" "sshpass:sshpass"; do
    pkg_name="${pkg_bin%%:*}"
    bin_name="${pkg_bin##*:}"
    if ! command -v "$bin_name" &>/dev/null; then
        pkg install -y "$pkg_name" 2>/dev/null
    fi
    if command -v "$bin_name" &>/dev/null; then
        echo -e "  ${GREEN}✓ $pkg_name OK${NC}"
    else
        echo -e "  ${RED}✗ $pkg_name FALHOU${NC}"; exit 1
    fi
done

if ! command -v microsocks &>/dev/null; then
    pkg install -y microsocks 2>/dev/null || {
        pkg install -y git make clang 2>/dev/null
        rm -rf /tmp/microsocks
        git clone https://github.com/rofl0r/microsocks.git /tmp/microsocks 2>/dev/null
        cd /tmp/microsocks && make && cp microsocks "$PREFIX/bin/" 2>/dev/null
        cd ~
    }
fi
command -v microsocks &>/dev/null && echo -e "  ${GREEN}✓ microsocks OK${NC}" || { echo -e "  ${RED}✗ microsocks FALHOU${NC}"; exit 1; }

# === INICIAR MICROSOCKS LOCAL ===
log "${YELLOW}Iniciando SOCKS5 local (porta $LOCAL_SOCKS_PORT)...${NC}"
microsocks -i 0.0.0.0 -p "$LOCAL_SOCKS_PORT" &
MICROSOCKS_PID=$!
sleep 1
if kill -0 "$MICROSOCKS_PID" 2>/dev/null; then
    echo -e "  ${GREEN}✓ Microsocks rodando (PID $MICROSOCKS_PID)${NC}"
else
    echo -e "  ${RED}✗ Microsocks falhou${NC}"; exit 1
fi

# === TESTAR CONECTIVIDADE ===
log "${YELLOW}Testando conectividade...${NC}"
if timeout 5 bash -c "echo >/dev/tcp/${RAILWAY_HOST}/${RAILWAY_PORT}" 2>/dev/null; then
    echo -e "  ${GREEN}✓ Railway acessível${NC}"
else
    echo -e "  ${YELLOW}⚠ Não foi possível testar, tentando mesmo assim...${NC}"
fi

# === INFO ===
echo ""
echo -e "${CYAN}Configuração:${NC}"
echo -e "  Servidor:  ${RAILWAY_HOST}:${RAILWAY_PORT}"
echo -e "  Túnel:     servidor:${REMOTE_TUNNEL_PORT} ← celular:${LOCAL_SOCKS_PORT}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${BOLD}Fingerprint Manager:${NC}"
echo -e "  Tipo:      SOCKS5"
echo -e "  Host:      ${RAILWAY_HOST}"
echo -e "  Porta:     ${RAILWAY_PORT}"
echo -e "  User/Pass: (vazio)"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

# === LOOP DE RECONEXÃO ===
ATTEMPT=0
BACKOFF=2

while true; do
    ATTEMPT=$((ATTEMPT + 1))

    # Verificar microsocks
    if ! kill -0 "$MICROSOCKS_PID" 2>/dev/null; then
        microsocks -i 0.0.0.0 -p "$LOCAL_SOCKS_PORT" &
        MICROSOCKS_PID=$!
        sleep 1
    fi

    log "Conectando SSH (tentativa ${ATTEMPT})..."

    sshpass -p "$TUNNEL_PASS" ssh \
        -N -T \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o GlobalKnownHostsFile=/dev/null \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=15 \
        -o ExitOnForwardFailure=yes \
        -o TCPKeepAlive=yes \
        -o Compression=no \
        -o LogLevel=ERROR \
        -R 0.0.0.0:${REMOTE_TUNNEL_PORT}:127.0.0.1:${LOCAL_SOCKS_PORT} \
        -p "$RAILWAY_PORT" \
        "${TUNNEL_USER}@${RAILWAY_HOST}" 2>&1

    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        log "${GREEN}✓ Conexão estável encerrada${NC}"
        BACKOFF=2
        ATTEMPT=0
    else
        log "${RED}✗ Falha (código $EXIT_CODE)${NC}"
    fi

    log "Reconectando em ${BACKOFF}s..."
    sleep $BACKOFF
    BACKOFF=$((BACKOFF * 2))
    [ $BACKOFF -gt 30 ] && BACKOFF=30
done
