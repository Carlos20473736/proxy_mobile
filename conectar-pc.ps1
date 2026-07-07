# ============================================================
# 5G-SHARE v5.0 - Conectar PC ao 5G do Celular
# Velocidade máxima via Cloudflare (datacenter Brasil)
# ============================================================

$ErrorActionPreference = "SilentlyContinue"
$CF_PATH = "C:\cloudflared\cloudflared-windows-amd64.exe"
$LOCAL_PORT = 1080

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║    5G-SHARE v5.0 - Conectar PC ao 5G do Celular        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Verificar cloudflared
if (-not (Test-Path $CF_PATH)) {
    Write-Host "[ERRO] cloudflared não encontrado em $CF_PATH" -ForegroundColor Red
    Write-Host "       Baixe: https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    Read-Host "Pressione Enter para sair"
    exit 1
}

# Pedir host
Write-Host " Cole o HOST que apareceu no celular:" -ForegroundColor Yellow
Write-Host " (ex: abc-xyz-123.trycloudflare.com)" -ForegroundColor Gray
Write-Host ""
$TUNNEL_HOST = Read-Host "  Host"

if ([string]::IsNullOrWhiteSpace($TUNNEL_HOST)) {
    Write-Host "[ERRO] Host vazio!" -ForegroundColor Red
    exit 1
}

# Limpar host (remover https:// se colou)
$TUNNEL_HOST = $TUNNEL_HOST -replace "https://", "" -replace "http://", "" -replace "/", ""

Write-Host ""
Write-Host "[*] Conectando ao túnel Cloudflare..." -ForegroundColor Yellow
Write-Host "    Host: $TUNNEL_HOST"
Write-Host "    Proxy local: 127.0.0.1:$LOCAL_PORT"
Write-Host ""

# Matar instâncias anteriores
Get-Process -Name "cloudflared*" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

# Iniciar cloudflared
$cfProcess = Start-Process -FilePath $CF_PATH -ArgumentList "access tcp --hostname $TUNNEL_HOST --url 127.0.0.1:$LOCAL_PORT" -PassThru -WindowStyle Hidden

Start-Sleep -Seconds 3

# Verificar se está rodando
if ($cfProcess.HasExited) {
    Write-Host "[ERRO] cloudflared falhou ao iniciar!" -ForegroundColor Red
    Read-Host "Pressione Enter para sair"
    exit 1
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                                                          ║" -ForegroundColor Green
Write-Host "║  ✅ PROXY ATIVO!                                        ║" -ForegroundColor Green
Write-Host "║                                                          ║" -ForegroundColor Green
Write-Host "║  Configure no Fingerprint Manager:                       ║" -ForegroundColor Green
Write-Host "║                                                          ║" -ForegroundColor Green
Write-Host "║  Protocolo: SOCKS5                                       ║" -ForegroundColor Green
Write-Host "║  Host:      127.0.0.1                                    ║" -ForegroundColor Green
Write-Host "║  Porta:     $LOCAL_PORT                                          ║" -ForegroundColor Green
Write-Host "║  Usuário:   5guser                                       ║" -ForegroundColor Green
Write-Host "║  Senha:     senha123                                     ║" -ForegroundColor Green
Write-Host "║                                                          ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host " Pressione Enter para DESCONECTAR..." -ForegroundColor Yellow
Read-Host

# Limpar
Stop-Process -Id $cfProcess.Id -Force -ErrorAction SilentlyContinue
Write-Host "[*] Desconectado." -ForegroundColor Gray
Start-Sleep -Seconds 2
