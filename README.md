# Proxy Mobile via Railway - v2.0 (Otimizado)

Solução de proxy mobile que roteia tráfego pelo IP 4G do celular via túnel SSH reverso no Railway.

**v2.0** inclui otimizações agressivas de velocidade que reduzem latência e aumentam throughput significativamente.

---

## Arquitetura

```
Fingerprint Manager → Railway (porta 1080) → sslh → túnel SSH reverso → celular (4G)
```

| Componente | Função |
|------------|--------|
| **sslh** (porta 1080) | Multiplexador: detecta SSH vs SOCKS5 na mesma porta |
| **sshd** (porta 2222) | Recebe conexão SSH do celular |
| **microsocks** (celular) | Proxy SOCKS5 local que usa o IP 4G |
| **túnel reverso** | Porta 9050 do Railway → porta 8899 do celular |

---

## Otimizações v2.0

### No Servidor (Railway)

| Otimização | Efeito |
|------------|--------|
| Buffers TCP 16MB | Mais throughput em conexões de alta latência |
| TCP BBR | Congestion control otimizado para redes móveis |
| TCP Fast Open | Reduz 1 RTT no handshake de novas conexões |
| `tcp_slow_start_after_idle=0` | Mantém velocidade constante mesmo após pausa |
| `tcp_tw_reuse=1` | Reutiliza portas, mais conexões simultâneas |
| Keepalive agressivo (10s) | Detecta conexão morta em ~30s |
| sslh timeout=2s | Detecção de protocolo 60% mais rápida |
| Ciphers leves no sshd | Menos CPU = mais banda disponível |
| `RekeyLimit 0 0` | Elimina micro-pausas de renegociação |

### No Celular (Termux)

| Otimização | Efeito |
|------------|--------|
| `aes128-gcm` como cipher primário | Usa aceleração AES de hardware do ARM |
| `Compression=no` | Evita recompressão de tráfego já comprimido |
| `RekeyLimit="0 0"` | Sem pausas de renegociação |
| `KexAlgorithms=curve25519-sha256` | Key exchange mais rápido |
| `ConnectTimeout=10` | Não fica pendurado em conexão lenta |
| Backoff inteligente | Reconexão rápida sem sobrecarregar |
| Auto-restart do microsocks | Recupera de travamentos automaticamente |

---

## Deploy no Railway

1. Faça fork ou suba este repositório no GitHub.
2. No [Railway](https://railway.app/), crie um novo projeto a partir do repo.
3. Após o deploy, vá em **Settings → Networking → TCP Proxy**.
4. Gere um TCP Proxy para a porta **1080**.
5. Anote o host e porta gerados (ex: `nozomi.proxy.rlwy.net:33719`).

> **Nota:** Apenas UMA porta pública é necessária (1080). O sslh multiplexa SSH e SOCKS5 automaticamente.

---

## Configurar o Celular (Termux)

1. Instale as dependências:
   ```bash
   pkg install sshpass openssh
   ```

2. Edite `start-celular.sh` com os dados do Railway:
   ```bash
   RAILWAY_HOST="nozomi.proxy.rlwy.net"   # Host do TCP Proxy
   RAILWAY_PORT="33719"                    # Porta do TCP Proxy
   ```

3. Execute:
   ```bash
   chmod +x start-celular.sh
   ./start-celular.sh
   ```

---

## Configurar o Fingerprint Manager

| Campo | Valor |
|-------|-------|
| **Tipo** | SOCKS5 |
| **Host** | Host do Railway (ex: `nozomi.proxy.rlwy.net`) |
| **Porta** | Porta do TCP Proxy (ex: `33719`) |
| **User** | *(deixar vazio)* |
| **Pass** | *(deixar vazio)* |

> **Importante:** O microsocks roda SEM autenticação porque o Chromium não suporta SOCKS5 com senha. A segurança é garantida pelo túnel SSH (apenas tráfego vindo do Railway chega ao microsocks).

---

## Diagnóstico de Velocidade

Se a velocidade estiver baixa, verifique:

1. **Sinal 4G do celular** — O gargalo geralmente é a rede móvel.
2. **CPU do celular** — Se estiver alta, o cipher pode estar pesado. O `aes128-gcm` usa aceleração de hardware em CPUs ARM modernas.
3. **Reconexões frequentes** — Verifique se o celular não está entrando em modo de economia de bateria (mata o Termux em background).
4. **Latência** — Teste com `ping` para o host do Railway. Deve ser < 100ms.

### Dicas para máxima velocidade:

- Mantenha o Termux com **wake lock** ativo (notificação "Acquire wakelock").
- Desabilite **otimização de bateria** para o Termux nas configurações do Android.
- Use **Wi-Fi do celular desligado** para forçar 4G (evita switching entre redes).
- Se possível, fixe a banda em **LTE** nas configurações de rede.

---

## Segurança

| Camada | Proteção |
|--------|----------|
| SSH tunnel | Criptografia AES-128-GCM ponta-a-ponta |
| microsocks em 127.0.0.1 | Inacessível pela internet diretamente |
| Senha SSH | `tunnel:proxypass123` (altere em produção) |
| sslh | Só aceita SSH e SOCKS5, rejeita outros protocolos |
