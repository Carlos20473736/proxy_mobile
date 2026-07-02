# Proxy Mobile via Railway - v3.0 (CHISEL)

Proxy mobile de alta velocidade que roteia tráfego pelo IP 5G/4G do celular via **chisel** (túnel HTTP2/WebSocket).

**v3.0** substitui SSH+sslh+microsocks por um único binário (chisel) que é **muito mais rápido**.

---

## Por que chisel é mais rápido que SSH?

| Aspecto | SSH (v2.0) | Chisel (v3.0) |
|---------|-----------|---------------|
| Protocolo | TCP puro | HTTP2 (multiplexing nativo) |
| Streams | 1 canal TCP | Múltiplos streams paralelos |
| Overhead | Alto (criptografia + MAC + rekey) | Baixo (HTTP2 frames) |
| Componentes | sslh + sshd + microsocks | 1 binário (chisel) |
| Reconexão | Script bash manual | Automática com backoff |
| CPU no celular | Alta (cipher + MAC por pacote) | Baixa |

---

## Arquitetura

```
Fingerprint Manager → Railway (porta 1080) → chisel tunnel (HTTP2) → celular (5G/4G)
                         SOCKS5                                         resolve DNS + navega
```

| Componente | Função |
|------------|--------|
| **chisel server** (Railway, porta 1080) | Aceita conexões SOCKS5 e tunela via HTTP2 |
| **chisel client** (celular) | Recebe tráfego e navega usando IP mobile |

---

## Deploy no Railway

1. Faça fork ou suba este repositório no GitHub.
2. No [Railway](https://railway.app/), crie um novo projeto a partir do repo.
3. Após o deploy, vá em **Settings → Networking → TCP Proxy**.
4. Gere um TCP Proxy para a porta **1080**.
5. Anote o host e porta gerados (ex: `nozomi.proxy.rlwy.net:33719`).

---

## Configurar o Celular (Termux)

1. Edite `start-celular.sh` com os dados do Railway:
   ```bash
   RAILWAY_HOST="nozomi.proxy.rlwy.net"   # Host do TCP Proxy
   RAILWAY_PORT="33719"                    # Porta do TCP Proxy
   ```

2. Execute:
   ```bash
   chmod +x start-celular.sh
   ./start-celular.sh
   ```

   Na primeira execução, o script baixa e instala o chisel automaticamente.

---

## Configurar o Fingerprint Manager

| Campo | Valor |
|-------|-------|
| **Tipo** | SOCKS5 |
| **Host** | Host do Railway (ex: `nozomi.proxy.rlwy.net`) |
| **Porta** | Porta do TCP Proxy (ex: `33719`) |
| **User** | *(deixar vazio)* |
| **Pass** | *(deixar vazio)* |

---

## Diagnóstico

Se a velocidade estiver baixa:

1. **Sinal 5G/4G** — O gargalo é sempre a rede móvel.
2. **Wake lock** — Mantenha o Termux com wake lock ativo.
3. **Otimização de bateria** — Desabilite para o Termux.
4. **Wi-Fi desligado** — Force o celular a usar apenas 5G/4G.

---

## Segurança

| Camada | Proteção |
|--------|----------|
| Chisel tunnel | Criptografia SSH embutida no protocolo |
| Autenticação | `tunnel:proxypass123` (altere em produção) |
| SOCKS5 sem auth | Seguro pois só funciona via túnel chisel |
