[CmdletBinding()]
param(
    [ValidateSet('Install', 'Allow')][string]$Action = 'Install',
    [switch]$ElevationAttempted
)

$ErrorActionPreference = 'Stop'

function Show-OneClickError {
    param([string]$Message)
    Write-Host ('ERROR: ' + $Message) -ForegroundColor Red
    if ($env:OS -eq 'Windows_NT') {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($Message, 'Remote Access Protection - Error', 'OK', 'Error')
        } catch { Write-Host 'The error dialog could not be displayed.' -ForegroundColor Red }
    }
}

function Get-NativeWindowsPowerShell {
    if (-not $env:SystemRoot) { throw 'Windows PowerShell could not be located because SystemRoot is not set.' }
    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $path = Join-Path $env:SystemRoot "$systemDirectory\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $path)) { throw "Windows PowerShell was not found: $path" }
    $path
}

function Test-NativeAdministrator {
    if ($env:OS -ne 'Windows_NT') { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function ConvertTo-NativeArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    '"{0}"' -f $Value
}

function Invoke-SelfElevated {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    $powershell = Get-NativeWindowsPowerShell
    $argumentLine = '-NoProfile -STA -ExecutionPolicy Bypass -File {0} -Action Install -ElevationAttempted' -f (ConvertTo-NativeArgument $ScriptPath)
    $child = Start-Process -FilePath $powershell -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
    if ($null -eq $child) { throw 'The elevated setup process did not start.' }
    $child.ExitCode
}

function Invoke-Controller {
    param(
        [Parameter(Mandatory = $true)][string]$ControllerPath,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Allow')][string]$ControllerAction
    )
    $powershell = Get-NativeWindowsPowerShell
    $argumentLine = '-NoProfile -STA -ExecutionPolicy Bypass -File {0} -Action {1}' -f (ConvertTo-NativeArgument $ControllerPath), (ConvertTo-NativeArgument $ControllerAction)
    $child = Start-Process -FilePath $powershell -ArgumentList $argumentLine -Wait -PassThru
    if ($null -eq $child) { throw 'The protection controller did not start.' }
    $child.ExitCode
}

function Get-InstalledControllerPath {
    $programFiles = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $env:ProgramW6432 } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles) }
    if (-not $programFiles) { throw 'Program Files directory could not be resolved.' }
    Join-Path (Join-Path $programFiles 'RemoteAccessToolBlocker') 'Control\Invoke-RemoteAccessProtection.ps1'
}

try {
    if ($Action -eq 'Install') {
        Write-Host 'Installing and enabling remote-access blocking. Administrator approval may be required.'
        $modulePath = Join-Path $PSScriptRoot 'RemoteAccessProtection.psm1'
        $controllerPath = Join-Path $PSScriptRoot 'Invoke-RemoteAccessProtection.ps1'
        if (-not (Test-Path -LiteralPath $modulePath)) { throw "Required package module not found: $modulePath" }
        if (-not (Test-Path -LiteralPath $controllerPath)) { throw "Required package controller not found: $controllerPath" }
        if (-not (Test-NativeAdministrator)) {
            if ($ElevationAttempted) { throw 'Administrator approval was not granted. Setup stopped without retrying elevation.' }
            $exitCode = Invoke-SelfElevated -ScriptPath $PSCommandPath
            exit $exitCode
        }
        $exitCode = Invoke-Controller -ControllerPath $controllerPath -ControllerAction Install
        if ($exitCode -ne 0) { throw "Setup failed (exit $exitCode). Protection was not confirmed; inspect the policy state." }
        exit 0
    }
    # Allow deliberately uses only the protected Program Files controller.
    $installedController = Get-InstalledControllerPath
    if (-not (Test-Path -LiteralPath $installedController)) { throw "Installed controller not found: $installedController. Run Start Here to install first." }
    $exitCode = Invoke-Controller -ControllerPath $installedController -ControllerAction Allow
    exit $exitCode
} catch {
    Show-OneClickError -Message $_.Exception.Message
    exit 1
}
