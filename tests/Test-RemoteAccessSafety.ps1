$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'integration\RemoteAccessSafety.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Missing module: $modulePath" }

$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw "Parse failed: $($errors[0].Message)" }
Import-Module $modulePath -Force -ErrorAction Stop
$moduleInfo = Get-Module RemoteAccessSafety
$exports = @(Get-Command -Module RemoteAccessSafety | Select-Object -ExpandProperty Name)
if ($exports.Count -ne 1 -or $exports[0] -ne 'Confirm-AllowRemoteAccess') { throw "Unexpected exports: $($exports -join ', ')" }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw $Message }
}

$catalogPath = Join-Path $repoRoot 'integration\RemoteAccessSafety.i18n.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($language in @('en', 'he')) {
    for ($stage = 1; $stage -le 3; $stage++) {
        $phrase = $catalog.$language.Stages[$stage - 1].Phrase
        $result = & $moduleInfo { param($Text, $Language, $Stage) Test-RemoteAccessSafetyPhrase -Text $Text -Language $Language -Stage $Stage } $phrase $language $stage
        Assert-True $result ("Exact phrase rejected for {0}/{1}" -f $language, $stage)
        $wrongLanguage = if ($language -eq 'en') { 'he' } else { 'en' }
        Assert-False (& $moduleInfo { param($Text, $Language, $Stage) Test-RemoteAccessSafetyPhrase -Text $Text -Language $Language -Stage $Stage } $phrase $wrongLanguage $stage) 'Wrong language accepted.'
        if ($language -eq 'en') {
            Assert-False (& $moduleInfo { param($Text, $Language, $Stage) Test-RemoteAccessSafetyPhrase -Text $Text.ToLowerInvariant() -Language $Language -Stage $Stage } $phrase $language $stage) 'Wrong case accepted.'
        }
    }
}
foreach ($badText in @('', ' ', $null)) {
    Assert-False (& $moduleInfo { param($Text) Test-RemoteAccessSafetyPhrase -Text $Text -Language en -Stage 1 } $badText) 'Empty or null phrase accepted.'
}

$privateFunctions = & $moduleInfo {
    Get-Command Get-RemoteAccessSafetyCatalog, New-RemoteAccessSafetyDialog, Show-RemoteAccessSafetyPrompt -ErrorAction Stop
}
Assert-True (@($privateFunctions).Count -eq 3) 'Required private helpers are missing.'

function Invoke-ConfirmCase {
    param([object[]]$Answers)
    & $moduleInfo {
        param($Answers)
        function Show-RemoteAccessSafetyPrompt {
            param([int]$Stage, [string]$Language)
            $script:Languages += $Language
            if ($script:AnswerIndex -ge $Answers.Count) { throw 'test input exhausted' }
            $answer = $Answers[$script:AnswerIndex]
            $script:AnswerIndex++
            if ($answer -is [Exception]) { throw $answer }
            return $answer
        }
        $script:AnswerIndex = 0
        $script:Languages = @()
        $value = @(Confirm-AllowRemoteAccess)
        [pscustomobject]@{ Value = if ($value.Count -eq 1) { $value[0] } else { $null }; Count = $value.Count; Calls = $script:AnswerIndex; Languages = @($script:Languages) }
    } $Answers
}
foreach ($answers in @(@([pscustomobject]@{ Approved = $false; Language = 'en' }), @([pscustomobject]@{ Approved = $true; Language = 'en' }), @([pscustomobject]@{ Approved = $false; Language = 'he' }), @([Exception]::new('closed')), @('malformed'))) {
    $case = Invoke-ConfirmCase $answers
    Assert-False ($case.Value -is [bool] -and $case.Value) 'Refusal or exception was approved.'
}
$success = Invoke-ConfirmCase @(
    [pscustomobject]@{ Approved = $true; Language = 'he' }
    [pscustomobject]@{ Approved = $true; Language = 'en' }
    [pscustomobject]@{ Approved = $true; Language = 'he' }
)
Assert-True ($success.Value -is [bool] -and $success.Value) 'Three approvals were not accepted.'
Assert-True ($success.Calls -eq 3) 'Expected exactly one approval per stage.'
Assert-True (($success.Languages -join ',') -eq 'en,he,en') 'Chosen language was not propagated.'

# The catalog must resolve from the module's OWN directory even when a caller in a
# different folder imports it (the documented $PSScriptRoot-in-function trap).
$callerRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("safety-caller-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $callerRoot -Force | Out-Null
    $caller = Join-Path $callerRoot 'foreign-caller.ps1'
    Set-Content -LiteralPath $caller -Encoding ASCII -Value @'
param([string]$ModulePath, [string]$Expected)
Import-Module -Name $ModulePath -Force -ErrorAction Stop
$m = Get-Module RemoteAccessSafety
$catalog = & $m { Get-RemoteAccessSafetyCatalog }
$actual = [string]$catalog.he.Stages[2].Phrase
if ($actual -cne $Expected) { throw "Catalog resolved to '$actual'" }
if (-not (& $m { param($t) Test-RemoteAccessSafetyPhrase -Text $t -Language he -Stage 3 } $Expected)) {
    throw 'Default catalog phrase check failed from a foreign caller directory.'
}
'@
    $engine = (Get-Process -Id $PID).Path
    & $engine -NoProfile -File $caller -ModulePath $modulePath -Expected $catalog.he.Stages[2].Phrase
    if ($LASTEXITCODE -ne 0) { throw 'Catalog lookup failed when called from a different directory.' }
} finally {
    if (Test-Path -LiteralPath $callerRoot) { Remove-Item -LiteralPath $callerRoot -Recurse -Force }
}

Write-Host 'Remote access safety tests passed.'