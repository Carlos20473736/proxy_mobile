#!/bin/bash
# ============================================
# Railway Proxy Mobile - Servidor SSH
# ============================================
# Este container roda um servidor SSH que aceita
# reverse tunnels do celular (Termux).
# O celular conecta via SSH e expõe a porta do
# microsocks (SOCKS5) na porta 1080 do container.
# O Railway expõe a porta 1080 via TCP Proxy.
# ============================================

echo "╔══════════════════════════════════════════╗"
echo "║  Railway Proxy Mobile - SSH Server       ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "SSH Port: 2222"
echo "Proxy Port: 1080 (aguardando túnel do celular)"
echo ""
echo "Comando para o celular (Termux):"
echo "  ssh -p PORT -o StrictHostKeyChecking=no \\"
echo "      -R 0.0.0.0:1080:localhost:8899 \\"
echo "      tunnel@HOST"
echo ""

# Iniciar SSH server em foreground
exec /usr/sbin/sshd -D -e
