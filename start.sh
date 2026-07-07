#!/bin/bash
# ============================================
# Railway Proxy Mobile v3.2 - SSH Direto
# ============================================
# ARQUITETURA:
#
# Porta 1080 → SSH direto (celular conecta aqui)
#   O celular faz reverse tunnel: porta 9050 ← microsocks do celular
#
# Porta 9050 → SOCKS5 (Fingerprint Manager conecta aqui)
#   Tráfego vai pelo túnel SSH até o celular
# ============================================

echo "╔══════════════════════════════════════════╗"
echo "║  Railway Proxy Mobile v3.2               ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Porta 1080: SSH direto (celular)         ║"
echo "║  Porta 9050: SOCKS5 (Fingerprint Mgr)    ║"
echo "║  Sem sslh = menos latência!              ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# === Garantir diretórios necessários ===
mkdir -p /run/sshd /var/run/sshd

# === Regenerar host keys se necessário ===
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    echo "[!] Regenerando host keys..."
    ssh-keygen -A
fi

# Garantir permissões corretas nas host keys
chmod 600 /etc/ssh/ssh_host_*_key 2>/dev/null
chmod 644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null

# === Verificar que o usuário tunnel existe ===
if ! id tunnel &>/dev/null; then
    echo "[!] Criando usuário tunnel..."
    useradd -m -s /bin/bash tunnel
    echo "tunnel:proxypass123" | chpasswd
fi

# ============================================
# === TUNING DE REDE (máxima velocidade) ===
# ============================================
echo "[*] Aplicando tuning de rede..."
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

# === Validar configuração SSH antes de iniciar ===
echo "[*] Validando configuração SSH..."
/usr/sbin/sshd -t
if [ $? -ne 0 ]; then
    echo "[ERRO] Configuração SSH inválida! Tentando config mínima..."
    cat > /etc/ssh/sshd_config <<'EOF'
Port 1080
PermitRootLogin yes
PasswordAuthentication yes
GatewayPorts yes
AllowTcpForwarding yes
PermitOpen any
MaxSessions 100
ClientAliveInterval 15
ClientAliveCountMax 3
TCPKeepAlive yes
Compression no
UseDNS no
PrintMotd no
EOF
    /usr/sbin/sshd -t || { echo "[FATAL] SSH não consegue iniciar!"; exit 1; }
fi
echo "[OK] Configuração SSH válida"
echo ""

echo "════════════════════════════════════════════"
echo " SSH escutando na porta 1080"
echo " Aguardando celular conectar..."
echo "════════════════════════════════════════════"
echo ""
echo " → Celular conecta via TCP Proxy na porta 1080"
echo " → Fingerprint Manager usa TCP Proxy na porta 9050"
echo ""

# Iniciar SSH server diretamente na porta 1080
# -D = daemon mode (foreground para Railway)
# -e = log para stderr (Railway captura)
exec /usr/sbin/sshd -D -e
