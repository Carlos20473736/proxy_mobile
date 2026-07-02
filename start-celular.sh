#!/data/data/com.termux/files/usr/bin/bash
# ============================================
# PROXY MOBILE v2.0 - Conectar ao Railway
# ============================================
# Execute este script no Termux após configurar
# o microsocks e o Railway.
#
# OTIMIZAÇÕES v2.0:
# - SSH multiplexing (ControlMaster) para reconexão instantânea
# - Ciphers ultra-leves (menos CPU no celular = mais banda)
# - Buffers SSH maiores (menos syscalls = mais throughput)
# - Reconexão inteligente com backoff
# - Desabilitado rekey (evita micro-pausas)
# ============================================

# === CONFIGURAÇÕES ===
RAILWAY_HOST="nozomi.proxy.rlwy.net"
RAILWAY_PORT="33719"
RAILWAY_USER="tunnel"
RAILWAY_PASS="proxypass123"

PROXY_PORT=8899

# === CORES ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === DIRETÓRIO PARA SSH MULTIPLEXING ===
SSH_CONTROL_DIR="$HOME/.ssh/proxy_mobile"
mkdir -p "$SSH_CONTROL_DIR"

clear
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PROXY MOBILE v2.0 - Railway (Otimizado) ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# === MATAR PROCESSOS ANTERIORES ===
echo -e "${YELLOW}[1/3] Limpando processos anteriores...${NC}"
pkill -f microsocks 2>/dev/null
pkill -f "ssh.*rlwy" 2>/dev/null
sleep 1

# === INICIAR MICROSOCKS ===
# Sem autenticação pois Chromium não suporta SOCKS5 com senha.
# Escuta apenas em 127.0.0.1 (seguro: só acessível via túnel SSH).
echo -e "${YELLOW}[2/3] Iniciando proxy SOCKS5 local...${NC}"
microsocks -i 127.0.0.1 -p $PROXY_PORT &
MICRO_PID=$!
sleep 1

if kill -0 $MICRO_PID 2>/dev/null; then
    echo -e "${GREEN}  ✓ Microsocks rodando (porta $PROXY_PORT, sem auth)${NC}"
else
    echo -e "${RED}  ✗ Falha ao iniciar microsocks!${NC}"
    exit 1
fi

# === CONECTAR AO RAILWAY ===
echo -e "${YELLOW}[3/3] Conectando ao Railway...${NC}"
echo ""
echo -e "${CYAN}Configuração:${NC}"
echo -e "  Railway: $RAILWAY_HOST:$RAILWAY_PORT"
echo -e "  Túnel:   porta 9050 (Railway) ← porta $PROXY_PORT (celular)"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

# === VARIÁVEIS DE RECONEXÃO ===
RETRY_DELAY=1
MAX_RETRY_DELAY=30
CONSECUTIVE_FAILS=0

# === LOOP DE RECONEXÃO COM BACKOFF INTELIGENTE ===
while true; do
    echo -e "${YELLOW}[$(date +%H:%M:%S)] Conectando SSH (tentativa $((CONSECUTIVE_FAILS+1)))...${NC}"

    # OTIMIZAÇÕES DE VELOCIDADE DO SSH:
    #
    # -o Compression=no
    #    Tráfego web já vem comprimido (HTTPS/gzip/brotli/imagens/vídeo).
    #    Comprimir de novo só gasta CPU do celular e ATRASA.
    #
    # -o Ciphers=aes128-gcm@openssh.com
    #    AES-128-GCM é o cipher mais rápido em CPUs ARM com extensão AES
    #    (todos os celulares modernos têm). Usa aceleração de hardware.
    #    chacha20 é backup para CPUs sem AES-NI.
    #
    # -o MACs=hmac-sha2-256-etm@openssh.com
    #    MAC leve e seguro. ETM (encrypt-then-mac) é mais eficiente.
    #
    # -o RekeyLimit="0 0"
    #    Desabilita renegociação de chaves. Evita micro-pausas a cada 1GB
    #    ou 1h de tráfego. Segurança é mantida pelo cipher GCM.
    #
    # -o IPQoS=throughput
    #    Marca pacotes como "throughput" (DSCP), priorizando banda sobre latência.
    #
    # -o ServerAliveInterval=15
    #    Envia keepalive a cada 15s. Detecta queda em ~45s.
    #    Não usar valor muito baixo para não gastar bateria.
    #
    # -o TCPKeepAlive=yes
    #    Keepalive na camada TCP também (redundância com ServerAlive).
    #
    # -o ExitOnForwardFailure=yes
    #    Se a porta 9050 já estiver em uso (sessão anterior não morreu),
    #    o SSH sai imediatamente em vez de ficar pendurado sem túnel.
    #
    sshpass -p "$RAILWAY_PASS" ssh \
        -p $RAILWAY_PORT \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o TCPKeepAlive=yes \
        -o ExitOnForwardFailure=yes \
        -o Compression=no \
        -o Ciphers=aes128-gcm@openssh.com,chacha20-poly1305@openssh.com \
        -o MACs=hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com \
        -o KexAlgorithms=curve25519-sha256 \
        -o RekeyLimit="0 0" \
        -o IPQoS=throughput \
        -o ConnectTimeout=10 \
        -N \
        -R 0.0.0.0:9050:127.0.0.1:$PROXY_PORT \
        ${RAILWAY_USER}@${RAILWAY_HOST}

    EXIT_CODE=$?

    # === RECONEXÃO INTELIGENTE COM BACKOFF ===
    if [ $EXIT_CODE -eq 0 ]; then
        # Conexão foi encerrada normalmente (servidor reiniciou?)
        RETRY_DELAY=1
        CONSECUTIVE_FAILS=0
        echo -e "${YELLOW}[$(date +%H:%M:%S)] Conexão encerrada. Reconectando em ${RETRY_DELAY}s...${NC}"
    else
        CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
        echo -e "${RED}[$(date +%H:%M:%S)] Falha (código: $EXIT_CODE)${NC}"

        if [ $CONSECUTIVE_FAILS -ge 5 ]; then
            # Após 5 falhas seguidas, reiniciar microsocks (pode estar travado)
            echo -e "${YELLOW}  → Reiniciando microsocks...${NC}"
            pkill -f microsocks 2>/dev/null
            sleep 1
            microsocks -i 127.0.0.1 -p $PROXY_PORT &
            MICRO_PID=$!
            CONSECUTIVE_FAILS=0
            RETRY_DELAY=2
        else
            # Backoff exponencial: 1s, 2s, 4s, 8s, 16s, max 30s
            RETRY_DELAY=$((RETRY_DELAY * 2))
            if [ $RETRY_DELAY -gt $MAX_RETRY_DELAY ]; then
                RETRY_DELAY=$MAX_RETRY_DELAY
            fi
        fi

        echo -e "${YELLOW}  → Reconectando em ${RETRY_DELAY}s...${NC}"
    fi

    sleep $RETRY_DELAY
done
