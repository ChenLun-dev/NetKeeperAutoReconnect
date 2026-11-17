@echo off
setlocal
net session >nul 2>&1
if errorlevel 1 (
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set "EXE=%~dp0校园网断线重连.exe"
if not exist "%EXE%" set "EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
tasklist /fi "imagename eq 校园网断线重连.exe" | find /i "校园网断线重连.exe" >nul
if not errorlevel 1 (
    echo [提示] “校园网断线重连”已在后台运行，无需重复启动。
    timeout /t 3 >nul
    exit /b 0
)
start "" "%SystemRoot%\System32\conhost.exe" --headless "%EXE%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0NetKeeperAutoReconnect.ps1"
echo [完成] 已在后台静默启动，日志见同目录 NetKeeperAutoReconnect.log
timeout /t 3 >nul