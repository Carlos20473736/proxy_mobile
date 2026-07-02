FROM debian:bookworm-slim

# Evitar prompts interativos durante o build
ENV DEBIAN_FRONTEND=noninteractive

# Instalar dependências em uma única camada otimizada
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        sslh \
        bash \
        ca-certificates \
        gcc \
        libc6-dev \
        git \
        make && \
    rm -rf /var/lib/apt/lists/*

# Compilar microsocks (proxy SOCKS5 ultra-leve)
RUN git clone https://github.com/rofl0r/microsocks.git /tmp/microsocks && \
    cd /tmp/microsocks && make && cp microsocks /usr/local/bin/ && \
    rm -rf /tmp/microsocks && \
    apt-get purge -y gcc libc6-dev git make && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Criar diretório necessário para o sshd
RUN mkdir -p /run/sshd

# Configurar SSH otimizado para máxima velocidade de túnel
# Primeiro, comentar o Subsystem sftp padrão (não precisamos)
RUN sed -i 's/^Subsystem/#Subsystem/' /etc/ssh/sshd_config && \
    echo "" >> /etc/ssh/sshd_config && \
    echo "# === PROXY MOBILE CONFIG ===" >> /etc/ssh/sshd_config && \
    echo "Port 2222" >> /etc/ssh/sshd_config && \
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

EXPOSE 1080

CMD ["/start.sh"]
