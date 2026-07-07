#!/bin/bash
# ============================================
# Railway Proxy Mobile v3.2 - SSH Direto
# ============================================

echo "=== Proxy Mobile v3.2 ==="
echo "Porta 1080: SSH (celular conecta aqui)"
echo "Porta 9050: SOCKS5 (Fingerprint Manager)"
echo ""

# Garantir diretórios
mkdir -p /run/sshd /var/run/sshd

# Verificar host keys (regenerar se ausentes)
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    echo "[!] Gerando host keys..."
    ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -q
    ssh-keygen -t ecdsa -b 256 -f /etc/ssh/ssh_host_ecdsa_key -N "" -q
    ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q
    chmod 600 /etc/ssh/ssh_host_*_key
    chmod 644 /etc/ssh/ssh_host_*_key.pub
fi

# Verificar usuário tunnel
if ! id tunnel &>/dev/null; then
    useradd -m -s /bin/bash tunnel
    echo "tunnel:proxypass123" | chpasswd
fi

# Tuning de rede (ignorar erros - Railway pode não permitir)
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true
sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_time=10 2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_intvl=10 2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_probes=3 2>/dev/null || true

# Validar sshd_config
echo "[*] Validando sshd..."
/usr/sbin/sshd -t
if [ $? -ne 0 ]; then
    echo "[ERRO] Config inválida, usando config mínima..."
    cat > /etc/ssh/sshd_config <<'MINIMAL'
Port 1080
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin yes
PasswordAuthentication yes
GatewayPorts yes
AllowTcpForwarding yes
UsePAM no
UseDNS no
MINIMAL
    /usr/sbin/sshd -t || { echo "[FATAL] Impossível iniciar SSH"; exit 1; }
fi

echo "[OK] Iniciando sshd na porta 1080..."
echo ""

# Iniciar sshd em foreground com log
exec /usr/sbin/sshd -D -e -p 1080
