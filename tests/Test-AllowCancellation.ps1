$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'integration/RemoteAccessProtection.psm1') -Force
$m=Get-Module RemoteAccessProtection
& $m {
    function script:Get-InstalledRemoteAccessProtectionInstaller {param($InstallRoot) '/fixture/engine.ps1'}
    function script:Test-Path {param($LiteralPath) $true}
    function script:Start-Process {param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,[switch]$NoNewWindow) [pscustomobject]@{ExitCode=6}}
    $caught=$null
    try {Invoke-RemoteAccessProtectionInstaller -Mode Remove -InstallRoot '/fixture'} catch {$caught=$_.Exception}
    if($caught -isnot [OperationCanceledException]){throw 'A refused warning must be cancellation, not an install failure.'}
}
Write-Host 'PASS: refusing a native warning is cancellation, not a failure popup.'
