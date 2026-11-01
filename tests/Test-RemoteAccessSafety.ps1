$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'integration\RemoteAccessSafety.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Missing module: $modulePath" }

Import-Module $modulePath -Force -ErrorAction Stop
$moduleInfo = Get-Module RemoteAccessSafety
$exports = @(Get-Command -Module RemoteAccessSafety | Select-Object -ExpandProperty Name)
if ($exports.Count -ne 1 -or $exports[0] -ne 'Confirm-AllowRemoteAccess') {
    throw "Module must export only Confirm-AllowRemoteAccess; exported: $($exports -join ', ')"
}

function Invoke-ConfirmationCase {
    param(
        [Parameter(Mandatory = $true)][object[]]$Answers,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $results = @(& $moduleInfo {
        param($Answers)
        $script:TestAnswers = @($Answers)
        $script:TestAnswerIndex = 0
        $script:TestPrompts = @()
        $script:TestWarnings = @()
        $script:TestWarningColors = @()
        $script:TestOutput = @()
        function Read-Host {
            param([string]$Prompt)
            $script:TestPrompts += $Prompt
            if ($script:TestAnswerIndex -ge $script:TestAnswers.Count) { throw 'test input exhausted' }
            $answer = $script:TestAnswers[$script:TestAnswerIndex]
            $script:TestAnswerIndex++
            if ($answer -is [Exception]) { throw $answer }
            return [string]$answer
        }
        function Write-Host {
            param([object]$Object, [ConsoleColor]$ForegroundColor)
            $script:TestWarnings += [string]$Object
            $script:TestWarningColors += $ForegroundColor
        }
        $script:TestOutput = @(Confirm-AllowRemoteAccess)
        [pscustomobject]@{
            Value = if ($script:TestOutput.Count -eq 1) { $script:TestOutput[0] } else { $null }
            OutputCount = $script:TestOutput.Count
            Prompts = @($script:TestPrompts)
            Warnings = @($script:TestWarnings)
            WarningColors = @($script:TestWarningColors)
        }
    } $Answers)

    if ($results.Count -ne 1) { throw "$Name`: expected one result object, got $($results.Count)" }
    $result = $results[0]
    if ($result.OutputCount -ne 1) { throw "$Name`: function must emit exactly one pipeline value, got $($result.OutputCount)" }
    if ($result.Value -isnot [bool]) { throw "$Name`: result must be a Boolean, got $($result.Value.GetType().FullName)" }
    if ($result.Value -ne $expected) { throw "$Name`: expected $expected, got $($result.Value)" }
    if ($result.Prompts.Count -ne $expectedPrompts) {
        throw "$Name`: expected $expectedPrompts prompt(s), got $($result.Prompts.Count)"
    }
    if ($result.Warnings.Count -lt 1) { throw "$Name`: warning was not displayed" }
    if (@($result.WarningColors | Where-Object { $_ -ne [ConsoleColor]::Red }).Count -ne 0) {
        throw "$Name`: every warning must be red"
    }
    if (-not ($result.Warnings -match 'files|passwords|banking')) { throw "$Name`: warning lacks sensitive-data risk" }
    if (-not ($result.Warnings -match 'stranger|unexpected caller')) { throw "$Name`: warning lacks stranger warning" }
    if (-not ($result.Warnings -match 'caller ID')) { throw "$Name`: warning lacks caller-ID warning" }
    if (-not ($result.Warnings -match 'official number|trusted website|bill|card|manually dial')) { throw "$Name`: warning lacks independent number-verification warning" }
    if (-not ($result.Warnings -match 'one-time codes|passwords|bank')) { throw "$Name`: warning lacks secret/bank warning" }
    return $result
}

$expected = $false; $expectedPrompts = 1
Invoke-ConfirmationCase -Name 'blank first confirmation' -Answers @('') | Out-Null
Invoke-ConfirmationCase -Name 'wrong-case first confirmation' -Answers @('i VERIFIED THE PERSON') | Out-Null
Invoke-ConfirmationCase -Name 'first input exception' -Answers @([Exception]::new('read failed')) | Out-Null

$expected = $false; $expectedPrompts = 2
Invoke-ConfirmationCase -Name 'blank second confirmation' -Answers @('I VERIFIED THE PERSON', '') | Out-Null
Invoke-ConfirmationCase -Name 'wrong-case second confirmation' -Answers @('I VERIFIED THE PERSON', 'i UNDERSTAND THE RISK') | Out-Null
Invoke-ConfirmationCase -Name 'second input exception' -Answers @('I VERIFIED THE PERSON', [Exception]::new('read failed')) | Out-Null

$expected = $false; $expectedPrompts = 3
Invoke-ConfirmationCase -Name 'blank third confirmation' -Answers @('I VERIFIED THE PERSON', 'I UNDERSTAND THE RISK', '') | Out-Null
Invoke-ConfirmationCase -Name 'wrong-case third confirmation' -Answers @('I VERIFIED THE PERSON', 'I UNDERSTAND THE RISK', 'allow remote access') | Out-Null
Invoke-ConfirmationCase -Name 'third input exception' -Answers @('I VERIFIED THE PERSON', 'I UNDERSTAND THE RISK', [Exception]::new('read failed')) | Out-Null

$expected = $true; $expectedPrompts = 3
$success = Invoke-ConfirmationCase -Name 'exact confirmation sequence' -Answers @(
    'I VERIFIED THE PERSON'
    'I UNDERSTAND THE RISK'
    'ALLOW REMOTE ACCESS'
)
if ($success.Prompts[0] -notmatch 'I VERIFIED THE PERSON' -or
    $success.Prompts[1] -notmatch 'I UNDERSTAND THE RISK' -or
    $success.Prompts[2] -notmatch 'ALLOW REMOTE ACCESS') {
    throw 'Confirmation prompts did not identify the required exact phrases.'
}

$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw "Parse failed: $($errors[0].Message)" }

Write-Host 'Remote access safety tests passed.'
