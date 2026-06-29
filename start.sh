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

# === TUNING DE REDE (velocidade maxima) ===
# Aumenta os buffers TCP e habilita otimizacoes do kernel para mais vazao.
# (Roda em best-effort; no Railway alguns sysctls podem ser ignorados.)
sysctl -w net.core.rmem_max=16777216 2>/dev/null
sysctl -w net.core.wmem_max=16777216 2>/dev/null
sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216' 2>/dev/null
sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216' 2>/dev/null
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null

# Iniciar SSH server em background
/usr/sbin/sshd -e

# Iniciar sslh na porta 1080
# IMPORTANTE: a versão do sslh no Debian usa "-p <addr>" para a porta de escuta
# (NÃO existe a opção "--listen" nesta versão).
# - Detecta SSH (bytes iniciais "SSH-") → redireciona para 127.0.0.1:2222
# - Detecta SOCKS5                       → redireciona para 127.0.0.1:9050
# - Qualquer outro protocolo (--anyprot) → redireciona para 127.0.0.1:9050
# Usamos sslh-select: um unico processo lida com TODAS as conexoes via select(),
# em vez de criar um processo novo por conexao (sslh fork). Para navegacao web
# com muitas requisicoes paralelas isso reduz o uso de CPU/memoria e melhora a
# vazao agregada.
exec /usr/sbin/sslh-select -f \
    -p 0.0.0.0:1080 \
    --ssh 127.0.0.1:2222 \
    --socks5 127.0.0.1:9050 \
    --anyprot 127.0.0.1:9050
