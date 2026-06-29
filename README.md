# Guia Definitivo: Proxy Mobile via Railway (Brasil)

Esta solução substitui o Pinggy por um servidor próprio no **Railway** (São Paulo), reduzindo a latência de ~400ms para ~50ms e garantindo um endereço fixo que nunca expira.

---

## Passo 1: Fazer o Deploy no Railway

1. Extraia o arquivo `railway-proxy-mobile.zip` em uma pasta no seu PC.
2. Crie um repositório privado no seu **GitHub** e suba os 3 arquivos (`Dockerfile`, `railway.json`, `start.sh`).
3. Acesse [railway.app](https://railway.app/) e faça login.
4. Clique em **New Project** > **Deploy from GitHub repo**.
5. Selecione o repositório que você criou.
6. O Railway vai começar a fazer o build da imagem Docker.

---

## Passo 2: Expor as Portas (Public Networking)

Depois que o deploy terminar, você precisa expor duas portas:
- A porta **2222** (para o celular conectar via SSH)
- A porta **1080** (para o Fingerprint Manager usar como proxy)

1. No painel do Railway, clique no seu serviço.
2. Vá na aba **Settings** > **Networking**.
3. Em **TCP Proxy**, clique em **Generate TCP Proxy**.
4. Quando pedir a porta, digite **2222**. O Railway vai gerar um endereço (ex: `round-proxy.rlwy.net:15000`).
5. Repita o processo: clique em **Generate TCP Proxy** novamente.
6. Desta vez, digite a porta **1080**. O Railway vai gerar outro endereço (ex: `round-proxy.rlwy.net:15001`).

---

## Passo 3: Configurar o Celular (Termux)

1. Instale o `sshpass` no Termux:
   ```bash
   pkg install sshpass
   ```
2. Abra o arquivo `start-celular.sh` que está no zip.
3. Edite as duas primeiras variáveis com os dados que o Railway te deu para a porta **2222**:
   ```bash
   RAILWAY_HOST="round-proxy.rlwy.net"  # O host gerado pelo Railway
   RAILWAY_SSH_PORT="15000"             # A porta pública que aponta para a 2222
   ```
4. Copie o script para o Termux e execute:
   ```bash
   chmod +x start-celular.sh
   ./start-celular.sh
   ```

---

## Passo 4: Configurar o Fingerprint Manager

No Fingerprint Manager, você vai usar o endereço gerado para a porta **1080**.

| Campo | Valor |
|-------|-------|
| **Tipo** | SOCKS5 |
| **Host** | `round-proxy.rlwy.net` (O mesmo host do Railway) |
| **Porta** | `15001` (A porta pública que aponta para a 1080) |
| **User** | `carlos` |
| **Pass** | `oitavamente` |

---

## Resumo da Arquitetura

1. O seu celular conecta no servidor SSH do Railway e diz: "qualquer coisa que chegar na porta 1080 do Railway, mande para mim".
2. O Fingerprint Manager conecta na porta 1080 do Railway.
3. O Railway repassa a conexão para o celular.
4. O celular faz a autenticação (`carlos/oitavamente`) e navega usando o IP 4G.

Tudo isso acontece em **São Paulo**, com latência mínima e sem expirar!
