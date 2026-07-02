#!/bin/bash
# ============================================
# Railway Proxy Mobile v3.1 - SSH Direto (Sem sslh)
# ============================================
# ARQUITETURA SIMPLIFICADA:
#
# Porta 1080 → SSH direto (celular conecta aqui)
#   O celular faz reverse tunnel: porta 9050 ← microsocks do celular
#
# Porta 9050 → SOCKS5 (Fingerprint Manager conecta aqui)
#   Tráfego vai pelo túnel SSH até o celular
#
# SEM sslh = menos latência (eliminamos 1 hop de processamento)
# ============================================

echo "╔══════════════════════════════════════════╗"
echo "║  Railway Proxy Mobile v3.1               ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Porta 1080: SSH direto (celular)         ║"
echo "║  Porta 9050: SOCKS5 (Fingerprint Mgr)    ║"
echo "║  Sem sslh = menos latência!              ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Garantir diretório do sshd
mkdir -p /run/sshd

# ============================================
# === TUNING DE REDE (máxima velocidade) ===
# ============================================
sysctl -w net.core.rmem_max=16777216 2>/dev/null
sysctl -w net.core.wmem_max=16777216 2>/dev/null
sysctl -w net.core.rmem_default=1048576 2>/dev/null
sysctl -w net.core.wmem_default=1048576 2>/dev/null
sysctl -w net.ipv4.tcp_rmem='4096 1048576 16777216' 2>/dev/null
sysctl -w net.ipv4.tcp_wmem='4096 1048576 16777216' 2>/dev/null
sysctl -w net.core.somaxconn=4096 2>/dev/null
sysctl -w net.core.netdev_max_backlog=5000 2>/dev/null
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
echo "Aguardando celular conectar via SSH..."
echo "  → Celular usa: porta 1080 (TCP Proxy antigo)"
echo "  → Fingerprint Manager usa: porta 9050 (TCP Proxy novo)"
echo ""

# Iniciar SSH server diretamente na porta 1080
# Sem sslh no meio = 1 hop a menos = menos latência
exec /usr/sbin/sshd -D -e
