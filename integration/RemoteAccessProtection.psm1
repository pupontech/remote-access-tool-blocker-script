$script:ModuleRoot = $PSScriptRoot
$ErrorActionPreference = 'Stop'
$script:PolicyGuid = '{2D13BFB7-4304-4847-9CDD-37820D3EE9B7}'
$script:AllBlockedVariant = 'T1A1S1R1'
$script:WindowsPowerShellPath = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }

function Get-RemoteAccessProtectionInstallRoot {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $programFiles = $env:ProgramW6432
    } else {
        $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    }
    if (-not $programFiles) { throw 'Program Files directory could not be resolved.' }
    Join-Path $programFiles 'RemoteAccessToolBlocker\Control'
}

function Test-RemoteAccessProtectionAdministrator {
    if ($env:OS -ne 'Windows_NT') { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Assert-RemoteAccessProtectionWindows {
    if ($env:OS -ne 'Windows_NT') { throw 'Remote-access protection can only be installed or changed on Windows 10/11.' }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw 'Run the host script in 64-bit Windows PowerShell; 32-bit process redirection can misroute App Control system paths.'
    }
}

function Resolve-RemoteAccessProtectionSource {
    $moduleRoot = $script:ModuleRoot
    $repoRoot = Split-Path $moduleRoot -Parent
    if (Test-Path -LiteralPath (Join-Path $moduleRoot 'policy\variants\RmmBlock-Enforce-T1A1S1R1.cip')) {
        $assetRoot = $moduleRoot
    } elseif (Test-Path -LiteralPath (Join-Path $repoRoot 'policy\variants\RmmBlock-Enforce-T1A1S1R1.cip')) {
        $assetRoot = $repoRoot
    } else {
        throw 'The all-blocked policy is missing. Copy the policy folder beside the integration scripts.'
    }

    $appControlRoot = Join-Path $assetRoot 'src\appcontrol'
    if (-not (Test-Path -LiteralPath $appControlRoot)) { $appControlRoot = $assetRoot }
    $installer = Get-ChildItem -LiteralPath $appControlRoot -Filter 'Install-RmmAppControl.v*.ps1' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $installer) { throw "Install-RmmAppControl.v*.ps1 not found under $appControlRoot." }

    $revertRoot = Join-Path $assetRoot 'revert'
    if (-not (Test-Path -LiteralPath (Join-Path $revertRoot 'Run-Revert.bat'))) { $revertRoot = $assetRoot }
    $revert = Get-ChildItem -LiteralPath $revertRoot -Filter 'Revert-RemoteAccessBlock-WinOnly.v*.ps1' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $revert -or -not (Test-Path -LiteralPath (Join-Path $revertRoot 'Run-Revert.bat'))) {
        throw 'The Windows-only emergency revert files are missing from the source tree.'
    }

    [pscustomobject]@{
        AssetRoot = $assetRoot
        PolicyDir = Join-Path $assetRoot 'policy'
        Installer = $installer.FullName
        RevertScript = $revert.FullName
        RevertBatch = Join-Path $revertRoot 'Run-Revert.bat'
        Controller = Join-Path $moduleRoot 'Invoke-RemoteAccessProtection.ps1'
        Module = Join-Path $moduleRoot 'RemoteAccessProtection.psm1'
        SafetyModule = Join-Path $moduleRoot 'RemoteAccessSafety.psm1'
    }
}

function ConvertFrom-RemoteAccessPolicyList {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json)

    try { $document = $Json | ConvertFrom-Json -ErrorAction Stop } catch {
        return [pscustomobject]@{ State = 'Unknown'; Variant = ''; FriendlyName = ''; Reason = 'CiTool returned invalid JSON.' }
    }
    if ($null -eq $document.OperationResult -or [string]$document.OperationResult -ne '0') {
        return [pscustomobject]@{ State = 'Unknown'; Variant = ''; FriendlyName = ''; Reason = 'CiTool did not return a successful policy listing.' }
    }
    if ($null -eq $document.PSObject.Properties['Policies'] -or $null -eq $document.Policies) {
        return [pscustomobject]@{ State = 'Unknown'; Variant = ''; FriendlyName = ''; Reason = 'CiTool did not include the Policies array.' }
    }

    $wanted = $script:PolicyGuid.Trim('{}').ToLowerInvariant()
    $policies = @($document.Policies)
    foreach ($candidate in $policies) {
        if ($null -eq $candidate -or $null -eq $candidate.PSObject.Properties['PolicyID'] -or -not [string]$candidate.PolicyID) {
            return [pscustomobject]@{ State = 'Unknown'; Variant = ''; FriendlyName = ''; Reason = 'CiTool returned a policy entry without a PolicyID.' }
        }
    }
    $policy = $policies | Where-Object {
        ([string]$_.PolicyID).Trim('{}').ToLowerInvariant() -eq $wanted
    } | Select-Object -First 1
    if (-not $policy) {
        return [pscustomobject]@{ State = 'Unblocked'; Variant = ''; FriendlyName = ''; Reason = 'The project policy is not installed.' }
    }

    $name = [string]$policy.FriendlyName
    $variant = if ($name -match '\[(T[01]A[01]S[01]R[01])\]') { $Matches[1] } else { '' }
    if ($name -match '\bAudit\b') {
        return [pscustomobject]@{ State = 'Unblocked'; Variant = $variant; FriendlyName = $name; Reason = 'The project policy is in audit mode; it does not block tools.' }
    }
    $isEnforced = ($policy.IsEnforced -eq $true) -or ([string]$policy.IsEnforced -match '^(?i:true|1)$')
    if ($name -match '\bEnforce\b' -and $isEnforced) {
        return [pscustomobject]@{ State = 'Blocked'; Variant = $variant; FriendlyName = $name; Reason = 'The project policy is enforced.' }
    }
    return [pscustomobject]@{ State = 'Unknown'; Variant = $variant; FriendlyName = $name; Reason = 'The installed policy mode could not be verified.' }
}

function Get-RemoteAccessProtectionState {
    [CmdletBinding()]
    param()

    Assert-RemoteAccessProtectionWindows
    $ciTool = Join-Path $env:SystemRoot 'System32\CiTool.exe'
    if (Test-Path -LiteralPath $ciTool) {
        try {
            $json = (& $ciTool --list-policies -json 2>$null | Out-String)
            if ($LASTEXITCODE -ne 0) {
                return [pscustomobject]@{ State = 'Unknown'; Variant = ''; FriendlyName = ''; Reason = "CiTool failed to list policies (exit $LASTEXITCODE)." }
            }
            return ConvertFrom-RemoteAccessPolicyList -Json $json
        } catch {
            return [pscustomobject]@{ State = 'Unknown'; Variant = ''; FriendlyName = ''; Reason = $_.Exception.Message }
        }
    }

    $activePolicy = Join-Path $env:SystemRoot "System32\CodeIntegrity\CiPolicies\Active\$($script:PolicyGuid).cip"
    if (Test-Path -LiteralPath $activePolicy) {
        return [pscustomobject]@{ State = 'Blocked'; Variant = ''; FriendlyName = ''; Reason = 'Policy file is staged; a restart may still be required.' }
    }
    return [pscustomobject]@{ State = 'Unblocked'; Variant = ''; FriendlyName = ''; Reason = 'The project policy file is not installed.' }
}

function Get-InstalledRemoteAccessProtectionInstaller {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $installer = Get-ChildItem -LiteralPath $InstallRoot -Filter 'Install-RmmAppControl.v*.ps1' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $installer) { throw "Installed policy engine not found in $InstallRoot. Run -Action Install first." }
    $installer.FullName
}

function Invoke-RemoteAccessProtectionInstaller {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Enforce', 'Remove')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )
    $installer = Get-InstalledRemoteAccessProtectionInstaller -InstallRoot $InstallRoot
    $policyDir = Join-Path $InstallRoot 'policy'
    if (-not (Test-Path -LiteralPath $policyDir)) { throw "Installed policy directory is missing: $policyDir" }
    if ($Mode -eq 'Enforce' -and -not (Test-Path -LiteralPath (Join-Path $policyDir "variants\RmmBlock-Enforce-$($script:AllBlockedVariant).cip"))) {
        throw "All-blocked policy variant is missing from $policyDir."
    }

    $quotedInstaller = '"{0}"' -f $installer
    $quotedPolicyDir = '"{0}"' -f $policyDir
    $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $quotedInstaller, '-Mode', $Mode, '-PolicyDir', $quotedPolicyDir)
    if ($Mode -eq 'Enforce') { $arguments += @('-Variant', $script:AllBlockedVariant) }
    $argumentLine = $arguments -join ' '
    $process = Start-Process -FilePath $script:WindowsPowerShellPath -ArgumentList $argumentLine -Wait -PassThru -NoNewWindow
    if ($Mode -eq 'Remove' -and $process.ExitCode -eq 6) { throw [OperationCanceledException]::new('Cancelled. Protection was not removed.') }
    if ($process.ExitCode -ne 0) { throw "Install-RmmAppControl failed with exit code $($process.ExitCode)." }
}

function Set-RemoteAccessProtection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Blocked', 'Unblocked')][string]$State,
        [string]$InstallRoot = (Get-RemoteAccessProtectionInstallRoot)
    )

    Assert-RemoteAccessProtectionWindows
    if (-not (Test-RemoteAccessProtectionAdministrator)) { throw 'This action requires an elevated administrator session.' }
    if ($State -eq 'Blocked') {
        Invoke-RemoteAccessProtectionInstaller -Mode Enforce -InstallRoot $InstallRoot
        $actual = Get-RemoteAccessProtectionState
        if ($actual.State -eq 'Unknown') { throw "Policy install could not be verified: $($actual.Reason)" }
        if ($actual.State -ne 'Blocked') { throw 'Policy engine returned success, but the remote-access block is not active.' }
        if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\CiTool.exe'))) {
            Write-Host 'All listed remote-access tools are blocked by the staged policy after the required restart.'
        } else {
            Write-Host 'All listed remote-access tools are blocked by the enforced policy.'
        }
        return
    }

    Invoke-RemoteAccessProtectionInstaller -Mode Remove -InstallRoot $InstallRoot
    $actual = Get-RemoteAccessProtectionState
    if ($actual.State -eq 'Unknown') { throw "Policy removal could not be verified: $($actual.Reason)" }
    if ($actual.State -ne 'Unblocked') { throw 'Policy engine returned success, but its blocking policy is still installed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\CiTool.exe'))) {
        Write-Host 'The policy file was removed. Restart Windows to finish unblocking the tools.'
    } else {
        Write-Host 'The project policy was removed; the tools are unblocked.'
    }
}

function Enable-RemoteAccessProtection {
    [CmdletBinding()]
    param()

    $InstallRoot = Get-RemoteAccessProtectionInstallRoot
    Set-RemoteAccessProtection -State Blocked -InstallRoot $InstallRoot
}

function New-RemoteAccessProtectionShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$ControllerPath = (Join-Path $InstallRoot 'Invoke-RemoteAccessProtection.ps1')
    )

    Assert-RemoteAccessProtectionWindows
    if (-not (Test-Path -LiteralPath $ControllerPath)) { throw "Desktop controller not found: $ControllerPath" }
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { throw 'The shared Windows desktop folder could not be resolved.' }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($control in @(
        @{ Name = 'Allow Remote Access'; Action = 'Allow'; Description = 'Danger: removes remote-access blocking after identity checks and explicit warnings.' },
        @{ Name = 'Block Remote Access'; Action = 'Enable'; Description = 'Restore Windows App Control remote-access blocking.' }
    )) {
        $shortcutPath = Join-Path $desktop ($control.Name + '.lnk')
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $script:WindowsPowerShellPath
        $shortcut.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $ControllerPath, $control.Action
        $shortcut.WorkingDirectory = $InstallRoot
        $shortcut.Description = $control.Description
        $shortcut.IconLocation = $script:WindowsPowerShellPath + ',0'
        $shortcut.Save()
        Write-Host "Desktop control created: $shortcutPath"
    }
    $legacyShortcut = Join-Path $desktop 'Remote access protection.lnk'
    if (Test-Path -LiteralPath $legacyShortcut) { Remove-Item -LiteralPath $legacyShortcut -Force }
}

function Set-RemoteAccessProtectionPolicyDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePolicyDir,
        [Parameter(Mandatory = $true)][string]$TargetPolicyDir
    )

    foreach ($mode in 'Enforce', 'Audit') {
        foreach ($extension in 'cip', 'xml') {
            $source = Join-Path $SourcePolicyDir "variants\RmmBlock-$mode-$($script:AllBlockedVariant).$extension"
            if (-not (Test-Path -LiteralPath $source)) { throw "All-blocked $mode.$extension policy is missing: $source" }
            $target = Join-Path $TargetPolicyDir "RmmBlock-$mode.$extension"
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
    $summary = Join-Path $TargetPolicyDir 'summary.txt'
    if (Test-Path -LiteralPath $summary) { Remove-Item -LiteralPath $summary -Force }
}

function Install-RemoteAccessProtection {
    [CmdletBinding()]
    param()

    $InstallRoot = Get-RemoteAccessProtectionInstallRoot
    Assert-RemoteAccessProtectionWindows
    if (-not (Test-RemoteAccessProtectionAdministrator)) { throw 'Run the host script as administrator before installing remote-access protection.' }
    $source = Resolve-RemoteAccessProtectionSource
    if (-not (Test-Path -LiteralPath $source.PolicyDir)) { throw "Policy directory not found: $($source.PolicyDir)" }
    $allBlocked = Join-Path $source.PolicyDir "variants\RmmBlock-Enforce-$($script:AllBlockedVariant).cip"
    if (-not (Test-Path -LiteralPath $allBlocked)) { throw "All-blocked policy is missing: $allBlocked" }

    $targetPolicy = Join-Path $InstallRoot 'policy'
    New-Item -ItemType Directory -Force -Path $targetPolicy | Out-Null
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    foreach ($entry in (Get-ChildItem -LiteralPath $source.PolicyDir -Force -Recurse)) {
        $relative = $entry.FullName.Substring($source.PolicyDir.Length).TrimStart([char]92, [char]47)
        $destination = Join-Path $targetPolicy $relative
        if ($entry.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
        } else {
            $parent = Split-Path $destination -Parent
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
            Copy-Item -LiteralPath $entry.FullName -Destination $destination -Force
        }
    }
    Set-RemoteAccessProtectionPolicyDefaults -SourcePolicyDir $source.PolicyDir -TargetPolicyDir $targetPolicy

    $controllerSource = $source.Controller
    $moduleSource = $source.Module
    foreach ($path in @($controllerSource, $moduleSource, $source.SafetyModule, $source.Installer, $source.RevertScript, $source.RevertBatch)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Required integration asset missing: $path" }
        $destination = Join-Path $InstallRoot (Split-Path $path -Leaf)
        if ([System.IO.Path]::GetFullPath($path) -ne [System.IO.Path]::GetFullPath($destination)) {
            Copy-Item -LiteralPath $path -Destination $destination -Force
        }
    }

    # Keep only the selected engine/revert versions so lexical auto-detection cannot pick an older or unrelated copy.
    $installedEngine = Split-Path $source.Installer -Leaf
    foreach ($old in (Get-ChildItem -LiteralPath $InstallRoot -Filter 'Install-RmmAppControl.v*.ps1' -File -ErrorAction SilentlyContinue)) {
        if ($old.Name -ne $installedEngine) { Remove-Item -LiteralPath $old.FullName -Force }
    }
    $installedRevert = Split-Path $source.RevertScript -Leaf
    foreach ($old in (Get-ChildItem -LiteralPath $InstallRoot -Filter 'Revert-RemoteAccessBlock-WinOnly.v*.ps1' -File -ErrorAction SilentlyContinue)) {
        if ($old.Name -ne $installedRevert) { Remove-Item -LiteralPath $old.FullName -Force }
    }

    New-RemoteAccessProtectionShortcut -InstallRoot $InstallRoot
    Set-RemoteAccessProtection -State Blocked -InstallRoot $InstallRoot
    Write-Host 'Install complete. Use Allow Remote Access only for verified support; Block Remote Access restores protection.'
}

function Invoke-RemoteAccessProtectionAllow {
    [CmdletBinding()]
    param()

    Assert-RemoteAccessProtectionWindows
    if (-not (Test-RemoteAccessProtectionAdministrator)) { throw 'Allow Remote Access requires administrator approval.' }
    $current = Get-RemoteAccessProtectionState
    if ($current.State -eq 'Unknown') { throw "Cannot allow remote access from an unknown policy state: $($current.Reason)" }
    if ($current.State -eq 'Unblocked') { Write-Host 'This project is already not blocking remote-access tools. No change made.'; return }
    # The policy engine requires the shared anti-scam confirmations at its removal boundary.
    Set-RemoteAccessProtection -State Unblocked -InstallRoot (Get-RemoteAccessProtectionInstallRoot)
}

function Invoke-RemoteAccessProtectionToggle {
    [CmdletBinding()]
    param()

    $InstallRoot = Get-RemoteAccessProtectionInstallRoot
    Assert-RemoteAccessProtectionWindows
    if (-not (Test-RemoteAccessProtectionAdministrator)) { throw 'The desktop toggle must be run elevated.' }
    $current = Get-RemoteAccessProtectionState
    if ($current.State -eq 'Unknown') { throw "Cannot safely toggle an unknown policy state: $($current.Reason)" }
    if ($current.State -eq 'Blocked') {
        Invoke-RemoteAccessProtectionAllow
    } else {
        Set-RemoteAccessProtection -State Blocked -InstallRoot $InstallRoot
    }
}

function Show-RemoteAccessProtectionStatus {
    [CmdletBinding()]
    param()

    $InstallRoot = Get-RemoteAccessProtectionInstallRoot
    $state = Get-RemoteAccessProtectionState
    switch ($state.State) {
        'Blocked' { Write-Host 'Status: BLOCKED by the project policy.' }
        'Unblocked' { Write-Host 'Status: NOT BLOCKED; use Block Remote Access to enable protection.' }
        default { Write-Host 'Status: UNKNOWN; run as administrator and inspect the Code Integrity policy state.' }
    }
    Write-Host $state.Reason
    if ($state.Variant) { Write-Host "Installed variant: $($state.Variant)" }
}

Export-ModuleMember -Function Get-RemoteAccessProtectionInstallRoot, Test-RemoteAccessProtectionAdministrator, ConvertFrom-RemoteAccessPolicyList, Get-RemoteAccessProtectionState, Install-RemoteAccessProtection, Enable-RemoteAccessProtection, Invoke-RemoteAccessProtectionAllow, Invoke-RemoteAccessProtectionToggle, Show-RemoteAccessProtectionStatus
