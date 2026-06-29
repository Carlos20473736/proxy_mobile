FROM alpine:3.19

# Instalar OpenSSH server
RUN apk add --no-cache openssh-server bash

# Criar diretório SSH
RUN mkdir -p /run/sshd

# Configurar SSH para aceitar reverse port forwarding
RUN echo "PermitRootLogin yes" >> /etc/ssh/sshd_config && \
    echo "GatewayPorts yes" >> /etc/ssh/sshd_config && \
    echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config && \
    echo "ClientAliveInterval 15" >> /etc/ssh/sshd_config && \
    echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config && \
    echo "MaxSessions 100" >> /etc/ssh/sshd_config && \
    echo "TCPKeepAlive yes" >> /etc/ssh/sshd_config && \
    echo "PermitOpen any" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "PermitEmptyPasswords no" >> /etc/ssh/sshd_config && \
    echo "Port 2222" >> /etc/ssh/sshd_config

# Gerar host keys
RUN ssh-keygen -A

# Criar usuário para o túnel
RUN adduser -D -s /bin/bash tunnel && \
    echo "tunnel:proxypass123" | chpasswd

# Script de inicialização
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 2222
EXPOSE 1080

CMD ["/start.sh"]
