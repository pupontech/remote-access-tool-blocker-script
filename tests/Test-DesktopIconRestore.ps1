$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { Write-Host 'SKIP: desktop icon restore needs Windows cmd.exe and NTFS ACLs.'; exit 0 }
$root = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $root 'integration\RemoteAccessProtection.psm1'
Import-Module $modulePath -Force
$m = Get-Module RemoteAccessProtection
$work = Join-Path ([IO.Path]::GetTempPath()) ('ratb-icons-' + [guid]::NewGuid().ToString('N'))
$recovery = Join-Path $work 'RemoteAccessToolBlocker'
$desktop = Join-Path $work 'Public Desktop'
New-Item -ItemType Directory -Force -Path $recovery, $desktop | Out-Null
try {
    $allow = Join-Path $desktop 'Allow Remote Access.lnk'
    $block = Join-Path $desktop 'Block Remote Access.lnk'
    [IO.File]::WriteAllBytes($allow, [byte[]](1..64))
    [IO.File]::WriteAllBytes($block, [byte[]](65..128))

    # Save the icons and helper files without a real task or ACL change.
    $iconDir = & $m { param($r, $d) Install-RemoteAccessProtectionIconRestore -RecoveryRoot $r -DesktopPath $d -SkipTask -SkipLock } $recovery $desktop
    if ($iconDir -ne (Join-Path $recovery 'DesktopIcons')) { throw "Unexpected icon folder: $iconDir" }
    foreach ($name in 'Allow Remote Access.lnk', 'Block Remote Access.lnk') {
        $saved = [IO.File]::ReadAllBytes((Join-Path $iconDir $name))
        $live = [IO.File]::ReadAllBytes((Join-Path $desktop $name))
        if ([Convert]::ToBase64String($saved) -cne [Convert]::ToBase64String($live)) { throw "$name was not saved byte-for-byte." }
    }
    $task = '\RemoteAccessToolBlocker\Restore desktop icons'
    foreach ($name in 'Stop Restoring Icons.bat', 'Start Restoring Icons.bat', 'README.txt') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $iconDir $name))
        if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw "$name is not ASCII." }
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        if ($text -match "[^`r]`n") { throw "$name is not CRLF." }
        if (-not $text.Contains($task)) { throw "$name does not name the restore task." }
    }
    $stop = Get-Content -Raw (Join-Path $iconDir 'Stop Restoring Icons.bat')
    if ($stop -notmatch 'schtasks\.exe /Delete /TN "\\RemoteAccessToolBlocker\\Restore desktop icons" /F') { throw 'Stop does not delete the task.' }
    if ($stop -notmatch 'net session' -or $stop -notmatch '-Verb RunAs') { throw 'Stop does not ask for administrator rights.' }
    $start = Get-Content -Raw (Join-Path $iconDir 'Start Restoring Icons.bat')
    if ($start -notmatch '/XML "%~dp0RestoreDesktopIcons\.xml"') { throw 'Start does not recreate the task from the saved XML.' }

    # Run the exact command the startup task runs: a deleted and a tampered icon both come back.
    $copyArgs = & $m { param($i, $d) Get-RemoteAccessProtectionIconRestoreArguments -IconDir $i -DesktopPath $d } $iconDir $desktop
    if ($copyArgs -notmatch '^/d /c copy /y "[^"*]+\\Allow Remote Access\.lnk" "[^"*]+" & copy /y "[^"*]+\\Block Remote Access\.lnk" "[^"*]+"$') { throw "Task arguments are not exactly the two named copies: $copyArgs" }
    # Anything else that ends up in the folder must never be copied onto the desktop.
    [IO.File]::WriteAllBytes((Join-Path $iconDir 'Stray.lnk'), [byte[]](7, 7))
    Remove-Item -LiteralPath $allow -Force
    [IO.File]::WriteAllBytes($block, [byte[]](9, 9, 9))
    foreach ($run in 1, 2) {
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList $copyArgs -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -ne 0) { throw "Restore copy failed on run $run (exit $($p.ExitCode))." }
        if (-not (Test-Path -LiteralPath $allow)) { throw "Deleted Allow icon was not restored on run $run." }
        if ([IO.File]::ReadAllBytes($block).Length -ne 64) { throw "Tampered Block icon was not replaced on run $run." }
        if (Test-Path -LiteralPath (Join-Path $desktop 'Stray.lnk')) { throw 'A file other than the two icons was copied to the desktop.' }
    }

    # A folder the current user owns must be reported as unsafe for a SYSTEM task,
    # both as the icon source and as the copy destination.
    $weak = & $m { param($p) Get-RemoteAccessProtectionFolderWeakness -Path $p } $recovery
    if (-not $weak) { throw 'A user-owned folder was reported as locked.' }
    $weakDesktop = & $m { param($p) Get-RemoteAccessProtectionDesktopWeakness -DesktopPath $p } $desktop
    if (-not $weakDesktop) { throw 'A user-writable desktop was reported as safe for the SYSTEM copy.' }
    $public = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
    $publicWeak = & $m { param($p) Get-RemoteAccessProtectionDesktopWeakness -DesktopPath $p } $public
    Write-Host ("INFO: this machine's shared desktop " + $(if ($publicWeak) { "would be REFUSED: $publicWeak" } else { 'passes the safety check.' }))

    $engine = Get-Content -Raw (Get-ChildItem (Join-Path $root 'src\appcontrol') -Filter 'Install-RmmAppControl.v*.ps1' | Sort-Object Name -Descending | Select-Object -First 1).FullName
    if (-not $engine.Contains('try { Protect-RevertFolder }')) { throw 'Engine does not lock the revert folder.' }
    if ($engine -notmatch '(?s)function Protect-RevertFolder \{.*GetAccessRules.*NOT locked') { throw 'Engine does not read back the revert-folder lock.' }

    # Contracts on the real task definition and setup order.
    $module = Get-Content -Raw $modulePath
    foreach ($needle in @(
        'New-ScheduledTaskTrigger -AtStartup',
        "-UserId 'S-1-5-18'",
        "Join-Path `$env:SystemRoot 'System32\cmd.exe'",
        'Protect-RemoteAccessProtectionFolder -Path $RecoveryRoot',
        'Install-RemoteAccessProtectionIconRestore | Out-Null'
    )) { if (-not $module.Contains($needle)) { throw "Contract missing: $needle" } }
    if ($module -match 'AtLogOn') { throw 'Icon restore must run at startup only.' }
    $restoreFn = [regex]::Match($module, '(?s)function Install-RemoteAccessProtectionIconRestore \{.*?\r?\n\}').Value
    if ($restoreFn -match 'Set-RemoteAccessProtection|Invoke-RemoteAccessProtectionInstaller|-Mode Remove') { throw 'Icon restore must never change the block.' }
    $lockIdx = $restoreFn.IndexOf('Protect-RemoteAccessProtectionFolder')
    $desktopIdx = $restoreFn.IndexOf('Get-RemoteAccessProtectionDesktopWeakness')
    $taskIdx = $restoreFn.IndexOf('Register-ScheduledTask')
    if ($lockIdx -lt 0 -or $taskIdx -lt $lockIdx) { throw 'The folder must be locked before the SYSTEM task is registered.' }
    if ($desktopIdx -lt 0 -or $taskIdx -lt $desktopIdx) { throw 'The shared desktop must be checked before the SYSTEM task is registered.' }
    $installFn = [regex]::Match($module, '(?s)function Install-RemoteAccessProtection \{.*?\r?\n\}').Value
    if ($installFn.IndexOf('New-RemoteAccessProtectionShortcut') -gt $installFn.IndexOf('Install-RemoteAccessProtectionIconRestore')) { throw 'Icons must exist before they are saved.' }
    Write-Host 'PASS: desktop icons are saved, restored by the single startup copy, Stop/Start helpers are correct, and unlocked folders are refused.'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
