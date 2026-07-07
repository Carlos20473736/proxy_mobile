@echo off
chcp 65001 >nul
title 5G-SHARE - Conectando ao Celular

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║    5G-SHARE v5.0 - Conectar PC ao 5G do Celular        ║
echo ╚══════════════════════════════════════════════════════════╝
echo.

:: Verificar se cloudflared existe
if not exist "C:\cloudflared\cloudflared-windows-amd64.exe" (
    echo [ERRO] cloudflared nao encontrado em C:\cloudflared\
    echo        Baixe de: https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe
    echo        Coloque em C:\cloudflared\
    pause
    exit /b 1
)

:: Pedir o host do túnel
echo  Cole o HOST que apareceu no celular:
echo  (ex: abc-xyz-123.trycloudflare.com)
echo.
set /p TUNNEL_HOST="  Host: "

if "%TUNNEL_HOST%"=="" (
    echo [ERRO] Host vazio!
    pause
    exit /b 1
)

:: Porta local
set LOCAL_PORT=1080

echo.
echo [*] Conectando ao tunel Cloudflare...
echo     Host: %TUNNEL_HOST%
echo     Proxy local: 127.0.0.1:%LOCAL_PORT%
echo.

:: Matar instâncias anteriores
taskkill /f /im cloudflared-windows-amd64.exe >nul 2>&1
timeout /t 1 >nul

:: Iniciar cloudflared access
echo [*] Iniciando cloudflared...
start /b "" "C:\cloudflared\cloudflared-windows-amd64.exe" access tcp --hostname %TUNNEL_HOST% --url 127.0.0.1:%LOCAL_PORT%

timeout /t 3 >nul

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║                                                          ║
echo ║  ✅ PROXY ATIVO!                                        ║
echo ║                                                          ║
echo ║  Configure no Fingerprint Manager:                       ║
echo ║                                                          ║
echo ║  Protocolo: SOCKS5                                       ║
echo ║  Host:      127.0.0.1                                    ║
echo ║  Porta:     %LOCAL_PORT%                                          ║
echo ║  Usuário:   5guser                                       ║
echo ║  Senha:     senha123                                     ║
echo ║                                                          ║
echo ╚══════════════════════════════════════════════════════════╝
echo.
echo  Pressione qualquer tecla para DESCONECTAR...
pause >nul

:: Limpar
taskkill /f /im cloudflared-windows-amd64.exe >nul 2>&1
echo.
echo [*] Desconectado.
timeout /t 2 >nul
