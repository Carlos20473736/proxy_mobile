#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  5G-SHARE v8.0 - KISS (Velocidade Máxima)                  ║
# ║  1 controle + N conexões de dados (pipe direto)             ║
# ╚══════════════════════════════════════════════════════════════╝

SERVER_HOST="hayabusa.proxy.rlwy.net"
SERVER_PORT="32618"
TUNNEL_SECRET="senha123"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  5G-SHARE v8.0 - Velocidade Máxima                     ║"
echo "║  Pipe direto | Zero overhead | Zero multiplexação       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Instalar Node.js se necessário
if ! command -v node &> /dev/null; then
    echo -e "${YELLOW}[*] Instalando Node.js...${NC}"
    pkg install -y nodejs-lts 2>/dev/null || pkg install -y nodejs
fi

termux-wake-lock 2>/dev/null

# Criar o cliente
cat > $HOME/.5g-v8.js << 'TUNNELEOF'
const net = require('net');

const HOST = process.env.SH;
const PORT = parseInt(process.env.SP);
const SECRET = process.env.SS;

let control = null;
let reconnecting = false;
let stats = { conns: 0, active: 0 };

function log(msg) { console.log(`\x1b[36m[TUNNEL]\x1b[0m ${msg}`); }

function connect() {
  if (reconnecting) return;
  reconnecting = true;
  
  log(`Conectando ${HOST}:${PORT}...`);
  
  control = net.createConnection({ host: HOST, port: PORT }, () => {
    control.write(`TUNNEL:${SECRET}\n`);
  });
  
  control.setNoDelay(true);
  control.setKeepAlive(true, 10000);
  
  let authed = false;
  let lineBuf = '';
  
  control.on('data', (d) => {
    lineBuf += d.toString();
    
    while (true) {
      const nl = lineBuf.indexOf('\n');
      if (nl === -1) break;
      const line = lineBuf.slice(0, nl).trim();
      lineBuf = lineBuf.slice(nl + 1);
      
      if (!authed) {
        if (line === 'OK') {
          authed = true;
          reconnecting = false;
          console.log(`\x1b[32m[✓] CONECTADO! PC pode usar o 5G agora.\x1b[0m`);
        } else {
          log('Auth falhou: ' + line);
          control.destroy();
        }
        continue;
      }
      
      // Processar comandos
      if (line.startsWith('OPEN:')) {
        handleOpen(line);
      } else if (line === 'PING') {
        try { control.write('PONG\n'); } catch(e) {}
      }
    }
  });
  
  control.on('close', () => {
    reconnecting = false;
    log('Desconectou. Reconectando em 3s...');
    setTimeout(connect, 3000);
  });
  
  control.on('error', (e) => {
    reconnecting = false;
    if (e.code !== 'ECONNREFUSED') log('Erro: ' + e.message);
    setTimeout(connect, 3000);
  });
}

function handleOpen(line) {
  // Formato: OPEN:<id>:<host>:<port>
  const parts = line.split(':');
  const id = parts[1];
  // Host pode conter ":" (IPv6), então pegar a porta do final
  const port = parseInt(parts[parts.length - 1]);
  const host = parts.slice(2, -1).join(':');
  
  stats.conns++;
  stats.active++;
  
  // Conectar ao destino
  const remote = net.createConnection({ host, port }, () => {
    remote.setNoDelay(true);
    
    // Abrir conexão de dados com o servidor
    const data = net.createConnection({ host: HOST, port: PORT }, () => {
      data.setNoDelay(true);
      data.write(`DATA:${SECRET}:${id}\n`);
      
      // Pipe direto: servidor ↔ destino (velocidade máxima!)
      data.pipe(remote);
      remote.pipe(data);
    });
    
    data.on('error', () => { remote.destroy(); stats.active--; });
    data.on('close', () => { remote.destroy(); stats.active--; });
    remote.on('error', () => data.destroy());
    remote.on('close', () => data.destroy());
  });
  
  remote.on('error', (e) => {
    stats.active--;
    // Abrir conexão de dados e fechar imediatamente (sinalizar erro)
    const data = net.createConnection({ host: HOST, port: PORT }, () => {
      data.write(`DATA:${SECRET}:${id}\n`);
      setTimeout(() => data.destroy(), 100);
    });
    data.on('error', () => {});
  });
  
  remote.setTimeout(10000, () => {
    remote.destroy();
    stats.active--;
  });
  remote.on('connect', () => remote.setTimeout(0));
}

// Status periódico
setInterval(() => {
  if (control && !control.destroyed) {
    process.stdout.write(`\r\x1b[33m[${new Date().toLocaleTimeString()}]\x1b[0m Conexões: ${stats.conns} total | ${stats.active} ativas    `);
  }
}, 5000);

connect();
TUNNELEOF

echo -e "${GREEN}[✓] Cliente criado${NC}"
echo ""

# Executar
SH="$SERVER_HOST" SP="$SERVER_PORT" SS="$TUNNEL_SECRET" exec node $HOME/.5g-v8.js
