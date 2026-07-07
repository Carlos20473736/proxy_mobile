const net = require('net');
const http = require('http');

// === SERVIDOR DE STATUS (Railway) ===
// Agora o Railway serve apenas como página de status
// O tráfego real vai direto pelo Cloudflare Tunnel (velocidade máxima)

const PORT = parseInt(process.env.PORT || '7777');

const statusServer = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
        service: '5G-SHARE v5.0',
        status: 'online',
        mode: 'cloudflare-tunnel',
        instructions: {
            celular: 'curl -sL https://raw.githubusercontent.com/Carlos20473736/proxy_mobile/main/start-celular.sh | bash',
            pc: 'Rode conectar-pc.bat ou conectar-pc.ps1',
            config: {
                protocolo: 'SOCKS5',
                host: '127.0.0.1',
                porta: 1080,
                usuario: '5guser',
                senha: 'senha123'
            }
        }
    }, null, 2));
});

statusServer.listen(PORT, '0.0.0.0', () => {
    console.log('=== 5G-SHARE v5.0 - Status Server ===');
    console.log(`Porta: ${PORT}`);
    console.log('Modo: Cloudflare Tunnel (velocidade máxima)');
    console.log('======================================');
});
