$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'integration\RemoteAccessProtection.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Missing module: $modulePath" }
$ErrorActionPreference = 'Continue'
Import-Module $modulePath -Force -ErrorAction Stop
$moduleInfo = Get-Module RemoteAccessProtection
$exports = @(Get-Command -Module RemoteAccessProtection | Select-Object -ExpandProperty Name)
if ($exports -notcontains 'Enable-RemoteAccessProtection') { throw 'Enable-RemoteAccessProtection must be part of the module API.' }
if ($exports -contains 'Set-RemoteAccessProtection') { throw 'The raw unblock operation must remain private.' }
$modulePreference = & $moduleInfo { $ErrorActionPreference }
$ErrorActionPreference = 'Stop'
if ($modulePreference -ne 'Stop') { throw 'Module state-changing file operations must fail fast.' }
$sourceLayout = & $moduleInfo { Resolve-RemoteAccessProtectionSource }
if ([System.IO.Path]::GetFullPath($sourceLayout.AssetRoot) -ne [System.IO.Path]::GetFullPath($repoRoot)) {
    throw "Source layout resolved to '$($sourceLayout.AssetRoot)' instead of '$repoRoot'"
}
if (-not (Test-Path -LiteralPath (Join-Path $sourceLayout.PolicyDir 'variants\RmmBlock-Enforce-T1A1S1R1.cip'))) {
    throw 'Source layout did not resolve the all-blocked policy payload.'
}
$tempBase = if ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$policyTestRoot = Join-Path $tempBase "remote-access-policy-defaults-$PID"
$sourcePolicy = Join-Path $policyTestRoot 'source'
$targetPolicy = Join-Path $policyTestRoot 'installed'
try {
    $sourceVariants = Join-Path $sourcePolicy 'variants'
    New-Item -ItemType Directory -Force -Path $sourceVariants | Out-Null
    New-Item -ItemType Directory -Force -Path $targetPolicy | Out-Null
    foreach ($mode in 'Enforce', 'Audit') {
        foreach ($extension in 'cip', 'xml') {
            $variant = Join-Path $sourceVariants "RmmBlock-$mode-T1A1S1R1.$extension"
            $baseline = Join-Path $targetPolicy "RmmBlock-$mode.$extension"
            [System.IO.File]::WriteAllText($variant, "all-blocked-$mode-$extension")
            [System.IO.File]::WriteAllText($baseline, 'legacy-upstream-default')
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $targetPolicy 'summary.txt'), 'stale upstream default')
    & $moduleInfo {
        param($SourceDir, $TargetDir)
        Set-RemoteAccessProtectionPolicyDefaults -SourcePolicyDir $SourceDir -TargetPolicyDir $TargetDir
    } $sourcePolicy $targetPolicy
    foreach ($mode in 'Enforce', 'Audit') {
        foreach ($extension in 'cip', 'xml') {
            $actual = Get-Content -Raw (Join-Path $targetPolicy "RmmBlock-$mode.$extension")
            if ($actual -ne "all-blocked-$mode-$extension") { throw "Installed $mode.$extension default was not all-blocked." }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $targetPolicy 'summary.txt')) { throw 'Stale upstream policy summary was retained.' }
} finally {
    if (Test-Path -LiteralPath $policyTestRoot) { Remove-Item -LiteralPath $policyTestRoot -Recurse -Force }
}

$guid = '{2D13BFB7-4304-4847-9CDD-37820D3EE9B7}'
function Assert-State([string]$Name, [string]$Json, [string]$Expected) {
    $actual = ConvertFrom-RemoteAccessPolicyList -Json $Json
    if ($actual.State -ne $Expected) {
        throw "$Name`: expected state '$Expected', got '$($actual.State)'"
    }
}

$enforcedJson = @{
    OperationResult = 0
    Policies = @(@{ PolicyID = $guid; FriendlyName = 'Remote Access Tool Blocker - Enforce [T1A1S1R1]'; IsEnforced = $true })
} | ConvertTo-Json -Depth 5
Assert-State 'Enforced policy is blocked' $enforcedJson 'Blocked'
$enforcedStatus = ConvertFrom-RemoteAccessPolicyList -Json $enforcedJson
if ($enforcedStatus.Variant -ne 'T1A1S1R1') { throw "Variant parser returned '$($enforcedStatus.Variant)' instead of T1A1S1R1" }
Assert-State 'Any enforced project variant is treated as blocked' (@{
    OperationResult = 0
    Policies = @(@{ PolicyID = $guid; FriendlyName = 'Remote Access Tool Blocker - Enforce [T1A1S0R1]'; IsEnforced = $true })
} | ConvertTo-Json -Depth 5) 'Blocked'
Assert-State 'Unverified enforce state fails closed' (@{
    OperationResult = 0
    Policies = @(@{ PolicyID = $guid; FriendlyName = 'Remote Access Tool Blocker - Enforce [T1A1S1R1]'; IsEnforced = $false })
} | ConvertTo-Json -Depth 5) 'Unknown'

Assert-State 'Audit policy is not blocking' (@{
    OperationResult = 0
    Policies = @(@{ PolicyID = $guid; FriendlyName = 'Remote Access Tool Blocker - Audit [T1A1S1R1]'; IsEnforced = $true })
} | ConvertTo-Json -Depth 5) 'Unblocked'

Assert-State 'A different policy is untouched' (@{
    OperationResult = 0
    Policies = @(@{ PolicyID = '{11111111-1111-1111-1111-111111111111}'; FriendlyName = 'Unrelated'; IsEnforced = $true })
} | ConvertTo-Json -Depth 5) 'Unblocked'

Assert-State 'CiTool access denied is unknown' (@{ OperationResult = -2147024891; Policies = @() } | ConvertTo-Json -Depth 5) 'Unknown'
Assert-State 'Missing policy listing is unknown' (@{ OperationResult = 0 } | ConvertTo-Json -Depth 5) 'Unknown'
Assert-State 'Malformed policy entries are unknown' (@{ OperationResult = 0; Policies = @(@{ FriendlyName = 'No policy identifier'; IsEnforced = $true }) } | ConvertTo-Json -Depth 5) 'Unknown'
Assert-State 'Missing policy list is unblocked' (@{ OperationResult = 0; Policies = @() } | ConvertTo-Json -Depth 5) 'Unblocked'
Assert-State 'Malformed JSON is unknown' 'not-json' 'Unknown'

$entry = Get-Content -Raw (Join-Path $repoRoot 'integration\Invoke-RemoteAccessProtection.ps1')
$module = Get-Content -Raw $modulePath
$tests = @(
    @{ Name = 'all four switchable tools default blocked'; Text = $module; Pattern = 'T1A1S1R1' },
    @{ Name = 'desktop shortcut lives on common desktop'; Text = $module; Pattern = 'CommonDesktopDirectory' },
    @{ Name = 'desktop shortcut launches toggle action'; Text = $module; Pattern = 'Action Toggle' },
    @{ Name = 'entry point defaults to install'; Text = $entry; Pattern = 'Action = ''Install''' },
    @{ Name = 'module refuses 32-bit App Control access'; Text = $module; Pattern = 'Is64BitOperatingSystem' },
    @{ Name = 'controller upgrades 32-bit launchers'; Text = $entry; Pattern = 'Sysnative' },
    @{ Name = 'no full GUI dependency'; Text = $module + $entry; Pattern = 'System[.]Windows[.]Forms' ; Forbidden = $true }
)
foreach ($test in $tests) {
    $found = $test.Text -match $test.Pattern
    if ($test.Forbidden) { $found = -not $found }
    if (-not $found) { throw "Contract failed: $($test.Name)" }
}

if (-not $entry.Contains('if ($Action -eq ''Toggle'' -and -not $isTrustedController)')) {
    throw 'The toggle must refuse elevation from a user-writable controller path.'
}
if (-not $entry.Contains('if (($Action -in @(''Install'', ''Enable'')) -and -not $isAdmin)')) {
    throw 'Install and enable actions must not self-elevate from an untrusted package path.'
}
if ($entry.Contains('[string]$InstallRoot')) {
    throw 'Controller must not accept a caller-controlled install root across UAC.'
}

$installStart = $module.IndexOf('function Install-RemoteAccessProtection')
$toggleStart = $module.IndexOf('function Invoke-RemoteAccessProtectionToggle', $installStart)
$installBody = $module.Substring($installStart, $toggleStart - $installStart)
$installEntry = $installBody.Substring(0, $installBody.IndexOf('Assert-RemoteAccessProtectionWindows'))
if (-not $installBody.Contains('Set-RemoteAccessProtectionPolicyDefaults')) {
    throw 'Installed policy root defaults must be reset to the all-blocked variant.'
}
if ($installEntry.Contains('[string]$InstallRoot')) { throw 'Public installation must use the protected default Program Files path.' }
if ($installBody.IndexOf('New-RemoteAccessProtectionShortcut') -lt 0 -or
    $installBody.IndexOf('Set-RemoteAccessProtection -State Blocked') -lt $installBody.IndexOf('New-RemoteAccessProtectionShortcut')) {
    throw 'Installation must create the desktop toggle before enforcing the policy.'
}
if ($module -match 'Export-ModuleMember[^\r\n]*Set-RemoteAccessProtection') {
    throw 'Direct policy removal must not be exported as a routine integration command.'
}
if ($module -notmatch "Type UNBLOCK to remove this protection policy") {
    throw 'Unblocking must require explicit typed confirmation from the toggle.'
}

$revertLauncher = Get-Content -Raw (Join-Path $repoRoot 'revert\Run-Revert.bat')
$winOnlyRevertIndex = $revertLauncher.IndexOf('Revert-RemoteAccessBlock-WinOnly.v*.ps1')
if ($winOnlyRevertIndex -lt 0 -or $revertLauncher.Contains('Revert-RemoteAccessBlock.v*.ps1')) {
    throw 'Revert launcher must select only the Windows-only variant.'
}
$installer = Get-Content -Raw (Join-Path $repoRoot 'src\appcontrol\Install-RmmAppControl.v2026-10-11.3.ps1')
$winOnlyRevert = Get-Content -Raw (Join-Path $repoRoot 'revert\Revert-RemoteAccessBlock-WinOnly.v2026-10-11.1.ps1')
if ($installer -match 'Revert-RemoteAccessBlock[.]v[+*?]' -or $installer -match 'eset-remove-guide|ESET website list|handles the ESET') {
    throw 'App Control installer must copy only WinOnly revert and must not handle ESET guides.'
}
if ($winOnlyRevert -match 'ESET|website list') { throw 'WinOnly revert must not contain ESET-specific prose.' }
if ($revertLauncher.Contains(":target_found`r`n)`r`n")) {
    throw 'Revert launcher has an orphaned closing parenthesis after its target label.'
}

$errors = $null; $tokens = $null
foreach ($path in @($modulePath, (Join-Path $repoRoot 'integration\Invoke-RemoteAccessProtection.ps1'))) {
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw "Parse failed for $path`: $($errors[0].Message)" }
    $errors = $null; $tokens = $null
}

Write-Host 'Script integration tests passed.'
