#!/data/data/com.termux/files/usr/bin/bash
# ============================================
# PROXY MOBILE v3.0 - CHISEL (Máxima Velocidade)
# ============================================
# Usa chisel em vez de SSH para o túnel.
# Chisel usa HTTP2/WebSocket = muito mais rápido.
#
# O celular roda como chisel client com "R:socks":
# - O servidor Railway aceita conexões SOCKS5 na porta 1080
# - As conexões são tuneladas via HTTP2 até aqui (celular)
# - O celular faz as requisições usando seu IP 5G/4G
#
# NÃO precisa mais de microsocks nem sshpass!
# O chisel tem SOCKS5 server embutido.
# ============================================

# === CONFIGURAÇÕES ===
# Host e porta do TCP Proxy do Railway (porta interna 1080)
RAILWAY_HOST="nozomi.proxy.rlwy.net"
RAILWAY_PORT="33719"
RAILWAY_USER="tunnel"
RAILWAY_PASS="proxypass123"

# Versão do chisel
CHISEL_VERSION="1.11.7"

# === CORES ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PROXY MOBILE v3.0 - CHISEL (Turbo)      ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║  Protocolo: HTTP2/WebSocket               ║${NC}"
echo -e "${CYAN}║  Túnel: Reverse SOCKS5 embutido           ║${NC}"
echo -e "${CYAN}║  Sem SSH, sem microsocks = mais rápido!   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# === MATAR PROCESSOS ANTERIORES ===
echo -e "${YELLOW}[1/4] Limpando processos anteriores...${NC}"
pkill -f chisel 2>/dev/null
pkill -f microsocks 2>/dev/null
pkill -f "ssh.*rlwy" 2>/dev/null
sleep 1

# === CORRIGIR DNS DO TERMUX ===
echo -e "${YELLOW}[2/4] Configurando DNS...${NC}"

# O Termux às vezes não tem resolver DNS funcionando em [::1]:53
# Vamos resolver o hostname para IP antes de conectar
RAILWAY_IP=$(getent hosts "$RAILWAY_HOST" 2>/dev/null | awk '{print $1}' | head -1)

if [ -z "$RAILWAY_IP" ]; then
    # Fallback: usar dig ou nslookup ou host
    RAILWAY_IP=$(dig +short "$RAILWAY_HOST" 2>/dev/null | head -1)
fi

if [ -z "$RAILWAY_IP" ]; then
    # Fallback 2: usar ping para resolver
    RAILWAY_IP=$(ping -c 1 -W 2 "$RAILWAY_HOST" 2>/dev/null | grep -oP '\(\K[0-9.]+' | head -1)
fi

if [ -z "$RAILWAY_IP" ]; then
    echo -e "${RED}  ✗ Não conseguiu resolver DNS de $RAILWAY_HOST${NC}"
    echo -e "${YELLOW}  Tentando conectar pelo hostname mesmo...${NC}"
    CONNECT_HOST="$RAILWAY_HOST"
else
    echo -e "${GREEN}  ✓ DNS resolvido: $RAILWAY_HOST → $RAILWAY_IP${NC}"
    CONNECT_HOST="$RAILWAY_IP"
fi

# === VERIFICAR/INSTALAR CHISEL ===
echo -e "${YELLOW}[3/4] Verificando chisel...${NC}"
if ! command -v chisel &>/dev/null; then
    echo -e "${YELLOW}  → Instalando chisel v${CHISEL_VERSION}...${NC}"
    
    # Detectar arquitetura
    ARCH=$(uname -m)
    case $ARCH in
        aarch64) CHISEL_ARCH="arm64" ;;
        armv7l)  CHISEL_ARCH="armv7" ;;
        armv6l)  CHISEL_ARCH="armv6" ;;
        x86_64)  CHISEL_ARCH="amd64" ;;
        *)       echo -e "${RED}Arquitetura não suportada: $ARCH${NC}"; exit 1 ;;
    esac
    
    curl -fsSL "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_linux_${CHISEL_ARCH}.gz" \
        | gunzip > "$PREFIX/bin/chisel" && \
        chmod +x "$PREFIX/bin/chisel"
    
    if command -v chisel &>/dev/null; then
        echo -e "${GREEN}  ✓ Chisel instalado com sucesso${NC}"
    else
        echo -e "${RED}  ✗ Falha ao instalar chisel!${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}  ✓ Chisel já instalado${NC}"
fi

# === CONECTAR AO RAILWAY ===
echo -e "${YELLOW}[4/4] Conectando ao Railway via chisel...${NC}"
echo ""
echo -e "${CYAN}Configuração:${NC}"
echo -e "  Servidor: ${CONNECT_HOST}:${RAILWAY_PORT}"
echo -e "  Modo: Reverse SOCKS5 (R:socks)"
echo -e "  Protocolo: HTTP2/WebSocket"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Quando conectar, o Fingerprint Manager usa:${NC}"
echo -e "  Tipo: SOCKS5"
echo -e "  Host: ${RAILWAY_HOST}"
echo -e "  Porta: ${RAILWAY_PORT}"
echo -e "  User/Pass: (vazio)"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

# === EXECUTAR CHISEL CLIENT ===
# R:socks = Reverse SOCKS5
#   O servidor escuta SOCKS5 e envia o tráfego para cá (celular)
#   O celular resolve DNS e faz as conexões usando seu IP 5G/4G
#
# --keepalive 10s = detecta queda rápido
# Reconexão automática com backoff exponencial embutida!
exec chisel client \
    --keepalive 10s \
    --auth ${RAILWAY_USER}:${RAILWAY_PASS} \
    "http://${CONNECT_HOST}:${RAILWAY_PORT}" \
    R:socks
