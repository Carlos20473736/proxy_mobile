#!/bin/bash
# ============================================
# Railway Proxy Mobile v3.0 - CHISEL
# ============================================
# ARQUITETURA:
#
# O Railway expõe DUAS portas públicas:
#   - Porta 1080 → chisel server (celular conecta aqui via WebSocket)
#   - Porta 9050 → SOCKS5 reverso (Fingerprint Manager conecta aqui)
#
# O celular roda chisel client com "R:0.0.0.0:9050:socks":
#   - O servidor abre porta 9050 como SOCKS5
#   - Conexões SOCKS5 são tuneladas via HTTP2 até o celular
#   - O celular resolve DNS e navega usando seu IP 5G/4G
#
# VANTAGENS vs SSH:
# - HTTP2 multiplexing (múltiplos streams paralelos)
# - Menos overhead de criptografia
# - Reconexão automática com backoff
# - Muito mais rápido
# ============================================

echo "╔══════════════════════════════════════════╗"
echo "║  Railway Proxy Mobile v3.0 (CHISEL)      ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Porta 1080: chisel server (tunnel)       ║"
echo "║  Porta 9050: SOCKS5 reverso (proxy)       ║"
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
# --reverse: permite R:socks (reverse SOCKS5)
# --port 1080: escuta WebSocket na porta 1080 (celular conecta aqui)
# --keepalive 10s: detecta quedas rápido
# --auth: autenticação
#
# O client vai fazer R:0.0.0.0:9050:socks
# Isso abre a porta 9050 no container como SOCKS5
# O Railway precisa de um TCP Proxy apontando para a porta 9050
echo "[OK] Iniciando chisel server na porta 1080..."
echo ""
echo "IMPORTANTE: Certifique-se de ter 2 TCP Proxies no Railway:"
echo "  1. Porta 1080 → para o celular conectar (chisel tunnel)"
echo "  2. Porta 9050 → para o Fingerprint Manager (SOCKS5)"
echo ""
echo "Aguardando celular conectar..."
echo ""

exec /usr/local/bin/chisel server \
    --port 1080 \
    --reverse \
    --keepalive 10s \
    --auth tunnel:proxypass123
