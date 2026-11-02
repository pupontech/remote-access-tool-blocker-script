$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'integration/RemoteAccessProtection.psm1') -Force
$m = Get-Module RemoteAccessProtection
$base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { [IO.Path]::GetTempPath() }
$fixture = Join-Path $base ('admin-shortcut-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $link = Join-Path $fixture 'Allow Remote Access.lnk'
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($link)
        $target = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "C:\Program Files\RemoteAccessToolBlocker\Control\Invoke-RemoteAccessProtection.ps1" -Action Allow'
        $shortcut.TargetPath = $target
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $fixture
        $shortcut.Save()
    } else {
        $bytes = New-Object byte[] 76
        [Array]::Copy([BitConverter]::GetBytes([uint32]76), 0, $bytes, 0, 4)
        [Array]::Copy(([guid]'00021401-0000-0000-C000-000000000046').ToByteArray(), 0, $bytes, 4, 16)
        [IO.File]::WriteAllBytes($link, $bytes)
    }
    $before = [IO.File]::ReadAllBytes($link)
    & $m { param($p) Set-RemoteAccessProtectionShortcutRunAs -Path $p } $link
    $after = [IO.File]::ReadAllBytes($link)
    if (([BitConverter]::ToUInt32($after,20) -band 0x2000) -eq 0) { throw 'Run as administrator flag was not set.' }
    $expected = [byte[]]$before.Clone()
    $flags = [BitConverter]::ToUInt32($expected,20) -bor [uint32]0x2000
    [Array]::Copy([BitConverter]::GetBytes([uint32]$flags),0,$expected,20,4)
    if ([Convert]::ToBase64String($expected) -cne [Convert]::ToBase64String($after)) { throw 'Unrelated shortcut bytes changed.' }
    & $m { param($p) Set-RemoteAccessProtectionShortcutRunAs -Path $p } $link
    if ([Convert]::ToBase64String($after) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($link))) { throw 'Repeated application changed the shortcut.' }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $readback = $shell.CreateShortcut($link)
        if ($readback.TargetPath -ine $target -or $readback.Arguments -cne $arguments -or $readback.WorkingDirectory -ine $fixture) { throw 'Shortcut readback changed target, arguments or working directory.' }
        Write-Host 'PASS: real Windows Shell Link retains STA Allow route and RUNAS_USER.'
    } else { Write-Host 'PASS: synthetic Shell Link header; real WScript.Shell readback requires Windows.' }
    foreach ($invalid in @([byte[]]@(1,2,3), (New-Object byte[] 76))) {
        [IO.File]::WriteAllBytes($link, $invalid)
        $refused = $false
        try { & $m { param($p) Set-RemoteAccessProtectionShortcutRunAs -Path $p } $link } catch { $refused = $true }
        if (-not $refused) { throw 'Malformed shortcut was not refused.' }
        if ([Convert]::ToBase64String($invalid) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($link))) { throw 'Malformed shortcut was modified.' }
    }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
exit 0
