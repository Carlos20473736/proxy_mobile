# 5G-SHARE - Proxy Mobile via Railway

Compartilhe a internet 5G do seu celular com qualquer PC, de qualquer lugar do mundo, sem precisar estar na mesma rede.

## Como Funciona

```
[PC] ──SOCKS5──→ [Railway Server] ←──Túnel──→ [Termux/Celular 5G] ──→ [Internet]
```

O PC conecta direto no servidor Railway usando **host + porta + usuário + senha** (SOCKS5).
O celular mantém um túnel aberto com o Railway, roteando todo o tráfego pelo 5G.

**Velocidade:** Mesma do seu 5G. Sem throttling de tethering.

---

## Configuração

### 1. Deploy no Railway

1. Faça deploy deste repositório no Railway
2. Configure as variáveis de ambiente no Railway:

| Variável | Valor | Descrição |
|----------|-------|-----------|
| `PORT` | `1080` | Porta do servidor (Railway define automaticamente) |
| `PROXY_USER` | `5guser` | Usuário para o PC conectar |
| `PROXY_PASS` | `sua_senha_aqui` | Senha para o PC conectar |
| `TUNNEL_SECRET` | `sua_chave_secreta` | Chave para autenticar o celular |

3. Anote o domínio público gerado pelo Railway (ex: `proxy-mobile-production.up.railway.app`)
4. **IMPORTANTE:** No Railway, vá em Settings > Networking e habilite **TCP Proxy** (não apenas HTTP). Anote a porta TCP pública gerada.

### 2. Configurar o Celular (Termux)

1. Instale o [Termux](https://f-droid.org/packages/com.termux/) no celular
2. Copie o arquivo `start-celular.sh` para o Termux
3. Execute:
   ```bash
   pkg install nodejs-lts
   bash start-celular.sh
   ```
4. Digite o host e porta do Railway quando solicitado
5. Pronto! O túnel está ativo.

### 3. Configurar o PC

No seu PC, configure o proxy SOCKS5 com os dados:

| Campo | Valor |
|-------|-------|
| Protocolo | **SOCKS5** |
| Host | `seu-app.railway.app` (ou IP do TCP Proxy) |
| Porta | A porta TCP pública do Railway |
| Usuário | O que você definiu em `PROXY_USER` |
| Senha | O que você definiu em `PROXY_PASS` |

Pode configurar em:
- Navegador (Firefox: Configurações > Rede > Proxy Manual)
- Sistema (Windows: Configurações > Rede > Proxy)
- Qualquer app que suporte SOCKS5

---

## Variáveis de Ambiente

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `PORT` | `1080` | Porta principal do servidor |
| `PROXY_USER` | `5guser` | Usuário SOCKS5 |
| `PROXY_PASS` | `senha123` | Senha SOCKS5 |
| `TUNNEL_SECRET` | `tunnel_secret_key` | Chave de autenticação do túnel |

---

## Endpoints HTTP

- `GET /` - Página de status
- `GET /status` - Status em JSON
- `GET /health` - Health check

---

## Notas

- O servidor detecta automaticamente se a conexão é SOCKS5 (PC), HTTP (status) ou Túnel (celular)
- Se o celular desconectar, o servidor faz fallback para conexão direta (usando a internet do Railway)
- O celular reconecta automaticamente se a conexão cair
- Use `termux-wake-lock` no Termux para manter o celular ativo
