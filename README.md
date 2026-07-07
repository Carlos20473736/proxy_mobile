# Proxy Mobile via Railway - v3.2

Proxy mobile que roteia tráfego pelo IP 5G/4G do celular via SSH otimizado.

**v3.2** corrige problemas de conexão da v3.1, melhora estabilidade e adiciona diagnóstico automático.

---

## Arquitetura

```
Fingerprint Manager → Railway:9050 (TCP Proxy) → túnel SSH → celular (5G/4G)
                        SOCKS5                                  microsocks
```

| Porta Railway | Função |
|---|---|
| 1080 (TCP Proxy: nozomi:33719) | SSH direto — celular conecta aqui |
| 9050 (TCP Proxy: reseau:51887) | SOCKS5 — Fingerprint Manager conecta aqui |

---

## Mudanças v3.1 → v3.2

| Problema v3.1 | Correção v3.2 |
|---|---|
| `Connection closed` (código 255) | Adicionado `-T` (sem TTY), ciphers expandidos, fallback config |
| Microsocks morre sem aviso | Monitoramento e restart automático do microsocks |
| Sem diagnóstico de falha | Mensagens de diagnóstico após 5 tentativas falhas |
| Host keys podem faltar | Regeneração automática no start.sh |
| sshd_config pode ser inválido | Validação com `sshd -t` + fallback para config mínima |
| Sem healthcheck | Railway detecta container morto e reinicia |
| KexAlgorithms não especificado | Adicionado para evitar incompatibilidade |

---

## Deploy no Railway

1. Faça fork ou suba este repositório no Railway
2. Crie **2 TCP Proxies** no serviço:
   - Porta **1080** → para o celular conectar via SSH
   - Porta **9050** → para o Fingerprint Manager usar como SOCKS5
3. Anote os hosts e portas gerados pelo Railway

### Verificação

Após o deploy, verifique no Railway:
- Status do serviço: **Active** (verde)
- Logs: deve mostrar "SSH escutando na porta 1080"
- Ambos TCP Proxies devem estar listados

---

## Configurar o Celular (Termux)

1. Instale o Termux (F-Droid recomendado)

2. No Termux, execute:
```bash
pkg update -y && pkg install -y openssh sshpass curl
```

3. Baixe e execute o script:
```bash
curl -fsSL "https://raw.githubusercontent.com/Carlos20473736/proxy_mobile/main/start-celular.sh" -o start-celular.sh
chmod +x start-celular.sh
```

4. **IMPORTANTE**: Edite o script com seus dados do Railway:
```bash
nano start-celular.sh
```
Altere estas linhas com os dados do seu TCP Proxy (porta 1080):
```bash
RAILWAY_HOST="nozomi.proxy.rlwy.net"   # Host do TCP Proxy porta 1080
RAILWAY_PORT="33719"                    # Porta do TCP Proxy porta 1080
```

5. Execute:
```bash
./start-celular.sh
```

### Dicas para Termux

- **Wake Lock**: `termux-wake-lock` (mantém o processo ativo)
- **Bateria**: Desabilite otimização de bateria para o Termux
- **Notificação**: Use `termux-notification` para monitorar status

---

## Configurar o Fingerprint Manager

| Campo | Valor |
|---|---|
| Tipo | SOCKS5 |
| Host | reseau.proxy.rlwy.net |
| Porta | 51887 |
| User | (vazio) |
| Pass | (vazio) |

---

## Diagnóstico / Troubleshooting

### Erro: "Connection closed" (código 255)

**Causas mais comuns:**

1. **Servidor Railway não está rodando**
   - Verifique no dashboard se o serviço está "Active"
   - Faça redeploy se necessário

2. **TCP Proxy não configurado corretamente**
   - Confirme que existe um TCP Proxy mapeando para a porta 1080
   - Verifique se o host e porta no script batem com o Railway

3. **Host keys incompatíveis**
   - O Railway pode regenerar o container (novas host keys)
   - O script já usa `UserKnownHostsFile=/dev/null` para evitar isso

4. **Rede bloqueando SSH**
   - Algumas redes móveis bloqueiam portas não-padrão
   - Tente trocar para dados móveis se estiver em Wi-Fi

### Erro: "Microsocks morreu"

- O script reinicia automaticamente
- Se persistir, verifique memória: `free -h`

### Velocidade baixa

- O gargalo é a rede 5G/4G do celular
- Verifique sinal e velocidade com speedtest
- SSH adiciona ~5-10% de overhead

### Desconexões frequentes

- Mantenha wake lock ativo: `termux-wake-lock`
- Desabilite otimização de bateria
- Use rede estável (5G > 4G > Wi-Fi público)

---

## Segurança

| Item | Status |
|---|---|
| Senha do túnel | `proxypass123` (altere no Dockerfile e script) |
| Acesso SOCKS5 | Sem autenticação (protegido pelo Railway) |
| Host keys | Geradas no build, regeneradas se ausentes |

**Recomendação**: Para produção, use autenticação por chave SSH em vez de senha.
