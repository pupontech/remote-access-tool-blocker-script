<#
.SYNOPSIS
  Revert (or restore) the remote-access tool block on this PC, standalone and offline.

.DESCRIPTION
  This is the always-available copy. The kit installs it to C:\RemoteAccessToolBlocker when a
  block is applied, so anyone local can undo the block without the original kit, the network, or
  this repository.

  REVERT (default)
    1. Backs up the current state into backups\<timestamp>\:
         - the installed App Control policy (.cip + its XML + the installed toggles/mode)
         - a machine summary (PC name, OS build, policy state, log tail)
    2. Removes the Windows App Control policy  (CiTool --remove-policy, or deletes the
       CiPolicies\Active file on builds without CiTool).  A restart finishes the unload.
    3. The Windows App Control policy is removed.

  RESTORE
    1. Lists the dated backups, newest first.
    2. Re-installs the App Control policy from the backup you pick, with its original toggles.

  Nothing here needs the internet, the repo, or any other file: the script uses the bundled RemoteAccessSafety.psm1 for mandatory anti-scam confirmations
  and restores the App Control policy from its own backups.

.PARAMETER WhatIf
  Show what would happen and change nothing. Recommended first run.
  This is an explicit switch, NOT the common parameter: with [CmdletBinding()] alone the
  common -WhatIf does not exist for a script, and enabling SupportsShouldProcess makes
  PowerShell emit its own "What if:" lines for every cmdlet the script calls, hiding the
  dry-run output. The explicit switch gives the same guarantee with readable output.

.PARAMETER Restore
  Restore a previously backed-up App Control policy instead of removing it.

.PARAMETER BackupPath
  The dated backup folder to restore from. Default: ask, offering the newest few.

.PARAMETER RemoveFolder
  After a successful revert, also delete this folder and its backups. Deliberately NOT the
  default - the folder is meant to stay in place so the block can be put back.

.PARAMETER NoPause
  Do not wait for a key press at the end (for remote/unattended use).

.EXAMPLE
  .\Revert-RemoteAccessBlock.bat
      Interactive revert: back up and remove the policy.

.EXAMPLE
  .\Run-Revert.bat -WhatIf
      Dry run - shows every step and changes nothing.

.EXAMPLE
  .\Run-Revert.bat -Restore
      Put a previously backed-up block back.

.NOTES
  Log: %ProgramData%\RemoteAccessToolBlocker\Revert.log (append-only, never deleted).
#>
# -WhatIf is declared EXPLICITLY.
#   [CmdletBinding()] alone does not provide it to a script (the switch fails to bind with
#   "A parameter cannot be found that matches parameter name 'WhatIf'"), and
#   SupportsShouldProcess does provide it but then makes PowerShell intercept every
#   ShouldProcess-aware cmdlet this script calls (New-Item, Add-Content, Set-Content,
#   Copy-Item, Remove-Item) and print its own framework chatter, drowning the dry run the
#   operator is meant to READ. An explicit switch keeps the guarantee - nothing is written
#   when -WhatIf is set - with output we control.
[CmdletBinding()]
param(
    [switch]$WhatIf,
    [switch]$Restore,
    [string]$BackupPath,
    [switch]$RemoveFolder,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '2026-10-11.1'

# --------------------------------------------------------------------- constants
# These must match Build- / Install-RmmAppControl. Kept as literals (not dot-sourced) so this
# script keeps working even if everything else on the disk has been removed.
$PolicyGuid = '{2D13BFB7-4304-4847-9CDD-37820D3EE9B7}'
$PolicyName = 'Remote Access Tool Blocker'
$bare = $PolicyGuid.Trim('{}').ToLowerInvariant()
$Folder = $PSScriptRoot
$BackupRoot = Join-Path $Folder 'backups'
$LogDir = if ($env:ProgramData) { Join-Path $env:ProgramData 'RemoteAccessToolBlocker' } else { $null }
$LogFile = if ($LogDir) { Join-Path $LogDir 'Revert.log' } else { $null }
# A missing Windows environment variable must produce a clear, specific error rather than
# a bare "Cannot bind argument to parameter 'Path' because it is null" at startup.
if (-not $env:windir) {
    Write-Host ''
    Write-Host 'This tool needs Windows: the WINDIR environment variable is not set.' -ForegroundColor Red
    Write-Host 'It cannot remove an App Control policy on a host without one.' -ForegroundColor Red
    exit 9
}
$ciTool = Join-Path $env:windir 'System32\CiTool.exe'
$activeDir = Join-Path $env:windir 'System32\CodeIntegrity\CiPolicies\Active'
$activeFile = Join-Path $activeDir ($PolicyGuid + '.cip')

$dry = [bool]$WhatIf
$steps = New-Object System.Collections.Generic.List[string]

# --------------------------------------------------------------------- helpers
function Say([string]$m, [string]$color = 'Gray') {
    Write-Host $m -ForegroundColor $color
    $script:steps.Add($m) | Out-Null
}
function Write-Log([string]$m) {
    if ($dry) { return }
    if (-not $LogFile) { return }   # no log location on this host - not a failure
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
        Add-Content -Encoding UTF8 -LiteralPath $LogFile -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    } catch { }
}
function Request-AllowRemoteAccessConsent {
    $modulePath = $null
    foreach ($candidate in @(
        (Join-Path $PSScriptRoot 'RemoteAccessSafety.psm1'),
        (Join-Path $PSScriptRoot '../../integration/RemoteAccessSafety.psm1'),
        (Join-Path $PSScriptRoot '../integration/RemoteAccessSafety.psm1')
    )) {
        if (Test-Path -LiteralPath $candidate) { $modulePath = $candidate; break }
    }
    if (-not $modulePath) { throw 'Safety confirmation module missing. No protection was removed. Extract the complete package again.' }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
    return (Confirm-AllowRemoteAccess)
}

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-PolicyState {
    # $null = not installed; 'denied' = needs admin; $false = no CiTool on this build
    if (-not (Test-Path -LiteralPath $ciTool)) { return $false }
    $raw = & $ciTool --list-policies -json 2>$null | Out-String
    try { $j = $raw | ConvertFrom-Json } catch { return $null }
    if ($j.OperationResult -and $j.OperationResult -ne 0) { return 'denied' }
    $pol = @($j.Policies) | Where-Object { ([string]$_.PolicyID).Trim('{}').ToLowerInvariant() -eq $bare }
    return ($pol | Select-Object -First 1)
}
function Get-VariantFromName([string]$name) {
    if ($name -match '\[(T[01]A[01]S[01](R[01])?)\]') { return $Matches[1] }
    return ''
}
function Get-Stamp { (Get-Date -Format 'yyyy-MM-dd_HHmmss') }
function Wait-Key {
    if ($NoPause) { return }
    Write-Host ''
    Write-Host 'Press any key to close ...' -ForegroundColor DarkGray
    try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Start-Sleep -Seconds 1 }
}

# --------------------------------------------------------------------- banner
Write-Host ''
Write-Host ('  Remote-access tool block - ' + $(if ($Restore) { 'RESTORE' } else { 'ALLOW REMOTE ACCESS' }) + "  (v$ScriptVersion)") -ForegroundColor Cyan
Write-Host ('  ' + $Folder) -ForegroundColor DarkGray
if ($dry) { Write-Host '  DRY RUN (-WhatIf): nothing will be changed.' -ForegroundColor Yellow }
Write-Host ''

if ($dry) {
    Say ('[dry run] would write a log line to ' + $LogFile)
} else {
    Write-Log ('=== v{0}  {1}  whatif={2}  admin={3}' -f $ScriptVersion, $(if ($Restore) { 'RESTORE' } else { 'REVERT' }), $dry, (Test-Admin))
}
Write-Log ("PC: {0}  user: {1}" -f $env:COMPUTERNAME, $env:USERNAME)

if (-not (Test-Admin)) {
    Say 'This needs administrator rights. Start it with Run-Revert.bat, which asks for them.' 'Red'
    Write-Log 'ABORT: not elevated'
    Wait-Key
    exit 2
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
} catch {
    $os = $null; $build = 0
}

# ===================================================================== RESTORE
if ($Restore) {
    Write-Host '--- Backups available on this PC ---' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        Say "No backups folder at $BackupRoot - nothing to restore from." 'Red'
        Wait-Key
        exit 3
    }
    $dirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending)
    if (-not $dirs) {
        Say "No backups found under $BackupRoot." 'Red'
        Wait-Key
        exit 3
    }
    $i = 1
    foreach ($d in $dirs) {
        $cip = @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.cip' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        $state = if ($cip) { "policy: $($cip[0].Name)" } else { 'policy: MISSING' }
        Write-Host ("  [{0}] {1}   {2}" -f $i, $d.Name, $state)
        $i++
    }
    Write-Host ''

    if (-not $BackupPath) {
        if ($NoPause) {
            $BackupPath = $dirs[0].FullName
            Say "No -BackupPath given, using newest: $BackupPath" 'Yellow'
        } else {
            $pick = Read-Host 'Which backup number to restore (Enter = newest, Q = quit)'
            if ($pick -match '^[Qq]') { Say 'Cancelled.' 'Yellow'; Wait-Key; exit 0 }
            if ([string]::IsNullOrWhiteSpace($pick)) { $BackupPath = $dirs[0].FullName }
            elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $dirs.Count) { $BackupPath = $dirs[[int]$pick - 1].FullName }
            else { Say "Not a valid choice: '$pick'" 'Red'; Wait-Key; exit 3 }
        }
    }
    if (-not (Test-Path -LiteralPath $BackupPath)) { Say "Backup folder not found: $BackupPath" 'Red'; Wait-Key; exit 3 }

    $cipFile = @(Get-ChildItem -LiteralPath $BackupPath -Filter '*.cip' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $cipFile) {
        Say "That backup has no .cip policy file - cannot restore it. Look in $BackupPath" 'Red'
        Write-Log "RESTORE FAILED: no .cip in $BackupPath"
        Wait-Key
        exit 3
    }
    $meta = Join-Path $BackupPath 'restore-info.txt'
    $variant = ''
    if (Test-Path -LiteralPath $meta) {
        $line = Select-String -LiteralPath $meta -Pattern '^Variant\s*:' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($line) { $variant = ($line.Line -replace '^Variant\s*:\s*', '').Trim() }
    }

    Write-Host ''
    Write-Host '--- Restoring ---' -ForegroundColor Cyan
    Say ("  policy file : " + $cipFile[0].FullName)
    if ($variant) { Say ("  toggles     : " + $variant) }

    if ($dry) {
        Say '[dry run] would install that .cip as the active App Control policy.'
        Say '[dry run] no policy was changed.'
    } else {
        if (Test-Path -LiteralPath $ciTool) {
            $out = & $ciTool --update-policy $cipFile[0].FullName -json 2>&1 | Out-String
            $rc = $LASTEXITCODE
            Write-Log ("CiTool --update-policy exit {0}: {1}" -f $rc, ($out -replace '\s+', ' ').Trim())
            if ($rc -ne 0) { Say 'Restore FAILED - see the log.' 'Red'; Wait-Key; exit 5 }
            Say '  -> policy restored and active now (no restart needed).' 'Green'
        } else {
            if (-not (Test-Path -LiteralPath $activeDir)) { New-Item -ItemType Directory -Force -Path $activeDir | Out-Null }
            Copy-Item -LiteralPath $cipFile[0].FullName -Destination $activeFile -Force
            Say '  -> policy copied into CiPolicies\Active. RESTART the PC to activate.' 'Yellow'
        }
        Write-Log 'RESTORE OK'
    }
    Wait-Key
    exit 0
}

# ===================================================================== REVERT
Write-Host '--- Current state ---' -ForegroundColor Cyan
$state = Get-PolicyState
$installed = $false
$installedVariant = ''
if ($state -eq 'denied') {
    Say '  App Control: unknown (listing policies needs admin - rerun elevated).' 'Yellow'
    $installed = $true   # assume installed; the removal below is harmless if it is not
} elseif ($state -eq $false) {
    $present = Test-Path -LiteralPath $activeFile
    Say ("  App Control: " + $(if ($present) { "policy file present ($activeFile) - no CiTool on this build" } else { 'NOT installed' }))
    $installed = $present
} elseif ($state) {
    $installedVariant = Get-VariantFromName ([string]$state.FriendlyName)
    $mode = if (([string]$state.FriendlyName) -match 'Audit') { 'AUDIT (logs only)' } else { 'ENFORCE (blocks)' }
    Say ("  App Control: INSTALLED  '$($state.FriendlyName)'  mode=$mode  enforced=$($state.IsEnforced)") 'Yellow'
    if ($installedVariant) { Say ("  toggles     : " + $installedVariant) }
    $installed = $true
} else {
    Say '  App Control: NOT installed'
}
if ($os) { Say ("  PC          : {0}  {1} build {2}" -f $env:COMPUTERNAME, $os.Caption, $build) }
Write-Host ''

# Require anti-scam consent before backup or any policy mutation. -NoPause is not consent.
if (-not $dry -and -not (Request-AllowRemoteAccessConsent)) { Say 'Cancelled. No protection was removed.' 'Yellow'; Wait-Key; exit 6 }

# ---- 1. back up
Write-Host '--- 1. Backing up current state ---' -ForegroundColor Cyan
$stamp = Get-Stamp
$bdir = Join-Path $BackupRoot $stamp
if ($dry) {
    Say ("  [dry run] would create " + $bdir)
} else {
    New-Item -ItemType Directory -Force -Path $bdir | Out-Null
    Write-Log ("Backup folder: " + $bdir)
}
$backed = 0
if ($installed) {
    # prefer the actual installed file, fall back to the repo's built policy
    $src = if (Test-Path -LiteralPath $activeFile) { $activeFile } else { $null }
    if (-not $src) {
        $src = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter 'RmmBlock-Enforce.cip' -File -ErrorAction SilentlyContinue | Select-Object -First 1)[0].FullName
    }
    if ($src -and (Test-Path -LiteralPath $src)) {
        if ($dry) { Say ("  [dry run] would copy " + $src) }
        else {
            Copy-Item -LiteralPath $src -Destination (Join-Path $bdir (Split-Path $src -Leaf)) -Force
            $backed++
            Say ("  saved policy: " + (Split-Path $src -Leaf))
        }
    } else {
        Say '  policy file not found on disk - nothing to save (the backup will record the state only)' 'Yellow'
    }
}
# machine + state summary (what restore needs, and what a technician needs to read)
$info = @()
$info += 'Remote-access tool block - revert backup'
$info += 'Created   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
$info += 'Script    : ' + $ScriptVersion
$info += 'PC        : ' + $env:COMPUTERNAME
if ($os) { $info += 'OS        : ' + $os.Caption + ' build ' + $build }
$info += 'PolicyID  : ' + $PolicyGuid
$info += 'Installed : ' + $installed
$info += 'Variant   : ' + $installedVariant
$info += 'ActiveCip : ' + $(if (Test-Path -LiteralPath $activeFile) { $activeFile } else { '(none)' })
$info += ''
$info += 'Restore with:  Run-Revert.bat -Restore   (then pick this folder)'
if ($dry) { Say ('  [dry run] would write restore-info.txt (' + $info.Count + ' lines)') }
else {
    Set-Content -LiteralPath (Join-Path $bdir 'restore-info.txt') -Value $info -Encoding UTF8
    $backed++
    Say '  wrote restore-info.txt'
}
Write-Host ''

# ---- 2. remove the policy
Write-Host '--- 2. Removing the Windows App Control policy ---' -ForegroundColor Cyan
if ($dry) {
    Say ('  [dry run] would run: CiTool --remove-policy ' + $PolicyGuid)
    Say ('  [dry run] would delete ' + $activeFile + ' if present')
    Say '  [dry run] no policy was changed.'
} else {
    if (Test-Path -LiteralPath $ciTool) {
        $out = & $ciTool --remove-policy $PolicyGuid -json 2>&1 | Out-String
        $rc = $LASTEXITCODE
        Write-Log ("CiTool --remove-policy exit {0}: {1}" -f $rc, ($out -replace '\s+', ' ').Trim())
        Say ("  CiTool --remove-policy exit " + $rc)
    } else {
        Say '  CiTool not present on this build - removing the file directly.' 'Yellow'
        Write-Log 'CiTool absent; file removal path'
    }
    if (Test-Path -LiteralPath $activeFile) {
        Remove-Item -LiteralPath $activeFile -Force
        Say ("  deleted " + $activeFile)
        Write-Log ("Deleted " + $activeFile)
    }
    Write-Log 'REVERT: policy removed'
    Say '  -> policy removed. RESTART the PC to make sure it is fully unloaded.' 'Green'
}
Write-Host ''


# ---- summary
Write-Host '--- Done ---' -ForegroundColor Cyan
if ($dry) {
    Say 'Dry run complete. Nothing was changed.'
} else {
    if ($backed -gt 0) { Say ("  Backup saved: " + $bdir) 'Green' }
    Say '  The block has been reverted. RESTART the PC to fully unload the policy.' 'Green'
    if (-not (Test-Path -LiteralPath $bdir)) { Say '  (no backup folder was created - nothing was installed to back up)' 'Yellow' }
    Say '  To put the block back:  Run-Revert.bat -Restore' 'White'
}
Say ("  Log: " + $LogFile)

if ($RemoveFolder) {
    Write-Host ''
    Write-Host ("  -RemoveFolder was given: deleting " + $Folder) -ForegroundColor Yellow
    if ($dry) { Say '  [dry run] would delete the folder and its backups.' }
    else {
        Write-Log ('Removing folder by request: ' + $Folder)
        # resolve to a full path and refuse anything that is not the expected leaf
        $full = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\')
        if ($full -notmatch '\\RemoteAccessToolBlocker$') {
            Say ("  REFUSED to delete: " + $full + " is not a RemoteAccessToolBlocker folder.") 'Red'
        } else {
            Start-Process $env:ComSpec -ArgumentList ('/c timeout /t 2 /nobreak >nul & rmdir /s /q "' + $full + '"') -WindowStyle Hidden
            Say '  folder will be removed after this window closes.'
        }
    }
}

Write-Log ('=== end (steps: {0})' -f $steps.Count)
Wait-Key
exit 0