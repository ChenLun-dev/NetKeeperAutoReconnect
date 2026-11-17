[CmdletBinding()]
param([string]$TaskName = 'NetKeeper自动重连')
$ErrorActionPreference = 'Continue'

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Get-Process -Name '校园网断线重连' -ErrorAction SilentlyContinue | Stop-Process -Force

# 移除本机 NCSI 应答配置，恢复系统默认
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$lines = Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch 'www\.msftconnecttest\.com' }
if ($lines) { Set-Content $hosts $lines -Encoding ASCII }
Remove-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet' -Name PassivePollPeriod -ErrorAction SilentlyContinue
Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue

Write-Host "已卸载：计划任务 $TaskName、hosts 探测指向、PassivePollPeriod 自定义值均已移除。" -ForegroundColor Green
