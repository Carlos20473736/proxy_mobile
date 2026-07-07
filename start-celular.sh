#!/data/data/com.termux/files/usr/bin/bash
# ============================================
# PROXY MOBILE v3.2 - SSH Direto (Máx Velocidade)
# ============================================
# Arquitetura:
# - SSH direto (sem sslh = menos latência)
# - Reverse tunnel: porta 9050 do Railway ← microsocks do celular
# - Fingerprint Manager conecta no TCP Proxy da porta 9050
# ============================================

# === CONFIGURAÇÕES ===
# Edite aqui com os dados do seu TCP Proxy (porta 1080)
RAILWAY_HOST="hayabusa.proxy.rlwy.net"
RAILWAY_PORT="32871"
TUNNEL_USER="tunnel"
TUNNEL_PASS="proxypass123"

# Porta local do microsocks
LOCAL_SOCKS_PORT="8899"

# === CORES ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# === FUNÇÕES AUXILIARES ===
log_info() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"; }
log_ok() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $1"; }
log_err() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $1"; }
log_warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] !${NC} $1"; }

clear
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  PROXY MOBILE v3.2 - SSH Direto (Turbo)       ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║  SSH direto (sem sslh = menos latência)       ║${NC}"
echo -e "${CYAN}║  Ciphers leves + buffers otimizados           ║${NC}"
echo -e "${CYAN}║  Reconexão automática com backoff             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# === VERIFICAR DEPENDÊNCIAS ===
check_install() {
    local pkg_name="$1"   # nome do pacote (pkg install)
    local bin_name="$2"   # nome do binário (command -v)
    # Se não informar bin_name, usa pkg_name
    [ -z "$bin_name" ] && bin_name="$pkg_name"
    if ! command -v "$bin_name" &>/dev/null; then
        log_warn "Instalando $pkg_name..."
        pkg install -y "$pkg_name" 2>/dev/null
        if ! command -v "$bin_name" &>/dev/null; then
            log_err "Falha ao instalar $pkg_name (binário: $bin_name)!"
            return 1
        fi
    fi
    log_ok "$pkg_name OK"
    return 0
}

# === MATAR PROCESSOS ANTERIORES ===
log_info "Limpando processos anteriores..."
pkill -f microsocks 2>/dev/null
pkill -f "ssh.*${RAILWAY_HOST}" 2>/dev/null
pkill -f "ssh.*rlwy" 2>/dev/null
sleep 1

# === VERIFICAR/INSTALAR DEPENDÊNCIAS ===
log_info "Verificando dependências..."
check_install "openssh" "ssh" || { log_err "SSH é necessário!"; exit 1; }
check_install "sshpass" "sshpass" || { log_err "sshpass é necessário!"; exit 1; }

# Microsocks - tentar pkg primeiro, senão compilar
if ! command -v microsocks &>/dev/null; then
    log_warn "Instalando microsocks..."
    pkg install -y microsocks 2>/dev/null
    if ! command -v microsocks &>/dev/null; then
        log_warn "Compilando microsocks..."
        pkg install -y git make clang 2>/dev/null
        rm -rf /tmp/microsocks
        git clone https://github.com/rofl0r/microsocks.git /tmp/microsocks 2>/dev/null
        cd /tmp/microsocks && make && cp microsocks "$PREFIX/bin/" 2>/dev/null
        cd ~
    fi
fi

if ! command -v microsocks &>/dev/null; then
    log_err "Não foi possível instalar microsocks!"
    exit 1
fi

# === INICIAR MICROSOCKS ===
log_info "Iniciando proxy SOCKS5 local..."
microsocks -i 0.0.0.0 -p "$LOCAL_SOCKS_PORT" &
MICROSOCKS_PID=$!
sleep 1

if kill -0 "$MICROSOCKS_PID" 2>/dev/null; then
    log_ok "Microsocks rodando (PID: $MICROSOCKS_PID, porta $LOCAL_SOCKS_PORT)"
else
    log_err "Falha ao iniciar microsocks!"
    exit 1
fi

# === TESTAR CONECTIVIDADE ===
log_info "Testando conectividade com Railway..."
if command -v nc &>/dev/null; then
    if nc -z -w 5 "$RAILWAY_HOST" "$RAILWAY_PORT" 2>/dev/null; then
        log_ok "Railway acessível ($RAILWAY_HOST:$RAILWAY_PORT)"
    else
        log_warn "Railway não respondeu ao teste de porta (pode funcionar mesmo assim)"
    fi
elif command -v timeout &>/dev/null; then
    timeout 5 bash -c "echo >/dev/tcp/$RAILWAY_HOST/$RAILWAY_PORT" 2>/dev/null && \
        log_ok "Railway acessível" || \
        log_warn "Railway não respondeu ao teste (pode funcionar mesmo assim)"
fi

# === INFORMAÇÕES DE CONEXÃO ===
echo ""
echo -e "${BOLD}Configuração:${NC}"
echo -e "  Railway SSH: ${CYAN}${RAILWAY_HOST}:${RAILWAY_PORT}${NC}"
echo -e "  Túnel:       porta 9050 (Railway) ← porta $LOCAL_SOCKS_PORT (celular)"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}Fingerprint Manager:${NC}"
echo -e "  Tipo:      SOCKS5"
echo -e "  Host:      reseau.proxy.rlwy.net"
echo -e "  Porta:     51887"
echo -e "  User/Pass: (vazio)"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""

# === LOOP DE RECONEXÃO ===
ATTEMPT=0
BACKOFF=2
MAX_BACKOFF=30
CONNECTED_ONCE=false

cleanup() {
    echo ""
    log_info "Encerrando..."
    pkill -f microsocks 2>/dev/null
    pkill -f "ssh.*${RAILWAY_HOST}" 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

while true; do
    ATTEMPT=$((ATTEMPT + 1))

    # Verificar se microsocks ainda está rodando
    if ! kill -0 "$MICROSOCKS_PID" 2>/dev/null; then
        log_warn "Microsocks morreu, reiniciando..."
        microsocks -i 0.0.0.0 -p "$LOCAL_SOCKS_PORT" &
        MICROSOCKS_PID=$!
        sleep 1
    fi

    log_info "Conectando SSH (tentativa ${ATTEMPT})..."

    # === CONEXÃO SSH ===
    # Notas sobre as opções:
    # -N = não executar comando remoto (só túnel)
    # -T = não alocar terminal (menos overhead)
    # -R = reverse tunnel (servidor escuta na 9050, encaminha para local 8899)
    # -o StrictHostKeyChecking=no = aceitar host key automaticamente
    # -o UserKnownHostsFile=/dev/null = não salvar host keys (mudam no Railway)
    # -o ServerAliveInterval = enviar keepalive a cada N segundos
    # -o ServerAliveCountMax = desconectar após N keepalives sem resposta
    # -o ConnectTimeout = timeout da conexão inicial
    # -o ExitOnForwardFailure = sair se o túnel não puder ser criado
    # -o TCPKeepAlive = keepalive TCP (além do SSH keepalive)
    sshpass -p "$TUNNEL_PASS" ssh \
        -N -T \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o GlobalKnownHostsFile=/dev/null \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=15 \
        -o ConnectionAttempts=1 \
        -o ExitOnForwardFailure=yes \
        -o TCPKeepAlive=yes \
        -o Compression=no \
        -o IPQoS=throughput \
        -o "Ciphers=aes128-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-gcm@openssh.com" \
        -o "MACs=hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512-etm@openssh.com" \
        -o "KexAlgorithms=curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256" \
        -o "RekeyLimit=0 0" \
        -o "LogLevel=ERROR" \
        -R 0.0.0.0:9050:127.0.0.1:${LOCAL_SOCKS_PORT} \
        -p "$RAILWAY_PORT" \
        "${TUNNEL_USER}@${RAILWAY_HOST}" 2>&1

    EXIT_CODE=$?

    case $EXIT_CODE in
        0)
            log_warn "Conexão encerrada normalmente"
            BACKOFF=2
            CONNECTED_ONCE=true
            ;;
        255)
            if [ "$CONNECTED_ONCE" = false ] && [ $ATTEMPT -ge 5 ]; then
                log_err "Falha persistente (código 255) - Possíveis causas:"
                echo -e "  ${YELLOW}1. Servidor Railway não está rodando (redeploy necessário)${NC}"
                echo -e "  ${YELLOW}2. Host/porta do TCP Proxy incorretos${NC}"
                echo -e "  ${YELLOW}3. Usuário/senha incorretos${NC}"
                echo -e "  ${YELLOW}4. Rede bloqueando a conexão SSH${NC}"
                echo ""
                echo -e "  ${CYAN}Verifique:${NC}"
                echo -e "  - Railway dashboard: serviço está 'Active'?"
                echo -e "  - TCP Proxy porta 1080 existe e está mapeado?"
                echo -e "  - Host: $RAILWAY_HOST | Porta: $RAILWAY_PORT"
                echo ""
            else
                log_err "Falha na conexão (código 255)"
            fi
            ;;
        *)
            log_err "Erro SSH (código: $EXIT_CODE)"
            ;;
    esac

    # Reset backoff se estava conectado
    if [ "$CONNECTED_ONCE" = true ] && [ $EXIT_CODE -eq 0 ]; then
        BACKOFF=2
    fi

    # Backoff exponencial (max 30s)
    log_info "Reconectando em ${BACKOFF}s..."
    sleep $BACKOFF
    BACKOFF=$((BACKOFF * 2))
    [ $BACKOFF -gt $MAX_BACKOFF ] && BACKOFF=$MAX_BACKOFF
done
