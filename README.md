# Proxy Mobile v4.0

## Arquitetura (1 TCP Proxy)

```
[Fingerprint Manager] → SOCKS5 → hayabusa.proxy.rlwy.net:32618
                                        ↓ (sslh detecta SOCKS5)
                                   microsocks:1080
                                        ↓ (reverse tunnel)
                                   celular:8899
                                        ↓
                                   internet (IP do celular)

[Celular/Termux] → SSH → hayabusa.proxy.rlwy.net:32618
                              ↓ (sslh detecta SSH)
                         sshd:2222
                              ↓ (reverse tunnel criado)
                         porta 8899 no servidor
```

## Configuração Railway

- **1 TCP Proxy**: `hayabusa.proxy.rlwy.net:32618 → :7777`
- Internamente: sslh na 7777 → SSH(2222) + SOCKS5(1080)

## No Celular (Termux)

```bash
curl -fsSL "https://raw.githubusercontent.com/Carlos20473736/proxy_mobile/main/start-celular.sh" -o start-celular.sh
chmod +x start-celular.sh
./start-celular.sh
```

## Fingerprint Manager

| Campo | Valor |
|-------|-------|
| Tipo | SOCKS5 |
| Host | hayabusa.proxy.rlwy.net |
| Porta | 32618 |
| User | (vazio) |
| Pass | (vazio) |
