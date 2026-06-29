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
#   nozomi.proxy.rlwy.net:33719 → porta 1080 → sslh → porta 9050 → celular
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

# Iniciar SSH server em background
/usr/sbin/sshd -e

# Iniciar sslh na porta 1080
# - Detecta SSH (bytes iniciais SSH-) → redireciona para 127.0.0.1:2222
# - Qualquer outro protocolo (SOCKS5) → redireciona para 127.0.0.1:9050
exec sslh -f \
    --listen 0.0.0.0:1080 \
    --ssh 127.0.0.1:2222 \
    --anyprot 127.0.0.1:9050
