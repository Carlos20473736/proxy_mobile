#!/bin/bash
# ============================================
# Railway Proxy Mobile - Multiplexador v2.0
# ============================================
# ARQUITETURA:
#
# Porta 1080 (exposta pelo Railway TCP Proxy)
#   │
#   ├── Se é SSH (celular) → redireciona para porta 2222 (sshd)
#   └── Se é SOCKS5 (Fingerprint Manager) → redireciona para porta 9050
#
# O celular conecta via SSH e faz reverse tunnel:
#   porta 9050 do container ← localhost:8899 do celular (microsocks)
#
# O Fingerprint Manager conecta como SOCKS5:
#   <host>.proxy.rlwy.net:<porta> → porta 1080 → sslh → porta 9050 → celular
# ============================================

echo "╔══════════════════════════════════════════╗"
echo "║  Railway Proxy Mobile v2.0 (Otimizado)   ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Porta 1080: sslh (multiplexador)        ║"
echo "║  SSH → porta 2222 (celular conecta aqui) ║"
echo "║  SOCKS5 → porta 9050 (proxy do celular)  ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Aguardando celular conectar via SSH..."
echo ""

# Garantir diretório do sshd
mkdir -p /run/sshd

# ============================================
# === TUNING DE REDE ===
# ============================================
# (Best-effort: no Railway alguns sysctls podem ser read-only)

# Buffers TCP grandes (16MB) para maximizar throughput
sysctl -w net.core.rmem_max=16777216 2>/dev/null
sysctl -w net.core.wmem_max=16777216 2>/dev/null
sysctl -w net.core.rmem_default=1048576 2>/dev/null
sysctl -w net.core.wmem_default=1048576 2>/dev/null
sysctl -w net.ipv4.tcp_rmem='4096 1048576 16777216' 2>/dev/null
sysctl -w net.ipv4.tcp_wmem='4096 1048576 16777216' 2>/dev/null

# Backlog e filas maiores
sysctl -w net.core.somaxconn=4096 2>/dev/null
sysctl -w net.core.netdev_max_backlog=5000 2>/dev/null

# TCP Fast Open
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null

# BBR congestion control (melhor para redes móveis)
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null

# Não resetar janela TCP após idle
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null
sysctl -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null

# MTU probing (descobre MTU ideal automaticamente)
sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null

# Keepalive agressivo (detecta conexão morta em ~30s)
sysctl -w net.ipv4.tcp_keepalive_time=10 2>/dev/null
sysctl -w net.ipv4.tcp_keepalive_intvl=10 2>/dev/null
sysctl -w net.ipv4.tcp_keepalive_probes=3 2>/dev/null

# Reutilização de portas
sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null
sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null

echo "[OK] Tuning de rede aplicado"

# ============================================
# === INICIAR SERVIÇOS ===
# ============================================

# Iniciar SSH server em background
/usr/sbin/sshd -e
echo "[OK] SSH server iniciado na porta 2222"

# Iniciar sslh-select na porta 1080
# sslh-select: um único processo lida com TODAS as conexões via select()
# (sem fork por conexão = menos overhead para muitas conexões simultâneas)
# O timeout padrão do sslh 1.20 já é 2s (ideal)
echo "[OK] Iniciando sslh-select na porta 1080"
exec /usr/sbin/sslh-select -f \
    -p 0.0.0.0:1080 \
    --ssh 127.0.0.1:2222 \
    --socks5 127.0.0.1:9050 \
    --anyprot 127.0.0.1:9050
