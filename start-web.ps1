<#
    Start `dsh web` with the proxy environment that Node actually needs.

    Why this is required on this machine
    ------------------------------------
    Node's fetch() (undici) ignores the Windows system proxy and the PAC file entirely.
    It only reads environment variables, and even then Node <= 23 ignores HTTPS_PROXY
    unless NODE_USE_ENV_PROXY=1 (Node 24+).

    Without this wrapper, requests to *.googleapis.com fail with ETIMEDOUT after ~300ms
    and the Antigravity plugin only reports "fetch failed" (code=undefined).

    Measured on this machine (Node v24.14.1):

        node fetch, direct                              -> ETIMEDOUT
        node fetch + HTTPS_PROXY (no env-proxy switch)  -> ETIMEDOUT
        node fetch + HTTPS_PROXY + NODE_USE_ENV_PROXY=1 -> 200

    Note: turning on the system proxy toggle is NOT enough, and neither is PAC.
    Only TUN/global mode (transparent interception) would avoid this wrapper.

    Usage
    -----
        .\start-web.ps1                      # http://127.0.0.1:3080, no browser
        .\start-web.ps1 -OpenBrowser
        .\start-web.ps1 -Port 3081
        .\start-web.ps1 -Proxy http://127.0.0.1:7890
        .\start-web.ps1 -Profile tui
#>

param(
    [string]$Proxy   = 'http://127.0.0.1:10809',
    [string]$Profile = 'web',
    [int]$Port       = 3080,
    [switch]$OpenBrowser
)

$ErrorActionPreference = 'Stop'

$env:HTTP_PROXY         = $Proxy
$env:HTTPS_PROXY        = $Proxy
$env:NODE_USE_ENV_PROXY = '1'
# Keep domestic mirrors off the proxy, otherwise pnpm/npm get slower or break.
$env:NO_PROXY           = 'localhost,127.0.0.1,registry.npmmirror.com,cdn.npmmirror.com'

Write-Host "proxy   : $Proxy"
Write-Host "profile : $Profile"
Write-Host "port    : $Port"
Write-Host ''

$dshArgs = if ($Profile -eq 'web') { @('web') } else { @('--profile', $Profile) }
$dshArgs += @('--port', "$Port")
if (-not $OpenBrowser) { $dshArgs += '--no-open' }

& dsh @dshArgs
