@echo off
setlocal
chcp 65001 >nul
call "%~dp0api_key.cmd"
if not defined AITUNNEL_API_KEY (
    echo API key is not configured. Edit api_key.cmd first.
    pause
    exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI_Console.ps1"
if errorlevel 1 pause
endlocal
