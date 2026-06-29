#!/data/data/com.termux/files/usr/bin/bash
# ============================================
# PROXY MOBILE - Conectar ao Railway
# ============================================
# Execute este script no Termux após configurar
# o microsocks e o Railway.
#
# ATENÇÃO (causa comum de "Connection reset/closed"):
#   RAILWAY_HOST/RAILWAY_PORT abaixo DEVEM apontar para o
#   TCP Proxy que o Railway gerou para a porta interna 1080
#   (o sslh multiplexa SSH e SOCKS5 na MESMA porta 1080).
#   NÃO use uma porta que aponte para nada além da 1080.
# ============================================

# === CONFIGURAÇÕES ===
# Host e porta do TCP Proxy do Railway que aponta para a porta interna 1080.
# Ex.: se o Railway gerou "nozomi.proxy.rlwy.net:33719" para a porta 1080,
# use exatamente esses valores aqui.
RAILWAY_HOST="nozomi.proxy.rlwy.net"
RAILWAY_PORT="33719"
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
echo -e "${CYAN}║  PROXY MOBILE - Railway (US East)         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# === MATAR PROCESSOS ANTERIORES ===
echo -e "${YELLOW}[1/3] Limpando processos anteriores...${NC}"
pkill -f microsocks 2>/dev/null
pkill -f "ssh.*rlwy" 2>/dev/null
sleep 1

# === INICIAR MICROSOCKS ===
# IMPORTANTE: o motor Chromium (Chrome e o navegador do Fingerprint Manager)
# NAO suporta SOCKS5 com usuario/senha -> isso causa ERR_NO_SUPPORTED_PROXIES.
# Por isso o microsocks roda SEM autenticacao.
# Para nao deixar o proxy aberto na internet, o microsocks escuta apenas em
# 127.0.0.1 (localhost) do celular. O tunel SSH reverso entrega o trafego
# do Railway nesse localhost, entao continua funcionando, mas ninguem na
# internet consegue acessar o microsocks diretamente.
echo -e "${YELLOW}[2/3] Iniciando proxy SOCKS5 (sem senha, restrito ao tunel)...${NC}"
microsocks -i 127.0.0.1 -p $PROXY_PORT &
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
echo -e "${CYAN}Dados:${NC}"
echo -e "  Railway: $RAILWAY_HOST:$RAILWAY_PORT (porta interna 1080 -> sslh)"
echo -e "  Túnel:   porta 9050 (Railway) ← porta $PROXY_PORT (celular)"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"

# Loop de reconexão
while true; do
    echo -e "${YELLOW}[$(date +%H:%M:%S)] Conectando SSH...${NC}"

    # OTIMIZACOES DE VELOCIDADE:
    # - Compression=no: trafego web ja vem comprimido (HTTPS/imagens/video);
    #   comprimir de novo so gasta CPU do celular e atrasa. Desligar acelera.
    # - Cipher e MAC leves (chacha20/aes-gcm): menos CPU no celular = mais vazao.
    # - ServerAliveInterval mais alto: menos overhead de keepalive.
    sshpass -p "$RAILWAY_PASS" ssh \
        -p $RAILWAY_PORT \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o TCPKeepAlive=yes \
        -o ExitOnForwardFailure=yes \
        -o Compression=no \
        -o Ciphers=chacha20-poly1305@openssh.com,aes128-gcm@openssh.com \
        -o IPQoS=throughput \
        -N \
        -R 0.0.0.0:9050:localhost:$PROXY_PORT \
        ${RAILWAY_USER}@${RAILWAY_HOST}

    EXIT_CODE=$?
    echo -e "${RED}[$(date +%H:%M:%S)] Desconectado (código: $EXIT_CODE)${NC}"
    echo -e "${YELLOW}Reconectando em 2s...${NC}"
    sleep 2
done
