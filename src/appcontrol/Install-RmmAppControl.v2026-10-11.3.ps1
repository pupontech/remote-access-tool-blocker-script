<#
.SYNOPSIS
  Install / remove / check the "Remote Access Tool Blocker (lolrmm)" Windows App Control policy on THIS PC.

.DESCRIPTION
  -Mode Enforce   install RmmBlock-Enforce.cip  -> listed remote-access tools are blocked from starting
  -Mode Audit     install RmmBlock-Audit.cip    -> nothing blocked; Windows logs what WOULD be blocked
  -Mode Remove    uninstall the policy (fully gone after a restart)
  -Mode Status    show whether it is installed + recent block/audit events (default)
  -Variant T1A1S0R1 which toggles: T=TeamViewer A=AnyDesk S=Splashtop R=RustDesk, 1 = block, 0 = allow
                  (uses the matching policy variant; omitted = the policy root's default)
                  (source/full-kit root default: T1A1S0R1; script-only preview root default: T1A1S1R1)

  Install/Remove need admin (Run-RmmAppControl.bat elevates). Uses CiTool.exe (Windows 11 22H2+); on older builds it
  copies the policy into %windir%\System32\CodeIntegrity\CiPolicies\Active and asks for a restart.
  The policy is Microsoft's AllowAll template plus deny rules for vendor signing certificates - see
  Build-RmmAppControl. Installing it again (e.g. a newer build) REPLACES the old copy (fixed policy ID).
  Log: %ProgramData%\RemoteAccessToolBlocker\RmmAppControl.log
  Installing also copies the standalone undo tool to %SystemDrive%\RemoteAccessToolBlocker, so the
  block can be reverted on that PC later without this kit (Run-Revert.bat there).
#>
[CmdletBinding()]
param(
    [ValidateSet('Enforce', 'Audit', 'Remove', 'Status')][string]$Mode = 'Status',
    [string]$PolicyDir,
    [ValidatePattern('^T[01]A[01]S[01]R[01]$')][string]$Variant
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '2026-10-11.3'
$PolicyGuid = '{2D13BFB7-4304-4847-9CDD-37820D3EE9B7}'      # must match Build-RmmAppControl
# Do not change $PolicyGuid: PCs already carrying this policy are keyed to it, and a new GUID would
# stack a second policy instead of replacing the installed one.
$bare = $PolicyGuid.Trim('{}').ToLowerInvariant()
if (-not $PolicyDir) {
    # the scripts live in src/appcontrol/, the built policies in <repo>/policy at the repo root
    foreach ($candidate in @((Join-Path $PSScriptRoot 'policy'), (Join-Path $PSScriptRoot '..\..\policy'))) {
        if (Test-Path -LiteralPath $candidate) { $PolicyDir = $candidate; break }
    }
    if (-not $PolicyDir) { $PolicyDir = Join-Path $PSScriptRoot 'policy' }
}
$ciTool = Join-Path $env:windir 'System32\CiTool.exe'
$activeDir = Join-Path $env:windir 'System32\CodeIntegrity\CiPolicies\Active'
# Log folder under %ProgramData%. Deployment-specific branding goes here; keep it plain ASCII.
$LogDirName = 'RemoteAccessToolBlocker'
$logDir = Join-Path $env:ProgramData $LogDirName
# Where the always-available standalone revert tool is installed on the PC.
$InstallDir = Join-Path $env:SystemDrive 'RemoteAccessToolBlocker'
# Captured at SCRIPT scope: inside a function $PSScriptRoot is the CALLER's script root,
# not this file's, so a function that reads it directly resolves to the wrong folder.
$ScriptRootHere = $PSScriptRoot
$RepoRootHere = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Write-Log([string]$m) {
    Write-Host $m
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        Add-Content -Encoding UTF8 -LiteralPath (Join-Path $logDir 'RmmAppControl.log') -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    } catch { }
}
function Install-RevertTool {
    # Copy the kit + the standalone revert tool to $InstallDir so the block can be undone
    # on this PC without the original kit, the network, or the repository.
    # A dated backup of any previous install is taken first. Never removes the old folder
    # before the new copy is in place.
    # Resolve by the FILES we need, not by a folder name: in the repo they live in
    # revert\, but in a built release ZIP they sit loose beside this installer. Looking
    # for a 'revert' directory made the kit layout silently skip the whole install.
    $srcRoot = $null
    $srcSub = $null
    $candidates = @(
        @{ root = $ScriptRootHere; sub = '' },          # flat kit layout (release ZIP)
        @{ root = $ScriptRootHere; sub = 'revert' },    # repo layout (revert\)
        @{ root = $RepoRootHere;   sub = '' },
        @{ root = $RepoRootHere;   sub = 'revert' }
    )
    foreach ($c in $candidates) {
        if (-not $c.root) { continue }
        $dir = if ($c.sub) { Join-Path $c.root $c.sub } else { $c.root }
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        if ((Get-ChildItem -Path (Join-Path $dir 'Run-Revert.bat') -File -ErrorAction SilentlyContinue) -or
            (Get-ChildItem -Path (Join-Path $dir 'Revert-RemoteAccessBlock-WinOnly.v*.ps1') -File -ErrorAction SilentlyContinue)) {
            $srcRoot = $c.root; $srcSub = $c.sub; break
        }
    }
    if (-not $srcRoot) {
        Write-Log "Revert tool not found next to this script - skipping the $InstallDir install."
        return
    }
    $revDir = if ($srcSub) { Join-Path $srcRoot $srcSub } else { $srcRoot }

    # 1. dated backup of any existing install
    if (Test-Path -LiteralPath $InstallDir) {
        $old = Join-Path $InstallDir 'backups'
        if (Test-Path -LiteralPath $old) {
            $keep = Join-Path ($InstallDir + '.backup-' + (Get-Date -Format 'yyyy-MM-dd_HHmmss')) 'backups'
            try {
                New-Item -ItemType Directory -Force -Path (Split-Path $keep -Parent) | Out-Null
                Copy-Item -LiteralPath $old -Destination $keep -Recurse -Force
                Write-Log "Backed up the previous revert-tool backups to $keep"
            } catch { Write-Log "Could not back up previous backups: $($_.Exception.Message)" }
        }
    } else {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }

    # 2. copy only the Windows App Control-only revert tool.
    $copied = 0
    $winOnly = @(Get-ChildItem -Path (Join-Path $revDir 'Revert-RemoteAccessBlock-WinOnly.v*.ps1') -File -ErrorAction SilentlyContinue)
    if ($winOnly.Count -eq 0) {
        Write-Log "No Windows-only revert script found - skipping the $InstallDir install."
        return
    }
    foreach ($f in @(Get-ChildItem -Path (Join-Path $revDir 'Run-Revert.bat') -File -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $InstallDir $f.Name) -Force
        $copied++
    }
    foreach ($f in $winOnly) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $InstallDir $f.Name) -Force
        $copied++
    }
    foreach ($f in @(Get-ChildItem -Path (Join-Path $InstallDir 'Revert-RemoteAccessBlock*.ps1') -File -ErrorAction SilentlyContinue)) {
        if ($winOnly.Name -notcontains $f.Name) { Remove-Item -LiteralPath $f.FullName -Force }
    }
    Write-Log 'Installed revert variant: Windows App Control only.'

    # 3. the built policies, so -Restore and the window work from the installed copy.
    #    Copy the CONTENTS into <InstallDir>\policy: -Destination <dir> would place the
    #    source folder INSIDE it, giving <InstallDir>\policy\policy\... and no working
    #    policy\variants\ at all (verified against a real copy).
    if (Test-Path -LiteralPath $PolicyDir) {
        $destPolicy = Join-Path $InstallDir 'policy'
        New-Item -ItemType Directory -Force -Path $destPolicy | Out-Null
        # Enumerate instead of using a wildcard: -LiteralPath does NOT expand '*', so
        # a glob there matches nothing and leaves the destination empty; -Path would
        # expand but reintroduces bracket-in-path hazards. Copy each entry explicitly.
        $polItems = @(Get-ChildItem -LiteralPath $PolicyDir -Force -ErrorAction SilentlyContinue)
        foreach ($item in $polItems) {
            if ($item.PSIsContainer) {
                $sub = Join-Path $destPolicy $item.Name
                New-Item -ItemType Directory -Force -Path $sub | Out-Null
                foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)) {
                    Copy-Item -LiteralPath $child.FullName -Destination $sub -Force
                }
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination $destPolicy -Force
            }
        }
        $variants = @(Get-ChildItem -LiteralPath (Join-Path $destPolicy 'variants') -Filter '*.cip' -File -ErrorAction SilentlyContinue)
        $polCount = @(Get-ChildItem -LiteralPath $destPolicy -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Log "Copied $polCount policy file(s), $($variants.Count) variant(s), into $destPolicy"
        if ($variants.Count -eq 0) { Write-Log "WARNING: no variants landed in $destPolicy - -Restore needs them." }
    } else {
        Write-Log "No policy folder at $PolicyDir - the installed copy cannot restore a policy by itself."
    }

    # 4. a short pointer file for whoever finds the folder
    $readme = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        'Remote-access tool block - standalone undo tool',
        '',
        'This folder was installed automatically when the block was applied to this PC.',
        'It is deliberately kept here so the block can be removed later WITHOUT the original',
        'kit, the network, or the repository.',
        '',
        '    Run-Revert.bat                 undo the block (asks first, then backs up)',
        '    Run-Revert.bat -WhatIf        dry run - show every step, change nothing',
        '    Run-Revert.bat -Restore       put a previously backed-up block back',
        '',
        'Backups live in backups\<timestamp>\ and are never deleted automatically.'
    )) { $readme.Add($line) }
    $readme.Add('')
    $readme.Add('To remove this folder, use Run-Revert.bat -RemoveFolder (it refuses unless the folder')
    $readme.Add('is named RemoteAccessToolBlocker).')
    Set-Content -LiteralPath (Join-Path $InstallDir 'README.txt') -Value $readme -Encoding UTF8

    Write-Log "Standalone revert tool installed to $InstallDir ($copied item(s) copied)."
}

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-Installed {
    # returns the CiTool policy object, or $null; $false when CiTool is unavailable
    if (-not (Test-Path -LiteralPath $ciTool)) { return $false }
    $raw = & $ciTool --list-policies -json 2>$null | Out-String
    try { $j = $raw | ConvertFrom-Json } catch { return $null }
    if ($j.OperationResult -and $j.OperationResult -ne 0) { return 'denied' }
    $pol = @($j.Policies) | Where-Object { ([string]$_.PolicyID).Trim('{}').ToLowerInvariant() -eq $bare }
    return ($pol | Select-Object -First 1)
}
function Format-Variant([string]$code) {
    # older builds wrote 3-letter codes (no R) - RustDesk was not blocked by them
    if ($code -notmatch '^T[01]A[01]S[01](R[01])?$') { return '' }
    $n = [ordered]@{ 'T' = 'TeamViewer'; 'A' = 'AnyDesk'; 'S' = 'Splashtop'; 'R' = 'RustDesk' }
    $parts = @(); $i = 0
    foreach ($k in $n.Keys) { $parts += '{0} {1}' -f $n[$k], $(if ($code.Length -gt $i * 2 + 1 -and $code[$i * 2 + 1] -eq [char]'1') { 'BLOCKED' } else { 'allowed' }); $i++ }
    $parts -join ', '
}
function Show-Status {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host ("PC: {0}  {1} build {2}" -f $env:COMPUTERNAME, $os.Caption, $os.BuildNumber)
    $p = Get-Installed
    $file = Join-Path $activeDir ($PolicyGuid + '.cip')
    if ($p -eq 'denied') {
        Write-Host 'Policy: unknown - listing policies needs administrator rights (use Run-RmmAppControl.bat).'
    } elseif ($p -eq $false) {
        if (Test-Path -LiteralPath $file) { Write-Host "Policy file present: $file (no CiTool on this build - active after a restart)" }
        else { Write-Host 'Policy: NOT installed' }
    } elseif ($p) {
        $audit = ([string]$p.FriendlyName) -match 'Audit'
        $vc = if ([string]$p.FriendlyName -match '\[(T[01]A[01]S[01](R[01])?)\]') { $Matches[1] } else { '' }
        if ($vc) { Write-Host ("Toggles: {0}  [{1}]" -f (Format-Variant $vc), $vc) }
        Write-Host ("Policy: INSTALLED  '{0}'  version {1}  enforced={2}  mode={3}" -f $p.FriendlyName, $(if ($p.VersionString) { $p.VersionString } else { $p.Version }), $p.IsEnforced, $(if ($audit) { 'AUDIT (logs only)' } else { 'ENFORCE (blocks)' }))
    } else { Write-Host 'Policy: NOT installed' }

    Write-Host ''
    Write-Host 'Recent App Control events for this policy (last 14 days; 3077 = blocked, 3076 = would be blocked in audit):'
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3076, 3077; StartTime = (Get-Date).AddDays(-14) } -MaxEvents 500 -ErrorAction Stop |
            Where-Object { $_.Message -match [regex]::Escape($bare) })   # events carry the policy ID, not its name
        if ($ev.Count -eq 0) { Write-Host '  (none)' }
        foreach ($e in ($ev | Select-Object -First 20)) {
            $first = ($e.Message -split "`r?`n")[0] -replace '^.*attempted to load \\Device\\HarddiskVolume\d+', 'file: ' -replace ' that did not meet.*$', ''
            Write-Host ("  {0}  [{1}]  {2}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $e.Id, $first)
        }
    } catch { Write-Host '  (none, or the log is not readable without admin)' }
}

Write-Host "Install-RmmAppControl v$ScriptVersion  -  mode $Mode"
if ($Mode -eq 'Status') { Show-Status; exit 0 }
if (-not (Test-Admin)) { Write-Host 'This needs administrator rights - run Run-RmmAppControl.bat (it asks for them).'; exit 2 }

$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 18362) { Write-Log "Windows build $build is too old for this policy format (needs Windows 10 1903 / build 18362 or newer)."; exit 3 }

if ($Mode -in 'Enforce', 'Audit') {
    if ($Variant) { $cip = Join-Path $PolicyDir "variants\RmmBlock-$Mode-$Variant.cip" }
    else { $cip = Join-Path $PolicyDir "RmmBlock-$Mode.cip" }
    if (-not (Test-Path -LiteralPath $cip)) { Write-Log "Policy file not found: $cip  (build it with Build-RmmAppControl first)"; exit 4 }
    Write-Log "Installing $cip ($Mode$(if ($Variant) { ', ' + (Format-Variant $Variant) })) ..."
    if (Test-Path -LiteralPath $ciTool) {
        $out = & $ciTool --update-policy $cip -json 2>&1 | Out-String
        $rc = $LASTEXITCODE
        Write-Log ("CiTool --update-policy exit {0}: {1}" -f $rc, ($out -replace '\s+', ' ').Trim())
        if ($rc -ne 0) { Write-Log 'FAILED - policy not installed.'; exit 5 }
        Write-Log "Done - active now (no restart needed)."
    } else {
        Copy-Item -LiteralPath $cip -Destination (Join-Path $activeDir ($PolicyGuid + '.cip')) -Force
        Write-Log "Copied to $activeDir - RESTART the PC to activate."
    }
    if ($Mode -eq 'Audit') { Write-Log 'AUDIT mode: nothing is blocked. Start a listed tool, then run Status to see the "would be blocked" event.' }
    # make the undo tool available on this PC regardless of which kit installed the policy
    try { Install-RevertTool } catch { Write-Log "Could not install the revert tool: $($_.Exception.Message)" }
} elseif ($Mode -eq 'Remove') {
    Write-Log 'Removing policy ...'
    if (Test-Path -LiteralPath $ciTool) {
        $out = & $ciTool --remove-policy $PolicyGuid -json 2>&1 | Out-String
        Write-Log ("CiTool --remove-policy exit {0}: {1}" -f $LASTEXITCODE, ($out -replace '\s+', ' ').Trim())
    }
    $file = Join-Path $activeDir ($PolicyGuid + '.cip')
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force; Write-Log "Deleted $file" }
    Write-Log 'Removed. RESTART the PC to make sure it is fully unloaded.'
}
Write-Host ''
Show-Status
