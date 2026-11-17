# NetKeeper 校园网断线重连

Windows 下 NetKeeper（闪讯）校园网客户端的守护脚本：秒级检测掉线并自动重连，
同时让任务栏网络图标**实时、准确**地反映真实联网状态，全程无窗口、无弹窗。
解压即用，无需安装任何依赖、无需修改任何参数。
**实际使用环境为山东财经大学燕山学院**

## 功能

- **秒级重连**：每 1 秒检测拨号链路与外网连通性，链路断开立即重连，实测断线到恢复约 4 秒。
- **开机无感**：启动后先等 NetKeeper 自启拨号完成再开始守护，不会误杀客户端造成二次拨号；
  45 秒仍无网才主动启动一次客户端兜底（可用 `-StartupWaitSeconds` 调整）。
- **图标准确**：通过本机 NCSI 探测应答 + 2 秒被动轮询，联网/断网图标几秒内同步，
  不会再出现"有网显示无网"或"没网显示有网"。
- **永不弹窗**：探测应答由本机返回，校园门户无法劫持出 `msftconnecttest.com` 浏览器页；
  客户端登录页/广告窗口持续隐藏。
- **静默运行**：`conhost --headless` 承载，无控制台窗口；可选改名 exe 让进程名显示为"校园网断线重连"。
- **任意电脑即用**：自动探测 NetKeeper 安装目录（进程 → 注册表 → 常见路径 → 浅层搜索）
  与拨号连接名（PPP 接口 → rasdial → 电话簿），新机器也无需配置。
- 单实例互斥、日志自动轮转（>5MB 改名 .old）。

## 环境要求

- Windows 10 / 11，PowerShell 5.1（系统自带）
- 已安装 NetKeeper 客户端，并至少成功拨号过一次
- 管理员权限（启动器会自动请求 UAC）

## 快速开始

| 操作 | 文件 |
|---|---|
| 双击启动守护（推荐先这样试用） | `启动自动重连.cmd` |
| 注册开机自启并立即启动 | `安装开机自启.cmd` |
| 取消开机自启并还原系统配置 | `卸载开机自启.cmd` |

也可以命令行运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\NetKeeperAutoReconnect.ps1          # 持续守护
powershell -ExecutionPolicy Bypass -File .\NetKeeperAutoReconnect.ps1 -Once    # 只检测一次，用于测试
```

## 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-CheckInterval` | `1` | 检测周期（秒） |
| `-FailThreshold` | `2` | 外网探测连续失败几次判定断网 |
| `-GraceSeconds` | `2` | 判定断网后给客户端的自愈等待 |
| `-StartupWaitSeconds` | `45` | 启动时等待在线的秒数，超时启动一次客户端；`0` = 一直等 |
| `-MaxRestartPerRound` | `3` | 单轮最多重启客户端次数，失败后 5 分钟再试 |
| `-NetKeeperDir` | 自动探测 | 客户端安装目录 |
| `-RasEntry` | 自动探测 | 拨号连接名（`rasdial` 中显示的名字） |
| `-PingTargets` | `223.5.5.5, 114.114.114.114` | ICMP 探测目标 |
| `-TcpProbeHost` / `-TcpProbePort` | `223.5.5.5` / `443` | ICMP 被拦时的 TCP 兜底探测 |
| `-LogFile` | 脚本同目录 `.log` | 日志路径 |
| `-Once` | — | 只检测一次后退出 |

## 工作原理

1. **链路检测**：PPP 接口存在、Up 且拿到 IPv4 即视为链路正常；链路断开是确定性故障，立即重连。
2. **外网探测**：ping 阿里/114 DNS，ICMP 全被拦时用 TCP 443 兜底。
3. **重连动作**：`rasdial <连接> /disconnect` 清残留 → 结束 `NK.exe` → 启动 `NetKeeper.exe`
   （客户端用已保存的账号自动拨号，脚本不接触任何密码）→ 0.5 秒轮询等恢复。
4. **网络图标**：脚本在 `127.0.0.1:80` 应答 Windows 的 NCSI 探测——实际在线时返回
   `Microsoft Connect Test`，离线时直接中止连接。配合 hosts 指向与 `PassivePollPeriod=2`，
   图标始终跟随真实网络状态，且门户无法触发浏览器弹窗。

### 对系统的修改（卸载脚本可全部还原）

- 计划任务 `NetKeeper自动重连`：用户登录后 5 秒、最高权限、静默启动守护。
- hosts：追加 `127.0.0.1 www.msftconnecttest.com`。
- 注册表 `HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet`：
  启用主动探测（默认配置）并新增 `PassivePollPeriod=2`。

## 进程名（可选）

想让任务管理器里显示"校园网断线重连"而不是 powershell：

```powershell
Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" ".\校园网断线重连.exe"
```

它只是 powershell 的副本改名，无副作用；启动器和安装脚本检测到它时会优先使用。

## 日志与排错

日志位于脚本同目录 `NetKeeperAutoReconnect.log`，记录守护启动、掉线判定、重连动作、恢复结果。
临时想看客户端界面：先停止守护（`Stop-ScheduledTask -TaskName 'NetKeeper自动重连'`），
手动打开 NetKeeper 即可。

## 免责声明

仅用于本人校园网账号的自动重连，不包含也不应被用于共享上网、破解或绕过认证。
