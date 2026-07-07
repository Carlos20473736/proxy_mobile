#!/bin/bash
# =============================================
# PROXY MOBILE v4.1 - Servidor Railway
# =============================================
# sslh na porta 7777 (TCP Proxy do Railway)
#   → SSH detectado → encaminha para sshd:2222
#   → Qualquer outra coisa (SOCKS5) → encaminha para 127.0.0.1:8899
#     (porta 8899 = reverse tunnel criado pelo celular)
# =============================================

echo "=== Proxy Mobile v4.1 ==="

mkdir -p /run/sshd

# Regenerar keys se necessário
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q
[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -q
[ -f /etc/ssh/ssh_host_ecdsa_key ] || ssh-keygen -t ecdsa -b 256 -f /etc/ssh/ssh_host_ecdsa_key -N "" -q

# Verificar usuário
id tunnel &>/dev/null || { useradd -m -s /bin/bash tunnel && echo "tunnel:proxypass123" | chpasswd; }

# Iniciar sshd
echo "[1/2] Iniciando sshd na porta 2222..."
/usr/sbin/sshd -D -e -p 2222 &
SSHD_PID=$!
sleep 1
if kill -0 $SSHD_PID 2>/dev/null; then
    echo "  ✓ sshd OK"
else
    echo "  ✗ sshd FALHOU"
    exit 1
fi

# Iniciar sslh
echo "[2/2] Iniciando sslh na porta 7777..."
echo "  SSH   → 127.0.0.1:2222"
echo "  SOCKS → 127.0.0.1:8899 (reverse tunnel)"
echo ""
echo "=== PRONTO ==="

exec sslh --foreground \
    --listen 0.0.0.0:7777 \
    --ssh 127.0.0.1:2222 \
    --anyprot 127.0.0.1:8899 \
    --timeout 2
