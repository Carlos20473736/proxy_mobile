#!/data/data/com.termux/files/usr/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  5G-SHARE v9.2 - IPv6 DIRETO + DuckDNS + Troca de IP        ║
# ║  Velocidade 100% do 5G | Zero intermediário                  ║
# ║  Domínio fixo: carlos5g.duckdns.org                          ║
# ╚══════════════════════════════════════════════════════════════╝

DUCKDNS_DOMAIN="carlos5g"
DUCKDNS_TOKEN="846b54ef-f234-4a33-bed0-2fa89e55a0d8"
PROXY_PORT="8899"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  5G-SHARE v9.2 - IPv6 Direto + Troca de IP              ║"
echo "║  Velocidade 100% | Zero intermediário                    ║"
echo "║  Domínio: ${DUCKDNS_DOMAIN}.duckdns.org:${PROXY_PORT}             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# === VERIFICAR ROOT ===
HAS_ROOT=false
if su -c 'echo ok' &>/dev/null 2>&1; then
    HAS_ROOT=true
    echo -e "${GREEN}  [✓] Root detectado — troca de IP rápida disponível${NC}"
else
    echo -e "${YELLOW}  [!] Sem root — troca de IP via modo avião manual${NC}"
fi

# === INSTALAR DEPENDÊNCIAS ===
echo -e "${YELLOW}[1/4] Verificando dependências...${NC}"
if ! command -v microsocks &> /dev/null; then
    echo "  Instalando microsocks..."
    pkg install -y microsocks 2>/dev/null
fi
if ! command -v curl &> /dev/null; then
    pkg install -y curl 2>/dev/null
fi
echo -e "${GREEN}  [✓] Dependências OK${NC}"

# === DETECTAR IPv6 ===
echo -e "${YELLOW}[2/4] Detectando IPv6 do 5G...${NC}"

get_ipv6() {
    curl -s6 --max-time 5 ifconfig.me 2>/dev/null || curl -s6 --max-time 5 api6.ipify.org 2>/dev/null || curl -s6 --max-time 5 icanhazip.com 2>/dev/null
}

get_ipv4() {
    curl -s4 --max-time 5 ifconfig.me 2>/dev/null || curl -s4 --max-time 5 api4.ipify.org 2>/dev/null || curl -s4 --max-time 5 icanhazip.com 2>/dev/null
}

IPV6=$(get_ipv6)
IPV4=$(get_ipv4)

if [ -z "$IPV6" ] && [ -z "$IPV4" ]; then
    echo -e "${RED}  [✗] Nenhum IP encontrado!${NC}"
    echo "  Verifique se o 5G está ativo e tente novamente."
    exit 1
fi

[ -n "$IPV6" ] && echo -e "${GREEN}  [✓] IPv6: ${IPV6}${NC}"
[ -n "$IPV4" ] && echo -e "${GREEN}  [✓] IPv4: ${IPV4}${NC}"

# === ATUALIZAR DUCKDNS ===
echo -e "${YELLOW}[3/4] Atualizando DuckDNS...${NC}"

update_duckdns() {
    local ip="$1"
    local result=$(curl -s "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ipv6=${ip}")
    if [ "$result" = "OK" ]; then
        return 0
    else
        return 1
    fi
}

if [ -n "$IPV6" ]; then
    if update_duckdns "$IPV6"; then
        echo -e "${GREEN}  [✓] DuckDNS atualizado: ${DUCKDNS_DOMAIN}.duckdns.org → ${IPV6}${NC}"
    else
        echo -e "${RED}  [✗] Erro ao atualizar DuckDNS${NC}"
    fi
fi

# === INICIAR PROXY ===
echo -e "${YELLOW}[4/4] Iniciando proxy SOCKS5...${NC}"

pkill -f microsocks 2>/dev/null
sleep 1

microsocks -i :: -p $PROXY_PORT &
PROXY_PID=$!
sleep 1

if kill -0 $PROXY_PID 2>/dev/null; then
    echo -e "${GREEN}  [✓] Proxy SOCKS5 ativo na porta ${PROXY_PORT}${NC}"
else
    echo -e "${RED}  [✗] Falha ao iniciar proxy${NC}"
    exit 1
fi

# === WAKE LOCK ===
termux-wake-lock 2>/dev/null

# === FUNÇÃO TROCAR IP ===
trocar_ip() {
    echo ""
    echo -e "${YELLOW}[!] Trocando IP...${NC}"
    
    if [ "$HAS_ROOT" = true ]; then
        # Com root: desliga/liga dados (3 segundos)
        su -c "svc data disable"
        sleep 2
        su -c "svc data enable"
        sleep 3
        echo -e "${GREEN}  [✓] Dados religados${NC}"
    else
        echo -e "${YELLOW}  → Ative o MODO AVIÃO por 3 segundos e desative${NC}"
        echo -e "${YELLOW}  → Pressione ENTER quando terminar...${NC}"
        read -r
    fi
    
    # Pegar novo IP
    local NEW_IPV6=$(get_ipv6)
    local NEW_IPV4=$(get_ipv4)
    
    if [ -n "$NEW_IPV6" ]; then
        echo -e "${GREEN}  [✓] Novo IPv6: ${NEW_IPV6}${NC}"
        update_duckdns "$NEW_IPV6"
        CURRENT_IPV6="$NEW_IPV6"
    fi
    if [ -n "$NEW_IPV4" ]; then
        echo -e "${GREEN}  [✓] Novo IPv4: ${NEW_IPV4}${NC}"
        CURRENT_IPV4="$NEW_IPV4"
    fi
    
    # Reiniciar microsocks
    pkill -f microsocks 2>/dev/null
    sleep 1
    microsocks -i :: -p $PROXY_PORT &
    PROXY_PID=$!
    echo -e "${GREEN}  [✓] Proxy reiniciado com novo IP${NC}"
}

# === INFORMAÇÕES PARA O PC ===
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SERVIDOR ATIVO! Configure no PC:${NC}"
echo ""
echo -e "  Protocolo: ${CYAN}SOCKS5${NC}"
echo -e "  Host:      ${CYAN}${DUCKDNS_DOMAIN}.duckdns.org${NC}"
echo -e "  Porta:     ${CYAN}${PROXY_PORT}${NC}"
echo -e "  Usuário:   ${CYAN}(vazio)${NC}"
echo -e "  Senha:     ${CYAN}(vazio)${NC}"
echo ""
echo -e "  IPv4: ${GREEN}${IPV4:-N/A}${NC}"
echo -e "  IPv6: ${GREEN}${IPV6:-N/A}${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Comandos:${NC}"
echo -e "    ${CYAN}t${NC} = Trocar IP agora"
echo -e "    ${CYAN}s${NC} = Ver status"
echo -e "    ${CYAN}q${NC} = Sair"
echo ""

# === MONITOR + COMANDOS ===
CURRENT_IPV6="$IPV6"
CURRENT_IPV4="$IPV4"
LAST_UPDATE=$(date +%s)

cleanup() {
    echo ""
    echo -e "${YELLOW}Encerrando...${NC}"
    pkill -f microsocks 2>/dev/null
    termux-wake-unlock 2>/dev/null
    exit 0
}
trap cleanup INT TERM

while true; do
    # Ler input do usuário com timeout de 30s
    read -t 30 -n 1 CMD
    
    case "$CMD" in
        t|T)
            trocar_ip
            ;;
        s|S)
            echo ""
            echo -e "${CYAN}═══ STATUS ═══${NC}"
            NOW=$(date +%s)
            UPTIME=$(( (NOW - LAST_UPDATE) / 60 ))
            echo -e "  Uptime: ${GREEN}${UPTIME} min${NC}"
            echo -e "  IPv4:   ${GREEN}${CURRENT_IPV4:-N/A}${NC}"
            echo -e "  IPv6:   ${GREEN}${CURRENT_IPV6:-N/A}${NC}"
            echo -e "  Proxy:  $(kill -0 $PROXY_PID 2>/dev/null && echo -e "${GREEN}ATIVO${NC}" || echo -e "${RED}PARADO${NC}")"
            echo -e "${CYAN}══════════════${NC}"
            ;;
        q|Q)
            cleanup
            ;;
        *)
            # Verificar se microsocks ainda está rodando
            if ! kill -0 $PROXY_PID 2>/dev/null; then
                echo -e "\n${YELLOW}[!] Proxy caiu, reiniciando...${NC}"
                microsocks -i :: -p $PROXY_PORT &
                PROXY_PID=$!
            fi
            
            # Verificar se o IP mudou
            NEW_IP=$(get_ipv6)
            if [ -n "$NEW_IP" ] && [ "$NEW_IP" != "$CURRENT_IPV6" ]; then
                echo -e "\n${YELLOW}[!] IPv6 mudou: ${NEW_IP}${NC}"
                CURRENT_IPV6="$NEW_IP"
                update_duckdns "$NEW_IP"
            fi
            
            NOW=$(date +%s)
            UPTIME=$(( (NOW - LAST_UPDATE) / 60 ))
            printf "\r${GREEN}[✓]${NC} Online ${UPTIME}min | IPv4: ${CURRENT_IPV4:-N/A} | [t]rocar [s]tatus [q]sair    "
            ;;
    esac
done
