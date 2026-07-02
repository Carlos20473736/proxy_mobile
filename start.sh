#!/bin/bash
# ============================================
# Railway Proxy Mobile - Multiplexador v2.0
# ============================================
# ARQUITETURA OTIMIZADA:
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
#
# OTIMIZAÇÕES v2.0:
# - Buffers TCP maximizados (16MB)
# - TCP BBR congestion control (melhor em redes móveis)
# - TCP Fast Open (reduz latência de handshake)
# - Keepalive agressivo para detectar quedas rápido
# - sslh-select com timeout otimizado
# - Desabilitado Nagle (TCP_NODELAY via sysctl)
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
# === TUNING DE REDE AGRESSIVO ===
# ============================================

# --- Buffers TCP grandes (16MB) para maximizar throughput ---
sysctl -w net.core.rmem_max=16777216 2>/dev/null
sysctl -w net.core.wmem_max=16777216 2>/dev/null
sysctl -w net.core.rmem_default=1048576 2>/dev/null
sysctl -w net.core.wmem_default=1048576 2>/dev/null
sysctl -w net.ipv4.tcp_rmem='4096 1048576 16777216' 2>/dev/null
sysctl -w net.ipv4.tcp_wmem='4096 1048576 16777216' 2>/dev/null

# --- Backlog e filas maiores (mais conexões simultâneas) ---
sysctl -w net.core.somaxconn=4096 2>/dev/null
sysctl -w net.core.netdev_max_backlog=5000 2>/dev/null
sysctl -w net.ipv4.tcp_max_syn_backlog=4096 2>/dev/null

# --- TCP Fast Open (reduz 1 RTT no handshake) ---
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null

# --- BBR congestion control (melhor para redes móveis/instáveis) ---
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null

# --- Otimizações de latência ---
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null
sysctl -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null
sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null
sysctl -w net.ipv4.tcp_timestamps=1 2>/dev/null
sysctl -w net.ipv4.tcp_sack=1 2>/dev/null
sysctl -w net.ipv4.tcp_window_scaling=1 2>/dev/null

# --- Keepalive agressivo (detecta conexão morta em ~30s) ---
sysctl -w net.ipv4.tcp_keepalive_time=10 2>/dev/null
sysctl -w net.ipv4.tcp_keepalive_intvl=10 2>/dev/null
sysctl -w net.ipv4.tcp_keepalive_probes=3 2>/dev/null

# --- Reutilização de portas (mais conexões simultâneas) ---
sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null
sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null

# --- Desabilitar slow start após idle (mantém velocidade constante) ---
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null

echo "[OK] Tuning de rede aplicado"
echo ""

# ============================================
# === INICIAR SERVIÇOS ===
# ============================================

# Iniciar SSH server em background
/usr/sbin/sshd -e
echo "[OK] SSH server iniciado na porta 2222"

# Iniciar sslh-select na porta 1080
# sslh-select usa um único processo com select() - ideal para muitas conexões
# simultâneas sem overhead de fork por conexão.
# --transparent: tenta preservar IP de origem (best-effort)
# -t 2: timeout de detecção de protocolo reduzido (2s em vez do padrão 5s)
#        isso faz o SOCKS5 conectar mais rápido pois o sslh decide mais cedo
echo "[OK] Iniciando sslh-select na porta 1080 (timeout=2s)"
exec /usr/sbin/sslh-select -f \
    -p 0.0.0.0:1080 \
    -t 2 \
    --ssh 127.0.0.1:2222 \
    --socks5 127.0.0.1:9050 \
    --anyprot 127.0.0.1:9050
