#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# 5G-SHARE v5.0 - VELOCIDADE MÁXIMA (Cloudflare Tunnel)
# Roda proxy SOCKS5 local + expõe via Cloudflare (datacenter SP)
# ============================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# === CONFIGURAÇÃO ===
PROXY_PORT=1080
PROXY_USER="5guser"
PROXY_PASS="senha123"
URL_FILE="$HOME/.5gshare-url.txt"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║    5G-SHARE v5.0 - VELOCIDADE MÁXIMA (Cloudflare)      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# === INSTALAR DEPENDÊNCIAS ===
echo -e "[1/3] Verificando dependências..."

if ! command -v microsocks &> /dev/null; then
    echo "  → Instalando microsocks..."
    pkg install -y microsocks 2>/dev/null
fi

if ! command -v cloudflared &> /dev/null; then
    echo "  → Instalando cloudflared..."
    # Baixar binário ARM64 do cloudflared
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ]; then
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    else
        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
    fi
    curl -sL "$CF_URL" -o "$PREFIX/bin/cloudflared"
    chmod +x "$PREFIX/bin/cloudflared"
fi

echo -e "  ${GREEN}✓ Dependências OK${NC}"

# === MATAR PROCESSOS ANTERIORES ===
pkill -f microsocks 2>/dev/null
pkill -f cloudflared 2>/dev/null
sleep 1

# === WAKE LOCK ===
termux-wake-lock 2>/dev/null

# === INICIAR PROXY SOCKS5 ===
echo -e "[2/3] Iniciando proxy SOCKS5..."
microsocks -i 127.0.0.1 -p $PROXY_PORT -u "$PROXY_USER" -P "$PROXY_PASS" &
PROXY_PID=$!
sleep 1

if kill -0 $PROXY_PID 2>/dev/null; then
    echo -e "  ${GREEN}✓ Proxy SOCKS5 rodando na porta $PROXY_PORT${NC}"
else
    echo -e "  ${RED}✗ Falha ao iniciar proxy${NC}"
    exit 1
fi

# === INICIAR CLOUDFLARE TUNNEL ===
echo -e "[3/3] Criando túnel Cloudflare..."
echo ""

# Cloudflared expõe a porta local do proxy via túnel
cloudflared tunnel --url tcp://127.0.0.1:$PROXY_PORT --no-autoupdate 2>&1 &
CF_PID=$!

# Esperar URL do túnel aparecer
echo -e "  Aguardando URL do túnel..."
TUNNEL_URL=""
for i in $(seq 1 30); do
    sleep 1
    # Cloudflared imprime a URL no stderr
    TUNNEL_URL=$(cat /proc/$CF_PID/fd/2 2>/dev/null | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1)
    if [ -z "$TUNNEL_URL" ]; then
        # Tentar de outra forma
        TUNNEL_URL=$(ps aux 2>/dev/null | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1)
    fi
    if [ -n "$TUNNEL_URL" ]; then
        break
    fi
done

# Se não encontrou, usar log file
if [ -z "$TUNNEL_URL" ]; then
    # Reiniciar com log
    kill $CF_PID 2>/dev/null
    sleep 1
    CF_LOG="$HOME/.5gshare-cf.log"
    cloudflared tunnel --url tcp://127.0.0.1:$PROXY_PORT --no-autoupdate > "$CF_LOG" 2>&1 &
    CF_PID=$!
    
    for i in $(seq 1 30); do
        sleep 1
        TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1)
        if [ -n "$TUNNEL_URL" ]; then
            break
        fi
    done
fi

if [ -z "$TUNNEL_URL" ]; then
    echo -e "  ${RED}✗ Não conseguiu criar túnel. Tentando método alternativo...${NC}"
    kill $CF_PID 2>/dev/null
    sleep 1
    
    # Método alternativo: rodar em foreground e capturar
    CF_LOG="$HOME/.5gshare-cf.log"
    cloudflared tunnel --url tcp://127.0.0.1:$PROXY_PORT --no-autoupdate 2>"$CF_LOG" &
    CF_PID=$!
    
    for i in $(seq 1 30); do
        sleep 1
        TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1)
        if [ -n "$TUNNEL_URL" ]; then
            break
        fi
    done
fi

if [ -z "$TUNNEL_URL" ]; then
    echo -e "  ${RED}✗ Falha ao obter URL do túnel${NC}"
    echo "  Verifique sua conexão de internet"
    kill $PROXY_PID $CF_PID 2>/dev/null
    exit 1
fi

# Extrair hostname do URL
TUNNEL_HOST=$(echo "$TUNNEL_URL" | sed 's|https://||')

# Salvar URL
echo "$TUNNEL_HOST" > "$URL_FILE"

echo -e "  ${GREEN}✓ Túnel Cloudflare criado!${NC}"
echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}"
echo "  DADOS PARA O PC:"
echo ""
echo "  Host: $TUNNEL_HOST"
echo "  Usuário: $PROXY_USER"
echo "  Senha: $PROXY_PASS"
echo ""
echo "  No PC, rode o conectar-pc.bat"
echo -e "${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}  ✅ SERVIDOR ATIVO - Pressione Ctrl+C para parar${NC}"
echo ""

# === MANTER VIVO ===
cleanup() {
    echo ""
    echo "Encerrando..."
    kill $PROXY_PID $CF_PID 2>/dev/null
    termux-wake-unlock 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

# Monitor
while true; do
    if ! kill -0 $CF_PID 2>/dev/null; then
        echo -e "${RED}[!] Túnel caiu. Reiniciando...${NC}"
        CF_LOG="$HOME/.5gshare-cf.log"
        cloudflared tunnel --url tcp://127.0.0.1:$PROXY_PORT --no-autoupdate 2>"$CF_LOG" &
        CF_PID=$!
        sleep 10
        NEW_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1)
        if [ -n "$NEW_URL" ]; then
            TUNNEL_HOST=$(echo "$NEW_URL" | sed 's|https://||')
            echo "$TUNNEL_HOST" > "$URL_FILE"
            echo -e "${GREEN}[✓] Novo túnel: $TUNNEL_HOST${NC}"
        fi
    fi
    if ! kill -0 $PROXY_PID 2>/dev/null; then
        echo -e "${RED}[!] Proxy caiu. Reiniciando...${NC}"
        microsocks -i 127.0.0.1 -p $PROXY_PORT -u "$PROXY_USER" -P "$PROXY_PASS" &
        PROXY_PID=$!
    fi
    sleep 15
done
