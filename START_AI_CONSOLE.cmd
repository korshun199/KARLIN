@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0api_key.cmd" (
    echo Copy api_key.cmd.example to api_key.cmd and add your API key.
    pause
    exit /b 1
)
call "%~dp0api_key.cmd"
if not defined AITUNNEL_API_KEY (
    echo API key is not configured. Edit api_key.cmd first.
    pause
    exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI_Console.ps1"
if errorlevel 1 pause
endlocal
