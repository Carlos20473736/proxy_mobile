#!/data/data/com.termux/files/usr/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  5G-SHARE v7.0 - ALTA PERFORMANCE                          ║
# ║  Pool de 4 conexões paralelas | Overhead 0.007%             ║
# ╚══════════════════════════════════════════════════════════════╝

SERVER_HOST="hayabusa.proxy.rlwy.net"
SERVER_PORT="32618"
TUNNEL_SECRET="senha123"
POOL_SIZE=4

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  5G-SHARE v7.0 - ALTA PERFORMANCE                      ║"
echo "║  Pool: ${POOL_SIZE} conexões | Protocolo binário | Flow Control  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Instalar Node.js se necessário
if ! command -v node &> /dev/null; then
    echo -e "${YELLOW}[*] Instalando Node.js...${NC}"
    pkg install -y nodejs-lts 2>/dev/null || pkg install -y nodejs
fi

termux-wake-lock 2>/dev/null

# Criar o cliente de túnel de alta performance
cat > $HOME/.5g-tunnel-v7.js << 'TUNNELEOF'
const net = require('net');
const dns = require('dns');

// === CONFIG ===
const HOST = process.env.SH;
const PORT = parseInt(process.env.SP);
const SECRET = process.env.SS;
const POOL_SIZE = parseInt(process.env.PS || '4');

// === PROTOCOLO ===
const CMD = {
  CONNECT: 1, CONNECTED: 2, DATA: 3, CLOSE: 4,
  ERROR: 5, PING: 6, FLOW_PAUSE: 7, FLOW_RESUME: 8
};
const HDR = 5;
const MAX_PAYLOAD = 65000;

// === ESTADO ===
const pool = [];           // Sockets do pool
const conns = new Map();   // id → {socket, paused}
const dnsCache = new Map(); // host → {ip, ts}
const DNS_TTL = 300000;    // 5 min cache
let stats = { rx: 0, tx: 0, conns: 0, active: 0 };

// === FUNÇÕES ===
function frame(cmd, id, data) {
  const len = data ? data.length : 0;
  const buf = Buffer.allocUnsafe(HDR + len);
  buf[0] = cmd;
  buf.writeUInt16BE(id, 1);
  buf.writeUInt16BE(len, 3);
  if (data) data.copy(buf, HDR);
  return buf;
}

function sendFrame(cmd, id, data) {
  // Encontrar socket disponível no pool (round-robin)
  for (let i = 0; i < pool.length; i++) {
    const s = pool[i];
    if (s && s.ready && !s.destroyed) {
      try {
        if (!data || data.length <= MAX_PAYLOAD) {
          s.write(frame(cmd, id, data));
        } else {
          let off = 0;
          while (off < data.length) {
            const chunk = data.slice(off, Math.min(off + MAX_PAYLOAD, data.length));
            // Distribuir chunks entre sockets do pool
            const target = pool[(i + Math.floor(off / MAX_PAYLOAD)) % pool.length];
            if (target && target.ready && !target.destroyed) {
              target.write(frame(cmd, id, chunk));
            } else {
              s.write(frame(cmd, id, chunk));
            }
            off += MAX_PAYLOAD;
          }
        }
        return true;
      } catch(e) { return false; }
    }
  }
  return false;
}

// === DNS CACHE ===
function resolveHost(host) {
  return new Promise((resolve) => {
    // Se já é IP, retorna direto
    if (/^\d+\.\d+\.\d+\.\d+$/.test(host) || host.includes(':')) {
      return resolve(host);
    }
    
    // Verificar cache
    const cached = dnsCache.get(host);
    if (cached && Date.now() - cached.ts < DNS_TTL) {
      return resolve(cached.ip);
    }
    
    // Resolver
    dns.resolve4(host, (err, addresses) => {
      if (err || !addresses.length) return resolve(host);
      const ip = addresses[0];
      dnsCache.set(host, { ip, ts: Date.now() });
      resolve(ip);
    });
  });
}

// === POOL DE CONEXÕES ===
function connectPool() {
  for (let i = 0; i < POOL_SIZE; i++) {
    connectSlot(i);
  }
}

function connectSlot(idx) {
  if (pool[idx] && !pool[idx].destroyed) return;
  
  const sock = net.createConnection({ host: HOST, port: PORT }, () => {
    // Autenticar com índice do pool
    sock.write(`${SECRET}:${idx}\n`);
  });
  
  sock.setNoDelay(true);
  sock.setKeepAlive(true, 15000);
  try { sock.setRecvBufferSize(524288); } catch(e) {}
  try { sock.setSendBufferSize(524288); } catch(e) {}
  
  sock.ready = false;
  sock._idx = idx;
  sock._buf = Buffer.alloc(0);
  pool[idx] = sock;
  
  let authed = false;
  
  sock.on('data', (data) => {
    if (!authed) {
      const msg = data.toString().trim();
      if (msg === 'OK') {
        authed = true;
        sock.ready = true;
        const readyCount = pool.filter(s => s && s.ready && !s.destroyed).length;
        if (readyCount === 1) {
          console.log(`\x1b[32m[✓] POOL ATIVO! ${readyCount}/${POOL_SIZE} conexões\x1b[0m`);
        } else {
          process.stdout.write(`\r\x1b[32m[✓] POOL: ${readyCount}/${POOL_SIZE} conexões ativas\x1b[0m    `);
          if (readyCount === POOL_SIZE) console.log('\n\x1b[32m[✓] VELOCIDADE MÁXIMA! Todas as conexões ativas.\x1b[0m');
        }
      } else {
        console.log(`\x1b[31m[✗] Slot ${idx}: auth falhou\x1b[0m`);
        sock.destroy();
      }
      return;
    }
    
    // Processar frames
    sock._buf = sock._buf.length ? Buffer.concat([sock._buf, data]) : data;
    processFrames(sock);
  });
  
  sock.on('close', () => {
    sock.ready = false;
    pool[idx] = null;
    const readyCount = pool.filter(s => s && s.ready && !s.destroyed).length;
    if (readyCount === 0) {
      console.log(`\n\x1b[31m[!] Pool offline. Reconectando em 3s...\x1b[0m`);
    }
    setTimeout(() => connectSlot(idx), 3000);
  });
  
  sock.on('error', (e) => {
    if (!authed) {
      // Silenciar erros de conexão durante reconexão
    }
  });
  
  // Ping keepalive
  const iv = setInterval(() => {
    if (sock.destroyed) { clearInterval(iv); return; }
    if (sock.ready) {
      try { sock.write(frame(CMD.PING, 0, null)); } catch(e) { clearInterval(iv); }
    }
  }, 15000);
  sock.on('close', () => clearInterval(iv));
}

// === PROCESSAR FRAMES ===
function processFrames(sock) {
  while (sock._buf.length >= HDR) {
    const len = sock._buf.readUInt16BE(3);
    if (sock._buf.length < HDR + len) break;
    
    const cmd = sock._buf[0];
    const id = sock._buf.readUInt16BE(1);
    const payload = len > 0 ? sock._buf.slice(HDR, HDR + len) : null;
    sock._buf = sock._buf.slice(HDR + len);
    
    handleCommand(cmd, id, payload);
  }
}

function handleCommand(cmd, id, payload) {
  switch(cmd) {
    case CMD.CONNECT: {
      // Server pede para conectar em host:port
      const target = payload.toString();
      const sep = target.lastIndexOf(':');
      const host = target.slice(0, sep);
      const port = parseInt(target.slice(sep + 1));
      
      stats.conns++;
      stats.active++;
      
      // Resolver DNS com cache e conectar
      resolveHost(host).then(ip => {
        const remote = net.createConnection({ host: ip, port }, () => {
          remote.setNoDelay(true);
          try { remote.setRecvBufferSize(262144); } catch(e) {}
          try { remote.setSendBufferSize(262144); } catch(e) {}
          sendFrame(CMD.CONNECTED, id, null);
        });
        
        remote.on('data', (d) => {
          stats.tx += d.length;
          const ok = sendFrame(CMD.DATA, id, d);
          // Backpressure
          if (!ok) {
            remote.pause();
            setTimeout(() => remote.resume(), 50);
          }
        });
        
        remote.on('close', () => {
          conns.delete(id);
          stats.active--;
          sendFrame(CMD.CLOSE, id, null);
        });
        
        remote.on('error', () => {
          conns.delete(id);
          stats.active--;
          sendFrame(CMD.ERROR, id, null);
        });
        
        // Timeout de conexão
        remote.setTimeout(8000, () => {
          remote.destroy();
          conns.delete(id);
          stats.active--;
          sendFrame(CMD.ERROR, id, null);
        });
        
        // Remover timeout após conectar
        remote.on('connect', () => remote.setTimeout(0));
        
        conns.set(id, remote);
      });
      break;
    }
    
    case CMD.DATA: {
      const c = conns.get(id);
      if (c && !c.destroyed) {
        stats.rx += payload.length;
        const ok = c.write(payload);
        // Backpressure: se buffer cheio, avisar server
        if (!ok) {
          sendFrame(CMD.FLOW_PAUSE, id, null);
          c.once('drain', () => sendFrame(CMD.FLOW_RESUME, id, null));
        }
      }
      break;
    }
    
    case CMD.CLOSE: {
      const c = conns.get(id);
      if (c) { c.destroy(); conns.delete(id); stats.active--; }
      break;
    }
    
    case CMD.FLOW_PAUSE: {
      const c = conns.get(id);
      if (c) c.pause();
      break;
    }
    
    case CMD.FLOW_RESUME: {
      const c = conns.get(id);
      if (c) c.resume();
      break;
    }
    
    case CMD.PING:
      // Pong automático
      sendFrame(CMD.PING, 0, null);
      break;
  }
}

// === STATS DISPLAY ===
setInterval(() => {
  const readyCount = pool.filter(s => s && s.ready && !s.destroyed).length;
  if (readyCount > 0) {
    const rxMB = (stats.tx / 1048576).toFixed(1);
    const txMB = (stats.rx / 1048576).toFixed(1);
    process.stdout.write(`\r\x1b[36m[STATS] Pool: ${readyCount}/${POOL_SIZE} | ↑${rxMB}MB ↓${txMB}MB | Conns: ${stats.active} ativas (${stats.conns} total)\x1b[0m    `);
  }
}, 5000);

// === INICIAR ===
console.log(`[*] Conectando pool de ${POOL_SIZE} sockets em ${HOST}:${PORT}...`);
connectPool();

// === CLEANUP ===
process.on('SIGINT', () => {
  console.log('\n\x1b[33m[!] Encerrando...\x1b[0m');
  for (const s of pool) { if (s && !s.destroyed) s.destroy(); }
  for (const [,c] of conns) { if (c && !c.destroyed) c.destroy(); }
  process.exit(0);
});

process.on('uncaughtException', (e) => {
  console.error('\n[!] Erro:', e.message);
});
TUNNELEOF

echo -e "${GREEN}[✓] Cliente v7.0 criado${NC}"
echo -e "${YELLOW}    Pool: ${POOL_SIZE} conexões paralelas${NC}"
echo -e "${YELLOW}    Protocolo: binário 5B header${NC}"
echo -e "${YELLOW}    Flow control: backpressure ativo${NC}"
echo -e "${YELLOW}    DNS: cache local 5min${NC}"
echo ""

SH="$SERVER_HOST" SP="$SERVER_PORT" SS="$TUNNEL_SECRET" PS="$POOL_SIZE" node $HOME/.5g-tunnel-v7.js
