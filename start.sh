#!/bin/bash
echo "=== Proxy Mobile v4.0 ==="
echo "Porta 7777: sslh (SSH + SOCKS5 multiplexado)"
echo ""

mkdir -p /run/sshd

# Regenerar keys se necessário
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q
[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -q
[ -f /etc/ssh/ssh_host_ecdsa_key ] || ssh-keygen -t ecdsa -b 256 -f /etc/ssh/ssh_host_ecdsa_key -N "" -q

# Verificar usuário
id tunnel &>/dev/null || { useradd -m -s /bin/bash tunnel && echo "tunnel:proxypass123" | chpasswd; }

# 1) Iniciar sshd na porta 2222
echo "[1/3] Iniciando sshd na porta 2222..."
/usr/sbin/sshd -D -e -p 2222 &
SSHD_PID=$!
sleep 1
if kill -0 $SSHD_PID 2>/dev/null; then
    echo "  [OK] sshd rodando (PID $SSHD_PID)"
else
    echo "  [ERRO] sshd falhou"
    exit 1
fi

# 2) Iniciar microsocks na porta 1080 (SOCKS5 interno)
echo "[2/3] Iniciando microsocks na porta 1080..."
microsocks -i 127.0.0.1 -p 1080 &
MICRO_PID=$!
sleep 1
if kill -0 $MICRO_PID 2>/dev/null; then
    echo "  [OK] microsocks rodando (PID $MICRO_PID)"
else
    echo "  [ERRO] microsocks falhou"
    exit 1
fi

# 3) Iniciar sslh na porta 7777 - multiplexador
# SSH começa com "SSH-", SOCKS5 começa com 0x05
# sslh detecta automaticamente e encaminha
echo "[3/3] Iniciando sslh na porta 7777..."
echo "  SSH    → 127.0.0.1:2222"
echo "  SOCKS5 → 127.0.0.1:1080"
echo ""
echo "=== PRONTO! Servidor ativo na porta 7777 ==="

exec sslh --foreground \
    --listen 0.0.0.0:7777 \
    --ssh 127.0.0.1:2222 \
    --anyprot 127.0.0.1:1080 \
    --timeout 5
