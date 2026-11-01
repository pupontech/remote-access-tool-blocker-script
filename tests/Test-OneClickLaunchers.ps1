$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$integration = Join-Path $repoRoot 'integration'
$start = Join-Path $integration 'Start-Here.ps1'
$enginePath = (Get-Process -Id $PID).Path
$startText = Get-Content -LiteralPath $start -Raw
$startErrors = $null
$startTokens = $null
[System.Management.Automation.Language.Parser]::ParseFile($start, [ref]$startTokens, [ref]$startErrors) | Out-Null
if ($startErrors.Count -gt 0) { throw "Start-Here.ps1 parse failed: $($startErrors[0].Message)" }

foreach ($name in 'START-HERE.bat', 'Allow Remote Access.bat') {
    $path = Join-Path $integration $name
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing launcher: $path" }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if (($bytes | Where-Object { $_ -ge 128 }).Count -gt 0) { throw "$name is not ASCII." }
    $lf = @($bytes | Where-Object { $_ -eq 10 }).Count
    $crlf = 0
    for ($i = 1; $i -lt $bytes.Length; $i++) { if ($bytes[$i - 1] -eq 13 -and $bytes[$i] -eq 10) { $crlf++ } }
    if ($lf -ne $crlf) { throw "$name must use CRLF only." }
}

if ($startText -match '(?im)net session') { throw 'Elevation must use the native administrator token, not net session.' }
if ($startText -match '(?im)-Command') { throw 'Launcher must not interpolate paths into -Command.' }
if ($startText -match '\$args') { throw 'Launcher must not provide generic argument forwarding.' }
foreach ($required in @('ElevationAttempted', 'Sysnative', 'WindowsIdentity', '-Verb RunAs', 'Action = ''Install''', 'Type BLOCK to continue', 'ProgramFiles', 'Action Allow')) {
    if ($startText -notmatch [regex]::Escape($required)) { throw "Missing launcher contract: $required" }
}
$allowComment = $startText.IndexOf('# Allow deliberately uses only')
if ($allowComment -lt 0 -or $startText.Substring($allowComment).Contains('$controllerPath')) {
    throw 'Allow must not invoke the source controller.'
}
$allowBat = Get-Content -LiteralPath (Join-Path $integration 'Allow Remote Access.bat') -Raw
if ($allowBat -notmatch '(?i)-Action Allow') { throw 'Allow Remote Access.bat must select Allow.' }

# Safe cancellation: BLOCK is required and must prevent any elevation attempt.
$cancelOutput = @('NO', '') | & $enginePath -NoProfile -File $start -Action Install 2>&1 | Out-String
$cancelCode = $LASTEXITCODE
if ($cancelCode -ne 2) { throw "Expected cancellation exit code 2, got $cancelCode. Output: $cancelOutput" }
if ($cancelOutput -notmatch 'No elevation or installation was attempted') { throw 'Cancellation proof was not displayed.' }

# Safe child error: a copied launcher with its package siblings absent must fail clearly.
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "one-click-launcher-test-$PID"
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $isolated = Join-Path $temp 'Start-Here.ps1'
    Copy-Item -LiteralPath $start -Destination $isolated
    $errorOutput = @('BLOCK', '') | & $enginePath -NoProfile -File $isolated -Action Install 2>&1 | Out-String
    $errorCode = $LASTEXITCODE
    if ($errorCode -eq 0) { throw 'Missing package child path unexpectedly succeeded.' }
    if ($errorOutput -notmatch 'Required package module not found|Required package controller not found') {
        throw "Missing package error was not clear: $errorOutput"
    }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

Write-Host 'One-click launcher tests passed.'
# The final fixture intentionally exits nonzero; do not leak that expected code to CI.
exit 0
