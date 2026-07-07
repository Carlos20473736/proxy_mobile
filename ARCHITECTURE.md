# Arquitetura v7.0 - ALTA PERFORMANCE

## Gargalos identificados na v6.0:

1. **Latência geográfica**: Railway US East, dados cruzam oceano 4x
   - Solução: Não podemos mudar a região, mas podemos MASCARAR a latência com pipeline
   
2. **Conexão única de túnel**: Um único socket TCP entre celular e Railway
   - Se um pacote atrasa, TODOS os streams param (head-of-line blocking)
   - Solução: POOL de conexões paralelas (4-8 sockets simultâneos)

3. **Serialização de frames**: Cada frame espera o anterior ser enviado
   - Solução: Round-robin entre múltiplas conexões do pool

4. **Sem backpressure**: Dados acumulam no buffer sem controle
   - Solução: Flow control com pause/resume baseado em highWaterMark

5. **TCP Nagle algorithm**: Pequenos pacotes são agrupados (40ms delay)
   - Solução: TCP_NODELAY + cork/uncork para pacotes grandes

## Nova Arquitetura:

```
PC ──HTTP CONNECT──→ [Railway Server] ←──POOL 4x TCP──→ [Termux] ──→ Internet
                         │                    │
                    Multiplexador         Demultiplexador
                    Round-Robin           Conexões diretas
                    Flow Control          DNS local
```

## Otimizações:

1. **Pool de 4 conexões TCP paralelas** entre celular e Railway
   - Elimina head-of-line blocking
   - Round-robin distribui carga
   - Se uma conexão cai, as outras continuam

2. **Protocolo binário mínimo** (5 bytes header)
   - CMD(1) + ID(2) + LEN(2) + PAYLOAD
   - Zero overhead de encoding

3. **Flow control com backpressure**
   - socket.pause() quando buffer > 1MB
   - socket.resume() quando drena
   - Evita OOM e mantém throughput estável

4. **TCP otimizado**
   - TCP_NODELAY em todos os sockets
   - Keepalive 15s
   - Buffer 512KB send/recv
   - Socket reuse

5. **Pipeline de requests**
   - Múltiplos CONNECT simultâneos
   - Não espera resposta para enviar próximo
   - Timeout agressivo (5s) para conexões lentas

6. **Prefetch DNS no celular**
   - Cache DNS local
   - Resolve antes de conectar
   - Reduz 1 RTT por conexão nova
