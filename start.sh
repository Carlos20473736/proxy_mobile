#!/bin/bash
# ============================================
# Railway Proxy Mobile v3.0 - CHISEL
# ============================================
# ARQUITETURA:
#
# Porta 1080 (exposta pelo Railway TCP Proxy)
#   │
#   └── chisel server (HTTP2/WebSocket tunnel)
#         │
#         └── Celular conecta como chisel client
#             com R:socks (reverse SOCKS5)
#
# O celular roda chisel client com "R:socks":
#   - O servidor escuta conexões SOCKS5 na porta 1080
#   - As conexões são tuneladas via HTTP2 até o celular
#   - O celular resolve e faz as requisições usando seu IP 4G/5G
#
# VANTAGENS vs SSH:
# - HTTP2 multiplexing (múltiplos streams em 1 conexão TCP)
# - Sem overhead de criptografia pesada do SSH
# - Reconexão automática com backoff exponencial
# - Passa por proxies/firewalls corporativos
# - Muito mais rápido em redes de alta latência
# ============================================

echo "╔══════════════════════════════════════════╗"
echo "║  Railway Proxy Mobile v3.0 (CHISEL)      ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Porta 1080: chisel server               ║"
echo "║  Celular: chisel client R:socks           ║"
echo "║  Protocolo: HTTP2 + WebSocket             ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ============================================
# === TUNING DE REDE ===
# ============================================
sysctl -w net.core.rmem_max=16777216 2>/dev/null
sysctl -w net.core.wmem_max=16777216 2>/dev/null
sysctl -w net.core.rmem_default=1048576 2>/dev/null
sysctl -w net.core.wmem_default=1048576 2>/dev/null
sysctl -w net.ipv4.tcp_rmem='4096 1048576 16777216' 2>/dev/null
sysctl -w net.ipv4.tcp_wmem='4096 1048576 16777216' 2>/dev/null
sysctl -w net.core.somaxconn=4096 2>/dev/null
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null
sysctl -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null
sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null
sysctl -w net.ipv4.tcp_keepalive_time=10 2>/dev/null
sysctl -w net.ipv4.tcp_keepalive_intvl=10 2>/dev/null
sysctl -w net.ipv4.tcp_keepalive_probes=3 2>/dev/null
sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null
sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null
echo "[OK] Tuning de rede aplicado"
echo ""

# ============================================
# === INICIAR CHISEL SERVER ===
# ============================================
# --reverse: permite que o client faça reverse port forwarding (R:socks)
# --port 1080: escuta na porta que o Railway expõe
# --keepalive 10s: keepalive agressivo para detectar quedas
# --auth: autenticação simples para segurança
echo "[OK] Iniciando chisel server na porta 1080..."
echo ""
echo "Aguardando celular conectar..."
echo ""

exec /usr/local/bin/chisel server \
    --port 1080 \
    --reverse \
    --keepalive 10s \
    --auth tunnel:proxypass123
