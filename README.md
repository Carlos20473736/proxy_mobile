# Proxy Mobile via Railway - v3.1

Proxy mobile que roteia tráfego pelo IP 5G/4G do celular via SSH otimizado.

**v3.1** remove o sslh (multiplexador) e usa SSH direto + 2 portas no Railway, eliminando 1 hop de processamento.

---

## Arquitetura

```
Fingerprint Manager → Railway:9050 (TCP Proxy) → túnel SSH → celular (5G/4G)
                        SOCKS5                                  microsocks
```

| Porta Railway | Função |
|---------------|--------|
| 1080 (TCP Proxy: nozomi:33719) | SSH direto — celular conecta aqui |
| 9050 (TCP Proxy: reseau:51887) | SOCKS5 — Fingerprint Manager conecta aqui |

---

## Otimizações de velocidade

| Otimização | Efeito |
|------------|--------|
| Sem sslh | -1 hop de processamento, menos latência |
| SSH direto na porta 1080 | Conexão imediata (sem detecção de protocolo) |
| Ciphers: aes128-gcm | Usa aceleração AES de hardware do ARM |
| Compression: no | Menos CPU no celular |
| RekeyLimit: 0 0 | Sem pausas de renegociação |
| TCP BBR | Melhor para redes móveis |
| Buffers TCP 16MB | Mais throughput |
| TCP Fast Open | -1 RTT por conexão |

---

## Deploy no Railway

1. Suba este repositório no Railway.
2. Crie **2 TCP Proxies**:
   - Porta **1080** (para o celular conectar via SSH)
   - Porta **9050** (para o Fingerprint Manager usar como SOCKS5)
3. Anote os hosts e portas gerados.

---

## Configurar o Celular (Termux)

1. Edite `start-celular.sh`:
   ```bash
   RAILWAY_HOST="nozomi.proxy.rlwy.net"   # Host do TCP Proxy porta 1080
   RAILWAY_PORT="33719"                    # Porta do TCP Proxy porta 1080
   ```

2. Execute:
   ```bash
   chmod +x start-celular.sh
   ./start-celular.sh
   ```

---

## Configurar o Fingerprint Manager

| Campo | Valor |
|-------|-------|
| Tipo | SOCKS5 |
| Host | reseau.proxy.rlwy.net |
| Porta | 51887 |
| User | *(vazio)* |
| Pass | *(vazio)* |

---

## Diagnóstico

- **Velocidade baixa**: O gargalo é a rede 5G/4G do celular + overhead do SSH.
- **Desconexões**: Mantenha o Termux com wake lock ativo e desabilite otimização de bateria.
