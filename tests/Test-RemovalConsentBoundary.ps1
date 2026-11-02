# Execute the real engine removal branch with inert policy/native-command doubles.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/appcontrol/Install-RmmAppControl.v2026-11-02.1.ps1'),[ref]$tokens,[ref]$errors)
$branch=$null
foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst]},$true)) {
    foreach($clause in $node.Clauses) {
        if($clause.Item1.Extent.Text -eq "`$Mode -eq 'Remove'") { $branch=$clause.Item2.Extent.Text }
    }
}
if(-not $branch) { throw 'Removal branch not found' }
if(-not $branch.Contains('Request-AllowRemoteAccessConsent')) { throw 'Policy removal has no consent gate.' }
$base=if($env:TMPDIR){$env:TMPDIR}else{[IO.Path]::GetTempPath()}
$fixture=Join-Path $base ('removal-consent-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    foreach($approved in @($false,$true)) {
        $text=@'
$ErrorActionPreference='Stop'
$ciTool='synthetic-no-native-tool'
$activeDir='synthetic-active'
$PolicyGuid='test-policy'
function Write-Log {param($m) Write-Host $m}
function Test-Path {param($LiteralPath) return ($LiteralPath -eq (Join-Path $activeDir ($PolicyGuid+'.cip')))}
function Remove-Item {param($LiteralPath,[switch]$Force) Write-Host 'FAKE_POLICY_REMOVAL'}
'@
        $text += "`nfunction Request-AllowRemoteAccessConsent { return `$$approved }`n& $branch`n"
        $file=Join-Path $fixture ('case-'+$approved+'.ps1')
        [IO.File]::WriteAllText($file,$text)
        $engine=(Get-Process -Id $PID).Path
        $output=(& $engine -NoProfile -File $file 2>&1 | Out-String)
        $rc=$LASTEXITCODE
        if($approved) {
            if($rc -ne 0 -or $output -notmatch 'FAKE_POLICY_REMOVAL') { throw "Approved fixture failed: $rc $output" }
        } elseif($rc -eq 0 -or $output -match 'FAKE_POLICY_REMOVAL') { throw "Denied consent reached removal: $rc $output" }
    }
    Write-Host 'PASS: real engine branch refuses removal without consent and reaches only inert removal after approval.'
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
