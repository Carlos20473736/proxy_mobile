#!/data/data/com.termux/files/usr/bin/bash
# ============================================
# PROXY MOBILE - Conectar ao Railway
# ============================================
# Execute este script no Termux após configurar
# o microsocks e o Railway.
# ============================================

# === CONFIGURAÇÕES (EDITE AQUI) ===
RAILWAY_HOST="SEU_DOMINIO.proxy.rlwy.net"  # Domínio TCP do Railway (porta SSH)
RAILWAY_SSH_PORT="PORTA_SSH"                # Porta SSH pública do Railway
RAILWAY_USER="tunnel"
RAILWAY_PASS="proxypass123"

PROXY_PORT=8899
PROXY_USER="carlos"
PROXY_PASS="oitavamente"

# === CORES ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PROXY MOBILE - Railway (Brasil)         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# === MATAR PROCESSOS ANTERIORES ===
echo -e "${YELLOW}[1/3] Limpando processos anteriores...${NC}"
pkill -f microsocks 2>/dev/null
pkill -f "ssh.*railway" 2>/dev/null
pkill -f "ssh.*rlwy" 2>/dev/null
sleep 1

# === INICIAR MICROSOCKS ===
echo -e "${YELLOW}[2/3] Iniciando proxy SOCKS5...${NC}"
microsocks -i 0.0.0.0 -p $PROXY_PORT -u $PROXY_USER -P $PROXY_PASS &
MICRO_PID=$!
sleep 1

if kill -0 $MICRO_PID 2>/dev/null; then
    echo -e "${GREEN}  ✓ Microsocks rodando na porta $PROXY_PORT${NC}"
else
    echo -e "${RED}  ✗ Falha ao iniciar microsocks!${NC}"
    exit 1
fi

# === CONECTAR AO RAILWAY ===
echo -e "${YELLOW}[3/3] Conectando ao Railway...${NC}"
echo ""
echo -e "${CYAN}Configuração:${NC}"
echo -e "  Host Railway: $RAILWAY_HOST:$RAILWAY_SSH_PORT"
echo -e "  Proxy local:  localhost:$PROXY_PORT"
echo -e "  Forwarding:   porta 1080 no Railway → localhost:$PROXY_PORT"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"

# Loop de reconexão
while true; do
    echo -e "${YELLOW}[TÚNEL] Conectando ao Railway...${NC}"
    
    sshpass -p "$RAILWAY_PASS" ssh \
        -p $RAILWAY_SSH_PORT \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o TCPKeepAlive=yes \
        -o ExitOnForwardFailure=yes \
        -o Compression=yes \
        -o Ciphers=aes128-gcm@openssh.com \
        -N \
        -R 0.0.0.0:1080:localhost:$PROXY_PORT \
        ${RAILWAY_USER}@${RAILWAY_HOST}
    
    EXIT_CODE=$?
    echo -e "${RED}[TÚNEL] Desconectado (código: $EXIT_CODE)${NC}"
    echo -e "${YELLOW}[TÚNEL] Reconectando em 2s...${NC}"
    sleep 2
done
