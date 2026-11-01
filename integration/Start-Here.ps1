[CmdletBinding()]
param(
    [ValidateSet('Install', 'Allow')]
    [string]$Action = 'Install',
    [switch]$ElevationAttempted
)

$ErrorActionPreference = 'Stop'

function Pause-OneClickConsole {
    [void](Read-Host 'Press Enter to close')
}

function Get-NativeWindowsPowerShell {
    if (-not $env:SystemRoot) {
        throw 'Windows PowerShell could not be located because SystemRoot is not set.'
    }
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
    } catch {
        $false
    }
}

function ConvertTo-NativeArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    # Windows paths cannot contain a double quote; quoting the complete token
    # keeps spaces, apostrophes, parentheses, ampersands, and exclamation marks data.
    '"{0}"' -f $Value
}

function Invoke-SelfElevated {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    $powershell = Get-NativeWindowsPowerShell
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File {0} -Action Install -ElevationAttempted' -f (ConvertTo-NativeArgument $ScriptPath)
    $child = Start-Process -FilePath $powershell -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
    $child.ExitCode
}

function Invoke-Controller {
    param(
        [Parameter(Mandatory = $true)][string]$ControllerPath,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Allow')][string]$ControllerAction
    )
    $powershell = Get-NativeWindowsPowerShell
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File {0} -Action {1}' -f (ConvertTo-NativeArgument $ControllerPath), (ConvertTo-NativeArgument $ControllerAction)
    $startArguments = @{
        FilePath = $powershell
        ArgumentList = $argumentLine
        Wait = $true
        PassThru = $true
    }
    $child = Start-Process @startArguments
    $child.ExitCode
}

function Get-InstalledControllerPath {
    $programFiles = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $env:ProgramW6432
    } else {
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    }
    if (-not $programFiles) { throw 'Program Files directory could not be resolved.' }
    Join-Path (Join-Path $programFiles 'RemoteAccessToolBlocker') 'Control\Invoke-RemoteAccessProtection.ps1'
}

try {
    if ($Action -eq 'Install') {
        Write-Host 'This installer will copy the policy and controller into Program Files, create the desktop control, and enable blocking.'
        Write-Host 'Warning: enabling this policy will stop the covered remote-support tools from starting until protection is allowed again.' -ForegroundColor Yellow
        $confirmation = Read-Host 'Type BLOCK to continue'
        if ($confirmation -cne 'BLOCK') {
            Write-Host 'Install cancelled. No elevation or installation was attempted.'
            Pause-OneClickConsole
            exit 2
        }

        $modulePath = Join-Path $PSScriptRoot 'RemoteAccessProtection.psm1'
        $controllerPath = Join-Path $PSScriptRoot 'Invoke-RemoteAccessProtection.ps1'
        if (-not (Test-Path -LiteralPath $modulePath)) { throw "Required package module not found: $modulePath" }
        if (-not (Test-Path -LiteralPath $controllerPath)) { throw "Required package controller not found: $controllerPath" }

        if (-not (Test-NativeAdministrator)) {
            if ($ElevationAttempted) { throw 'Administrator approval was not granted or the elevated launcher returned without an administrator token.' }
            $exitCode = Invoke-SelfElevated -ScriptPath $PSCommandPath
            Pause-OneClickConsole
            exit $exitCode
        }

        $exitCode = Invoke-Controller -ControllerPath $controllerPath -ControllerAction Install
        if (-not $ElevationAttempted) { Pause-OneClickConsole }
        exit $exitCode
    }

    # Allow deliberately uses only the protected Program Files controller. It never
    # runs the source controller and does not perform its own elevation. The installed
    # controller receives -Action Allow.
    $installedController = Get-InstalledControllerPath
    if (-not (Test-Path -LiteralPath $installedController)) { throw "Installed controller not found: $installedController. Run Start Here to install first." }
    $exitCode = Invoke-Controller -ControllerPath $installedController -ControllerAction Allow
    Pause-OneClickConsole
    exit $exitCode
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Pause-OneClickConsole
    exit 1
}
