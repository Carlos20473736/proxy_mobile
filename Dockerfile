FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Instalar dependências
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        bash \
        procps \
        net-tools \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Criar diretórios do sshd
RUN mkdir -p /run/sshd /var/run/sshd

# Configurar SSH otimizado para máxima velocidade
RUN cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak && \
    cat > /etc/ssh/sshd_config <<'EOF'
# === PROXY MOBILE v3.2 - SSH OTIMIZADO ===
Port 1080
Protocol 2

# Autenticação
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Túnel e forwarding
GatewayPorts yes
AllowTcpForwarding yes
PermitOpen any
PermitTunnel yes
MaxSessions 100

# Keep-alive (detectar desconexões rápido)
ClientAliveInterval 15
ClientAliveCountMax 3
TCPKeepAlive yes

# Performance
Compression no
UseDNS no
IPQoS throughput

# Ciphers leves (hardware-accelerated)
Ciphers aes128-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256

# Sem renegociação
RekeyLimit 0 0

# Logging
LogLevel INFO

# Banner
PrintMotd no
PrintLastLog no
EOF

# Gerar host keys (RSA, ECDSA, ED25519)
RUN ssh-keygen -A && \
    chmod 600 /etc/ssh/ssh_host_*_key && \
    chmod 644 /etc/ssh/ssh_host_*_key.pub

# Criar usuário para o túnel com shell bash
RUN useradd -m -s /bin/bash tunnel && \
    echo "tunnel:proxypass123" | chpasswd && \
    mkdir -p /home/tunnel/.ssh && \
    chown -R tunnel:tunnel /home/tunnel

# Script de inicialização
COPY start.sh /start.sh
RUN chmod +x /start.sh

# SSH direto na porta 1080
EXPOSE 1080

# Healthcheck para Railway saber que o container está vivo
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD netstat -tlnp | grep -q ':1080' || exit 1

CMD ["/start.sh"]
