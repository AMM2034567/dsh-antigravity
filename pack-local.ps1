# Re-pack this fork and (re)install it into the dsh web profile.
#
# Why this exists: the dsh web profile installs this plugin from a *local tarball*
# ("./dist/dsh-antigravity-0.0.4.tgz"), because plain `github:` git dependencies need
# `git ls-remote https://github.com/...` and github.com is unreachable on this machine
# (codeload/api.github.com work, but github.com:443 times out).
#
# Consequence: after ANY edit to lib/*.js you must re-run this script, otherwise the
# profile keeps using the previously packed tarball.
#
# Usage:  pwsh -File .\pack-local.ps1              (profile: web)
#         pwsh -File .\pack-local.ps1 -Profile tui

param(
    [string]$Profile = 'web'
)

$ErrorActionPreference = 'Stop'

$repo = $PSScriptRoot
$dist = Join-Path $repo 'dist'

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
Remove-Item (Join-Path $dist '*.tgz') -Force -ErrorAction SilentlyContinue

Push-Location $repo
try {
    $out = npm pack --pack-destination $dist 2>&1
    $out | Where-Object { $_ -notmatch '^npm notice' } | ForEach-Object { Write-Host $_ }
}
finally { Pop-Location }

$tgz = Get-ChildItem (Join-Path $dist '*.tgz') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $tgz) { throw 'npm pack produced no tarball' }

$spec = 'file:' + ($tgz.FullName -replace '\\', '/')
Write-Host ''
Write-Host ("packed : {0} ({1} bytes)" -f $tgz.Name, $tgz.Length)
Write-Host ("install: {0}" -f $spec)
Write-Host ''

dsh plugin --profile $Profile add $spec
if ($LASTEXITCODE -ne 0) { throw "dsh plugin add failed with exit code $LASTEXITCODE" }

Write-Host ''
Write-Host 'Done. Restart `dsh web` (or `dsh --profile <name>`) for the change to take effect.'
