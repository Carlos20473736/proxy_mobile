FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Instalar apenas o necessário (sem sslh!)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        bash \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Criar diretório do sshd
RUN mkdir -p /run/sshd

# Configurar SSH otimizado para máxima velocidade
# Comentar Subsystem padrão e aplicar config customizada
RUN sed -i 's/^Subsystem/#Subsystem/' /etc/ssh/sshd_config && \
    echo "" >> /etc/ssh/sshd_config && \
    echo "# === PROXY MOBILE - SSH OTIMIZADO ===" >> /etc/ssh/sshd_config && \
    echo "Port 1080" >> /etc/ssh/sshd_config && \
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config && \
    echo "GatewayPorts yes" >> /etc/ssh/sshd_config && \
    echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config && \
    echo "ClientAliveInterval 10" >> /etc/ssh/sshd_config && \
    echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config && \
    echo "MaxSessions 100" >> /etc/ssh/sshd_config && \
    echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config && \
    echo "PermitOpen any" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config && \
    echo "Compression no" >> /etc/ssh/sshd_config && \
    echo "UseDNS no" >> /etc/ssh/sshd_config && \
    echo "IPQoS throughput" >> /etc/ssh/sshd_config && \
    echo "Ciphers aes128-gcm@openssh.com,chacha20-poly1305@openssh.com" >> /etc/ssh/sshd_config && \
    echo "MACs hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com" >> /etc/ssh/sshd_config && \
    echo "RekeyLimit 0 0" >> /etc/ssh/sshd_config

# Gerar host keys
RUN ssh-keygen -A

# Criar usuário para o túnel
RUN useradd -m -s /bin/bash tunnel && \
    echo "tunnel:proxypass123" | chpasswd

# Script de inicialização
COPY start.sh /start.sh
RUN chmod +x /start.sh

# SSH direto na porta 1080 (sem sslh no meio!)
EXPOSE 1080

CMD ["/start.sh"]
