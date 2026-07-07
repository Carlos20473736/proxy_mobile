#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  5G-SHARE v9.0 - IPv6 DIRETO + DuckDNS                     ║
# ║  Velocidade 100% do 5G | Zero intermediário                 ║
# ║  Domínio fixo: carlos5g.duckdns.org                         ║
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
echo "║  5G-SHARE v9.0 - IPv6 Direto                           ║"
echo "║  Velocidade 100% | Zero intermediário                   ║"
echo "║  Domínio: ${DUCKDNS_DOMAIN}.duckdns.org:${PROXY_PORT}             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

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
    # Pegar IPv6 público via internet (Termux sem root não mostra IPv6 local)
    curl -s6 --max-time 5 ifconfig.me 2>/dev/null || curl -s6 --max-time 5 api6.ipify.org 2>/dev/null || curl -s6 --max-time 5 icanhazip.com 2>/dev/null
}

IPV6=$(get_ipv6)

if [ -z "$IPV6" ]; then
    echo -e "${RED}  [✗] Nenhum IPv6 encontrado!${NC}"
    echo "  Verifique se o 5G está ativo e tente novamente."
    exit 1
fi

echo -e "${GREEN}  [✓] IPv6: ${IPV6}${NC}"

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

if update_duckdns "$IPV6"; then
    echo -e "${GREEN}  [✓] DuckDNS atualizado: ${DUCKDNS_DOMAIN}.duckdns.org → ${IPV6}${NC}"
else
    echo -e "${RED}  [✗] Erro ao atualizar DuckDNS${NC}"
    echo "  Continuando com IP direto..."
fi

# === INICIAR PROXY ===
echo -e "${YELLOW}[4/4] Iniciando proxy SOCKS5...${NC}"

# Matar microsocks anterior se existir
pkill -f microsocks 2>/dev/null
sleep 1

# Iniciar microsocks escutando em todas interfaces IPv6
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
echo -e "  Ou direto: ${CYAN}${IPV6}${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Monitorando IPv6... (Ctrl+C para parar)${NC}"
echo ""

# === MONITOR DE IP ===
# Verifica a cada 30s se o IPv6 mudou e atualiza o DuckDNS
CURRENT_IP="$IPV6"
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
    sleep 30
    
    # Verificar se microsocks ainda está rodando
    if ! kill -0 $PROXY_PID 2>/dev/null; then
        echo -e "${YELLOW}[!] Proxy caiu, reiniciando...${NC}"
        microsocks -i :: -p $PROXY_PORT &
        PROXY_PID=$!
        sleep 1
    fi
    
    # Verificar se o IPv6 mudou
    NEW_IP=$(get_ipv6)
    
    if [ -z "$NEW_IP" ]; then
        echo -e "\r${RED}[!] IPv6 perdido - aguardando reconexão...${NC}    "
        continue
    fi
    
    if [ "$NEW_IP" != "$CURRENT_IP" ]; then
        echo ""
        echo -e "${YELLOW}[!] IPv6 mudou!${NC}"
        echo -e "  Antigo: ${RED}${CURRENT_IP}${NC}"
        echo -e "  Novo:   ${GREEN}${NEW_IP}${NC}"
        
        CURRENT_IP="$NEW_IP"
        
        # Atualizar DuckDNS
        if update_duckdns "$NEW_IP"; then
            echo -e "${GREEN}  [✓] DuckDNS atualizado!${NC}"
        else
            echo -e "${RED}  [✗] Erro ao atualizar DuckDNS${NC}"
        fi
        
        # Reiniciar microsocks com novo IP
        pkill -f microsocks 2>/dev/null
        sleep 1
        microsocks -i :: -p $PROXY_PORT &
        PROXY_PID=$!
        
        echo -e "${GREEN}  [✓] Proxy reiniciado no novo IP${NC}"
        echo ""
    fi
    
    # Status
    NOW=$(date +%s)
    UPTIME=$(( (NOW - LAST_UPDATE) / 60 ))
    printf "\r${GREEN}[✓]${NC} Online há ${UPTIME}min | IP: ${CURRENT_IP:0:20}... | Porta: ${PROXY_PORT}    "
done
