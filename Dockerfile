FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Instalar apenas o mínimo necessário
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        bash && \
    rm -rf /var/lib/apt/lists/*

# Baixar chisel (túnel TCP sobre HTTP2 - muito mais rápido que SSH)
ENV CHISEL_VERSION=1.11.7
RUN curl -fsSL "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_linux_amd64.gz" \
    | gunzip > /usr/local/bin/chisel && \
    chmod +x /usr/local/bin/chisel

# Script de inicialização
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 1080

CMD ["/start.sh"]
