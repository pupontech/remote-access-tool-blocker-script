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

# Exactly one typed sentence, on the first dialog only.
$catalogPath = Join-Path $repoRoot 'integration\RemoteAccessSafety.i18n.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($language in @('en', 'he')) {
    $stages = @($catalog.$language.Stages)
    Assert-True ($stages.Count -eq 3) "$language must have three stages."
    Assert-True ($stages[0].Phrase -is [string] -and $stages[0].Phrase.Length -gt 0) "$language stage 1 must require a sentence."
    Assert-True ($null -eq $stages[1].Phrase) "$language stage 2 must not require typing."
    Assert-True ($null -eq $stages[2].Phrase) "$language stage 3 must not require typing."
}
$englishSentence = [string]$catalog.en.Stages[0].Phrase
$hebrewSentence = [string]$catalog.he.Stages[0].Phrase

foreach ($language in @('en', 'he')) {
    $sentence = [string]$catalog.$language.Stages[0].Phrase
    $wrongLanguage = if ($language -eq 'en') { 'he' } else { 'en' }
    Assert-True (& $moduleInfo { param($t, $l) Test-RemoteAccessSafetyPhrase -Text $t -Language $l -Stage 1 } $sentence $language) "Exact stage-1 sentence rejected for $language."
    Assert-False (& $moduleInfo { param($t, $l) Test-RemoteAccessSafetyPhrase -Text $t -Language $l -Stage 1 } $sentence $wrongLanguage) 'Sentence from the other language was accepted.'
    Assert-False (& $moduleInfo { param($t, $l) Test-RemoteAccessSafetyPhrase -Text $t -Language $l -Stage 1 } " $sentence" $language) 'Leading space was accepted.'
    Assert-False (& $moduleInfo { param($t, $l) Test-RemoteAccessSafetyPhrase -Text $t -Language $l -Stage 1 } "$sentence " $language) 'Trailing space was accepted.'
    if ($language -eq 'en') {
        Assert-False (& $moduleInfo { param($t, $l) Test-RemoteAccessSafetyPhrase -Text $t -Language $l -Stage 1 } $sentence.ToLowerInvariant() $language) 'Wrong case was accepted.'
    }
    foreach ($stage in 2, 3) {
        Assert-False (& $moduleInfo { param($t, $l, $s) Test-RemoteAccessSafetyPhrase -Text $t -Language $l -Stage $s } $sentence $language $stage) "Stage $stage must never demand a phrase."
    }
}
foreach ($badText in @('', ' ')) {
    Assert-False (& $moduleInfo { param($t) Test-RemoteAccessSafetyPhrase -Text $t -Language en -Stage 1 } $badText) 'Empty or blank phrase was accepted.'
}
Assert-False (& $moduleInfo { Test-RemoteAccessSafetyPhrase -Text $null -Language en -Stage 1 }) 'Null phrase was accepted.'

# A catalog that asks for a second phrase must be rejected outright.
$broken = [pscustomobject]@{
    en = [pscustomobject]@{
        LanguageName = 'English'; Title = 'T'; Yes = 'Yes'; No = 'No'; Cancel = 'Cancel'; LanguageLabel = 'Language'; Instruction = 'i'
        Stages = @(
            [pscustomobject]@{ Warning = 'w1'; Phrase = 'once' }
            [pscustomobject]@{ Warning = 'w2'; Phrase = 'again' }
            [pscustomobject]@{ Warning = 'w3'; Phrase = $null }
        )
    }
    he = [pscustomobject]@{
        LanguageName = 'x'; Title = 'T'; Yes = 'Y'; No = 'N'; Cancel = 'C'; LanguageLabel = 'L'; Instruction = 'i'
        Stages = @(
            [pscustomobject]@{ Warning = 'w1'; Phrase = 'once' }
            [pscustomobject]@{ Warning = 'w2'; Phrase = $null }
            [pscustomobject]@{ Warning = 'w3'; Phrase = $null }
        )
    }
}
$threw = $false
try { & $moduleInfo { param($c) Get-RemoteAccessSafetyCatalog -Catalog $c } $broken | Out-Null } catch { $threw = $true }
Assert-True $threw 'A catalog that asks for a second phrase must be rejected.'

$privateFunctions = & $moduleInfo {
    Get-Command Get-RemoteAccessSafetyCatalog, New-RemoteAccessSafetyDialog, Show-RemoteAccessSafetyPrompt, Get-RemoteAccessSafetyPhrase, Set-RemoteAccessSafetyDirection -ErrorAction Stop
}
Assert-True (@($privateFunctions).Count -eq 5) 'Required private helpers are missing.'

# Crash guard: the dialog must never toggle RightToLeftLayout at runtime.
$source = Get-Content -LiteralPath $modulePath -Raw
Assert-False ($source -match '\.RightToLeftLayout\s*=') 'The safety dialog must not assign RightToLeftLayout; it re-creates the window handle.'
Assert-False ($source -match '\bRead-Host\b') 'Console input is forbidden in the safety dialog.'

function New-Answer {
    param([bool]$Approved, [string]$Language)
    [pscustomobject]@{ Approved = $Approved; Language = $Language }
}
function Invoke-ConfirmCase {
    param([object[]]$Answers)
    & $moduleInfo {
        param([object[]]$Answers)
        $script:AnswerIndex = 0
        $script:Stages = @()
        $script:Languages = @()
        function Show-RemoteAccessSafetyPrompt {
            param([int]$Stage, [string]$Language)
            $script:Stages += $Stage
            $script:Languages += $Language
            if ($script:AnswerIndex -ge $Answers.Count) { throw 'test input exhausted' }
            $answer = $Answers[$script:AnswerIndex]
            $script:AnswerIndex++
            if ($answer -is [Exception]) { throw $answer }
            return $answer
        }
        $value = @(Confirm-AllowRemoteAccess)
        [pscustomobject]@{
            Value     = if ($value.Count -eq 1) { $value[0] } else { $null }
            Count     = $value.Count
            Calls     = $script:AnswerIndex
            Stages    = @($script:Stages)
            Languages = @($script:Languages)
        }
    } $Answers
}

$refusalCases = New-Object System.Collections.ArrayList
[void]$refusalCases.Add(@((New-Answer $false 'en')))
[void]$refusalCases.Add(@((New-Answer $true 'en'), (New-Answer $false 'en')))
[void]$refusalCases.Add(@((New-Answer $true 'he'), (New-Answer $true 'he'), (New-Answer $false 'he')))
[void]$refusalCases.Add(@([Exception]::new('dialog closed')))
[void]$refusalCases.Add(@((New-Answer $true 'en'), [Exception]::new('dialog crashed')))
[void]$refusalCases.Add(@('malformed'))
[void]$refusalCases.Add(@((New-Answer $true 'fr')))
[void]$refusalCases.Add(@((New-Answer $true 'en'), (New-Answer $true ''), (New-Answer $true 'en')))
foreach ($answers in $refusalCases) {
    $case = Invoke-ConfirmCase $answers
    Assert-False ($case.Value -is [bool] -and $case.Value) 'Refusal, exception or invalid language was approved.'
    Assert-True ($case.Count -eq 1) 'Confirmation must emit exactly one value.'
}

$success = Invoke-ConfirmCase @(
    (New-Answer $true 'he')
    (New-Answer $true 'he')
    (New-Answer $true 'he')
)
Assert-True ($success.Value -is [bool] -and $success.Value) 'Three approvals were not accepted.'
Assert-True ($success.Count -eq 1) 'Confirmation must emit exactly one value on success.'
Assert-True ($success.Calls -eq 3) 'Expected exactly one prompt per stage.'
Assert-True (($success.Stages -join ',') -eq '1,2,3') 'Stages must run in order.'
Assert-True (($success.Languages -join ',') -eq 'en,he,he') 'Chosen language was not carried forward.'

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
$actual = [string]$catalog.he.Stages[0].Phrase
if ($actual -cne $Expected) { throw "Catalog resolved to '$actual'" }
if (-not (& $m { param($t) Test-RemoteAccessSafetyPhrase -Text $t -Language he -Stage 1 } $Expected)) {
    throw 'Default catalog sentence check failed from a foreign caller directory.'
}
'@
    $engine = (Get-Process -Id $PID).Path
    & $engine -NoProfile -File $caller -ModulePath $modulePath -Expected $hebrewSentence
    if ($LASTEXITCODE -ne 0) { throw 'Catalog lookup failed when called from a different directory.' }
} finally {
    if (Test-Path -LiteralPath $callerRoot) { Remove-Item -LiteralPath $callerRoot -Recurse -Force }
}

Write-Host "Remote access safety tests passed. One sentence only: EN '$englishSentence' / HE '$hebrewSentence'."
