#!/bin/bash
# ============================================
# Railway Proxy Mobile - Multiplexador
# ============================================
# ARQUITETURA:
#
# Porta 1080 (exposta pelo Railway TCP Proxy)
#   │
#   ├── Se é SSH (celular) → redireciona para porta 2222 (sshd)
#   └── Se é SOCKS5 (Fingerprint Manager) → redireciona para porta 9050
#
# O celular conecta via SSH e faz reverse tunnel:
#   porta 9050 do container ← localhost:8899 do celular (microsocks)
#
# O Fingerprint Manager conecta como SOCKS5:
#   <host>.proxy.rlwy.net:<porta> → porta 1080 → sslh → porta 9050 → celular
# ============================================

echo "╔══════════════════════════════════════════╗"
echo "║  Railway Proxy Mobile - Multiplexador    ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Porta 1080: sslh (multiplexador)        ║"
echo "║  SSH → porta 2222 (celular conecta aqui) ║"
echo "║  SOCKS5 → porta 9050 (proxy do celular)  ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Aguardando celular conectar via SSH..."
echo ""

# Garantir diretório do sshd
mkdir -p /run/sshd

# Iniciar SSH server em background
/usr/sbin/sshd -e

# Iniciar sslh na porta 1080
# IMPORTANTE: a versão do sslh no Debian usa "-p <addr>" para a porta de escuta
# (NÃO existe a opção "--listen" nesta versão).
# - Detecta SSH (bytes iniciais "SSH-") → redireciona para 127.0.0.1:2222
# - Detecta SOCKS5                       → redireciona para 127.0.0.1:9050
# - Qualquer outro protocolo (--anyprot) → redireciona para 127.0.0.1:9050
exec sslh -f \
    -p 0.0.0.0:1080 \
    --ssh 127.0.0.1:2222 \
    --socks5 127.0.0.1:9050 \
    --anyprot 127.0.0.1:9050
