$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'integration\RemoteAccessSafety.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Missing module: $modulePath" }

$source = Get-Content -LiteralPath $modulePath -Raw
$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw "Parse failed: $($errors[0].Message)" }

Import-Module $modulePath -Force -ErrorAction Stop
$moduleInfo = Get-Module RemoteAccessSafety
$exports = @(Get-Command -Module RemoteAccessSafety | Select-Object -ExpandProperty Name)
if ($exports.Count -ne 1 -or $exports[0] -ne 'Confirm-AllowRemoteAccess') {
    throw "Module must export only Confirm-AllowRemoteAccess; exported: $($exports -join ', ')"
}
if ($source -match '\bRead-Host\b') { throw 'Console Read-Host fallback is forbidden.' }
if ($source -notmatch 'MessageBoxDefaultButton\]::Button2') { throw 'Native popup must default to No.' }
if ($source -notmatch 'MessageBoxButtons\]::YesNoCancel') { throw 'Native popup must offer Yes, No and Cancel.' }
if ($source -notmatch 'MessageBoxIcon\]::Warning') { throw 'Native popup must use Warning icon.' }
if ($source -notmatch 'System\.Windows\.Forms') { throw 'Native Windows Forms MessageBox is required.' }
if ($source -notmatch 'Add-Type') { throw 'Windows Forms assembly must load lazily.' }
if ($source -notmatch 'Show-RemoteAccessSafetyPrompt') { throw 'Private popup helper is required.' }
if ($source -match 'Export-ModuleMember[^\r\n]*Show-RemoteAccessSafetyPrompt') { throw 'Popup helper must remain private.' }

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
$nativeCheck = @(& $moduleInfo {
    $value = @(Show-RemoteAccessSafetyPrompt -Title 'test' -Text 'test')
    [pscustomobject]@{ Value = if ($value.Count -eq 1) { $value[0] } else { $null }; Count = $value.Count }
})
if ($nativeCheck.Count -ne 1 -or $nativeCheck[0].Count -ne 1 -or $nativeCheck[0].Value -isnot [bool]) {
    throw 'Native popup helper must return exactly one Boolean on non-Windows/error paths.'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -and $nativeCheck[0].Value) {
    throw 'Native popup helper must refuse on non-Windows.'
}
}

$requiredText = @(
    'WARNING: Remote access can expose your files, passwords, and banking information.',
    'Never allow a stranger or an unexpected caller to connect. Caller ID is not proof.',
    'If an unexpected caller asks for access, hang up. Independently find the company official number on a trusted website, bill, or card, then manually dial it.',
    'Do not use a number or link supplied by the caller, and do not trust search ads.',
    'Never share passwords or one-time codes, and never access your bank while connected.',
    'Only proceed for a technician you know and trust in person, or support you independently contacted and verified.',
    'WARNING: You are about to remove a safety barrier. A scammer may steal your money or private information.',
    'FINAL WARNING: Do not continue because a caller is pressuring you. Cancel if you have any doubt.'
)
foreach ($text in $requiredText) {
    if ($source.IndexOf($text, [StringComparison]::Ordinal) -lt 0) { throw "Preserved warning text missing: $text" }
}

function Invoke-Case {
    param([object[]]$Answers, [bool]$Expected, [string]$Name)
    $results = @(& $moduleInfo {
        param($Answers)
        $script:Calls = @()
        $script:AnswerIndex = 0
        function Show-RemoteAccessSafetyPrompt {
            param([string]$Title, [string]$Text)
            $script:Calls += [pscustomobject]@{ Title = $Title; Text = $Text }
            if ($script:AnswerIndex -ge $Answers.Count) { throw 'test input exhausted' }
            $answer = $Answers[$script:AnswerIndex]
            $script:AnswerIndex++
            if ($answer -is [Exception]) { throw $answer }
            return $answer
        }
        $value = @(Confirm-AllowRemoteAccess)
        [pscustomobject]@{
            Value = if ($value.Count -eq 1) { $value[0] } else { $null }
            OutputCount = $value.Count
            Calls = @($script:Calls)
        }
    } $Answers)
    if ($results.Count -ne 1) { throw "$Name`: expected one result object" }
    $result = $results[0]
    if ($result.OutputCount -ne 1 -or $result.Value -isnot [bool]) { throw "$Name`: output must be exactly one Boolean" }
    if ($result.Value -ne $Expected) { throw "$Name`: expected $Expected, got $($result.Value)" }
    $expectedCalls = if ($Expected) { 3 } else { $Answers.Count }
    if ($result.Calls.Count -ne $expectedCalls) { throw "$Name`: expected $expectedCalls popup(s), got $($result.Calls.Count)" }
    return $result
}

Invoke-Case -Name 'first refusal' -Answers @($false) -Expected $false | Out-Null
Invoke-Case -Name 'second refusal' -Answers @($true, $false) -Expected $false | Out-Null
Invoke-Case -Name 'third refusal' -Answers @($true, $true, $false) -Expected $false | Out-Null
Invoke-Case -Name 'first exception' -Answers @([Exception]::new('closed')) -Expected $false | Out-Null
Invoke-Case -Name 'second exception' -Answers @($true, [Exception]::new('closed')) -Expected $false | Out-Null
Invoke-Case -Name 'third exception' -Answers @($true, $true, [Exception]::new('closed')) -Expected $false | Out-Null
Invoke-Case -Name 'first nonbool' -Answers @('Yes') -Expected $false | Out-Null
Invoke-Case -Name 'second nonbool' -Answers @($true, 1) -Expected $false | Out-Null
Invoke-Case -Name 'third nonbool' -Answers @($true, $true, [int]1) -Expected $false | Out-Null
$success = Invoke-Case -Name 'three explicit Yes answers' -Answers @($true, $true, $true) -Expected $true

$first = $success.Calls[0].Text
$second = $success.Calls[1].Text
$third = $success.Calls[2].Text
for ($i=0; $i -lt 3; $i++) { if ($success.Calls[$i].Title -notlike ('*({0} of 3)' -f ($i+1))) { throw 'Popup stage title is missing.' } }
if ($first -notmatch 'I VERIFIED THE PERSON' -or $second -notmatch 'I UNDERSTAND THE RISK' -or $third -notmatch 'ALLOW REMOTE ACCESS') { throw 'Popup stages are out of order or missing.' }
if ($first -notmatch 'files.*passwords.*banking' -or $first -notmatch 'stranger|unexpected caller' -or $first -notmatch 'caller ID' -or $first -notmatch 'official number|trusted website|bill|card|manually dial' -or $first -notmatch 'one-time codes|bank') { throw 'Core scam/password/banking warning text was not preserved in popup body.' }
if ($second -notmatch 'safety barrier|scammer') { throw 'Second warning text missing.' }
if ($third -notmatch 'FINAL WARNING|pressuring you|Cancel') { throw 'Final warning text missing.' }

Write-Host 'Remote access safety tests passed.'
