FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Instalar openssh-server
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        procps && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/sshd /var/run/sshd

# Escrever sshd_config do ZERO (ignora qualquer config padrão)
RUN echo 'Port 1080' > /etc/ssh/sshd_config && \
    echo 'AddressFamily any' >> /etc/ssh/sshd_config && \
    echo 'ListenAddress 0.0.0.0' >> /etc/ssh/sshd_config && \
    echo 'Protocol 2' >> /etc/ssh/sshd_config && \
    echo 'HostKey /etc/ssh/ssh_host_rsa_key' >> /etc/ssh/sshd_config && \
    echo 'HostKey /etc/ssh/ssh_host_ecdsa_key' >> /etc/ssh/sshd_config && \
    echo 'HostKey /etc/ssh/ssh_host_ed25519_key' >> /etc/ssh/sshd_config && \
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config && \
    echo 'PermitEmptyPasswords no' >> /etc/ssh/sshd_config && \
    echo 'ChallengeResponseAuthentication no' >> /etc/ssh/sshd_config && \
    echo 'UsePAM no' >> /etc/ssh/sshd_config && \
    echo 'GatewayPorts yes' >> /etc/ssh/sshd_config && \
    echo 'AllowTcpForwarding yes' >> /etc/ssh/sshd_config && \
    echo 'PermitOpen any' >> /etc/ssh/sshd_config && \
    echo 'PermitTunnel yes' >> /etc/ssh/sshd_config && \
    echo 'MaxSessions 100' >> /etc/ssh/sshd_config && \
    echo 'ClientAliveInterval 15' >> /etc/ssh/sshd_config && \
    echo 'ClientAliveCountMax 3' >> /etc/ssh/sshd_config && \
    echo 'TCPKeepAlive yes' >> /etc/ssh/sshd_config && \
    echo 'Compression no' >> /etc/ssh/sshd_config && \
    echo 'UseDNS no' >> /etc/ssh/sshd_config && \
    echo 'PrintMotd no' >> /etc/ssh/sshd_config && \
    echo 'AcceptEnv LANG LC_*' >> /etc/ssh/sshd_config && \
    echo 'MaxStartups 10:30:100' >> /etc/ssh/sshd_config

# Gerar host keys (remover existentes primeiro)
RUN rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub && \
    ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -q && \
    ssh-keygen -t ecdsa -b 256 -f /etc/ssh/ssh_host_ecdsa_key -N "" -q && \
    ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q && \
    chmod 600 /etc/ssh/ssh_host_*_key && \
    chmod 644 /etc/ssh/ssh_host_*_key.pub

# Criar usuário tunnel
RUN useradd -m -s /bin/bash tunnel && \
    echo "tunnel:proxypass123" | chpasswd

# Validar config
RUN /usr/sbin/sshd -t && echo "SSHD CONFIG OK"

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080

CMD ["/start.sh"]
