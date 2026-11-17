<#
.SYNOPSIS
    NetKeeper 校园网客户端掉线自动重连守护脚本（秒级检测）。

.DESCRIPTION
    每 1 秒检测 PPPoE 拨号接口，链路正常时再探测外网；
    连续 2 次失败即判定断网：先给客户端 8 秒自愈窗口，
    仍不恢复则断开残留连接 -> 结束 NK.exe -> 启动 NetKeeper.exe 重新拨号，
    并以 0.5 秒粒度轮询等恢复。全程隐藏客户端窗口，动作写入日志。

.NOTES
    必须以管理员身份运行（NetKeeper 客户端清单要求 requireAdministrator）。
#>
[CmdletBinding()]
param(
    # 检测周期（秒），1 秒轮询
    [int]$CheckInterval = 1,
    # 连续检测失败多少次判定断网（2 次 ≈ 2 秒）
    [int]$FailThreshold = 2,
    # 判定断网后先等客户端自行重拨的秒数
    [int]$GraceSeconds = 2,
    # 启动时先等网络确认在线再开始守护的秒数；超时启动一次 NetKeeper 客户端后开始守护；0 = 一直等
    [int]$StartupWaitSeconds = 45,
    # 单轮最多重启客户端几次
    [int]$MaxRestartPerRound = 3,
    # 客户端安装目录（留空则自动探测）
    [string]$NetKeeperDir = '',
    # 拨号连接 / PPP 接口名称（留空则自动探测）
    [string]$RasEntry = '',
    # 外网探测目标（ICMP，任一成功即视为在线）
    [string[]]$PingTargets = @('223.5.5.5', '114.114.114.114'),
    # ICMP 全被拦截时，用该 TCP 目标做二次判断
    [string]$TcpProbeHost = '223.5.5.5',
    [int]$TcpProbePort = 443,
    # 日志文件
    [string]$LogFile,
    # 只检测一次（需要时执行一次重连）后退出，用于测试
    [switch]$Once
)

$ErrorActionPreference = 'Continue'

# 单实例保护：已有守护进程在运行时直接退出
$global:GuardianMutex = New-Object System.Threading.Mutex($false, 'Global\NetKeeperAutoReconnectGuardian')
if (-not $global:GuardianMutex.WaitOne(0)) {
    Write-Host '已有“校园网断线重连”守护进程在运行，本实例退出。'
    exit 0
}

# 全程静默：隐藏自身控制台窗口 + 隐藏 NetKeeper 客户端窗口
Add-Type -Namespace NK -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("wininet.dll")] public static extern bool InternetGetConnectedState(out int lpdwFlags, int dwReserved);
'@ -ErrorAction SilentlyContinue

function Hide-ClientWindow {
    foreach ($p in (Get-Process -Name 'NK', 'NetKeeper' -ErrorAction SilentlyContinue)) {
        $h = $p.MainWindowHandle
        if ($h -ne [IntPtr]::Zero) { [void][NK.Win]::ShowWindow($h, 0) }
    }
}

[void][NK.Win]::ShowWindow([NK.Win]::GetConsoleWindow(), 0)

if (-not $LogFile) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $LogFile = Join-Path $scriptDir 'NetKeeperAutoReconnect.log'
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '[{0}]({1}) : {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) {
            Move-Item $LogFile ($LogFile + '.old') -Force
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
}

function Test-PppLink {
    # PPP 接口存在、处于 Up 且拿到了 IPv4 地址
    try {
        $nic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.Name -eq $RasEntry -and $_.NetworkInterfaceType -eq 'Ppp' } |
            Select-Object -First 1
        if (-not $nic -or $nic.OperationalStatus -ne 'Up') { return $false }

        $hasIpv4 = $nic.GetIPProperties().UnicastAddresses |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.ToString().StartsWith('169.254.') }
        return [bool]$hasIpv4
    } catch {
        return $false
    }
}

function Test-Ping {
    param([string]$Target, [int]$TimeoutMs = 800)
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($Target, $TimeoutMs)
        return ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    } catch {
        return $false
    }
}

function Test-Tcp {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 800)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-Online {
    # 系统层面没有可用连接时直接判离线，省掉等待超时
    $flags = 0
    if (-not [NK.Win]::InternetGetConnectedState([ref]$flags, 0)) { return $false }

    foreach ($t in $PingTargets) {
        if (Test-Ping -Target $t) { return $true }
    }
    return (Test-Tcp -Target $TcpProbeHost -Port $TcpProbePort)
}

function Test-ClientAlive {
    return [bool](Get-Process -Name 'NK' -ErrorAction SilentlyContinue)
}

# 本机 NCSI 探测应答：hosts 已将 www.msftconnecttest.com 指向 127.0.0.1。
# 仅在实际在线时返回预期内容（探测通过，图标显示已连接）；
# 离线时直接中止连接，探测失败，图标如实显示无网。
# 因为不会返回被劫持的错误页面，所以也不会触发浏览器弹窗。
$script:ActualOnline = $false
$script:NcsiListener = $null
$script:NcsiTask = $null
function Initialize-NcsiResponder {
    try {
        $script:NcsiListener = New-Object System.Net.HttpListener
        $script:NcsiListener.Prefixes.Add('http://127.0.0.1:80/')
        $script:NcsiListener.Start()
        $script:NcsiTask = $script:NcsiListener.GetContextAsync()
        Write-Log 'NCSI 本机探测应答已启动（127.0.0.1:80）'
    } catch {
        Write-Log "NCSI 本机探测应答启动失败：$($_.Exception.Message)" 'WARN'
        $script:NcsiListener = $null
    }
}
function Respond-NcsiProbe {
    if (-not $script:NcsiListener) { return }
    try {
        if ($script:NcsiTask -and $script:NcsiTask.IsCompleted) {
            $ctx = $script:NcsiTask.Result
            if ($script:ActualOnline) {
                $bytes = [Text.Encoding]::ASCII.GetBytes('Microsoft Connect Test')
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = 'text/plain'
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.Close()
            } else {
                # 实际无网：中止连接让探测失败，图标显示无网（不返回错误页面，避免门户弹窗）
                $ctx.Response.Abort()
            }
            $script:NcsiTask = $script:NcsiListener.GetContextAsync()
        }
    } catch {
        try { $script:NcsiTask = $script:NcsiListener.GetContextAsync() } catch {}
    }
}

function Stop-Client {
    $names = @('NK', 'NetKeeper')
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
                Write-Log "已结束进程 $n (PID $($_.Id))"
            } catch {
                Write-Log "结束进程 $n 失败：$($_.Exception.Message)" 'ERROR'
            }
        }
    }
    Start-Sleep -Milliseconds 800
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
        }
    }
}

function Wait-Online {
    param([int]$TimeoutSeconds = 60)
    # 0.5 秒一次快速轮询，恢复即返回
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        Hide-ClientWindow
        if ((Test-PppLink) -and (Test-Online)) { return $true }
    }
    return $false
}

function Invoke-Reconnect {
    param([int]$Attempt)
    Write-Log "第 $Attempt 次重连：重置拨号连接 $RasEntry"
    try { & rasdial $RasEntry /disconnect 2>$null | Out-Null } catch {}

    Stop-Client

    $exe = Join-Path $NetKeeperDir 'NetKeeper.exe'
    if (-not (Test-Path $exe)) {
        Write-Log "找不到客户端启动程序：$exe" 'ERROR'
        return $false
    }

    Write-Log "启动客户端：$exe"
    try {
        Start-Process -FilePath $exe -WorkingDirectory $NetKeeperDir | Out-Null
    } catch {
        Write-Log "启动客户端失败：$($_.Exception.Message)" 'ERROR'
        return $false
    }

    # 等待 NK.exe 起来，期间持续隐藏其窗口
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not (Test-ClientAlive)) {
        Hide-ClientWindow
        Start-Sleep -Milliseconds 300
    }

    if (Wait-Online -TimeoutSeconds 60) {
        Write-Log '重连成功，网络已恢复' 'INFO'
        return $true
    }
    Write-Log '本次重连后仍未恢复联网' 'WARN'
    return $false
}

# ---------- 入口 ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log '当前不是管理员权限，无法结束/启动 NetKeeper 客户端。请右键“以管理员身份运行”。' 'ERROR'
    exit 1
}

# ---------- 环境自动适配（换电脑无需改参数） ----------
function Find-NetKeeperDir {
    # 1) 正在运行的客户端进程路径最可靠（NK.exe 可能在 run\ 子目录，向上找到安装根目录）
    $p = Get-Process -Name 'NK', 'NetKeeper' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path) {
        $dir = Split-Path -Parent $p.Path
        for ($i = 0; $i -lt 4 -and $dir; $i++) {
            if (Test-Path (Join-Path $dir 'NetKeeper.exe')) { return $dir }
            $parent = Split-Path -Parent $dir
            if ($parent -eq $dir) { break }
            $dir = $parent
        }
    }
    # 2) 注册表卸载项
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($item in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $loc = (Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue).InstallLocation
            if ($loc) {
                $loc = $loc.Trim().Trim('"').TrimEnd('\')
                if ($loc -and (Test-Path (Join-Path $loc 'NetKeeper.exe'))) { return $loc }
            }
        }
    }
    # 3) 各固定盘常见安装位置
    $drives = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
    foreach ($drive in $drives) {
        foreach ($sub in @('Program Files\NetKeeper', 'Program Files (x86)\NetKeeper', 'NetKeeper')) {
            $p = Join-Path $drive.Name $sub
            if (Test-Path (Join-Path $p 'NetKeeper.exe')) { return $p }
        }
    }
    # 4) 最后兜底：固定盘浅层搜索（最多 3 层目录，避免全盘扫描）
    foreach ($drive in $drives) {
        $hit = Get-ChildItem $drive.Name -Filter 'NetKeeper.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.DirectoryName }
    }
    return $null
}

function Find-RasEntry {
    # 1) 当前 PPP 接口名
    $name = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.NetworkInterfaceType -eq 'Ppp' } | Select-Object -First 1 -ExpandProperty Name
    if ($name) { return $name }
    # 2) rasdial 报告的已连接项
    $name = (rasdial 2>$null | Select-String '已连接|Connected' |
        ForEach-Object { ($_ -split '\s{2,}')[0].Trim() } | Select-Object -First 1)
    if ($name) { return $name }
    # 3) 电话簿（从未拨号过的新机器也能读到已保存的连接名）
    foreach ($pbk in @("$env:APPDATA\Microsoft\Network\Connections\Pbk\rasphone.pbk",
                       "$env:ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk")) {
        if (Test-Path $pbk) {
            $entry = Get-Content $pbk -Encoding Unicode -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^\[.+\]$' } | Select-Object -First 1
            if ($entry) { return $entry.Trim('[', ']') }
        }
    }
    return 'Netkeeper'
}

if (-not $NetKeeperDir) { $NetKeeperDir = Find-NetKeeperDir }
if (-not $NetKeeperDir -or -not (Test-Path (Join-Path $NetKeeperDir 'NetKeeper.exe'))) {
    Write-Log '未找到 NetKeeper 客户端，可用 -NetKeeperDir 手动指定安装目录' 'ERROR'
    exit 1
}
if (-not $RasEntry) { $RasEntry = Find-RasEntry }

# ---------- NCSI 系统配置（本机探测应答 + 2 秒被动轮询） ----------
function Initialize-NcsiConfig {
    try {
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
        Set-ItemProperty $k -Name EnableActiveProbing -Value 1
        Set-ItemProperty $k -Name ActiveWebProbeHost -Value 'www.msftconnecttest.com'
        Set-ItemProperty $k -Name ActiveWebProbePath -Value 'connecttest.txt'
        Set-ItemProperty $k -Name ActiveWebProbeContent -Value 'Microsoft Connect Test'
        New-ItemProperty $k -Name PassivePollPeriod -PropertyType DWord -Value 2 -Force | Out-Null
        $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
        $content = Get-Content $hosts -Raw -ErrorAction SilentlyContinue
        if ($content -notmatch 'www\.msftconnecttest\.com') {
            Add-Content $hosts "`r`n127.0.0.1 www.msftconnecttest.com" -Encoding ASCII
            Write-Log '已写入 hosts：127.0.0.1 www.msftconnecttest.com'
        }
    } catch { Write-Log "NCSI 配置写入失败：$($_.Exception.Message)" 'WARN' }
}
Initialize-NcsiConfig

Write-Log ("守护启动：检测周期 {0}s，失败阈值 {1} 次，自愈等待 {2}s，拨号连接 {3}，客户端 {4}" -f $CheckInterval, $FailThreshold, $GraceSeconds, $RasEntry, $NetKeeperDir)

# 先等网络首次确认在线，再开始守护（NetKeeper 自启拨号期间只观察、不干预）
Initialize-NcsiResponder
# 开机时 Windows 可能沿用上次的“已连接”缓存状态，这里强制重新探测一次，
# 由本机应答按当前真实状态（未联网）回答，避免开机误报有网
Write-Log '启动时刷新 NCSI，清除缓存的网络状态'
Restart-Service NlaSvc -Force -ErrorAction SilentlyContinue
$waitDeadline = if ($StartupWaitSeconds -gt 0) { (Get-Date).AddSeconds($StartupWaitSeconds) } else { $null }
Write-Log '等待网络确认在线，之后开始守护'
while ($true) {
    Hide-ClientWindow
    $lu = Test-PppLink
    $script:ActualOnline = $false
    if ($lu) { $script:ActualOnline = Test-Online }
    Respond-NcsiProbe
    if ($script:ActualOnline) {
        Write-Log '已确认网络在线，开始守护'
        break
    }
    if ($waitDeadline -and (Get-Date) -ge $waitDeadline) {
        Write-Log "等待 $StartupWaitSeconds 秒仍未在线，启动一次 NetKeeper 客户端后开始守护" 'WARN'
        $exe = Join-Path $NetKeeperDir 'NetKeeper.exe'
        if (-not (Test-ClientAlive) -and (Test-Path $exe)) {
            try {
                Start-Process -FilePath $exe -WorkingDirectory $NetKeeperDir | Out-Null
                Write-Log "启动客户端：$exe"
            } catch {
                Write-Log "启动客户端失败：$($_.Exception.Message)" 'ERROR'
            }
        }
        break
    }
    if ($Once) { Write-Log '检测结果：离线（等待在线中，不干预）'; exit 0 }
    Start-Sleep -Seconds 1
}

$failCount = 0
$restartCount = 0

while ($true) {
    Hide-ClientWindow

    $linkOk = Test-PppLink
    $online = $false
    if ($linkOk) { $online = Test-Online }
    $script:ActualOnline = $online
    Respond-NcsiProbe

    if ($online) {
        if ($failCount -gt 0) { Write-Log '网络恢复正常' 'INFO' }
        $failCount = 0
        $restartCount = 0
        if ($Once) { Write-Log '检测结果：在线'; exit 0 }
        Start-Sleep -Milliseconds (1000 * $CheckInterval)
        continue
    }

    # 链路已断属于确定性故障，立即判定；链路在但外网不通则需连续 2 次
    if ($linkOk) { $failCount++ } else { $failCount = $FailThreshold }

    if ($failCount -lt $FailThreshold) {
        Start-Sleep -Milliseconds (1000 * $CheckInterval)
        continue
    }

    $reason = if (-not $linkOk) { "拨号连接 $RasEntry 未连接" } else { '拨号已连接但外网不通' }
    Write-Log ("判定断网：{0}" -f $reason) 'WARN'

    # 链路已断时客户端自己重拨也要数秒，直接重启更快；仅“链路在但外网不通”才留自愈窗口
    $grace = if (Test-PppLink) { $GraceSeconds } else { 0 }
    if (Test-ClientAlive -and $grace -gt 0) {
        $graceDeadline = (Get-Date).AddSeconds($grace)
        while ((Get-Date) -lt $graceDeadline) {
            Start-Sleep -Milliseconds 500
            Hide-ClientWindow
            if ((Test-PppLink) -and (Test-Online)) { $online = $true; break }
            if (-not (Test-ClientAlive)) { break }
        }
        if ($online) {
            Write-Log '客户端已自行重拨成功' 'INFO'
            $failCount = 0
            $restartCount = 0
            if ($Once) { exit 0 }
            continue
        }
    }

    if ($restartCount -ge $MaxRestartPerRound) {
        Write-Log '本轮重启次数已达上限，等待 5 分钟后重新尝试' 'ERROR'
        Start-Sleep -Seconds 300
        $restartCount = 0
        $failCount = 0
        continue
    }

    $restartCount++
    if (Invoke-Reconnect -Attempt $restartCount) {
        $failCount = 0
        $restartCount = 0
        if ($Once) { exit 0 }
    } elseif ($restartCount -ge $MaxRestartPerRound) {
        Write-Log '本轮重连全部失败，等待 5 分钟后重新尝试' 'ERROR'
        Start-Sleep -Seconds 300
        $restartCount = 0
        $failCount = 0
    } else {
        Start-Sleep -Seconds 10
    }
}
