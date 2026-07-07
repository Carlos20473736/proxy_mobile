#!/bin/bash
echo "=== Proxy Mobile v4.0 ==="
echo "Porta 7777: sslh (SSH + SOCKS5 via tunnel)"
echo ""

mkdir -p /run/sshd

# Regenerar keys se necessário
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q
[ -f /etc/ssh/ssh_host_rsa_key ] || ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -q
[ -f /etc/ssh/ssh_host_ecdsa_key ] || ssh-keygen -t ecdsa -b 256 -f /etc/ssh/ssh_host_ecdsa_key -N "" -q

# Verificar usuário
id tunnel &>/dev/null || { useradd -m -s /bin/bash tunnel && echo "tunnel:proxypass123" | chpasswd; }

# 1) Iniciar sshd na porta 2222
echo "[1/2] Iniciando sshd na porta 2222..."
/usr/sbin/sshd -D -e -p 2222 &
SSHD_PID=$!
sleep 1
if kill -0 $SSHD_PID 2>/dev/null; then
    echo "  [OK] sshd rodando (PID $SSHD_PID)"
else
    echo "  [ERRO] sshd falhou"
    exit 1
fi

# 2) Iniciar sslh na porta 7777
# SSH → sshd:2222
# Qualquer outra coisa (SOCKS5) → porta 8800 (reverse tunnel do celular)
echo "[2/2] Iniciando sslh na porta 7777..."
echo "  SSH    → 127.0.0.1:2222"
echo "  SOCKS5 → 127.0.0.1:8800 (reverse tunnel)"
echo ""
echo "=== PRONTO! Aguardando conexão do celular ==="
echo "  Quando celular conectar, SOCKS5 ficará disponível."

exec sslh --foreground \
    --listen 0.0.0.0:7777 \
    --ssh 127.0.0.1:2222 \
    --anyprot 127.0.0.1:8800 \
    --timeout 5
