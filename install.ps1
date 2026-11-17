[CmdletBinding()]
param(
    [string]$TaskName = 'NetKeeper自动重连',
    [string]$Delay = 'PT5S'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps1 = Join-Path $root 'NetKeeperAutoReconnect.ps1'
if (-not (Test-Path $ps1)) { Write-Host "未找到 $ps1" -ForegroundColor Red; exit 1 }

# 有改名版 powershell 就用它（进程名更直观），否则用系统 powershell
$exe = Join-Path $root '校园网断线重连.exe'
if (-not (Test-Path $exe)) { $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
    -Argument "--headless `"$exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = $Delay
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "已注册并启动计划任务：$TaskName（登录后 $Delay 触发，最高权限，全程静默）" -ForegroundColor Green
