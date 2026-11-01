[CmdletBinding()]
param(
    [ValidateSet('Install', 'Enable', 'Toggle', 'Status')][string]$Action = 'Install'
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'RemoteAccessProtection.psm1'
try {
    if (-not (Test-Path -LiteralPath $modulePath)) { throw "Required module not found: $modulePath" }
    Import-Module -Name $modulePath -Force -ErrorAction Stop

    if ($env:OS -ne 'Windows_NT') { throw 'This integration runs only on Windows 10/11.' }
    $installRoot = Get-RemoteAccessProtectionInstallRoot
    $isAdmin = Test-RemoteAccessProtectionAdministrator
    $needs64Bit = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
    $expectedController = Join-Path $installRoot 'Invoke-RemoteAccessProtection.ps1'
    $isTrustedController = [string]::Equals(
        [System.IO.Path]::GetFullPath($PSCommandPath),
        [System.IO.Path]::GetFullPath($expectedController),
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if ($Action -eq 'Toggle' -and -not $isTrustedController) {
        throw 'Toggle is available only from the protected Program Files controller installed by -Action Install.'
    }
    if (($Action -in @('Install', 'Enable')) -and -not $isAdmin) {
        throw 'Run Install/Enable from an elevated 64-bit Windows PowerShell session. The extracted package will not self-elevate from a user-writable path.'
    }

    if ($needs64Bit -or ($Action -eq 'Toggle' -and -not $isAdmin)) {
        $systemDirectory = if ($needs64Bit) { 'Sysnative' } else { 'System32' }
        $powershell = Join-Path $env:SystemRoot "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path -LiteralPath $powershell)) { throw "Windows PowerShell was not found: $powershell" }
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $PSCommandPath, $Action
        $startArgs = @{
            FilePath = $powershell
            ArgumentList = $arguments
            Wait = $true
            PassThru = $true
        }
        if ($Action -eq 'Toggle' -and -not $isAdmin) { $startArgs.Verb = 'RunAs' }
        $child = Start-Process @startArgs
        exit $child.ExitCode
    }

    switch ($Action) {
        'Install' { Install-RemoteAccessProtection }
        'Enable' { Enable-RemoteAccessProtection }
        'Toggle' {
            Invoke-RemoteAccessProtectionToggle
            [void](Read-Host 'Press Enter to close')
        }
        'Status' { Show-RemoteAccessProtectionStatus }
    }
    exit 0
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    if ($Action -eq 'Toggle') { [void](Read-Host 'Press Enter to close') }
    exit 1
}
