<#
  启动 dsh web，并自动解决代理问题。

  为什么需要这个脚本
  ------------------
  Node 的 fetch（undici）**完全不读 Windows 系统代理，也不读 PAC**，只认环境变量；
  而且 Node <= 23 即使设了 HTTPS_PROXY 也默认忽略。所以：

      node fetch 直连                                    -> ETIMEDOUT
      node fetch + HTTPS_PROXY（不开开关）                -> ETIMEDOUT
      node fetch + HTTPS_PROXY + NODE_USE_ENV_PROXY=1     -> 200

  NODE_USE_ENV_PROXY=1 是 Node 24+ 的开关。
  注意：打开系统「使用代理服务器」开关没用，PAC 也没用；
  只有 TUN / 全局模式（网络层透明拦截）才能绕过 —— 所以用了 Cloudflare WARP 的 TUN 模式时，
  这个脚本会检测到直连可用，什么都不设。

  脚本做什么
  ----------
  1. 用 node 实测「直连」能不能到 Google（这一步用的是 dsh 真正会走的链路，最准）。
     能通 -> 说明 TUN/全局模式已生效，直接启动，不设任何代理变量。
  2. 不通 -> 枚举本机代理进程（xray / v2rayN / FlClash / Clash / WARP / sing-box ...）
     占用的监听端口，加上几个常见端口，逐个用 node 实测，选第一个真能通的。
     （SOCKS5 端口会被自动跳过 —— undici 不支持 SOCKS。）
  3. 都没通 -> 打印诊断信息（含 warp-cli 状态）后退出，不启动一个注定失败的服务器。

  用法
  ----
      双击  start-dsh-web.cmd
      或：  pwsh -File .\start-dsh-web.ps1

      .\start-dsh-web.ps1 -DetectOnly                 # 只做检测，不启动
      .\start-dsh-web.ps1 -Proxy http://127.0.0.1:10809
      .\start-dsh-web.ps1 -Port 3081 -NoBrowser
      .\start-dsh-web.ps1 -WorkingDirectory D:\myproject
#>

[CmdletBinding()]
param(
    # 手动指定代理，例如 http://127.0.0.1:10809。不指定则自动检测。
    [string]$Proxy,

    # dsh web 的工作目录
    [string]$WorkingDirectory = $env:USERPROFILE,

    # 要启动的 profile（默认 web）
    [string]$Profile = 'web',

    [int]$Port = 3080,

    # 不自动打开浏览器
    [switch]$NoBrowser,

    # 只检测代理，不启动服务
    [switch]$DetectOnly
)

$ErrorActionPreference = 'Stop'

function Write-Head([string]$text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Write-Ok([string]$text)   { Write-Host "   $text" -ForegroundColor Green }
function Write-Bad([string]$text)  { Write-Host "   $text" -ForegroundColor DarkGray }

# ---- 探测用的 JS：走 dsh 真正会用的那条链路 ----------------------------------
$ProbeJs = @'
const url = 'https://www.google.com/generate_204';
fetch(url, { signal: AbortSignal.timeout(5000) })
  .then((r) => process.exit(r.ok ? 0 : 1))
  .catch(() => process.exit(1));
'@

function Test-NodeFetch {
    param([string]$ProxyUrl)

    $savedHttp  = $env:HTTP_PROXY
    $savedHttps = $env:HTTPS_PROXY
    $savedSwitch = $env:NODE_USE_ENV_PROXY

    try {
        if ($ProxyUrl) {
            $env:HTTP_PROXY         = $ProxyUrl
            $env:HTTPS_PROXY        = $ProxyUrl
            $env:NODE_USE_ENV_PROXY = '1'
        }
        else {
            $env:HTTP_PROXY         = $null
            $env:HTTPS_PROXY        = $null
            $env:NODE_USE_ENV_PROXY = $null
        }

        & node -e $ProbeJs 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        $env:HTTP_PROXY         = $savedHttp
        $env:HTTPS_PROXY        = $savedHttps
        $env:NODE_USE_ENV_PROXY = $savedSwitch
    }
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host '找不到 node，请先确认 Node.js 已加入 PATH。' -ForegroundColor Red
    exit 1
}

$chosen   = $null   # 空字符串表示「直连可用，不设代理」
$detected = @()

# ---- 1. 直连 -----------------------------------------------------------------
Write-Head '1. 检测直连（TUN / 全局模式是否生效）'
if (Test-NodeFetch) {
    Write-Ok '直连可用 —— TUN/全局模式已生效，不需要代理变量'
    $chosen = ''
}
else {
    Write-Bad '直连不通（预期之中，除非你的代理开了 TUN 模式）'

    # ---- 2. 探测代理 ---------------------------------------------------------
    Write-Head '2. 探测本机可用的 HTTP 代理'

    $proxyProcPattern = 'xray|v2ray|mihomo|clash|verge|flclash|sing-box|singbox|warp|hiddify|nekoray|surge|tun2socks'

    if ($Proxy) {
        $detected = @($Proxy)
        Write-Host "   使用 -Proxy 指定的地址"
    }
    else {
        $dynamic = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in '127.0.0.1', '0.0.0.0', '::', '::1' } |
            ForEach-Object {
                $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -match $proxyProcPattern) {
                    [pscustomobject]@{ Port = $_.LocalPort; Proc = $proc.ProcessName }
                }
            } |
            Sort-Object Port -Unique

        $detected = @($dynamic | ForEach-Object { "http://127.0.0.1:$($_.Port)" })
        # 常见端口兜底
        $detected += @('http://127.0.0.1:10809', 'http://127.0.0.1:7890', 'http://127.0.0.1:7897',
                       'http://127.0.0.1:10812', 'http://127.0.0.1:1080', 'http://127.0.0.1:2080',
                       'http://127.0.0.1:40000')
        $detected = $detected | Select-Object -Unique
    }

    foreach ($candidate in $detected) {
        Write-Host ("   测试 {0,-30}" -f $candidate) -NoNewline
        if (Test-NodeFetch $candidate) {
            Write-Host ' 可用' -ForegroundColor Green
            $chosen = $candidate
            break
        }
        Write-Host ' 不通' -ForegroundColor DarkGray
    }
}

# ---- 3. 结论 -----------------------------------------------------------------
if ($null -eq $chosen) {
    Write-Head '失败：没有找到可用的网络路径'
    Write-Host '   已尝试的候选：' -ForegroundColor Yellow
    $detected | ForEach-Object { Write-Host "     $_" }

    $warpCli = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'
    if (Test-Path $warpCli) {
        Write-Host ''
        Write-Host '   Cloudflare WARP 状态：' -ForegroundColor Yellow
        (& $warpCli --accept-tos status 2>&1) | ForEach-Object { Write-Host "     $_" }
        Write-Host '   如果 WARP 显示 Disconnected，连上它（推荐 TUN 模式）再运行本脚本。'
    }

    Write-Host ''
    Write-Host '   其他可能：xray/v2rayN/FlClash 没启动，或节点本身失效。'
    Write-Host '   也可以手动指定：  .\start-dsh-web.ps1 -Proxy http://127.0.0.1:10809'
    exit 1
}

if ($chosen) {
    Write-Ok "将使用代理 $chosen"
    $env:HTTP_PROXY         = $chosen
    $env:HTTPS_PROXY        = $chosen
    $env:NODE_USE_ENV_PROXY = '1'
    # 国内镜像排除在代理之外，否则 pnpm / npm 会变慢甚至失败
    $env:NO_PROXY           = 'localhost,127.0.0.1,registry.npmmirror.com,cdn.npmmirror.com'
}
else {
    $env:HTTP_PROXY         = $null
    $env:HTTPS_PROXY        = $null
    $env:NODE_USE_ENV_PROXY = $null
}

if ($DetectOnly) {
    Write-Head '仅检测模式，不启动服务'
    exit 0
}

# ---- 4. 启动 -----------------------------------------------------------------
Write-Head '3. 启动 dsh web'
if (-not (Test-Path $WorkingDirectory)) {
    Write-Host "   工作目录不存在：$WorkingDirectory" -ForegroundColor Red
    exit 1
}
Set-Location $WorkingDirectory
Write-Host "   工作目录 : $WorkingDirectory"
Write-Host "   profile  : $Profile"
Write-Host "   端口     : $Port"

# 端口占用检查：忘了关上一个实例是最常见的失败原因。
$busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($busy) {
    $owner = Get-Process -Id $busy.OwningProcess -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host "   端口 $Port 已被占用（pid $($busy.OwningProcess) $(if ($owner) { $owner.ProcessName } else { '?' })）" -ForegroundColor Yellow
    Write-Host '   先关掉那个实例，或者换一个端口：'
    Write-Host "     .\start-dsh-web.ps1 -Port $($Port + 1)"
    exit 1
}

Write-Host ''

$dshArgs = if ($Profile -eq 'web') { @('web') } else { @('--profile', $Profile) }
$dshArgs += @('--port', "$Port")
if ($NoBrowser) { $dshArgs += '--no-open' }

& dsh @dshArgs
