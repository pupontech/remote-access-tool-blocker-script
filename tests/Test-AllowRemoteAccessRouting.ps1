$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'integration/RemoteAccessProtection.psm1') -Force
$m = Get-Module RemoteAccessProtection
if (-not (Get-Command Invoke-RemoteAccessProtectionAllow -ErrorAction SilentlyContinue)) { throw 'Named Allow Remote Access action is missing.' }
& $m {
    function script:Assert-RemoteAccessProtectionWindows {}
    function script:Test-RemoteAccessProtectionAdministrator { $true }
    function script:Get-RemoteAccessProtectionInstallRoot { '/synthetic/install-root' }
    function script:Get-RemoteAccessProtectionState { [pscustomobject]@{State=$script:FakeState;Reason='fixture'} }
    function script:Set-RemoteAccessProtection { param($State,$InstallRoot) $script:Requested += $State }
    foreach ($state in 'Blocked','Unblocked','Unknown') {
        $script:FakeState=$state; $script:Requested=@();$refused=$false
        try { Invoke-RemoteAccessProtectionAllow } catch { $refused=$true }
        if ($state -eq 'Blocked' -and ($script:Requested -join ',') -ne 'Unblocked') { throw 'Allow did not request removal.' }
        if ($state -ne 'Blocked' -and $script:Requested.Count) { throw 'Allow changed an unblocked/unknown state.' }
        if (($state -eq 'Unknown') -ne $refused) { throw 'Unknown-state refusal mismatch.' }
    }
}
Write-Host 'PASS: Allow requests only removal, never enables protection, and refuses unknown state.'
