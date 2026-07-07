# 5G-SHARE v5.0 - Velocidade Máxima

Compartilhe a internet 5G do celular com o PC na velocidade máxima, sem estar na mesma rede.

## Arquitetura

```
[PC] → Cloudflare (SP) → [Celular 5G] → Internet
```

O tráfego passa pelo datacenter Cloudflare em São Paulo — latência mínima, velocidade máxima.

## Como usar

### 1. No Celular (Termux)

```bash
curl -sL https://raw.githubusercontent.com/Carlos20473736/proxy_mobile/main/start-celular.sh | bash
```

Anote o **Host** que aparecer na tela.

### 2. No PC (Windows)

1. Baixe o `cloudflared`: [Download](https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe)
2. Coloque em `C:\cloudflared\`
3. Rode o `conectar-pc.bat` (ou `conectar-pc.ps1`)
4. Cole o Host que apareceu no celular

### 3. No Fingerprint Manager

| Campo | Valor |
|-------|-------|
| Protocolo | SOCKS5 |
| Host | 127.0.0.1 |
| Porta | 1080 |
| Usuário | 5guser |
| Senha | senha123 |

## Por que é rápido?

- **Sem Base64** — dados binários puros
- **Sem intermediário nos EUA** — Cloudflare tem datacenter em SP
- **microsocks** — proxy SOCKS5 nativo em C (não Node.js)
- **Sem overhead** — conexão TCP direta via túnel
- **Sem throttling** — operadora vê como uso normal do celular
